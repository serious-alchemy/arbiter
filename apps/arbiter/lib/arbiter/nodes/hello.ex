defmodule Arbiter.Nodes.Hello do
  @moduledoc """
  What the primary reads out of a node's `hello` and answers in `hello_ok`
  (`docs/design/remote-workers.md` §4.2, §13): the per-run verdicts and the
  effective worker ceiling. Pure of process state; the run check reads
  `worker_runs`.
  """

  require Ash.Query

  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunState

  @doc """
  The primary's verdict on each run id the node reports in `hello`: `"known"`
  (a `worker_runs` row in a live state — the primary still owns it) or
  `"unknown"` (no such run, already finished, or not a run id at all — the
  agent quiesces it, §10.4).

  `worker_runs` has no `node_id` yet (RW8), so "known" is *a live run with this
  id*, not *a live run assigned to this node*. The run-scoped authorization of
  §5.3 tightens it when that column lands.
  """
  @spec verdicts([term()]) :: %{String.t() => String.t()}
  def verdicts(run_ids) when is_list(run_ids) do
    ids = run_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()
    uuids = Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1)))
    live = live_run_ids(uuids)

    Map.new(ids, fn id -> {id, if(MapSet.member?(live, id), do: "known", else: "unknown")} end)
  end

  defp live_run_ids([]), do: MapSet.new()

  defp live_run_ids(uuids) do
    live_states = Enum.filter(RunState.states(), &RunState.live?/1)

    Run
    |> Ash.Query.filter(id in ^uuids and state in ^live_states)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> MapSet.new(& &1.id)
  end

  @doc """
  The effective `max_workers` (§13): `min(operator, node ceiling)` over whichever
  are set; when neither is, the node's own suggestion. `nil` when nothing is known.
  """
  @spec effective_max_workers(pos_integer() | nil, map()) :: non_neg_integer() | nil
  def effective_max_workers(operator, capacity) when is_map(capacity) do
    ceiling = positive(capacity["ceiling"])

    case Enum.reject([positive(operator), ceiling], &is_nil/1) do
      [] -> positive(capacity["suggestion"])
      limits -> Enum.min(limits)
    end
  end

  def effective_max_workers(operator, _), do: positive(operator)

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  @doc "The run ids a `hello` lists (`runs: [%{\"id\" => …}]`), in order, ignoring malformed entries."
  @spec run_ids(term()) :: [String.t()]
  def run_ids(runs) when is_list(runs) do
    for %{"id" => id} <- runs, is_binary(id), do: id
  end

  def run_ids(_), do: []
end
