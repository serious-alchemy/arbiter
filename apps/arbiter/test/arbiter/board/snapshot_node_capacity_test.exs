defmodule Arbiter.Board.SnapshotNodeCapacityTest do
  @moduledoc """
  RW14 (`docs/design/remote-workers.md` §13): the board's slot count is the sum
  of the caps of every *available* node (the primary's own cap included); there
  is no install-wide ceiling over that sum (DC1 deleted it). A
  placement-headroom term stops the board planning slots that neither the
  primary nor any node can serve.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Actor
  alias Arbiter.Board.Snapshot
  alias Arbiter.Nodes
  alias Arbiter.Nodes.Capacity
  alias Arbiter.Tasks.Workspace

  @operator Actor.operator("cli")

  setup do
    on_exit(fn ->
      {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(nil)
    end)

    :ok
  end

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{
      name: "node-cap-#{System.unique_integer([:positive])}",
      prefix: "nc#{System.unique_integer([:positive])}",
      config: config
    })
  end

  defp placement(mode), do: %{"worker" => %{"placement" => mode}}

  defp node(name, max, attrs \\ %{}) do
    Map.merge(
      %{
        id: "node-#{name}",
        name: name,
        kind: :machine,
        state: :online,
        health: :ready,
        max: max,
        live: 0
      },
      attrs
    )
  end

  defp local_cap!(n), do: {:ok, ^n} = Nodes.set_local_max_workers(n, @operator)

  defp effective(ws, nodes, extra \\ []) do
    counted = Keyword.get(extra, :counted)
    opts = [nodes: nodes, remote_available?: Keyword.get(extra, :remote?, true)]
    Snapshot.effective_max_concurrent(ws, counted, opts)
  end

  describe "no enrolled nodes" do
    test "the effective concurrency is the local cap" do
      ws = workspace!()
      local_cap!(4)
      assert effective(ws, []) == 4
    end

    test "with no override it is the local hardware suggestion (DC1)" do
      ws = workspace!()
      put_app_env(:arbiter, :local_hardware, %{cpus: 12, mem_total: 31 * 1024 * 1024 * 1024})

      assert Capacity.local_cap() == 6
      assert effective(ws, []) == 6
      assert Snapshot.effective_max_concurrent(ws.id) == 6
    end
  end

  describe "the sum of available node caps" do
    setup do
      local_cap!(2)
      %{ws: workspace!(placement("prefer_remote"))}
    end

    test "an online node adds its cap", %{ws: ws} do
      assert effective(ws, [node("a", 3)]) == 5
      assert effective(ws, [node("a", 3), node("b", 1)]) == 6
      assert Snapshot.install_capacity(nodes: [node("a", 3)], remote_available?: true) == 5
      opts = [nodes: [node("a", 3)], remote_available?: true]
      assert Snapshot.effective_max_concurrent(nil, nil, opts) == 5
    end

    test "a local-only workspace is not promised a node's slots" do
      ws = workspace!()
      assert effective(ws, [node("a", 3)]) == 2
    end

    for state <- [:draining, :offline, :revoked, :suspect] do
      test "a #{state} node adds 0", %{ws: ws} do
        assert effective(ws, [node("a", 3, %{state: unquote(state)})]) == 2
      end
    end

    test "a lost node (its session is gone, so it reads offline) adds 0", %{ws: ws} do
      assert effective(ws, [node("a", 3), node("gone", 5, %{state: :offline, live: 0})]) == 5
    end

    test "a node that is not healthy adds 0", %{ws: ws} do
      assert effective(ws, [node("a", 3, %{health: :degraded})]) == 2
      assert effective(ws, [node("a", 3, %{health: :outdated})]) == 2
    end

    test "a node with no known cap adds 0", %{ws: ws} do
      assert effective(ws, [node("a", nil)]) == 2
    end

    test "nodes add nothing while remote execution is off", %{ws: ws} do
      assert effective(ws, [node("a", 3)], remote?: false) == 2
    end

    test "the breakdown names what each node contributed", %{ws: _ws} do
      breakdown =
        Capacity.breakdown(
          nodes: [node("a", 3), node("b", 2, %{state: :draining})],
          remote_available?: true
        )

      assert breakdown.local == 2
      assert breakdown.remote == 3
      assert breakdown.sum == 5
      assert breakdown.effective == 5
      assert [%{name: "a", contributes: 3}, %{name: "b", contributes: 0}] = breakdown.nodes
    end
  end

  describe "there is no install-wide ceiling over the sum (DC1)" do
    setup do
      local_cap!(2)
      %{ws: workspace!(placement("prefer_remote"))}
    end

    test "the sum applies", %{ws: ws} do
      assert effective(ws, [node("a", 3)]) == 5
    end

    test "the breakdown carries no ceiling" do
      breakdown = Capacity.breakdown(nodes: [node("a", 3)], remote_available?: true)

      assert %{sum: 5, effective: 5} = breakdown
      refute Map.has_key?(breakdown, :ceiling)
      refute Map.has_key?(breakdown, :ceiling_cuts?)
    end
  end

  describe "provider account caps still bind" do
    test "node capacity free but the account full: no slots" do
      local_cap!(2)
      ws = workspace!()
      other = workspace!()

      account =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "rw14-#{System.unique_integer([:positive])}",
          max_concurrent: 1
        })

      for w <- [ws, other],
          do:
            Ash.create!(WorkspaceProviderAccount, %{
              workspace_id: w.id,
              provider: :claude,
              provider_account_id: account.id
            })

      key = "rw14-worker-#{System.unique_integer([:positive])}"
      test = self()

      pid =
        spawn(fn ->
          {:ok, _} = Registry.register(Arbiter.Worker.Registry, key, nil)
          :ok = Arbiter.Worker.Registry.put_dispatch(key, other.id, "claude")
          send(test, {:registered, self()})
          Process.sleep(:infinity)
        end)

      assert_receive {:registered, ^pid}
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      # A free node with room: the sum is 5, the account is full.
      assert effective(ws, [node("a", 3)]) == 0
    end
  end

  describe "placement headroom" do
    test "remote_only work with every node full plans no slot beyond what is running" do
      local_cap!(2)
      ws = workspace!(placement("remote_only"))
      full = [node("a", 2, %{live: 2}), node("b", 1, %{live: 1})]

      assert effective(ws, full, counted: 0) == 0
      # What is already running keeps its slots; nothing new is planned.
      assert effective(ws, full, counted: 3) == 3
    end

    test "remote_only work with every node drained or lost plans nothing" do
      local_cap!(2)
      ws = workspace!(placement("remote_only"))

      nodes = [
        node("a", 2, %{state: :draining}),
        node("b", 1, %{state: :offline}),
        node("c", 1, %{state: :revoked})
      ]

      assert effective(ws, nodes, counted: 0) == 0
    end

    test "remote_only work plans exactly the free node slots" do
      local_cap!(2)
      ws = workspace!(placement("remote_only"))
      nodes = [node("a", 3, %{live: 1})]

      assert effective(ws, nodes, counted: 1) == 3
      assert effective(ws, nodes, counted: 0) == 2
    end

    test "remote_only never leans on the local cap" do
      local_cap!(5)
      ws = workspace!(placement("remote_only"))
      assert effective(ws, [], counted: 0) == 0
    end

    test "prefer_remote plans local plus node capacity, bounded by what is free" do
      local_cap!(2)
      ws = workspace!(placement("prefer_remote"))

      assert effective(ws, [node("a", 3)], counted: 0) == 5
      assert effective(ws, [node("a", 3, %{live: 3})], counted: 0) == 2
    end

    test "a local-only workspace is served by the local cap alone" do
      local_cap!(2)
      ws = workspace!()
      assert effective(ws, [node("a", 3)], counted: 0) == 2
    end

    test "a local cap of 0 plans no local-only slot" do
      local_cap!(0)
      ws = workspace!()
      assert effective(ws, [node("a", 3)], counted: 0) == 0
      assert effective(ws, [], counted: 0) == 0
    end

    test "a local cap of 0 leaves a prefer_remote workspace its nodes" do
      local_cap!(0)
      ws = workspace!(placement("prefer_remote"))
      assert effective(ws, [node("a", 3)], counted: 0) == 3
    end
  end

  describe "load/1" do
    defp ready_issue(ws) do
      now = DateTime.utc_now()

      %{
        id: "bd-rw14",
        title: "local-only work",
        state: :queued,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: ws.id,
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: now,
        updated_at: now,
        closed_at: nil
      }
    end

    test "a local-only Ready card never takes a planned slot while the local cap is 0" do
      local_cap!(0)
      ws = workspace!()

      board = Snapshot.load(workspace_id: ws.id, issues: [ready_issue(ws)], workers: [])

      assert board.slots_total == 0
      assert board.slots_free == 0
      assert board.slots_used == 0
      assert board.promote == nil
      assert [%{id: "bd-rw14", reason: reason, state: :blocked}] = board.ready
      assert reason =~ "held — local capacity 0"
    end

    test "with a local slot the same card is promoted" do
      local_cap!(1)
      ws = workspace!()

      board = Snapshot.load(workspace_id: ws.id, issues: [ready_issue(ws)], workers: [])

      assert board.slots_total == 1
      assert board.promote == "bd-rw14"
    end
  end
end
