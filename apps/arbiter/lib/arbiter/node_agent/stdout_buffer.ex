defmodule Arbiter.NodeAgent.StdoutBuffer do
  @moduledoc """
  The agent's per-run stdout ring (`docs/design/remote-workers.md` §4.2, §7.6):
  an offset-addressed buffer that keeps every byte the primary has not
  acknowledged, so a channel blip loses nothing.

    * `append/2` assigns the next offset and keeps the bytes;
    * `ack/2` drops everything up to a cumulative offset (an ack never moves
      backwards, and one past the end is clamped);
    * `from/2` returns what is still retained from an offset: all of it after a
      blip (the primary's ack is the last it sent, and it drops what it already
      has);
    * a buffer that would exceed `cap` unacknowledged bytes is `{:error,
      :overflow}`: bytes are never silently discarded. The owner treats that as
      a stalled primary and stops the run, which is also what the fence does at
      60 s.

  Pure. The bytes are opaque (stream-json lines, never decoded here).
  """

  defstruct chunks: :queue.new(), base: 0, size: 0, cap: 64 * 1024 * 1024

  @type t :: %__MODULE__{}

  @spec new(pos_integer()) :: t()
  def new(cap \\ 64 * 1024 * 1024), do: %__MODULE__{cap: cap}

  @doc "Total bytes ever appended: the next offset."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc "The highest acknowledged offset (everything before it is gone)."
  @spec acked(t()) :: non_neg_integer()
  def acked(%__MODULE__{base: base}), do: base

  @doc "Bytes held and not yet acknowledged."
  @spec pending(t()) :: non_neg_integer()
  def pending(%__MODULE__{base: base, size: size}), do: size - base

  @spec append(t(), binary()) :: {:ok, t(), non_neg_integer()} | {:error, :overflow}
  def append(%__MODULE__{} = buf, bytes) when is_binary(bytes) do
    if pending(buf) + byte_size(bytes) > buf.cap do
      {:error, :overflow}
    else
      {:ok,
       %{
         buf
         | chunks: :queue.in({buf.size, bytes}, buf.chunks),
           size: buf.size + byte_size(bytes)
       }, buf.size}
    end
  end

  @spec ack(t(), non_neg_integer()) :: t()
  def ack(%__MODULE__{} = buf, offset) when is_integer(offset) do
    offset = offset |> max(buf.base) |> min(buf.size)
    %{buf | chunks: drop_before(buf.chunks, offset), base: offset}
  end

  @doc "The retained bytes from `offset`, as `{offset, bytes}` chunks in order."
  @spec from(t(), non_neg_integer()) :: {:ok, [{non_neg_integer(), binary()}]} | {:error, :gone}
  def from(%__MODULE__{base: base}, offset) when offset < base, do: {:error, :gone}

  def from(%__MODULE__{} = buf, offset) do
    chunks =
      for {start, bytes} <- :queue.to_list(buf.chunks), start + byte_size(bytes) > offset do
        if start >= offset do
          {start, bytes}
        else
          skip = offset - start
          {offset, binary_part(bytes, skip, byte_size(bytes) - skip)}
        end
      end

    {:ok, chunks}
  end

  defp drop_before(queue, offset) do
    case :queue.out(queue) do
      {{:value, {start, bytes}}, rest} ->
        stop = start + byte_size(bytes)

        cond do
          stop <= offset ->
            drop_before(rest, offset)

          start >= offset ->
            queue

          true ->
            skip = offset - start
            :queue.in_r({offset, binary_part(bytes, skip, byte_size(bytes) - skip)}, rest)
        end

      {:empty, _} ->
        queue
    end
  end
end
