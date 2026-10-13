defmodule Arbiter.Quota.SeatWeights do
  @moduledoc """
  Weighted seats from R3's per-model draw (DC11, bd-8lsfey; folds R11;
  `docs/design/provider-dynamic-concurrency.md` §3.4 phase 2, §8).

  Phase 1 counts every seat as 1. A premium-model ticket draws more of the
  window per seat-hour than a cheap one, so under `scheduler_admission: enforce`
  (`Arbiter.Accounts.SeatCheck`) a seat weighs

      weight_m = ρ_m / ρ̄          ρ_m = c_m × τ_m

  where `c_m` is R3's share of the window per weighted token for model `m`
  (`Arbiter.Loop.Scarcity.Draw`, one fit per account, pool and window),
  `τ_m` is the weighted tokens model `m` draws per run-hour, and `ρ̄` is the
  seat-hour-weighted mean of the `ρ_m` over the weighted models, so that the
  mix an account runs averages one seat per seat. Admission then compares
  `Σ weights + weight_new ≤ budget`; with every weight 1 that is phase 1's
  `seats < budget`. The price `δ` is unchanged.

    * **The confidence test.** A model's `c_m` must pass the same one-sided 95%
      test as the seat-hour `ρ` (`c − t·se > 0`, `Calibration.t_critical/1`),
      or its seats weigh 1 as in phase 1: it is absent from `weights/2`. So is
      a model R3 withheld (`:non_positive`, `:collinear`, too few intervals),
      one with no run-hours, and every model of an insufficient fit. Absence is
      never zero.
    * **The floor.** No seat weighs less than `ρ_min / ρ̄` (`weight/3`'s
      `floor`, which `SeatCheck` takes from the pool's published budget), so no
      model looks free.
    * **Run-hours stand in for seat-hours.** An idle pinned seat draws nothing,
      so `τ_m` is per run-hour; the overstatement is the same for every model
      and cancels in `ρ_m / ρ̄`.

  `rates/3` and `weights/2` are pure. `calibrate/1` is the read the budget
  server runs beside `Arbiter.Quota.BudgetCalibration`, off its own process,
  at boot and daily; nothing on an admission path calls it, and under `legacy`
  and `shadow` nothing reads the result (I1, I2).
  """

  require Ash.Query

  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Loop.Scarcity
  alias Arbiter.Loop.Scarcity.Calibration
  alias Arbiter.Loop.Scarcity.Draw
  alias Arbiter.Usage
  alias Arbiter.Workers.Run

  @default_days 30
  @default_floor_ratio 0.25

  @type rate :: %{tau: float(), hours: float(), tokens: float()}
  @type weights :: %{String.t() => float()}

  @type result :: %{
          account_id: String.t(),
          pool: String.t(),
          window: String.t(),
          weights: weights()
        }

  # ---- the pure core -------------------------------------------------------

  @doc """
  Weighted tokens and run-hours per model, from `events` (`usage_events`-shaped
  maps with `:worker_run_id`, `:model` and the token counts) and the `runs`
  they belong to (`:id`, `:started_at`, `:completed_at`). A run's hours go to
  the model that drew most in it; a run still open is charged to `until`. An
  event of no known run is ignored, so the tokens and the hours describe the
  same runs. Returns `%{model => %{tau:, hours:, tokens:}}`, `tau` being the
  tokens per run-hour.
  """
  @spec rates([map()], [map()], DateTime.t()) :: %{String.t() => rate()}
  def rates(events, runs, until) do
    by_run = Map.new(runs, &{&1.id, &1})
    known = Enum.filter(events, &Map.has_key?(by_run, &1.worker_run_id))

    tokens =
      known
      |> Enum.group_by(&(&1.model || "unknown"), &Scarcity.weighted_tokens/1)
      |> Map.new(fn {model, list} -> {model, Enum.sum(list)} end)

    hours =
      known
      |> Enum.group_by(& &1.worker_run_id)
      |> Enum.reduce(%{}, fn {run_id, list}, acc ->
        model = dominant_model(list)

        Map.update(
          acc,
          model,
          run_hours(by_run[run_id], until),
          &(&1 + run_hours(by_run[run_id], until))
        )
      end)

    for {model, h} <- hours, h > 0.0, into: %{} do
      t = Map.get(tokens, model, 0.0)
      {model, %{tau: t / h, hours: h, tokens: t}}
    end
  end

  defp dominant_model(events) do
    events
    |> Enum.group_by(&(&1.model || "unknown"), &Scarcity.weighted_tokens/1)
    |> Enum.max_by(fn {model, list} -> {Enum.sum(list), model} end)
    |> elem(0)
  end

  defp run_hours(run, until) do
    finish = run.completed_at || until
    max(DateTime.diff(finish, run.started_at, :millisecond), 0) / 3_600_000
  end

  @doc """
  The weights of one `Draw` fit (`Calibration.fit/2`'s map) given the `rates/3`
  of the same account and pool. Only the models that pass the confidence test
  and have run-hours are in the map; the rest weigh 1 (`weight/3`).
  """
  @spec weights(Calibration.fit(), %{String.t() => rate()}) :: weights()
  def weights(%{status: :calibrated, models: models, dof: dof}, rates)
      when is_map(models) and is_integer(dof) do
    case Calibration.t_critical(dof) do
      nil ->
        %{}

      t_crit ->
        rhos =
          for {model, entry} <- models,
              %{hours: hours, tau: tau} when hours > 0.0 <- [Map.get(rates, model)],
              c = coefficient(entry, t_crit),
              do: {model, c * tau, hours}

        normalise(rhos)
    end
  end

  def weights(_fit, _rates), do: %{}

  defp coefficient(
         %{status: :calibrated, share_per_weighted_token: c, std_error: se},
         t_crit
       )
       when is_number(c) and is_number(se) and c > 0.0 and c - t_crit * se > 0.0,
       do: c

  defp coefficient(_entry, _t_crit), do: nil

  defp normalise(rhos) do
    total_hours = rhos |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    mean =
      rhos
      |> Enum.map(fn {_m, rho, hours} -> rho * hours end)
      |> Enum.sum()
      |> Kernel./(max(total_hours, 1.0e-12))

    if mean > 0.0,
      do: Map.new(rhos, fn {model, rho, _hours} -> {model, rho / mean} end),
      else: %{}
  end

  @doc """
  `ρ_min / ρ̄` for a pool's published `budget`: the floor under every seat's
  weight (§3.4), from the rates of its binding window. A quarter, the prior's
  floor over the prior, when the budget names no rate.
  """
  @spec floor_ratio(Arbiter.Quota.Budget.t() | nil) :: float()
  def floor_ratio(%{quota_binding: label, windows: windows}) when is_list(windows) do
    case Enum.find(windows, &(&1[:window] == label)) do
      %{rho: rho, rho_min: rho_min} when is_number(rho) and is_number(rho_min) and rho > 0 ->
        rho_min / rho

      _ ->
        @default_floor_ratio
    end
  end

  def floor_ratio(_budget), do: @default_floor_ratio

  @doc """
  What one seat of `model` weighs: its weight, never below `floor`
  (`ρ_min / ρ̄`), and 1 for a model with no weight or none named.

  The calibration keys weights by the model id the CLI reported
  (`"claude-opus-4-8"`), while a dispatch is stamped with the model it was
  routed to, which may be an alias (`"opus"`, `"claude-opus-4-8[1m]"`). An
  exact id wins; otherwise the weights of every calibrated id that carries all
  of the routed name's words are averaged.
  """
  @spec weight(weights() | nil, String.t() | nil, number()) :: float()
  def weight(weights, model, floor) when is_map(weights) and is_binary(model) do
    case find(weights, model) do
      nil -> 1.0
      w -> max(w * 1.0, floor * 1.0)
    end
  end

  def weight(_weights, _model, _floor), do: 1.0

  defp find(weights, model) do
    case Map.fetch(weights, model) do
      {:ok, w} ->
        w

      :error ->
        wanted = words(model)

        matches =
          if wanted == [],
            do: [],
            else: for({id, w} <- weights, wanted -- words(id) == [], do: w)

        if matches == [], do: nil, else: Enum.sum(matches) / length(matches)
    end
  end

  defp words(model) do
    model
    |> String.downcase()
    |> String.replace(~r/\[[^\]]*\]/, "")
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  # ---- the read ------------------------------------------------------------

  @doc """
  The weights of every (account, pool, window) R3's draw calibration fits, for
  the budget server to index. Options: `:since` / `:until` (default the last 30
  days), and `:draw` (`Draw.calibrate/1`'s results, to avoid fitting twice).
  Read-only.
  """
  @spec calibrate(keyword()) :: [result()]
  def calibrate(opts \\ []) do
    until = Keyword.get_lazy(opts, :until, &DateTime.utc_now/0)

    since =
      Keyword.get_lazy(opts, :since, fn ->
        DateTime.add(until, -@default_days * 86_400, :second)
      end)

    draw =
      Keyword.get_lazy(opts, :draw, fn -> Draw.calibrate(since: since, until: until) end)

    usable = Enum.filter(draw, &(&1.fit.status == :calibrated))
    events = read_events(usable |> Enum.map(& &1.account_id) |> Enum.uniq(), since, until)
    runs = read_runs(events)

    usable
    |> Enum.map(fn %{account_id: account, provider: provider, pool: pool} = result ->
      pooled =
        events
        |> Map.get(account, [])
        |> Enum.filter(&(ModelFamily.classify(&1.provider || provider, &1.model).pool == pool))

      rates = rates(pooled, Map.values(runs), until)

      %{
        account_id: account,
        pool: pool,
        window: result.window,
        weights: weights(result.fit, rates)
      }
    end)
    |> Enum.reject(&(&1.weights == %{}))
  end

  defp read_events([], _since, _until), do: %{}

  defp read_events(account_ids, since, until) do
    Usage.Event
    |> Ash.Query.filter(
      provider_account_id in ^account_ids and occurred_at > ^since and occurred_at <= ^until and
        not is_nil(worker_run_id)
    )
    |> Ash.Query.select([
      :provider_account_id,
      :worker_run_id,
      :provider,
      :model,
      :tokens_in,
      :tokens_out,
      :cache_creation_tokens,
      :cache_read_tokens
    ])
    |> Ash.read!()
    |> Enum.group_by(& &1.provider_account_id)
  end

  defp read_runs(events) do
    ids = events |> Map.values() |> List.flatten() |> Enum.map(& &1.worker_run_id) |> Enum.uniq()

    case ids do
      [] ->
        %{}

      ids ->
        Run
        |> Ash.Query.filter(id in ^ids)
        |> Ash.Query.select([:id, :started_at, :completed_at])
        |> Ash.read!()
        |> Map.new(&{&1.id, &1})
    end
  end
end
