defmodule Arbiter.Loop.Scarcity.Draw do
  @moduledoc """
  Draw calibration over the quota history (bd-3is1nz, R3 of
  `docs/design/paced-quota-routing-signals.md`): the window share per weighted
  token for each (pool, window, model), read from `quota_snapshots` deltas
  against `usage_events`.

  `Arbiter.Loop.Scarcity` calibrates Claude's 5h capacity from the one reading
  of the window now in force. This extends it to every pool the history holds
  — Claude's 5h and 7d, Codex's windows, each Antigravity model group — and to
  a coefficient per model, by feeding the interval equations to
  `Arbiter.Loop.Scarcity.Calibration` (non-negative least squares).

  ## Where an observation comes from

  For one account and one (bucket, window) the history is a series of readings.
  Walking it in time order, an *interval* runs from an anchor capture to a later
  one at least `min_interval` away (close captures coalesce, because a
  utilization reading is coarse and a sub-interval delta is mostly rounding). Its
  share is the utilization delta; its draw is every `usage_events` row of the
  same account, in the same pool, whose `occurred_at` falls in `(anchor, end]` —
  the same half-open convention `docs/loop-scarcity-unit.md` states for the 5h
  calibration (the numerator ends at the capture, never at `now`).

  An interval is **dropped**, never diffed, when

    * the window reset inside it (`resets_at` moved, or utilization fell), since
      a delta across a reset is not a draw, or
    * it is longer than the window can hold (a polling gap), since the usage in
      it cannot be pinned to the readings.

  Dropping loses data and invents none. What the ledger can't see — an
  interactive session on the same plan — is the `background_share_per_hour`
  term of the fit, so it does not inflate the per-model coefficients.

  ## Shadow only

  Nothing on a routing path calls this. `calibrate/1` is read-only and is
  invoked from `mix arbiter.draw_calibration`; `lookup/4` and
  `Arbiter.Loop.Scarcity.draw_share/5` are the seam R11 will read. Both return
  `nil`, never `0.0`, for a (pool, window, model) the fit could not support.
  """

  require Ash.Query

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Loop.Scarcity
  alias Arbiter.Loop.Scarcity.Calibration
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Usage

  @five_hour_seconds 5 * 3600
  @week_seconds 7 * 86_400
  # `resets_at` is reported to the second but jitters between polls; a new
  # window instance moves it by hours.
  @reset_jitter_seconds 600
  # Below this a utilization reading's own rounding dominates the delta.
  @utilization_epsilon 1.0e-9

  @type result :: %{
          account_id: String.t(),
          provider: String.t(),
          pool: String.t(),
          window: String.t(),
          fit: Calibration.fit()
        }

  @doc """
  Calibrate every (account, pool, window) the history holds.

  Options: `:since` / `:until` bound the history read (default: the last 30
  days to now), `:min_interval_seconds` and `:max_interval_seconds` override the
  per-window defaults, and `:min_observations` / `:min_model_observations` /
  `:background` pass through to `Calibration.fit/2`.

  One result per (account, provider, bucket, window), with `fit.status ==
  :insufficient_data` where the history can't support a coefficient. Accounts are
  fitted separately because two accounts on one provider may be on different
  plans.
  """
  @spec calibrate(keyword()) :: [result()]
  def calibrate(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)
    since = Keyword.get_lazy(opts, :since, fn -> DateTime.add(until, -30 * 86_400, :second) end)
    snapshots = read_snapshots(since, until)
    usage = read_usage(Enum.map(snapshots, & &1.provider_account_id) |> Enum.uniq(), since, until)

    snapshots
    |> Enum.group_by(&{&1.provider_account_id, &1.provider, &1.bucket, &1.window})
    |> Enum.map(fn {{account_id, provider, bucket, window}, samples} ->
      pool = pool(provider, bucket)

      observations =
        observations(samples, Map.get(usage, account_id, []),
          pool: pool,
          provider: provider,
          window: window,
          min_interval_seconds: opts[:min_interval_seconds],
          max_interval_seconds: opts[:max_interval_seconds]
        )

      fit_opts = Keyword.take(opts, [:min_observations, :min_model_observations, :background])

      %{
        account_id: account_id,
        provider: provider,
        pool: pool,
        window: window,
        fit: Calibration.fit(observations, fit_opts)
      }
    end)
    |> Enum.sort_by(&{&1.pool, &1.window, &1.account_id})
  end

  @doc """
  The interval observations for one (account, pool, window): `samples` are
  snapshot-shaped maps (`:utilization`, `:resets_at`, `:captured_at`) and
  `usage` are `usage_events`-shaped maps. Pure; see the moduledoc for the rules.
  """
  @spec observations([map()], [map()], keyword()) :: [Calibration.observation()]
  def observations(samples, usage, opts) do
    pool = Keyword.fetch!(opts, :pool)
    provider = Keyword.fetch!(opts, :provider)
    window = Keyword.fetch!(opts, :window)
    min_s = opts[:min_interval_seconds] || min_interval(window)
    max_s = opts[:max_interval_seconds] || max_interval(window)

    pooled =
      usage
      |> Enum.filter(&(ModelFamily.classify(&1.provider || provider, &1.model).pool == pool))
      |> Enum.sort_by(& &1.occurred_at, DateTime)

    case Enum.sort_by(samples, & &1.captured_at, DateTime) do
      [] -> []
      [anchor | rest] -> walk(rest, anchor, pooled, min_s, max_s, [])
    end
  end

  defp walk([], _anchor, _usage, _min_s, _max_s, acc), do: Enum.reverse(acc)

  defp walk([sample | rest], anchor, usage, min_s, max_s, acc) do
    elapsed = DateTime.diff(sample.captured_at, anchor.captured_at)

    cond do
      reset?(anchor, sample) ->
        walk(rest, sample, usage, min_s, max_s, acc)

      elapsed < min_s ->
        walk(rest, anchor, usage, min_s, max_s, acc)

      elapsed > max_s ->
        walk(rest, sample, usage, min_s, max_s, acc)

      true ->
        walk(rest, sample, usage, min_s, max_s, [interval(anchor, sample, usage, elapsed) | acc])
    end
  end

  defp interval(anchor, sample, usage, elapsed) do
    draws =
      usage
      |> Enum.filter(fn u ->
        DateTime.compare(u.occurred_at, anchor.captured_at) == :gt and
          DateTime.compare(u.occurred_at, sample.captured_at) != :gt
      end)
      |> Enum.group_by(&(&1.model || "unknown"), &Scarcity.weighted_tokens/1)
      |> Map.new(fn {model, tokens} -> {model, Enum.sum(tokens)} end)

    %{share: sample.utilization - anchor.utilization, hours: elapsed / 3600, draws: draws}
  end

  defp reset?(anchor, sample) do
    sample.utilization < anchor.utilization - @utilization_epsilon or
      window_moved?(anchor.resets_at, sample.resets_at)
  end

  defp window_moved?(%DateTime{} = a, %DateTime{} = b),
    do: abs(DateTime.diff(a, b)) > @reset_jitter_seconds

  defp window_moved?(_a, _b), do: false

  defp min_interval("5h"), do: 1800
  defp min_interval(_window), do: 4 * 3600

  defp max_interval("5h"), do: @five_hour_seconds
  defp max_interval(_window), do: @week_seconds

  @doc """
  The pool a snapshot's (provider, bucket) draws on, in `ModelFamily.classify/2`'s
  naming: the provider itself, or `provider:group` for a bucketed provider.
  """
  @spec pool(String.t(), String.t() | nil) :: String.t()
  def pool(provider, bucket) when bucket in [nil, ""], do: provider
  def pool(provider, provider), do: provider
  def pool(provider, bucket), do: "#{provider}:#{bucket}"

  @doc """
  The calibrated share per weighted token for `model` on (`pool`, `window`), or
  `nil` — never `0.0` — when no fit supports one. With several accounts
  calibrated for the pool, the fit with the most intervals answers; pass
  `:account_id` to ask about one.
  """
  @spec lookup([result()], String.t(), String.t(), String.t(), keyword()) :: float() | nil
  def lookup(results, pool, window, model, opts \\ []) do
    account = Keyword.get(opts, :account_id)

    results
    |> Enum.filter(
      &(&1.pool == pool and &1.window == window and (is_nil(account) or &1.account_id == account))
    )
    |> Enum.flat_map(fn %{fit: fit} ->
      case fit.models[model] do
        %{status: :calibrated, share_per_weighted_token: c, n: n} when is_number(c) and c > 0.0 ->
          [{n, c}]

        _ ->
          []
      end
    end)
    |> case do
      [] -> nil
      found -> found |> Enum.max_by(&elem(&1, 0)) |> elem(1)
    end
  end

  @doc "A plain-text table of `calibrate/1` results, for an operator to read."
  @spec format([result()]) :: String.t()
  def format([]), do: "No quota history to calibrate from."

  def format(results) do
    Enum.map_join(results, "\n\n", &format_result/1)
  end

  defp format_result(%{fit: fit} = r) do
    head = "#{r.pool} / #{r.window} (account #{r.account_id}, #{fit.n} intervals)"

    case fit.status do
      :insufficient_data ->
        "#{head}: insufficient data (#{fit.reason})" <> format_models(fit.models)

      :calibrated ->
        head <> format_models(fit.models) <> format_background(fit.background_share_per_hour)
    end
  end

  defp format_models(models) do
    models
    |> Enum.sort()
    |> Enum.map_join(fn {model, e} ->
      case e do
        %{status: :calibrated, share_per_weighted_token: c} ->
          # `c` is a fraction of the window per weighted token: x1e6 tokens, x100 percent.
          "\n  #{model}: #{:erlang.float_to_binary(c * 1.0e8, decimals: 4)}% of the window per 1M weighted tokens"

        %{reason: reason} ->
          "\n  #{model}: insufficient data (#{reason})"
      end
    end)
  end

  defp format_background(nil), do: "\n  unattributed traffic: not separable from the data"

  defp format_background(c),
    do:
      "\n  unattributed traffic: #{:erlang.float_to_binary(c * 100, decimals: 3)}% of the window per hour"

  # ---- reads ---------------------------------------------------------------

  defp read_snapshots(since, until) do
    QuotaSnapshot
    |> Ash.Query.filter(captured_at >= ^since and captured_at <= ^until)
    |> Ash.Query.sort(captured_at: :asc)
    |> Ash.read!()
  end

  # `raw` is the heavy column on this table and calibration never reads it.
  defp read_usage([], _since, _until), do: %{}

  defp read_usage(account_ids, since, until) do
    Usage.Event
    |> Ash.Query.filter(
      provider_account_id in ^account_ids and occurred_at > ^since and occurred_at <= ^until
    )
    |> Ash.Query.select([
      :provider_account_id,
      :provider,
      :model,
      :occurred_at,
      :tokens_in,
      :tokens_out,
      :cache_creation_tokens,
      :cache_read_tokens
    ])
    |> Ash.read!()
    |> Enum.group_by(& &1.provider_account_id)
  end
end
