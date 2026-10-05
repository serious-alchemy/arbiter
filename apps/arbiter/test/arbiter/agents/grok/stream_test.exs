defmodule Arbiter.Agents.Grok.StreamTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Grok.Stream

  # Fixtures are real `grok -p --output-format streaming-messages-json` captures
  # from the bd-7nbwix live probe (grok 1.0.25, grok-4.7): scratch paths and
  # thinking signatures redacted, no credentials were ever in the stream.
  @fixtures Path.expand("../../../fixtures/grok", __DIR__)

  defp events(name) do
    @fixtures
    |> Path.join(name)
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  describe "tool_name/1" do
    test "maps grok built-ins onto the Claude vocabulary" do
      assert Stream.tool_name("run_terminal_command") == "Bash"
      assert Stream.tool_name("write") == "Write"
      assert Stream.tool_name("search_replace") == "Edit"
      assert Stream.tool_name("read_file") == "Read"
      assert Stream.tool_name("grep") == "Grep"
      assert Stream.tool_name("list_dir") == "LS"
      assert Stream.tool_name("spawn_subagent") == "Task"
    end

    test "leaves unknown (MCP) tool names alone" do
      assert Stream.tool_name("mcp__arbiter__ticket_show") == "mcp__arbiter__ticket_show"
    end
  end

  describe "decode_tool_output/1" do
    test "decodes a Bash byte-array output to text" do
      content = Jason.encode!(%{"type" => "Bash", "output" => :binary.bin_to_list("hi ☃\nok\n")})
      assert Stream.decode_tool_output(content) == "hi ☃\nok\n"
    end

    test "passes plain text and non-Bash typed results through" do
      assert Stream.decode_tool_output("plain") == "plain"
      other = ~s({"type":"SearchReplace","EditsApplied":{}})
      assert Stream.decode_tool_output(other) == other
    end

    test "unwraps a ListDir listing" do
      content =
        Jason.encode!(%{
          "type" => "ListDir",
          "Content" => %{"content" => "- /work/\n  - README.md", "absolute_root_path" => "/work"}
        })

      assert Stream.decode_tool_output(content) == "- /work/\n  - README.md"
    end

    test "a Bash result whose bytes are not valid UTF-8 degrades to a lossy string" do
      content = Jason.encode!(%{"type" => "Bash", "output" => [104, 105, 255]})
      assert Stream.decode_tool_output(content) =~ "hi"
    end
  end

  describe "normalize_event/1 on the recorded success stream" do
    setup do: {:ok, events: Enum.map(events("success_stream.jsonl"), &Stream.normalize_event/1)}

    test "tool_use names are mapped, ids and inputs untouched", %{events: events} do
      names =
        for %{"type" => "assistant", "message" => %{"content" => c}} <- events,
            %{"type" => "tool_use", "name" => n} <- c,
            do: n

      assert names == ["LS", "Bash", "Write", "Write", "Bash"]
    end

    test "Bash tool_result byte arrays become text", %{events: events} do
      texts =
        for %{"type" => "user", "message" => %{"content" => c}} <- events,
            %{"type" => "tool_result", "content" => t} <- c,
            do: t

      assert Enum.any?(texts, &(&1 =~ "On branch main"))
      assert Enum.any?(texts, &(&1 =~ "add util"))
      refute Enum.any?(texts, &(&1 =~ ~s("output":[)))
    end

    test "thinking blocks survive", %{events: events} do
      assert Enum.any?(events, fn
               %{"type" => "assistant", "message" => %{"content" => c}} ->
                 Enum.any?(c, &(&1["type"] == "thinking"))

               _ ->
                 false
             end)
    end

    test "the success result keeps its usage and cost", %{events: events} do
      result = List.last(events)
      assert result["subtype"] == "success"
      assert result["usage"]["input_tokens"] == 29_112
      assert result["total_cost_usd"] == 0.078108
    end
  end

  describe "normalize_event/1 on error results" do
    test "an all-zero usage with is_error is unknown, not free" do
      for name <- ["error_bad_model.jsonl", "error_not_signed_in.jsonl"] do
        result = name |> events() |> List.last() |> Stream.normalize_event()

        assert result["is_error"] == true
        refute Map.has_key?(result, "usage")
        refute Map.has_key?(result, "total_cost_usd")
        assert [_ | _] = result["errors"]
      end
    end

    test "a non-error result with zero usage is kept as reported" do
      event = %{"type" => "result", "is_error" => false, "usage" => %{"input_tokens" => 0}}
      assert Stream.normalize_event(event)["usage"] == %{"input_tokens" => 0}
    end
  end

  describe "message_usage_fields/2" do
    test "accumulates per-message usage with cached and uncached input separate" do
      [_init, a1, _u1, a2 | _] = events("success_stream.jsonl")

      first = Stream.message_usage_fields(a1, %{})
      assert first[:tokens_in] == 11_680
      assert first[:cache_read_tokens] == 1_664
      assert first[:tokens_out] == 212

      second = Stream.message_usage_fields(a2, first)
      assert second[:tokens_in] == 11_680 + 2_338
      assert second[:cache_read_tokens] == 1_664 + 13_312
      assert second[:tokens_out] == 212 + 134
    end

    test "returns nothing for a message without usage" do
      assert Stream.message_usage_fields(%{"message" => %{}}, %{}) == %{}
    end
  end

  describe "error_lines/1" do
    test "surfaces result errors[] so StopReason can classify them" do
      result = "error_not_signed_in.jsonl" |> events() |> List.last()
      assert [line | _] = Stream.error_lines(result)
      assert line =~ "Not signed in"
    end

    test "is empty for a success result" do
      assert Stream.error_lines(%{"type" => "result", "subtype" => "success"}) == []
    end
  end
end
