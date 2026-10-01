defmodule Arbiter.Messages.CoordinatorNotifierAlertsTest do
  @moduledoc """
  bd-7gt8rm (ticket lifecycle 8/13): the four system-level producers in
  `CoordinatorNotifier` — `credential_expired`, `quota_poll_failing`,
  `overage_alert` and `budget_exceeded` — raise an operator-owned system alert
  (`Arbiter.Alerts`) instead of posting a coordinator escalation, and each has
  a counterpart that clears it when the condition clears.

  Replaces the escalation-shaped tests from bd-5wchp1, bd-6jjgk0 and bd-7cd38f;
  the body text those pinned now lives in the alert's `detail`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Messages.Message
  alias Arbiter.Worker.StopReason

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp only_alert(kind) do
    assert [alert] = Alerts.active(kind: kind)
    alert
  end

  defp auth_reason, do: StopReason.classify(1, ["401 invalid authentication credentials"])

  defp oauth_401_reason(count) do
    %StopReason{
      category: :auth_expired,
      summary: "#{count} consecutive 401s from the /api/oauth/usage poll for [\"ws\"]",
      remediation: "re-authenticate the operator's Claude OAuth credentials (`claude login`)",
      exit_status: nil,
      signal: nil
    }
  end

  defp no_mail(ws), do: assert(Message.inbox("admiral", workspace_id: ws) == [])

  describe "credential_expired" do
    test "raises an operator-owned alert naming the adapter, and posts no escalation" do
      ws = uniq("ws")

      assert :ok =
               CoordinatorNotifier.credential_expired(
                 %{workspace_id: ws},
                 Arbiter.Agents.Claude,
                 auth_reason()
               )

      alert = only_alert(:credential_expired)
      assert alert.owner == :operator
      assert alert.workspace_id == ws
      assert alert.subject =~ "Claude credentials expired"
      assert alert.detail =~ "Proactive"
      assert alert.detail =~ "suspended"
      assert is_nil(alert.cleared_at)
      no_mail(ws)
    end

    test "N failing cycles keep one active alert whose detail tracks the latest" do
      ws = uniq("ws")

      for n <- 2..10 do
        CoordinatorNotifier.credential_expired(
          %{workspace_id: ws},
          Arbiter.Agents.Claude,
          oauth_401_reason(n),
          :usage_poll
        )
      end

      alert = only_alert(:credential_expired)
      assert alert.detail =~ "10 consecutive 401s"
      assert alert.raise_count == 9
    end

    test "each (adapter, source) is its own alert" do
      ws = uniq("ws")

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        auth_reason(),
        :periodic_probe
      )

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        oauth_401_reason(2),
        :usage_poll
      )

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Codex,
        oauth_401_reason(2),
        :usage_poll
      )

      assert length(Alerts.active(kind: :credential_expired)) == 3
    end

    test "a :usage_poll expiry with the gate open says dispatch is NOT suspended and names the probe's credential" do
      CoordinatorNotifier.credential_expired(
        %{workspace_id: uniq("ws")},
        Arbiter.Agents.Claude,
        oauth_401_reason(2),
        :usage_poll,
        false
      )

      alert = only_alert(:credential_expired)
      refute alert.detail =~ "new worker dispatches for this adapter are suspended"
      assert alert.detail =~ "NOT suspended"
      assert alert.detail =~ "probe's own cached OAuth token"
    end

    test "a :usage_poll expiry with the gate closed claims suspension and still names the probe's credential" do
      CoordinatorNotifier.credential_expired(
        %{workspace_id: uniq("ws")},
        Arbiter.Agents.Claude,
        oauth_401_reason(2),
        :usage_poll,
        true
      )

      alert = only_alert(:credential_expired)
      assert alert.detail =~ "new worker dispatches for this adapter are suspended"
      assert alert.detail =~ "probe's own cached OAuth token"
    end

    test "the default source does not add the usage-poll caveat" do
      CoordinatorNotifier.credential_expired(
        %{workspace_id: uniq("ws")},
        Arbiter.Agents.Claude,
        auth_reason()
      )

      alert = only_alert(:credential_expired)
      assert alert.detail =~ "new worker dispatches for this adapter are suspended"
      refute alert.detail =~ "probe's own cached OAuth token"
    end

    test "with no workspace raises nothing" do
      assert :ok =
               CoordinatorNotifier.credential_expired(
                 %{workspace_id: nil},
                 Arbiter.Agents.Claude,
                 auth_reason()
               )

      assert Alerts.active() == []
    end
  end

  describe "credential_restored" do
    test "clears the alert its (adapter, source) raised, and posts nothing" do
      ws = uniq("ws")

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        auth_reason()
      )

      alert = only_alert(:credential_expired)

      assert :ok =
               CoordinatorNotifier.credential_restored(%{workspace_id: ws}, Arbiter.Agents.Claude)

      assert Ash.get!(Arbiter.Alerts.SystemAlert, alert.id).cleared_at
      assert Alerts.active() == []
      no_mail(ws)
    end

    test "a :usage_poll recovery leaves a :periodic_probe episode for the same adapter active" do
      ws = uniq("ws")

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        auth_reason(),
        :periodic_probe
      )

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        oauth_401_reason(2),
        :usage_poll
      )

      CoordinatorNotifier.credential_restored(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        :usage_poll
      )

      alert = only_alert(:credential_expired)
      assert alert.subject =~ "proactive detection"
    end

    test "a later failure after recovery opens a fresh alert" do
      ws = uniq("ws")

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        auth_reason()
      )

      first = only_alert(:credential_expired)
      CoordinatorNotifier.credential_restored(%{workspace_id: ws}, Arbiter.Agents.Claude)

      CoordinatorNotifier.credential_expired(
        %{workspace_id: ws},
        Arbiter.Agents.Claude,
        auth_reason()
      )

      second = only_alert(:credential_expired)
      refute second.id == first.id
    end

    test "recovering with nothing active is a no-op" do
      ws = uniq("ws")

      assert :ok =
               CoordinatorNotifier.credential_restored(%{workspace_id: ws}, Arbiter.Agents.Claude)

      assert Alerts.active() == []
      no_mail(ws)
    end
  end

  describe "quota_poll_failing / quota_poll_recovered" do
    test "raises one install-wide alert naming the failure count, and posts no escalation" do
      ws = uniq("ws")

      assert :ok =
               CoordinatorNotifier.quota_poll_failing(%{workspace_id: ws}, 3, {:http_error, 500})

      alert = only_alert(:quota_poll_failing)
      assert alert.owner == :operator
      assert alert.subject =~ "3 consecutive cycles"
      assert alert.detail =~ "/api/oauth/usage"
      no_mail(ws)

      # The poll is account-wide: a later outage reported through another
      # workspace folds into the same alert.
      CoordinatorNotifier.quota_poll_failing(%{workspace_id: uniq("ws")}, 3, :timeout)
      assert [%{id: id}] = Alerts.active(kind: :quota_poll_failing)
      assert id == alert.id
    end

    test "a successful poll clears it" do
      CoordinatorNotifier.quota_poll_failing(%{workspace_id: uniq("ws")}, 3, :timeout)
      alert = only_alert(:quota_poll_failing)

      assert :ok = CoordinatorNotifier.quota_poll_recovered()

      assert Ash.get!(Arbiter.Alerts.SystemAlert, alert.id).cleared_at
      assert Alerts.active() == []
    end
  end

  describe "overage_alert / overage_cleared" do
    test "raises a per-workspace alert naming the spend and threshold, and posts no escalation" do
      ws = uniq("ws")

      assert :ok =
               CoordinatorNotifier.overage_alert(
                 %{task_id: uniq("bd"), workspace_id: ws},
                 12.5,
                 10.0
               )

      alert = only_alert(:overage_alert)
      assert alert.key == ws
      assert alert.workspace_id == ws
      assert alert.subject =~ "$10.00"
      assert alert.subject =~ "12.50"
      assert alert.detail =~ "has NOT stopped"
      no_mail(ws)
    end

    test "a second crossing refreshes the workspace's alert" do
      ws = uniq("ws")
      CoordinatorNotifier.overage_alert(%{workspace_id: ws}, 10.5, 10.0)
      CoordinatorNotifier.overage_alert(%{workspace_id: ws}, 20.5, 10.0)

      alert = only_alert(:overage_alert)
      assert alert.subject =~ "20.50"
      assert alert.raise_count == 2
    end

    test "clearing one workspace leaves another's alert active" do
      ws_a = uniq("ws")
      ws_b = uniq("ws")
      CoordinatorNotifier.overage_alert(%{workspace_id: ws_a}, 12.0, 10.0)
      CoordinatorNotifier.overage_alert(%{workspace_id: ws_b}, 12.0, 10.0)

      assert :ok = CoordinatorNotifier.overage_cleared(ws_a)

      assert [%{key: ^ws_b}] = Alerts.active(kind: :overage_alert)
    end

    test "with no workspace raises nothing" do
      assert :ok = CoordinatorNotifier.overage_alert(%{workspace_id: nil}, 5.0, 5.0)
      assert Alerts.active() == []
    end
  end

  describe "budget_exceeded / budget_recovered" do
    defp budget_info do
      %{
        spend: 42.0,
        estimate: %{p25: 5.0, p75: 10.0, median: 7.0, p90: 20.0, basis: "difficulty", n: 12},
        difficulty: 2,
        worker_state: "no live worker"
      }
    end

    test "raises a per-task alert, and posts no escalation" do
      ws = uniq("ws")
      task_id = uniq("bd")

      assert :ok =
               CoordinatorNotifier.budget_exceeded(
                 %{task_id: task_id, workspace_id: ws},
                 budget_info()
               )

      alert = only_alert(:budget_exceeded)
      assert alert.key == task_id
      assert alert.owner == :operator
      assert alert.subject == CoordinatorNotifier.budget_exceeded_subject(task_id)
      assert alert.detail =~ "$42.00"
      no_mail(ws)
    end

    test "a repeat updates the detail instead of adding a second alert" do
      ws = uniq("ws")
      task_id = uniq("bd")
      CoordinatorNotifier.budget_exceeded(%{task_id: task_id, workspace_id: ws}, budget_info())

      CoordinatorNotifier.budget_exceeded(%{task_id: task_id, workspace_id: ws}, %{
        budget_info()
        | spend: 55.0
      })

      alert = only_alert(:budget_exceeded)
      assert alert.detail =~ "$55.00"
    end

    test "budget_recovered clears every task not still over" do
      ws = uniq("ws")
      over = uniq("bd")
      back = uniq("bd")
      CoordinatorNotifier.budget_exceeded(%{task_id: over, workspace_id: ws}, budget_info())
      CoordinatorNotifier.budget_exceeded(%{task_id: back, workspace_id: ws}, budget_info())

      assert :ok = CoordinatorNotifier.budget_recovered([over])

      assert [%{key: ^over}] = Alerts.active(kind: :budget_exceeded)
    end
  end

  # bd-2wnkoq: these used to say a 7d hold "cannot lift without a fresh polled
  # snapshot". It can: the hold is bounded by the 7d window's own reset
  # (`Arbiter.Quota.Gate.long_window_stale?/1`). Say when it lifts.
  describe "the poll-failure pages say when a 7d hold lifts" do
    defp escalation_body(ws) do
      assert [msg] = Message.inbox(Message.coordinator_ref(), workspace_id: ws)
      msg.body
    end

    @lifts "a 7d hold stays in force until the 7d window resets"

    test "quota_poll_failing" do
      CoordinatorNotifier.quota_poll_failing(%{workspace_id: uniq("ws")}, 3, :timeout)

      detail = only_alert(:quota_poll_failing).detail
      assert detail =~ @lifts
      refute detail =~ "cannot lift"
    end

    test "operator_login_lapsed" do
      ws = uniq("ws")
      CoordinatorNotifier.operator_login_lapsed(%{workspace_id: ws}, 3, :no_credentials)

      body = escalation_body(ws)
      assert body =~ @lifts
      refute body =~ "cannot lift"
    end

    test "quota_grant_failing" do
      ws = uniq("ws")

      CoordinatorNotifier.quota_grant_failing(
        %{workspace_id: ws},
        "/tmp/quota-claude/.credentials.json",
        {:poll_failing, 3, {:http_error, 401}}
      )

      body = escalation_body(ws)
      assert body =~ @lifts
      refute body =~ "cannot lift"
    end
  end

  # bd-2wnkoq: an alert about the quota snapshot's *state* — keyed on how old
  # it is, not on anything reporting a poll failure.
  describe "quota_snapshot_stale / quota_snapshot_recovered" do
    defp stale_info(overrides \\ %{}) do
      Map.merge(
        %{
          account_id: "acct-1",
          account: "claude:default",
          workspaces: ["default", "vstim"],
          captured_at: ~U[2026-09-17 00:29:42Z],
          age_seconds: 19 * 3_600 + 3 * 60,
          threshold_seconds: 1_800,
          capture_source: "oauth_poll",
          last_poll_at: nil,
          cap_reached_until: nil,
          long_window: %{
            label: "7d",
            utilization: 0.45,
            status: "allowed",
            reset_at: ~U[2026-09-20 00:00:00Z],
            reset_in_seconds: 71 * 3_600,
            rolled?: false,
            hold: nil
          }
        },
        overrides
      )
    end

    defp held_7d(info) do
      put_in(info.long_window.hold, %{
        workspaces: ["default"],
        reason: "7d quota 96% ≥ 90%"
      })
    end

    test "raises one operator alert saying how long quota accounting has been blind" do
      ws = uniq("ws")

      assert :ok = CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: ws}, stale_info())

      alert = only_alert(:quota_snapshot_stale)
      assert alert.owner == :operator
      assert alert.workspace_id == ws
      assert alert.key == "claude:acct-1"
      assert alert.subject =~ "claude:default"
      assert alert.subject =~ "2026-09-17T00:29:42Z"
      assert alert.detail =~ "blind for 19h 3m"
      assert alert.detail =~ "5h gate is failing open"
      assert alert.detail =~ "5h overage detection"
      assert alert.detail =~ "/api/oauth/usage poll"
      no_mail(ws)
    end

    test "says a 7d hold is in force, and when it lifts" do
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: uniq("ws")}, held_7d(stale_info()))

      alert = only_alert(:quota_snapshot_stale)
      assert alert.detail =~ "7d hold: IN FORCE for default (7d quota 96% ≥ 90%)"
      assert alert.detail =~ "lifts when the 7d window resets at 2026-09-20T00:00:00Z (in 2d 23h)"
    end

    test "a blind spell of a day or more reads in days" do
      CoordinatorNotifier.quota_snapshot_stale(
        %{workspace_id: uniq("ws")},
        stale_info(%{age_seconds: 50 * 3_600 + 7 * 60})
      )

      assert only_alert(:quota_snapshot_stale).detail =~ "blind for 2d 2h:"
    end

    test "says when no 7d hold is in force" do
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: uniq("ws")}, stale_info())

      alert = only_alert(:quota_snapshot_stale)
      assert alert.detail =~ "7d hold: none in force"
      assert alert.detail =~ "45%"
      refute alert.detail =~ "IN FORCE"
    end

    test "says a rolled 7d reading no longer binds, with or without a reset time" do
      rolled = %{
        label: "7d",
        utilization: 0.96,
        status: "allowed_warning",
        reset_at: ~U[2026-09-16 00:00:00Z],
        reset_in_seconds: 0,
        rolled?: true,
        hold: nil
      }

      CoordinatorNotifier.quota_snapshot_stale(
        %{workspace_id: uniq("ws")},
        stale_info(%{long_window: rolled})
      )

      assert only_alert(:quota_snapshot_stale).detail =~
               "7d hold: none in force — the last 7d reading is past its own reset " <>
                 "(2026-09-16T00:00:00Z)"

      CoordinatorNotifier.quota_snapshot_stale(
        %{workspace_id: uniq("ws")},
        stale_info(%{long_window: %{rolled | reset_at: nil, reset_in_seconds: nil}})
      )

      assert only_alert(:quota_snapshot_stale).detail =~
               "7d hold: none in force — the last 7d reading is over 7 days old"
    end

    test "is best-effort: an assessment it cannot format raises nothing and returns :ok" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   CoordinatorNotifier.quota_snapshot_stale(
                     %{workspace_id: uniq("ws")},
                     %{account_id: "acct-1"}
                   )
        end)

      assert log =~ "could not build the alert"
      assert Alerts.active() == []
    end

    test "says when the last reading showed the 5h cap reached in a window still open" do
      info = stale_info(%{cap_reached_until: ~U[2026-09-17 02:00:00Z]})
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: uniq("ws")}, info)

      alert = only_alert(:quota_snapshot_stale)
      assert alert.detail =~ "2026-09-17T02:00:00Z"
      assert alert.detail =~ "keeps being recorded as overage"
    end

    test "says the poll is succeeding when it is, but not carrying the 5h figure" do
      info = stale_info(%{last_poll_at: ~U[2026-09-17 19:30:00Z]})
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: uniq("ws")}, info)

      alert = only_alert(:quota_snapshot_stale)
      assert alert.detail =~ "last succeeded at 2026-09-17T19:30:00Z"
    end

    test "a repeat refreshes the account's one alert instead of stacking" do
      ws = uniq("ws")
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: ws}, stale_info())
      first = only_alert(:quota_snapshot_stale)

      CoordinatorNotifier.quota_snapshot_stale(
        %{workspace_id: ws},
        stale_info(%{age_seconds: 20 * 3_600})
      )

      alert = only_alert(:quota_snapshot_stale)
      assert alert.id == first.id
      assert alert.raise_count == 2
      assert alert.detail =~ "blind for 20h"
    end

    test "quota_snapshot_recovered clears every account not still stale" do
      ws = uniq("ws")
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: ws}, stale_info())

      CoordinatorNotifier.quota_snapshot_stale(
        %{workspace_id: ws},
        stale_info(%{account_id: "acct-2", account: "claude:other"})
      )

      assert :ok = CoordinatorNotifier.quota_snapshot_recovered(["acct-2"])

      assert [%{key: "claude:acct-2"}] = Alerts.active(kind: :quota_snapshot_stale)
    end

    test "a later stale episode opens a new alert" do
      ws = uniq("ws")
      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: ws}, stale_info())
      first = only_alert(:quota_snapshot_stale)

      CoordinatorNotifier.quota_snapshot_recovered([])
      assert Ash.get!(Arbiter.Alerts.SystemAlert, first.id).cleared_at
      assert Alerts.active(kind: :quota_snapshot_stale) == []

      CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: ws}, stale_info())
      second = only_alert(:quota_snapshot_stale)
      refute second.id == first.id
    end

    test "with no workspace raises nothing" do
      assert :ok = CoordinatorNotifier.quota_snapshot_stale(%{workspace_id: nil}, stale_info())
      assert Alerts.active() == []
    end
  end
end
