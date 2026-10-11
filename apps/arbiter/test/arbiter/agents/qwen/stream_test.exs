defmodule Arbiter.Agents.Qwen.StreamTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Qwen.Stream, as: QStream
  alias Arbiter.Worker.StopReason

  describe "tool_name/1" do
    test "maps qwen built-ins onto the Claude vocabulary, passing unknown names through" do
      assert QStream.tool_name("run_shell_command") == "Bash"
      assert QStream.tool_name("read_file") == "Read"
      assert QStream.tool_name("write_file") == "Write"
      assert QStream.tool_name("replace") == "Edit"
      assert QStream.tool_name("list_directory") == "LS"
      assert QStream.tool_name("grep_search") == "Grep"
      assert QStream.tool_name("mcp__arbiter__ticket_show") == "mcp__arbiter__ticket_show"
    end
  end

  describe "normalize_event/1" do
    test "renames tool_use blocks" do
      event = %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{"type" => "text", "text" => "hi"},
            %{"type" => "tool_use", "name" => "run_shell_command", "input" => %{}}
          ]
        }
      }

      assert %{"message" => %{"content" => [%{"type" => "text"}, %{"name" => "Bash"}]}} =
               QStream.normalize_event(event)
    end

    test "init: qwen_code_version becomes claude_code_version" do
      event = %{"type" => "system", "subtype" => "init", "qwen_code_version" => "0.25.0"}
      assert %{"claude_code_version" => "0.25.0"} = QStream.normalize_event(event)
    end

    test "an error result with all-zero usage drops the usage (unknown, not free)" do
      event = %{
        "type" => "result",
        "is_error" => true,
        "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
      }

      refute Map.has_key?(QStream.normalize_event(event), "usage")
    end

    test "an error result with real usage keeps it" do
      event = %{"type" => "result", "is_error" => true, "usage" => %{"input_tokens" => 5}}
      assert %{"usage" => %{"input_tokens" => 5}} = QStream.normalize_event(event)
    end

    test "passes other events through unchanged" do
      event = %{"type" => "user", "message" => %{"content" => "x"}}
      assert QStream.normalize_event(event) == event
    end
  end

  describe "message_usage_fields/2" do
    test "adds the message's usage onto the running sums under ledger keys" do
      event = %{
        "type" => "assistant",
        "message" => %{
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 3,
            "cache_read_input_tokens" => 4
          }
        }
      }

      assert %{tokens_in: 15, tokens_out: 5, cache_read_tokens: 4} =
               QStream.message_usage_fields(event, %{tokens_in: 5, tokens_out: 2})
    end

    test "is empty without usage" do
      assert QStream.message_usage_fields(%{"type" => "assistant", "message" => %{}}, %{}) == %{}
    end
  end

  describe "error_lines/1" do
    test "reads the error object and errors[]" do
      assert ["qwen error: 404 not found", "qwen error: retry"] =
               QStream.error_lines(%{
                 "type" => "result",
                 "error" => %{"message" => "404 not found\nretry"}
               })

      assert ["qwen error: a"] = QStream.error_lines(%{"type" => "result", "errors" => ["a"]})
      assert [] = QStream.error_lines(%{"type" => "result"})
    end
  end

  # The exit-code table (bd-3km00p §1): every documented qwen exit status and
  # the StopReason category it must classify as.
  describe "exit code → StopReason table" do
    @table [
      {41, :auth_expired},
      {42, :crashed},
      {44, :crashed},
      {52, :crashed},
      {53, :exited_without_done},
      {54, :crashed},
      {55, :exited_without_done}
    ]

    for {code, category} <- @table do
      test "exit #{code} classifies as #{category} via StopReason.classify/3" do
        assert %StopReason{category: unquote(category), exit_status: unquote(code)} =
                 StopReason.classify(unquote(code), ["some output"], "qwen")
      end

      test "exit #{code} has a qwen-specific summary" do
        assert %StopReason{summary: summary} = QStream.stop_reason(unquote(code))
        assert summary =~ "qwen"
      end
    end

    test "budget exits are flagged as budget stops" do
      assert QStream.budget_exit?(53)
      assert QStream.budget_exit?(55)
      refute QStream.budget_exit?(1)
      refute QStream.budget_exit?(0)
    end

    test "exit 0, 1 and signals are not in the table (the generic classifier decides)" do
      assert QStream.stop_reason(0) == nil
      assert QStream.stop_reason(1) == nil
      assert QStream.stop_reason(143) == nil
      assert QStream.stop_reason(nil) == nil
    end

    test "the table wins over incidental output vocabulary in the tail" do
      assert %StopReason{category: :exited_without_done} =
               StopReason.classify(53, ["rate limit 429 unauthorized"], "qwen")
    end

    test "other providers' exit 53 is untouched" do
      assert %StopReason{category: :crashed} = StopReason.classify(53, ["boom"], "gemini")
    end

    test "exit 143 is still a kill for qwen" do
      assert %StopReason{category: :killed} = StopReason.classify(143, ["x"], "qwen")
    end
  end
end
