defmodule Arbiter.Quota.CodexPacingTest do
  @moduledoc "Plan-aware Codex pacing (bd-afvsnc)."
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.{Codex, CodexPlanWindows, CodexQuota, CodexQuotaSnapshot, Gate}
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-10-04 12:00:00Z]
  @month 43_200 * 60

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.drop(prior, [:throttle_threshold, :weekly_threshold, :codex_plan_windows])
    )

    :ok
  end

  defp paced_account(extra \\ %{}),
    do: %ProviderAccount{
      provider: :codex,
      quota_config: Map.merge(%{"threshold_mode" => "paced"}, extra)
    }

  # `elapsed` of a window of `seconds` has gone by at @now.
  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  defp row(attrs) do
    struct(
      %CodexQuota{
        provider: "codex",
        plan: "free",
        session_used_percent: 10.0,
        session_reset_at: reset_after(0.5, @month),
        weekly_used_percent: nil,
        weekly_reset_at: nil,
        limit_reached: false,
        captured_at: @now
      },
      attrs
    )
  end

  describe "CodexPlanWindows" do
    test "free and paid resolve to different lengths; weekly is nil on free" do
      assert CodexPlanWindows.minutes("free", :session) == 43_200
      assert CodexPlanWindows.minutes("free", :weekly) == nil
      assert CodexPlanWindows.minutes("plus", :session) == 300
      assert CodexPlanWindows.minutes("Plus", :weekly) == 10_080
    end

    test "unknown or missing plan is nil, never a default" do
      assert CodexPlanWindows.minutes("mystery", :session) == nil
      assert CodexPlanWindows.minutes(nil, :session) == nil
      refute CodexPlanWindows.known_plan?("mystery")
    end

    test "app-env override merges over the defaults" do
      Application.put_env(:arbiter, :quota, codex_plan_windows: %{"free" => %{session: 100}})
      assert CodexPlanWindows.minutes("free", :session) == 100
      assert CodexPlanWindows.minutes("plus", :session) == 300
    end
  end

  describe "gate pacing resolves the window length per plan" do
    test "free plan under pace is allowed" do
      r = row(session_used_percent: 20.0, session_reset_at: reset_after(0.53, @month))
      assert Gate.gating_window(r, {paced_account(), nil}, now: @now) == nil
    end

    test "free plan over pace is held, with a pace reason" do
      r = row(session_used_percent: 80.0, session_reset_at: reset_after(0.53, @month))

      assert %{mode: :paced, window: "30d"} =
               Gate.gating_window(r, {paced_account(), nil}, now: @now)

      assert Gate.hold_phrase(r, {paced_account(), nil}, now: @now) =~ "pace"
    end

    test "window reset clears the hold" do
      r = row(session_used_percent: 80.0, session_reset_at: reset_after(0.53, @month))
      assert Gate.gating_window(r, {paced_account(), nil}, now: @now)
      later = DateTime.add(r.session_reset_at, 60, :second)
      assert Gate.gating_window(r, {paced_account(), nil}, now: later) == nil
    end

    test "same used/elapsed inputs give different verdicts on free vs plus" do
      # 40% used, reset 3.5h out. Free (30d window): ~99.5% elapsed, ceiling
      # ~0.995 -> allowed. Plus (5h window): 30% elapsed, ceiling = the 0.35
      # floor -> held.
      reset = DateTime.add(@now, 12_600, :second)
      free = row(plan: "free", session_used_percent: 40.0, session_reset_at: reset)
      plus = row(plan: "plus", session_used_percent: 40.0, session_reset_at: reset)
      acct = {paced_account(), nil}

      assert Gate.gating_window(free, acct, now: @now) == nil
      assert Gate.gating_window(plus, acct, now: @now)
      assert Snapshot.normalize(free).window_label == "30d"
      assert Snapshot.normalize(plus).window_label == "5h"
    end

    test "a reported window length outranks the plan table" do
      r = row(plan: "free", session_window_minutes: 300)
      assert Snapshot.normalize(r).window_label == "5h"
    end

    test "unknown plan with no reported length: pacing off (flat ceiling applies)" do
      r =
        row(
          plan: "mystery",
          session_used_percent: 60.0,
          session_reset_at: reset_after(0.9, @month)
        )

      assert Snapshot.normalize(r).window_label == "session"
      # paced would hold nothing at 60% of 90% elapsed anyway; flat 0.85 allows it.
      assert Gate.gating_window(r, {paced_account(), nil}, now: @now) == nil
      r2 = %{r | session_used_percent: 90.0}
      binding = Gate.gating_window(r2, {paced_account(), nil}, now: @now)
      assert binding
      refute Map.has_key?(binding, :mode)
    end

    test "weekly: nil does not break the free shape; paid weekly paced independently" do
      free = row(plan: "free")
      snap = Snapshot.normalize(free)
      assert snap.secondary_utilization == nil
      assert snap.secondary_reset_at == nil

      plus =
        row(
          plan: "plus",
          session_used_percent: 1.0,
          session_reset_at: reset_after(0.5, 18_000),
          weekly_used_percent: 90.0,
          weekly_reset_at: reset_after(0.3, 604_800)
        )

      assert %{window: "weekly", mode: :paced} =
               Gate.gating_window(plus, {paced_account(), nil}, now: @now)
    end
  end

  describe "Codex.pacing/3 (quota_get state)" do
    test "reports fractions, no gating_reason when under pace" do
      r = row(session_used_percent: 20.0, session_reset_at: reset_after(0.5, @month))
      p = Codex.pacing(r, paced_account(), now: @now)
      assert p.enabled
      assert_in_delta p.elapsed_fraction, 0.5, 0.001
      assert_in_delta p.used_fraction, 0.2, 0.001
      assert p.window_source == :plan_table
      assert p.gating_reason == nil
      assert p.weekly == nil
    end

    test "gating_reason when held" do
      r = row(session_used_percent: 80.0, session_reset_at: reset_after(0.5, @month))
      p = Codex.pacing(r, paced_account(), now: @now)
      assert is_binary(p.gating_reason)
    end

    test "unknown plan says pacing is off" do
      r = row(plan: "mystery")
      p = Codex.pacing(r, paced_account(), now: @now)
      refute p.enabled
      assert p.disabled_reason =~ "mystery"
      assert p.elapsed_fraction == nil
    end

    test "reported length is labelled as such" do
      r = row(plan: "mystery", session_window_minutes: 43_200)
      p = Codex.pacing(r, paced_account(), now: @now)
      assert p.enabled
      assert p.window_source == :reported
    end
  end

  describe "persistence" do
    setup do
      prev = Application.get_env(:arbiter, :codex_quota_http_stub)
      Application.put_env(:arbiter, :codex_quota_http_stub, true)

      on_exit(fn ->
        if is_nil(prev),
          do: Application.delete_env(:arbiter, :codex_quota_http_stub),
          else: Application.put_env(:arbiter, :codex_quota_http_stub, prev)
      end)
    end

    defp fetch!(ws, body) do
      Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn -> Req.Test.json(conn, body) end)
      Codex.fetch(ws.id, credentials: %{access_token: "t", account_id: "a"})
    end

    test "each capture is appended to the snapshot history; downgrade clears weekly" do
      ws = Ash.create!(Workspace, %{name: "pace-ws"})
      account_id = quota_account_id!(ws.id, "codex")

      fetch!(ws, %{
        "plan_type" => "plus",
        "rate_limit" => %{
          "primary_window" => %{"used_percent" => 10, "reset_at" => 1_782_247_200},
          "secondary_window" => %{"used_percent" => 5, "reset_at" => 1_782_748_800}
        }
      })

      fetch!(ws, %{
        "plan_type" => "free",
        "rate_limit" => %{
          "primary_window" => %{"used_percent" => 27, "reset_at" => 1_784_000_000},
          "secondary_window" => nil
        }
      })

      row = Codex.latest(account_id)
      assert row.plan == "free"
      assert row.weekly_used_percent == nil
      assert row.weekly_reset_at == nil

      history = Codex.history(account_id)
      assert Enum.map(history, & &1.plan) == ["plus", "free"]
      assert %CodexQuotaSnapshot{session_used_percent: 27.0} = List.last(history)
    end
  end
end
