defmodule Arbiter.Workflows.MergeQueue.CiTriageTest do
  # GitHub #1144: of 127 fix passes in 14 days only ~21 changed code. The triage
  # sorts a red head into infra / unrelated_tests / target_red / needs_agent
  # before an agent is spawned, and anything it cannot read is needs_agent.
  #
  # bd-3ij7dw hardened it: `unrelated_tests` needs ExUnit failure evidence and
  # takes its files only from the failure blocks; risky diff scope, an unreadable
  # diff and a truncated log are never "unrelated".
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.CiTriage

  # ExUnit prints app-relative paths; the diff carries repo-relative ones.
  @drain "test/arbiter/board/drain_test.exs"
  @coverage "test/arbiter/reviews/coverage_test.exs"
  @changed ["docs/guide.md", "apps/arbiter/lib/arbiter/worker/watchdog.ex"]

  defp verdicts(result), do: Enum.map(result.evidence, & &1.verdict)

  # A realistic ExUnit report: one numbered failure block per file, then the
  # run's summary line.
  defp exunit(files) do
    blocks =
      files
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {file, n} ->
        "  #{n}) test it works (SomeTest)\n     #{file}:#{10 + n}\n" <>
          "     Assertion with == failed\n     left:  1\n     right: 2\n"
      end)

    "#{blocks}\nFinished in 1.2 seconds (0.5s async, 0.7s sync)\n" <>
      "9 tests, #{length(files)} failures\n"
  end

  defp test_check(files, extra \\ %{}),
    do: Map.merge(%{name: "mix test", conclusion: "failure", summary: exunit(files)}, extra)

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
    test "GitHub: ExUnit failure blocks name test files the diff does not touch" do
      result = CiTriage.classify([test_check([@drain, @coverage])], @changed)

      assert result.class == :unrelated_tests
      assert result.reason =~ "not touch"
      assert [%{job: "mix test", verdict: :unrelated_test, files: files}] = result.evidence
      assert files == [@drain, @coverage]
    end

    test "GitLab: a trace with a failure block names only untouched test files" do
      summary = "1) test flaky (DrainTest)\n   test/arbiter/board/drain_test.exs:44\n   boom\n"

      checks = [
        %{name: "rspec", failure_reason: "script_failure", summary: summary, url: nil}
      ]

      assert %{class: :unrelated_tests} = CiTriage.classify(checks, @changed)
    end

    test "doctest and property failure blocks count as failure evidence" do
      summary =
        "  1) doctest Foo.bar/1 (1) (FooTest)\n     test/foo_test.exs:3\n     boom\n\n" <>
          "  2) property holds (BarTest)\n     test/bar_test.exs:9\n     boom\n"

      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]
      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert hd(result.evidence).files == ["test/foo_test.exs", "test/bar_test.exs"]
    end

    test "the file list comes only from the failure blocks, not from annotations or other text" do
      summary =
        "warning: unused\n  test/arbiter/other_test.exs:3\n\n" <> exunit([@drain])

      checks = [
        %{
          name: "mix test",
          conclusion: "failure",
          summary: summary,
          files: ["test/arbiter/annotated_test.exs"]
        }
      ]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert [%{files: [@drain]}] = result.evidence
    end

    test "infra and unrelated tests together re-run too, naming both" do
      checks = [
        %{name: "build", conclusion: "timed_out", summary: "", files: []},
        test_check([@drain])
      ]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert Enum.sort(verdicts(result)) == [:infra, :unrelated_test]
    end

    test "an infra phrase beside an ExUnit failure block is not infra (a new hang or OOM can be the diff's)" do
      summary = exunit([@drain]) <> "\nKilled\nexit code 137\n"
      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert [%{verdict: :unrelated_test}] = result.evidence
    end

    test "a pool timeout with no failure block anywhere is still infra" do
      summary = "connection not available and request was dropped from queue after 2000ms"
      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      assert CiTriage.classify(checks, @changed).class == :infra
    end
  end

  describe "needs_agent (no positive evidence of an unrelated test failure)" do
    test "annotations alone, with no ExUnit failure block, are not enough" do
      checks = [%{name: "mix test", conclusion: "failure", summary: "", files: [@drain]}]

      result = CiTriage.classify(checks, @changed)

      assert result.class == :needs_agent
      assert [%{verdict: :unknown}] = result.evidence
    end

    test "a log with test paths but no failure block is needs_agent" do
      summary = "Compiling...\n  test/arbiter/board/drain_test.exs:44: warning: unused alias\n"
      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end

    test "a summary line alone has failure evidence but names no file: needs_agent" do
      checks = [
        %{name: "mix test", conclusion: "failure", summary: "9 tests, 2 failures\n"}
      ]

      assert [%{verdict: :unknown}] = CiTriage.classify(checks, @changed).evidence
    end

    test "'0 failures' is not failure evidence" do
      summary = "  test/arbiter/board/drain_test.exs:44: warning\n9 tests, 0 failures\n"
      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end

    test "a test_helper crash is needs_agent" do
      summary =
        "** (RuntimeError) cannot start repo\n    test/test_helper.exs:4: (file)\n" <>
          "    (elixir) lib/code.ex:1: Code.require_file/1\n"

      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]

      assert CiTriage.classify(checks, @changed).class == :needs_agent
    end

    test "a failure block located in test/support or test_helper is needs_agent" do
      for file <- ["test/support/data_case.ex", "test/test_helper.exs"] do
        result = CiTriage.classify([test_check([file])], @changed)
        assert result.class == :needs_agent, file
        assert [%{verdict: :touches_diff}] = result.evidence
      end
    end

    test "a test/support stack frame beneath an untouched failing test does not force an agent" do
      summary =
        "  1) test it works (SomeTest)\n     test/arbiter/board/drain_test.exs:11\n" <>
          "     ** (RuntimeError) boom\n     test/support/data_case.ex:30: DataCase.setup/1\n" <>
          "\n9 tests, 1 failure\n"

      checks = [%{name: "mix test", conclusion: "failure", summary: summary}]
      result = CiTriage.classify(checks, @changed)

      assert result.class == :unrelated_tests
      assert [%{files: [@drain]}] = result.evidence
    end

    test "warnings-as-errors in a test run is needs_agent, even beside a failure block" do
      for line <- [
            "Test suite failed due to warnings",
            "Test suite aborted after successful execution due to warnings while using the --warnings-as-errors option"
          ] do
        checks = [
          %{name: "mix test", conclusion: "failure", summary: exunit([@drain]) <> line}
        ]

        assert CiTriage.classify(checks, @changed).class == :needs_agent, line
      end
    end
  end

  describe "needs_agent (the diff's scope)" do
    for path <- [
          "config/runtime.exs",
          "apps/arbiter/config/test.exs",
          "mix.exs",
          "apps/arbiter/mix.exs",
          "mix.lock",
          "apps/arbiter/test/support/data_case.ex",
          "apps/arbiter/test/test_helper.exs",
          "apps/arbiter/priv/repo/migrations/20260101000000_add_x.exs",
          "package.json",
          "db/migrate/20260101_add_x.rb"
        ] do
      test "a diff touching #{path} makes an untouched test failure needs_agent" do
        changed = ["docs/guide.md", unquote(path)]

        result = CiTriage.classify([test_check([@drain])], changed)

        assert result.class == :needs_agent
        assert [%{verdict: :touches_diff, detail: detail}] = result.evidence
        assert detail =~ unquote(path)
      end
    end

    test "a docs-only diff does not trigger the scope rule" do
      assert CiTriage.classify([test_check([@drain])], ["docs/guide.md", "README.md"]).class ==
               :unrelated_tests
    end

    test "a hard infra signal is still infra under a risky diff" do
      checks = [%{name: "build", conclusion: "timed_out", summary: ""}]
      assert CiTriage.classify(checks, ["mix.exs"]).class == :infra
    end

    test "a failing test under the directory of a changed module counts as touched" do
      check = test_check(["test/app/accounts/user_test.exs"])

      result = CiTriage.classify([check], ["apps/app/lib/app/accounts.ex"])

      assert result.class == :needs_agent

      assert [%{verdict: :touches_diff, files: ["test/app/accounts/user_test.exs"]}] =
               result.evidence
    end

    test "a failing test beside a changed sibling source file counts as touched" do
      check = test_check(["test/app/accounts/user_test.exs"])

      assert CiTriage.classify([check], ["lib/app/accounts/session.ex"]).class == :needs_agent
    end

    test "a changed module elsewhere does not touch the failing test" do
      check = test_check(["test/app/accounts/user_test.exs"])

      assert CiTriage.classify([check], ["lib/app/billing.ex", "lib/app/billing/invoice.ex"]).class ==
               :unrelated_tests
    end
  end

  describe "needs_agent (the failure touches the diff)" do
    test "a failing test file the diff edits" do
      changed = ["apps/arbiter/test/arbiter/board/drain_test.exs"]

      result = CiTriage.classify([test_check([@drain])], changed)

      assert result.class == :needs_agent
      assert [%{verdict: :touches_diff, files: [@drain]}] = result.evidence
    end

    test "the conventional subject module of a failing test is in the diff" do
      changed = ["apps/arbiter/lib/arbiter/board/drain.ex"]

      result = CiTriage.classify([test_check([@drain])], changed)

      assert result.class == :needs_agent
      assert hd(result.evidence).detail =~ "drain.ex"
    end

    test "a stack frame in a changed source file" do
      summary =
        "1) test drains (DrainTest)\n   test/arbiter/board/drain_test.exs:9\n" <>
          "   (arbiter) lib/arbiter/worker/watchdog.ex:101: Watchdog.go/1\n"

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
        test_check(["test/arbiter/worker/watchdog_test.exs"])
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
      assert CiTriage.classify([test_check([@drain])], :unknown).class == :needs_agent
    end

    test "an empty changed-file list is an unreadable diff, not 'nothing touched'" do
      result = CiTriage.classify([test_check([@drain])], [])

      assert result.class == :needs_agent
      assert [%{verdict: :unknown, detail: detail}] = result.evidence
      assert detail =~ "diff"
    end

    test "a truncated log excerpt can never produce unrelated_tests" do
      check = test_check([@drain], %{truncated: true})

      result = CiTriage.classify([check], @changed)

      assert result.class == :needs_agent
      assert [%{verdict: :unknown, detail: detail}] = result.evidence
      assert detail =~ "truncated"
    end

    test "a truncated excerpt is not trusted for a soft infra phrase either" do
      check = %{name: "t", conclusion: "failure", summary: "exit code 137", truncated: true}

      assert CiTriage.classify([check], @changed).class == :needs_agent
    end

    test "garbage input is needs_agent, never a crash" do
      assert CiTriage.classify(nil, nil).class == :needs_agent
      assert CiTriage.classify([%{}], @changed).class == :needs_agent
      assert CiTriage.classify([:not_a_map], @changed).class == :needs_agent
    end
  end

  describe "target_red" do
    test "a target hold wins over the job data" do
      hold = "target branch main is red (deploy / test)"

      result = CiTriage.classify([test_check([@drain])], @changed, target_hold: hold)

      assert result.class == :target_red
      assert result.reason =~ hold
    end
  end

  describe "render/1" do
    test "names the class, reason and per-job evidence" do
      text = [test_check([@drain])] |> CiTriage.classify(@changed) |> CiTriage.render()

      assert text =~ "unrelated_tests"
      assert text =~ "mix test"
      assert text =~ "drain_test.exs"
    end
  end
end
