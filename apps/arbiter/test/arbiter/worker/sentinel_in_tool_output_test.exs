defmodule Arbiter.Worker.SentinelInToolOutputTest do
  @moduledoc """
  A Codex worker asked to re-emit the completion sentinel ran
  `/bin/sh -lc "printf 'arb done\\n'"`. The sentinel reached the transcript only
  as command output (never as agent message text), so the harness ignored it
  and the finished, committed run was reported as `exited without completing`.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Codex
  alias Arbiter.Worker.StopReason

  @printf_tail [
    "⏵ $ /bin/sh -lc \"git status --short && git rev-parse --short HEAD\"",
    "⏴ command done",
    "⏴ a255cd94",
    "⏵ $ /bin/sh -lc \"printf 'arb done\\n'\"",
    "⏴ command done",
    "⏴ arb done",
    "Completed worktree verification: clean at a255cd94."
  ]

  test "sentinel only in the last shell command's output is :sentinel_in_tool_output" do
    reason = StopReason.classify(0, @printf_tail, "codex")
    assert reason.category == :sentinel_in_tool_output
    assert reason.summary =~ "tool output"
    assert StopReason.label(reason) =~ "tool output"
    refute reason.category in [:exited_without_done, :crashed]
  end

  test "a mid-run grep result containing `arb done` is not the sentinel" do
    tail = [
      "⏵ $ /bin/sh -lc \"grep -rn 'arb done' lib\"",
      "⏴ command done",
      "⏴ lib/foo.ex:12: arb done",
      "⏵ $ /bin/sh -lc \"mix test\"",
      "⏴ command done",
      "⏴ 3 tests, 0 failures",
      "Tests pass."
    ]

    assert StopReason.classify(0, tail, "codex").category == :exited_without_done
  end

  test "a grep as the LAST command is not the sentinel" do
    tail = [
      "⏵ $ /bin/sh -lc \"grep -rn 'arb done' lib\"",
      "⏴ command done",
      "⏴ arb done",
      "Found it."
    ]

    assert StopReason.classify(0, tail, "codex").category == :exited_without_done
  end

  test "sentinel followed by further commands is not the sentinel" do
    tail = @printf_tail ++ ["⏵ $ /bin/sh -lc \"ls\"", "⏴ command done", "⏴ a.txt"]
    assert StopReason.classify(0, tail, "codex").category == :exited_without_done
  end

  test "other providers and non-zero exits are unaffected" do
    assert StopReason.classify(0, @printf_tail, "gemini").category == :exited_without_done
    refute StopReason.classify(1, @printf_tail, "codex").category == :sentinel_in_tool_output
  end

  test "codex instructions say the sentinel is the agent's own final message line" do
    text = Codex.ConfigDir.worker_memory()
    assert text =~ "final message"
    assert text =~ "never"
    refute text =~ "printing the `arb done`"
  end
end
