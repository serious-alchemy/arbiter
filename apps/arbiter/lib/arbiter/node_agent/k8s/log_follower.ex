defmodule Arbiter.NodeAgent.K8s.LogFollower do
  @moduledoc """
  The `pods/log` follower of one run (`docs/design/remote-workers.md` K§3.4, ticket K15):
  it turns the `worker` container's log into the `stdout` stream the primary expects from
  any node, `ARB2` frames (`Arbiter.Nodes.StdoutFrame`, A4) whose opaque cursor is
  `Arbiter.NodeAgent.K8s.LogLines`'s `"<timestamp> <n>"`.

    * **Following.** A reader process (`GET …/log?follow=true&timestamps=true`, resumed from
      `sinceTime` = the position's timestamp) hands the lines of each chunk to this process,
      which packs them into frames of at most `:frame_bytes` and `:emit`s them. A stream that
      ends or fails is re-opened from the position after `:retry_ms`.
    * **Backpressure is TCP's.** A frame is kept until the primary acknowledges its cursor
      (`ack/2`). With `:window_bytes` unacknowledged the reader's hand-over blocks, so it
      stops reading and the kubelet stops being drained.
    * **Re-attach.** The frames the primary has not acknowledged are kept in memory, so a
      connection that dropped them costs nothing: `attach/2` takes the cursor the primary
      says it holds (its last taken frame, which an `ack` may not have outrun), forgets what
      is at or before it and sends the rest again. Nothing is read twice.
    * **The end.** `finish/1` says the worker has ended. The next end of the stream is
      followed by one non-follow read from the position to EOF (the tail), the held partial
      line is flushed, and the owner gets `{:log_drained, run, cursor}`: the cursor of the
      last frame (`nil` for a run with no output), which the controller puts in `exit`. A pod
      that is already gone drains with what was sent.

  Started unlinked and monitoring `:owner` (the controller), which it follows to the grave.

  Options: `:run`, `:pod`, `:client`, `:owner` (required), `:emit` (`fn frame -> any`),
  `:cursor` (resume after it), `:container` ("worker"), `:frame_bytes` (16 KiB),
  `:window_bytes` (256 KiB), `:retry_ms` (500).
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.LogLines
  alias Arbiter.Nodes.StdoutFrame

  require Logger

  @frame_bytes 16 * 1024
  @window_bytes 256 * 1024
  @retry_ms 500

  # -- API ----------------------------------------------------------------------

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "The primary acknowledged `cursor`: frames up to it are forgotten."
  @spec ack(GenServer.server(), String.t()) :: :ok
  def ack(follower, cursor), do: GenServer.cast(follower, {:ack, cursor})

  @doc "The channel is up and the primary holds `cursor` (or nothing): resend the rest."
  @spec attach(GenServer.server(), String.t() | nil) :: :ok
  def attach(follower, cursor), do: GenServer.cast(follower, {:attach, cursor})

  @doc "The worker container has ended: drain the tail, then report `:log_drained`."
  @spec finish(GenServer.server()) :: :ok
  def finish(follower), do: GenServer.cast(follower, :finish)

  @doc "The cursor of the last frame taken from the log (`nil`: none yet)."
  @spec position(GenServer.server()) :: String.t() | nil
  def position(follower), do: GenServer.call(follower, :position)

  @spec stop(GenServer.server()) :: :ok
  def stop(follower) do
    GenServer.stop(follower, :normal)
  catch
    :exit, _ -> :ok
  end

  # -- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    state = %{
      run: Keyword.fetch!(opts, :run),
      pod: Keyword.fetch!(opts, :pod),
      client: Keyword.fetch!(opts, :client),
      owner: owner,
      emit: Keyword.get(opts, :emit, fn _frame -> :ok end),
      container: Keyword.get(opts, :container, "worker"),
      frame_bytes: Keyword.get(opts, :frame_bytes, @frame_bytes),
      window_bytes: Keyword.get(opts, :window_bytes, @window_bytes),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      position: Keyword.get(opts, :cursor),
      queue: :queue.new(),
      unacked: 0,
      waiting: nil,
      final?: false,
      drained?: false,
      reader: nil
    }

    {:ok, %{state | reader: start_reader(state)}}
  end

  @impl true
  def handle_call(:position, _from, state), do: {:reply, state.position, state}

  def handle_call(:resume_point, _from, state),
    do: {:reply, {state.position, state.final?}, state}

  # The reader hands over the lines of a chunk; it is answered when they are taken, which is
  # held back while the window is full.
  def handle_call({:lines, lines}, from, state) do
    state = %{state | waiting: {from, pack(lines, state.frame_bytes)}}
    {:noreply, release_reader(state)}
  end

  def handle_call(:drained, _from, state) do
    send(state.owner, {:log_drained, state.run, state.position})
    {:reply, :ok, %{state | drained?: true}}
  end

  @impl true
  def handle_cast({:ack, cursor}, state),
    do: {:noreply, state |> trim(cursor) |> release_reader()}

  def handle_cast({:attach, cursor}, state) do
    state = state |> trim(cursor) |> release_reader()
    for {_cursor, frame, _size} <- :queue.to_list(state.queue), do: state.emit.(frame)
    {:noreply, state}
  end

  # The worker has ended: whatever follow is open is cut (a stream that outlived its
  # container must not hold the exit back) and the tail is read from the position to EOF.
  # Frames of the cut reader that were not taken are read again from the position.
  def handle_cast(:finish, %{final?: true} = state), do: {:noreply, state}

  def handle_cast(:finish, state) do
    if is_pid(state.reader), do: Process.exit(state.reader, :kill)
    state = %{state | final?: true, waiting: nil}
    {:noreply, %{state | reader: if(state.drained?, do: nil, else: start_reader(state))}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, reader, :normal}, %{reader: reader} = state),
    do: {:noreply, %{state | reader: nil}}

  # A crashed reader is restarted at the position.
  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    Logger.warning("k8s log follower #{state.run}: reader crashed: #{inspect(reason, limit: 5)}")
    Process.send_after(self(), :restart_reader, state.retry_ms)
    {:noreply, %{state | reader: nil}}
  end

  def handle_info(:restart_reader, %{reader: nil, drained?: false} = state),
    do: {:noreply, %{state | reader: start_reader(state)}}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{reader: reader}) when is_pid(reader) do
    Process.exit(reader, :kill)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- frames ---------------------------------------------------------------------

  defp take(state, {cursor, bytes}) do
    frame = StdoutFrame.encode_cursor(state.run, cursor, bytes)
    state.emit.(frame)
    size = byte_size(bytes)

    %{
      state
      | position: cursor,
        queue: :queue.in({cursor, frame, size}, state.queue),
        unacked: state.unacked + size
    }
  end

  # Lines into `{cursor of the last line, bytes}` frames of at most `max` bytes (one longer
  # line is a frame of its own: the primary cuts lines itself).
  defp pack(lines, max) do
    lines
    |> Enum.reduce([], fn {cursor, text}, acc ->
      case acc do
        [{_, bytes} | rest] when byte_size(bytes) + byte_size(text) <= max ->
          [{cursor, bytes <> text} | rest]

        _ ->
          [{cursor, text} | acc]
      end
    end)
    |> Enum.reverse()
  end

  # Forget the frames up to and including the one named `cursor` (a cursor not in the queue,
  # or nil, forgets nothing).
  defp trim(state, nil), do: state

  defp trim(state, cursor) do
    items = :queue.to_list(state.queue)

    case Enum.find_index(items, fn {c, _, _} -> c == cursor end) do
      nil ->
        state

      index ->
        {gone, kept} = Enum.split(items, index + 1)
        freed = gone |> Enum.map(&elem(&1, 2)) |> Enum.sum()
        %{state | queue: :queue.from_list(kept), unacked: state.unacked - freed}
    end
  end

  # The reader's frames go out while the window has room; it is answered (and reads on) once
  # all of its batch has.
  defp release_reader(%{waiting: nil} = state), do: state

  defp release_reader(%{waiting: {from, []}} = state) do
    GenServer.reply(from, :ok)
    %{state | waiting: nil}
  end

  defp release_reader(%{waiting: {from, [frame | rest]}, unacked: unacked} = state)
       when unacked < state.window_bytes,
       do: release_reader(take(%{state | waiting: {from, rest}}, frame))

  defp release_reader(state), do: state

  # -- the reader -------------------------------------------------------------------

  defp start_reader(state) do
    follower = self()
    {client, pod} = {state.client, state.pod}
    opts = [container: state.container, retry_ms: state.retry_ms]
    spawn_link(fn -> read(follower, client, pod, opts) end)
  end

  defp read(follower, client, pod, opts) do
    {cursor, final?} = GenServer.call(follower, :resume_point, :infinity)

    log_opts = [
      container: opts[:container],
      timestamps: true,
      since_time: LogLines.since_time(cursor)
    ]

    case attempt(follower, client, pod, cursor, final?, log_opts) do
      :drained ->
        GenServer.call(follower, :drained, :infinity)

      :retry ->
        Process.sleep(opts[:retry_ms])
        read(follower, client, pod, opts)
    end
  end

  # The worker is gone: one read from the position to EOF, then the partial line.
  defp attempt(follower, client, pod, cursor, true, log_opts) do
    case Client.read_log(client, pod, log_opts) do
      {:ok, body} ->
        {reader, lines} = LogLines.feed(LogLines.new(cursor), body)
        hand_over(follower, lines ++ LogLines.flush(reader))
        :drained

      {:error, :not_found} ->
        :drained

      {:error, _} ->
        :retry
    end
  end

  defp attempt(follower, client, pod, cursor, false, log_opts) do
    fun = fn chunk, reader ->
      {reader, lines} = LogLines.feed(reader, chunk)
      hand_over(follower, lines)
      {:cont, reader}
    end

    _ = Client.follow_log(client, pod, LogLines.new(cursor), fun, log_opts)
    :retry
  end

  defp hand_over(_follower, []), do: :ok
  defp hand_over(follower, lines), do: GenServer.call(follower, {:lines, lines}, :infinity)
end
