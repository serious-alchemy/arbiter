defmodule Arbiter.Agents.Qwen.RetryHold do
  @moduledoc """
  Turns qwen's endless-looking 429 retry loop into a provider hold
  (bd-1po4s4, Q7 of the bd-3km00p epic; the Grok counterpart is bd-cwq8b0).

  On a 429 qwen retries up to 10 times with growing backoff and prints
  `Retrying in 12s (attempt 3/10)` between attempts. Left alone the run sits
  idle (burning its wall clock and the worker slot) for many minutes before
  qwen gives up with a generic error. `ClaudeSession` feeds every raw line to
  `track/3`; once the streak of retries (no assistant message in between) has
  used `retry_wall_budget_s` of wall time, counting the backoff qwen announced
  next, `track/3` flags the session. `Arbiter.Worker` then kills the process and
  classifies the stop as `:quota_exhausted` via `stop_reason/2`, which opens the
  account hold and queues the resume exactly as for Claude's usage limit.

  Config: `config :arbiter, :qwen_quota, retry_wall_budget_s: 300, hold_s: 900`.
  """

  alias Arbiter.Worker.StopReason

  @default_budget_s 300
  @default_hold_s 900

  @notice ~r/Retrying in (?:(?<m>\d+)m\s*)?(?<s>\d+)s\s*\(attempt (?<n>\d+)\/(?<max>\d+)\)/i

  @doc "Parse a retry notice line."
  @spec parse(String.t()) ::
          {:ok, %{delay_s: non_neg_integer(), attempt: pos_integer(), max: pos_integer()}}
          | :error
  def parse(line) when is_binary(line) do
    case Regex.named_captures(@notice, line) do
      %{"m" => m, "s" => s, "n" => n, "max" => max} ->
        {:ok,
         %{
           delay_s: to_int(m) * 60 + to_int(s),
           attempt: to_int(n),
           max: to_int(max)
         }}

      _ ->
        :error
    end
  end

  @doc "The wall-time budget in seconds."
  @spec budget_s() :: pos_integer()
  def budget_s, do: setting(:retry_wall_budget_s, @default_budget_s)

  @doc "How long the account is held once the budget is spent, in seconds."
  @spec hold_s() :: pos_integer()
  def hold_s, do: setting(:hold_s, @default_hold_s)

  @doc """
  Fold one raw output line into the session. Sets `:qwen_retry` (the streak) and,
  once the budget is spent, `:qwen_retry_hold`. `now_ms` is a monotonic
  millisecond clock, injectable for tests.
  """
  @spec track(map(), String.t(), integer()) :: map()
  def track(session, line, now_ms \\ System.monotonic_time(:millisecond)) do
    with nil <- Map.get(session, :qwen_retry_hold),
         {:ok, notice} <- parse(line) do
      since = get_in(session, [:qwen_retry, :since_ms]) || now_ms
      waited_ms = now_ms - since + notice.delay_s * 1000
      streak = %{since_ms: since, attempt: notice.attempt, max: notice.max}
      session = Map.put(session, :qwen_retry, streak)

      if waited_ms >= budget_s() * 1000 do
        info = %{attempts: notice.attempt, waited_s: div(waited_ms, 1000)}
        Map.put(session, :qwen_retry_hold, info)
      else
        session
      end
    else
      _ -> session
    end
  end

  @doc "An assistant message means the endpoint answered: the retry streak is over."
  @spec reset(map()) :: map()
  def reset(session), do: Map.delete(session, :qwen_retry)

  @doc "The `:quota_exhausted` stop for a session flagged by `track/3`."
  @spec stop_reason(%{attempts: integer(), waited_s: integer()}, integer() | nil) ::
          StopReason.t()
  def stop_reason(%{attempts: attempts, waited_s: waited_s}, exit_status) do
    %StopReason{
      category: :quota_exhausted,
      summary:
        "qwen's endpoint kept answering 429 (retry attempt #{attempts}, ~#{waited_s}s of " <>
          "backoff, budget #{budget_s()}s); stopped and held instead of waiting it out",
      remediation:
        "The endpoint is rate limiting this account. Dispatch to it stays held for " <>
          "#{hold_s()}s, or route to another provider.",
      exit_status: exit_status,
      signal: nil,
      retry_after: DateTime.add(DateTime.utc_now(), hold_s(), :second)
    }
  end

  defp to_int(""), do: 0
  defp to_int(s), do: String.to_integer(s)

  defp setting(key, default) do
    case :arbiter |> Application.get_env(:qwen_quota, []) |> Keyword.get(key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end
end
