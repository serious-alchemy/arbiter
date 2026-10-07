defmodule Arbiter.Nodes.Bridge.Frame do
  @moduledoc """
  The binary `bridge.data` frame (`docs/design/remote-workers.md` §4.2, §8):
  the `ARB1` magic, a per-stream sequence number, the stream id, then the bytes.

      <<"ARB1", seq::unsigned-64, stream::unsigned-32, bytes::binary>>

  A frame with no bytes is not a frame: a sender never makes one, and a peer
  that sends one is not following the protocol.
  """

  @magic "ARB1"

  @type t :: %{seq: non_neg_integer(), stream: non_neg_integer(), bytes: binary()}

  @spec encode(non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def encode(seq, stream, bytes) when is_binary(bytes),
    do: <<@magic, seq::unsigned-64, stream::unsigned-32, bytes::binary>>

  @spec decode(term()) :: {:ok, t()} | :error
  def decode(<<@magic, seq::unsigned-64, stream::unsigned-32, bytes::binary>>)
      when byte_size(bytes) > 0,
      do: {:ok, %{seq: seq, stream: stream, bytes: bytes}}

  def decode(_other), do: :error

  @spec decode!(binary()) :: t()
  def decode!(binary) do
    {:ok, frame} = decode(binary)
    frame
  end
end
