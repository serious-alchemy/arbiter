defmodule Arbiter.Reports.ReviewHealth do
  @moduledoc """
  ReviewGate health for `/reports` (bd-tbimna; design
  `docs/design/reports-design-v2.md` §5.4): does the gate converge fast, how
  often does the first review pass, and how often does the coordinator have to
  overrule it.

  Every figure is one bounded SQL aggregate over `review_gate_rounds` and
  `gate_resolutions`; no row, finding text or transcript is loaded.

    * A **gate cycle** is `(task_id, fix_round_attempt)` over `role = 'review'`
      rows (an automatic fix round restarts `round` at 1, see
      `Arbiter.ReviewGate.Round`). *Rounds per cycle* is `MAX(round)`, dated by
      the cycle's last review row.
    * **First-pass approve rate** = round-1 `approve` rows / round-1 review
      rows, dated by the row. `timed_out` rows are in the denominator (a pass
      that produced no verdict did not approve) and are also reported on their
      own, with the approve-with-unmet-criteria count (`converged = false`).
    * **Outcome** is a SQL port of `Arbiter.ReviewGate.Resolutions.outcome/2`,
      per task, dated by the task's last activity (its last round or review-gate
      resolution). Keep the two in step: `outcomes/2` is what the parity test
      compares with the Elixir function.
    * **Provider charts** (review cost per provider / model / family, and the
      same-family fallback rate) start at `provider_start/0`: before it
      `reviewer_provider` is null on most rows and the split would be noise.

  ## The SQL outcome

  `outcome/2` reads a task's rounds sorted by `(fix_round_attempt, round,
  inserted_at)` and its resolutions oldest first; the port keeps that order, so
  "the last row" is the last by that sort, not by clock. Then:

    1. a `review_gate` resolution exists and is not older than the last row
       (or there are no rows) ⇒ `resolved`;
    2. else the last `review` row approved ⇒ `converged`;
    3. else there is a `review` row ⇒ `not_converged`;
    4. else `none`.

  Timestamps are compared as text: every `inserted_at` is stored as
  fixed-width `YYYY-MM-DDTHH:MM:SS.ffffffZ`, so lexicographic order is time
  order.

  `gate_cap_hit` is not read (its `events` row is pruned); a cap hit is a
  cycle whose rounds reach the cap.
  """

  alias Arbiter.Repo

  @provider_start ~D[2026-09-20]
  @outcomes [:converged, :resolved, :not_converged]
  @scope_filters ~w(workspace repo type difficulty epic)

  # `round` restarts on every automatic fix round: sort by attempt first, as
  # `review_gate_rounds_list` does. `rowid` is the insertion-order tiebreak.
  @round_order "r.fix_round_attempt DESC, r.round DESC, r.inserted_at DESC, r.rowid DESC"

  # Per task: the verdict of the last review row ('' if it has none), the
  # stamp of the last row of any role, and of the last review_gate resolution.
  # `activity` is the later of the two stamps.
  @outcome_sql """
  SELECT task_id, outcome, activity FROM (
    SELECT task_id,
      CASE
        WHEN last_resolution_at IS NOT NULL
             AND (last_row_at IS NULL OR last_resolution_at >= last_row_at) THEN 'resolved'
        WHEN last_review = 'approve' THEN 'converged'
        WHEN last_review IS NOT NULL THEN 'not_converged'
        ELSE 'none'
      END AS outcome,
      CASE
        WHEN last_resolution_at IS NULL THEN last_row_at
        WHEN last_row_at IS NULL OR last_resolution_at > last_row_at THEN last_resolution_at
        ELSE last_row_at
      END AS activity
    FROM (
      SELECT t.task_id AS task_id,
        (SELECT COALESCE(r.verdict, '') FROM review_gate_rounds r
          WHERE r.task_id = t.task_id AND r.role = 'review'
          ORDER BY #{@round_order} LIMIT 1) AS last_review,
        (SELECT r.inserted_at FROM review_gate_rounds r
          WHERE r.task_id = t.task_id
          ORDER BY #{@round_order} LIMIT 1) AS last_row_at,
        (SELECT MAX(g.inserted_at) FROM gate_resolutions g
          WHERE g.task_id = t.task_id AND g.gate = 'review_gate') AS last_resolution_at
      FROM (
        SELECT task_id FROM review_gate_rounds
        UNION
        SELECT task_id FROM gate_resolutions WHERE gate = 'review_gate'
      ) t
      WHERE 1 = 1 %SCOPE%
    )
  )
  WHERE 1 = 1 %RANGE%
  """

  @week "date(substr(%COL%, 1, 10), 'weekday 0', '-6 days')"

  @doc "First day the provider charts cover (design §5.4)."
  @spec provider_start() :: Date.t()
  def provider_start, do: @provider_start

  @spec load(map(), DateTime.t()) :: map()
  def load(filters, now \\ DateTime.utc_now()) do
    cutoff = cutoff(Map.get(filters, "range", "all"), now)
    scope = scope(filters, "task_id")

    rounds = rounds_per_cycle(scope, cutoff)
    first_pass_weekly = first_pass_weekly(scope, cutoff)
    outcomes_weekly = outcomes_weekly(scope, cutoff)

    %{
      cycles: rounds |> Enum.map(& &1.count) |> Enum.sum(),
      rounds: rounds,
      first_pass: first_pass(first_pass_weekly),
      first_pass_weekly: fill_weeks(first_pass_weekly, %{n: 0, approved: 0, rate: nil}),
      verdicts: verdicts(scope, cutoff),
      outcomes: outcome_totals(outcomes_weekly),
      outcomes_weekly: outcomes_chart(outcomes_weekly),
      providers: %{
        since: @provider_start,
        rows: provider_rows(scope, cutoff),
        fallback: fallback(scope, cutoff)
      },
      resolutions: resolutions(scope, cutoff)
    }
  end

  @doc """
  The outcome of every task with a gate round or a `review_gate` resolution,
  as `%{task_id => "converged" | "resolved" | "not_converged" | "none"}` — the
  SQL port of `Arbiter.ReviewGate.Resolutions.outcome/2`.
  """
  @spec outcomes(map(), DateTime.t()) :: %{String.t() => String.t()}
  def outcomes(filters, now \\ DateTime.utc_now()) do
    {scope_sql, scope_params} = scope(filters, "t.task_id")
    {range_sql, range_params} = range(cutoff(Map.get(filters, "range", "all"), now), "activity")

    @outcome_sql
    |> String.replace("%SCOPE%", scope_sql)
    |> String.replace("%RANGE%", range_sql)
    |> query(scope_params ++ range_params)
    |> Map.new(fn [task_id, outcome, _activity] -> {task_id, outcome} end)
  end

  # ---- queries -----------------------------------------------------------

  defp rounds_per_cycle({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "at")

    """
    SELECT rounds, COUNT(*) FROM (
      SELECT MAX(round) AS rounds, MAX(inserted_at) AS at
      FROM review_gate_rounds
      WHERE role = 'review' #{scope_sql}
      GROUP BY task_id, fix_round_attempt
    ) WHERE 1 = 1 #{range_sql}
    GROUP BY rounds ORDER BY rounds
    """
    |> query(scope_params ++ range_params)
    |> Enum.map(fn [rounds, count] -> %{rounds: rounds, count: count} end)
  end

  defp first_pass_weekly({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "inserted_at")

    """
    SELECT #{week("inserted_at")} AS week, COUNT(*), COALESCE(SUM(verdict = 'approve'), 0)
    FROM review_gate_rounds
    WHERE role = 'review' AND round = 1 #{scope_sql} #{range_sql}
    GROUP BY week ORDER BY week
    """
    |> query(scope_params ++ range_params)
    |> Enum.map(fn [week, n, approved] ->
      %{week: Date.from_iso8601!(week), n: n, approved: approved, rate: rate(approved, n)}
    end)
  end

  defp first_pass(weekly) do
    n = weekly |> Enum.map(& &1.n) |> Enum.sum()
    approved = weekly |> Enum.map(& &1.approved) |> Enum.sum()
    %{n: n, approved: approved, rate: rate(approved, n)}
  end

  defp verdicts({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "inserted_at")

    [[rows, approve, unmet, timed_out]] =
      """
      SELECT COUNT(*),
        COALESCE(SUM(verdict = 'approve'), 0),
        COALESCE(SUM(verdict = 'approve' AND converged = 0), 0),
        COALESCE(SUM(verdict = 'timed_out'), 0)
      FROM review_gate_rounds
      WHERE role = 'review' #{scope_sql} #{range_sql}
      """
      |> query(scope_params ++ range_params)

    %{
      review_rows: rows,
      approve: approve,
      approve_unmet: unmet,
      timed_out: timed_out,
      timed_out_rate: rate(timed_out, rows)
    }
  end

  defp outcomes_weekly({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "activity")

    """
    SELECT #{week("activity")} AS week, outcome, COUNT(*) FROM (
    #{String.replace(@outcome_sql, "%SCOPE%", scope_sql) |> String.replace("%RANGE%", range_sql)}
    ) WHERE activity IS NOT NULL
    GROUP BY week, outcome ORDER BY week
    """
    |> query(scope_params ++ range_params)
    |> Enum.map(fn [week, outcome, count] -> {Date.from_iso8601!(week), outcome, count} end)
  end

  defp outcome_totals(weekly) do
    base = %{converged: 0, resolved: 0, not_converged: 0, none: 0}

    Enum.reduce(weekly, base, fn {_week, outcome, count}, acc ->
      Map.update!(acc, String.to_existing_atom(outcome), &(&1 + count))
    end)
  end

  defp outcomes_chart(weekly) do
    weekly
    |> Enum.group_by(&elem(&1, 0), fn {_week, outcome, count} -> {outcome, count} end)
    |> Enum.map(fn {week, pairs} ->
      counts = Map.new(@outcomes, fn o -> {o, 0} end)

      counts =
        Enum.reduce(pairs, counts, fn {outcome, count}, acc ->
          case String.to_existing_atom(outcome) do
            :none -> acc
            key -> Map.put(acc, key, count)
          end
        end)

      %{week: week, counts: counts}
    end)
    |> fill_weeks(%{counts: Map.new(@outcomes, fn o -> {o, 0} end)})
  end

  # Review passes since `provider_start/0`, by who ran them. Cost is summed
  # over priced rows only: a null `cost_usd` is never counted as zero.
  defp provider_rows({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "inserted_at")

    """
    SELECT reviewer_provider, reviewer_model, reviewer_family,
      COUNT(*), COUNT(cost_usd), SUM(cost_usd)
    FROM review_gate_rounds
    WHERE role = 'review' AND inserted_at >= ? #{scope_sql} #{range_sql}
    GROUP BY reviewer_provider, reviewer_model, reviewer_family
    ORDER BY COUNT(*) DESC, reviewer_provider, reviewer_model, reviewer_family
    """
    |> query([provider_floor()] ++ scope_params ++ range_params)
    |> Enum.map(fn [provider, model, family, passes, priced, cost] ->
      %{
        provider: provider,
        model: model,
        family: family,
        passes: passes,
        priced: priced,
        cost_usd: cost && cost * 1.0
      }
    end)
  end

  defp fallback({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "inserted_at")

    [[passes, fallbacks]] =
      """
      SELECT COUNT(same_family_fallback), COALESCE(SUM(same_family_fallback), 0)
      FROM review_gate_rounds
      WHERE role = 'review' AND inserted_at >= ? #{scope_sql} #{range_sql}
      """
      |> query([provider_floor()] ++ scope_params ++ range_params)

    %{passes: passes, fallbacks: fallbacks, rate: rate(fallbacks, passes)}
  end

  defp resolutions({scope_sql, scope_params}, cutoff) do
    {range_sql, range_params} = range(cutoff, "inserted_at")

    """
    SELECT decision, actor, COUNT(*) FROM gate_resolutions
    WHERE gate = 'review_gate' #{scope_sql} #{range_sql}
    GROUP BY decision, actor
    ORDER BY COUNT(*) DESC, decision, actor
    """
    |> query(scope_params ++ range_params)
    |> Enum.map(fn [decision, actor, count] ->
      %{decision: decision, actor: actor, count: count}
    end)
  end

  # ---- helpers -----------------------------------------------------------

  defp query(sql, params), do: Repo.query!(sql, params).rows

  defp week(column), do: String.replace(@week, "%COL%", column)

  defp rate(_part, 0), do: nil
  defp rate(part, whole), do: part / whole

  # One entry per Monday from the first to the last week, `empty` merged into
  # the gaps, so a quiet week shows as a quiet week.
  defp fill_weeks([], _empty), do: []

  defp fill_weeks(points, empty) do
    by_week = Map.new(points, &{&1.week, &1})
    weeks = Enum.map(points, & &1.week)
    {first, last} = {Enum.min(weeks, Date), Enum.max(weeks, Date)}

    first
    |> Date.range(last, 7)
    |> Enum.map(fn week -> Map.get(by_week, week) || Map.put(empty, :week, week) end)
  end

  # `AND <column> IN (…)` limiting `column` to tickets matching the page's
  # ticket filters; empty when none is set. A subquery, never a bound id list
  # (SQLite's expression-tree limit, design §6).
  defp scope(filters, column) do
    {conds, params} =
      @scope_filters
      |> Enum.flat_map(fn key ->
        case Map.get(filters, key, "") do
          "" -> []
          value -> [scope_cond(key, value)]
        end
      end)
      |> Enum.unzip()

    case conds do
      [] ->
        {"", []}

      _ ->
        {"AND #{column} IN (SELECT id FROM issues WHERE issue_type != 'epic' AND " <>
           Enum.join(conds, " AND ") <> ")", List.flatten(params)}
    end
  end

  defp scope_cond("workspace", id), do: {"workspace_id = ?", [id]}
  defp scope_cond("repo", repo), do: {"repo = ?", [repo]}
  defp scope_cond("type", type), do: {"issue_type = ?", [type]}
  defp scope_cond("difficulty", d), do: {"difficulty = ?", [String.to_integer(d)]}

  defp scope_cond("epic", epic) do
    {"id IN (SELECT to_issue_id FROM dependencies WHERE type = 'parent_of' AND from_issue_id = ?)",
     [epic]}
  end

  defp range(nil, _column), do: {"", []}
  defp range(cutoff, column), do: {"AND #{column} >= ?", [cutoff]}

  defp cutoff("all", _now), do: nil

  defp cutoff(range, now) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    now |> DateTime.add(-days * 86_400, :second) |> stamp()
  end

  defp provider_floor, do: stamp(DateTime.new!(@provider_start, ~T[00:00:00.000000], "Etc/UTC"))

  # The stored width: six fractional digits, `Z`.
  defp stamp(%DateTime{} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {elem(at.microsecond, 0), 6}})
end
