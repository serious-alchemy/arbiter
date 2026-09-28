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

  describe "occupies_slot?/2 on the :agents basis" do
    test "a live agent session occupies a slot whatever the record's state says" do
      for state <- @run_states do
        assert SlotGate.occupies_slot?(worker("bd-1", state, %{agent_live: true}), :agents),
               "#{state} with a live agent should hold a slot"
      end
    end

    test "a record with no live agent occupies no slot, including one waiting on a question" do
      for state <- @run_states do
        refute SlotGate.occupies_slot?(worker("bd-1", state, %{agent_live: false}), :agents),
               "#{state} without a live agent should hold no slot"
      end
    end

    test "every role counts, not just the author" do
      for role <- [nil, :reviewer, :implementer, :fix_pass, :conflict_resolver] do
        assert SlotGate.occupies_slot?(
                 worker("bd-1", :working, %{role: role, agent_live: true}),
                 :agents
               ),
               "#{inspect(role)} with a live agent should hold a slot"
      end
    end

    test "unknown liveness degrades to the run-state rule rather than to 'free'" do
      # A caller that cannot answer the liveness question (no :agent_live key)
      # must not have its workers silently counted as free — that would
      # over-dispatch. It falls back to the pre-bd-aw2cyt run-state test.
      assert SlotGate.occupies_slot?(worker("bd-1", :working), :agents)
      refute SlotGate.occupies_slot?(worker("bd-1", :finished), :agents)
    end
  end

  describe "occupies_slot?/2 on the :issues basis" do
    test "reproduces the pre-bd-aw2cyt rule: author records in a live run state" do
      for state <- [:starting, :working, :question, :review_gate] do
        assert SlotGate.occupies_slot?(worker("bd-1", state, %{agent_live: false}), :issues),
               "#{state} should hold a slot on the :issues basis"
      end

      refute SlotGate.occupies_slot?(
               worker("bd-1", :finished, %{agent_live: true}),
               :issues
             )
    end

    test "a reviewer / implementer pass folds into its author and holds nothing of its own" do
      refute SlotGate.occupies_slot?(
               worker("bd-1#review", :working, %{role: :reviewer, agent_live: true}),
               :issues
             )

      refute SlotGate.occupies_slot?(
               worker("bd-1#review#impl1", :working, %{role: :implementer, agent_live: true}),
               :issues
             )
    end
  end

  describe "slot_states/0" do
    test "is every live run state" do
      assert SlotGate.slot_states() == [:starting, :working, :waiting]
    end
  end

  describe "occupied/2" do
    test "counts live agents across every role" do
      workers = [
        worker("bd-1", :finished, %{agent_live: false}),
        worker("bd-1", :working, %{role: :fix_pass, agent_live: true}),
        worker("bd-2#review", :working, %{role: :reviewer, agent_live: true}),
        worker("bd-2", :review_gate, %{agent_live: false}),
        worker("bd-3", :question, %{agent_live: false})
      ]

      assert SlotGate.occupied(workers, :agents) == 2
      # The old rule saw three live author records instead (the fix pass
      # shares its author's id; the finished run and the reviewer hold none).
      assert SlotGate.occupied(workers, :issues) == 3
    end
  end

  describe "free/3" do
    test "never reports a negative number of slots" do
      workers = for i <- 1..5, do: worker("bd-#{i}", :working, %{agent_live: true})
      assert SlotGate.free(2, workers, :agents) == 0
      assert SlotGate.free(8, workers, :agents) == 3
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

  describe "basis/0" do
    test "defaults to :agents" do
      assert SlotGate.basis() == :agents
    end

    test "honours the conductor.slot_basis application setting" do
      prev = Application.get_env(:arbiter, :conductor_slot_basis)
      on_exit(fn -> restore_env(prev) end)

      Application.put_env(:arbiter, :conductor_slot_basis, :issues)
      assert SlotGate.basis() == :issues

      Application.put_env(:arbiter, :conductor_slot_basis, "issues")
      assert SlotGate.basis() == :issues

      # A typo'd value is not config: fall back to the default rather than
      # silently adopting something nobody asked for.
      Application.put_env(:arbiter, :conductor_slot_basis, "nonsense")
      assert SlotGate.basis() == :agents
    end
  end

  defp restore_env(nil), do: Application.delete_env(:arbiter, :conductor_slot_basis)
  defp restore_env(v), do: Application.put_env(:arbiter, :conductor_slot_basis, v)
end
