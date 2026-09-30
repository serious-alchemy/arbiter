defmodule Arbiter.Tasks.AttentionSweepBootTest do
  @moduledoc """
  bd-9jipdh: a server boot must not re-raise `attention raised` for tickets
  that were already awaiting verification, a ticket that newly reaches
  verification still raises exactly once, and a verification wait is exempt
  from the coordinator→operator time limit.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Tasks.{AttentionSweep, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "sweepboot-#{System.unique_integer([:positive])}",
        prefix: "sb"
      })

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))
    %{ws: ws}
  end

  # A ticket awaiting verification whose attention is derived, not stored —
  # how the live ones read (the sweep, not a transition, is what sees them).
  defp verifying!(ws, title) do
    task = park_verifying!(ws, title)
    {:ok, task} = Ash.update(task, %{}, action: :clear_attention)
    assert is_nil(task.attention_cause)
    task
  end

  # Through the real transition, which stores the cause and raises it once.
  defp park_verifying!(ws, title) do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id, issue_type: :feature})
    put_state!(task, :verifying)
  end

  defp drain_events do
    receive do
      {:event, _} -> drain_events()
    after
      0 -> :ok
    end
  end

  defp sweep_now(pid) do
    send(pid, :sweep)
    _ = :sys.get_state(pid)
  end

  defp start_sweep(id) do
    start_supervised!(
      {AttentionSweep, name: nil, enabled: false, primary?: fn -> true end},
      id: id
    )
  end

  test "a boot with tickets already awaiting verification raises nothing", %{ws: ws} do
    for n <- 1..3, do: verifying!(ws, "already verifying #{n}")

    # Reaching verification raised these once, back when they got there.
    drain_events()

    # A fresh process is a server boot: its first-seen clock is empty.
    pid = start_sweep(:boot)
    sweep_now(pid)
    sweep_now(pid)

    refute_receive {:event, %{topic: "inbox", kind: "attention", event: "raised"}}, 100
  end

  test "a ticket that newly reaches verification raises exactly one event", %{ws: ws} do
    pid = start_sweep(:newly)
    sweep_now(pid)

    task = park_verifying!(ws, "newly verifying")
    sweep_now(pid)
    sweep_now(pid)

    assert_receive {:event,
                    %{
                      topic: "inbox",
                      kind: "attention",
                      event: "raised",
                      task_id: id,
                      cause: "awaiting_verification"
                    }},
                   1_000

    assert id == task.id

    refute_receive {:event, %{topic: "inbox", kind: "attention", event: "raised", task_id: ^id}},
                   100
  end

  test "an awaiting_verification item is never promoted by the time limit", %{ws: ws} do
    task = verifying!(ws, "waits for a restart")
    long_after = DateTime.add(DateTime.utc_now(), 100 * 3600, :second)

    assert %{promoted: []} = AttentionSweep.run(now: long_after, workspace_id: ws.id)
    assert Ash.get!(Issue, task.id).attention_owner == nil
  end
end
