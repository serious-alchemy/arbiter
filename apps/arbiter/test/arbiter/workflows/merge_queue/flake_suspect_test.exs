defmodule Arbiter.Workflows.MergeQueue.FlakeSuspectTest do
  # bd-2l0hzm AC4: PR #2003 (docs only) went red three times on three different
  # tests it never touched, and one fix pass "fixed" an unrelated flaky test.
  use ExUnit.Case, async: true

  alias Arbiter.Workflows.MergeQueue.FlakeSuspect

  @drain "apps/arbiter/test/arbiter/board/drain_test.exs"
  @gate "apps/arbiter/test/arbiter/quota/gate_provider_test.exs"

  describe "failing_tests/1" do
    test "collects test files from :files and from path:line references in the summary" do
      checks = [
        %{name: "mix test", summary: "", files: [@drain]},
        %{
          name: "mix test (2)",
          summary:
            "1) test teardown (GateProviderTest)\n   test/arbiter/quota/gate_provider_test.exs:423"
        }
      ]

      assert FlakeSuspect.failing_tests(checks) ==
               {:ok, [@drain, "test/arbiter/quota/gate_provider_test.exs"]}
    end

    test "is :unknown when any failing check names no test file" do
      checks = [
        %{name: "mix test", summary: "", files: [@drain]},
        %{name: "mix audit", summary: "credo: lib/arbiter/worker.ex:12 nesting too deep"}
      ]

      assert FlakeSuspect.failing_tests(checks) == :unknown
    end

    test "is :unknown with no checks" do
      assert FlakeSuspect.failing_tests([]) == :unknown
    end
  end

  describe "outside_diff?/2" do
    test "true when no failing test file is in the diff" do
      assert FlakeSuspect.outside_diff?([@drain], ["docs/guide.md"])
    end

    test "false when the diff touches a failing test file, matching app-relative paths" do
      refute FlakeSuspect.outside_diff?(["test/arbiter/quota/gate_provider_test.exs"], [@gate])
      refute FlakeSuspect.outside_diff?([@gate], [@gate, "docs/guide.md"])
    end

    test "does not match on a shared suffix that is not a whole path segment" do
      assert FlakeSuspect.outside_diff?(["drain_test.exs"], [
               "apps/x/test/board/sub_drain_test.exs"
             ])
    end
  end

  describe "classify/2" do
    test "{:outside_diff, files} when every failing check is a test outside the diff" do
      checks = [%{name: "mix test", summary: "", files: [@drain]}]
      assert FlakeSuspect.classify(checks, ["docs/guide.md"]) == {:outside_diff, [@drain]}
    end

    test ":in_diff when the PR touches a failing test" do
      checks = [%{name: "mix test", summary: "", files: [@drain]}]
      assert FlakeSuspect.classify(checks, [@drain]) == :in_diff
    end

    test ":unknown when the failing tests or the diff cannot be read" do
      assert FlakeSuspect.classify([%{name: "build", summary: "boom"}], ["a.ex"]) == :unknown

      assert FlakeSuspect.classify([%{name: "t", summary: "", files: [@drain]}], :unknown) ==
               :unknown
    end
  end
end
