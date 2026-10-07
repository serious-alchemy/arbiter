defmodule Arbiter.Nodes.Bridge.Core do
  @moduledoc """
  One end of the bridge multiplexer's protocol, with no IO
  (`docs/design/remote-workers.md` §4.2, §8): the stream table, the sender
  (`Arbiter.Nodes.Bridge.Mux`), and the receiver's accounting. The primary's
  `Arbiter.Nodes.Bridge` and the agent's `Arbiter.NodeAgent.Bridge` are the same
  protocol, so both drive one of these and carry out its **effects**:

      {:push, event, payload}      send on the node channel; `bridge.data` is `{:binary, frame}`
      {:stream, id, :write, bin}   write to the stream's local socket, then `local_wrote/3`
      {:stream, id, :rearm}        read the stream's local socket again
      {:stream, id, :shutdown_write}  the peer sent its last byte: half-close the local socket
      {:stream, id, :stop}         close the stream's local socket
      {:violation, reason}         the peer sent something that is not the protocol: drop the channel

  ## Events (both directions)

  | event | payload |
  |-------|---------|
  | `bridge.open` | `{run, name, stream}`, agent → primary; the caller authorizes it, then `open_remote/4` |
  | `bridge.data` | binary `Arbiter.Nodes.Bridge.Frame` |
  | `bridge.credit` | `{stream, n}`: `n` bytes of `stream` were **written to the peer's socket** |
  | `bridge.recv` | `{n}`: `n` bytes of frames were **received by the peer's transport**, on any stream |
  | `bridge.close` | `{stream}`: half close, the sender has no more bytes |
  | `bridge.reset` | `{stream, reason}`: the stream is gone; drop it |

  A stream is removed when both directions have closed, or on a reset from either
  end. Every frame received is acknowledged with `bridge.recv`, even one for a
  stream already gone, so the sender's node-wide in-flight count never leaks.
  """

  alias Arbiter.Nodes.Bridge.{Frame, Limits, Mux}

  defstruct [:limits, :mux, streams: %{}, runs: %{}, node_bytes: 0]

  @type t :: %__MODULE__{}
  @type effect :: tuple()

  @max_stream_id 0xFFFFFFFF

  @spec new(map()) :: t()
  def new(limits \\ %{}) do
    limits = Map.merge(Limits.defaults(), limits)

    %__MODULE__{
      limits: limits,
      mux:
        Mux.new(
          window: limits.window,
          frame: limits.frame,
          node_cap: limits.node_cap,
          max_stream_bytes: limits.max_stream_bytes
        )
    }
  end

  @spec stream?(t(), term()) :: boolean()
  def stream?(%__MODULE__{streams: streams}, id), do: Map.has_key?(streams, id)

  @spec stream_ids(t()) :: [non_neg_integer()]
  def stream_ids(%__MODULE__{streams: streams}), do: Map.keys(streams)

  @doc "The ids of the streams of `run`."
  @spec run_streams(t(), String.t()) :: [non_neg_integer()]
  def run_streams(%__MODULE__{streams: streams}, run),
    do: for({id, %{run: ^run}} <- streams, do: id)

  @doc "`{run, name}` of a stream."
  @spec target(t(), non_neg_integer()) :: {String.t(), String.t()} | nil
  def target(%__MODULE__{streams: streams}, id) do
    case streams do
      %{^id => %{run: run, name: name}} -> {run, name}
      _ -> nil
    end
  end

  @doc "Bytes on the link that the peer's transport has not yet received."
  @spec inflight(t()) :: non_neg_integer()
  def inflight(%__MODULE__{mux: mux}), do: Mux.inflight(mux)

  # ---- opening ------------------------------------------------------------

  @doc "This end opens a stream (an accepted local connection): registers it and announces it."
  @spec open_local(t(), term(), String.t(), String.t()) ::
          {:ok, t(), [effect()]} | {:error, atom()}
  def open_local(core, id, run, name) do
    with {:ok, core} <- register(core, id, run, name) do
      {:ok, core, [{:push, "bridge.open", %{"run" => run, "name" => name, "stream" => id}}]}
    end
  end

  @doc "The peer opened a stream (already authorized by the caller)."
  @spec open_remote(t(), term(), String.t(), String.t()) ::
          {:ok, t(), [effect()]} | {:error, atom()}
  def open_remote(core, id, run, name) do
    with {:ok, core} <- register(core, id, run, name), do: {:ok, core, []}
  end

  defp register(core, id, run, name) do
    %{limits: limits, streams: streams, runs: runs} = core

    cond do
      not (is_integer(id) and id in 1..@max_stream_id) -> {:error, :bad_stream}
      not (is_binary(run) and is_binary(name)) -> {:error, :bad_target}
      Map.has_key?(streams, id) -> {:error, :duplicate_stream}
      core.node_bytes >= limits.max_node_bytes -> {:error, :node_byte_cap}
      map_size(streams) >= limits.max_streams_per_node -> {:error, :node_stream_cap}
      Map.get(runs, run, 0) >= limits.max_streams_per_run -> {:error, :run_stream_cap}
      true -> {:ok, add_stream(core, id, run, name)}
    end
  end

  defp add_stream(core, id, run, name) do
    stream = %{
      run: run,
      name: name,
      rx_seq: 0,
      unwritten: 0,
      rx_total: 0,
      tx_done?: false,
      rx_done?: false
    }

    %{
      core
      | streams: Map.put(core.streams, id, stream),
        runs: Map.update(core.runs, run, 1, &(&1 + 1)),
        mux: Mux.open_stream(core.mux, id)
    }
  end

  # ---- local socket events -------------------------------------------------

  @doc "Bytes were read from the stream's local socket."
  @spec local_data(t(), non_neg_integer(), binary()) :: {t(), [effect()]}
  def local_data(%__MODULE__{} = core, id, bytes) do
    cond do
      not stream?(core, id) ->
        {core, []}

      core.node_bytes + byte_size(bytes) > core.limits.max_node_bytes ->
        reset(core, id, :node_byte_cap)

      true ->
        core = %{core | node_bytes: core.node_bytes + byte_size(bytes)}
        {mux, actions} = Mux.local_data(core.mux, id, bytes)
        apply_actions(%{core | mux: mux}, actions)
    end
  end

  @doc "The stream's local socket reached end of file."
  @spec local_eof(t(), non_neg_integer()) :: {t(), [effect()]}
  def local_eof(%__MODULE__{} = core, id) do
    {mux, actions} = Mux.local_closed(core.mux, id)
    apply_actions(%{core | mux: mux}, actions)
  end

  @doc "`n` bytes handed out as `{:stream, id, :write, _}` are now written to the local socket."
  @spec local_wrote(t(), non_neg_integer(), pos_integer()) :: {t(), [effect()]}
  def local_wrote(%__MODULE__{streams: streams} = core, id, n) do
    case streams do
      %{^id => s} ->
        s = %{s | unwritten: max(s.unwritten - n, 0)}
        {put(core, id, s), [{:push, "bridge.credit", %{"stream" => id, "n" => n}}]}

      _ ->
        {core, []}
    end
  end

  @doc "End the stream from this end: tell the peer, stop the local socket."
  @spec reset(t(), non_neg_integer(), atom()) :: {t(), [effect()]}
  def reset(%__MODULE__{} = core, id, reason) do
    if stream?(core, id) do
      {remove(core, id),
       [
         {:push, "bridge.reset", %{"stream" => id, "reason" => Atom.to_string(reason)}},
         {:stream, id, :stop}
       ]}
    else
      {core, []}
    end
  end

  # ---- events from the peer ------------------------------------------------

  @spec remote(t(), String.t(), term()) :: {t(), [effect()]}
  def remote(%__MODULE__{} = core, "bridge.data", {:binary, binary}) do
    case Frame.decode(binary) do
      {:ok, frame} -> received(core, frame)
      :error -> {core, [{:violation, :bad_frame}]}
    end
  end

  def remote(core, "bridge.data", _other), do: {core, [{:violation, :bad_frame}]}

  def remote(core, "bridge.credit", %{"stream" => id, "n" => n}) when is_integer(n) and n > 0 do
    {mux, actions} = Mux.credit(core.mux, id, n)
    apply_actions(%{core | mux: mux}, actions)
  end

  def remote(core, "bridge.recv", %{"n" => n}) when is_integer(n) and n > 0 do
    {mux, actions} = Mux.received(core.mux, n)
    apply_actions(%{core | mux: mux}, actions)
  end

  def remote(%__MODULE__{streams: streams} = core, "bridge.close", %{"stream" => id}) do
    case streams do
      %{^id => %{rx_done?: false} = s} ->
        finish(put(core, id, %{s | rx_done?: true}), id, [{:stream, id, :shutdown_write}])

      _ ->
        {core, []}
    end
  end

  def remote(core, "bridge.reset", %{"stream" => id}) do
    if stream?(core, id),
      do: {remove(core, id), [{:stream, id, :stop}]},
      else: {core, []}
  end

  def remote(core, _event, _payload), do: {core, []}

  # Every frame is acknowledged to the sender's transport first: the node-wide
  # in-flight count must fall whatever becomes of the bytes.
  defp received(core, %{seq: seq, stream: id, bytes: bytes}) do
    n = byte_size(bytes)
    recv = {:push, "bridge.recv", %{"n" => n}}

    case core.streams do
      %{^id => s} ->
        case check(core, s, seq, n) do
          :ok ->
            s = %{s | rx_seq: seq + 1, unwritten: s.unwritten + n, rx_total: s.rx_total + n}
            core = %{put(core, id, s) | node_bytes: core.node_bytes + n}
            {core, [recv, {:stream, id, :write, bytes}]}

          {:error, reason} ->
            {core, effects} = reset(core, id, reason)
            {core, [recv | effects]}
        end

      _ ->
        {core, [recv]}
    end
  end

  defp check(core, s, seq, n) do
    limits = core.limits

    cond do
      s.rx_done? -> {:error, :data_after_close}
      n > limits.frame -> {:error, :frame_too_large}
      seq != s.rx_seq -> {:error, :bad_sequence}
      s.unwritten + n > limits.window -> {:error, :window_exceeded}
      s.rx_total + n > limits.max_stream_bytes -> {:error, :stream_byte_cap}
      core.node_bytes + n > limits.max_node_bytes -> {:error, :node_byte_cap}
      true -> :ok
    end
  end

  # ---- plumbing -------------------------------------------------------------

  defp put(core, id, s), do: %{core | streams: Map.put(core.streams, id, s)}

  defp remove(core, id) do
    case core.streams do
      %{^id => %{run: run}} ->
        runs =
          case Map.get(core.runs, run, 1) do
            n when n <= 1 -> Map.delete(core.runs, run)
            n -> Map.put(core.runs, run, n - 1)
          end

        %{core | streams: Map.delete(core.streams, id), runs: runs, mux: Mux.drop_stream(core.mux, id)}

      _ ->
        core
    end
  end

  defp apply_actions(core, actions) do
    Enum.reduce(actions, {core, []}, fn action, {core, effects} ->
      {core, new} = apply_action(core, action)
      {core, effects ++ new}
    end)
  end

  defp apply_action(core, {:frame, _id, frame}), do: {core, [{:push, "bridge.data", {:binary, frame}}]}
  defp apply_action(core, {:rearm, id}), do: {core, [{:stream, id, :rearm}]}

  defp apply_action(core, {:close, id}) do
    case core.streams do
      %{^id => s} ->
        finish(put(core, id, %{s | tx_done?: true}), id, [{:push, "bridge.close", %{"stream" => id}}])

      _ ->
        {core, []}
    end
  end

  # The Mux dropped it already (a byte cap): tell the peer, stop the socket.
  defp apply_action(core, {:reset, id, reason}) do
    {remove(core, id),
     [
       {:push, "bridge.reset", %{"stream" => id, "reason" => Atom.to_string(reason)}},
       {:stream, id, :stop}
     ]}
  end

  # Closed in both directions: nothing more can be said on it.
  defp finish(core, id, effects) do
    case core.streams do
      %{^id => %{tx_done?: true, rx_done?: true}} -> {remove(core, id), effects ++ [{:stream, id, :stop}]}
      _ -> {core, effects}
    end
  end
end
