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
end
