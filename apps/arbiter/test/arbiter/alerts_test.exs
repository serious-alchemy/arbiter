defmodule Arbiter.AlertsTest do
  @moduledoc """
  bd-7gt8rm (ticket lifecycle 8/13): a system alert is a record with no
  ticket — kind, detail, `raised_at`, `cleared_at` and an owner — that one
  active row per `(kind, key)` represents, and that clears when its
  condition does.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.Alerts.SystemAlert

  require Ash.Query

  @ws "ws-alerts-test"

  defp key, do: "key-#{System.unique_integer([:positive])}"

  defp raise_one(kind, key, detail, extra \\ %{}) do
    Alerts.raise_alert(
      Map.merge(
        %{kind: kind, key: key, workspace_id: @ws, subject: "subject #{detail}", detail: detail},
        extra
      )
    )
  end

  defp rows(kind, key) do
    SystemAlert
    |> Ash.Query.filter(kind == ^kind and key == ^key)
    |> Ash.read!()
  end

  describe "raise_alert/1" do
    test "records kind, detail, raised_at, an operator owner and no cleared_at" do
      key = key()
      assert {:ok, alert} = raise_one(:quota_poll_failing, key, "3 cycles")

      assert alert.kind == :quota_poll_failing
      assert alert.key == key
      assert alert.workspace_id == @ws
      assert alert.detail == "3 cycles"
      assert alert.owner == :operator
      assert %DateTime{} = alert.raised_at
      assert alert.last_raised_at == alert.raised_at
      assert alert.raise_count == 1
      assert is_nil(alert.cleared_at)
    end

    test "re-raising an active alert updates it instead of adding a second row" do
      key = key()
      {:ok, first} = raise_one(:overage_alert, key, "$10")
      {:ok, second} = raise_one(:overage_alert, key, "$20")

      assert second.id == first.id
      assert second.detail == "$20"
      assert second.subject == "subject $20"
      assert second.raise_count == 2
      assert second.raised_at == first.raised_at
      assert DateTime.compare(second.last_raised_at, first.last_raised_at) == :gt

      assert [%{id: id}] = rows(:overage_alert, key)
      assert id == first.id
    end

    test "the same key under another kind is a different alert" do
      key = key()
      {:ok, a} = raise_one(:overage_alert, key, "a")
      {:ok, b} = raise_one(:budget_exceeded, key, "b")
      refute a.id == b.id
    end

    test "a raise after a clear opens a fresh episode" do
      key = key()
      {:ok, first} = raise_one(:quota_poll_failing, key, "first")
      assert {:ok, [_]} = Alerts.clear(:quota_poll_failing, key)
      {:ok, second} = raise_one(:quota_poll_failing, key, "second")

      refute second.id == first.id
      assert second.raise_count == 1
      assert [_cleared, _active] = rows(:quota_poll_failing, key)
    end

    test "refuses a kind that is not a system alert" do
      assert {:error, _} = raise_one(:merge_blocked, key(), "nope")
    end
  end

  describe "clear/2" do
    test "stamps cleared_at on the active alert" do
      key = key()
      {:ok, alert} = raise_one(:credential_expired, key, "expired")

      assert {:ok, [cleared]} = Alerts.clear(:credential_expired, key)
      assert cleared.id == alert.id
      assert %DateTime{} = cleared.cleared_at
      assert Alerts.active(kind: :credential_expired) |> Enum.all?(&(&1.key != key))
    end

    test "is a no-op when nothing is active" do
      assert {:ok, []} = Alerts.clear(:credential_expired, key())
    end
  end

  describe "clear_except/2" do
    test "clears every active alert of a kind whose key is not kept" do
      keep = key()
      drop = key()
      {:ok, _} = raise_one(:budget_exceeded, keep, "keep")
      {:ok, _} = raise_one(:budget_exceeded, drop, "drop")

      assert {:ok, [cleared]} = Alerts.clear_except(:budget_exceeded, [keep])
      assert cleared.key == drop

      active_keys = Enum.map(Alerts.active(kind: :budget_exceeded), & &1.key)
      assert keep in active_keys
      refute drop in active_keys
    end
  end

  describe "active/1" do
    test "lists only uncleared alerts, oldest first, filterable by workspace and kind" do
      k1 = key()
      k2 = key()
      k3 = key()
      {:ok, a1} = raise_one(:quota_poll_failing, k1, "one")
      {:ok, a2} = raise_one(:overage_alert, k2, "two", %{workspace_id: "ws-other"})
      {:ok, _} = raise_one(:budget_exceeded, k3, "three")
      {:ok, _} = Alerts.clear(:budget_exceeded, k3)

      assert Enum.map(Alerts.active(), & &1.id) == [a1.id, a2.id]

      assert [%{id: id}] = Alerts.active(workspace_id: "ws-other")
      assert id == a2.id
      assert Enum.map(Alerts.active(kind: :quota_poll_failing), & &1.id) == [a1.id]
    end
  end

  describe "announcements" do
    test "opening and clearing are broadcast on the workspace's inbox topic; a refresh is not" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(@ws))
      key = key()

      {:ok, _} = raise_one(:quota_poll_failing, key, "down")
      assert_receive {:event, %{topic: "inbox", kind: "alert", event: "raised", key: ^key}}

      {:ok, _} = raise_one(:quota_poll_failing, key, "still down")
      refute_receive {:event, %{kind: "alert", key: ^key}}, 50

      {:ok, _} = Alerts.clear(:quota_poll_failing, key)
      assert_receive {:event, %{topic: "inbox", kind: "alert", event: "cleared", key: ^key}}
    end
  end

  describe "serialize/1" do
    test "renders the JSON shape the API and MCP return" do
      {:ok, alert} = raise_one(:overage_alert, key(), "$12")

      assert %{
               id: _,
               kind: "overage_alert",
               owner: "operator",
               detail: "$12",
               raised_at: raised_at,
               cleared_at: nil,
               raise_count: 1
             } = Alerts.serialize(alert)

      assert is_binary(raised_at)
    end
  end
end
