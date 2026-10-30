defmodule Arbiter.Usage.SpendBreakdown do
  @moduledoc """
  A ticket's actual spend, split by the kind of pass that spent it — the
  payload behind `GET /api/issues/:id`'s `spend` and `arb ticket show`'s
  `Spend:` block.

  The total is `Arbiter.Usage.LiveSpend.for_task/1`'s, the figure the task page
  shows; the per-pass lines are the settled ledger rows grouped by `role`
  (falling back to the task-id suffix for an un-stamped row). The base
  session's rows split into the first `implement` pass and later `resume`s
  (ordered by `occurred_at`). Unpriced rows (subscription / codex) are counted,
  never priced as `$0`.
  """

  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.BaseTaskBackfill
  alias Arbiter.Usage.LiveSpend

  @kinds ~w(implement review_round fix_pass conflict resume review)

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec for_task(String.t(), keyword()) :: map()
  def for_task(task_id, opts \\ []) when is_binary(task_id) do
    live = Keyword.get_lazy(opts, :live, fn -> LiveSpend.for_task(task_id) end)
    rows = Budget.rows_for_task(task_id)

    passes =
      rows
      |> classify()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {kind, rs} -> {kind, pass(kind, rs)} end)
      |> Enum.sort_by(fn {kind, _} -> Enum.find_index(@kinds, &(&1 == kind)) end)
      |> Enum.map(&elem(&1, 1))

    %{
      total_usd: live.total_usd,
      run_count: length(rows),
      unpriced_runs: Enum.count(rows, &(not is_number(&1.cost_usd))),
      live: live.live?,
      passes: passes
    }
  end

  defp pass(kind, rows) do
    priced = Enum.filter(rows, &is_number(&1.cost_usd))

    %{
      kind: kind,
      count: length(rows),
      usd: priced |> Enum.reduce(0.0, &(&2 + &1.cost_usd)) |> Float.round(2),
      unpriced_runs: length(rows) - length(priced)
    }
  end

  defp classify(rows) do
    {base, other} = Enum.split_with(rows, &(role(&1) == "base"))

    base_kinds =
      base
      |> Enum.sort_by(&(&1.occurred_at && DateTime.to_unix(&1.occurred_at, :microsecond)))
      |> Enum.with_index()
      |> Enum.map(fn {r, i} -> {if(i == 0, do: "implement", else: "resume"), r} end)

    base_kinds ++ Enum.map(other, &{kind(role(&1)), &1})
  end

  defp role(%{role: r}) when is_binary(r) and r != "", do: r
  defp role(%{task_id: id}), do: BaseTaskBackfill.role_for(id)

  defp kind("impl"), do: "review_round"
  defp kind("review"), do: "review"
  defp kind("fix_pass"), do: "fix_pass"
  defp kind("conflict"), do: "conflict"
  defp kind(_), do: "resume"
end
