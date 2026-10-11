defmodule Mix.Tasks.Arbiter.ReplayReportTest do
  # Same reasoning as arbiter_backfill_issue_repos_test.exs: a static assertion
  # that the task delegates to the release-callable report (repo only) rather
  # than booting the full application (bd-c7lx65, R15).
  use ExUnit.Case, async: true

  @source File.read!("lib/mix/tasks/arbiter.replay_report.ex")
  @run_body Regex.run(~r/def run\(argv\) do(.*?)\n  end/s, @source) |> Enum.at(1)

  test "does not boot the full application" do
    refute @run_body =~ "app.start", "must not call Mix.Task.run(\"app.start\")"

    assert @run_body =~ "Arbiter.Release.replay_report(",
           "must delegate to the release-callable report"

    assert @run_body =~ "Arbiter.Release.replay_candidates(",
           "must delegate to the release-callable candidate list"
  end

  test "documents the release invocations, and that a replay itself runs in the live node" do
    assert @source =~ "bin/arbiter eval 'Arbiter.Release.replay_report()'"
    assert @source =~ "bin/arbiter rpc 'Arbiter.Release.replay("
  end
end
