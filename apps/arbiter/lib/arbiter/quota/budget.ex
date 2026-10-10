defmodule Arbiter.Quota.Budget do
  @moduledoc """
  The provider concurrency budget (bd-6c8g4t, DC3 of
  `docs/design/provider-dynamic-concurrency.md` §3): how many *seats* a
  provider pool can sustain for the next horizon, as an integer plus a reason.

  This module is **pure**. `compute/1` takes one pool's quota snapshot, the
  seats in flight, the draw per seat-hour and the commitment horizon, and
  returns a `t:t/0`; `hysteresis/3` and `publish/3` turn a stream of those into
  the published budget (§3.7). `Arbiter.Quota.Budget.Server` owns the clock,
  the ETS table and the `budget_changed` event.

  ## Nothing decides by it yet

  Until DC8, nothing on an admission, gate or dispatch path may read a budget
  (invariants I1, I2 and I8). `Arbiter.Quota.BudgetShadowTest` pins that
  structurally. Its one reader is the scheduler walk (DC6,
  `Arbiter.Board.WalkInputs`), which runs only under `scheduler_admission:
  shadow` or `enforce` and is recorded beside today's decision, never in its
  place. The budget stops nothing that runs: it is read only by admission
  (DC8), the walk and the display.

  ## The function (§3.3)

  For each trusted window `w` of the pool, with `ρ = max(ρ, ρ_min)` (I11):

      u_now = u + (S·ρ + b)·lag
      t_r ≥ H:  n_w = (line(now + H) − u_now − b·H) / (ρ·H)
      t_r < H:  n_w = min(n_before, n_after)
        n_before = (line(reset) − u_now − b·t_r) / (ρ·t_r)
        n_after  = (line′(H − t_r) − b·(H − t_r)) / (ρ·(H − t_r))

  `raw` is the smallest `n_w`; the budget is `clamp(floor(raw), 0, ceiling)`
  after hysteresis. `line(t)` and `line′(x)` come from `Arbiter.Quota.Gate`
  (`pace/6` with a `now:` what-if, and `fresh_pace/5`), never from `Pace`
  directly (I6). `ρ` is never below `ρ_min = prior / 4`, so every `n` is
  finite (I11).

  ## Inputs (`compute/1`)

    * `:quota` — a quota row or a `Arbiter.Quota.Gate.Snapshot`; `nil` for no
      reading. `:model` is forwarded to `Snapshot.normalize/2` (the agy pools).
    * `:account` / `:workspace` — the policy pair `Gate.pace/6` composes
      `min(account, workspace)` over. The account's `max_concurrent` is the
      ceiling (with `:share`).
    * `:pool`, `:now`, `:seats` (live), `:horizon` hours (clamped to [1, 4]).
    * `:rates` — `%{window_label => resolution}`, a `BudgetCalibration.resolve/3`
      result (or just `%{rho: ρ}`). A window with none uses the prior.
    * `:background` — `b`, a number or `%{window_label => number}`; 0 by default.
    * `:hard` — `:paused | :quota_stop | :unavailable`, the hard zeros the quota
      row cannot tell us about (§3.5).
    * `:previous` — `%{budget: n, trusted_at: dt}`, for the no-reading rule.
    * `:metered?` — `false` for a provider with no quota source at all.
  """

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.BudgetCalibration
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  # Hysteresis (§3.7): a rise must clear one seat plus this margin, twice, a
  # minute apart.
  @theta 0.25
  @dwell_seconds 60

  # With no trusted reading the last published budget stands this long (§3.5):
  # the OAuth poll's longest 429 cooldown.
  @no_reading_seconds 2 * 3600

  @default_horizon 2.0
  @horizon_range {1.0, 4.0}

  # The window lengths a prior assumes for a window with no fixed length
  # (Codex `session`, agy `used`): the gate treats those as flat.
  @fallback_seconds %{primary: 5 * 3600, long: 7 * 86_400}

  @hard_bindings [:provider_refusing, :weekly_warning, :paused, :quota_stop, :unavailable]
  @unhysteresised [:no_reading, :unmetered | @hard_bindings]

  @type binding ::
          :ceiling
          | {:window, String.t()}
          | :provider_refusing
          | :weekly_warning
          | :paused
          | :quota_stop
          | :unavailable
          | :no_reading
          | :unmetered

  @type hysteresis :: %{
          budget: non_neg_integer() | nil,
          pending: %{raw: float(), since: DateTime.t()} | nil
        }

  @type t :: %__MODULE__{
          account: String.t() | nil,
          pool: String.t() | nil,
          policy_workspace: String.t() | nil,
          budget: non_neg_integer() | :unlimited,
          raw: float() | nil,
          exempt_raw: float() | nil,
          exempt_budget: non_neg_integer() | nil,
          seats: non_neg_integer(),
          free: non_neg_integer() | :unlimited,
          binding: binding(),
          quota_binding: String.t() | nil,
          reason: String.t(),
          windows: [map()],
          ceiling: %{max_concurrent: pos_integer() | nil, share: pos_integer() | nil},
          horizon: float(),
          computed_at: DateTime.t(),
          published_at: DateTime.t() | nil,
          pending_rise: %{raw: float(), since: DateTime.t()} | nil
        }

  defstruct account: nil,
            pool: nil,
            policy_workspace: nil,
            budget: 0,
            raw: nil,
            exempt_raw: nil,
            exempt_budget: nil,
            seats: 0,
            free: 0,
            binding: :no_reading,
            quota_binding: nil,
            reason: "",
            windows: [],
            ceiling: %{max_concurrent: nil, share: nil},
            horizon: @default_horizon,
            computed_at: nil,
            published_at: nil,
            pending_rise: nil

  # ---- compute (pure) -------------------------------------------------------

  @doc """
  The budget of one pool, before hysteresis. See the moduledoc for the options.
  """
  @spec compute(keyword() | map()) :: t()
  def compute(opts) do
    opts = Map.new(opts)
    account = Map.get(opts, :account)
    workspace = Map.get(opts, :workspace)
    snapshot = Snapshot.normalize(Map.get(opts, :quota), model: Map.get(opts, :model))
    ctx = context(opts, account, workspace)

    base = %__MODULE__{
      account: Map.get(opts, :account_id) || account_id(account),
      pool: Map.get(opts, :pool),
      policy_workspace: workspace_id(workspace),
      seats: ctx.seats,
      windows: eval_windows(snapshot, ctx),
      ceiling: ceiling(account, Map.get(opts, :share)),
      horizon: ctx.horizon,
      computed_at: ctx.now
    }

    decide(base, opts, snapshot, ctx)
  end

  defp context(opts, account, workspace) do
    %{
      policy: {account, workspace},
      account: account,
      now: Map.get_lazy(opts, :now, &DateTime.utc_now/0),
      seats: max(Map.get(opts, :seats) || 0, 0),
      horizon: clamp_horizon(Map.get(opts, :horizon)),
      rates: Map.get(opts, :rates) || %{},
      background: Map.get(opts, :background) || 0.0,
      priority: nil
    }
  end

  defp decide(base, opts, snapshot, ctx) do
    exempt = Gate.pace_exempt_priority(ctx.policy)

    cond do
      zero = hard_zero(opts, snapshot, ctx.policy, ctx.now) ->
        hard(base, zero, exempt, snapshot)

      snapshot == nil and Map.get(opts, :metered?, true) == false ->
        unmetered(base)

      true ->
        case trusted(base.windows) do
          [] -> no_reading(base, Map.get(opts, :previous), ctx.now)
          trusted -> quota(base, trusted, ctx, snapshot, exempt)
        end
    end
  end

  defp quota(base, trusted, ctx, snapshot, exempt) do
    {binding, raw} = Enum.min_by(Enum.map(trusted, &{&1.window, &1.n}), &elem(&1, 1))

    exempt_raw =
      if exempt do
        ctx = %{ctx | priority: exempt}

        snapshot
        |> eval_windows(ctx)
        |> trusted()
        |> Enum.map(& &1.n)
        |> Enum.min(fn -> nil end)
      end

    finalize(
      %{base | raw: raw, exempt_raw: exempt_raw, quota_binding: binding},
      max(floor(raw), 0)
    )
  end

  defp hard(base, binding, exempt, snapshot) do
    %{
      base
      | budget: 0,
        free: 0,
        binding: binding,
        exempt_budget: if(exempt, do: 0),
        reason: hard_reason(binding, snapshot)
    }
  end

  defp unmetered(base) do
    ceil = ceiling_value(base.ceiling)
    budget = ceil || :unlimited

    %{
      base
      | budget: budget,
        free: free(budget, base.seats),
        binding: :unmetered,
        reason: "no quota source; " <> if(ceil, do: "ceiling #{ceil}", else: "unlimited")
    }
  end

  # §3.5: no trusted reading at all. The last published budget stands for up to
  # 2 h (bounded by the ceiling); after that the ceiling, or 1.
  defp no_reading(base, previous, now) do
    ceil = ceiling_value(base.ceiling)

    {budget, text} =
      case previous do
        %{budget: held, trusted_at: %DateTime{} = at} when is_integer(held) ->
          if DateTime.diff(now, at) < @no_reading_seconds,
            do: {min(held, ceil || held), "holding the last budget #{held}"},
            else: {ceil || 1, "reading lost over 2h ago"}

        _ ->
          {ceil || 1, "no reading yet"}
      end

    %{
      base
      | budget: budget,
        free: free(budget, base.seats),
        binding: :no_reading,
        reason: "no trusted quota reading (#{text})"
    }
  end

  # The quota-derived budget for a given hysteresis output `qb`, under the
  # struct's ceiling (the ceiling is applied after hysteresis, §3.8).
  defp finalize(%__MODULE__{} = b, qb) do
    ceil = ceiling_value(b.ceiling)
    budget = if ceil, do: min(qb, ceil), else: qb

    exempt =
      b.exempt_raw &&
        b.exempt_raw |> floor() |> max(0) |> cap(ceil) |> max(budget)

    binding = if ceil && qb > ceil, do: :ceiling, else: {:window, b.quota_binding}

    %{
      b
      | budget: budget,
        free: free(budget, b.seats),
        exempt_budget: exempt,
        binding: binding,
        reason: quota_reason(b, qb, ceil)
    }
  end

  defp cap(n, nil), do: n
  defp cap(n, ceil), do: min(n, ceil)

  defp free(:unlimited, _seats), do: :unlimited
  defp free(budget, seats), do: max(budget - seats, 0)

  defp trusted(windows), do: Enum.filter(windows, &(&1.status == :ok))

  # ---- hard zeros (§3.5) ----------------------------------------------------

  defp hard_zero(opts, snapshot, policy, now) do
    case Map.get(opts, :hard) do
      hard when hard in [:paused, :quota_stop, :unavailable] ->
        hard

      _ ->
        case Gate.hard_stop(snapshot, policy, now: now) do
          %{signal: :warning} -> :weekly_warning
          %{} -> :provider_refusing
          nil -> nil
        end
    end
  end

  defp hard_reason(:provider_refusing, snapshot),
    do: "provider is refusing requests" <> status_note(snapshot)

  defp hard_reason(:weekly_warning, _),
    do: "long window at allowed_warning (weekly_warning_policy: hold)"

  defp hard_reason(:paused, _), do: "provider paused"
  defp hard_reason(:quota_stop, _), do: "quota-stop hold"
  defp hard_reason(:unavailable, _), do: "provider unavailable (auth expired or circuit broken)"

  defp status_note(%Snapshot{status: status}) when status not in [nil, "allowed"],
    do: " (#{status})"

  defp status_note(%Snapshot{secondary_status: status}) when status not in [nil, "allowed"],
    do: " (#{status})"

  defp status_note(_), do: ""

  # ---- windows --------------------------------------------------------------

  defp eval_windows(nil, _ctx), do: []

  defp eval_windows(%Snapshot{} = s, ctx) do
    primary = %{
      side: :primary,
      label: s.window_label,
      used: s.utilization,
      reset_at: s.reset_at,
      stale?: Gate.stale?(s, ctx.now)
    }

    long = %{
      side: :long,
      label: s.secondary_window_label,
      used: s.secondary_utilization,
      reset_at: s.secondary_reset_at,
      stale?: Gate.long_window_stale?(s, ctx.now)
    }

    [primary | if(s.secondary_window_label, do: [long], else: [])]
    |> Enum.map(&eval_window(&1, s, ctx))
  end

  defp eval_window(w, snapshot, ctx) do
    seconds = Gate.window_seconds(w.label, ctx.account)
    rate = rate(w, seconds, ctx)
    b = background(ctx.background, w.label)

    entry = %{
      window: w.label,
      side: w.side,
      status: :ok,
      used: if(is_number(w.used), do: w.used * 1.0),
      rho: rate.rho,
      rho_source: rate.source,
      rho_min: rate.floor,
      raw_rho: rate.raw_rho,
      floored?: rate.floored?,
      passed_over: rate.passed_over,
      b: b,
      horizon_h: ctx.horizon,
      fresh?: false,
      used_now: nil,
      line_now: nil,
      line_at_h: nil,
      line_at_reset: nil,
      reset_in_h: nil,
      n: nil,
      n_before: nil,
      n_after: nil,
      expiring: nil
    }

    reset_passed? = w.reset_at && DateTime.compare(w.reset_at, ctx.now) != :gt

    cond do
      not is_number(w.used) -> %{entry | status: :no_reading}
      reset_passed? and is_integer(seconds) -> fresh_window(entry, w, seconds, ctx)
      reset_passed? -> %{entry | status: :stale}
      w.stale? -> %{entry | status: :stale}
      true -> capacity(entry, w, w.used, w.reset_at, lag_hours(snapshot, ctx.now), ctx)
    end
  end

  # A window whose reset has passed is the fresh window: u = 0 at the reset
  # plus the draw projected since (§3.5).
  defp fresh_window(entry, w, seconds, ctx) do
    passed = DateTime.diff(ctx.now, w.reset_at)
    windows_elapsed = div(passed, seconds) + 1
    next_reset = DateTime.add(w.reset_at, windows_elapsed * seconds, :second)
    last_reset = DateTime.add(next_reset, -seconds, :second)
    lag = DateTime.diff(ctx.now, last_reset, :millisecond) / 3_600_000

    capacity(%{entry | fresh?: true}, w, 0.0, next_reset, lag, ctx)
  end

  defp capacity(entry, w, used, reset_at, lag, ctx) do
    %{rho: rho, b: b} = entry
    h = ctx.horizon
    u_now = used + (ctx.seats * rho + b) * lag
    line = fn t -> line(ctx, w, used, reset_at, t) end
    t_r = reset_at && DateTime.diff(reset_at, ctx.now, :millisecond) / 3_600_000
    horizon_end = hours_after(ctx.now, h)

    {n, n_before, n_after} =
      if t_r == nil or t_r >= h do
        {(line.(horizon_end) - u_now - b * h) / (rho * h), nil, nil}
      else
        before = (line.(reset_at) - u_now - b * t_r) / (rho * t_r)
        x = h - t_r
        fresh = fresh_line(ctx, w, reset_at, hours_after(reset_at, x))
        after_reset = (fresh - b * x) / (rho * x)
        {min(before, after_reset), before, after_reset}
      end

    line_at_reset = reset_at && line.(reset_at)

    %{
      entry
      | used_now: u_now,
        line_now: line.(ctx.now),
        line_at_h: line.(horizon_end),
        line_at_reset: line_at_reset,
        reset_in_h: t_r,
        n: n,
        n_before: n_before,
        n_after: n_after,
        expiring: t_r && max(0.0, line_at_reset - (u_now + (ctx.seats * rho + b) * t_r))
    }
  end

  # The one definition of the line: the gate's own, read at time `t`.
  defp line(ctx, w, used, reset_at, t) do
    ctx.policy
    |> Gate.pace(w.side, w.label, used, reset_at, pace_opts(ctx, t))
    |> Map.fetch!(:ceiling)
  end

  defp fresh_line(ctx, w, reset_at, t) do
    ctx.policy
    |> Gate.fresh_pace(w.side, w.label, reset_at, pace_opts(ctx, t))
    |> Map.fetch!(:ceiling)
  end

  defp pace_opts(%{priority: nil}, t), do: [now: t]
  defp pace_opts(%{priority: p}, t), do: [now: t, priority: p]

  defp hours_after(%DateTime{} = at, hours),
    do: DateTime.add(at, round(hours * 3_600_000), :millisecond)

  defp lag_hours(%Snapshot{captured_at: %DateTime{} = at}, now),
    do: max(DateTime.diff(now, at, :millisecond), 0) / 3_600_000

  defp lag_hours(_snapshot, _now), do: 0.0

  defp background(b, _label) when is_number(b), do: max(b * 1.0, 0.0)
  defp background(%{} = by_window, label), do: background(Map.get(by_window, label, 0.0), label)
  defp background(_, _label), do: 0.0

  # ρ for one window: the resolved rung's value, else the prior; never below
  # the floor ρ_min = prior / 4 (I11), whatever it is handed.
  defp rate(w, seconds, ctx) do
    max_concurrent = match?(%ProviderAccount{}, ctx.account) && ctx.account.max_concurrent
    seconds = seconds || Map.fetch!(@fallback_seconds, w.side)
    prior = BudgetCalibration.prior(seconds, max_concurrent || nil)
    floor = BudgetCalibration.rho_floor(prior)
    given = Map.get(ctx.rates, w.label) || %{}
    asked = number_or(given[:rho], prior)
    fitted = number_or(given[:raw_rho], asked)

    %{
      rho: max(asked, floor),
      floor: floor,
      source: source(given),
      raw_rho: fitted,
      floored?: fitted < floor,
      passed_over: given[:passed_over] || []
    }
  end

  defp source(%{rung: 0}), do: :fit
  defp source(%{rung: 1}), do: :peer
  defp source(%{rung: 2}), do: :prior
  defp source(%{rho: _}), do: :given
  defp source(_), do: :prior

  defp number_or(n, _default) when is_number(n), do: n * 1.0
  defp number_or(_, default), do: default

  # ---- ceiling --------------------------------------------------------------

  defp ceiling(account, share) do
    mc =
      case account do
        %ProviderAccount{max_concurrent: n} when is_integer(n) and n > 0 -> n
        _ -> nil
      end

    %{max_concurrent: mc, share: if(is_integer(share) and share > 0, do: share)}
  end

  defp ceiling_value(%{max_concurrent: mc, share: share}) do
    case Enum.reject([mc, share], &is_nil/1) do
      [] -> nil
      set -> Enum.min(set)
    end
  end

  defp clamp_horizon(h) when is_number(h) do
    {lo, hi} = @horizon_range
    (h * 1.0) |> max(lo) |> min(hi)
  end

  defp clamp_horizon(_), do: @default_horizon

  defp account_id(%ProviderAccount{id: id}), do: id
  defp account_id(_), do: nil

  defp workspace_id(%{id: id}), do: id
  defp workspace_id(_), do: nil

  # ---- the reason (§3.8) ----------------------------------------------------

  defp quota_reason(%__MODULE__{} = b, qb, ceil) do
    detail = binding_detail(b)

    if ceil && qb > ceil do
      "ceiling #{ceiling_name(b.ceiling)} #{ceil} (quota allows #{qb}: #{detail})"
    else
      "quota allows #{qb}: #{detail}"
    end
  end

  defp ceiling_name(%{max_concurrent: mc, share: share}),
    do: if(mc && (share == nil or mc <= share), do: "max_concurrent", else: "share")

  defp binding_detail(%__MODULE__{} = b) do
    w = Enum.find(b.windows, &(&1.window == b.quota_binding and &1.status == :ok))

    reset =
      if w.n_before,
        do:
          ", reset in #{fmt(w.reset_in_h)}h (#{fmt(w.n_before)} before, #{fmt(w.n_after)} after)",
        else: ""

    "#{w.window} binds, #{fmt(w.used)} used, line #{fmt(w.line_now)} now and " <>
      "#{fmt(w.line_at_h)} in #{trim(w.horizon_h)}h#{reset}, #{rate_note(w)}"
  end

  defp rate_note(%{floored?: true} = w),
    do: "#{pct(w.rho)}/seat-h floor; fit #{pct(w.raw_rho)}"

  defp rate_note(%{rho_source: :prior, passed_over: [_ | _] = passed} = w),
    do: "#{pct(w.rho)}/seat-h prior; own fit #{passed |> own_fit_note()}"

  defp rate_note(%{rho_source: :prior} = w), do: "#{pct(w.rho)}/seat-h prior"
  defp rate_note(%{rho_source: :peer} = w), do: "#{pct(w.rho)}/seat-h from other accounts"
  defp rate_note(w), do: "#{pct(w.rho)}/seat-h"

  defp own_fit_note(passed) do
    case Enum.find(passed, &match?({0, _}, &1)) do
      {0, {:not_distinguishable_from_zero, _t}} -> "not distinguishable from 0"
      {0, why} -> "#{why}"
      _ -> "not used"
    end
  end

  defp fmt(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)
  defp fmt(_), do: "-"
  defp pct(n), do: :erlang.float_to_binary(n * 100, decimals: 1) <> "%"
  defp trim(h), do: h |> Float.round(1) |> to_string() |> String.replace_suffix(".0", "")

  # ---- hysteresis (§3.7) ----------------------------------------------------

  @doc "The empty hysteresis state: nothing published yet."
  @spec new_hysteresis() :: hysteresis()
  def new_hysteresis, do: %{budget: nil, pending: nil}

  @doc """
  One step of the published quota budget `B` following `raw` (§3.7):

    * a fall is taken at once: `floor(raw) < B` sets `B := max(floor(raw), 0)`;
    * a rise needs `raw ≥ B + 1 + θ` (θ = #{@theta}) on two recomputes at least
      #{@dwell_seconds} s apart, then `B := floor(raw − θ)`; a recompute back
      under the margin forgets the pending rise;
    * the first reading publishes its floor.

  `B ≤ floor(raw)` always holds, and `raw` inside `[B, B + 1.25)` changes nothing.
  """
  @spec hysteresis(hysteresis(), float(), DateTime.t()) :: hysteresis()
  def hysteresis(%{budget: nil}, raw, _now), do: %{budget: max(floor(raw), 0), pending: nil}

  def hysteresis(%{budget: b} = state, raw, now) do
    cond do
      floor(raw) < b ->
        %{budget: max(floor(raw), 0), pending: nil}

      raw >= b + 1 + @theta ->
        rise(state, raw, now)

      true ->
        %{state | pending: nil}
    end
  end

  defp rise(%{pending: %{since: since}} = state, raw, now) do
    if DateTime.diff(now, since) >= @dwell_seconds,
      do: %{budget: floor(raw - @theta), pending: nil},
      else: %{state | pending: %{since: since, raw: raw}}
  end

  defp rise(state, raw, now), do: %{state | pending: %{since: now, raw: raw}}

  @doc """
  Publish a computed budget through hysteresis: `{published, next_state}`. A
  hard zero, a lost reading and an unmetered pool are not noise and skip
  hysteresis in both directions (§3.5): they publish as computed and reset
  the state, so recovery takes the first reading's floor.
  """
  @spec publish(t(), hysteresis(), DateTime.t()) :: {t(), hysteresis()}
  def publish(%__MODULE__{binding: binding} = computed, _state, now)
      when binding in @unhysteresised,
      do: {%{computed | published_at: now}, new_hysteresis()}

  def publish(%__MODULE__{raw: raw} = computed, state, now) do
    next = hysteresis(state, raw, now)
    published = finalize(computed, next.budget)
    {%{published | published_at: now, pending_rise: next.pending}, next}
  end

  # ---- helpers for readers --------------------------------------------------

  @doc """
  Expiring headroom of window `label` (§8): what would reset unused at the
  current seats, `max(0, line(reset) − (u_now + (S·ρ + b)·t_r))`, as a share of
  the window. `0.0` for a window with no reset or not evaluated.
  """
  @spec expiring(t(), String.t()) :: float()
  def expiring(%__MODULE__{windows: windows}, label) do
    case Enum.find(windows, &(&1.window == label and &1.status == :ok)) do
      %{expiring: e} when is_number(e) -> e
      _ -> 0.0
    end
  end

  @doc """
  The exploration budget (§8), in seats: half of the smallest window's expiring
  headroom, `floor(min_w expiring(w) / (2·ρ·H))`, with the same floored `ρ` as
  the budget. `0` when the pool is at a hard zero or has no reset to expire at.
  Exploration seats count against the budget like any other seat.
  """
  @spec explore(t(), keyword()) :: non_neg_integer()
  def explore(budget, opts \\ [])
  def explore(%__MODULE__{binding: binding}, _opts) when binding in @hard_bindings, do: 0

  def explore(%__MODULE__{windows: windows, horizon: h}, _opts) do
    windows
    |> Enum.filter(&(&1.status == :ok and is_number(&1.expiring)))
    |> Enum.map(&(&1.expiring / (2 * &1.rho * h)))
    |> case do
      [] -> 0
      shares -> shares |> Enum.min() |> floor() |> max(0)
    end
  end

  @doc """
  The lowest budget among a card's candidate pools: what a card whose predicted
  model is `nil` takes (§3.1). `nil` for none.
  """
  @spec lowest([t()]) :: t() | nil
  def lowest([]), do: nil
  def lowest(budgets), do: Enum.min_by(budgets, &rank/1)

  defp rank(%__MODULE__{budget: :unlimited}), do: :infinity
  defp rank(%__MODULE__{budget: n}), do: n
end
