defmodule Arbiter.Board.CapacityExplainerTest do
  @moduledoc """
  bd-5fl9sx: the explanation of the slot cap and of capacity holds comes from
  the scheduler's own terms, so it must agree with `effective_max_concurrent/3`
  and with the board's `slots_total` for node-, workspace-, ceiling- and
  account-bound setups.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Actor
  alias Arbiter.Board.CapacityExplainer
  alias Arbiter.Board.Snapshot
  alias Arbiter.Nodes
  alias Arbiter.Tasks.Workspace

  @operator Actor.operator("cli")

  setup do
    previous = Application.fetch_env(:arbiter, :conductor_system_max_concurrent)
    Application.delete_env(:arbiter, :conductor_system_max_concurrent)
    {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(nil)

    on_exit(fn ->
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(nil)

      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :conductor_system_max_concurrent, v)
        :error -> Application.delete_env(:arbiter, :conductor_system_max_concurrent)
      end
    end)

    :ok
  end

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{
      name: "explain-#{System.unique_integer([:positive])}",
      prefix: "ex#{System.unique_integer([:positive])}",
      config: config
    })
  end

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

  defp account!(attrs) do
    Ash.create!(
      ProviderAccount,
      Map.merge(%{provider: :claude, slug: "expl-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp link!(ws, account) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })
  end

  defp live_worker!(ws) do
    key = "expl-worker-#{System.unique_integer([:positive])}"
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(Arbiter.Worker.Registry, key, nil)
        :ok = Arbiter.Worker.Registry.put_dispatch(key, ws.id, "claude")
        send(test, {:registered, self()})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    key
  end

  defp issue(id, ws, extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
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
      },
      extra
    )
  end

  # The cap explanation for `ws`, plus the scheduler's own answer for the same
  # inputs, so each test can assert the two agree.
  defp explained(ws, nodes, counted \\ 0) do
    opts = [nodes: nodes, remote_available?: true]
    terms = Snapshot.capacity_terms(ws, counted, opts)
    cap = CapacityExplainer.cap(%{capacity: terms, slots_used: 0, slots_free: 0})
    {cap, terms, Snapshot.effective_max_concurrent(ws, counted, opts)}
  end

  defp limit_of(cap, key), do: Enum.find(cap.limits, &(&1.key == key))

  describe "node-bound" do
    test "the machines' sum is the cap, listing each node and why one adds nothing" do
      local_cap!(3)
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})

      {cap, terms, scheduler} =
        explained(ws, [node("big", 2), node("ryan-oryx-pro", 4, %{state: :offline})])

      assert cap.effective == scheduler
      assert terms.effective == scheduler
      assert scheduler == 5
      assert cap.binding == :nodes

      assert limit_of(cap, :nodes).binding?
      assert limit_of(cap, :nodes).text =~ "Capacity 5 = this machine (3) + big (2) + ryan-oryx-pro (0, offline)"
      assert limit_of(cap, :nodes).change =~ "arb node set local --max-workers N"
      assert cap.headline =~ "machine capacity"
    end

    test "a draining or unhealthy node is explained in words" do
      local_cap!(1)
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})

      {cap, _terms, _} =
        explained(ws, [
          node("a", 2, %{state: :draining}),
          node("b", 2, %{health: :degraded})
        ])

      text = limit_of(cap, :nodes).text
      assert text =~ "a (0, draining)"
      assert text =~ "b (0, not healthy)"
    end
  end

  describe "workspace-bound" do
    test "the workspace setting binds when it is below the machines" do
      local_cap!(5)
      ws = workspace!(%{"conductor" => %{"max_concurrent" => 2}})

      {cap, _terms, scheduler} = explained(ws, [])

      assert cap.effective == scheduler
      assert scheduler == 2
      assert cap.binding == :workspace
      assert cap.headline == "Limited to 2 by the workspace setting."
      assert limit_of(cap, :workspace).binding?
      refute limit_of(cap, :nodes).binding?
      assert limit_of(cap, :workspace).change =~ "arb config set conductor.max_concurrent N"
    end
  end

  describe "ceiling-bound" do
    test "the install-wide limit binds when it cuts the machine total" do
      local_cap!(5)
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(3)
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})

      {cap, _terms, scheduler} = explained(ws, [node("a", 4)])

      assert cap.effective == scheduler
      assert scheduler == 3
      assert cap.binding == :ceiling
      assert limit_of(cap, :ceiling).text =~ "Install-wide limit: 3"
      assert limit_of(cap, :ceiling).change =~ "arb settings set conductor_system_max_concurrent N"
    end
  end

  describe "account-bound" do
    test "the account's headroom binds and the explanation names who is using it" do
      local_cap!(6)
      ws = workspace!(%{"conductor" => %{"max_concurrent" => 6}})
      account = account!(%{max_concurrent: 2})
      link!(ws, account)
      _key = live_worker!(ws)

      {cap, _terms, scheduler} = explained(ws, [], 0)

      assert cap.effective == scheduler
      assert scheduler == 1
      assert cap.binding == :account
      assert cap.headline =~ "Limited to 1 by the Claude account (claude:#{account.slug}): 1 of 2 in use."
      assert limit_of(cap, :account).binding?
      assert limit_of(cap, :account).text =~ "1 of 2 in use"
      assert limit_of(cap, :account).change =~ "arb account set claude:#{account.slug} --max-concurrent N"
    end

    test "an account with no limit set is listed but never binding" do
      local_cap!(2)
      ws = workspace!()
      link!(ws, account!(%{}))

      {cap, _terms, scheduler} = explained(ws, [])

      assert cap.effective == scheduler
      assert cap.binding == :nodes
      refute limit_of(cap, :account).binding?
      assert limit_of(cap, :account).text =~ "no limit set"
    end
  end

  describe "agreement with the board" do
    test "the board's slots_total is the explainer's effective cap" do
      local_cap!(5)
      ws = workspace!(%{"conductor" => %{"max_concurrent" => 2}})

      board = Snapshot.load(workspace_id: ws.id, issues: [], workers: [])

      assert board.slots_total == 2
      assert CapacityExplainer.cap(board).effective == board.slots_total
      assert %{cap: %{binding: :workspace}} = CapacityExplainer.explain(board)
    end
  end

  describe "what is using the slots" do
    test "a ticket holding a slot with no agent is listed as parked" do
      local_cap!(1)
      ws = workspace!()

      parked = issue("bd-parked", ws, %{state: :active})
      board = Snapshot.load(workspace_id: ws.id, issues: [parked], workers: [])

      cap = CapacityExplainer.cap(board)

      assert board.slot_holders == ["bd-parked"]
      assert cap.used == 1
      assert cap.parked == 1
      assert [%{id: "bd-parked", state: :parked, text: text}] = cap.users
      assert text =~ "no agent is running"
      assert text =~ "still holds a slot"
    end
  end

  describe "capacity holds" do
    setup do
      local_cap!(1)
      ws = workspace!()
      parked = issue("bd-parked", ws, %{state: :active})
      waiting = issue("bd-waiting", ws)
      board = Snapshot.load(workspace_id: ws.id, issues: [parked, waiting], workers: [])
      %{board: board, ws: ws}
    end

    test "the head of the queue carries the structured no-slot hold", %{board: board} do
      assert [%{id: "bd-waiting", hold: :no_slot}] = board.ready
    end

    test "it is explained as waiting for capacity, in words", %{board: board} do
      %{holds: %{"bd-waiting" => hold}} = CapacityExplainer.explain(board)

      assert hold.kind == :capacity
      assert hold.badge == "Waiting for capacity"
      assert hold.summary =~ "Waiting for a free worker slot"
      assert hold.summary =~ "bd-parked"
      assert hold.summary =~ "starts when one finishes"
      refute hold.summary =~ "no_slot"
      refute hold.summary =~ "max_concurrent"
      assert hold.details =~ "no free worker slot"
    end

    test "an account-bound hold names the account's runs" do
      ws = workspace!(%{"conductor" => %{"max_concurrent" => 6}})
      account = account!(%{max_concurrent: 1})
      link!(ws, account)
      key = live_worker!(ws)
      waiting = issue("bd-acct-wait", ws)
      board = Snapshot.load(workspace_id: ws.id, issues: [waiting], workers: [])

      # The account is the only provider the workspace can use and it is full,
      # so the scheduler holds the card on the pool, not on the slot count.
      assert [%{hold: {:provider_constraint, _}}] = board.ready
      %{holds: %{"bd-acct-wait" => hold}} = CapacityExplainer.explain(board)

      assert hold.kind == :capacity
      assert hold.summary =~ "Waiting for a Claude slot."
      assert hold.summary =~ "allows 1 at once and it is in use (#{key} implement)"
      assert hold.summary =~ "It starts when one finishes."
    end
  end

  describe "a no-slot hold bound by the account" do
    test "says which account is full and what is using it" do
      local_cap!(6)
      ws = workspace!(%{"conductor" => %{"max_concurrent" => 6}})
      account = account!(%{max_concurrent: 2})
      link!(ws, account)
      first = live_worker!(ws)
      second = live_worker!(ws)

      board = %{capacity: Snapshot.capacity_terms(ws, 0, []), slot_holders: []}
      assert board.capacity.binding == :account
      assert board.capacity.effective == 0

      hold = CapacityExplainer.hold(:no_slot, board)

      assert hold.summary =~ "Waiting for a Claude slot."
      assert hold.summary =~ "allows 2 at once and all are in use"
      assert hold.summary =~ first
      assert hold.summary =~ second
    end

    test "a workspace-bound hold says the workspace is the limit" do
      local_cap!(6)
      ws = workspace!(%{"conductor" => %{"max_concurrent" => 2}})

      board = %{capacity: Snapshot.capacity_terms(ws, 2, []), slot_holders: ["bd-a", "bd-b"]}
      hold = CapacityExplainer.hold(:no_slot, board)

      assert hold.summary =~ "The workspace allows 2 at once and they are all in use"
      assert hold.summary =~ "bd-a, bd-b"
    end
  end

  describe "other holds" do
    test "a provider-constraint hold at capacity reads as waiting for capacity" do
      detail =
        "exclude gemini: claude:default at capacity (no concurrency slot left (max_concurrent / share))"

      hold = CapacityExplainer.hold({:provider_constraint, detail}, %{}, raw: "held — #{detail}")

      assert hold.kind == :capacity
      assert hold.badge == "Waiting for capacity"
      assert hold.summary =~ "provider restriction (exclude gemini)"
      assert hold.summary =~ "The Claude account (claude:default) is full right now."
      refute hold.summary =~ "max_concurrent"
      assert hold.details =~ "max_concurrent / share"
    end

    test "a paused provider keeps its own badge" do
      hold =
        CapacityExplainer.hold({:provider_constraint, "require codex: codex paused"}, %{})

      assert hold.kind == :paused_provider
      assert hold.badge == "Paused provider"
    end

    test "a quota hold keeps its own badge and shows the gate's sentence as details" do
      hold = CapacityExplainer.hold({:quota, "7d quota 62% ≥ paced 55%"}, %{})

      assert hold.kind == :quota
      assert hold.badge == "Quota hold"
      assert hold.details == "7d quota 62% ≥ paced 55%"
    end

    test "an auth hold is not called a quota hold" do
      hold = CapacityExplainer.hold({:quota, "claude auth hold (3 consecutive auth deaths)"}, %{})
      assert hold.badge == "Auth hold"
    end

    test "a paused scheduler" do
      assert %{badge: "Scheduler paused", kind: :scheduler_paused} =
               CapacityExplainer.hold(:paused, %{})
    end
  end
end
