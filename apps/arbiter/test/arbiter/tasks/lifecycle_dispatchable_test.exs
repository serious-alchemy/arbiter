defmodule Arbiter.Tasks.LifecycleDispatchableTest do
  @moduledoc """
  bd-asxw4e (ticket lifecycle 3/13): the one dispatch-eligibility predicate.
  A ticket may be dispatched when its column is `:ready` and the scheduler
  holds nothing against it — the question `Arbiter.Board.Scheduler.plan/1`
  and `Arbiter.Worker.Dispatch` both ask.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Lifecycle

  defp ticket(state, attrs \\ %{}),
    do: Map.merge(%{id: "bd-1", state: state, issue_type: :feature}, attrs)

  describe "the column" do
    test "a :ready ticket with nothing held against it is dispatchable" do
      assert Lifecycle.dispatchable(ticket(:queued), %{}) == :ok
      assert Lifecycle.dispatchable?(ticket(:queued), %{})
    end

    test "a :backlog ticket is held in Backlog" do
      assert Lifecycle.dispatchable(ticket(:backlog), %{}) == {:held, {:column, :backlog}}
      refute Lifecycle.dispatchable?(ticket(:backlog), %{})
    end

    test "a queued ticket with open blockers is held, naming them" do
      assert Lifecycle.dispatchable(ticket(:queued), %{blocked_by: ["bd-9", "bd-3"]}) ==
               {:held, {:blocked_by, ["bd-3", "bd-9"]}}
    end

    test "a ticket already past Ready is held in its column" do
      for {state, column} <- [
            active: :in_progress,
            merging: :merging,
            verifying: :verifying,
            closed: :closed
          ] do
        assert Lifecycle.dispatchable(ticket(state), %{}) == {:held, {:column, column}}
      end
    end

    test "the column outranks every scheduler hold" do
      ctx = %{paused: true, quota: {:hold, "quota exhausted"}, slots_free: 0}
      assert Lifecycle.dispatchable(ticket(:backlog), ctx) == {:held, {:column, :backlog}}
    end
  end

  describe "scheduler holds, in precedence order" do
    test "a conflicts_with counterpart in flight" do
      ctx = %{conflicts_with: ["bd-7"], claimed: %{"bd-7" => "running"}, paused: true}
      assert Lifecycle.dispatchable(ticket(:queued), ctx) == {:held, {:conflicts_with, "bd-7"}}
    end

    test "a file overlap with in-flight work" do
      ctx = %{
        scope: MapSet.new(["lib/a.ex"]),
        in_flight: [{"bd-7", MapSet.new(["lib/a.ex", "lib/b.ex"])}],
        paused: true
      }

      assert Lifecycle.dispatchable(ticket(:queued), ctx) ==
               {:held, {:file_overlap, ["lib/a.ex"], "bd-7"}}
    end

    test "paused, then a quota hold, then no free slot" do
      assert Lifecycle.dispatchable(ticket(:queued), %{paused: true, slots_free: 0}) ==
               {:held, :paused}

      assert Lifecycle.dispatchable(ticket(:queued), %{
               quota: {:hold, "quota exhausted"},
               slots_free: 0
             }) ==
               {:held, {:quota, "quota exhausted"}}

      assert Lifecycle.dispatchable(ticket(:queued), %{slots_free: 0}) == {:held, :no_slot}
      assert Lifecycle.dispatchable(ticket(:queued), %{slots_free: 1}) == :ok
    end

    test "a hold the caller did not ask about is not held" do
      # No `:slots_free` key: the caller is not asking about slots.
      assert Lifecycle.dispatchable(ticket(:queued), %{quota: :ok}) == :ok
    end
  end

  describe "describe_hold/1" do
    test "names the reason an operator reads" do
      assert Lifecycle.describe_hold({:column, :backlog}) == "in Backlog"
      assert Lifecycle.describe_hold({:blocked_by, ["bd-3", "bd-9"]}) == "blocked by bd-3, bd-9"
      assert Lifecycle.describe_hold({:column, :in_progress}) == "already In progress"
      assert Lifecycle.describe_hold(:no_slot) == "no free worker slot"
    end
  end

  describe "a provider-constraint hold (bd-13pqcp)" do
    test "is the ticket's own hold, ahead of the board-wide ones" do
      ctx = %{provider_constraint: {:hold, "exclude gemini: none free"}, paused: true}

      assert Lifecycle.dispatchable(ticket(:queued), ctx) ==
               {:held, {:provider_constraint, "exclude gemini: none free"}}

      assert Lifecycle.describe_hold({:provider_constraint, "require claude"}) ==
               "provider constraint (require claude)"
    end

    test ":ok, or a ctx that does not ask, is not held" do
      assert Lifecycle.dispatchable(ticket(:queued), %{provider_constraint: :ok}) == :ok
      assert Lifecycle.dispatchable(ticket(:queued), %{}) == :ok
    end
  end
end
