defmodule Arbiter.Quota.BudgetCalibration do
  @moduledoc """
  Seat-hour calibration (bd-c1dief, DC2 of
  `docs/design/provider-dynamic-concurrency.md` §3.4): how much of a quota
  window one seat draws in an hour, `ρ`, for each (account, pool, window).

  For each series of `quota_snapshots` captures it fits

      Δu = ρ · seat_hours + b · hours

  over the intervals between captures, by the same non-negative least squares
  (`Arbiter.Loop.Scarcity.Calibration.fit/2`) the per-model draw calibration
  uses, and over the same intervals (`Arbiter.Loop.Scarcity.Draw.intervals/3`:
  close captures coalesce, an interval across a reset or a polling gap is
  dropped). `seat_hours` is the trapezoid of the `seats` column over every
  capture in the interval; until that column has history it is reconstructed
  as run hours from `worker_runs`, which overstates `ρ` per seat (an idle
  pinned seat draws nothing), so a budget built on it comes out low, the safe
  side. The fit needs no token capture.

  ## The ladder

  "Absence is never zero." `resolve/3` picks the `ρ` to use:

    * **rung 0** — the account's own fit, when it has at least 8 intervals, at
      least 3 with seats, and *measures a seat*: `fit/2` returned a coefficient
      and its one-sided 95% lower bound, `ρ − t₀.₉₅·se(ρ)`, is above 0. A pool
      held at its ceiling has `seat_hours` moving with `hours`, so the data
      cannot split the draw between seats and background; such a fit predicts
      the past as well as the true one and only shows once more seats run.
    * **rung 1** — the median `ρ` of the other accounts of the same provider
      whose fit does measure a seat.
    * **rung 2** — the prior `1 / (W · k)`: `W` the window in hours, `k` the
      account's `max_concurrent` (2 when unset).

  No `ρ` is taken below the floor `ρ_min = prior / 4`: a fit that passes but
  comes out lower is clamped to it, never dropped, so a seat measured cheaper
  never gets a smaller budget than one measured dearer. The prior is `4·ρ_min`,
  so rung 2 is never clamped (I11).

  `H`, the horizon, is the median In-progress life of tickets over 30 days,
  from the first `active` transition to leaving `active`
  (`ticket_transitions`), clamped to [1 h, 4 h] and 2 h until measured.

  ## Shadow only

  Read-only, and nothing on an admission, gate or board path calls it
  (`Arbiter.Quota.BudgetCalibrationShadowTest` pins that). Its callers are
  `mix arbiter.budget_calibration`, `Arbiter.Release.budget_calibration/0` and
  the admission shadow report (`Arbiter.Board.AdmissionShadowReport`, DC7).
  DC3's `Budget` is the first consumer.
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Loop.Scarcity.Calibration
  alias Arbiter.Loop.Scarcity.Draw
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Tasks.TicketTransition
  alias Arbiter.Workers.Run

  @seat "seat"
  @min_observations 8
  @min_seat_observations 3
  @floor_divisor 4
  @default_k 2
  @default_horizon_hours 2.0
  @horizon_range {1.0, 4.0}
  @default_days 30

  @type reason ::
          :too_few_observations
          | :too_few_model_observations
          | :no_identifiable_model
          | :collinear
          | :non_positive
          | :no_standard_error
          | :no_peer_fit
          | :unknown_window
          | {:not_distinguishable_from_zero, float()}

  @type resolution :: %{
          rung: 0 | 1 | 2,
          rho: float(),
          raw_rho: float(),
          floored?: boolean(),
          passed_over: [{0 | 1, reason()}]
        }

  @type result :: %{
          required(:account_id) => String.t(),
          required(:provider) => String.t(),
          required(:pool) => String.t(),
          required(:window) => String.t(),
          required(:fit) => Calibration.fit(),
          required(:observations) => [Calibration.observation()],
          required(:prior) => float() | nil,
          required(:floor) => float() | nil,
          required(:horizon_hours) => float(),
          required(:rung) => 0 | 1 | 2 | nil,
          required(:rho) => float() | nil,
          required(:raw_rho) => float() | nil,
          required(:floored?) => boolean(),
          required(:passed_over) => [{0 | 1 | 2, reason()}]
        }

  # ---- the ladder (pure) ---------------------------------------------------

  @doc """
  The prior `ρ` for a window of `window_seconds`: `1 / (W · k)`, `W` in hours
  and `k` the account's `max_concurrent`, or 2 when that is unset. With no
  measurement this assumes the operator's ceiling is the steady state.
  """
  @spec prior(pos_integer(), integer() | nil) :: float()
  def prior(window_seconds, max_concurrent) do
    k = if is_integer(max_concurrent) and max_concurrent > 0, do: max_concurrent, else: @default_k
    1 / (window_seconds / 3600 * k)
  end

  @doc "The floor `ρ_min = prior / 4`."
  @spec rho_floor(float()) :: float()
  def rho_floor(prior), do: prior / @floor_divisor

  @doc """
  `{:ok, ρ}` when `fit` measures a seat, else `{:error, reason}`. A coefficient
  `fit/2` withheld (`:non_positive`, `:collinear`, too few intervals) is an
  error with its reason; a positive one whose one-sided 95% lower confidence
  bound is not above 0 is `{:not_distinguishable_from_zero, t}`.
  """
  @spec measure(Calibration.fit()) :: {:ok, float()} | {:error, reason()}
  def measure(%{status: :calibrated, models: %{@seat => entry}} = fit) do
    case entry do
      %{status: :calibrated, share_per_weighted_token: rho, std_error: se}
      when is_number(se) and is_integer(fit.dof) ->
        t_crit = Calibration.t_critical(fit.dof)

        if rho - t_crit * se > 0.0,
          do: {:ok, rho},
          else: {:error, {:not_distinguishable_from_zero, t_value(rho, se)}}

      %{status: :calibrated} ->
        {:error, :no_standard_error}

      %{reason: reason} ->
        {:error, reason}
    end
  end

  def measure(%{reason: reason}) when not is_nil(reason), do: {:error, reason}
  def measure(_fit), do: {:error, :no_identifiable_model}

  defp t_value(rho, se) when se > 0.0, do: rho / se
  defp t_value(_rho, _se), do: 0.0

  @doc """
  Pick the `ρ` for one (account, pool, window): its own fit (rung 0), else the
  median of `peer_rhos` (rung 1), else `prior` (rung 2). `peer_rhos` are the
  measured `ρ`s of the provider's other accounts. A rung passed over is kept in
  `:passed_over` with why; a `ρ` under the floor is clamped (`floored?: true`,
  the fitted value in `:raw_rho`).
  """
  @spec resolve(Calibration.fit(), float(), [float()]) :: resolution()
  def resolve(fit, prior, peer_rhos) do
    case measure(fit) do
      {:ok, rho} ->
        clamp(0, rho, prior, [])

      {:error, why} ->
        case peer_rhos do
          [] ->
            %{
              rung: 2,
              rho: prior,
              raw_rho: prior,
              floored?: false,
              passed_over: [{0, why}, {1, :no_peer_fit}]
            }

          rhos ->
            clamp(1, median(rhos), prior, [{0, why}])
        end
    end
  end

  defp clamp(rung, rho, prior, passed) do
    floor = rho_floor(prior)

    %{
      rung: rung,
      rho: max(rho, floor),
      raw_rho: rho,
      floored?: rho < floor,
      passed_over: passed
    }
  end

  # ---- observations (pure) -------------------------------------------------

  @doc """
  The fit's observations for one (account, pool, window) series. `samples` are
  snapshot-shaped maps (`:utilization`, `:resets_at`, `:captured_at`, `:seats`)
  and `runs` are `worker_runs`-shaped maps (`:started_at`, `:completed_at`,
  `:provider`, `:model`) of the same account, used only for an interval whose
  captures do not all carry `seats`. Options: `:window` and `:pool` (required),
  `:min_interval_seconds` / `:max_interval_seconds`.
  """
  @spec observations([map()], [map()], keyword()) :: [Calibration.observation()]
  def observations(samples, runs, opts) do
    pool = Keyword.fetch!(opts, :pool)
    window = Keyword.fetch!(opts, :window)
    pooled = Enum.filter(runs, &(run_pool(&1) == pool))

    samples
    |> Draw.intervals(window, opts)
    |> Enum.map(fn %{anchor: anchor, sample: sample, elapsed: elapsed, points: points} ->
      seat_hours =
        if Enum.all?(points, &is_integer(&1.seats)),
          do: trapezoid(points),
          else: run_hours(pooled, anchor.captured_at, sample.captured_at)

      %{
        share: sample.utilization - anchor.utilization,
        hours: elapsed / 3600,
        draws: %{@seat => seat_hours}
      }
    end)
  end

  defp trapezoid(points) do
    points
    |> Enum.zip(tl(points))
    |> Enum.reduce(0.0, fn {a, b}, acc ->
      acc + (a.seats + b.seats) / 2 * DateTime.diff(b.captured_at, a.captured_at) / 3600
    end)
  end

  defp run_hours(runs, from, to) do
    runs
    |> Enum.map(fn run ->
      start = later(run.started_at, from)
      stop = earlier(run.completed_at || to, to)
      max(DateTime.diff(stop, start), 0) / 3600
    end)
    |> Enum.sum()
  end

  defp later(nil, b), do: b
  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp run_pool(run), do: ModelFamily.classify(run.provider, run.model).pool

  # ---- the horizon H (pure) ------------------------------------------------

  @doc """
  The median In-progress life per pool, in hours: from a ticket's first
  `active` transition to its leaving `active`. `transitions` are
  `ticket_transitions`-shaped maps and `pools` maps a ticket id to its pool; a
  ticket still active, or pinned to no pool, is not counted. Clamped to
  [1 h, 4 h]; a pool with no finished ticket is absent (`horizon_for/2` says 2 h).
  """
  @spec horizon([map()], %{String.t() => String.t()}) :: %{String.t() => float()}
  def horizon(transitions, pools) do
    transitions
    |> Enum.group_by(& &1.ticket_id)
    |> Enum.flat_map(fn {ticket, rows} ->
      with pool when is_binary(pool) <- Map.get(pools, ticket),
           {:ok, hours} <- active_life(Enum.sort_by(rows, & &1.at, DateTime)) do
        [{pool, hours}]
      else
        _ -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {pool, lives} -> {pool, lives |> median() |> clamp_horizon()} end)
  end

  defp active_life(rows) do
    with {entered, rest} <- split_at_first(rows, &(&1.to_state == :active)),
         [left | _] <- Enum.drop_while(rest, &(&1.from_state != :active)) do
      {:ok, DateTime.diff(left.at, entered.at) / 3600}
    else
      _ -> :error
    end
  end

  defp split_at_first(rows, pred) do
    case Enum.split_while(rows, &(not pred.(&1))) do
      {_before, [entered | rest]} -> {entered, rest}
      _ -> :error
    end
  end

  defp clamp_horizon(hours) do
    {lo, hi} = @horizon_range
    hours |> max(lo) |> min(hi)
  end

  @doc "`H` for `pool` out of `horizon/2`'s map: 2 h until measured."
  @spec horizon_for(%{String.t() => float()}, String.t()) :: float()
  def horizon_for(horizons, pool), do: Map.get(horizons, pool, @default_horizon_hours)

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
  end

  # ---- the report ----------------------------------------------------------

  @doc """
  Calibrate every (account, pool, window) the history holds. Options:
  `:since` / `:until` bound the history read (default the last 30 days to now).

  One `t:result/0` per (account, provider, pool, window): the fit and the
  observations it was fitted on, and the rung, `ρ`, prior, floor and `H` the
  ladder lands on. Read-only.
  """
  @spec calibrate(keyword()) :: [result()]
  def calibrate(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)

    since =
      Keyword.get_lazy(opts, :since, fn ->
        DateTime.add(until, -@default_days * 86_400, :second)
      end)

    snapshots = read_snapshots(since, until)
    account_ids = snapshots |> Enum.map(& &1.provider_account_id) |> Enum.uniq()
    accounts = read_accounts(account_ids)
    runs = read_runs(account_ids, since, until)
    horizons = read_horizons(since, until)

    fits =
      snapshots
      |> Enum.group_by(&{&1.provider_account_id, &1.provider, &1.bucket, &1.window})
      |> Enum.map(fn {{account_id, provider, bucket, window}, samples} ->
        pool = Draw.pool(provider, bucket)

        obs = observations(samples, Map.get(runs, account_id, []), pool: pool, window: window)

        %{
          account_id: account_id,
          provider: provider,
          pool: pool,
          window: window,
          observations: obs,
          fit:
            Calibration.fit(obs,
              min_observations: @min_observations,
              min_model_observations: @min_seat_observations
            )
        }
      end)

    fits
    |> Enum.map(&finish(&1, fits, accounts, horizons))
    |> Enum.sort_by(&{&1.pool, &1.window, &1.account_id})
  end

  defp finish(entry, fits, accounts, horizons) do
    account = Map.get(accounts, entry.account_id)
    seconds = Gate.window_seconds(entry.window, account)
    horizon = horizon_for(horizons, entry.pool)

    case seconds do
      nil ->
        Map.merge(entry, %{
          prior: nil,
          floor: nil,
          horizon_hours: horizon,
          rung: nil,
          rho: nil,
          raw_rho: nil,
          floored?: false,
          passed_over: [{2, :unknown_window}]
        })

      seconds ->
        prior = prior(seconds, account && account.max_concurrent)
        peers = peer_rhos(entry, fits)

        entry
        |> Map.merge(resolve(entry.fit, prior, peers))
        |> Map.merge(%{prior: prior, floor: rho_floor(prior), horizon_hours: horizon})
    end
  end

  # The provider's other accounts on the same pool and window whose fit measures a seat.
  defp peer_rhos(entry, fits) do
    for other <- fits,
        other.account_id != entry.account_id,
        other.provider == entry.provider,
        other.pool == entry.pool,
        other.window == entry.window,
        {:ok, rho} <- [measure(other.fit)],
        do: rho
  end

  @doc "A plain-text report of `calibrate/1` results, for an operator to read."
  @spec format([result()]) :: String.t()
  def format([]), do: "No quota history to calibrate from."
  def format(results), do: Enum.map_join(results, "\n\n", &format_result/1)

  defp format_result(r) do
    head = "#{r.pool} / #{r.window} (account #{r.account_id}, #{r.fit.n} intervals)"

    body =
      case r.rung do
        nil ->
          "\n  no budget: window length unknown (#{inspect(r.passed_over)})"

        rung ->
          "\n  #{rho_line(r, rung)}" <>
            "\n  prior #{pct(r.prior)}/seat-h, floor #{pct(r.floor)}/seat-h" <>
            passed_lines(r.passed_over) <>
            fit_line(r.fit)
      end

    head <> body <> "\n  H #{:erlang.float_to_binary(r.horizon_hours, decimals: 1)} h"
  end

  defp rho_line(r, 0), do: "rung 0 (own fit): #{pct(r.rho)}/seat-h#{floor_note(r)}"
  defp rho_line(r, 1), do: "rung 1 (other accounts): #{pct(r.rho)}/seat-h#{floor_note(r)}"
  defp rho_line(r, 2), do: "rung 2 (prior): #{pct(r.rho)}/seat-h"

  defp floor_note(%{floored?: true} = r), do: " (floor; fit #{pct(r.raw_rho)})"
  defp floor_note(_r), do: ""

  defp passed_lines(passed) do
    Enum.map_join(passed, fn {rung, why} -> "\n  passed over rung #{rung}: #{why_text(why)}" end)
  end

  defp why_text({:not_distinguishable_from_zero, t}),
    do: "fit not distinguishable from 0 (t = #{:erlang.float_to_binary(t * 1.0, decimals: 2)})"

  defp why_text(why), do: to_string(why)

  defp fit_line(%{status: :calibrated, models: %{@seat => %{status: :calibrated} = e}} = fit) do
    se = if e.std_error, do: " ± #{pct(e.std_error)}", else: ""

    bg =
      case fit.background_share_per_hour do
        nil -> "background not separable"
        b -> "background #{pct(b)}/h"
      end

    "\n  fit: #{pct(e.share_per_weighted_token)}#{se}/seat-h, #{bg}"
  end

  defp fit_line(_fit), do: ""

  defp pct(x), do: "#{:erlang.float_to_binary(x * 100, decimals: 3)}%"

  # ---- reads ---------------------------------------------------------------

  defp read_snapshots(since, until) do
    QuotaSnapshot
    |> Ash.Query.filter(captured_at >= ^since and captured_at <= ^until)
    |> Ash.Query.sort(captured_at: :asc)
    |> Ash.read!()
  end

  defp read_accounts([]), do: %{}

  defp read_accounts(ids) do
    ProviderAccount
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read!()
    |> Map.new(&{&1.id, &1})
  end

  # `output_lines` is the heavy column on `worker_runs` and calibration never reads it.
  defp read_runs([], _since, _until), do: %{}

  defp read_runs(account_ids, since, until) do
    Run
    |> Ash.Query.filter(
      provider_account_id in ^account_ids and started_at <= ^until and
        (is_nil(completed_at) or completed_at >= ^since)
    )
    |> Ash.Query.select([:provider_account_id, :provider, :model, :started_at, :completed_at])
    |> Ash.read!()
    |> Enum.group_by(& &1.provider_account_id)
  end

  defp read_horizons(since, until) do
    transitions =
      TicketTransition
      |> Ash.Query.filter(
        at >= ^since and at <= ^until and (to_state == :active or from_state == :active)
      )
      |> Ash.Query.select([:ticket_id, :from_state, :to_state, :at])
      |> Ash.read!()

    horizon(transitions, ticket_pools(Enum.map(transitions, & &1.ticket_id) |> Enum.uniq()))
  end

  # A ticket's pool is that of its first implementing run: the account and model
  # the implementer pin resolved to.
  defp ticket_pools([]), do: %{}

  defp ticket_pools(ticket_ids) do
    Run
    |> Ash.Query.filter(task_id in ^ticket_ids and kind == :implement)
    |> Ash.Query.select([:task_id, :provider, :model, :started_at])
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.read!()
    |> Enum.reduce(%{}, fn run, acc ->
      case run_pool(run) do
        pool when is_binary(pool) -> Map.put_new(acc, run.task_id, pool)
        _ -> acc
      end
    end)
  end
end
