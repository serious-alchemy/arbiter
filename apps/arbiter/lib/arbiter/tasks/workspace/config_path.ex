defmodule Arbiter.Tasks.Workspace.ConfigPath do
  @moduledoc """
  The one addressing rule for a key inside a workspace `config`: a dotted path
  whose literal dots are escaped with a backslash.

      "repo_paths.my\\.repo"  →  ["repo_paths", "my.repo"]

  Several config sections are keyed by a repo name (`repo_paths.<repo>`,
  `merge.repos.<repo>`, `review_automation.repo_overrides.<repo>`,
  `agent.security.repos.<repo>`), and a repo name may contain a dot. `\\\\` is a
  literal backslash; empty segments are dropped. `PatchConfig` (`unset_paths`),
  the MCP `workspace_config_*` tools and `arb config` all split with this rule.
  """

  @doc "Split a (possibly escaped) dotted path into its key segments."
  @spec split(String.t()) :: [String.t()]
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

  @doc "The escaped dotted form of `segments` (the inverse of `split/1`)."
  @spec join([String.t()]) :: String.t()
  def join(segments) when is_list(segments) do
    Enum.map_join(segments, ".", fn seg ->
      seg |> String.replace("\\", "\\\\") |> String.replace(".", "\\.")
    end)
  end

  @doc "A nested map holding `value` at `segments`, merged into `map`."
  @spec put(map(), [String.t()], term()) :: map()
  def put(map, [k], value) when is_map(map), do: Map.put(map, k, value)

  def put(map, [k | rest], value) when is_map(map) do
    sub =
      case Map.get(map, k) do
        %{} = s -> s
        _ -> %{}
      end

    Map.put(map, k, put(sub, rest, value))
  end

  @doc "The value at `segments` in a nested map; `nil` if any segment is missing."
  @spec get(term(), [String.t()]) :: term()
  def get(value, []), do: value

  def get(map, [k | rest]) when is_map(map) do
    case Map.get(map, k) do
      nil -> nil
      sub -> get(sub, rest)
    end
  end

  def get(_, _), do: nil
end
