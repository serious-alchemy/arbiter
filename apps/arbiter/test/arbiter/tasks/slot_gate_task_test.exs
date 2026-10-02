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

    test "a row with no stored state holds none" do
      refute SlotGate.holds_slot?(%{id: "l"})
    end

    # bd-cut6uv: a ReviewGate holding its reviewer back until CI is green has no
    # agent live — it is waiting on a machine, like a Merging PR waiting on CI.
    test "an :active ticket whose ReviewGate is waiting on CI holds no slot" do
      marker =
        Arbiter.Worker.ReviewCi.marker("a1b2c3d4e5f6", 1, %{interval_ms: 60_000, max_polls: 30})

      waiting = ticket("w", :active, %{review_gate_state: %{"ci_wait" => marker}})

      refute SlotGate.holds_slot?(waiting)
      assert SlotGate.slots_used([waiting, ticket("a", :active)]) == 1
      assert SlotGate.slot_holders([waiting, ticket("a", :active)]) == ["a"]
    end

    test "a cleared, expired or malformed marker holds the slot as usual" do
      cleared = ticket("c", :active, %{review_gate_state: %{"ci_wait" => nil}})
      assert SlotGate.holds_slot?(cleared)

      expired =
        ticket("e", :active, %{
          review_gate_state: %{
            "ci_wait" => %{
              "sha" => "a1b2c3d4e5f6",
              "expires_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -60, :second))
            }
          }
        })

      assert SlotGate.holds_slot?(expired)
      assert SlotGate.holds_slot?(ticket("m", :active, %{review_gate_state: %{"ci_wait" => %{}}}))
      assert SlotGate.holds_slot?(ticket("n", :active, %{review_gate_state: nil}))
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
