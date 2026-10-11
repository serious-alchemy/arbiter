defmodule Arbiter.Test.ScriptedOpenAI.Router do
  @moduledoc false
  # The Plug behind `Arbiter.Test.ScriptedOpenAI`; `opts` is the script agent's pid.

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.Test.ScriptedOpenAI

  @model "scripted-model"

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    {:ok, raw, conn} = read_body(conn)

    body =
      case Jason.decode(raw) do
        {:ok, decoded} -> decoded
        _ -> %{}
      end

    ScriptedOpenAI.record(agent, %{
      method: conn.method,
      path: conn.request_path,
      headers: conn.req_headers,
      body: body
    })

    {delay, step} = ScriptedOpenAI.next(agent)
    if delay > 0, do: Process.sleep(delay)
    respond(conn, step, body["stream"] == true)
  end

  defp respond(conn, :exhausted, _stream?), do: error(conn, 500, "script_exhausted")
  defp respond(conn, {:error, status, message}, _), do: error(conn, status, message)

  defp respond(conn, {:rate_limit, seconds}, _) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> error(429, "rate_limit_exceeded")
  end

  defp respond(conn, {:text, text}, false), do: json(conn, 200, completion(message(text), "stop"))

  defp respond(conn, {:text, text}, true) do
    pieces = List.wrap(text)
    first = delta_chunk(%{"role" => "assistant", "content" => ""}, nil)
    deltas = Enum.map(pieces, &delta_chunk(%{"content" => &1}, nil))
    sse(conn, [first | deltas] ++ [delta_chunk(%{}, "stop")])
  end

  defp respond(conn, {:tool_calls, calls}, false) do
    msg = %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls(calls)}
    json(conn, 200, completion(msg, "tool_calls"))
  end

  defp respond(conn, {:tool_calls, calls}, true) do
    first = delta_chunk(%{"role" => "assistant", "content" => nil}, nil)

    deltas =
      calls
      |> tool_calls()
      |> Enum.with_index()
      |> Enum.map(fn {call, i} ->
        delta_chunk(%{"tool_calls" => [Map.put(call, "index", i)]}, nil)
      end)

    sse(conn, [first | deltas] ++ [delta_chunk(%{}, "tool_calls")])
  end

  defp tool_calls(calls) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, i} ->
      args = call[:arguments] || %{}

      %{
        "id" => call[:id] || "call_#{i}",
        "type" => "function",
        "function" => %{
          "name" => call.name,
          "arguments" => if(is_binary(args), do: args, else: Jason.encode!(args))
        }
      }
    end)
  end

  defp message(text),
    do: %{"role" => "assistant", "content" => text |> List.wrap() |> Enum.join()}

  defp completion(message, finish) do
    %{
      "id" => "chatcmpl-scripted",
      "object" => "chat.completion",
      "created" => 0,
      "model" => @model,
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish}],
      "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}
    }
  end

  defp delta_chunk(delta, finish) do
    %{
      "id" => "chatcmpl-scripted",
      "object" => "chat.completion.chunk",
      "created" => 0,
      "model" => @model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
    }
  end

  defp error(conn, status, message) do
    json(conn, status, %{
      "error" => %{"message" => message, "type" => "scripted_error", "code" => message}
    })
  end

  defp json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp sse(conn, chunks) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    Enum.reduce(chunks, conn, fn c, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, "data: " <> Jason.encode!(c) <> "\n\n")
      conn
    end)
    |> then(fn conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
      conn
    end)
  end
end
