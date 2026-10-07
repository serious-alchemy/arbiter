defmodule ArbiterCli.Cmd.Config.Value do
  @moduledoc """
  Value parsing and dotted-path map manipulation for `arb config set`/`unset`
  — the parts of `arb config` that are pure data transforms with no I/O. (The
  safety rails — `repo_paths` emptied, tracker misconfig, `secret*` keys — are
  enforced by the server, P-20.)
  """

  @doc """
  The one value-typing rule (shared with `arb settings set`): the text is
  decoded as JSON — `true`/`false`/`null`, numbers, `{...}`/`[...]`, and a
  *quoted* string — and anything that is not valid JSON is the raw string. So
  `true` is the boolean, `"true"` (quotes kept in the shell) is the string
  `true`, and `hello` is `hello`.
  """
  def parse_value(raw) when is_binary(raw) do
    case Jason.decode(String.trim(raw)) do
      {:ok, v} -> v
      {:error, _} -> raw
    end
  end

  # ----- dotted-path helpers ---------------------------------------------

  @doc """
  Split a dotted key into segments; `\\.` is a literal dot (a repo name such as
  `repo_paths.my\\.repo`), `\\\\` a literal backslash, empty segments are
  dropped. Mirrors the server's `Arbiter.Tasks.Workspace.ConfigPath`.
  """
  def split(path) when is_binary(path) do
    path |> scan([], []) |> Enum.reject(&(&1 == ""))
  end

  defp scan(<<"\\.", rest::binary>>, cur, acc), do: scan(rest, ["." | cur], acc)
  defp scan(<<"\\\\", rest::binary>>, cur, acc), do: scan(rest, ["\\" | cur], acc)
  defp scan(<<".", rest::binary>>, cur, acc), do: scan(rest, [], [done(cur) | acc])
  defp scan(<<c::utf8, rest::binary>>, cur, acc), do: scan(rest, [<<c::utf8>> | cur], acc)
  defp scan(<<byte, rest::binary>>, cur, acc), do: scan(rest, [<<byte>> | cur], acc)
  defp scan(<<>>, cur, acc), do: Enum.reverse([done(cur) | acc])

  defp done(cur), do: cur |> Enum.reverse() |> IO.iodata_to_binary()

  @doc false
  def get_in_path(value, []), do: value

  def get_in_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> get_in_path(sub, rest)
    end
  end

  def get_in_path(_, _), do: nil

  @doc false
  def put_in_path(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  def put_in_path(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, put_in_path(sub, rest, value))
  end

  @doc false
  def drop_path(map, [k]) when is_map(map), do: Map.delete(map, k)

  def drop_path(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      %{} = sub -> Map.put(map, k, drop_path(sub, rest))
      _ -> map
    end
  end

  def drop_path(other, _), do: other

  @doc false
  def deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  # ----- rendering ----------------------------------------------------------

  @doc false
  def pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, s} -> s
      {:error, _} -> inspect(value)
    end
  end

  @doc false
  def pretty_inline(value) do
    case Jason.encode(value) do
      {:ok, s} -> s
      {:error, _} -> inspect(value)
    end
  end
end
