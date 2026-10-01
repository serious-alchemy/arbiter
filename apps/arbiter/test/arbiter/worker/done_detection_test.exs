defmodule Arbiter.Worker.DoneDetectionTest do
  @moduledoc """
  bd-c27m5o: `arb done` must be detected only from the agent's own assistant
  text, on a line by itself. Tool inputs, tool results, undecodable JSON
  fragments and prose that merely mentions the marker must never trip it.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Worker.ClaudeSession

  defp session(provider \\ nil) do
    ClaudeSession.build_session_config(
      "bd-done-detect",
      "worker:done-detect-#{System.unique_integer([:positive])}",
      provider: provider
    )
    |> Map.merge(%{line_buf: "", output_lines: [], exit_status: nil, exited_at: nil})
  end

  defp feed(session, events) do
    Enum.reduce(events, session, fn event, acc ->
      line = if is_binary(event), do: event, else: Jason.encode!(event)
      ClaudeSession.handle_data(acc, line, true)
    end)
  end

  defp assistant(blocks), do: %{"type" => "assistant", "message" => %{"content" => blocks}}
  defp user(blocks), do: %{"type" => "user", "message" => %{"content" => blocks}}

  defp done? do
    receive do
      {:__claude_session_done__, _} -> true
    after
      50 -> false
    end
  end

  describe "claude stream-json" do
    test "marker only inside a tool input is not done" do
      feed(session(), [
        assistant([
          %{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => "echo arb done"}}
        ])
      ])

      refute done?()
    end

    test "marker only at the end of a tool result is not done" do
      feed(session(), [
        user([
          %{
            "type" => "tool_result",
            "content" => "docs say:\nuse the `arb done`\narb done"
          }
        ])
      ])

      refute done?()
    end

    test "an undecodable JSON fragment ending in the marker is not done" do
      feed(session(), [~s({"type":"user","message":{"content":[{"type":"tool_result","content":"arb done)])
      refute done?()
    end

    test "prose that mentions the marker is not done" do
      feed(session(), [
        assistant([%{"type" => "text", "text" => "I will print `arb done`"}]),
        assistant([%{"type" => "text", "text" => "all set - arb done"}])
      ])

      refute done?()
    end

    test "a real sentinel line in assistant text is done" do
      feed(session(), [
        assistant([%{"type" => "text", "text" => "Finished the work.\n\narb done"}])
      ])

      assert done?()
    end

    test "a raw (non-JSON) sentinel line is still done" do
      feed(session(), ["arb done"])
      assert done?()
    end
  end

  describe "codex" do
    test "marker in a command_execution item is not done" do
      feed(session("codex"), [
        %{
          "type" => "item.completed",
          "item" => %{
            "type" => "command_execution",
            "command" => "echo arb done",
            "aggregated_output" => "arb done"
          }
        }
      ])

      refute done?()
    end

    test "marker in an agent_message item is done" do
      feed(session("codex"), [
        %{
          "type" => "item.completed",
          "item" => %{"type" => "agent_message", "text" => "ok\narb done"}
        }
      ])

      assert done?()
    end
  end

  describe "agy / gemini" do
    test "marker in a tool step is not done" do
      feed(session("gemini"), [
        %{
          "event" => "step_update",
          "step_update" => %{"step_type" => "run_command", "text_delta" => "arb done"}
        },
        %{"type" => "tool_result", "output" => "arb done"}
      ])

      refute done?()
    end

    test "marker in assistant text is done" do
      feed(session("gemini"), [
        %{"type" => "message", "role" => "assistant", "content" => "fine\narb done"}
      ])

      assert done?()
    end
  end
end
