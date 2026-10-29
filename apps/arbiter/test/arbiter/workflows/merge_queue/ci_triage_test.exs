defmodule Arbiter.Workflows.MergeQueue.CiTriageTest do
  # GitHub #1144: of 127 fix passes in 14 days only ~21 changed code. The triage
  # sorts a red head into infra / unrelated_tests / target_red / needs_agent
  # before an agent is spawned, and anything it cannot read is needs_agent.
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.CiTriage

  @drain "apps/arbiter/test/arbiter/board/drain_test.exs"
  @coverage "apps/arbiter/test/arbiter/reviews/coverage_test.exs"
  @changed ["docs/guide.md", "apps/arbiter/lib/arbiter/worker/watchdog.ex"]

  defp verdicts(result), do: Enum.map(result.evidence, & &1.verdict)

  describe "infra (GitHub fixtures)" do
    test "a timed_out job is infra" do
      checks = [%{name: "test", conclusion: "timed_out", summary: "", files: []}]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :infra
      assert result.reason =~ "timed_out"
      assert [%{job: "test", verdict: :infra}] = result.evidence
    end

    test "a cancelled job is infra" do
      checks = [%{name: "test", conclusion: "cancelled", summary: "", files: []}]
      assert CiTriage.classify(checks, @changed).class == :infra
    end

    test "an unschedulable runner pod in the log is infra" do
      summary = "Pod arc-runner-x is unschedulable: 0/12 nodes are available: Insufficient cpu."
      checks = [%{name: "test", conclusion: "failure", summary: summary, files: []}]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :infra
      assert hd(result.evidence).detail =~ "unschedulable"
    end

    test "an OOM-killed job and a DB pool timeout are infra" do
      oom = %{name: "build", conclusion: "failure", summary: "Killed\nexit code 137", files: []}

      pool = %{
        name: "test",
        conclusion: "failure",
        summary:
          "** (DBConnection.ConnectionError) connection not available and request was dropped from queue after 2000ms",
        files: []
      }

      assert CiTriage.classify([oom], @changed).class == :infra
      assert CiTriage.classify([pool], @changed).class == :infra
    end

    test "an infra phrase beside a failing path in the diff is not trusted as infra" do
      summary = "Insufficient memory\napps/arbiter/lib/arbiter/worker/watchdog.ex:12 crashed"
      checks = [%{name: "test", conclusion: "failure", summary: summary, files: []}]

      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end

    test "a text-only infra signal cannot be trusted when the diff is unreadable" do
      summary = "0/12 nodes are available: Insufficient cpu."
      checks = [%{name: "test", conclusion: "failure", summary: summary, files: []}]

      assert CiTriage.classify(checks, :unknown).class == :needs_agent
    end
  end

  describe "infra (GitLab fixtures)" do
    for reason <-
          ~w(runner_system_failure stuck_or_timeout_failure job_execution_timeout scheduler_failure) do
      test "failure_reason #{reason} is infra, even with the diff unreadable" do
        checks = [%{name: "rspec", failure_reason: unquote(reason), summary: "", url: nil}]

        result = CiTriage.classify(checks, :unknown)

        assert result.class == :infra
        assert result.reason =~ unquote(reason)
      end
    end

    test "a canceled job is infra" do
      checks = [%{name: "rspec", status: "canceled", summary: "", url: nil}]
      assert CiTriage.classify(checks, @changed).class == :infra
    end

    test "a script_failure with no readable cause is NOT infra" do
      checks = [%{name: "rspec", failure_reason: "script_failure", summary: "", url: nil}]
      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end
  end

  describe "unrelated_tests" do
    test "GitHub: annotations name test files the diff does not touch" do
      checks = [
        %{name: "mix test", conclusion: "failure", summary: "", files: [@drain, @coverage]}
      ]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert result.reason =~ "not touch"
      assert [%{job: "mix test", verdict: :unrelated_test, files: files}] = result.evidence
      assert files == [@drain, @coverage]
    end

    test "GitLab: path:line references in the trace name only untouched test files" do
      summary = "1) test flaky (DrainTest)\n   test/arbiter/board/drain_test.exs:44\n   boom"

      checks = [
        %{name: "rspec", failure_reason: "script_failure", summary: summary, url: nil}
      ]

      assert %{class: :unrelated_tests} = CiTriage.classify(checks, @changed)
    end

    test "infra and unrelated tests together re-run too, naming both" do
      checks = [
        %{name: "build", conclusion: "timed_out", summary: "", files: []},
        %{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}
      ]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert Enum.sort(verdicts(result)) == [:infra, :unrelated_test]
    end
  end

  describe "needs_agent (the failure touches the diff)" do
    test "a failing test file the diff edits" do
      checks = [%{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}]
      changed = ["apps/arbiter/test/arbiter/board/drain_test.exs"]

      result = CiTriage.classify(checks, changed)

      assert result.class == :needs_agent
      assert [%{verdict: :touches_diff, files: [@drain]}] = result.evidence
    end

    test "the conventional subject module of a failing test is in the diff" do
      checks = [%{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}]
      changed = ["apps/arbiter/lib/arbiter/board/drain.ex"]

      result = CiTriage.classify(checks, changed)

      assert result.class == :needs_agent
      assert hd(result.evidence).detail =~ "drain.ex"
    end

    test "a stack frame in a changed source file" do
      summary =
        "1) test drains (DrainTest)\n   test/arbiter/board/drain_test.exs:9\n" <>
          "   (arbiter) lib/arbiter/worker/watchdog.ex:101: Watchdog.go/1"

      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end

    test "a compile error is never unrelated, whatever test path it prints" do
      summary =
        "** (CompileError) test/arbiter/board/drain_test.exs:3: undefined function foo/0"

      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end

    test "one infra job and one job touching the diff is needs_agent" do
      checks = [
        %{name: "build", failure_reason: "runner_system_failure", summary: "", url: nil},
        %{
          name: "mix test",
          conclusion: "failure",
          summary: "",
          files: ["apps/arbiter/test/arbiter/worker/watchdog_test.exs"]
        }
      ]

      changed = ["apps/arbiter/lib/arbiter/worker/watchdog.ex"]
      result = CiTriage.classify(checks, changed)

      assert result.class == :needs_agent
      assert Enum.sort(verdicts(result)) == [:infra, :touches_diff]
    end
  end

  describe "fail safe" do
    test "no failing-check data is needs_agent" do
      result = CiTriage.classify([], @changed)
      assert result.class == :needs_agent
      assert result.reason =~ "no failing-check"
    end

    test "a failure naming no test file (lint, format, build) is needs_agent" do
      checks = [
        %{name: "credo", conclusion: "failure", summary: "lib/x.ex:3 too deep", files: []}
      ]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :needs_agent
      assert [%{verdict: :unknown}] = result.evidence
    end

    test "untouched test failures with an unreadable diff are needs_agent" do
      checks = [%{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}]
      assert CiTriage.classify(checks, :unknown).class == :needs_agent
    end

    test "garbage input is needs_agent, never a crash" do
      assert CiTriage.classify(nil, nil).class == :needs_agent
      assert CiTriage.classify([%{}], @changed).class == :needs_agent
      assert CiTriage.classify([:not_a_map], @changed).class == :needs_agent
    end
  end

  describe "target_red" do
    test "a target hold wins over the job data" do
      checks = [%{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}]
      hold = "target branch main is red (deploy / test)"

      result = CiTriage.classify(checks, @changed, target_hold: hold)

      assert result.class == :target_red
      assert result.reason =~ hold
    end
  end

  describe "render/1" do
    test "names the class, reason and per-job evidence" do
      checks = [%{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}]
      text = @changed |> then(&CiTriage.classify(checks, &1)) |> CiTriage.render()

      assert text =~ "unrelated_tests"
      assert text =~ "mix test"
      assert text =~ "drain_test.exs"
    end
  end
end
