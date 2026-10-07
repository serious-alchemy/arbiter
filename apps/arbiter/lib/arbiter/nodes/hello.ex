defmodule Arbiter.Nodes.Hello do
  @moduledoc """
  What the primary reads out of a node's `hello` and answers in `hello_ok`
  (`docs/design/remote-workers.md` §4.2, §13): the effective worker ceiling and the
  run ids a hello lists. Pure. The per-run verdicts are the session's own
  (`Arbiter.Nodes.Session`): a run is known iff the session holds it (§10.4).
  """

  @doc """
  The effective `max_workers` of a node (§13, with the RW8 operator amendment).

  The node's cap is the operator's override when there is one, else the node's
  own suggestion: the operator can go **up or down** from the suggestion. A
  ceiling the node's owner set on the node itself (`ARB_NODE_MAX_WORKERS`, the
  ConfigMap's `max_concurrent`) is a hard bound on that cap, so an override
  above it loses to it. `nil` when nothing is known.
  """
  @spec effective_max_workers(pos_integer() | nil, map() | nil) :: non_neg_integer() | nil
  def effective_max_workers(override, capacity) do
    capacity = if is_map(capacity), do: capacity, else: %{}
    base = positive(override) || positive(capacity["suggestion"])

    case {base, positive(capacity["ceiling"])} do
      {nil, ceiling} -> ceiling
      {base, nil} -> base
      {base, ceiling} -> min(base, ceiling)
    end
  end

  @doc """
  What decided `effective_max_workers/2`: `:ceiling` when the node owner's bound
  is the binding term (so the UI can show the override and the bound that beat
  it), `:override`, `:suggestion`, or `nil` when nothing is known.
  """
  @spec cap_source(pos_integer() | nil, map() | nil) :: :ceiling | :override | :suggestion | nil
  def cap_source(override, capacity) do
    capacity = if is_map(capacity), do: capacity, else: %{}
    base = positive(override) || positive(capacity["suggestion"])
    ceiling = positive(capacity["ceiling"])

    cond do
      ceiling != nil and (base == nil or ceiling <= base) -> :ceiling
      positive(override) -> :override
      base -> :suggestion
      true -> nil
    end
  end

  @doc "The run ids a `hello` lists (`runs: [%{\"id\" => …}]`), in order, ignoring malformed entries."
  @spec run_ids(term()) :: [String.t()]
  def run_ids(runs) when is_list(runs) do
    for %{"id" => id} <- runs, is_binary(id), do: id
  end

  def run_ids(_), do: []

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil
end
