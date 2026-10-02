defmodule Arbiter.Reports.Cost do
  @moduledoc """
  Cost per ticket by difficulty and provider for `/reports` (bd-bgni2q; design
  `docs/design/reports-design-v2.md` §5.6).

  The ledger is aggregated **in SQL**: one `GROUP BY` over `usage_events`
  returns a row per (ticket id, provider, model, account) — never an event row,
  never `raw`. Those group rows (hundreds, not thousands) are folded to the
  base ticket with `Arbiter.Usage.Estimate.fold_task_id/1` and joined to closed
  issues in Elixir.

  ## Parity with `ticket_show.estimate`

  The per-difficulty `p25`/`median`/`p75`/`p90` use the estimator's own
  population and arithmetic: `source: :task` rows inside the same rolling
  window (`Estimate.window_days/0`, filtered on `occurred_at`), closed tickets
  only, priced rows only, a ticket's cost = the sum of its priced rows, each
  ticket weighted by `Estimate.recency_weight/2` of its latest priced row,
  reduced by `Estimate.percentiles/1`. So for a difficulty the figures equal
  the estimate's `difficulty` rung (`basis: "difficulty"`). The page's `range`
  filter deliberately does not apply here: a different window would make the
  page disagree with the ticket card.

  ## Honesty about unmetered providers

  A null `cost_usd` is never summed as zero. A (provider, model, account) line
  with no priced row reports `cost_usd: nil` and `metered?: false`; its tokens
  (where reported) and row counts are still shown. Dollars are never summed
  across providers' unmetered rows because there is nothing to sum.

  ## Coordinator overhead

  `overhead` is `source: :coordinator_session` spend over the same window: no
  ticket owns it, so it is reported apart from the per-ticket figures, with
  its share of all priced worker-plus-coordinator spend.
  """

  import Ecto.Query, only: [from: 2]

  alias Arbiter.Repo
  alias Arbiter.Tasks.Issue
  alias Arbiter.Usage.Estimate

  require Ash.Query

  @id_chunk 200

  @spec load(map(), keyword()) :: map()
  def load(filters, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    window = Keyword.get(opts, :window_days, Estimate.window_days())
    since = DateTime.add(now, -window, :day)
    ws = filters |> Map.get("workspace", "") |> blank_to_nil()

    groups = ledger_groups(since, ws)
    issues = closed_issues(groups, filters)

    tickets =
      groups
      |> fold_groups()
      |> Enum.filter(&Map.has_key?(issues, &1.ticket))
      |> Enum.map(&Map.put(&1, :issue, Map.fetch!(issues, &1.ticket)))

    %{
      window_days: window,
      difficulties: difficulties(tickets, now),
      overhead: overhead(since, ws)
    }
  end

  # ---- SQL ---------------------------------------------------------------

  defp ledger_groups(since, ws) do
    base =
      from(e in "usage_events",
        where:
          e.source == "task" and not is_nil(e.task_id) and
            e.occurred_at >= type(^since, :utc_datetime_usec),
        group_by: [
          fragment("COALESCE(NULLIF(?, ''), ?)", e.base_task_id, e.task_id),
          e.provider,
          e.model,
          e.provider_account_id
        ],
        select: %{
          raw_id: fragment("COALESCE(NULLIF(?, ''), ?)", e.base_task_id, e.task_id),
          provider: e.provider,
          model: e.model,
          account_id: e.provider_account_id,
          rows: count(e.id),
          priced_rows: count(e.cost_usd),
          cost_usd: sum(e.cost_usd),
          token_rows: fragment("COUNT(?)", e.tokens_in),
          tokens: fragment("SUM(COALESCE(?, 0) + COALESCE(?, 0))", e.tokens_in, e.tokens_out),
          latest_priced:
            type(
              fragment("MAX(CASE WHEN ? IS NOT NULL THEN ? END)", e.cost_usd, e.occurred_at),
              :utc_datetime_usec
            )
        }
      )

    base
    |> then(fn q -> if ws, do: from(e in q, where: e.workspace_id == ^ws), else: q end)
    |> Repo.all()
  end

  defp overhead(since, ws) do
    q =
      from(e in "usage_events",
        where:
          e.source in ["task", "coordinator_session"] and
            e.occurred_at >= type(^since, :utc_datetime_usec),
        group_by: e.source,
        select: {e.source, count(e.id), count(e.cost_usd), sum(e.cost_usd)}
      )

    q = if ws, do: from(e in q, where: e.workspace_id == ^ws), else: q

    by_source =
      Map.new(Repo.all(q), fn {src, rows, priced, cost} -> {src, {rows, priced, cost}} end)

    {rows, priced, cost} = Map.get(by_source, "coordinator_session", {0, 0, nil})
    {_, _, task_cost} = Map.get(by_source, "task", {0, 0, nil})

    cost = if priced > 0, do: money(cost)
    total = (cost || 0.0) + (task_cost || 0.0)

    %{
      cost_usd: cost,
      rows: rows,
      unpriced_rows: rows - priced,
      share: if(cost && total > 0, do: cost / total)
    }
  end

  # ---- folding -----------------------------------------------------------

  # Merge group rows whose ids fold to the same ticket (`t`, `t#review`,
  # `t:fixpass` …) and share a (provider, model, account).
  defp fold_groups(groups) do
    groups
    |> Enum.group_by(&{Estimate.fold_task_id(&1.raw_id), &1.provider, &1.model, &1.account_id})
    |> Enum.map(fn {{ticket, provider, model, account_id}, gs} ->
      priced = Enum.sum(Enum.map(gs, & &1.priced_rows))
      token_rows = Enum.sum(Enum.map(gs, & &1.token_rows))

      %{
        ticket: ticket,
        provider: provider,
        model: model,
        account_id: account_id,
        rows: Enum.sum(Enum.map(gs, & &1.rows)),
        priced_rows: priced,
        cost_usd: if(priced > 0, do: gs |> Enum.map(&(&1.cost_usd || 0)) |> Enum.sum()),
        token_rows: token_rows,
        tokens: if(token_rows > 0, do: gs |> Enum.map(&(&1.tokens || 0)) |> Enum.sum()),
        latest_priced: gs |> Enum.map(& &1.latest_priced) |> Enum.reject(&is_nil/1) |> latest()
      }
    end)
  end

  defp latest([]), do: nil
  defp latest(list), do: Enum.max(list, DateTime)

  # Closed tickets only, then the repo / type / difficulty filters.
  defp closed_issues(groups, filters) do
    groups
    |> Enum.map(&Estimate.fold_task_id(&1.raw_id))
    |> Enum.uniq()
    |> Enum.chunk_every(@id_chunk)
    |> Enum.flat_map(fn ids ->
      closed = :closed

      Issue
      |> Ash.Query.filter(id in ^ids and state == ^closed)
      |> Ash.Query.select([:id, :difficulty, :issue_type, :repo])
      |> Ash.read!()
    end)
    |> Enum.filter(&issue_matches?(&1, filters))
    |> Map.new(&{&1.id, &1})
  end

  defp issue_matches?(issue, filters) do
    Enum.all?(filters, fn
      {"repo", repo} when repo != "" -> issue.repo == repo
      {"type", type} when type != "" -> to_string(issue.issue_type) == type
      {"difficulty", d} when d != "" -> to_string(issue.difficulty) == d
      _ -> true
    end)
  end

  # ---- per difficulty ----------------------------------------------------

  defp difficulties(tickets, now) do
    tickets
    |> Enum.group_by(& &1.issue.difficulty)
    |> Enum.map(fn {difficulty, lines} -> difficulty_row(difficulty, lines, now) end)
    |> Enum.sort_by(&(&1.difficulty || 99))
  end

  defp difficulty_row(difficulty, lines, now) do
    per_ticket = Enum.group_by(lines, & &1.ticket)
    sample = sample_rows(per_ticket, now)

    stats =
      if sample == [],
        do: %{p25: nil, median: nil, p75: nil, p90: nil},
        else: Estimate.percentiles(sample)

    Map.merge(stats, %{
      difficulty: difficulty,
      tickets: map_size(per_ticket),
      priced_tickets: length(sample),
      cost_usd: sum_cost(lines),
      providers: provider_rows(lines, now)
    })
  end

  # One estimator-shaped row per ticket with at least one priced row.
  defp sample_rows(per_ticket, now) do
    per_ticket
    |> Enum.flat_map(fn {_ticket, lines} ->
      case sum_cost(lines) do
        nil -> []
        cost -> [%{cost_usd: cost, weight: weight(lines, now)}]
      end
    end)
  end

  defp weight(lines, now) do
    lines
    |> Enum.map(& &1.latest_priced)
    |> Enum.reject(&is_nil/1)
    |> latest()
    |> Estimate.recency_weight(now)
  end

  defp sum_cost(lines) do
    case Enum.filter(lines, &(&1.priced_rows > 0)) do
      [] -> nil
      priced -> priced |> Enum.map(& &1.cost_usd) |> Enum.sum() |> money()
    end
  end

  defp provider_rows(lines, now) do
    lines
    |> Enum.group_by(&{&1.provider, &1.model, &1.account_id})
    |> Enum.map(fn {{provider, model, account_id}, ls} ->
      sample = ls |> Enum.group_by(& &1.ticket) |> sample_rows(now)
      metered? = sample != []

      stats =
        if metered?,
          do: Map.take(Estimate.percentiles(sample), [:p25, :median, :p75]),
          else: %{p25: nil, median: nil, p75: nil}

      Map.merge(stats, %{
        provider: provider,
        model: model,
        account_id: account_id,
        metered?: metered?,
        tickets: ls |> Enum.map(& &1.ticket) |> Enum.uniq() |> length(),
        priced_tickets: length(sample),
        cost_usd: sum_cost(ls),
        unmetered_rows: Enum.sum(Enum.map(ls, &(&1.rows - &1.priced_rows))),
        tokens: ls |> Enum.reject(&is_nil(&1.tokens)) |> Enum.map(& &1.tokens) |> sum_or_nil()
      })
    end)
    |> Enum.sort_by(&{&1.provider || "", &1.model || "", &1.account_id || ""})
  end

  defp sum_or_nil([]), do: nil
  defp sum_or_nil(list), do: Enum.sum(list)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp money(value), do: Float.round(value / 1, 2)
end
