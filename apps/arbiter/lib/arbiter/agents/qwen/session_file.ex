defmodule Arbiter.Agents.Qwen.SessionFile do
  @moduledoc """
  qwen's persisted per-session chat JSONL (bd-1po4s4, Q7 of the bd-3km00p epic).

  qwen records every API response as a `ui_telemetry` system record:

      {"type":"system","subtype":"ui_telemetry","sessionId":"...",
       "systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response",
         "model":"qwen3-coder:30b","input_token_count":1200,
         "output_token_count":40,"cached_content_token_count":0,
         "thoughts_token_count":0,"tool_token_count":0,"total_token_count":1240}}}

  The file is the reconciliation source for the stream's usage and the only
  record when a run is killed before its `result` line. It carries what the
  stream does not (`thoughts_token_count`) and never a cost (qwen reports none;
  see `Arbiter.Agents.Qwen.Usage` for pricing). `input_token_count` **includes**
  the cached part; `parse/1` splits them so the totals speak the ledger's
  `tokens_in` (uncached) / `cache_read_tokens`.

  The record shape is taken from qwen's documented telemetry, not a live
  capture (see `test/fixtures/qwen/README.md`). Lines of any other shape, and
  a torn last line from a killed run, are skipped.
  """

  @type totals :: %{
          model: String.t() | nil,
          session_id: String.t() | nil,
          tokens_in: non_neg_integer(),
          cache_read_tokens: non_neg_integer(),
          tokens_out: non_neg_integer(),
          thinking_tokens: non_neg_integer(),
          api_calls: non_neg_integer()
        }

  @doc "Sum the `api_response` telemetry in a session JSONL document; `:none` when it has none."
  @spec parse(String.t()) :: {:ok, totals()} | :none
  def parse(contents) when is_binary(contents) do
    events =
      contents
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&api_response/1)

    case events do
      [] -> :none
      events -> {:ok, sum(events)}
    end
  end

  @doc """
  The chat JSONL of session `session_id` under a worker's `config_dir` (its
  isolated `$HOME`, see `Arbiter.Agents.Qwen.ConfigDir`): qwen writes
  `<QWEN_HOME>/projects/<cwd-slug>/chats/<session_id>.jsonl`. `session_id` is
  matched as a literal token (it is spliced into a glob).
  """
  @spec locate(String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :not_found
  def locate(config_dir, session_id)
      when is_binary(config_dir) and config_dir != "" and is_binary(session_id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, session_id) do
      [".qwen", ""]
      |> Enum.flat_map(fn root ->
        Path.wildcard(
          Path.join([config_dir, root, "projects", "*", "chats", session_id <> ".jsonl"])
        )
      end)
      |> Enum.sort()
      |> List.first()
      |> case do
        nil -> :not_found
        path -> {:ok, path}
      end
    else
      :not_found
    end
  end

  def locate(_config_dir, _session_id), do: :not_found

  @doc "Read and `parse/1` a session file; `:none` if it is missing or unreadable."
  @spec read(Path.t() | nil) :: {:ok, totals()} | :none
  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, _} -> :none
    end
  end

  def read(_), do: :none

  defp api_response(line) do
    with {:ok, %{"subtype" => "ui_telemetry"} = record} <- Jason.decode(line),
         %{"event.name" => name} = ui <- get_in(record, ["systemPayload", "uiEvent"]),
         true <- String.ends_with?(name, "api_response") do
      [{record["sessionId"], ui}]
    else
      _ -> []
    end
  end

  defp sum(events) do
    {session_id, _} = hd(events)

    base = %{
      model: nil,
      session_id: session_id,
      tokens_in: 0,
      cache_read_tokens: 0,
      tokens_out: 0,
      thinking_tokens: 0,
      api_calls: 0
    }

    Enum.reduce(events, base, fn {_sid, ui}, acc ->
      input = int(ui["input_token_count"])
      cached = min(int(ui["cached_content_token_count"]), input)

      %{
        acc
        | model: ui["model"] || acc.model,
          tokens_in: acc.tokens_in + input - cached,
          cache_read_tokens: acc.cache_read_tokens + cached,
          tokens_out: acc.tokens_out + int(ui["output_token_count"]),
          thinking_tokens: acc.thinking_tokens + int(ui["thoughts_token_count"]),
          api_calls: acc.api_calls + 1
      }
    end)
  end

  defp int(n) when is_integer(n) and n >= 0, do: n
  defp int(_), do: 0
end
