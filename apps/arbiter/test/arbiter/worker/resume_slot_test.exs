defmodule Arbiter.Worker.ResumeSlotTest do
  @moduledoc """
  bd-92mx1m / bd-asxw4e: a resume is gated on whether the ticket **currently
  holds a slot**, not on who is resuming it — and a ticket holds a slot
  exactly while it is In progress (`:active`), the same rule the board counts
  by (`Arbiter.Tasks.SlotGate`). An `:active` ticket passes through uncapped
  (the #1969/#1995 no-deadlock guarantee); any other re-acquires a slot like a
  new admission.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Events.Record
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.ResumeSlot

  require Ash.Query

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "resume-slot-#{System.unique_integer([:positive])}",
        prefix: "rsl#{System.unique_integer([:positive])}"
      })

    {:ok, a} = Ash.create(Issue, %{title: "task A", workspace_id: ws.id})
    {:ok, b} = Ash.create(Issue, %{title: "task B", workspace_id: ws.id})
    %{ws: ws, a: a, b: b}
  end

  # A ticket in `state`, as the gate would read it — the struct is never written.
  defp in_state(ticket, state), do: %{ticket | state: state}

  describe "an :active ticket holds its slot" do
    test "resuming it needs no new slot, at a full cap, whoever resumes it", %{a: a, b: b} do
      a = in_state(a, :active)
      tickets = [a, in_state(b, :active)]

      for origin <- [:human, :automatic] do
        assert {:ok, :held} = ResumeSlot.admit(a, origin: origin, tickets: tickets, cap: 1)
      end
    end

    # The fix-round and reboot shapes: whatever happened to the worker (failed
    # mid hand-off, cut off by a restart, parked on a human), the ticket never
    # left In progress, so it never gave its slot up.
    test "whatever its worker did — no worker rows are read at all", %{a: a, b: b} do
      a = in_state(a, :active)

      assert {:ok, :held} =
               ResumeSlot.admit(a, origin: :automatic, tickets: [in_state(b, :active)], cap: 1)
    end
  end

  describe "orphaned tickets hold no slot (bd-3fbj83)" do
    test "an idle ticket is not counted against the workspace cap", %{a: a, b: b} do
      c = %{in_state(b, :active) | id: "orphan-1"}
      tickets = [in_state(a, :queued), in_state(b, :active), c]

      assert {:error, {:slot_cap_full, %{holders: holders}}} =
               ResumeSlot.admit(in_state(a, :queued), tickets: tickets, cap: 2)

      assert "orphan-1" in holders

      assert {:ok, :acquired} =
               ResumeSlot.admit(in_state(a, :queued),
                 tickets: tickets,
                 cap: 2,
                 idle_ids: ["orphan-1"]
               )
    end
  end

  describe "a ticket not In progress must acquire a slot" do
    test "resuming a :queued ticket needs a slot", %{a: a, b: b} do
      a = in_state(a, :queued)
      tickets = [a, in_state(b, :active)]

      assert {:ok, :acquired} = ResumeSlot.admit(a, tickets: tickets, cap: 2)
      assert {:error, {:slot_cap_full, _}} = ResumeSlot.admit(a, tickets: tickets, cap: 1)
    end

    test "so does a :merging one — an open PR holds no slot", %{a: a, b: b} do
      a = in_state(a, :merging)

      assert {:defer, %{holders: [holder]}} =
               ResumeSlot.admit(a,
                 origin: :automatic,
                 tickets: [a, in_state(b, :active)],
                 cap: 1
               )

      assert holder == b.id
    end

    test "a human resume at a full cap is refused, naming the cap and the holders", %{
      a: a,
      b: b
    } do
      a = in_state(a, :queued)

      assert {:error, {:slot_cap_full, info}} =
               ResumeSlot.admit(a, origin: :human, tickets: [a, in_state(b, :active)], cap: 1)

      assert info.cap == 1
      assert info.holders == [b.id]
      assert info.task_id == a.id

      message = ResumeSlot.refusal_message(info)
      assert message =~ "1"
      assert message =~ b.id
      assert message =~ a.id
      assert message =~ "force"
    end

    test "the default origin is human — refuse, never bypass", %{a: a, b: b} do
      a = in_state(a, :queued)

      assert {:error, {:slot_cap_full, _}} =
               ResumeSlot.admit(a, tickets: [in_state(b, :active)], cap: 1)
    end

    test "an automatic resume at a full cap is deferred", %{a: a, b: b} do
      a = in_state(a, :verifying)

      assert {:defer, %{cap: 1, holders: [holder]}} =
               ResumeSlot.admit(a, origin: :automatic, tickets: [in_state(b, :active)], cap: 1)

      assert holder == b.id
    end

    test "force overrides the cap and records the override", %{ws: ws, a: a, b: b} do
      a = in_state(a, :queued)

      assert {:ok, :forced} =
               ResumeSlot.admit(a,
                 origin: :human,
                 force: true,
                 actor: "coordinator",
                 tickets: [in_state(b, :active)],
                 cap: 1
               )

      [event] =
        Record
        |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
        |> Ash.read!()

      assert event.payload["task_id"] == a.id
      assert event.payload["cap"] == 1
      assert event.payload["holders"] == [b.id]
      assert event.payload["actor"] == "coordinator"
    end

    test "force with a free slot is a plain admission, not an override", %{ws: ws, a: a} do
      assert {:ok, :acquired} = ResumeSlot.admit(a, force: true, tickets: [], cap: 1)

      assert [] =
               Record
               |> Ash.Query.filter(workspace_id == ^ws.id and topic == "slot_cap_override")
               |> Ash.read!()
    end

    test "a resume the scheduler already admitted is not re-checked", %{a: a, b: b} do
      assert {:ok, :admitted} =
               ResumeSlot.admit(a,
                 origin: :automatic,
                 slot_admitted: true,
                 tickets: [in_state(b, :active)],
                 cap: 1
               )
    end
  end

  describe "reading the world" do
    setup do
      put_local_cap(1)
    end

    test "reads the tickets In progress and the configured cap when not handed them", %{
      a: a,
      b: b
    } do
      {:ok, b} = Issue.start_work(b)
      assert b.state == :active

      assert {:error, {:slot_cap_full, %{cap: 1, holders: holders}}} = ResumeSlot.admit(a)
      assert b.id in holders

      {:ok, a} = Issue.start_work(a)
      assert {:ok, :held} = ResumeSlot.admit(a)
    end
  end
end
