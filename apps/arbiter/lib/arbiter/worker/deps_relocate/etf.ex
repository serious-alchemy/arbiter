defmodule Arbiter.Worker.DepsRelocate.Etf do
  @moduledoc """
  Rewrite the directory a Mix manifest records, in the manifest's bytes
  (`Arbiter.Worker.DepsRelocate`, SI5).

  A `_build/<env>/lib/<dep>/.mix/compile.elixir` manifest is an Erlang external term. It
  holds the dependency's module names, so decoding it with `:safe` (which refuses any
  atom the VM has not seen) refuses nearly every real manifest, and a relocation that
  decodes with `:safe` then silently does nothing: Mix finds the dependency stale and
  rebuilds it. An unsafe decode would let a file that came out of a container create
  atoms without bound.

  This module does neither. It walks the term format, copies every byte it does not
  change (atoms included, as bytes) and rewrites only a binary that is `from` or under
  it, fixing that binary's own length prefix; containers carry element counts, never
  byte lengths, so nothing else moves. It creates no atom and no term.

  `rewrite/3` is `{:ok, binary}` when a binary was rewritten, `:unchanged` when none
  matched, and `:error` for anything it cannot walk (a tag a manifest does not hold, a
  truncated term, an oversized inflate): the caller leaves the file alone, which costs
  a rebuild and never builds something wrong.

  A single self-contained file with no dependency on the rest of Arbiter: the pod's
  `seed-layer` script runs it as `elixir -r etf.ex -r deps_relocate.ex`.
  """

  # A manifest is a few hundred KB; this is a bound on what a hostile file may inflate to.
  @max_inflated 256 * 1024 * 1024

  @spec rewrite(binary(), String.t(), String.t()) :: {:ok, binary()} | :unchanged | :error
  def rewrite(<<131, 80, size::32, zdata::binary>>, from, to) when size <= @max_inflated do
    with {:ok, body} <- inflate(zdata, size),
         {:ok, iodata, <<>>, true} <- walk(body, from, to) do
      out = IO.iodata_to_binary(iodata)
      {:ok, <<131, 80, byte_size(out)::32, :zlib.compress(out)::binary>>}
    else
      {:ok, _iodata, <<>>, false} -> :unchanged
      _ -> :error
    end
  end

  def rewrite(<<131, 80, _::binary>>, _from, _to), do: :error

  def rewrite(<<131, body::binary>>, from, to) do
    case walk(body, from, to) do
      {:ok, iodata, <<>>, true} -> {:ok, IO.iodata_to_binary([131, iodata])}
      {:ok, _iodata, <<>>, false} -> :unchanged
      _ -> :error
    end
  end

  def rewrite(_other, _from, _to), do: :error

  # -- bounded inflate -----------------------------------------------------------------------

  defp inflate(data, size) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      inflate_loop(z, :zlib.safeInflate(z, data), [], 0, size)
    rescue
      _ -> :error
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, chunk}, acc, total, size) do
    total = total + IO.iodata_length(chunk)
    acc = [acc, chunk]

    cond do
      total > size ->
        :error

      state == :continue ->
        inflate_loop(z, :zlib.safeInflate(z, []), acc, total, size)

      total == size ->
        {:ok, IO.iodata_to_binary(acc)}

      true ->
        :error
    end
  end

  # -- the walk: {:ok, iodata, rest, changed?} -------------------------------------------------

  # A binary: the only thing rewritten.
  defp walk(<<109, len::32, data::binary-size(len), rest::binary>>, from, to) do
    if under?(data, from) do
      moved = to <> binary_part(data, byte_size(from), len - byte_size(from))
      {:ok, [<<109, byte_size(moved)::32>>, moved], rest, true}
    else
      {:ok, [<<109, len::32>>, data], rest, false}
    end
  end

  # Tuples, lists and maps: counts, then that many terms.
  defp walk(<<104, n::8, rest::binary>>, from, to), do: group(<<104, n::8>>, n, rest, from, to)
  defp walk(<<105, n::32, rest::binary>>, from, to), do: group(<<105, n::32>>, n, rest, from, to)

  defp walk(<<116, n::32, rest::binary>>, from, to),
    do: group(<<116, n::32>>, 2 * n, rest, from, to)

  defp walk(<<108, n::32, rest::binary>>, from, to),
    do: group(<<108, n::32>>, n + 1, rest, from, to)

  # Fixed-size and length-prefixed leaves, copied as they are.
  defp walk(<<106, rest::binary>>, _from, _to), do: {:ok, [106], rest, false}
  defp walk(<<97, v::binary-size(1), rest::binary>>, _f, _t), do: {:ok, [97, v], rest, false}
  defp walk(<<98, v::binary-size(4), rest::binary>>, _f, _t), do: {:ok, [98, v], rest, false}
  defp walk(<<70, v::binary-size(8), rest::binary>>, _f, _t), do: {:ok, [70, v], rest, false}
  defp walk(<<99, v::binary-size(31), rest::binary>>, _f, _t), do: {:ok, [99, v], rest, false}

  defp walk(<<tag, len::16, v::binary-size(len), rest::binary>>, _f, _t)
       when tag in [100, 107, 118],
       do: {:ok, [<<tag, len::16>>, v], rest, false}

  defp walk(<<tag, len::8, v::binary-size(len), rest::binary>>, _f, _t) when tag in [115, 119],
    do: {:ok, [<<tag, len::8>>, v], rest, false}

  defp walk(<<110, n::8, sign::8, v::binary-size(n), rest::binary>>, _f, _t),
    do: {:ok, [<<110, n::8, sign::8>>, v], rest, false}

  defp walk(<<111, n::32, sign::8, v::binary-size(n), rest::binary>>, _f, _t),
    do: {:ok, [<<111, n::32, sign::8>>, v], rest, false}

  defp walk(<<77, len::32, bits::8, v::binary-size(len), rest::binary>>, _f, _t),
    do: {:ok, [<<77, len::32, bits::8>>, v], rest, false}

  # Anything else (a pid, a reference, a fun) is not in a manifest.
  defp walk(_other, _from, _to), do: :error

  defp group(head, count, rest, from, to), do: group(head, count, rest, from, to, [], false)

  defp group(head, 0, rest, _from, _to, acc, changed),
    do: {:ok, [head | Enum.reverse(acc)], rest, changed}

  defp group(head, count, rest, from, to, acc, changed) do
    case walk(rest, from, to) do
      {:ok, iodata, rest, was_changed} ->
        group(head, count - 1, rest, from, to, [iodata | acc], changed or was_changed)

      :error ->
        :error
    end
  end

  defp under?(dir, from), do: dir == from or String.starts_with?(dir, from <> "/")
end
