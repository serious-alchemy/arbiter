defmodule Arbiter.Nodes.LocalCapacityTest do
  @moduledoc """
  RW8 operator amendment: one cap on the primary covers every local run, and a
  cap of 0 holds local-only work instead of failing it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Nodes.Placement
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Registry, as: WorkerRegistry

  setup do
    ws = Ash.create!(Workspace, %{name: "lc-#{System.unique_integer([:positive])}"})
    on_exit(fn -> Settings.set_nodes_local_max_workers(nil) end)
    {:ok, ws: ws}
  end

  defp fake_worker(ws, opts \\ []) do
    key = Keyword.get(opts, :key, "lc-fake-#{System.unique_integer([:positive])}")
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(WorkerRegistry, key, nil)
        :ok = WorkerRegistry.put_dispatch(key, ws.id, "claude", Keyword.take(opts, [:node_id]))
        send(test, {:registered, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    {key, pid}
  end

  defp stop!(pid) do
    ref = Process.monitor(pid)
    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  describe "cap/0" do
    test "defaults to the install's local concurrency and is not enforced" do
      assert %{cap: cap, source: :default, enforced?: false} = LocalCapacity.cap()
      assert cap == Arbiter.Board.Snapshot.system_max_concurrent()
    end

    test "an override replaces the default, down to 0, and is enforced" do
      {:ok, 2} = Arbiter.Nodes.set_local_max_workers(2, nil)
      assert %{cap: 2, source: :override, enforced?: true} = LocalCapacity.cap()

      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)
      assert %{cap: 0, source: :override, enforced?: true} = LocalCapacity.cap()
    end
  end

  describe "kinds/0" do
    test "names how each spawn kind is capped" do
      assert LocalCapacity.kinds() == %{
               implementer: :at_cap,
               redispatch: :zero_only,
               resume: :never,
               review: :zero_only,
               reviewer: :zero_only,
               fix_pass: :zero_only,
               conflict_pass: :zero_only,
               review_fix_round: :zero_only
             }
    end
  end

  describe "admit/3 with no override (today's behaviour)" do
    test "admits every kind, whatever is running", %{ws: ws} do
      for _ <- 1..5, do: fake_worker(ws)

      for kind <- Map.keys(LocalCapacity.kinds()) do
        assert :ok = LocalCapacity.admit("bd-none-#{kind}", kind, [])
      end
    end
  end

  describe "admit/3 with an override" do
    test "a fresh implementer is refused at the cap and admitted below it", %{ws: ws} do
      {:ok, 2} = Arbiter.Nodes.set_local_max_workers(2, nil)
      {_k1, _} = fake_worker(ws)
      assert :ok = LocalCapacity.admit("bd-a", :implementer, [])
      LocalCapacity.release("bd-a")
      {_k2, w2} = fake_worker(ws)

      assert {:error, {:no_node_capacity, info}} = LocalCapacity.admit("bd-b", :implementer, [])
      assert info.node == "local"
      assert info.cap == 2
      assert length(info.holders) == 2
      assert info.message =~ "held"

      stop!(w2)
      assert :ok = LocalCapacity.admit("bd-b", :implementer, [])
    end

    test "a worker on a remote node does not count against the primary's cap", %{ws: ws} do
      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      fake_worker(ws, node_id: "node-1")
      assert :ok = LocalCapacity.admit("bd-remote-free", :implementer, [])
    end

    test "a reservation counts until released, so a burst cannot overbook", %{ws: _ws} do
      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      assert :ok = LocalCapacity.admit("bd-first", :implementer, [])
      assert {:error, {:no_node_capacity, _}} = LocalCapacity.admit("bd-second", :implementer, [])
      LocalCapacity.release("bd-first")
      assert :ok = LocalCapacity.admit("bd-second", :implementer, [])
    end

    test "force goes over the cap", %{ws: ws} do
      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      fake_worker(ws)
      assert :ok = LocalCapacity.admit("bd-forced", :implementer, force: true)
    end

    test "a ticket's own workers do not count against its own follow-up", %{ws: ws} do
      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      fake_worker(ws, key: "bd-own")
      assert :ok = LocalCapacity.admit("bd-own", :reviewer, [])
      assert :ok = LocalCapacity.admit("bd-own", :fix_pass, [])
    end

    test "follow-up kinds are never held for being at the cap (no deadlock)", %{ws: ws} do
      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      fake_worker(ws)
      fake_worker(ws)

      for kind <- [:review, :reviewer, :fix_pass, :conflict_pass, :review_fix_round, :resume] do
        assert :ok = LocalCapacity.admit("bd-follow-#{kind}", kind, [])
      end
    end
  end

  describe "admit/3 with the cap at 0" do
    setup do
      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)
      :ok
    end

    test "holds every local kind except a resume, naming the reason" do
      for kind <- [:implementer, :review, :reviewer, :fix_pass, :conflict_pass, :review_fix_round] do
        assert {:error, {:no_node_capacity, info}} =
                 LocalCapacity.admit("bd-zero-#{kind}", kind,
                   reason: {:local_only, :non_claude_provider},
                   provider: :codex
                 )

        assert info.cap == 0
        assert info.node == "local"

        assert info.phrase ==
                 "held — local capacity 0 (run is local-only: provider codex has no podman path)"
      end
    end

    test "a hold with no stated reason still reads as a hold" do
      assert {:error, {:no_node_capacity, info}} = LocalCapacity.admit("bd-zero", :reviewer, [])
      assert info.phrase == "held — local capacity 0"
    end

    test "a resume is counted but never held" do
      assert :ok = LocalCapacity.admit("bd-zero-resume", :resume, [])
    end

    test "resumes as soon as the cap rises" do
      assert {:error, {:no_node_capacity, _}} = LocalCapacity.admit("bd-rise", :implementer, [])
      {:ok, 1} = Arbiter.Nodes.set_local_max_workers(1, nil)
      assert :ok = LocalCapacity.admit("bd-rise", :implementer, [])
    end

    test "force still goes over (recorded)" do
      assert :ok = LocalCapacity.admit("bd-zero-forced", :implementer, force: true)
    end
  end

  describe "gate/3 (the placement-aware entry point)" do
    test "an eligible run placed on a node does not touch the primary's cap" do
      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)

      node = %{
        id: "node-x",
        name: "x",
        state: :online,
        health: :ready,
        labels: [],
        live: 0,
        max: 1
      }

      request = %{
        task_id: "bd-eligible",
        workspace_id: "ws",
        kind: :implementer,
        provider: :claude,
        layout: :private_clone,
        mode: :prefer_remote
      }

      assert {:ok, {:node, %{name: "x"}}} =
               LocalCapacity.gate(request, nodes: [node], remote_available?: true)

      Placement.release("bd-eligible")
    end

    test "an ineligible run is held at local cap 0 with its reason" do
      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)

      request = %{
        task_id: "bd-agy",
        workspace_id: "ws",
        kind: :implementer,
        provider: :agy,
        layout: :worktree,
        mode: :prefer_remote
      }

      assert {:error, {:no_node_capacity, info}} = LocalCapacity.gate(request, [])

      assert info.phrase =~
               "held — local capacity 0 (run is local-only: provider agy has no podman path)"
    end

    test "remote_only with no node capacity is refused before the local cap is read" do
      request = %{
        task_id: "bd-ro",
        workspace_id: "ws",
        kind: :implementer,
        provider: :claude,
        layout: :private_clone,
        mode: :remote_only
      }

      assert {:error, {:no_node_capacity, %{mode: :remote_only}}} =
               LocalCapacity.gate(request, nodes: [], remote_available?: true)
    end

    test "prefer_remote that finds no node falls back to the local cap" do
      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)

      request = %{
        task_id: "bd-fallback",
        workspace_id: "ws",
        kind: :implementer,
        provider: :claude,
        layout: :private_clone,
        mode: :prefer_remote
      }

      assert {:error, {:no_node_capacity, info}} =
               LocalCapacity.gate(request, nodes: [], remote_available?: true)

      assert info.phrase =~ "held — local capacity 0"
      assert info.phrase =~ "no node had a free slot"
    end

    test "with no override an unchanged local_only dispatch is simply local" do
      request = %{
        task_id: "bd-plain",
        workspace_id: "ws",
        kind: :implementer,
        provider: :claude,
        layout: :worktree,
        mode: :local_only
      }

      assert {:ok, :local} = LocalCapacity.gate(request, [])
    end
  end
end
