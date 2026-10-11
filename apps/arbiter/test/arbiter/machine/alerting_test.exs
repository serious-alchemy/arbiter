defmodule Arbiter.Machine.AlertingTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.Machine.Alerting
  alias Arbiter.Tasks.Workspace

  @moduletag :capture_log

  defp transition(from, to, machine \\ "oryx-#{System.unique_integer([:positive])}") do
    snapshot = %{
      level: to,
      temp_c: 96.0,
      reason: {:thermal, 96.0},
      reason_text: "thermal 96 °C",
      offered: 2
    }

    {machine, %{machine: machine, from: from, to: to, snapshot: snapshot}}
  end

  defp active(machine),
    do: Enum.filter(Alerts.active(kind: :machine_derate), &(&1.key == machine))

  setup do
    ws = Ash.create!(Workspace, %{name: "derate-#{System.unique_integer([:positive])}"})
    Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))
    {:ok, ws: ws}
  end

  test "entering hard derate raises an operator alert naming the machine and reason", %{ws: ws} do
    {machine, event} = transition(:soft, :hard)
    assert :ok = Alerting.transition(event, workspace_id: ws.id)

    assert [alert] = active(machine)
    assert alert.subject =~ machine
    assert alert.subject =~ "thermal 96"
    assert alert.workspace_id == ws.id
    assert_receive {:event, %{kind: "alert", event: "raised", alert_kind: "machine_derate"}}
  end

  test "leaving hard derate clears it and announces the clear", %{ws: ws} do
    {machine, enter} = transition(:none, :hard)
    :ok = Alerting.transition(enter, workspace_id: ws.id)
    assert [_] = active(machine)

    {^machine, leave} = transition(:hard, :soft, machine)
    :ok = Alerting.transition(leave, workspace_id: ws.id)
    assert active(machine) == []
    assert_receive {:event, %{kind: "alert", event: "cleared", alert_kind: "machine_derate"}}
  end

  test "soft derate transitions alert nothing", %{ws: ws} do
    {machine, enter} = transition(:none, :soft)
    :ok = Alerting.transition(enter, workspace_id: ws.id)
    {^machine, leave} = transition(:soft, :none, machine)
    :ok = Alerting.transition(leave, workspace_id: ws.id)
    assert active(machine) == []
    refute_receive {:event, %{kind: "alert"}}, 20
  end

  test "with no workspace to announce on it is a no-op, not a crash" do
    {machine, event} = transition(:none, :hard)
    assert :ok = Alerting.transition(event, workspace_id: nil)
    assert active(machine) == []
  end
end
