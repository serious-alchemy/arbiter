defmodule Arbiter.Nodes.RefusalTest do
  @moduledoc """
  K12 (A3): a node's `refuse{no_capacity | unschedulable | image_unavailable | bad_spec}` is a
  **hold**, not a failure: the dispatch returns `{:error, {:no_node_capacity, info}}`, the
  ticket goes back to Ready (so the slot it took is free), the run is `interrupted` and no
  resume attempt is consumed.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.Nodes.{Placement, Refusal}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  require Ash.Query

  @reasons ~w(no_capacity unschedulable image_unavailable bad_spec)

  describe "from_start_error/1" do
    test "recognises a refusal as the spawn error carries it" do
      for reason <- @reasons do
        error = {:claude_start_failed, {:remote_placement_failed, {:refused, reason, "why"}}}
        assert {:ok, %{reason: ^reason, detail: "why"}} = Refusal.from_start_error(error)
      end
    end

    test "a refusal with no detail still parses" do
      error = {:claude_start_failed, {:remote_placement_failed, {:refused, "bad_spec", nil}}}
      assert {:ok, %{reason: "bad_spec", detail: nil}} = Refusal.from_start_error(error)
    end

    test "any other start failure is not a refusal (those still fail the dispatch)" do
      for error <- [
            {:claude_start_failed, {:remote_placement_failed, :prepare_timeout}},
            {:claude_start_failed, {:remote_placement_failed, :not_connected}},
            {:claude_start_failed, :enoent},
            {:transition_failed, :x},
            :timeout
          ] do
        assert Refusal.from_start_error(error) == :error
      end
    end

    test "an unknown refuse reason is not trusted as one" do
      error = {:claude_start_failed, {:remote_placement_failed, {:refused, "bad_idea", nil}}}
      assert Refusal.from_start_error(error) == :error
    end
  end

  describe "info/3" do
    test "is a no_node_capacity info with an operator-facing message naming the reason" do
      for reason <- @reasons do
        info = Refusal.info("bd-1", "edge-1", %{reason: reason, detail: "quota exceeded"})
        assert info.task_id == "bd-1"
        assert info.node == "edge-1"
        assert info.refused == reason
        assert info.message =~ "held"
        assert info.message =~ "edge-1"
        assert info.message =~ "quota exceeded"
        assert Placement.refusal_message(info) == info.message
      end
    end
  end

  describe "hold/4" do
    setup do
      {:ok, ws} = Ash.create(Workspace, %{name: "refusal-ws", prefix: "rf"})
      {:ok, task} = Ash.create(Issue, %{title: "refused", workspace_id: ws.id})
      put_state!(task, :active)
      {:ok, worker} = Worker.start(task_id: task.id, repo: "r")
      on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker, :normal) end)
      %{task: task, worker: worker}
    end

    for reason <- @reasons do
      test "refuse{#{reason}}: a hold, run interrupted, no attempt consumed, ticket back to Ready",
           %{task: task, worker: worker} do
        refusal = %{reason: unquote(reason), detail: "d"}

        assert {:error, {:no_node_capacity, info}} =
                 Refusal.hold(task, worker, "edge-1", refusal)

        assert info.refused == unquote(reason)

        snap = Worker.state(worker)
        assert %{state: :finished, outcome: :interrupted} = snap
        assert snap.meta.stop_reason.category == :placement_refused
        assert Map.get(snap.meta, :resume_attempts, 0) == 0

        run = Ash.get!(Run, snap.run_id)
        assert run.outcome == :interrupted
        assert run.stop_category == "placement_refused"

        # the ticket gives its slot back: Ready, not failed, not escalated
        assert %{state: :queued} = Ash.get!(Issue, task.id)

        assert [] =
                 Message
                 |> Ash.Query.filter(task_ref == ^task.id and kind == :escalation)
                 |> Ash.read!()
      end
    end

    test "the reserved placement slot is released by the hold", %{task: task, worker: worker} do
      :ok = Placement.reserve(task.id, "node-1")
      assert Enum.any?(Placement.reservations(), &(&1.task_id == task.id))

      {:error, {:no_node_capacity, _}} =
        Refusal.hold(task, worker, "edge-1", %{reason: "no_capacity", detail: nil})

      refute Enum.any?(Placement.reservations(), &(&1.task_id == task.id))
    end
  end
end
