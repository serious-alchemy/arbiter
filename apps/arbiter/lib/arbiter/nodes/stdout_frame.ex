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

  ## Opaque cursors (A4)

  A backend whose stream has no byte offsets (the Kubernetes controller follows
  `pods/log`, resumed by an RFC 3339 nano timestamp) sends an `ARB2` frame instead:

      <<"ARB2", cursor_size::unsigned-big-16, cursor::binary-size(cursor_size),
        id_size::8, run_id::binary-size(id_size), bytes::binary>>

  `cursor` is an opaque string naming the resume point *after* the frame's bytes. The
  receiver stores it and echoes it in the `ack`; it never parses it.
  """

  @magic "ARB1"
  @cursor_magic "ARB2"

  @doc "Frame `bytes` that start at `offset` of run `run_id`'s stdout."
  @spec encode(String.t(), non_neg_integer(), iodata()) :: binary()
  def encode(run_id, offset, bytes)
      when is_binary(run_id) and byte_size(run_id) in 1..255 and is_integer(offset) and
             offset >= 0 do
    <<@magic, offset::unsigned-big-64, byte_size(run_id)::8, run_id::binary,
      IO.iodata_to_binary(bytes)::binary>>
  end

  @doc "Frame `bytes` whose resume point is the opaque `cursor` (A4, `ARB2`)."
  @spec encode_cursor(String.t(), binary(), iodata()) :: binary()
  def encode_cursor(run_id, cursor, bytes)
      when is_binary(run_id) and byte_size(run_id) in 1..255 and is_binary(cursor) and
             byte_size(cursor) <= 0xFFFF do
    <<@cursor_magic, byte_size(cursor)::unsigned-big-16, cursor::binary, byte_size(run_id)::8,
      run_id::binary, IO.iodata_to_binary(bytes)::binary>>
  end

  @doc """
  Split a frame into `{:ok, run_id, position, bytes}`: `position` is the integer offset of
  an `ARB1` frame, or `{:cursor, string}` for an `ARB2` one.
  """
  @spec decode(term()) ::
          {:ok, String.t(), non_neg_integer() | {:cursor, binary()}, binary()}
          | {:error, :bad_frame}
  def decode(
        <<@magic, offset::unsigned-big-64, size::8, run_id::binary-size(size), bytes::binary>>
      )
      when size > 0,
      do: {:ok, run_id, offset, bytes}

  def decode(
        <<@cursor_magic, csize::unsigned-big-16, cursor::binary-size(csize), size::8,
          run_id::binary-size(size), bytes::binary>>
      )
      when size > 0,
      do: {:ok, run_id, {:cursor, cursor}, bytes}

  def decode(_), do: {:error, :bad_frame}
end
