defmodule Arbiter.Worker.DispatchNodePlacementTest do
  @moduledoc """
  RW8 (bd-3igo6h): the second admission gate in `Worker.Dispatch.dispatch/2`
  (`ensure_node_capacity/2`, after `ensure_account_capacity/2`): per-workspace
  `worker.placement`, the primary's own cap, and `{:no_node_capacity, _}`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Nodes.Placement
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  @repo ResumeSlotFixture.repo()

  setup do
    ResumeSlotFixture.setup_repo!()
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 10)
    on_exit(fn -> Settings.set_nodes_local_max_workers(nil) end)
    %{ws: workspace!()}
  end

  defp workspace!(config \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "place-#{n}", prefix: "pl#{n}", config: config})
    ws
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- placement fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp dispatch(issue, opts \\ []) do
    Dispatch.dispatch(issue.id, [repo: @repo, start_driver: false] ++ opts)
  end

  describe "worker.placement unset (local_only) and no override: dispatch is unchanged" do
    test "a dispatch starts a worker and reads no node state", %{ws: ws} do
      issue = ready!(ws, "unchanged")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
      assert Ash.get!(Issue, issue.id).state == :active
      # Nothing was reserved: the gate had nothing to decide.
      assert Placement.reservations() == []
    end

    test "many fresh dispatches are not capped by the (unenforced) local default", %{ws: ws} do
      Application.put_env(:arbiter, :conductor_system_max_concurrent, 1)

      for n <- 1..3 do
        assert {:ok, _} = dispatch(ready!(ws, "burst #{n}"))
      end
    end

    test "prefer_remote with no node available runs locally, as before", %{ws: _ws} do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote")

      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end
  end

  # The podman-backed Claude implementer: the only run placement may send away.
  @podman [security: %{"sandbox" => %{"backend" => "podman"}}]

  describe "worker.placement: remote_only" do
    test "an eligible run is held with {:no_node_capacity, _} while nothing can run remotely" do
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      issue = ready!(ws, "remote only")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman)
      assert info.mode == :remote_only
      assert info.task_id == issue.id

      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
    end
  end

  describe "worker.placement: remote_only, but the run cannot go remote" do
    test "a run that is not the podman Claude implementer stays local (never refused)" do
      ws = workspace!(%{"worker" => %{"placement" => "remote_only"}})
      assert {:ok, %{worker_pid: pid}} = dispatch(ready!(ws, "bwrap run"))
      assert is_pid(pid)
    end
  end

  describe "the primary's cap at 0" do
    setup do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)
      :ok
    end

    test "holds a dispatch with its reason, and starts it once the cap rises", %{ws: ws} do
      issue = ready!(ws, "held")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue)
      assert info.node == "local"
      assert info.cap == 0
      assert info.phrase =~ "held — local capacity 0 (run is local-only:"

      assert Worker.whereis(issue.id) == nil
      assert Ash.get!(Issue, issue.id).state == :queued
      # A hold leaves nothing reserved behind.
      assert Placement.reservations() == []

      {:ok, 1} = Nodes.set_local_max_workers(1, nil)
      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      assert is_pid(pid)
    end

    test "an eligible prefer_remote run no node can take is held with that in the reason" do
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})
      issue = ready!(ws, "prefer remote, nowhere to go")

      assert {:error, {:no_node_capacity, info}} = dispatch(issue, @podman)
      assert info.phrase =~ "held — local capacity 0 (no node had a free slot)"
    end

    test "force_slot goes over the cap", %{ws: ws} do
      issue = ready!(ws, "forced")
      assert {:ok, _} = dispatch(issue, force_slot: true, slot_override_actor: "test")
    end
  end

  describe "the primary's cap at N" do
    test "refuses the (N+1)th fresh dispatch and releases its reservation after each", %{ws: ws} do
      {:ok, 2} = Nodes.set_local_max_workers(2, nil)

      assert {:ok, _} = dispatch(ready!(ws, "one"))
      assert {:ok, _} = dispatch(ready!(ws, "two"))
      assert Placement.reservations() == []

      third = ready!(ws, "three")
      assert {:error, {:no_node_capacity, info}} = dispatch(third)
      assert info.cap == 2
      assert length(info.holders) == 2
      assert Ash.get!(Issue, third.id).state == :queued
    end

    test "a re-dispatch of a ticket already In progress is not held for being at the cap", %{
      ws: ws
    } do
      {:ok, 1} = Nodes.set_local_max_workers(1, nil)
      issue = ready!(ws, "active")
      assert {:ok, %{worker_pid: pid}} = dispatch(issue)
      ref = Process.monitor(pid)
      :ok = Worker.stop(issue.id, :normal)
      assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

      other = ready!(ws, "fills the slot")
      assert {:ok, _} = dispatch(other)

      assert {:ok, _} = dispatch(Ash.get!(Issue, issue.id))
    end
  end
end
