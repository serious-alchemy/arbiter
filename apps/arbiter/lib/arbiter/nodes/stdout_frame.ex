defmodule Arbiter.Nodes.StdoutFrame do
  @moduledoc """
  The binary frame a node pushes as `stdout` (`docs/design/remote-workers.md`
  §4.2): the existing `ARB1` header idea (`Arbiter.Sessions.Frame`) scoped to a
  run.

      <<"ARB1", offset::unsigned-big-64, id_size::8, run_id::binary-size(id_size), bytes::binary>>

  `offset` is the byte offset **of the first byte in the frame** within the
  run's stdout stream, so the receiver can tell a replay from new data and a gap
  from neither: it keeps the next offset it expects, drops the part of a frame
  it already has, and treats a frame that starts beyond that as a gap (it asks
  for a resend by not acking). The bytes are never decoded or validated here.
  """

  @magic "ARB1"

  @doc "Frame `bytes` that start at `offset` of run `run_id`'s stdout."
  @spec encode(String.t(), non_neg_integer(), iodata()) :: binary()
  def encode(run_id, offset, bytes)
      when is_binary(run_id) and byte_size(run_id) in 1..255 and is_integer(offset) and
             offset >= 0 do
    <<@magic, offset::unsigned-big-64, byte_size(run_id)::8, run_id::binary,
      IO.iodata_to_binary(bytes)::binary>>
  end

  @doc "Split a frame into `{:ok, run_id, offset, bytes}`."
  @spec decode(term()) :: {:ok, String.t(), non_neg_integer(), binary()} | {:error, :bad_frame}
  def decode(
        <<@magic, offset::unsigned-big-64, size::8, run_id::binary-size(size), bytes::binary>>
      )
      when size > 0,
      do: {:ok, run_id, offset, bytes}

  def decode(_), do: {:error, :bad_frame}
end
