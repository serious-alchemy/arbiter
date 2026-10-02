defmodule Mix.Tasks.Arbiter.OffloadRunOutput do
  @shortdoc "Clear old runs' output_lines / output_summary once their on-disk copy is verified"
  @moduledoc """
  One pass of `Arbiter.Workers.OutputOffload` (bd-6jcebm): clears
  `worker_runs.output_lines` and `worker_run_steps.output_summary` for runs
  older than the retention window, **only** where the durable transcript
  (`<run_id>.log`) or session archive (`<run_id>.jsonl.gz`) exists on disk.
  Nothing without an on-disk copy is touched.

  ## Usage

      mix arbiter.offload_run_output                   # dry-run (default)
      mix arbiter.offload_run_output --apply           # write
      mix arbiter.offload_run_output --days 30 --apply # a longer window

  The server runs the same sweep daily; this is for the first catch-up pass
  and for inspecting the effect without writing. SQLite keeps the freed pages
  for reuse — run `VACUUM` once on a quiet install to shrink the file. See the
  `Arbiter.Workers.OutputOffload` moduledoc for the policy and what is kept.
  """

  use Mix.Task

  alias Arbiter.Workers.OutputOffload

  @switches [apply: :boolean, days: :integer]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    apply? = opts[:apply] == true

    # Config + the Repo only: `app.start` would boot a second endpoint and a
    # second set of patrols beside the live coordinator, on the same SQLite file.
    Mix.Task.run("app.config")

    Mix.shell().info(
      if apply?,
        do: "Offloading run output to its on-disk copies (writing)…",
        else: "Offloading run output — DRY RUN, no writes. Re-run with --apply.\n"
    )

    sweep_opts =
      [apply?: apply?]
      |> then(fn o ->
        if opts[:days], do: Keyword.put(o, :retention_days, opts[:days]), else: o
      end)

    {:ok, report, _started} =
      Ecto.Migrator.with_repo(Arbiter.Repo, fn _repo -> OutputOffload.sweep(sweep_opts) end,
        pool_size: 1
      )

    report |> report() |> Mix.shell().info()
  end

  @doc false
  def report(r) do
    verb = if r.apply?, do: "offloaded", else: "would offload"

    """

    output_lines
      runs scanned:         #{r.lines_scanned}
      runs #{String.pad_trailing(verb <> ":", 16)}#{r.lines_offloaded}   (#{human(r.lines_bytes)})
      kept, no .log file:   #{r.lines_no_file}
    output_summary
      runs scanned:         #{r.steps_runs_scanned}
      steps #{String.pad_trailing(verb <> ":", 15)}#{r.steps_offloaded}   (#{human(r.steps_bytes)})
      runs kept, no archive: #{r.steps_runs_no_file}
    """
  end

  defp human(n) when n >= 1_048_576, do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp human(n) when n >= 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp human(n), do: "#{n} B"
end
