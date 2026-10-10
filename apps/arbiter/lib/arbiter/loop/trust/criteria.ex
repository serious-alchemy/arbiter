defmodule Arbiter.Loop.Trust.Criteria do
  @moduledoc """
  The pure half of `Arbiter.Loop.Trust` (G18, `docs/design/guardrail-profiles.md`
  §6.2–6.3): what makes a run clean, a subject's window counts and round-1
  quality, and the thresholds a promotion proposal needs.

  ## A clean run (§6.2)

  A **main implementer run** (`kind = implement`, role `base`) is clean when:

    * its ticket's first ReviewGate round approved — read from
      `Arbiter.Loop.SubjectStats` (`first_round_approved?`), so the ticket must
      be closed as completed;
    * it has no critical or major guardrail event;
    * it raised no misbehaviour escalation: it did not stop as a stuck worker
      (`stalled`), did not tamper with its clone, and did not fail the notes gate.
      Fabricated evidence is a critical event on the run, so the event rule
      already covers it. Quota holds and permission requests do not count;
    * it stayed under its spend cap (no `spend_cap` stop).

  ## Moving up (§6.3)

  | from | to | needs |
  |---|---|---|
  | `quarantine` | `probation` | ≥ 10 clean runs on ≥ 7 tickets; 0 critical or major events in the window; round-1 approve rate at D0–D1 no more than 10 points below the incumbent's, each over ≥ 10 reviewed tickets |
  | `probation` | `trusted` | ≥ 20 clean runs across ≥ 2 repos; ≥ 21 days at probation; 0 critical or major events; the same quality bar at D2 |
  | `trusted` | `privileged` | never proposed: the Loop only reports the record |

  Runs and quality count from the **promotion clock**: the later of the window's
  start and `clock_started_at` (a tier change or a version change resets it).
  Events count over the whole window: a reset clock never forgets an event.

  The **incumbent** at a band is the other subject with ≥ 10 reviewed tickets
  there, highest tier first, then most reviewed. With none, the quality bar is
  unmet: a promotion is never proposed on missing evidence.
  """

  alias Arbiter.Guardrails

  @misbehaviour_stops ~w(stalled tampered_clone)
  @bands %{"d0_1" => [0, 1], "d2" => [2]}
  @min_reviewed 10
  @quality_margin 0.10

  @moves %{
    quarantine: %{to: :probation, clean_runs: 10, clean_tickets: 7, band: "d0_1"},
    probation: %{to: :trusted, clean_runs: 20, clean_repos: 2, days_at_tier: 21, band: "d2"}
  }

  @doc "The difficulty bands round-1 quality is measured at."
  @spec bands() :: %{String.t() => [non_neg_integer()]}
  def bands, do: @bands

  @doc "The §6.3 thresholds for a move out of `tier`, or `nil` when the Loop never proposes one."
  @spec move(atom() | nil) :: map() | nil
  def move(tier), do: Map.get(@moves, tier)

  # ---- clean runs ---------------------------------------------------------------

  @doc "Whether a run is a main implementer run: `kind = implement`, role `base`."
  @spec main_run?(map()) :: boolean()
  def main_run?(%{kind: "implement", role: role}) when role in [nil, "base"], do: true
  def main_run?(_run), do: false

  @doc """
  Whether `run` is clean (§6.2). `approved` is the set of tickets whose first
  ReviewGate round approved; `flagged` the set of run ids with a critical or
  major event.
  """
  @spec clean?(map(), MapSet.t(), MapSet.t()) :: boolean()
  def clean?(run, approved, flagged) do
    MapSet.member?(approved, run.task_id) and not MapSet.member?(flagged, run.id) and
      not misbehaved?(run) and run.stop_category != "spend_cap"
  end

  @doc "A stuck worker, a tampered clone, or a notes-gate failure."
  @spec misbehaved?(map()) :: boolean()
  def misbehaved?(run) do
    run.stop_category in @misbehaviour_stops or notes_gate_failure?(run.failure_reason)
  end

  # `Arbiter.Worker`'s notes-gate park writes one of these two reasons.
  defp notes_gate_failure?(reason) when is_binary(reason),
    do:
      String.contains?(reason, "blank_notes_at_completion") or
        String.starts_with?(reason, "strict policy denied")

  defp notes_gate_failure?(_), do: false

  @doc """
  The run counts for one subject: its main implementer runs started at or after
  `clock` and how many are clean, on how many tickets and repos.
  """
  @spec run_counts([map()], [map()], [map()], DateTime.t()) :: map()
  def run_counts(runs, events, tasks, clock) do
    approved = for t <- tasks, t.first_round_approved? == true, into: MapSet.new(), do: t.task_id

    flagged =
      for e <- events, e.severity in ["critical", "major"], e.run_id, into: MapSet.new(),
        do: e.run_id

    main = Enum.filter(runs, &(main_run?(&1) and at_or_after?(&1.started_at, clock)))
    clean = Enum.filter(main, &clean?(&1, approved, flagged))

    %{
      runs: length(main),
      clean_runs: length(clean),
      clean_tickets: clean |> Enum.map(& &1.task_id) |> Enum.uniq() |> length(),
      clean_repos: clean |> Enum.map(& &1.repo) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length(),
      clean_run_ids: Enum.map(clean, & &1.id),
      clean_task_ids: clean |> Enum.map(& &1.task_id) |> Enum.uniq()
    }
  end

  @doc "Event counts by severity: `{critical, major, minor}`."
  @spec event_counts([map()]) :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def event_counts(events) do
    by = Enum.frequencies_by(events, & &1.severity)
    {Map.get(by, "critical", 0), Map.get(by, "major", 0), Map.get(by, "minor", 0)}
  end

  # ---- quality --------------------------------------------------------------------

  @doc """
  Round-1 quality over SubjectStats tasks whose first attempt started at or after
  `clock`: `%{reviewed:, q:}` overall and per band (`"d0_1"`, `"d2"`), each
  band `%{"reviewed" => n, "approved" => k, "q" => q | nil}`.
  """
  @spec quality([map()], DateTime.t() | nil) :: %{
          reviewed: non_neg_integer(),
          q: float() | nil,
          bands: map()
        }
  def quality(tasks, clock) do
    reviewed = Enum.filter(tasks, &(&1.reviewed? and at_or_after?(&1.started_at, clock)))

    %{
      reviewed: length(reviewed),
      q: rate(reviewed),
      bands:
        Map.new(@bands, fn {band, ds} ->
          in_band = Enum.filter(reviewed, &(&1.difficulty in ds))

          {band,
           %{
             "reviewed" => length(in_band),
             "approved" => Enum.count(in_band, & &1.first_round_approved?),
             "q" => rate(in_band)
           }}
        end)
    }
  end

  defp rate([]), do: nil
  defp rate(tasks), do: Enum.count(tasks, & &1.first_round_approved?) / length(tasks)

  @doc """
  The incumbents per band from every subject's whole-window quality:
  `%{band => [%{"subject" => key, "tier" => tier, "reviewed" => n, "q" => q}]}`,
  best first (highest tier, then most reviewed). Only subjects with at least
  ten reviewed tickets in the band qualify.
  """
  @spec incumbents([{String.t(), atom() | nil, map()}]) :: %{String.t() => [map()]}
  def incumbents(subjects) do
    Map.new(@bands, fn {band, _} ->
      ranked =
        subjects
        |> Enum.flat_map(fn {key, tier, quality} ->
          case quality.bands[band] do
            %{"reviewed" => n, "q" => q} when n >= @min_reviewed ->
              [%{"subject" => key, "tier" => tier && to_string(tier), "reviewed" => n, "q" => q}]

            _ ->
              []
          end
        end)
        |> Enum.sort_by(&{-tier_rank(&1["tier"]), -&1["reviewed"], &1["subject"]})

      {band, ranked}
    end)
  end

  defp tier_rank(nil), do: -1
  defp tier_rank(tier), do: Guardrails.tier_rank(String.to_existing_atom(tier))

  # ---- eligibility ------------------------------------------------------------------

  @doc """
  The §6.3 verdict for a subject at `tier`: `{eligible_for, eligibility}`.
  `facts` carries the record's counts plus `:key`, `:quality`, `:days_at_tier`,
  `:pinned`, `:suspended` and `:incumbents` (from `incumbents/1`).
  """
  @spec eligibility(atom() | nil, map()) :: {atom() | nil, map()}
  def eligibility(nil, _facts),
    do: {nil, %{"note" => "no subject rule is configured: guardrails are off"}}

  def eligibility(:trusted, _facts) do
    {nil,
     %{
       "from" => "trusted",
       "to" => "privileged",
       "proposed" => false,
       "criteria" => [],
       "note" =>
         "never proposed by the Loop: privileged grants prod reach, so only the operator " <>
           "promotes (`arb trust promote`)"
     }}
  end

  def eligibility(:privileged, _facts),
    do:
      {nil, %{"from" => "privileged", "to" => nil, "criteria" => [], "note" => "the top tier"}}

  def eligibility(tier, facts) do
    move = Map.fetch!(@moves, tier)
    criteria = criteria(move, facts)

    blocked_by =
      cond do
        facts.suspended -> "suspended"
        facts.pinned -> "pinned"
        true -> nil
      end

    eligible? = blocked_by == nil and Enum.all?(criteria, & &1["met"])

    {if(eligible?, do: move.to),
     %{
       "from" => Atom.to_string(tier),
       "to" => Atom.to_string(move.to),
       "proposed" => eligible?,
       "blocked_by" => blocked_by,
       "criteria" => criteria
     }}
  end

  defp criteria(move, facts) do
    [
      count("clean_runs", move.clean_runs, facts.clean_runs),
      move[:clean_tickets] && count("clean_tickets", move.clean_tickets, facts.clean_tickets),
      move[:clean_repos] && count("clean_repos", move.clean_repos, facts.clean_repos),
      move[:days_at_tier] && count("days_at_tier", move.days_at_tier, facts.days_at_tier),
      %{
        "name" => "no_critical_or_major",
        "need" => 0,
        "have" => facts.critical_events + facts.major_events,
        "met" => facts.critical_events + facts.major_events == 0
      },
      quality_bar(move.band, facts)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp count(name, need, have),
    do: %{"name" => name, "need" => need, "have" => have, "met" => have >= need}

  defp quality_bar(band, facts) do
    own = facts.quality.bands[band]
    incumbent = facts.incumbents |> Map.get(band, []) |> Enum.find(&(&1["subject"] != facts.key))

    {met, detail} =
      cond do
        own["reviewed"] < @min_reviewed ->
          {false, "#{own["reviewed"]} reviewed ticket(s) at #{label(band)}; needs #{@min_reviewed}"}

        incumbent == nil ->
          {false, "no incumbent subject has #{@min_reviewed} reviewed tickets at #{label(band)}"}

        own["q"] + @quality_margin + 1.0e-9 >= incumbent["q"] ->
          {true, "#{pct(own["q"])} vs the incumbent's #{pct(incumbent["q"])}"}

        true ->
          {false,
           "#{pct(own["q"])} is more than 10 points below the incumbent's #{pct(incumbent["q"])}"}
      end

    %{
      "name" => "round1_quality",
      "band" => band,
      "have" => own["q"],
      "reviewed" => own["reviewed"],
      "incumbent" => incumbent,
      "met" => met,
      "detail" => detail
    }
  end

  defp label("d0_1"), do: "D0–D1"
  defp label("d2"), do: "D2"

  defp pct(q), do: "#{Float.round(q * 100, 1)}%"

  defp at_or_after?(_dt, nil), do: true
  defp at_or_after?(nil, _clock), do: false
  defp at_or_after?(dt, clock), do: DateTime.compare(dt, clock) != :lt
end
