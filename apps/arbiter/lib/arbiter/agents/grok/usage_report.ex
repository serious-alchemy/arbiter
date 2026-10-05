defmodule Arbiter.Agents.Grok.UsageReport do
  @moduledoc """
  `grok usage <session-id>`: grok's own persisted per-session token and cost
  totals (bd-9ydvov, shapes from bd-7nbwix).

  It is local and costs no tokens, runs against the worker's own `GROK_HOME`,
  and carries what the stream does not (`reasoningTokens`), so it is the
  reconciliation source for the usage events built from the stream, and the
  only record left when a run is killed before its `result` line.

  Its `inputTokens` **includes** cache reads, unlike the stream's
  `input_tokens`; `parse/1` splits them back apart so both sources speak the
  ledger's `tokens_in` (uncached) / `cache_read_tokens`. Cost is in ticks
  (1e10 per USD) and notional on the free tier.

  This module is the pure side (argv and parsing). Running it after a run and
  persisting the JSON is the worker's job.
  """

  @ticks_per_usd 10_000_000_000
  @session_id ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,127}\z/

  @type report :: %{
          session_id: String.t() | nil,
          model: String.t() | nil,
          tokens_in: integer(),
          cache_read_tokens: integer(),
          cache_creation_tokens: integer(),
          tokens_out: integer(),
          reasoning_tokens: integer(),
          total_tokens: integer(),
          model_calls: integer(),
          cost_usd: float() | nil
        }

  @doc """
  The argv for a session's report (run it with the spawn's env so `GROK_HOME`
  is the worker's). The id becomes an argv element of a CLI that reads session
  directories, so only a plain id is accepted.
  """
  @spec argv(String.t()) :: {:ok, [String.t()]} | {:error, :invalid_session_id}
  def argv(session_id) when is_binary(session_id) do
    if Regex.match?(@session_id, session_id),
      do: {:ok, ["grok", "usage", session_id]},
      else: {:error, :invalid_session_id}
  end

  def argv(_), do: {:error, :invalid_session_id}

  @doc "Parse a `grok usage` JSON document into ledger-keyed totals."
  @spec parse(String.t()) :: {:ok, report()} | {:error, :invalid_report}
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"session" => %{"inputTokens" => input} = session} = doc} when is_integer(input) ->
        cached = int(session["cachedReadTokens"])

        {:ok,
         %{
           session_id: doc["sessionId"],
           model: session["primaryModelId"],
           tokens_in: max(input - cached, 0),
           cache_read_tokens: cached,
           cache_creation_tokens: int(session["cacheCreationTokens"]),
           tokens_out: int(session["outputTokens"]),
           reasoning_tokens: int(session["reasoningTokens"]),
           total_tokens: int(session["totalTokens"]),
           model_calls: int(session["modelCalls"]),
           cost_usd: cost(session["costUsdTicks"])
         }}

      _ ->
        {:error, :invalid_report}
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0

  defp cost(ticks) when is_integer(ticks), do: ticks / @ticks_per_usd
  defp cost(_), do: nil
end
