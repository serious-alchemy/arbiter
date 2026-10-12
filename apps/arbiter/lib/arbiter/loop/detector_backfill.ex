defmodule Arbiter.Loop.DetectorBackfill do
  @moduledoc """
  Stage 2 of the loop discovery pass (bd-8u2aqn,
  `docs/design/loop-inference-discovery-pass.md` §"Implementation issues" 3):
  run a **newly merged** `@finding_buckets` detector over the reviewer findings
  Stage 0 retained, so its first `PendingWrite` carries measured historical
  evidence instead of starting from zero.

  ## What this is not

  There is no model call here and no auto-merge path. Admission is a reviewed
  pull request that adds a `{regex, category}` tuple to
  `Arbiter.Loop.FindingBuckets` (and, for a new category, its attribution row —
  the module refuses to compile without one). That a human merged the regex is
  the whole safety argument of the design doc (§2, §5). This module only runs
  *after* that merge, over code that is already deterministic; nothing a model
  emits can reach `run/2` — its only inputs are a category string that must
  already be in the compiled allowlist, and the stored review rounds.

  ## Why no new fingerprint machinery

  The merged detector's `category` is a compile-time constant, so
  `Arbiter.Loop.fingerprint/1` is stable across windows and the backfill
  records through the ordinary `Arbiter.Loop.record/2` path via
  `Arbiter.Loop.Proposals.record_all/2`.

  ## Idempotence

  `record/2` unions `incident_refs` / `task_refs` into the existing row and
  recomputes the counts from the union. Re-running the backfill (or running it
  after ordinary windows have already reinforced the row) never inserts a
  second row and never changes counts for evidence it has already seen.

  ## Retention bound

  The backfill can reach only:

    * review rounds newer than `retention_days/0` (28 days — four of the
      default seven-day analysis windows, the same four the discovery pass
      checks a candidate against). A caller's `:since` older than that is
      clamped, and the report says so (`clamped?: true`).
    * at most `unit_limit/0` matching units (1200 — the per-window
      `Arbiter.Loop.Corpus.residue_retention_limit/0` of 300 times those four
      windows), newest first. A caller's `:unit_limit` above it is capped;
      truncation is reported (`truncated?: true`).

  Older evidence is not reachable and is not reconstructed: the detector earns
  it forward through ordinary windows.

  ## Running it

  See `Arbiter.Release.backfill(:finding_detector, ...)` and the "Admitting an
  accepted detector" recipe in `docs/design/loop-inference-discovery-pass.md`.
  """

  alias Arbiter.Loop.{Analysis, Corpus, FindingBuckets, Proposals, Report}

  @retention_days 28
  @unit_limit 1200

  @type result :: %{
          category: String.t(),
          since: DateTime.t(),
          until: DateTime.t(),
          units: non_neg_integer(),
          tasks: non_neg_integer(),
          clamped?: boolean(),
          truncated?: boolean(),
          unit_limit: pos_integer(),
          applied?: boolean(),
          rows: [Arbiter.Loop.PendingWrite.t()],
          dropped: [map()]
        }

  @doc "How far back, in days, the backfill can reach."
  @spec retention_days() :: pos_integer()
  def retention_days, do: @retention_days

  @doc "The most units one backfill reads."
  @spec unit_limit() :: pos_integer()
  def unit_limit, do: @unit_limit

  @doc """
  Backfill `category` over the retained review rounds.

  Options: `:apply?` (default `false` — a dry run that reports the reach and
  writes nothing), `:since` / `:unit_limit` (both clamped to the retention
  bound), `:now`, `:workspace_id`, `:evidence_bar`, and `:buckets` (the
  allowlist, default `FindingBuckets.buckets/0`; tests pass a fixture detector).

  Returns `{:error, :unknown_category}` when no bucket produces `category`.
  """
  @spec run(String.t(), keyword()) :: {:ok, result()} | {:error, :unknown_category}
  def run(category, opts \\ []) when is_binary(category) do
    buckets = Keyword.get(opts, :buckets, FindingBuckets.buckets())

    if Enum.any?(buckets, fn {_re, cat} -> cat == category end) do
      {:ok, backfill(category, buckets, opts)}
    else
      {:error, :unknown_category}
    end
  end

  defp backfill(category, buckets, opts) do
    until = Keyword.get(opts, :now) || DateTime.utc_now()
    floor = DateTime.add(until, -@retention_days * 86_400, :second)
    requested = Keyword.get(opts, :since) || floor
    since = if DateTime.compare(requested, floor) == :lt, do: floor, else: requested
    limit = opts |> Keyword.get(:unit_limit, @unit_limit) |> min(@unit_limit)

    # One over the limit, so "exactly at the limit" is distinguishable from
    # "cut off by it".
    fetched = Corpus.category_units(since, until, category, buckets, limit + 1)
    units = Enum.take(fetched, limit)
    apply? = Keyword.get(opts, :apply?, false)

    %{rows: rows, dropped: dropped} =
      if apply? and units != [],
        do: record(category, units, until, opts),
        else: %{rows: [], dropped: []}

    %{
      category: category,
      since: since,
      until: until,
      units: length(units),
      tasks: units |> Enum.map(& &1.task_id) |> Enum.uniq() |> length(),
      clamped?: DateTime.compare(requested, floor) == :lt,
      truncated?: length(fetched) > limit,
      unit_limit: limit,
      applied?: apply?,
      rows: rows,
      dropped: dropped
    }
  end

  # Mirrors `Analysis.finding_categories/1`: one entry per task (a task's
  # finding is one incident), run ids as the incident refs.
  defp record(category, units, until, opts) do
    by_task = Enum.uniq_by(units, & &1.task_id)

    cat = %{
      category: category,
      incidents: length(by_task),
      tasks: Enum.map(by_task, & &1.task_id),
      run_ids: by_task |> Enum.map(& &1.run_id) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      example: hd(units).text
    }

    suggestion_opts = Keyword.take(opts, [:evidence_bar])

    report = %Report{
      window: %{label: "detector backfill", since: nil, until: until},
      totals: %{},
      finding_categories: [cat],
      suggestions: Analysis.finding_suggestions([cat], suggestion_opts)
    }

    Proposals.record_all(
      report,
      Keyword.take(opts, [:workspace_id, :evidence_bar]) ++ [origin: "loop.detector_backfill"]
    )
  end
end
