defmodule ArbiterWeb.Spike.Mux do
  @moduledoc """
  RW2 spike (bd-6tx1xv, remote-workers design §4.2/§8): the **sender half** of
  the credit-windowed bridge multiplexer — pure state, no IO. **Prototype, not
  product code.**

  Each side of the tunnel owns one `Mux` for the bytes it *reads from a local
  socket and sends over the channel*. Limits are the design's numbers: 256 KiB
  credit window per stream, 16 KiB frames, 1 MiB in flight per node. The
  receiving side returns credit (`bridge.credit`) only after it has written
  the bytes to its own local socket, which is what makes the window real
  backpressure rather than a counter.

  `local_data/3`, `credit/3` and `local_closed/2` return `{mux, actions}`:

    * `{:frame, stream, binary}` — send as a `bridge.data` binary push
    * `{:rearm, stream}` — the buffer drained; resume reading the local socket
    * `{:close, stream}` — send `bridge.close`, buffer is empty
  """

  defstruct streams: %{}, inflight: 0, window: 262_144, frame: 16_384, node_cap: 1_048_576

  def new(opts \\ []), do: struct!(__MODULE__, opts)

  def open_stream(%__MODULE__{} = mux, id) do
    stream = %{
      credit: mux.window,
      buf: :queue.new(),
      buf_size: 0,
      seq: 0,
      closing?: false,
      done?: false
    }

    %{mux | streams: Map.put(mux.streams, id, stream)}
  end

  def drop_stream(%__MODULE__{} = mux, id) do
    case Map.pop(mux.streams, id) do
      {nil, _} -> mux
      {_stream, streams} -> %{mux | streams: streams}
    end
  end

  def local_data(%__MODULE__{} = mux, id, data) do
    mux
    |> update_stream(id, fn s ->
      %{s | buf: :queue.in(data, s.buf), buf_size: s.buf_size + byte_size(data)}
    end)
    |> drain(id)
  end

  def local_closed(%__MODULE__{} = mux, id) do
    mux |> update_stream(id, &%{&1 | closing?: true}) |> drain(id)
  end

  @doc "The peer wrote `n` bytes of ours to its socket: replenish and drain every stream."
  def credit(%__MODULE__{} = mux, id, n) do
    mux = %{mux | inflight: max(mux.inflight - n, 0)}
    mux = update_stream(mux, id, &%{&1 | credit: &1.credit + n})

    mux.streams
    |> Map.keys()
    |> Enum.sort_by(&(&1 == id), :desc)
    |> Enum.reduce({mux, []}, fn sid, {mux, acc} ->
      {mux, actions} = drain(mux, sid)
      {mux, acc ++ actions}
    end)
  end

  def buffered(%__MODULE__{streams: streams}),
    do: streams |> Map.values() |> Enum.map(& &1.buf_size) |> Enum.sum()

  defp update_stream(mux, id, fun) do
    case mux.streams do
      %{^id => s} -> %{mux | streams: Map.put(mux.streams, id, fun.(s))}
      _ -> mux
    end
  end

  defp drain(%__MODULE__{streams: streams} = mux, id) do
    case streams do
      %{^id => s} -> drain_stream(mux, id, s, [])
      _ -> {mux, []}
    end
  end

  defp drain_stream(mux, id, s, acc) do
    allowed = min(min(s.credit, mux.node_cap - mux.inflight), mux.frame)

    cond do
      s.done? ->
        {put(mux, id, s), Enum.reverse(acc)}

      s.buf_size == 0 and s.closing? ->
        {put(mux, id, %{s | done?: true}), Enum.reverse([{:close, id} | acc])}

      s.buf_size == 0 ->
        {put(mux, id, s), Enum.reverse([{:rearm, id} | acc])}

      allowed <= 0 ->
        {put(mux, id, s), Enum.reverse(acc)}

      true ->
        {chunk, rest} = take(s.buf, min(allowed, s.buf_size))
        size = byte_size(chunk)
        frame = <<"ARB1", s.seq::unsigned-64, id::unsigned-32, chunk::binary>>

        s = %{s | buf: rest, buf_size: s.buf_size - size, credit: s.credit - size, seq: s.seq + 1}
        mux = %{mux | inflight: mux.inflight + size}
        drain_stream(mux, id, s, [{:frame, id, frame} | acc])
    end
  end

  defp put(mux, id, s), do: %{mux | streams: Map.put(mux.streams, id, s)}

  # Pull up to `n` bytes off the queue as one binary (may split the head chunk).
  defp take(q, n), do: take(q, n, [])

  defp take(q, 0, acc), do: {IO.iodata_to_binary(Enum.reverse(acc)), q}

  defp take(q, n, acc) do
    case :queue.out(q) do
      {{:value, bin}, rest} when byte_size(bin) <= n ->
        take(rest, n - byte_size(bin), [bin | acc])

      {{:value, bin}, rest} ->
        <<head::binary-size(n), tail::binary>> = bin
        {IO.iodata_to_binary(Enum.reverse([head | acc])), :queue.in_r(tail, rest)}

      {:empty, rest} ->
        {IO.iodata_to_binary(Enum.reverse(acc)), rest}
    end
  end
end
