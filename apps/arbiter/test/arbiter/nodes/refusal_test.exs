defmodule Arbiter.Nodes.RefusalTest do
  @moduledoc """
  K12 (A3): a node's `refuse{no_capacity | unschedulable | image_unavailable | bad_spec |
  service_not_ready}` is a **hold**, not a failure: the dispatch returns `{:error, {:no_node_capacity, info}}`, the
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

  # K14: `service_not_ready` (a crash-looping test-service sidecar, K§3.3) is the cluster
  # controller's fifth refusal; the run never started, so it is a hold like the others.
  # bd-bmecet adds the primary's own two: a placement the controller never acknowledged or lost.
  @reasons ~w(no_capacity unschedulable image_unavailable bad_spec service_not_ready unacknowledged placement_lost placement_timeout startup_failed)

  describe "pull_refusal?/1 (SI4a)" do
    test "an image_unavailable refusal of a pull or a contract check is a pull refusal" do
      for detail <- [
            ~s({:pull_failed, 125, "unauthorized"}),
            ~s({:contract_mismatch, "arbiter.runtime-contract", "2"})
          ] do
        assert Refusal.pull_refusal?(%{reason: "image_unavailable", detail: detail})
      end
    end

    test "other refusals and other image_unavailable causes are not" do
      refute Refusal.pull_refusal?(%{reason: "image_unavailable", detail: "{:inspect_failed, 1}"})
      refute Refusal.pull_refusal?(%{reason: "image_unavailable", detail: nil})
      refute Refusal.pull_refusal?(%{reason: "no_capacity", detail: "{:pull_failed, 1, \"x\"}"})
    end
  end

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

    test "a placement timeout (bd-3jjt3p) is a refusal-shaped hold with the stage and budget" do
      error =
        {:claude_start_failed, {:remote_placement_failed, {:placement_timeout, :prepare, 1800}}}

      assert {:ok, %{reason: "placement_timeout", detail: detail}} =
               Refusal.from_start_error(error)

      assert detail =~ "prepare"
      assert detail =~ "1800"
    end

    test "recognises the unwrapped shapes a ReviewGate spawn returns" do
      refused = {:remote_placement_failed, {:refused, "unschedulable", "0/3 nodes are available"}}

      for error <- [refused, {:worker_session_failed, refused}] do
        assert {:ok, %{reason: "unschedulable", detail: "0/3 nodes are available"}} =
                 Refusal.from_start_error(error)
      end

      assert {:ok, %{reason: "placement_timeout"}} =
               Refusal.from_start_error(
                 {:worker_session_failed,
                  {:remote_placement_failed, {:placement_timeout, :assign, 900}}}
               )

      assert Refusal.from_start_error({:worker_session_failed, :enoent}) == :error
    end

    test "an unknown refuse reason is not trusted as one" do
      error = {:claude_start_failed, {:remote_placement_failed, {:refused, "bad_idea", nil}}}
      assert Refusal.from_start_error(error) == :error
    end
  end

  describe "capacity?/1" do
    test "only a refusal that is the cluster being full is a capacity hold" do
      assert Refusal.capacity?(%{reason: "unschedulable", detail: nil})
      assert Refusal.capacity?(%{reason: "no_capacity", detail: nil})

      for reason <- @reasons -- ~w(unschedulable no_capacity) do
        refute Refusal.capacity?(%{reason: reason, detail: nil}), reason
      end
    end
  end

  describe "info/3" do
    test "carries a phrase, as every other no_node_capacity hold does" do
      info = Refusal.info("bd-1", "edge-1", %{reason: "unschedulable", detail: "0/3 nodes"})
      assert is_binary(info.phrase)
      assert info.phrase =~ "edge-1"
      assert info.phrase =~ "unschedulable"
    end

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
