defmodule Mix.Tasks.Arbiter.BackfillTicketTransitions do
  @shortdoc "Replay the paper trail into ticket_transitions"
  @moduledoc """
  Backfill `ticket_transitions` (bd-d8fi92) for every ticket whose history
  predates the live triggers, by replaying its `issues_versions` across the
  three eras. See `Arbiter.Tasks.TicketTransitionBackfill` for the rules and
  `Arbiter.Tasks.Lifecycle.History` for the mapping.

  ## Usage

      mix arbiter.backfill_ticket_transitions          # dry-run (default)
      mix arbiter.backfill_ticket_transitions --apply  # write the rows

  The dry run is the check: mismatches against the stored state, unmapped
  values, illegal transitions and the CFD invariant on sample days.
  Idempotent: a ticket whose history has started is skipped, so a second
  `--apply` inserts nothing. The primary instance also applies it on boot.

  ## Release installs

  A thin CLI wrapper over `Arbiter.Release.backfill/2`:

      bin/arbiter eval 'Arbiter.Release.backfill(:ticket_transitions)'             # dry-run
      bin/arbiter eval 'Arbiter.Release.backfill(:ticket_transitions, apply?: true)'
  """

  use Mix.Task

  @switches [apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, switches: @switches)

    Mix.Task.run("app.config")

    Arbiter.Release.backfill(:ticket_transitions, apply?: opts[:apply] == true, hint: "--apply")
  end
end
