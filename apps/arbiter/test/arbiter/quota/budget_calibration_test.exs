defmodule Arbiter.Quota.BudgetCalibrationTest do
  @moduledoc """
  DC2 (bd-c1dief; `docs/design/provider-dynamic-concurrency.md` §3.4, I11): the
  seat-hour fit `Δu = ρ·seat_hours + b·hours`, its fallback ladder and the ρ
  floor. Shadow only — `shadow_only_test.exs` pins that nothing reads it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Scarcity.Calibration
  alias Arbiter.Quota.BudgetCalibration
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Workers.Run

  @t0 ~U[2026-10-01 00:00:00Z]
  @prior 1 / (5 * 3)

  defp at(minutes), do: DateTime.add(@t0, round(minutes * 60), :second)

  defp snap(minutes, util, seats) do
    %{utilization: util, resets_at: at(300), captured_at: at(minutes), seats: seats}
  end

  # ---- I11's three fixtures (Appendix A) ------------------------------------

  @hours [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 0.75, 1.25, 1.75, 2.25]

  defp seat_obs(seat_hours, hours, share),
    do: %{share: share, hours: hours, draws: %{"seat" => seat_hours}}

  # Seats held at 2.9-3.0 and a draw at exactly the prior's rate with no
  # background, read to the poll's 1 point (Appendix A, seeds 1..8).
  defp barely_moving(seed) do
    :rand.seed(:exsss, {seed, 7, 9})

    for h <- @hours do
      density = 2.9 + :rand.uniform() * 0.1
      sh = density * h
      noise = (:rand.uniform() - 0.5) * 0.01
      seat_obs(sh, h, Float.round(@prior * sh + noise, 2))
    end
  end

  defp rung_fit(obs), do: Calibration.fit(obs, min_observations: 8, min_model_observations: 3)

  describe "I11: fits the data doesn't pin down fall through to the prior" do
    test "seats that never move: b takes the whole draw and fit/2 returns :non_positive" do
      obs = for h <- @hours, do: seat_obs(3.0 * h, h, 0.2 * h)
      fit = rung_fit(obs)

      assert fit.models["seat"].reason == :non_positive
      assert_in_delta fit.background_share_per_hour, 0.2, 1.0e-9

      assert %{rung: 2, rho: rho, passed_over: [{0, :non_positive}, {1, :no_peer_fit}]} =
               BudgetCalibration.resolve(fit, @prior, [])

      assert_in_delta rho, @prior, 1.0e-12
    end

    test "seats that barely move: rho is positive but not distinguishable from 0" do
      # Seeds 4 and 7 are the two eight-seed draws the design singles out.
      for seed <- [4, 7] do
        fit = barely_moving(seed) |> rung_fit()
        entry = fit.models["seat"]

        assert entry.status == :calibrated
        assert entry.share_per_weighted_token < @prior / 2
        assert entry.share_per_weighted_token / entry.std_error < Calibration.t_critical(fit.dof)

        assert %{
                 rung: 2,
                 rho: rho,
                 passed_over: [{0, {:not_distinguishable_from_zero, t}}, {1, :no_peer_fit}]
               } =
                 BudgetCalibration.resolve(fit, @prior, [])

        assert_in_delta rho, @prior, 1.0e-12
        assert t < 1.86
      end
    end

    test "the well-measured seeds are kept" do
      kept =
        for seed <- 1..8, seed not in [4, 7] do
          BudgetCalibration.resolve(barely_moving(seed) |> rung_fit(), @prior, [])
        end

      assert Enum.all?(kept, &(&1.rung == 0))
      assert Enum.all?(kept, &(&1.rho >= @prior / 4))
    end

    test "a noise-free rho of 0.001 passes the test and is clamped to the floor" do
      :rand.seed(:exsss, {1, 2, 3})

      obs =
        for h <- @hours do
          sh = (2.9 + :rand.uniform() * 0.1) * h
          seat_obs(sh, h, 0.001 * sh + 0.197 * h)
        end

      fit = rung_fit(obs)
      assert_in_delta fit.models["seat"].share_per_weighted_token, 0.001, 1.0e-9

      assert %{rung: 0, rho: rho, raw_rho: raw, floored?: true, passed_over: []} =
               BudgetCalibration.resolve(fit, @prior, [])

      assert_in_delta raw, 0.001, 1.0e-9
      assert_in_delta rho, @prior / 4, 1.0e-12
    end
  end

  describe "resolve/3: the ladder" do
    defp good_fit(rho) do
      :rand.seed(:exsss, {5, 5, 5})

      obs =
        for h <- @hours ++ [0.6, 0.9] do
          sh = h * (1 + :rand.uniform() * 4)
          seat_obs(sh, h, rho * sh + 0.01 * h + (:rand.uniform() - 0.5) * 0.0002)
        end

      rung_fit(obs)
    end

    test "rung 0 uses the account's own fit" do
      assert %{rung: 0, rho: rho, floored?: false} =
               BudgetCalibration.resolve(good_fit(0.05), @prior, [0.03])

      assert_in_delta rho, 0.05, 0.002
    end

    test "rung 1 takes the median of other accounts' measured rho when the own fit fails" do
      thin = Calibration.fit([], min_observations: 8, min_model_observations: 3)

      assert %{rung: 1, rho: rho, passed_over: [{0, :too_few_observations}]} =
               BudgetCalibration.resolve(thin, @prior, [0.05, 0.03, 0.04])

      assert_in_delta rho, 0.04, 1.0e-12
    end

    test "rung 1 is floored too" do
      thin = Calibration.fit([], min_observations: 8, min_model_observations: 3)

      assert %{rung: 1, rho: rho, floored?: true} =
               BudgetCalibration.resolve(thin, @prior, [0.001])

      assert_in_delta rho, @prior / 4, 1.0e-12
    end

    test "rung 2 is the prior, and is never clamped" do
      thin = Calibration.fit([], min_observations: 8, min_model_observations: 3)

      assert %{rung: 2, rho: rho, floored?: false, passed_over: passed} =
               BudgetCalibration.resolve(thin, @prior, [])

      assert rho == @prior
      assert passed == [{0, :too_few_observations}, {1, :no_peer_fit}]
    end

    test "the resolved rho is never below the floor and never zero" do
      for rho <- [0.0, 1.0e-9, 0.001, 0.02, 0.5] do
        fit = good_fit(rho)
        assert %{rho: r} = BudgetCalibration.resolve(fit, @prior, [])
        assert r >= @prior / 4
      end
    end
  end

  describe "prior/2" do
    test "1 / (W * k), with k = 2 when max_concurrent is unset" do
      assert_in_delta BudgetCalibration.prior(5 * 3600, 3), 1 / 15, 1.0e-12
      assert_in_delta BudgetCalibration.prior(5 * 3600, nil), 1 / 10, 1.0e-12
      assert_in_delta BudgetCalibration.prior(7 * 86_400, 3), 1 / (168 * 3), 1.0e-12
    end
  end

  describe "observations/3 (pure)" do
    test "seat-hours are the trapezoid of the seats column over every capture" do
      samples = [snap(0, 0.0, 2), snap(10, 0.01, 4), snap(60, 0.1, 4), snap(120, 0.2, 0)]

      assert [first, second] =
               BudgetCalibration.observations(samples, [], window: "5h", pool: "claude")

      # 0 -> 60 min: coalesced capture at 10; (2+4)/2 * 10min + (4+4)/2 * 50min
      assert_in_delta first.draws["seat"], 3.0 * (10 / 60) + 4.0 * (50 / 60), 1.0e-9
      assert_in_delta first.share, 0.1, 1.0e-9
      assert_in_delta first.hours, 1.0, 1.0e-9
      # 60 -> 120 min: (4+0)/2 * 1h
      assert_in_delta second.draws["seat"], 2.0, 1.0e-9
    end

    test "an interval with no seats history is reconstructed from run hours" do
      samples = [snap(0, 0.0, nil), snap(60, 0.1, nil)]

      runs = [
        %{started_at: at(10), completed_at: at(40), provider: "claude", model: nil},
        # open run: counts until the interval's end
        %{started_at: at(30), completed_at: nil, provider: "claude", model: nil},
        # a run on another pool does not seat this one
        %{started_at: at(0), completed_at: at(60), provider: "codex", model: nil},
        # outside the interval
        %{started_at: at(70), completed_at: at(90), provider: "claude", model: nil}
      ]

      assert [obs] =
               BudgetCalibration.observations(samples, runs, window: "5h", pool: "claude")

      assert_in_delta obs.draws["seat"], 0.5 + 0.5, 1.0e-9
    end

    test "an interval that spans a reset is dropped, as in the draw calibration" do
      samples = [snap(0, 0.5, 1), snap(60, 0.05, 1)]
      assert BudgetCalibration.observations(samples, [], window: "5h", pool: "claude") == []
    end
  end

  describe "calibrate/1 against the database" do
    defp insert_series(account, provider, bucket, window, seats_for, n) do
      for i <- 0..n do
        Ash.create!(QuotaSnapshot, %{
          provider_account_id: account,
          provider: provider,
          bucket: bucket,
          window: window,
          utilization: 0.01 * i * i / 4 + 0.002 * i,
          resets_at: at(24 * 60 * 3),
          captured_at: at(i * 40),
          seats: seats_for.(i)
        })
      end
    end

    test "fits a seat-hour coefficient per (account, pool, window) and reports the rung" do
      account = Ecto.UUID.generate()
      insert_series(account, "claude", "claude", "5h", fn i -> rem(i * 7, 5) + 1 end, 14)

      assert [result] = BudgetCalibration.calibrate(since: at(-60), until: at(24 * 60))

      assert %{account_id: ^account, provider: "claude", pool: "claude", window: "5h"} = result
      assert result.fit.status == :calibrated
      assert result.rung in [0, 2]
      assert result.rho >= result.floor
      assert_in_delta result.prior, 1 / (5 * 2), 1.0e-12
      assert result.horizon_hours == 2.0
    end

    test "falls back to the prior with the reason when the history is thin" do
      account = Ecto.UUID.generate()
      insert_series(account, "claude", "claude", "5h", fn _ -> 1 end, 3)

      assert [%{rung: 2, rho: rho, passed_over: [{0, :too_few_observations}, {1, :no_peer_fit}]}] =
               BudgetCalibration.calibrate(since: at(-60), until: at(24 * 60))

      assert_in_delta rho, 0.1, 1.0e-12
    end

    test "reconstructs seats from worker_runs while the column has no history" do
      account = Ecto.UUID.generate()
      insert_series(account, "claude", "claude", "5h", fn _ -> nil end, 12)

      for i <- 0..11 do
        Ash.create!(Run, %{
          task_id: "bd-seat#{i}",
          workspace_id: "ws",
          repo: "arbiter",
          provider: "claude",
          provider_account_id: account,
          started_at: at(i * 40),
          completed_at: at(i * 40 + 60)
        })
      end

      assert [result] = BudgetCalibration.calibrate(since: at(-60), until: at(24 * 60))
      assert result.fit.n >= 8
      assert result.fit.models["seat"].n >= 3
    end

    test "writes nothing" do
      account = Ecto.UUID.generate()
      insert_series(account, "claude", "claude", "5h", fn _ -> 1 end, 10)
      before = length(Ash.read!(QuotaSnapshot))
      _ = BudgetCalibration.calibrate(since: at(-60), until: at(24 * 60))
      assert length(Ash.read!(QuotaSnapshot)) == before
    end
  end

  describe "horizon/2 (H)" do
    defp tr(ticket, to, from, minutes),
      do: %{ticket_id: ticket, to_state: to, from_state: from, at: at(minutes)}

    test "median In-progress life, from the first active transition to leaving active" do
      transitions = [
        tr("a", :active, :queued, 0),
        tr("a", :merging, :active, 120),
        # re-entering active later is not a second life
        tr("a", :active, :merging, 130),
        tr("a", :verifying, :active, 400),
        tr("b", :active, :queued, 0),
        tr("b", :merging, :active, 180),
        tr("c", :active, :queued, 0),
        tr("c", :merging, :active, 240)
      ]

      pools = %{"a" => "claude", "b" => "claude", "c" => "claude"}
      assert BudgetCalibration.horizon(transitions, pools)["claude"] == 3.0
    end

    test "clamped to [1h, 4h] and 2h until measured" do
      short = [tr("a", :active, :queued, 0), tr("a", :merging, :active, 6)]
      long = [tr("a", :active, :queued, 0), tr("a", :merging, :active, 60 * 20)]
      assert BudgetCalibration.horizon(short, %{"a" => "claude"})["claude"] == 1.0
      assert BudgetCalibration.horizon(long, %{"a" => "claude"})["claude"] == 4.0
      assert BudgetCalibration.horizon([], %{}) == %{}
      assert BudgetCalibration.horizon_for(%{}, "claude") == 2.0
    end

    test "a ticket still active, or pinned to no pool, is not counted" do
      transitions = [tr("a", :active, :queued, 0), tr("b", :active, :queued, 0)]
      assert BudgetCalibration.horizon(transitions, %{"a" => "claude"}) == %{}
    end
  end

  describe "format/1" do
    test "prints the rung, rho, and why a rung was passed over" do
      assert BudgetCalibration.format([]) =~ "No quota history"

      thin = Calibration.fit([], min_observations: 8, min_model_observations: 3)
      resolved = BudgetCalibration.resolve(thin, @prior, [])

      result =
        Map.merge(resolved, %{
          account_id: "acct",
          provider: "claude",
          pool: "claude",
          window: "5h",
          fit: thin,
          prior: @prior,
          floor: @prior / 4,
          horizon_hours: 2.0
        })

      out = BudgetCalibration.format([result])
      assert out =~ "claude / 5h"
      assert out =~ "prior"
      assert out =~ "too_few_observations"
      assert out =~ "H 2.0 h"
    end
  end
end
