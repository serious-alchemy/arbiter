defmodule Arbiter.Tasks.SlotGateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.SlotGate

  # A worker snapshot in one of the run's states. `:question` and
  # `:review_gate` are a `:waiting` run and what it waits on; `:finished` is
  # a run that is over (the author opened its PR, or it failed).
  defp worker(task_id, state, attrs \\ %{}) do
    Map.merge(
      Map.merge(
        %{task_id: task_id, registry_key: task_id, role: nil, meta: %{}},
        run_fields(state)
      ),
      attrs
    )
  end

  defp run_fields(:question), do: %{state: :waiting, waiting_on: :question, outcome: nil}
  defp run_fields(:review_gate), do: %{state: :waiting, waiting_on: :review_gate, outcome: nil}
  defp run_fields(:finished), do: %{state: :finished, waiting_on: nil, outcome: :succeeded}
  defp run_fields(state), do: %{state: state, waiting_on: nil, outcome: nil}

  @run_states [:starting, :working, :question, :review_gate, :finished]

  describe "occupies_slot?/1" do
    test "a live agent session occupies a slot whatever the record's state says" do
      for state <- @run_states do
        assert SlotGate.occupies_slot?(worker("bd-1", state, %{agent_live: true})),
               "#{state} with a live agent should hold a slot"
      end
    end

    test "a record with no live agent occupies no slot, including one waiting on a question" do
      for state <- @run_states do
        refute SlotGate.occupies_slot?(worker("bd-1", state, %{agent_live: false})),
               "#{state} without a live agent should hold no slot"
      end
    end

    test "every role counts, not just the author" do
      for role <- [nil, :reviewer, :implementer, :fix_pass, :conflict_resolver] do
        assert SlotGate.occupies_slot?(worker("bd-1", :working, %{role: role, agent_live: true})),
               "#{inspect(role)} with a live agent should hold a slot"
      end
    end

    test "unknown liveness fails closed: only a run that is over reads as free" do
      # A caller that cannot answer the liveness question (no :agent_live key)
      # must not have its workers silently counted as free. Only `:finished`
      # proves no agent — in any role.
      for state <- [:starting, :working, :question, :review_gate],
          role <- [nil, :reviewer, :implementer, :fix_pass] do
        assert SlotGate.occupies_slot?(worker("bd-1", state, %{role: role})),
               "#{state} / #{inspect(role)} of unknown liveness should count"
      end

      refute SlotGate.occupies_slot?(worker("bd-1", :finished))
    end
  end

  describe "occupied/1" do
    test "counts live agents across every role" do
      workers = [
        worker("bd-1", :finished, %{agent_live: false}),
        worker("bd-1", :working, %{role: :fix_pass, agent_live: true}),
        worker("bd-2#review", :working, %{role: :reviewer, agent_live: true}),
        worker("bd-2", :review_gate, %{agent_live: false}),
        worker("bd-3", :question, %{agent_live: false})
      ]

      assert SlotGate.occupied(workers) == 2
    end
  end

  describe "free/2" do
    test "never reports a negative number of slots" do
      workers = for i <- 1..5, do: worker("bd-#{i}", :working, %{agent_live: true})
      assert SlotGate.free(2, workers) == 0
      assert SlotGate.free(8, workers) == 3
    end
  end

  # bd-asxw4e: holders are tickets In progress — see `SlotGateTaskTest`. The
  # worker rows, whatever their phase, name none.
  describe "slot_holders/1" do
    test "names each :active ticket once, and no worker row" do
      tickets = [
        %{id: "bd-a", state: :active},
        %{id: "bd-b", state: :merging},
        %{id: "bd-a", state: :active}
      ]

      assert SlotGate.slot_holders(tickets) == ["bd-a"]

      workers = [%{task_id: "bd-c", state: :working, phase: :implementing}]
      assert SlotGate.slot_holders(workers) == []
    end
  end
end
