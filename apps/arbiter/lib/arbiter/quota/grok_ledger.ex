defmodule Arbiter.Quota.GrokLedger do
  @moduledoc """
  grok's quota, estimated from the ledger (bd-cwq8b0, epic bd-6f3edy).

  grok's free tier allows about 500K tokens per **rolling 24h** window, cached
  tokens counted (bd-73uvlo / bd-7nbwix), and there is no safe pollable
  endpoint for it: `grok usage` is per local session, and calling the billing
  endpoint with the session token directly is the ToS grey area bd-73uvlo
  flagged. So the headroom is an estimate: the sum of grok `usage_events` over
  the trailing 24h against a configurable cap.

      config :arbiter, :grok_quota, cap_tokens: 500_000

  `snapshot/1` projects that onto the provider-neutral
  `Arbiter.Quota.Gate.Snapshot` (window label `"24h"`, utilization
  `used / cap`), so `Arbiter.Quota.Gate` holds a grok dispatch exactly as it
  holds any other provider, and `Arbiter.Quota.Headroom` ranks it.
  `Arbiter.Quota.latest_for_provider/2` serves it for `"grok"`.

  ## The reset time is the window rolling, not a clock time

  `reset_at` is the first moment enough old usage has aged out of the window
  for utilization to drop below the gate's threshold. There is no fixed reset.

  ## A 429 is a measurement

  A run that stopped on `subscription:free-usage-exhausted`
  (`Arbiter.Worker.StopReason`, category `:quota_exhausted`) carries the
  server's own count, `tokens (actual/limit): N/M`, in its `failure_reason`.
  That count includes usage Arbiter never saw (an interactive `grok` session on
  the same account), so the ledger alone can sit under the cap while the
  server says no. `exhaustion/1` reads the newest such run inside the window
  and `snapshot/1` adds the part of `N` the ledger cannot explain (`N` minus
  the ledger's sum over the 24h before the 429) as one pseudo-event stamped
  when the 429 happened. That unseen usage ages out with the window like any
  other, so the hold lifts when the *rolling window* drains, at the latest 24h
  after the 429, never at a made-up clock time.

  The ledger is **not** scoped to a provider account: the free tier is one
  xAI account and the cap belongs to it, so every `provider = "grok"` row
  counts.
  """

  import Ecto.Query, only: [from: 2]

  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Repo
  alias Arbiter.Usage.LedgerRow
  alias Arbiter.Workers.Run

  require Ash.Query
  require Logger

  @provider "grok"
  @window_label "24h"
  @window_seconds 24 * 3600
  @default_cap 500_000

  # The window is `(now - 24h, now]`, so a row is out of it one tick after its
  # 24h mark; the buffer keeps `reset_at` on the right side of that edge.
  @reset_buffer_seconds 1

  @exhausted_count ~r/tokens \(actual\/limit\):\s*(\d+)\/(\d+)/

  @type exhaustion :: %{at: DateTime.t(), actual: pos_integer() | nil, limit: pos_integer() | nil}

  @doc "The window length every grok quota figure here is over, in seconds."
  @spec window_seconds() :: pos_integer()
  def window_seconds, do: @window_seconds

  @doc """
  The token cap per rolling 24h (`config :arbiter, :grok_quota, cap_tokens:`),
  default #{@default_cap}. A non-positive or non-integer value is ignored.
  """
  @spec cap() :: pos_integer()
  def cap do
    case :arbiter |> Application.get_env(:grok_quota, []) |> Keyword.get(:cap_tokens) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_cap
    end
  end

  @doc """
  Tokens the ledger holds for grok over the trailing 24h, **excluding** the
  unseen usage a 429 reports (see the moduledoc). Options: `:now`.
  """
  @spec used(keyword()) :: non_neg_integer()
  def used(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    window_start(now) |> events(now) |> sum_within(now)
  end

  @doc """
  The newest grok run that stopped on a free-usage 429 and did so inside the
  trailing 24h, as `%{at, actual, limit}` (the counts are `nil` when the
  failure text carried none), or `nil`. Options: `:now`.
  """
  @spec exhaustion(keyword()) :: exhaustion() | nil
  def exhaustion(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    since = window_start(now)

    Run
    |> Ash.Query.filter(
      provider == ^@provider and stop_category == "quota_exhausted" and completed_at > ^since and
        completed_at <= ^now
    )
    |> Ash.Query.sort(completed_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:completed_at, :failure_reason])
    |> Ash.read!()
    |> case do
      [%{completed_at: %DateTime{} = at, failure_reason: reason}] ->
        {actual, limit} = parse_counts(reason)
        %{at: at, actual: actual, limit: limit}

      _ ->
        nil
    end
  end

  @doc """
  The ledger-estimated quota snapshot for grok, for `Arbiter.Quota.Gate`.

  `nil` (the gate's fail-open input) when the ledger cannot be read. Options:
  `:now`, `:cap`.
  """
  @spec snapshot(keyword()) :: Snapshot.t() | nil
  def snapshot(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cap = Keyword.get_lazy(opts, :cap, &cap/0)
    marker = exhaustion(now: now)

    since =
      if marker, do: DateTime.add(marker.at, -@window_seconds, :second), else: window_start(now)

    rows =
      since
      |> events(now)
      |> add_unseen(marker, cap)
      |> Enum.sort_by(&DateTime.to_unix(elem(&1, 0), :microsecond))

    used = sum_within(rows, now)

    %Snapshot{
      provider: @provider,
      utilization: used / cap,
      status: if(used >= cap, do: "limit_reached"),
      reset_at: reset_at(rows, used, cap, now),
      captured_at: now,
      window_label: @window_label
    }
  rescue
    error ->
      Logger.warning("GrokLedger: could not read the ledger (#{Exception.message(error)})")
      nil
  end

  # ---- internals ---------------------------------------------------------

  defp window_start(now), do: DateTime.add(now, -@window_seconds, :second)

  # `[{occurred_at, tokens}]`, oldest first, in `(since, now]`. With a 429
  # marker `since` reaches back 24h before it: the window the server's count
  # covered.
  defp events(%DateTime{} = since, %DateTime{} = now) do
    from(e in LedgerRow,
      where: e.provider == ^@provider and e.occurred_at > ^since and e.occurred_at <= ^now,
      order_by: e.occurred_at,
      select:
        {e.occurred_at,
         fragment(
           "COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0) + COALESCE(?, 0)",
           e.tokens_in,
           e.cache_read_tokens,
           e.cache_creation_tokens,
           e.tokens_out
         )}
    )
    |> Repo.all()
  end

  defp sum_within(rows, now) do
    start = window_start(now)

    for {at, tokens} <- rows, DateTime.compare(at, start) == :gt, reduce: 0 do
      acc -> acc + tokens
    end
  end

  defp add_unseen(rows, nil, _cap), do: rows

  defp add_unseen(rows, %{at: at, actual: actual}, cap) do
    seen =
      for {row_at, tokens} <- rows,
          DateTime.compare(row_at, at) != :gt,
          DateTime.compare(row_at, DateTime.add(at, -@window_seconds, :second)) == :gt,
          reduce: 0,
          do: (acc -> acc + tokens)

    unseen = max((actual || cap) - seen, 0)
    if unseen > 0, do: [{at, unseen} | rows], else: rows
  end

  # The first moment utilization is back under the gate's threshold: age rows
  # out oldest-first until what is left is under it.
  defp reset_at(rows, used, cap, now) do
    target = cap * Gate.threshold()
    start = window_start(now)

    if used < target do
      nil
    else
      rows
      |> Enum.filter(fn {at, _} -> DateTime.compare(at, start) == :gt end)
      |> Enum.reduce_while(used, fn {at, tokens}, remaining ->
        remaining = remaining - tokens

        if remaining < target,
          do: {:halt, {:lifts, at}},
          else: {:cont, remaining}
      end)
      |> case do
        {:lifts, at} -> DateTime.add(at, @window_seconds + @reset_buffer_seconds, :second)
        _ -> nil
      end
    end
  end

  defp parse_counts(text) when is_binary(text) do
    case Regex.run(@exhausted_count, text) do
      [_, actual, limit] -> {String.to_integer(actual), String.to_integer(limit)}
      _ -> {nil, nil}
    end
  end

  defp parse_counts(_), do: {nil, nil}
end
