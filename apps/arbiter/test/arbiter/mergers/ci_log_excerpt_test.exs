defmodule Arbiter.Mergers.CILogExcerptTest do
  use ExUnit.Case, async: true

  alias Arbiter.Mergers.CILogExcerpt

  @ts "2026-10-09T12:00:01.1234567Z "

  defp gh_log(lines), do: Enum.map_join(lines, "\n", &(@ts <> &1))

  test "keeps ExUnit failure blocks (name, file:line, assertion) and drops the noise" do
    noise = for i <- 1..200, do: "compiling module #{i}"

    log =
      gh_log(
        noise ++
          [
            "",
            "  1) test renders the index (ArbiterWeb.SessionIndexLiveTest)",
            "     test/arbiter_web/live/session_index_live_test.exs:42",
            "     Assertion with == failed",
            "     code:  assert html == \"x\"",
            "     left:  \"y\"",
            "     right: \"x\"",
            "     stacktrace:",
            "       test/arbiter_web/live/session_index_live_test.exs:44: (test)",
            ""
          ] ++ for(i <- 1..200, do: "tail noise #{i}") ++ ["3 tests, 1 failure"]
      )

    out = CILogExcerpt.extract(log, 4_000)

    assert out =~ "1) test renders the index (ArbiterWeb.SessionIndexLiveTest)"
    assert out =~ "session_index_live_test.exs:42"
    assert out =~ "Assertion with == failed"
    assert out =~ "left:  \"y\""
    assert out =~ "3 tests, 1 failure"
    refute out =~ "compiling module 5"
    refute out =~ "tail noise 100"
    refute out =~ "2026-10-09T12:00:01"
  end

  test "strips ANSI colour codes" do
    out = CILogExcerpt.extract("\e[31m** (RuntimeError) boom\e[0m\n  lib/a.ex:3: A.b/0", 1_000)
    assert out =~ "** (RuntimeError) boom"
    refute out =~ "\e["
  end

  test "picks up generic error lines with file:line from other toolchains" do
    log =
      gh_log(
        for(i <- 1..50, do: "step #{i}") ++
          ["##[error]src/app.ts:10:5 - error TS2322: bad type", "FAIL src/app.test.ts"] ++
          for(i <- 1..50, do: "after #{i}")
      )

    out = CILogExcerpt.extract(log, 2_000)
    assert out =~ "src/app.ts:10:5"
    assert out =~ "FAIL src/app.test.ts"
    refute out =~ "step 3\n"
  end

  test "falls back to the log tail when nothing looks like a failure" do
    log = Enum.map_join(1..500, "\n", &"line #{&1}")
    out = CILogExcerpt.extract(log, 200)
    assert out =~ "line 500"
    refute out =~ "line 1\n"
    assert String.length(out) <= 210
  end

  test "output is bounded and keeps both the first failures and the closing summary" do
    blocks =
      for i <- 1..100 do
        ["  #{i}) test number #{i} (Mod.T)", "     test/t_test.exs:#{i}", "     boom #{i}", ""]
      end

    log = Enum.join(List.flatten(blocks) ++ ["100 tests, 100 failures"], "\n")
    out = CILogExcerpt.extract(log, 1_000)

    assert String.length(out) <= 1_050
    assert out =~ "1) test number 1 (Mod.T)"
    assert out =~ "100 tests, 100 failures"
  end

  test "failure blocks survive a flood of earlier and later file:line noise" do
    warnings =
      for i <- 1..150, do: "warning: unused variable x#{i}\n  lib/arbiter/mod_#{i}.ex:#{i}"

    slow =
      for i <- 1..40, do: "  * test slow #{i} (#{i}.0ms) [L#{i}] test/slow_#{i}_test.exs:#{i}"

    block = [
      "",
      "  1) test one serializer, one cap (Arbiter.MCP.WorkerReadSideTest)",
      "     test/arbiter/mcp/worker_read_side_test.exs:219",
      "     Expected truthy, got false",
      "     code: assert function_exported?(Serializer, :show, 3)",
      "     stacktrace:",
      "       test/arbiter/mcp/worker_read_side_test.exs:220: (test)",
      ""
    ]

    log = gh_log(warnings ++ block ++ ["Top 10 slowest (1s)"] ++ slow ++ ["10 tests, 1 failure"])

    out = CILogExcerpt.extract(log, 4_000)

    assert out =~ "1) test one serializer, one cap (Arbiter.MCP.WorkerReadSideTest)"
    assert out =~ "worker_read_side_test.exs:219"
    assert out =~ "code: assert function_exported?(Serializer, :show, 3)"
    assert out =~ "10 tests, 1 failure"
    assert String.length(out) <= 4_100
  end

  test "empty and non-binary input yield an empty string" do
    assert CILogExcerpt.extract("", 100) == ""
    assert CILogExcerpt.extract(nil, 100) == ""
    assert CILogExcerpt.extract_with_status(nil, 100) == {"", false}
  end

  describe "extract_with_status/2 (bd-3ij7dw)" do
    test "a log that fits whole is not truncated" do
      log =
        gh_log([
          "  1) test a (ATest)",
          "     test/a_test.exs:3",
          "     boom",
          "",
          "1 test, 1 failure"
        ])

      assert {out, false} = CILogExcerpt.extract_with_status(log, 4_000)
      assert out == CILogExcerpt.extract(log, 4_000)
    end

    test "failure blocks dropped for want of budget make it truncated" do
      block = fn n ->
        [
          "  #{n}) test number #{n} (BigTest)",
          "     test/big_#{n}_test.exs:#{n}",
          "     Assertion with == failed"
        ] ++ for(i <- 1..20, do: "     detail line #{i} of failure #{n}") ++ [""]
      end

      log = gh_log(Enum.flat_map(1..30, block) ++ ["30 tests, 30 failures"])

      assert {out, true} = CILogExcerpt.extract_with_status(log, 1_000)
      assert String.length(out) <= 1_100
      assert CILogExcerpt.extract(log, 1_000) == out
    end

    test "a single oversized block cut by the bound is truncated" do
      lines =
        ["  1) test huge (HugeTest)", "     test/huge_test.exs:1"] ++
          for(i <- 1..28, do: String.duplicate("x", 80) <> "#{i}")

      assert {_out, true} = CILogExcerpt.extract_with_status(gh_log(lines), 500)
    end

    test "the tail fallback of a log with no failure markers is truncated only when cut" do
      assert {_, false} = CILogExcerpt.extract_with_status("just\nsome\nlines", 500)

      assert {_, true} =
               CILogExcerpt.extract_with_status(String.duplicate("plain line\n", 400), 500)
    end
  end

  describe "realistic logs through CILogExcerpt into the CI triage (bd-3ij7dw)" do
    alias Arbiter.Workflows.MergeQueue.CiTriage

    @esc <<27>>
    @changed ["docs/guide.md"]

    defp classify(log, changed \\ @changed, extra \\ %{}) do
      {summary, truncated} = CILogExcerpt.extract_with_status(log, 4_000)

      check =
        Map.merge(
          %{name: "test", conclusion: "failure", summary: summary, truncated: truncated},
          extra
        )

      CiTriage.classify([check], changed)
    end

    test "GitHub: ANSI colour, timestamps, doctest and property blocks, umbrella paths" do
      log =
        gh_log(
          for(i <- 1..60, do: "Compiling lib/app/mod_#{i}.ex") ++
            [
              "==> arbiter",
              "#{@esc}[31m  1) doctest Arbiter.Foo.bar/1 (3) (Arbiter.FooTest)#{@esc}[0m",
              "     test/arbiter/foo_test.exs:9",
              "     Doctest failed",
              "",
              "#{@esc}[31m  2) property reverses (Arbiter.PropTest)#{@esc}[0m",
              "     apps/arbiter/test/arbiter/prop_test.exs:21",
              "     Failed with generated values (after 4 successful runs)",
              "",
              "Finished in 3.1 seconds (1.0s async, 2.1s sync)",
              "#{@esc}[31m12 tests, 2 failures#{@esc}[0m"
            ]
        )

      result = classify(log)

      assert result.class == :unrelated_tests

      assert hd(result.evidence).files == [
               "test/arbiter/foo_test.exs",
               "apps/arbiter/test/arbiter/prop_test.exs"
             ]
    end

    test "GitLab: section markers, carriage returns and ANSI around the failure block" do
      log =
        "section_start:1700000000:step_script\r#{@esc}[0K#{@esc}[32;1mRunning mix test#{@esc}[0;m\r\n" <>
          "  1) test drains (Arbiter.DrainTest)\r\n" <>
          "     test/arbiter/board/drain_test.exs:44\r\n" <>
          "     ** (MatchError) no match\r\n\r\n" <>
          "9 tests, 1 failure\r\n" <>
          "section_end:1700000010:step_script\r#{@esc}[0K\r\n"

      result = classify(log)

      assert result.class == :unrelated_tests
      assert hd(result.evidence).files == ["test/arbiter/board/drain_test.exs"]
    end

    test "the failing test file is in the diff: needs_agent" do
      log =
        gh_log([
          "  1) test drains (DrainTest)",
          "     test/arbiter/board/drain_test.exs:44",
          "     boom",
          "",
          "9 tests, 1 failure"
        ])

      assert classify(log, ["apps/arbiter/test/arbiter/board/drain_test.exs"]).class ==
               :needs_agent
    end

    test "a log truncated by the 4000-char cap is never unrelated_tests" do
      noisy =
        for n <- 1..40 do
          [
            "  #{n}) test number #{n} (BigTest)",
            "     test/big_#{n}_test.exs:#{n}",
            "     Assertion with == failed"
          ] ++ for(i <- 1..25, do: "     detail line #{i} of failure #{n}") ++ [""]
        end

      result = classify(gh_log(Enum.flat_map(noisy, & &1) ++ ["40 tests, 40 failures"]))

      assert result.class == :needs_agent
      assert [%{verdict: :unknown, detail: detail}] = result.evidence
      assert detail =~ "truncated"
    end

    test "warnings-as-errors and a test_helper crash in real logs are needs_agent" do
      warn =
        gh_log([
          "  1) test a (ATest)",
          "     test/a_test.exs:3",
          "     boom",
          "",
          "Test suite failed due to warnings",
          "1 test, 1 failure"
        ])

      crash = gh_log(["** (RuntimeError) repo not started", "    test/test_helper.exs:2: (file)"])

      assert classify(warn).class == :needs_agent
      assert classify(crash).class == :needs_agent
    end
  end

  describe "randomised logs (seeded, deterministic)" do
    defp random_log(seed) do
      :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
      blocks = :rand.uniform(25)

      body =
        for n <- 1..blocks, reduce: [] do
          acc ->
            noise =
              for i <- 1..:rand.uniform(15),
                  do: "noise #{seed}.#{n}.#{i} " <> String.duplicate("z", :rand.uniform(60))

            block = [
              "  #{n}) test t#{n} (RandTest)",
              "     test/rand_#{n}_test.exs:#{n}",
              "     boom #{String.duplicate("b", :rand.uniform(80))}"
            ]

            acc ++ noise ++ block ++ [""]
        end

      Enum.join(body ++ ["#{blocks} tests, #{blocks} failures"], "\n")
    end

    test "the excerpt stays bounded, deterministic and truthful about truncation" do
      for seed <- 1..40, limit <- [300, 1_000, 4_000] do
        log = random_log(seed)
        {out, truncated?} = CILogExcerpt.extract_with_status(log, limit)

        assert String.length(out) <= limit + limit
        assert CILogExcerpt.extract_with_status(log, limit) == {out, truncated?}
        assert CILogExcerpt.extract(log, limit) == out
        # Whenever every failure header survives and nothing was flagged, none was lost.
        if not truncated? do
          assert length(Regex.scan(~r/^\s*\d+\) test /m, out)) ==
                   length(Regex.scan(~r/^\s*\d+\) test /m, log))
        end
      end
    end

    test "the summary line and the first failure always survive" do
      for seed <- 1..40 do
        log = random_log(seed)
        out = CILogExcerpt.extract(log, 400)

        assert out =~ "1) test t1 (RandTest)"
        assert out =~ ~r/\d+ tests, \d+ failures/
      end
    end
  end
end
