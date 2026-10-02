defmodule Arbiter.Workers.OutputOffload do
  @moduledoc """
  Retention policy for the two bulky per-run output columns (bd-6jcebm, from
  the bd-91rxi7 perf audit): `worker_runs.output_lines` and
  `worker_run_steps.output_summary`.

  Measured 2026-10-01 on the live DB (715 MB): `output_lines` 173 MB across
  6,010 runs, `output_summary` 163 MB across 171,480 steps — and the step
  column alone grew 135 MB in September. Together they are most of the file,
  they dominate snapshot/backup time, and nothing on a hot path reads them for
  an old run.

  ## The decision: offload to the files that already exist, never delete

  Both columns are *renderings* of something Arbiter already keeps on disk
  under `Arbiter.Worker.OutputLog.root/0`:

    * `output_lines` is the 500-line tail of `<run_id>.log` — the uncapped
      rendered transcript. The file is a strict superset.
    * `output_summary` is the first 2,000 characters of one tool result, which
      the gzipped session JSONL `<run_id>.jsonl.gz`
      (`Arbiter.Worker.SessionArchive`) holds in full.

  So the policy is **verified offload**: once a finished run is older than
  `:retention_days`, its column is cleared *only if* the on-disk counterpart
  exists and is non-empty. A run with no file keeps its column (counted as
  `*_no_file` in the report), so no information is ever destroyed — only moved
  out of the hot SQLite file. Pure time-based pruning was rejected because
  ~32% of `output_lines` bytes belong to runs with no `.log` (non-session runs,
  and the pre-2026-06-20 corpus), and for those the column is the only copy.
  Keep-last-N-per-task was rejected as it keeps the biggest, most active
  tasks' bytes and gains nothing over age. Compression was rejected because
  the bytes are already on disk compressed, and SQLite cannot page a
  compressed column cheaply.

  ## What is deliberately kept

    * Step rows themselves (name, duration, `is_error`, digests, summaries of
      the *input*) — the analytics (`Arbiter.Workers.StepStats`) never needed
      the output.
    * `output_summary` of **git-shaped steps** (`input_summary LIKE '%git%'`,
      ~21 MB). `Arbiter.Loop.Corpus` reads those to tell whether a fix pass
      committed or pushed, across the whole corpus.
    * `output_summary` of the **last 8 steps of every `fix_pass` run**.
      `Arbiter.Loop.Corpus.last_step_outputs/1` feeds them, unfiltered, to
      `FixPassClassifier.final_summary/2`, which uses them to recognise
      tool-result bodies in the transcript tail of older, untagged runs. Clearing
      them would leak tool-result text into the summary the classifier sees.
      Keep the `8` below in step with `@summary_step_outputs` in the corpus.
    * Everything within the retention window, so the fix-pass classifier and
      live dashboards see no change for recent runs.

  Readers of an offloaded `output_lines` fall back to the transcript tail:
  `transcript_tail/1`. `Arbiter.Worker.ReviewGate` transcript recovery already
  reads the durable files and is unaffected.

  ## Operating it

  `Arbiter.Workers.OutputOffload` is a supervised sweeper (daily, primary
  instance only) that **ships OFF** (operator ruling, bd-16ljft): it sweeps
  nothing until the installation setting `output_offload_enabled` is `true`
  (`arb settings set output_offload_enabled true`, `/settings`, or the coordinator
  MCP tool `installation_config_set` with value `true`/`null`). The setting
  is read on every tick, so flipping it needs no restart; unsetting turns it
  back off.

  To see what it would do first, run the dry-run report on a release:

      bin/arbiter eval 'Arbiter.Release.offload_report()'              # writes nothing
      bin/arbiter eval 'Arbiter.Release.offload_report(apply: true)'   # one manual sweep

  `mix arbiter.offload_run_output` is the Mix equivalent (dry by default). The
  sweep is idempotent and re-runnable.

  SQLite does **not** shrink the file when rows are cleared — the freed pages
  are reused by new writes, which is what stops growth. To return the space to
  the OS (and make backups smaller) run `VACUUM` once on a quiet install; it
  needs free disk roughly equal to the DB size.

  ## Configuration

  Via `config :arbiter, :output_offload`:

    * `:enabled`          — test override. Unset (the normal case) defers to
                            the installation setting; `true` / `false` force it.
    * `:interval_ms`      — sweep cadence (default 24 h).
    * `:initial_delay_ms` — delay before the first sweep after boot (10 min).
    * `:retention_days`   — age of `completed_at` / `occurred_at` past which a
                            column may be offloaded (default 14).
  """

  use GenServer

  require Logger

  alias Arbiter.Repo
  alias Arbiter.SingleInstance
  alias Arbiter.Worker.{OutputLog, SessionArchive}

  @default_interval_ms 24 * 60 * 60_000
  @default_initial_delay_ms 10 * 60_000
  @default_retention_days 14
  @page 500

  @type report :: %{
          apply?: boolean(),
          lines_scanned: non_neg_integer(),
          lines_offloaded: non_neg_integer(),
          lines_bytes: non_neg_integer(),
          lines_no_file: non_neg_integer(),
          steps_runs_scanned: non_neg_integer(),
          steps_offloaded: non_neg_integer(),
          steps_bytes: non_neg_integer(),
          steps_runs_no_file: non_neg_integer()
        }

  @doc """
  Run one sweep and return a `t:report/0`.

  Options: `:apply?` (default `true`; `false` reports without writing),
  `:retention_days`, `:now` (a `DateTime`, for tests).
  """
  @spec sweep(keyword()) :: report()
  def sweep(opts \\ []) do
    apply? = Keyword.get(opts, :apply?, true)
    days = Keyword.get(opts, :retention_days, cfg(:retention_days, @default_retention_days))
    now = Keyword.get(opts, :now, DateTime.utc_now())
    cutoff = now |> DateTime.add(-days, :day) |> DateTime.to_iso8601()

    %{
      apply?: apply?,
      lines_scanned: 0,
      lines_offloaded: 0,
      lines_bytes: 0,
      lines_no_file: 0,
      steps_runs_scanned: 0,
      steps_offloaded: 0,
      steps_bytes: 0,
      steps_runs_no_file: 0
    }
    |> offload_lines(cutoff, apply?, "")
    |> offload_steps(cutoff, apply?, "")
  end

  @doc """
  A run's output lines for display: the `output_lines` column, or — when that
  column is empty on a finished run (offloaded here, or never captured) — the
  durable transcript's tail. A run still working keeps its (empty) column: its
  `.log` is mid-write and the live feed owns that view.
  """
  @spec output_lines(map()) :: [String.t()]
  def output_lines(%{output_lines: [_ | _] = lines}), do: lines

  def output_lines(%{id: id, state: state}) when state in [:finished, "finished"],
    do: transcript_tail(id)

  def output_lines(_run), do: []

  @doc """
  The last `n` lines (default 500, the cap `output_lines` was written with) of
  a run's durable transcript, or `[]` when there is none. The read-side
  fallback for a run whose `output_lines` column has been offloaded.
  """
  @spec transcript_tail(String.t() | nil, pos_integer()) :: [String.t()]
  def transcript_tail(run_id, n \\ 500)
  def transcript_tail(nil, _n), do: []

  def transcript_tail(run_id, n) do
    case OutputLog.tail_lines(run_id, n) do
      {:ok, lines} -> lines
      {:error, _} -> []
    end
  end

  # ---- output_lines ------------------------------------------------------------

  # `length(output_lines) > 2` skips the `"[]"` an offloaded (or empty) row
  # holds, without a separate marker column. Paged by id so a page of
  # permanently-unfixable runs (no `.log`) cannot starve the ones after it.
  defp offload_lines(report, cutoff, apply?, after_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT id, length(output_lines) FROM worker_runs
        WHERE state = 'finished' AND completed_at < ?1
          AND length(output_lines) > 2 AND id > ?2
        ORDER BY id LIMIT #{@page}
        """,
        [cutoff, after_id]
      )

    case rows do
      [] ->
        report

      _ ->
        report = Enum.reduce(rows, report, &offload_run_lines(&1, &2, apply?))

        [last_id, _] = List.last(rows)
        offload_lines(report, cutoff, apply?, last_id)
    end
  end

  defp offload_run_lines([id, bytes], acc, apply?) do
    acc = %{acc | lines_scanned: acc.lines_scanned + 1}

    if file_present?(OutputLog.path_for(id)) do
      if apply?, do: Repo.query!("UPDATE worker_runs SET output_lines = '[]' WHERE id = ?1", [id])
      %{acc | lines_offloaded: acc.lines_offloaded + 1, lines_bytes: acc.lines_bytes + bytes}
    else
      %{acc | lines_no_file: acc.lines_no_file + 1}
    end
  end

  # ---- output_summary ----------------------------------------------------------

  @git_free "(input_summary IS NULL OR input_summary NOT LIKE '%git%')"

  defp offload_steps(report, cutoff, apply?, after_run) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT run_id FROM worker_run_steps
        WHERE occurred_at < ?1 AND output_summary IS NOT NULL AND output_summary <> ''
          AND #{@git_free} AND run_id > ?2
        ORDER BY run_id LIMIT #{@page}
        """,
        [cutoff, after_run]
      )

    case rows do
      [] ->
        report

      _ ->
        report =
          Enum.reduce(rows, report, fn [run_id], acc ->
            acc = %{acc | steps_runs_scanned: acc.steps_runs_scanned + 1}

            if file_present?(SessionArchive.path_for(run_id)) do
              offload_run_steps(acc, run_id, cutoff, apply?)
            else
              %{acc | steps_runs_no_file: acc.steps_runs_no_file + 1}
            end
          end)

        [last] = List.last(rows)
        offload_steps(report, cutoff, apply?, last)
    end
  end

  # The last 8 steps (by `occurred_at`, as the corpus orders them) of a
  # `fix_pass` run stay: `Arbiter.Loop.Corpus` reads their `output_summary`.
  @fix_pass_tail "id NOT IN (SELECT id FROM worker_run_steps WHERE run_id = ?1 " <>
                   "AND (SELECT kind FROM worker_runs WHERE id = ?1) = 'fix_pass' " <>
                   "ORDER BY occurred_at DESC LIMIT 8)"

  @step_where "run_id = ?1 AND occurred_at < ?2 AND output_summary IS NOT NULL " <>
                "AND #{@git_free} AND #{@fix_pass_tail}"

  defp offload_run_steps(acc, run_id, cutoff, apply?) do
    %{rows: [[count, bytes]]} =
      Repo.query!(
        """
        SELECT count(*), coalesce(sum(length(output_summary)), 0)
        FROM worker_run_steps WHERE #{@step_where}
        """,
        [run_id, cutoff]
      )

    if apply? and count > 0 do
      Repo.query!(
        "UPDATE worker_run_steps SET output_summary = NULL WHERE #{@step_where}",
        [run_id, cutoff]
      )
    end

    %{acc | steps_offloaded: acc.steps_offloaded + count, steps_bytes: acc.steps_bytes + bytes}
  end

  defp file_present?(path) do
    match?({:ok, %File.Stat{type: :regular, size: size}} when size > 0, File.stat(path))
  end

  # ---- GenServer ---------------------------------------------------------------

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    state = %{
      override: cfg_opt(:enabled, opts, nil),
      interval_ms: cfg_opt(:interval_ms, opts, @default_interval_ms),
      primary?: Keyword.get(opts, :primary?, &SingleInstance.primary?/0)
    }

    if state.override != false do
      Process.send_after(
        self(),
        :sweep,
        cfg_opt(:initial_delay_ms, opts, @default_initial_delay_ms)
      )
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    if enabled?(state) and state.primary?.(), do: run_sweep()
    Process.send_after(self(), :sweep, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Off unless an operator switched it on (bd-16ljft). Read on every tick, so
  # flipping the installation setting takes effect with no restart.
  defp enabled?(%{override: nil}), do: Arbiter.Settings.output_offload_enabled() == true
  defp enabled?(%{override: override}), do: override == true

  defp run_sweep do
    report = sweep()

    Logger.info(
      "Arbiter.Workers.OutputOffload: output_lines offloaded=#{report.lines_offloaded} " <>
        "(#{report.lines_bytes} B, #{report.lines_no_file} kept: no .log); " <>
        "output_summary offloaded=#{report.steps_offloaded} (#{report.steps_bytes} B, " <>
        "#{report.steps_runs_no_file} runs kept: no archive)"
    )
  rescue
    e -> Logger.error("Arbiter.Workers.OutputOffload sweep failed: #{Exception.message(e)}")
  end

  defp cfg_opt(key, opts, default) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> cfg(key, default)
    end
  end

  defp cfg(key, default) do
    case get_in(Application.get_env(:arbiter, :output_offload, []), [key]) do
      nil -> default
      val -> val
    end
  end
end
