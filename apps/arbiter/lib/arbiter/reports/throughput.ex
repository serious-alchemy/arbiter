defmodule Arbiter.Reports.Throughput do
  @moduledoc """
  Throughput and lead time for `/reports` (bd-4h5ikn; design
  `docs/design/reports-design-v2.md` §5.3 and the lead half of §5.2).

  Reads `issues` only: completed, non-epic tickets, one slim row each
  (`difficulty`, `created_at`, `closed_at`). `compute/1` is pure over those
  rows so the arithmetic is unit-testable against hand-computed fixtures.

    * **Weekly throughput** — tickets by `closed_at` week (Monday, UTC) and
      difficulty, plus *weighted size* = Σ `weight/1` and its trailing
      4-week moving average. Reopened tickets count in the week they last
      closed (`closed_at` is cleared on reopen and re-set on close).
    * **Lead time** — `closed_at − created_at`, nearest-rank P50/P90 (the
      same `ROW_NUMBER()` definition the design specifies for SQL), a
      day-bucket histogram, and the P50/P90 either side of the
      2026-08-24 refined-lifecycle cutover.

  ## Weighting policy

  `@weights` is the single place the policy lives, and the page prints it
  from `weights/0` / `unrated_weight/0`: D0 = 0.5, D1…D4 = 1…4, **unrated
  (difficulty null, or above D4) = 2** — the `unrated_as_d2` rule
  `Arbiter.Usage.Estimate` already applies, so the page and
  `ticket_show.estimate` agree. Confirmed by the operator 2026-10-01.
  """

  require Ash.Query

  alias Arbiter.Tasks.Issue

  @weights %{0 => 0.5, 1 => 1, 2 => 2, 3 => 3, 4 => 4}
  @unrated_weight 2
  @era_cutover ~D[2026-08-24]
  @moving_avg_weeks 4
  # Histogram edges in days; the last bucket is open-ended.
  @edges [0, 1, 2, 3, 4, 5, 6, 7, 10, 14, 21, 30]

  @doc "The difficulty → weight table (unrated is `unrated_weight/0`)."
  @spec weights() :: %{non_neg_integer() => number()}
  def weights, do: @weights

  @spec unrated_weight() :: number()
  def unrated_weight, do: @unrated_weight

  @doc "Weight of one ticket of `difficulty` (`nil`/unknown → unrated)."
  @spec weight(integer() | nil) :: number()
  def weight(difficulty), do: Map.get(@weights, difficulty, @unrated_weight)

  @doc "Date the refined lifecycle began (design §3.1)."
  @spec era_cutover() :: Date.t()
  def era_cutover, do: @era_cutover

  @doc """
  Loads and computes. `filters` is the `/reports` filter map; `range` bounds
  `closed_at` here (throughput and lead time are about when work finished).
  """
  @spec load(map()) :: map()
  def load(filters) do
    Issue
    |> Ash.Query.select([:id, :difficulty, :created_at, :closed_at])
    |> Ash.Query.filter(
      state == :closed and close_reason == :completed and issue_type != :epic and
        not is_nil(closed_at)
    )
    |> apply_filters(filters)
    |> Ash.read!()
    |> compute()
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {_, ""}, q ->
        q

      {"workspace", id}, q ->
        Ash.Query.filter(q, workspace_id == ^id)

      {"repo", repo}, q ->
        Ash.Query.filter(q, repo == ^repo)

      {"type", type}, q ->
        Ash.Query.filter(q, issue_type == ^String.to_existing_atom(type))

      {"difficulty", d}, q ->
        Ash.Query.filter(q, difficulty == ^String.to_integer(d))

      {"range", "all"}, q ->
        q

      {"range", range}, q ->
        days = range |> String.trim_trailing("d") |> String.to_integer()
        cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
        Ash.Query.filter(q, closed_at >= ^cutoff)

      _, q ->
        q
    end)
  end

  @doc "Pure aggregation over `%{difficulty, created_at, closed_at}` rows."
  @spec compute([map()]) :: %{weekly: [map()], lead: map()}
  def compute(rows) do
    %{weekly: weekly(rows), lead: lead(rows)}
  end

  # ---- weekly ----

  defp weekly([]), do: []

  defp weekly(rows) do
    by_week = Enum.group_by(rows, &week/1)
    weeks = Map.keys(by_week)
    {first, last} = {Enum.min(weeks, Date), Enum.max(weeks, Date)}

    first
    |> Date.range(last, 7)
    |> Enum.map(fn week ->
      week_rows = Map.get(by_week, week, [])

      %{
        week: week,
        count: length(week_rows),
        counts: Enum.frequencies_by(week_rows, &normalize_difficulty(&1.difficulty)),
        weighted: week_rows |> Enum.map(&weight(&1.difficulty)) |> Enum.sum()
      }
    end)
    |> with_moving_average()
  end

  defp week(%{closed_at: at}), do: at |> DateTime.to_date() |> Date.beginning_of_week(:monday)

  # Out-of-table difficulties (D5) are unrated, matching `weight/1`.
  defp normalize_difficulty(d) when is_map_key(@weights, d), do: d
  defp normalize_difficulty(_), do: nil

  defp with_moving_average(weeks) do
    weeks
    |> Enum.with_index()
    |> Enum.map(fn {w, i} ->
      start = max(i - @moving_avg_weeks + 1, 0)
      window = Enum.slice(weeks, start, i - start + 1)
      avg = Enum.sum(Enum.map(window, & &1.weighted)) / length(window)
      Map.put(w, :moving_avg, avg)
    end)
  end

  # ---- lead time ----

  defp lead(rows) do
    leads =
      for %{created_at: c, closed_at: x} = r <- rows, c != nil do
        {max(DateTime.diff(x, c, :second), 0) / 3600, r}
      end

    hours = Enum.map(leads, &elem(&1, 0))
    cutover = DateTime.new!(@era_cutover, ~T[00:00:00], "Etc/UTC")

    {post, pre} =
      leads |> Enum.split_with(fn {_, r} -> DateTime.compare(r.closed_at, cutover) != :lt end)

    Map.merge(stats(hours), %{
      buckets: buckets(hours),
      eras: %{
        before: stats(Enum.map(pre, &elem(&1, 0))),
        after: stats(Enum.map(post, &elem(&1, 0)))
      }
    })
  end

  defp stats(hours) do
    sorted = Enum.sort(hours)

    %{
      n: length(sorted),
      p50_hours: percentile(sorted, 0.5),
      p90_hours: percentile(sorted, 0.9)
    }
  end

  # Nearest rank: the ceil(p·n)-th smallest value.
  defp percentile([], _), do: nil

  defp percentile(sorted, p) do
    rank = max(ceil(p * length(sorted)), 1)
    sorted |> Enum.at(rank - 1) |> Kernel.*(1.0)
  end

  defp buckets(hours) do
    lowers = @edges
    uppers = tl(@edges) ++ [:infinity]

    Enum.zip_with(lowers, uppers, fn from, to ->
      count =
        Enum.count(hours, fn h ->
          d = h / 24
          d >= from and (to == :infinity or d < to)
        end)

      %{from: from, to: if(to == :infinity, do: "∞", else: to), count: count}
    end)
  end
end
