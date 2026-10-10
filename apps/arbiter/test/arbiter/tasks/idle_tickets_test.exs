defmodule Arbiter.Tasks.IdleTicketsTest do
  @moduledoc """
  bd-3fbj83: an `:active` ticket with no live run and no queued or held
  follow-up is orphaned and holds no slot.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.IdleTickets
  alias Arbiter.Tasks.SlotGate

  @now ~U[2026-10-10 12:00:00Z]
  @old ~U[2026-10-10 10:00:00Z]

  defp ticket(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        state: :active,
        issue_type: :feature,
        workspace_id: "ws-1",
        updated_at: @old,
        review_gate_state: nil
      },
      attrs
    )
  end

  defp ids(tickets, opts \\ []),
    do: IdleTickets.ids(tickets, Keyword.merge([now: @now, workers: []], opts))

  test "an orphaned active ticket is idle and drops out of the slot holders" do
    orphan = ticket("orphan")
    other = ticket("other")

    assert ids([orphan, other], workers: [%{task_id: "other"}]) == ["orphan"]

    assert SlotGate.slot_holders([orphan, other], idle_ids: ["orphan"]) == ["other"]
    assert SlotGate.slots_used([orphan, other], idle_ids: ["orphan"]) == 1
    assert SlotGate.slot_holders([orphan, other]) == ["orphan", "other"]
  end

  test "a live worker, including a reviewer round, keeps the ticket out of the idle set" do
    assert ids([ticket("a"), ticket("b")], workers: [%{task_id: "a"}, %{task_id: "b#review"}]) ==
             []
  end

  test "a queued or held follow-up is not idle" do
    assert ids([ticket("a")], queued_ids: ["a"]) == []
  end

  test "durable markers keep a ticket out of the idle set" do
    pass = %{"pass" => %{"phase" => "fix", "round" => 1, "held" => true}}
    held = %{"held_resume" => %{"kind" => "resume"}}
    wait = %{"ci_wait" => %{"sha" => "abc", "expires_at" => "2026-10-10T13:00:00Z"}}

    tickets = [
      ticket("p", %{review_gate_state: pass}),
      ticket("h", %{review_gate_state: held}),
      ticket("c", %{review_gate_state: wait})
    ]

    assert ids(tickets) == []
  end

  test "a recently changed ticket is inside the dispatch grace window" do
    assert ids([ticket("fresh", %{updated_at: DateTime.add(@now, -30)})]) == []
    assert ids([ticket("nil-stamp", %{updated_at: nil})]) == []
  end

  test "non-active tickets and epics are never idle" do
    assert ids([ticket("m", %{state: :merging}), ticket("e", %{issue_type: :epic})]) == []
  end
end
