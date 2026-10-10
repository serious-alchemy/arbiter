defmodule Arbiter.NodeAgent.PodChannel.BootBundle.Tar do
  @moduledoc """
  A minimal ustar writer, in memory. `:erl_tar` writes through a file or a
  user-supplied handle; this needs neither, so a `/boot` response (which
  carries private keys and provider tokens) is assembled without a byte of it
  touching the controller's disk.

  Entries are `{name, body, mode}`: regular files only, names of at most 100
  bytes, relative, with no `..`. Anything else raises: a name that could escape
  the pod's extraction root must not be encodable.
  """

  @block 512

  @spec encode([{String.t(), binary(), non_neg_integer()}]) :: binary()
  def encode(entries) do
    body = for {name, data, mode} <- entries, into: <<>>, do: file(name, data, mode)
    # two zero blocks end the archive
    body <> <<0::size(2 * @block * 8)>>
  end

  defp file(name, data, mode) do
    check_name!(name)
    header(name, byte_size(data), mode) <> data <> padding(byte_size(data))
  end

  defp check_name!(name) do
    segments = String.split(name, "/")

    if name == "" or byte_size(name) > 100 or String.starts_with?(name, "/") or
         String.contains?(name, <<0>>) or Enum.any?(segments, &(&1 in ["", ".", ".."])) do
      raise ArgumentError, "tar entry name not allowed: #{inspect(name)}"
    end
  end

  defp header(name, size, mode) do
    fields =
      [
        pad(name, 100),
        octal(mode, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12)
      ]

    rest = [
      "0",
      pad("", 100),
      "ustar\0",
      "00",
      pad("", 32),
      pad("", 32),
      octal(0, 8),
      octal(0, 8),
      pad("", 155)
    ]

    blank = IO.iodata_to_binary(fields ++ ["        "] ++ rest)
    sum = for <<byte <- blank>>, reduce: 0, do: (acc -> acc + byte)

    <<before::binary-size(148), _::binary-size(8), tail::binary>> = blank
    block = before <> checksum(sum) <> tail
    block <> <<0::size((@block - byte_size(block)) * 8)>>
  end

  defp checksum(sum), do: String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, ?\s>>

  # `width - 1` octal digits and a NUL
  defp octal(value, width),
    do: String.pad_leading(Integer.to_string(value, 8), width - 1, "0") <> <<0>>

  defp pad(value, width), do: value <> <<0::size((width - byte_size(value)) * 8)>>

  defp padding(size) do
    case rem(size, @block) do
      0 -> <<>>
      r -> <<0::size((@block - r) * 8)>>
    end
  end
end
