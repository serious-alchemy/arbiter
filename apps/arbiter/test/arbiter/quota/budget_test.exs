defmodule Arbiter.Quota.BudgetTest do
  @moduledoc """
  DC3 (bd-6c8g4t; `docs/design/provider-dynamic-concurrency.md` §3.3, §3.5-§3.8,
  §11): `Arbiter.Quota.Budget`, the pure capacity function. Covers invariants
  I3 (the ceiling bounds the budget), I5 (hard zeros), I6 (one definition of
  the line), I7 (hysteresis), I10 (the near-reset guard) and I11 (the budget is
  finite for any fit), with the design's own fixtures: §3.8's two examples,
  flat mode, Codex `session`, a stale primary window before and after its
  reset, the exempt budget, and I11's three fits.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Loop.Scarcity.Calibration
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.BudgetCalibration
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  @five_hours 5 * 3600

  # ---- Example A's state (§3.8, Appendix A): the live claude:default readings --

  @a_now ~U[2026-10-10 01:40:27Z]

  defp account(config \\ %{"threshold_mode" => "paced"}, max_concurrent \\ 3),
    do: %ProviderAccount{provider: :claude, quota_config: config, max_concurrent: max_concurrent}

  defp example_a_snapshot do
    %Snapshot{
      provider: "claude",
      utilization: 0.19,
      status: "allowed",
      reset_at: ~U[2026-10-10 04:40:00Z],
      captured_at: ~U[2026-10-10 01:38:49Z],
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: 0.49,
      secondary_status: "allowed",
      secondary_reset_at: ~U[2026-10-12 16:00:00Z],
      secondary_window_label: "7d"
    }
  end

  defp compute(overrides) do
    base = [
      account: account(),
      pool: "claude",
      quota: example_a_snapshot(),
      now: @a_now,
      seats: 3,
      horizon: 2.0
    ]

    base |> Keyword.merge(overrides) |> Budget.compute()
  end

  defp window(budget, label), do: Enum.find(budget.windows, &(&1.window == label))

  describe "Example A: live readings, illustrative rate (§3.8)" do
    test "the prior: 3 seats track each line; the ceiling binds" do
      b = compute([])

      assert_in_delta window(b, "5h").n, 4.55, 0.01
      assert_in_delta window(b, "7d").n, 37.99, 0.05
      assert_in_delta b.raw, 4.55, 0.01
      assert b.budget == 3
      assert b.binding == :ceiling
      assert b.ceiling == %{max_concurrent: 3, share: nil}
      assert b.seats == 3
      assert b.free == 0

      w = window(b, "5h")
      assert_in_delta w.used, 0.19, 1.0e-9
      assert_in_delta w.used_now, 0.195444, 1.0e-5
      assert_in_delta w.line_now, 0.4015, 1.0e-3
      assert_in_delta w.line_at_h, 0.8015, 1.0e-3
      assert_in_delta w.reset_in_h, 2.9925, 1.0e-3
      assert_in_delta w.rho, 1 / 15, 1.0e-9
      assert w.rho_source == :prior
      assert_in_delta w.rho_min, 1 / 60, 1.0e-9
      assert w.horizon_h == 2.0

      assert b.reason =~ "ceiling max_concurrent 3"
      assert b.reason =~ "quota allows 4"
      assert b.reason =~ "5h binds"
      assert b.reason =~ "6.7%/seat-h prior"
    end

    test "a seat draws half the prior: more room, the ceiling still binds" do
      b = compute(rates: %{"5h" => %{rho: 1 / 30}, "7d" => %{rho: 1 / 1008}})

      assert_in_delta window(b, "5h").n, 9.13, 0.02
      assert_in_delta window(b, "7d").n, 76.02, 0.1
      assert b.budget == 3
      assert b.binding == :ceiling
    end

    test "a seat draws twice the prior: the budget binds below today's 3" do
      b = compute(rates: %{"5h" => %{rho: 2 / 15}, "7d" => %{rho: 1 / 252}})

      assert_in_delta window(b, "5h").n, 2.25, 0.02
      assert_in_delta window(b, "7d").n, 18.97, 0.05
      assert b.budget == 2
      assert b.binding == {:window, "5h"}
      assert b.reason =~ "5h binds"
      refute b.reason =~ "ceiling"
    end
  end

  # ---- Example B: near a reset (§3.8, I10) ------------------------------------

  @b_now ~U[2026-10-10 04:10:00Z]

  defp example_b_snapshot(used \\ 0.70) do
    %Snapshot{
      provider: "claude",
      utilization: used,
      status: "allowed",
      reset_at: ~U[2026-10-10 04:40:00Z],
      captured_at: @b_now,
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: 0.10,
      secondary_status: "allowed",
      secondary_reset_at: ~U[2026-10-14 04:10:00Z],
      secondary_window_label: "7d"
    }
  end

  defp compute_b(overrides),
    do:
      compute(
        [
          quota: example_b_snapshot(),
          now: @b_now,
          account: account(%{"threshold_mode" => "paced"}, nil)
        ] ++ overrides
      )

  describe "Example B: near a reset (I10)" do
    test "the fresh window absorbs only what its floor allows" do
      b = compute_b(rates: %{"5h" => %{rho: 1 / 15}})
      w = window(b, "5h")

      assert_in_delta w.n_before, 9.0, 1.0e-6
      assert_in_delta w.n_after, 3.5, 1.0e-6
      assert_in_delta w.n, 3.5, 1.0e-6
      assert b.budget == 3
      assert b.binding == {:window, "5h"}
    end

    property "I10: with a reset inside H, the budget is at most n_after" do
      check all(
              t_r <- float(min: 0.3, max: 1.95),
              used <- float(min: 0.0, max: 0.95),
              rho <- float(min: 0.02, max: 0.3),
              b_rate <- float(min: 0.0, max: 0.05)
            ) do
        now = @b_now
        reset = DateTime.add(now, round(t_r * 3600), :second)
        snap = %{example_b_snapshot(used) | reset_at: reset}
        h = 2.0

        budget =
          compute(
            quota: snap,
            now: now,
            account: account(%{"threshold_mode" => "paced"}, nil),
            seats: 0,
            rates: %{"5h" => %{rho: rho}},
            background: b_rate,
            horizon: h
          )

        x = h - DateTime.diff(reset, now) / 3600
        # 5h paced floor 0.35 beats elapsed x/5 for x < 1.75
        expected_after = (max(0.35, x / 5) - b_rate * x) / (max(rho, 0.025) * x)

        w = window(budget, "5h")
        assert_in_delta w.n_after, expected_after, 1.0e-6
        assert budget.raw <= expected_after + 1.0e-9
        assert budget.budget <= max(floor(expected_after), 0)
      end
    end
  end

  # ---- I3: the ceiling bounds the budget ---------------------------------------

  describe "I3: the ceiling bounds the budget" do
    property "budget <= min(max_concurrent, share) whenever they are set" do
      check all(
              used <- float(min: 0.0, max: 1.0),
              seats <- integer(0..20),
              max_concurrent <- one_of([constant(nil), integer(1..10)]),
              share <- one_of([constant(nil), integer(1..10)]),
              rho <- float(min: 0.0, max: 0.5)
            ) do
        snap = %{example_a_snapshot() | utilization: used}

        b =
          compute(
            quota: snap,
            account: account(%{"threshold_mode" => "paced"}, max_concurrent),
            share: share,
            seats: seats,
            rates: %{"5h" => %{rho: rho}}
          )

        assert is_integer(b.budget) and b.budget >= 0

        for ceiling <- [max_concurrent, share], is_integer(ceiling) do
          assert b.budget <= ceiling
        end

        assert b.free == max(b.budget - seats, 0)
      end
    end

    test "the ceiling is the smaller of the two" do
      b = compute(share: 2)
      assert b.ceiling == %{max_concurrent: 3, share: 2}
      assert b.budget == 2
      assert b.binding == :ceiling
    end

    test "no ceiling and a roomy pool: the quota's integer is published" do
      b = compute(account: account(%{"threshold_mode" => "paced"}, nil), seats: 0)
      assert b.budget == floor(b.raw)
      assert b.binding == {:window, "5h"}
      assert b.ceiling == %{max_concurrent: nil, share: nil}
    end
  end

  # ---- I5: hard zeros are zero ------------------------------------------------

  describe "I5: hard zeros" do
    test "the provider refusing (past-plan primary status)" do
      b = compute(quota: %{example_a_snapshot() | status: "rejected"})
      assert b.budget == 0
      assert b.binding == :provider_refusing
      assert b.reason =~ "refusing"
    end

    test "the long window rejected" do
      b = compute(quota: %{example_a_snapshot() | secondary_status: "rejected"})
      assert b.budget == 0
      assert b.binding == :provider_refusing
    end

    test "weekly_warning_policy: hold with the long window at allowed_warning" do
      snap = %{example_a_snapshot() | secondary_status: "allowed_warning"}
      hold = account(%{"threshold_mode" => "paced", "weekly_warning_policy" => "hold"})

      assert compute(quota: snap, account: hold).budget == 0
      assert compute(quota: snap, account: hold).binding == :weekly_warning
      # ignore (the default) is not a stop
      assert compute(quota: snap).budget == 3
    end

    for {hard, binding} <- [paused: :paused, quota_stop: :quota_stop, unavailable: :unavailable] do
      test "#{hard} gives 0 with binding #{binding}" do
        b = compute(hard: unquote(hard))
        assert b.budget == 0
        assert b.binding == unquote(binding)
        assert b.exempt_budget in [nil, 0]
        assert b.free == 0
      end
    end

    test "a hard zero holds even for the exempt budget" do
      exempt = account(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0})
      b = compute(account: exempt, hard: :paused)
      assert b.budget == 0
      assert b.exempt_budget == 0
    end

    test "a stale primary window's status is not trusted, as the gate does" do
      stale = %{example_a_snapshot() | status: "rejected", captured_at: ~U[2026-10-10 00:00:00Z]}
      refute compute(quota: stale).binding == :provider_refusing
    end
  end

  # ---- I6: one definition of the line ----------------------------------------

  describe "I6: one definition of the line" do
    @budget_source Path.expand("../../../lib/arbiter/quota/budget.ex", __DIR__)

    test "Budget never calls Pace directly" do
      source = File.read!(@budget_source)
      refute source =~ ~r/\bPace\./
      refute source =~ "alias Arbiter.Quota.Pace"
      assert source =~ "Gate.pace("
    end

    test "line(now) is the gate's own ceiling for the same inputs" do
      snap = example_a_snapshot()
      b = compute([])

      primary = Gate.pace(account(), :primary, "5h", 0.19, snap.reset_at, now: @a_now)
      long = Gate.pace(account(), :long, "7d", 0.49, snap.secondary_reset_at, now: @a_now)

      assert_in_delta window(b, "5h").line_now, primary.ceiling, 1.0e-12
      assert_in_delta window(b, "7d").line_now, long.ceiling, 1.0e-12
      # and the figures the design quotes (effective_policy in quota_get)
      assert_in_delta primary.ceiling, 0.40152, 2.0e-4
      assert_in_delta long.ceiling, 0.62901, 2.0e-4
    end
  end

  # ---- flat mode, Codex `session`, agy -----------------------------------------

  describe "flat mode and windows with no length" do
    test "a flat side is a constant line" do
      flat = account(%{"throttle_threshold" => 0.8, "weekly_threshold" => 0.9}, nil)
      b = compute(account: flat, seats: 0)
      w = window(b, "5h")

      assert w.line_now == 0.8
      assert w.line_at_h == 0.8
      # (0.8 - 0.19) / (2 / 15) with the default k of 2: prior = 1/10 -> 0.61 / 0.2
      assert_in_delta w.n, (0.8 - 0.19) / (2 * w.rho), 1.0e-9
      assert_in_delta w.rho, 1 / 10, 1.0e-9
    end

    test "Codex's session window has no length: the flat ceiling, and a prior over the 5h default" do
      codex = %ProviderAccount{provider: :codex, quota_config: %{}, max_concurrent: nil}

      snap = %Snapshot{
        provider: "codex",
        utilization: 0.30,
        status: "allowed",
        reset_at: DateTime.add(@a_now, 3600, :second),
        captured_at: @a_now,
        window_label: "session"
      }

      b = compute(account: codex, quota: snap, seats: 0, pool: "codex")
      w = window(b, "session")

      assert w.line_now == 0.85
      assert w.n > 0
      assert b.budget == floor(b.raw)
      assert [%{window: "session"}] = b.windows
    end
  end

  # ---- a stale primary window, before and after its reset ----------------------

  describe "stale primary window (§3.5)" do
    test "before its reset a stale window is skipped; the long window still binds" do
      snap = %{example_a_snapshot() | captured_at: ~U[2026-10-10 00:00:00Z]}
      b = compute(quota: snap)

      assert window(b, "5h").status == :stale
      assert window(b, "5h").n == nil
      assert window(b, "7d").status == :ok
      assert b.binding in [:ceiling, {:window, "7d"}]
      assert b.budget == 3
    end

    test "after its reset it is evaluated as the fresh window: u = 0 plus the draw since" do
      snap = %{
        example_a_snapshot()
        | reset_at: ~U[2026-10-10 01:20:27Z],
          captured_at: ~U[2026-10-10 01:00:00Z]
      }

      b = compute(quota: snap, seats: 3, account: account(%{"threshold_mode" => "paced"}, nil))
      w = window(b, "5h")

      assert w.status == :ok
      assert w.fresh?
      # twenty minutes since the reset at 3 seats * 1/10 per seat-hour (k = 2)
      assert_in_delta w.used_now, 3 * (1 / 10) * (20 / 60), 1.0e-6
      assert_in_delta w.reset_in_h, 5 - 20 / 60, 1.0e-6
    end

    test "no trusted window at all: the last published budget, bounded by the ceiling" do
      stale = %{
        example_a_snapshot()
        | captured_at: ~U[2026-10-10 00:00:00Z],
          secondary_reset_at: nil,
          secondary_window_label: nil
      }

      prev = %{budget: 2, trusted_at: DateTime.add(@a_now, -3600, :second)}
      b = compute(quota: stale, previous: prev)
      assert b.budget == 2
      assert b.binding == :no_reading

      big = %{budget: 9, trusted_at: DateTime.add(@a_now, -3600, :second)}
      assert compute(quota: stale, previous: big).budget == 3
    end

    test "no trusted reading for over 2 h: the ceiling, or 1" do
      stale = %{
        example_a_snapshot()
        | captured_at: ~U[2026-10-10 00:00:00Z],
          secondary_window_label: nil
      }

      old = %{budget: 1, trusted_at: DateTime.add(@a_now, -3 * 3600, :second)}
      assert compute(quota: stale, previous: old).budget == 3
      b = compute(quota: stale, previous: old, account: account(%{}, nil))
      assert b.budget == 1
      assert b.binding == :no_reading
    end

    test "no quota row at all is no reading too" do
      b = compute(quota: nil)
      assert b.binding == :no_reading
      assert b.budget == 3
    end
  end

  describe "a provider with no quota source (§3.5)" do
    test "the ceiling, or :unlimited" do
      assert %{budget: 3, binding: :unmetered} = compute(quota: nil, metered?: false)

      assert %{budget: :unlimited, binding: :unmetered, free: :unlimited} =
               compute(quota: nil, metered?: false, account: account(%{}, nil))
    end
  end

  # ---- the exempt budget (R7) -------------------------------------------------

  describe "the exempt budget" do
    defp early_snapshot do
      %Snapshot{
        provider: "claude",
        utilization: 0.10,
        status: "allowed",
        reset_at: DateTime.add(@a_now, @five_hours, :second),
        captured_at: @a_now,
        capture_source: "oauth_poll",
        window_label: "5h",
        secondary_utilization: 0.10,
        secondary_status: "allowed",
        secondary_reset_at: DateTime.add(@a_now, 3 * 86_400, :second),
        secondary_window_label: "7d"
      }
    end

    test "an account that exempts nothing has none" do
      assert compute(
               quota: early_snapshot(),
               account: account(%{"threshold_mode" => "paced"}, nil)
             ).exempt_budget ==
               nil
    end

    test "the same function over the lifted line admits more, never fewer" do
      exempt = account(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0}, nil)
      b = compute(quota: early_snapshot(), account: exempt, seats: 0)

      assert_in_delta window(b, "5h").line_at_h, 0.4, 1.0e-6
      assert_in_delta b.raw, (0.4 - 0.10) / (2 / 10), 1.0e-6
      # the exempt line is the flat ceiling 0.85: (0.85 - 0.10) / (2 * 1/10)
      assert_in_delta b.exempt_raw, (0.85 - 0.10) / (2 / 10), 1.0e-6
      assert b.exempt_budget == floor(b.exempt_raw)
      assert b.exempt_budget > b.budget
    end

    test "the ceiling still applies to the exempt budget" do
      exempt = account(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0}, 2)
      b = compute(quota: early_snapshot(), account: exempt, seats: 0)
      assert b.exempt_budget == 2
    end

    test "never below the budget" do
      exempt = account(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0}, nil)
      b = compute(account: exempt)
      assert b.exempt_budget >= b.budget
    end
  end

  # ---- expiring headroom and explore (§8) -------------------------------------

  describe "expiring/2 and explore/2" do
    test "expiring headroom is what would reset unused at the current seats" do
      b = compute([])
      # 1.0 - (u_now + 3 * 1/15 * 2.9925 h)
      assert_in_delta Budget.expiring(b, "5h"), 1.0 - (0.195444 + 3 / 15 * 2.9925), 1.0e-3
      assert Budget.expiring(b, "5h") > 0
      assert Budget.expiring(b, "nope") == 0.0
    end

    test "explore is half of it, in seats" do
      quiet =
        compute(
          quota: early_snapshot(),
          seats: 0,
          account: account(%{"threshold_mode" => "paced"}, nil)
        )

      per_window =
        for label <- ["5h", "7d"] do
          Budget.expiring(quiet, label) / (2 * window(quiet, label).rho * 2.0)
        end

      assert Budget.explore(quiet) == floor(Enum.min(per_window))
      assert Budget.explore(quiet) == 2

      assert Budget.explore(quiet) >= 0
    end

    test "no expiring headroom, no exploration" do
      assert Budget.explore(compute([])) == 0
      assert Budget.explore(compute(hard: :paused)) == 0
    end
  end

  describe "lowest/1: a card with no predicted model" do
    test "takes the lowest budget among the account's pools" do
      a = compute(pool: "antigravity:gemini_models")
      b = %{compute(pool: "antigravity:claude_and_gpt_models") | budget: 1}
      assert Budget.lowest([a, b]).pool == "antigravity:claude_and_gpt_models"
      assert Budget.lowest([]) == nil
    end
  end

  # ---- I11: the budget is finite for any fit ---------------------------------

  describe "I11: finite for any fit" do
    property "raw is finite and the budget is at most its value with every rho at the floor" do
      check all(
              used <- float(min: 0.0, max: 1.0),
              seats <- integer(0..30),
              rho <- one_of([constant(0.0), float(min: 0.0, max: 1.0)]),
              rho_long <- one_of([constant(0.0), float(min: 0.0, max: 0.05)]),
              reset_in <- float(min: 0.001, max: 12.0),
              b_rate <- float(min: 0.0, max: 0.1),
              horizon <- float(min: 1.0, max: 4.0)
            ) do
        reset = DateTime.add(@a_now, round(reset_in * 3600), :second)
        snap = %{example_a_snapshot() | utilization: used, reset_at: reset}
        acct = account(%{"threshold_mode" => "paced"}, nil)
        prior_5h = BudgetCalibration.prior(@five_hours, nil)
        prior_7d = BudgetCalibration.prior(604_800, nil)

        run = fn rates ->
          compute(
            quota: snap,
            account: acct,
            seats: seats,
            rates: rates,
            background: b_rate,
            horizon: horizon
          )
        end

        given = run.(%{"5h" => %{rho: rho}, "7d" => %{rho: rho_long}})

        at_floor =
          run.(%{
            "5h" => %{rho: BudgetCalibration.rho_floor(prior_5h)},
            "7d" => %{rho: BudgetCalibration.rho_floor(prior_7d)}
          })

        assert is_float(given.raw)
        assert abs(given.raw) < 1.0e7
        assert given.budget <= at_floor.budget
        assert given.budget >= 0
      end
    end

    @hours [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 0.75, 1.25, 1.75, 2.25]
    @prior 1 / (5 * 3)

    defp seat_obs(seat_hours, hours, share),
      do: %{share: share, hours: hours, draws: %{"seat" => seat_hours}}

    defp fit(obs), do: Calibration.fit(obs, min_observations: 8, min_model_observations: 3)

    defp budget_with(resolution),
      do: compute(rates: %{"5h" => resolution, "7d" => %{rho: 1 / 504}}, seats: 3)

    defp prior_budget do
      compute(account: account(%{"threshold_mode" => "paced"}, 3), seats: 3) |> Map.fetch!(:raw)
    end

    test "seats that never move: the fit is withheld, the prior's budget results" do
      resolution =
        for(h <- @hours, do: seat_obs(3.0 * h, h, 0.2 * h))
        |> fit()
        |> BudgetCalibration.resolve(@prior, [])

      assert [{0, :non_positive}, {1, :no_peer_fit}] = resolution.passed_over
      b = compute(rates: %{"5h" => resolution, "7d" => %{rho: 1 / 504}}, seats: 3)
      assert_in_delta b.raw, prior_budget(), 1.0e-9
      assert b.reason =~ "prior"
      assert b.reason =~ "non_positive"
    end

    test "seats that barely move: positive but not distinguishable from 0, so the prior's" do
      for seed <- [4, 7] do
        :rand.seed(:exsss, {seed, 7, 9})

        obs =
          for h <- @hours do
            sh = (2.9 + :rand.uniform() * 0.1) * h
            seat_obs(sh, h, Float.round(@prior * sh + (:rand.uniform() - 0.5) * 0.01, 2))
          end

        resolution = obs |> fit() |> BudgetCalibration.resolve(@prior, [])
        assert resolution.rung == 2

        b = compute(rates: %{"5h" => resolution, "7d" => %{rho: 1 / 504}}, seats: 3)
        assert_in_delta b.raw, prior_budget(), 1.0e-9
        assert b.reason =~ "not distinguishable from 0"
      end
    end

    test "a noise-free rho of 0.001 passes the test and is clamped to the floor" do
      :rand.seed(:exsss, {1, 2, 3})

      obs =
        for h <- @hours do
          sh = (2.9 + :rand.uniform() * 0.1) * h
          seat_obs(sh, h, 0.001 * sh + 0.197 * h)
        end

      resolution =
        obs
        |> fit()
        |> BudgetCalibration.resolve(@prior, [])

      assert resolution.floored?

      b = budget_with(resolution)
      assert_in_delta window(b, "5h").rho, @prior / 4, 1.0e-12
      assert b.reason =~ "floor"
      assert b.raw <= compute(rates: %{"5h" => %{rho: @prior / 4}}).raw
    end

    test "a rho of 0 handed straight in is raised to the floor" do
      b = budget_with(%{rho: 0.0})
      assert_in_delta window(b, "5h").rho, @prior / 4, 1.0e-12
    end
  end

  # ---- I7: hysteresis ---------------------------------------------------------

  describe "I7: hysteresis" do
    @t0 ~U[2026-10-10 12:00:00Z]

    defp at(seconds), do: DateTime.add(@t0, seconds, :second)

    defp run_raws(raws, step \\ 60) do
      {states, _} =
        raws
        |> Enum.with_index()
        |> Enum.map_reduce(Budget.new_hysteresis(), fn {raw, i}, state ->
          state = Budget.hysteresis(state, raw, at(i * step))
          {state, state}
        end)

      states
    end

    test "the first reading publishes its floor" do
      assert %{budget: 4} = Budget.hysteresis(Budget.new_hysteresis(), 4.55, @t0)
    end

    test "a fall is published at once, down to 0 at the floor" do
      s = Budget.hysteresis(Budget.new_hysteresis(), 5.0, @t0)
      assert %{budget: 3} = Budget.hysteresis(s, 3.9, at(1))
      assert %{budget: 0} = Budget.hysteresis(s, -2.0, at(1))
    end

    test "a rise needs the quarter-seat margin on two recomputes at least 60 s apart" do
      s = Budget.hysteresis(Budget.new_hysteresis(), 4.0, @t0)

      # 5.0 is B + 1 but short of B + 1.25: nothing
      assert %{budget: 4, pending: nil} = Budget.hysteresis(s, 5.0, at(60))

      # past the margin: pending, not yet published
      s1 = Budget.hysteresis(s, 5.3, at(60))
      assert %{budget: 4, pending: %{since: since}} = s1
      assert since == at(60)

      # a second recompute inside 60 s does not publish either
      assert %{budget: 4} = s2 = Budget.hysteresis(s1, 5.4, at(90))
      assert s2.pending.since == at(60)

      # 60 s after the first: floor(raw - 0.25)
      assert %{budget: 5, pending: nil} = Budget.hysteresis(s1, 5.3, at(120))
      assert %{budget: 6} = Budget.hysteresis(s1, 7.0, at(120))
    end

    test "a dip back under the margin drops the pending rise" do
      s = Budget.hysteresis(Budget.new_hysteresis(), 4.0, @t0)
      s1 = Budget.hysteresis(s, 5.3, at(60))
      assert %{pending: nil} = Budget.hysteresis(s1, 4.9, at(90))
      # and the dwell restarts
      s2 = Budget.hysteresis(s1, 4.9, at(90))
      s3 = Budget.hysteresis(s2, 5.3, at(150))
      assert %{budget: 4} = s3
      assert s3.pending.since == at(150)
    end

    property "oscillation inside [B, B + 1.25) publishes nothing" do
      check all(
              b <- integer(1..20),
              noise <- list_of(float(min: 0.0, max: 1.2499), min_length: 1, max_length: 30)
            ) do
        raws = [b + 0.0 | Enum.map(noise, &(&1 + b))]
        assert raws |> run_raws() |> Enum.map(& &1.budget) |> Enum.uniq() == [b]
      end
    end

    property "a monotone rising raw gives a monotone rising published budget" do
      check all(steps <- list_of(float(min: 0.0, max: 1.5), min_length: 2, max_length: 40)) do
        raws = Enum.scan(steps, 0.0, &(&1 + &2))
        published = raws |> run_raws() |> Enum.map(& &1.budget)
        assert published == Enum.sort(published)
        assert List.last(published) <= floor(List.last(raws))
      end
    end

    property "a monotone falling raw gives a monotone falling published budget" do
      check all(steps <- list_of(float(min: 0.0, max: 1.5), min_length: 2, max_length: 40)) do
        raws = Enum.scan(steps, 30.0, &(&2 - &1))
        published = raws |> run_raws() |> Enum.map(& &1.budget)
        assert published == Enum.sort(published, :desc)
      end
    end

    test "publish/3 applies the ceiling after hysteresis, and keeps B <= floor(raw)" do
      computed = compute(account: account(%{"threshold_mode" => "paced"}, nil), seats: 0)
      {b1, s1} = Budget.publish(computed, Budget.new_hysteresis(), @a_now)
      assert b1.budget == floor(computed.raw)
      assert b1.published_at == @a_now
      assert s1.budget == b1.budget
    end

    test "publish/3 holds a small rise and reports it as pending" do
      base = compute(account: account(%{"threshold_mode" => "paced"}, nil), seats: 0)
      low = %{base | raw: 4.0}
      high = %{base | raw: 5.3}

      {_, s0} = Budget.publish(low, Budget.new_hysteresis(), @t0)
      {held, s1} = Budget.publish(high, s0, at(60))
      assert held.budget == 4
      assert %{raw: 5.3, since: since} = held.pending_rise
      assert since == at(60)

      {rose, s2} = Budget.publish(high, s1, at(125))
      assert rose.budget == 5
      assert rose.pending_rise == nil
      assert s2.budget == 5
    end

    test "a hard zero is published at once and recovery skips the dwell" do
      base = compute(account: account(%{"threshold_mode" => "paced"}, nil), seats: 0)
      {_, s0} = Budget.publish(%{base | raw: 4.0}, Budget.new_hysteresis(), @t0)

      zero = compute(hard: :paused)
      {z, s1} = Budget.publish(zero, s0, at(10))
      assert z.budget == 0
      assert s1.budget == nil

      {back, _} = Budget.publish(%{base | raw: 9.0}, s1, at(20))
      assert back.budget == 9
    end

    test "the ceiling is applied after hysteresis: lowering it acts at once" do
      base = compute(account: account(%{"threshold_mode" => "paced"}, nil), seats: 0)
      {_, s0} = Budget.publish(%{base | raw: 8.0}, Budget.new_hysteresis(), @t0)
      capped = %{base | raw: 8.0, ceiling: %{max_concurrent: 2, share: nil}}
      {b, _} = Budget.publish(capped, s0, at(5))
      assert b.budget == 2
      assert b.binding == :ceiling
    end
  end
end
