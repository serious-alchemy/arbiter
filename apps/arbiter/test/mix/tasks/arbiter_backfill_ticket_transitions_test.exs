defmodule Mix.Tasks.Arbiter.BackfillTicketTransitionsTest do
  # A thin CLI wrapper over Arbiter.Release.backfill/2 (bd-d8fi92), which
  # starts only Ash + the Repo — never a second full Arbiter beside a live one.
  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/arbiter.backfill_ticket_transitions.ex")
  @run_body Regex.run(~r/def run\(argv\) do(.*?)\n  end/s, @source) |> Enum.at(1)

  test "does not boot the full application" do
    refute @run_body =~ "app.start", "must not call Mix.Task.run(\"app.start\")"

    assert @run_body =~ "Arbiter.Release.backfill(:ticket_transitions",
           "must delegate to the release-callable backfill"
  end

  test "documents the release eval invocation" do
    assert @source =~ "bin/arbiter eval"
    assert @source =~ "Arbiter.Release.backfill(:ticket_transitions"
  end
end
