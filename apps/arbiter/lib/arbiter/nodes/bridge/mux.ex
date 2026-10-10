defmodule Arbiter.Nodes.Bridge.Mux do
  @moduledoc """
  The **sender half** of the bridge multiplexer (`docs/design/remote-workers.md`
  §4.2, §8): pure state, no IO. Each end of the tunnel owns one for the bytes it
  reads from a local socket and sends over the node channel.

  Two limits bound what is in flight, and they are released by **different**
  acknowledgements, which is what keeps a slow consumer local:

    * **The stream window** (`:window`, 256 KiB) bounds the bytes a stream has
      sent that the peer has not yet *written to its own socket*. The peer's
      `bridge.credit` returns it (`credit/3`). A stream whose consumer is slow
      runs out of window and stops reading its own local socket (no `:rearm`),
      so the producer is pushed back on, and nothing else moves.
    * **The node cap** (`:node_cap`, 256 KiB, RW2/U4) bounds the bytes sent that
      the peer's *transport* has not yet received: what is queued on the link, and
      so what a heartbeat waits behind. The peer's `bridge.recv` returns it
      (`received/2`), as soon as a frame arrives and *before* its consumer
      writes it. A stalled consumer therefore never holds the node cap, and one
      stream cannot starve the heartbeat or any other run.

  Streams with data are served round-robin, one frame (`:frame`, 16 KiB) per
  turn, so a bulk push cannot starve the others when the node cap is small.
  `:max_stream_bytes` caps what one stream may send over its life.

  Calls return `{mux, actions}`:

    * `{:frame, stream, binary}`: send as a `bridge.data` binary push
    * `{:rearm, stream}`: the buffer drained; read the local socket again
    * `{:close, stream}`: send `bridge.close` (the buffer is on the wire)
    * `{:reset, stream, reason}`: send `bridge.reset`; the stream is gone
  """

  alias Arbiter.Nodes.Bridge.Frame

  defstruct streams: %{},
            ready: :queue.new(),
            inflight: 0,
            window: 262_144,
            frame: 16_384,
            node_cap: 262_144,
            max_stream_bytes: 1_073_741_824

  @type t :: %__MODULE__{}
  @type action ::
          {:frame, non_neg_integer(), binary()}
          | {:rearm, non_neg_integer()}
          | {:close, non_neg_integer()}
          | {:reset, non_neg_integer(), atom()}

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @doc "Register a stream. It starts armed: its local socket is being read."
  @spec open_stream(t(), non_neg_integer()) :: t()
  def open_stream(%__MODULE__{} = mux, id) do
    stream = %{
      credit: mux.window,
      buf: :queue.new(),
      buf_size: 0,
      seq: 0,
      total: 0,
      queued?: false,
      armed?: true,
      closing?: false,
      done?: false
    }

    %{mux | streams: Map.put(mux.streams, id, stream)}
  end

  @doc "Forget a stream and whatever it had buffered."
  @spec drop_stream(t(), non_neg_integer()) :: t()
  def drop_stream(%__MODULE__{} = mux, id), do: %{mux | streams: Map.delete(mux.streams, id)}

  @spec local_data(t(), non_neg_integer(), binary()) :: {t(), [action()]}
  def local_data(%__MODULE__{streams: streams} = mux, id, data) when is_binary(data) do
    case streams do
      %{^id => s} when s.total + byte_size(data) > mux.max_stream_bytes ->
        {drop_stream(mux, id), [{:reset, id, :stream_byte_cap}]}

      %{^id => s} ->
        s = %{
          s
          | buf: :queue.in(data, s.buf),
            buf_size: s.buf_size + byte_size(data),
            total: s.total + byte_size(data),
            armed?: false
        }

        mux |> put(id, s) |> enqueue(id) |> pump()

      _ ->
        {mux, []}
    end
  end

  @doc "The local socket reached end of file: close once the buffer is on the wire."
  @spec local_closed(t(), non_neg_integer()) :: {t(), [action()]}
  def local_closed(%__MODULE__{streams: streams} = mux, id) do
    case streams do
      %{^id => %{done?: false} = s} ->
        mux |> put(id, %{s | closing?: true}) |> enqueue(id) |> pump()

      _ ->
        {mux, []}
    end
  end

  @doc "The peer wrote `n` bytes of stream `id` to its socket: the window reopens."
  @spec credit(t(), non_neg_integer(), pos_integer()) :: {t(), [action()]}
  def credit(%__MODULE__{streams: streams} = mux, id, n) do
    case streams do
      %{^id => s} ->
        s = %{s | credit: min(s.credit + n, mux.window)}
        mux |> put(id, s) |> enqueue(id) |> pump()

      _ ->
        {mux, []}
    end
  end

  @doc "The peer's transport received `n` bytes: the node-wide in-flight count drops."
  @spec received(t(), non_neg_integer()) :: {t(), [action()]}
  def received(%__MODULE__{} = mux, n), do: pump(%{mux | inflight: max(mux.inflight - n, 0)})

  @doc "Bytes read from local sockets and not yet sent."
  @spec buffered(t()) :: non_neg_integer()
  def buffered(%__MODULE__{streams: streams}),
    do: streams |> Map.values() |> Enum.map(& &1.buf_size) |> Enum.sum()

  @doc "Bytes sent over the link that the peer's transport has not yet received."
  @spec inflight(t()) :: non_neg_integer()
  def inflight(%__MODULE__{inflight: n}), do: n

  # ---- scheduling ---------------------------------------------------------

  defp put(mux, id, s), do: %{mux | streams: Map.put(mux.streams, id, s)}

  # A stream wants the link when it has bytes to send or a close to announce.
  defp enqueue(mux, id) do
    case mux.streams do
      %{^id => %{queued?: false, done?: false} = s} when s.buf_size > 0 or s.closing? ->
        %{put(mux, id, %{s | queued?: true}) | ready: :queue.in(id, mux.ready)}

      _ ->
        mux
    end
  end

  defp pump(mux), do: pump(mux, [])

  defp pump(mux, acc) do
    case :queue.out(mux.ready) do
      {:empty, _} ->
        {mux, Enum.reverse(acc)}

      {{:value, id}, rest} ->
        mux = %{mux | ready: rest}

        case mux.streams do
          %{^id => s} -> turn(mux, id, %{s | queued?: false}, acc)
          # dropped while queued
          _ -> pump(mux, acc)
        end
    end
  end

  # One stream's turn: finish it, park it, or send one frame and go to the back.
  defp turn(mux, id, %{buf_size: 0} = s, acc), do: finish(mux, id, s, acc)

  defp turn(mux, id, %{credit: credit} = s, acc) when credit <= 0,
    # Out of window: parked until its peer credits. Others are not held up.
    do: pump(put(mux, id, s), acc)

  defp turn(mux, id, s, acc) do
    room = mux.node_cap - mux.inflight

    if room <= 0 do
      # The link is full. Keep the turn order: this stream is still first.
      mux = put(mux, id, %{s | queued?: true})
      {%{mux | ready: :queue.in_r(id, mux.ready)}, Enum.reverse(acc)}
    else
      size = Enum.min([s.credit, room, mux.frame, s.buf_size])
      {chunk, buf} = take(s.buf, size)
      frame = Frame.encode(s.seq, id, chunk)

      s = %{s | buf: buf, buf_size: s.buf_size - size, credit: s.credit - size, seq: s.seq + 1}
      mux = %{mux | inflight: mux.inflight + size}
      acc = [{:frame, id, frame} | acc]

      if s.buf_size > 0 do
        mux = put(mux, id, %{s | queued?: true})
        pump(%{mux | ready: :queue.in(id, mux.ready)}, acc)
      else
        {mux, acc} = finish_acc(mux, id, s, acc)
        pump(mux, acc)
      end
    end
  end

  defp finish(mux, id, s, acc) do
    {mux, acc} = finish_acc(mux, id, s, acc)
    pump(mux, acc)
  end

  # Buffer empty: announce a pending close, else read the local socket again.
  defp finish_acc(mux, id, %{closing?: true, done?: false} = s, acc),
    do: {put(mux, id, %{s | done?: true}), [{:close, id} | acc]}

  defp finish_acc(mux, id, %{armed?: false, closing?: false} = s, acc),
    do: {put(mux, id, %{s | armed?: true}), [{:rearm, id} | acc]}

  defp finish_acc(mux, id, s, acc), do: {put(mux, id, s), acc}

  # Pull exactly `n` bytes off the queue as one binary (may split the head chunk).
  defp take(q, n), do: take(q, n, [])

  defp take(q, 0, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), q}

  defp take(q, n, acc) do
    case :queue.out(q) do
      {{:value, bin}, rest} when byte_size(bin) <= n ->
        take(rest, n - byte_size(bin), [bin | acc])

      {{:value, bin}, rest} ->
        <<head::binary-size(^n), tail::binary>> = bin
        {IO.iodata_to_binary(Enum.reverse([head | acc])), :queue.in_r(tail, rest)}
    end
  end
end
