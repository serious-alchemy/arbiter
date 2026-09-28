defmodule Arbiter.Tasks.SlotGateTaskTest do
  @moduledoc """
  bd-asxw4e (ticket lifecycle 3/13): a slot is a ticket In progress. The
  dispatch cap counts exactly the tickets whose stored state is `:active` —
  whatever worker rows linger beside them. Merging and Verifying release the
  slot; a ticket between ReviewGate rounds is still `:active` and keeps it
  (the bd-45pwo1 guarantee).
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.SlotGate

  defp ticket(id, state, attrs \\ %{}) do
    Map.merge(%{id: id, state: state, issue_type: :feature, workspace_id: "ws-1"}, attrs)
  end

  describe "holds_slot?/1" do
    test "only an :active ticket holds a slot" do
      assert SlotGate.holds_slot?(ticket("a", :active))

      for state <- [:backlog, :queued, :merging, :verifying, :closed] do
        refute SlotGate.holds_slot?(ticket("a", state)), "#{state} must hold no slot"
      end
    end

    test "an epic never holds one, whatever its state says" do
      refute SlotGate.holds_slot?(ticket("e", :active, %{issue_type: :epic}))
    end

    test "a legacy row with no stored state is judged by the state its status implies" do
      assert SlotGate.holds_slot?(%{id: "l", status: :in_progress, pr_ref: nil})
      refute SlotGate.holds_slot?(%{id: "l", status: :in_progress, pr_ref: "https://pr/1"})
    end
  end

  describe "slots_used/1 and slot_holders/1" do
    test "a :merging ticket holds no slot, whatever worker rows linger" do
      # The worker list is not an input at all: a row lingering under the
      # open PR cannot put the ticket back in a slot.
      tickets = [ticket("m", :merging)]
      assert SlotGate.slots_used(tickets) == 0
      assert SlotGate.slot_holders(tickets) == []
    end

    test "an :active ticket between ReviewGate rounds with no live agent holds one slot" do
      assert SlotGate.slots_used([ticket("r", :active)]) == 1
    end

    test "a :verifying ticket holds none" do
      assert SlotGate.slots_used([ticket("v", :verifying)]) == 0
    end

    test "counts one slot per :active ticket and names them in order" do
      tickets = [
        ticket("a", :active),
        ticket("q", :queued),
        ticket("b", :active),
        ticket("m", :merging),
        ticket("c", :closed)
      ]

      assert SlotGate.slots_used(tickets) == 2
      assert SlotGate.slot_holders(tickets) == ["a", "b"]
    end
  end

  describe "slots_free/2" do
    test "never reports a negative number of slots" do
      tickets = for id <- ~w(a b c), do: ticket(id, :active)
      assert SlotGate.slots_free(2, tickets) == 0
      assert SlotGate.slots_free(4, tickets) == 1
    end
  end
end
