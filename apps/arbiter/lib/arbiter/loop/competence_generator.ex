defmodule Arbiter.Loop.CompetenceGenerator do
  @moduledoc """
  The seeding generator for the hand competence matrix (bd-biycyw, R6 of
  `docs/design/paced-quota-routing-signals.md` §3.3, §3.6, and Appendix A).

  Runs the Appendix A queries (via `Arbiter.Loop.SubjectStats`) over the
  baseline window `[2026-08-24T00:00Z, 2026-10-01T12:00Z)` (or a caller-specified
  window), aggregates closed tasks by `(provider, model, difficulty)`, applies
  90th percentile winsorising to time to close, and proposes matrix rows.

  The proposed rows can be reviewed, formatted as a report, or committed to
  installation settings (`Arbiter.Settings.set_competence_matrix/1`).
  """

  alias Arbiter.Loop.SubjectStats
  alias Arbiter.Settings

  @default_from ~U[2026-08-24 00:00:00Z]
  @default_until ~U[2026-10-01 12:00:00Z]
  @default_min_n 5
  @winsorize_quantile 0.90

  @type row :: %{String.t() => term()}

  @doc """
  Propose competence matrix rows from measured tasks.

  Options:
    * `:tasks` — pre-sampled tasks (skips DB queries);
    * `:from` — window start (default #{@default_from});
    * `:until` — window cutoff (default #{@default_until});
    * `:min_n` — minimum tasks per cell (default #{@default_min_n});
    * `:workspace_id` — optional workspace filter.
  """
  @spec generate(keyword()) :: [row()]
  def generate(opts \\ []) do
    from = Keyword.get(opts, :from, @default_from)
    until = Keyword.get(opts, :until, @default_until)
    min_n = Keyword.get(opts, :min_n, @default_min_n)

    tasks =
      Keyword.get_lazy(opts, :tasks, fn ->
        SubjectStats.sample(
          from: from,
          until: until,
          half_life_days: nil,
          workspace_id: opts[:workspace_id]
        )
      end)

    date_str = Date.to_iso8601(DateTime.to_date(until))

    tasks
    |> Enum.group_by(fn t ->
      {canonical_provider(t.provider), to_string(t.model), t.difficulty}
    end)
    |> Enum.filter(fn {_key, cell_tasks} -> length(cell_tasks) >= min_n end)
    |> Enum.map(fn {{provider, model, difficulty}, cell_tasks} ->
      summarize_cell(provider, model, difficulty, cell_tasks, date_str)
    end)
    |> Enum.sort_by(fn r ->
      {r["match"]["difficulty"], r["match"]["provider"], r["match"]["model"]}
    end)
  end

  @doc """
  Generate proposed rows and persist them into installation settings.
  """
  @spec seed_installation!(keyword()) :: {:ok, [row()]} | {:error, term()}
  def seed_installation!(opts \\ []) do
    rows = generate(opts)

    with {:ok, _} <- Settings.set_competence_matrix(rows) do
      {:ok, rows}
    end
  end

  @doc """
  Format proposed rows as a Markdown table matching design doc §3.6.
  """
  @spec format([row()]) :: String.t()
  def format(rows) do
    header = """
    | First choice | n | Round-1 approve | Review rounds | Fix passes | Attempts | Difficulty raised | Time to close, mean / median (h) | Imputed $, mean / median |
    |---|---|---|---|---|---|---|---|---|
    """

    body =
      Enum.map_join(rows, "\n", fn r ->
        choice = "#{r["match"]["provider"]} #{r["match"]["model"]}, D#{r["match"]["difficulty"]}"
        n = r["n"]

        q =
          if r["round_1_approve"],
            do: "#{round(r["round_1_approve"] * 100)}% (#{r["reviewed_n"]})",
            else: "—"

        r_rounds = format_num(r["review_rounds"])
        f_passes = format_num(r["fix_passes"])
        att = format_num(r["attempts"])

        diff_r =
          if r["difficulty_raised"], do: "#{round(r["difficulty_raised"] * 100)}%", else: "0%"

        time =
          "#{format_num(r["time_to_close_mean_hours"])} / #{format_num(r["time_to_close_median_hours"])}"

        cost = "#{format_num(r["cost_usd_mean"])} / #{format_num(r["cost_usd_median"])}"

        "| #{choice} | #{n} | #{q} | #{r_rounds} | #{f_passes} | #{att} | #{diff_r} | #{time} | #{cost} |"
      end)

    header <> body <> "\n"
  end

  # SubjectStats records agy runs under the `gemini` adapter; the matrix (and
  # `Competence.lookup/2`) key agy as `antigravity`, as the §3.6 baseline does.
  defp canonical_provider(provider) when provider in ["gemini", "agy", :gemini, :agy],
    do: "antigravity"

  defp canonical_provider(provider), do: to_string(provider)

  defp format_num(nil), do: "—"
  defp format_num(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 2)
  defp format_num(n), do: to_string(n)

  defp summarize_cell(provider, model, difficulty, tasks, date_str) do
    n = length(tasks)
    {reviewed_n, q} = calc_approval(tasks)
    runs = calc_run_metrics(tasks, n)
    stats = calc_time_and_cost(tasks)

    %{
      "match" => %{
        "provider" => provider,
        "model" => model,
        "difficulty" => difficulty
      },
      "n" => n,
      "rung" => 1,
      "measured_at" => date_str,
      "round_1_approve" => q && round2(q),
      "reviewed_n" => reviewed_n,
      "review_rounds" => round2(runs.review_rounds),
      "fix_passes" => round2(runs.fix_passes),
      "attempts" => round2(runs.attempts),
      "difficulty_raised" => round2(runs.difficulty_raised),
      "time_to_close_mean_hours" => stats.mean_time && round1(stats.mean_time),
      "time_to_close_median_hours" => stats.med_time && round1(stats.med_time),
      "cost_usd_mean" => stats.mean_cost && round2(stats.mean_cost),
      "cost_usd_median" => stats.med_cost && round2(stats.med_cost),
      "author_runs" => round2(runs.attempts + runs.fix_passes),
      "review_runs" => round2(runs.review_rounds),
      "weight" => 1.0
    }
  end

  defp calc_approval(tasks) do
    reviewed = Enum.filter(tasks, & &1.reviewed?)
    reviewed_n = length(reviewed)

    q =
      if reviewed_n > 0 do
        Enum.count(reviewed, & &1.first_round_approved?) / reviewed_n
      end

    {reviewed_n, q}
  end

  defp calc_run_metrics(tasks, n) do
    %{
      review_rounds: Enum.sum(for t <- tasks, do: t.review_rounds) / n,
      fix_passes: Enum.sum(for t <- tasks, do: t.fix_passes) / n,
      attempts: Enum.sum(for t <- tasks, do: t.attempts) / n,
      difficulty_raised: Enum.count(tasks, & &1.difficulty_raised?) / n
    }
  end

  defp calc_time_and_cost(tasks) do
    times = for t <- tasks, is_number(t.hours_to_close), do: t.hours_to_close * 1.0
    costs = for t <- tasks, is_number(t.cost_usd), do: t.cost_usd * 1.0

    %{
      med_time: median(times),
      mean_time: winsorized_mean(times, @winsorize_quantile),
      med_cost: median(costs),
      mean_cost: mean(costs)
    }
  end

  defp winsorized_mean([], _q), do: nil

  defp winsorized_mean(values, quantile) do
    sorted = Enum.sort(values)
    len = length(sorted)
    clamp_count = max(1, round(len * (1.0 - quantile)))
    cap_idx = max(0, len - 1 - clamp_count)
    cap = Enum.at(sorted, cap_idx)

    capped = for v <- sorted, do: min(v, cap)
    Enum.sum(capped) / len
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    len = length(sorted)
    mid = div(len, 2)

    if rem(len, 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp round1(nil), do: nil
  defp round1(n), do: Float.round(n * 1.0, 1)

  defp round2(nil), do: nil
  defp round2(n), do: Float.round(n * 1.0, 2)
end
