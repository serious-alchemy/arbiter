defmodule Arbiter.Board.AdmissionShadowReportTest do
  @moduledoc """
  DC7 (bd-6cuqcf; `docs/design/provider-dynamic-concurrency.md` §10.3-§10.4):
  the report that compares the scheduler walk's recorded decisions with
  today's. `build/1` is pure and is tested on hand-made rows; `collect/1` and
  `Arbiter.Release.admission_shadow_report/1` read the real tables.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.AdmissionShadowEvent
  alias Arbiter.Board.AdmissionShadowReport, as: Report
  alias Arbiter.Quota.QuotaSnapshot

  @t0 ~U[2026-10-01 00:00:00Z]
  @until ~U[2026-10-15 00:00:00Z]

  defp at(minutes), do: DateTime.add(@t0, round(minutes * 60), :second)

  defp dispatch(minutes, overrides \\ %{}) do
    record =
      Map.merge(
        %{
          "policy" => "shadow",
          "dispatched" => "bd-a",
          "pick" => "bd-a",
          "agrees" => true,
          "comparable" => true,
          "cause" => nil,
          "pool" => "claude",
          "pool_label" => "claude:default",
          "account_id" => "acct-1"
        },
        overrides
      )

    %{at: at(minutes), record: record}
  end

  defp event(minutes, overrides \\ %{}) do
    Map.merge(
      %{
        at: at(minutes),
        policy: "shadow",
        legacy_pick: "bd-a",
        walk_pick: "bd-a",
        agrees: true,
        comparable: true,
        cause: nil,
        legacy: %{},
        walk: %{"pool_label" => "claude:default"},
        budgets: []
      },
      overrides
    )
  end

  defp build(data) do
    Report.build(
      Map.merge(
        %{
          since: @t0,
          until: @until,
          dispatches: [],
          events: [],
          snapshots: [],
          accounts: %{},
          calibration: []
        },
        data
      )
    )
  end

  describe "agreement" do
    test "counts comparable dispatches, the rate and every disagreement by cause" do
      dispatches = [
        dispatch(1),
        dispatch(2),
        dispatch(3, %{
          "pick" => "bd-b",
          "agrees" => false,
          "cause" => "capacity:provider"
        }),
        dispatch(4, %{"pick" => "bd-c", "agrees" => false, "cause" => "queued"}),
        dispatch(5, %{"pick" => nil, "agrees" => false, "comparable" => false, "cause" => "paused"})
      ]

      %{agreement: a} = build(%{dispatches: dispatches})

      assert a.dispatches == 5
      assert a.comparable == 4
      assert a.agree == 2
      assert a.disagree == 2
      assert_in_delta a.rate, 0.5, 1.0e-9
      assert a.not_comparable == 1
      assert a.by_cause == %{"capacity:provider" => 1, "queued" => 1}
    end

    test "an empty window has no rate, never 0 or 100 percent" do
      %{agreement: a} = build(%{})
      assert a.comparable == 0
      assert a.rate == nil
    end

    test "is split per pool of the walk's pick" do
      dispatches = [
        dispatch(1),
        dispatch(2, %{"pool_label" => "codex:default", "pool" => "codex"}),
        dispatch(3, %{
          "pool_label" => "codex:default",
          "pool" => "codex",
          "agrees" => false,
          "cause" => "capacity:node"
        })
      ]

      %{agreement: %{pools: pools}} = build(%{dispatches: dispatches})

      assert %{comparable: 1, agree: 1} = Enum.find(pools, &(&1.pool == "claude:default"))

      assert %{comparable: 2, agree: 1, disagree: 1, by_cause: %{"capacity:node" => 1}} =
               Enum.find(pools, &(&1.pool == "codex:default"))
    end

    test "counts the budgets that sat above today's cap, where the ceiling binds" do
      events = [
        event(0, %{
          budgets: [
            %{"label" => "claude:default", "pool" => "claude", "budget" => 5, "cap" => 3},
            %{"label" => "codex:default", "pool" => "codex", "budget" => 2, "cap" => 3}
          ]
        })
      ]

      %{agreement: a} = build(%{events: events})
      assert a.budget_above_cap == %{"claude:default" => 1}
      assert a.budget_below_cap == %{"codex:default" => 1}
    end
  end

  describe "throughput" do
    test "minutes where today held and the walk would place, and the reverse" do
      events = [
        event(0),
        # today holds, the walk places a card: 30 minutes
        event(60, %{legacy_pick: nil, agrees: false, comparable: false, cause: "legacy_hold"}),
        event(90),
        # the walk holds, today places: 15 minutes
        event(120, %{walk_pick: nil, agrees: false, comparable: false, cause: "capacity:provider"}),
        event(135)
      ]

      %{throughput: t} = build(%{events: events})

      assert_in_delta t.walk_ahead_minutes, 30.0, 1.0e-6
      assert_in_delta t.legacy_ahead_minutes, 15.0, 1.0e-6
      assert t.by_pool == %{"claude:default" => 30.0}
    end

    test "the last interval runs to the end of the window, capped" do
      events = [event(0, %{legacy_pick: nil, agrees: false, comparable: false})]
      %{throughput: t} = build(%{events: events})

      # capped at 6 h so a switch back to legacy cannot inflate it
      assert_in_delta t.walk_ahead_minutes, 360.0, 1.0e-6
      assert t.capped_intervals == 1
    end
  end

  describe "pace safety" do
    defp snap(minutes, util, seats, extra \\ %{}) do
      Map.merge(
        %{
          provider_account_id: "acct-1",
          provider: "claude",
          bucket: "claude",
          window: "5h",
          utilization: util,
          resets_at: at(300),
          captured_at: at(minutes),
          seats: seats,
          budget: nil
        },
        extra
      )
    end

    test "reports the u - line distribution and ahead-of-pace admissions per pool" do
      # 5h window ending at minute 300, paced: at minute 60 the line is the
      # 0.35 floor, so u = 0.60 is 0.25 ahead of it.
      snapshots = [
        snap(30, 0.01, 1),
        snap(60, 0.60, 2),
        snap(90, 0.62, 2),
        snap(240, 0.90, 2)
      ]

      paced = %Arbiter.Accounts.ProviderAccount{quota_config: %{"threshold_mode" => "paced"}}

      %{pace: [pool]} = build(%{snapshots: snapshots, accounts: %{"acct-1" => paced}})

      assert pool.pool == "claude"
      assert pool.captures == 4
      # the worst capture is minute 90: u .62 on a line still at the .35 floor
      assert_in_delta pool.max_ahead, 0.27, 1.0e-6
      # seats rose 1 -> 2 at minute 60 with u over the line by .25
      assert pool.ahead_admissions == 1
      assert_in_delta pool.largest_epsilon, 0.25, 1.0e-6
      # the line (.8 at minute 240) is still below u .9: never back on it
      assert pool.minutes_back_to_line == nil
    end

    test "counts a projected exhaustion once per episode" do
      calibration = [
        %{
          account_id: "acct-1",
          provider: "claude",
          pool: "claude",
          window: "5h",
          rung: 2,
          rho: 0.2,
          raw_rho: 0.2,
          floored?: false,
          passed_over: [],
          horizon_hours: 2.0,
          fit: %{status: :insufficient, n: 0},
          observations: []
        }
      ]

      # at minute 30, 1 seat * 0.2/h * 4.5h left = 0.9 more: 0.95 + ... > 1
      snapshots = [snap(10, 0.05, 1), snap(30, 0.2, 1), snap(60, 0.3, 1), snap(120, 0.3, 0)]

      %{pace: [pool]} = build(%{snapshots: snapshots, calibration: calibration})
      assert pool.projected_exhaustions == 1
    end

    test "nothing is projected without a rate" do
      %{pace: [pool]} = build(%{snapshots: [snap(10, 0.99, 3)]})
      assert pool.projected_exhaustions == 0
    end
  end

  describe "calibration" do
    test "bias and mean absolute error per rung from predicted vs actual draw" do
      obs = [
        # predicted 0.1 * 2 + 0.01 * 1 = 0.21 against an actual 0.20
        %{share: 0.20, hours: 1.0, draws: %{"seat" => 2.0}},
        # predicted 0.1 * 1 + 0.01 * 1 = 0.11 against an actual 0.10
        %{share: 0.10, hours: 1.0, draws: %{"seat" => 1.0}}
      ]

      calibration = [
        %{
          account_id: "acct-1",
          provider: "claude",
          pool: "claude",
          window: "5h",
          rung: 0,
          rho: 0.1,
          raw_rho: 0.1,
          floored?: false,
          passed_over: [{1, :no_peer_fit}],
          horizon_hours: 2.0,
          fit: %{
            status: :calibrated,
            n: 2,
            background_share_per_hour: 0.01,
            models: %{"seat" => %{status: :calibrated, share_per_weighted_token: 0.1}}
          },
          observations: obs
        }
      ]

      %{calibration: %{rungs: [rung], fits: [fit]}} = build(%{calibration: calibration})

      assert rung.rung == 0
      assert rung.intervals == 2
      assert_in_delta rung.mean_abs_error, 0.01, 1.0e-9
      assert_in_delta rung.bias, 0.02 / 0.30, 1.0e-9
      assert fit.rung == 0
      assert fit.passed_over == [{1, :no_peer_fit}]
    end

    test "a fit with no observations reports no bias, not zero" do
      calibration = [
        %{
          account_id: "a",
          provider: "claude",
          pool: "claude",
          window: "5h",
          rung: 2,
          rho: 0.1,
          raw_rho: 0.1,
          floored?: false,
          passed_over: [],
          horizon_hours: 2.0,
          fit: %{status: :insufficient, n: 0},
          observations: []
        }
      ]

      %{calibration: %{rungs: [rung]}} = build(%{calibration: calibration})
      assert rung.bias == nil
      assert rung.intervals == 0
    end
  end

  describe "stability" do
    test "published budget changes per pool per day and the median dwell" do
      snapshots =
        for {m, b} <- [{0, 3}, {60, 3}, {120, 2}, {240, 3}, {300, 3}, {480, 1}] do
          snap(m, 0.1, 1, %{budget: b})
        end

      %{stability: [pool]} = build(%{snapshots: snapshots})

      assert pool.pool == "claude"
      assert pool.changes == 3
      # 14 day window
      assert_in_delta pool.changes_per_day, 3 / 14, 1.0e-9
      assert_in_delta pool.max_changes_per_hour, 1.0, 1.0e-9
      # dwells: 120 min (3 until 2 at m120), 120, 240 -> median 120
      assert_in_delta pool.median_dwell_minutes, 120.0, 1.0e-6
    end

    test "captures before the budget columns existed are not changes" do
      %{stability: [pool]} = build(%{snapshots: [snap(0, 0.1, nil), snap(60, 0.1, nil)]})
      assert pool.changes == 0
      assert pool.median_dwell_minutes == nil
    end
  end

  describe "near resets" do
    test "budget against seats before a reset and usage after it" do
      reset = at(300)

      snapshots = [
        snap(100, 0.2, 1, %{budget: 3}),
        # inside the last horizon (2 h) before the reset
        snap(200, 0.5, 3, %{budget: 1}),
        snap(280, 0.6, 3, %{budget: 1}),
        # after the reset: a new window
        snap(310, 0.02, 3, %{budget: 3, resets_at: at(600)}),
        snap(360, 0.05, 2, %{budget: 3, resets_at: at(600)}),
        snap(500, 0.30, 2, %{budget: 3, resets_at: at(600)})
      ]

      %{near_resets: [r]} = build(%{snapshots: snapshots})

      assert r.pool == "claude"
      assert r.window == "5h"
      assert r.reset_at == reset
      assert r.max_seats_before == 3
      assert r.min_budget_before == 1
      assert r.over_budget_before == true
      assert_in_delta r.max_used_after, 0.05, 1.0e-9
    end
  end

  describe "the enforce gate (§10.4)" do
    test "each criterion is met, unmet or unknown, never silently green" do
      %{gate: gate} = build(%{})

      assert Enum.all?(gate, &(&1.status == :unmet or &1.status == :unknown))
      assert Enum.find(gate, &(&1.id == :days_in_shadow)).status == :unmet
      assert Enum.find(gate, &(&1.id == :comparable_dispatches)).status == :unmet
      assert Enum.find(gate, &(&1.id == :disagreements_reviewed)).status == :unknown
    end

    test "met on enough comparable dispatches over enough days" do
      dispatches = for m <- 0..59, do: dispatch(m * 400)
      %{gate: gate} = build(%{dispatches: dispatches})

      assert Enum.find(gate, &(&1.id == :comparable_dispatches)).status == :met
      assert Enum.find(gate, &(&1.id == :days_in_shadow)).status == :met
    end
  end

  describe "format/1" do
    test "renders every section" do
      text = Report.format(build(%{dispatches: [dispatch(1)], events: [event(0)]}))

      for heading <- ~w(Agreement Throughput Pace Calibration Stability Near Gate) do
        assert text =~ heading
      end
    end
  end

  describe "collect/1 and Arbiter.Release.admission_shadow_report/1" do
    test "reads event rows and quota captures; an empty database reports empty, not green" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert %{agreement: %{dispatches: 0}} =
                   Arbiter.Release.admission_shadow_report(start: false)
        end)

      assert output =~ "Agreement"
    end

    test "reports events written by AdmissionShadow" do
      now = DateTime.utc_now()

      Ash.create!(
        AdmissionShadowEvent,
        %{
          at: DateTime.add(now, -3600, :second),
          policy: "shadow",
          legacy_pick: nil,
          walk_pick: "bd-x",
          agrees: false,
          comparable: false,
          cause: "legacy_hold",
          legacy: %{"pick" => nil},
          walk: %{"pick" => "bd-x", "pool_label" => "claude:default"},
          budgets: [%{"label" => "claude:default", "budget" => 2, "cap" => 3}]
        },
        action: :record
      )

      Ash.create!(QuotaSnapshot, %{
        provider_account_id: Ecto.UUID.generate(),
        provider: "claude",
        bucket: "claude",
        window: "5h",
        utilization: 0.1,
        resets_at: DateTime.add(now, 3600, :second),
        captured_at: DateTime.add(now, -1800, :second),
        seats: 1,
        budget: 2
      })

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          report = Arbiter.Release.admission_shadow_report(start: false)
          assert report.agreement.budget_below_cap == %{"claude:default" => 1}
          assert report.throughput.walk_ahead_minutes > 0
          assert [%{pool: "claude"}] = report.pace
        end)

      assert output =~ "claude"
    end

    test "writes nothing" do
      before = length(Ash.read!(AdmissionShadowEvent))

      ExUnit.CaptureIO.capture_io(fn ->
        Arbiter.Release.admission_shadow_report(start: false)
      end)

      assert length(Ash.read!(AdmissionShadowEvent)) == before
    end
  end
end
