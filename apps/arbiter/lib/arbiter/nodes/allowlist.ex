defmodule Arbiter.Nodes.Allowlist do
  @moduledoc """
  A workspace's node allowlist, `worker.placement_nodes` (bd-d7tb2d).

  A list of selectors; when set, remote placement considers only nodes matching at
  least one. Unset (or an empty list) keeps the historic behaviour: any node.

  Selector strings: `name:<node name>`, `label:<k=v>`, `kind:<cluster|machine>`.
  Unprefixed: `cluster`/`machine`/`local` is a kind, anything containing `=` a label,
  otherwise a node name.
  """

  @kinds ~w(cluster machine local)

  @type selector :: {:name | :label | :kind, String.t()}

  @doc "The workspace's parsed selectors, or `nil` when unset (any node)."
  @spec selectors(map() | nil) :: [selector()] | nil
  def selectors(%{config: %{"worker" => %{"placement_nodes" => list}}}) when is_list(list) do
    case list |> Enum.map(&parse/1) |> Enum.reject(&is_nil/1) do
      [] -> nil
      parsed -> parsed
    end
  end

  def selectors(_workspace), do: nil

  @doc "Parse one selector; `nil` when it is not a usable string."
  @spec parse(term()) :: selector() | nil
  def parse("name:" <> v) when v != "", do: {:name, v}
  def parse("label:" <> v) when v != "", do: {:label, v}
  def parse("kind:" <> v) when v != "", do: {:kind, v}
  def parse(v) when v in @kinds, do: {:kind, v}

  def parse(v) when is_binary(v) and v != "" do
    if String.contains?(v, "="), do: {:label, v}, else: {:name, v}
  end

  def parse(_), do: nil

  @doc "Does a node row pass the allowlist? `nil` allows everything."
  @spec allows?([selector()] | nil, map()) :: boolean()
  def allows?(nil, _row), do: true
  def allows?(selectors, row), do: Enum.any?(selectors, &matches?(&1, row))

  defp matches?({:name, n}, row), do: n in [Map.get(row, :name), Map.get(row, :id)]
  defp matches?({:kind, k}, row), do: to_string(Map.get(row, :kind)) == k
  defp matches?({:label, l}, row), do: l in (Map.get(row, :labels) || [])

  @doc "Human text of the selectors."
  @spec describe([selector()] | nil) :: String.t()
  def describe(nil), do: "any node"
  def describe(selectors), do: Enum.map_join(selectors, ", ", fn {t, v} -> "#{t}:#{v}" end)
end
