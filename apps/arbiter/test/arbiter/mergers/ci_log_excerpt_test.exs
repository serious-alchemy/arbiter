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

    slow = for i <- 1..40, do: "  * test slow #{i} (#{i}.0ms) [L#{i}] test/slow_#{i}_test.exs:#{i}"

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
  end
end
