defmodule Arbiter.Workflows.MergeQueue.FixPassPromptCiTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Issue
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  defp prompt(checks) do
    FixPassDispatcher.prompt_for(%{
      task: %Issue{id: "bd-fixture"},
      branch: "feature/fixture",
      target_branch: "main",
      checks: checks
    })
  end

  test "the briefing states the final CI status, failing jobs, excerpt and full-log path" do
    text =
      prompt([
        %{name: "mix test", summary: "1) test boom (Foo)", log_path: "/var/ci/job-9.log"},
        %{name: "format", summary: ""}
      ])

    assert text =~ "Final CI status: FAILED (failing jobs: mix test, format)"
    assert text =~ "1) test boom (Foo)"
    assert text =~ "full log: /var/ci/job-9.log"
  end

  test "the briefing forbids polling CI and says Arbiter re-runs and watches it" do
    text = prompt([%{name: "mix test", summary: "x"}])

    assert text =~ "Do NOT poll CI"
    assert text =~ "gh run watch"
    assert text =~ "Arbiter re-runs and watches CI"
  end
end
