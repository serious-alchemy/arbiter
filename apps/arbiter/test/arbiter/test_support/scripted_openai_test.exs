defmodule Arbiter.Test.ScriptedOpenAITest do
  use ExUnit.Case, async: true

  alias Arbiter.Test.ScriptedOpenAI

  defp post(server, body, opts \\ []) do
    Req.post!(
      server.url <> "/chat/completions",
      [json: body, retry: false, receive_timeout: 2_000] ++ opts
    )
  end

  test "a non-streaming text step returns one chat completion and records the request" do
    server = ScriptedOpenAI.start_supervised!([{:text, "hello"}])
    resp = post(server, %{"model" => "m", "messages" => []})

    assert resp.status == 200

    assert [%{"message" => %{"content" => "hello"}, "finish_reason" => "stop"}] =
             resp.body["choices"]

    assert [%{path: "/v1/chat/completions", body: %{"model" => "m"}}] =
             ScriptedOpenAI.requests(server)

    assert ScriptedOpenAI.remaining(server) == []
  end

  test "a tool_calls step carries JSON-encoded arguments and finish_reason tool_calls" do
    server =
      ScriptedOpenAI.start_supervised!([
        {:tool_calls, [%{id: "c1", name: "read_file", arguments: %{"path" => "a.txt"}}]}
      ])

    resp = post(server, %{"messages" => []})
    [choice] = resp.body["choices"]

    assert choice["finish_reason"] == "tool_calls"

    assert [%{"id" => "c1", "function" => %{"name" => "read_file", "arguments" => args}}] =
             choice["message"]["tool_calls"]

    assert Jason.decode!(args) == %{"path" => "a.txt"}
  end

  test "stream: true yields SSE deltas ending in [DONE]" do
    server = ScriptedOpenAI.start_supervised!([{:text, ["hel", "lo"]}])
    resp = post(server, %{"stream" => true, "messages" => []})

    assert resp.status == 200
    assert ["text/event-stream" <> _] = resp.headers["content-type"]

    events =
      resp.body
      |> String.split("\n\n", trim: true)
      |> Enum.map(&String.replace_prefix(&1, "data: ", ""))

    assert List.last(events) == "[DONE]"

    content =
      events
      |> Enum.drop(-1)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.map_join(fn %{"choices" => [%{"delta" => d}]} -> d["content"] || "" end)

    assert content == "hello"
  end

  test "a streamed tool_calls step emits indexed tool_call deltas" do
    server = ScriptedOpenAI.start_supervised!([{:tool_calls, [%{name: "ls"}]}])
    resp = post(server, %{"stream" => true})

    assert resp.body =~ ~s("tool_calls":[{)
    assert resp.body =~ ~s("finish_reason":"tool_calls")
    assert resp.body =~ "data: [DONE]"
  end

  test "error and 429 steps carry status, body and retry-after" do
    server =
      ScriptedOpenAI.start_supervised!([
        {:error, 400, "bad_request"},
        {:error, 503, "overloaded"},
        {:rate_limit, 7}
      ])

    assert %{status: 400, body: %{"error" => %{"message" => "bad_request"}}} = post(server, %{})
    assert %{status: 503} = post(server, %{})
    limited = post(server, %{})
    assert limited.status == 429
    assert limited.headers["retry-after"] == ["7"]
  end

  test "a sleep step delays the next response only" do
    server = ScriptedOpenAI.start_supervised!([{:sleep, 150}, {:text, "slow"}, {:text, "fast"}])

    {slow_us, _} = :timer.tc(fn -> post(server, %{}) end)
    {fast_us, _} = :timer.tc(fn -> post(server, %{}) end)

    assert slow_us >= 150_000
    assert fast_us < 150_000
  end

  test "an over-called script fails loudly with 500 script_exhausted" do
    server = ScriptedOpenAI.start_supervised!([])
    resp = post(server, %{})
    assert resp.status == 500
    assert resp.body["error"]["message"] == "script_exhausted"
  end
end
