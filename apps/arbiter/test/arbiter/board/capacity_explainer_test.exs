defmodule Arbiter.Board.CapacityExplainerTest do
  @moduledoc """
  bd-5fl9sx: the explanation of the slot cap and of capacity holds comes from
  the scheduler's own terms, so it must agree with `effective_max_concurrent/3`
  and with the board's `slots_total` for node-, placement- and account-bound
  setups. (DC1 deleted the install-wide and workspace `max_concurrent` limits.)
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
    on_exit(fn -> {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(nil) end)

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

  # The binding term really is a minimum: its value is the effective cap, and
  # no other listed term is below it. (Ties go to the limit the operator set on
  # purpose; the value still has to be the minimum.)
  defp assert_binding_is_minimum(terms) do
    values = Keyword.values(terms.terms)
    assert terms.terms[terms.binding] == terms.effective
    assert terms.effective == Enum.min(values)
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
      assert_binding_is_minimum(terms)

      # Binding means raising it raises the cap: one more local worker, one more slot.
      local_cap!(4)

      assert elem(
               explained(ws, [node("big", 2), node("ryan-oryx-pro", 4, %{state: :offline})]),
               2
             ) == 6

      assert limit_of(cap, :nodes).binding?

      assert limit_of(cap, :nodes).text =~
               "Capacity 5 = this machine (3) + big (2) + ryan-oryx-pro (0, offline)"

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

  describe "machine-bound" do
    test "the install's capacity is the machines' sum and no other limit is listed" do
      local_cap!(5)
      ws = workspace!(%{"worker" => %{"placement" => "prefer_remote"}})

      {cap, terms, scheduler} = explained(ws, [node("a", 4)])

      assert cap.effective == scheduler
      assert scheduler == 9
      assert cap.binding == :nodes
      assert_binding_is_minimum(terms)
      assert Enum.sort(Keyword.keys(terms.terms)) == [:nodes, :placement, :placement_free]
      assert limit_of(cap, :nodes).change =~ "arb node set local --max-workers N"

      # The deleted limits are not terms, limits or hints any more.
      for key <- [:ceiling, :workspace], do: refute(key in Enum.map(cap.limits, & &1.key))
    end
  end

  describe "account-bound" do
    test "the account's headroom binds and the explanation names who is using it" do
      local_cap!(6)
      ws = workspace!()
      account = account!(%{max_concurrent: 2})
      link!(ws, account)
      _key = live_worker!(ws)

      {cap, terms, scheduler} = explained(ws, [], 0)

      assert cap.effective == scheduler
      assert scheduler == 1
      assert cap.binding == :account
      assert_binding_is_minimum(terms)

      # Raising the account's limit raises the cap.
      Ash.update!(account, %{max_concurrent: 5})
      assert elem(explained(ws, [], 0), 2) > scheduler

      assert cap.headline =~
               "Limited to 1 by the Claude account (claude:#{account.slug}): 1 of 2 in use."

      assert limit_of(cap, :account).binding?
      assert limit_of(cap, :account).text =~ "1 of 2 in use"

      assert limit_of(cap, :account).change =~
               "arb account set claude:#{account.slug} --max-concurrent N"
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
      local_cap!(2)
      ws = workspace!()

      board = Snapshot.load(workspace_id: ws.id, issues: [], workers: [])

      assert board.slots_total == 2
      assert CapacityExplainer.cap(board).effective == board.slots_total
      assert %{cap: %{binding: :nodes}} = CapacityExplainer.explain(board)
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
      local_cap!(6)
      ws = workspace!()
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
      ws = workspace!()
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

    test "routed accounts bound the hold: the provider accounts are named, not the machines" do
      local_cap!(6)
      ws = workspace!()

      routing = %{
        capacity: 2,
        available: [
          %{account: %{provider: :claude, slug: "one"}},
          %{account: %{provider: :codex, slug: "two"}}
        ]
      }

      terms = Snapshot.capacity_terms(ws, 2, routing: routing)
      assert terms.binding == :account
      assert %{kind: :routed} = terms.account

      hold =
        CapacityExplainer.hold(:no_slot, %{capacity: terms, slot_holders: ["bd-a", "bd-b"]})

      assert hold.summary =~
               "The provider accounts (claude:one, codex:two) have room for 2 at once"

      assert hold.summary =~ "bd-a, bd-b"
      refute hold.summary =~ "available machines"
    end

    test "a machine-bound hold says every slot on the available machines is in use" do
      local_cap!(2)
      ws = workspace!()

      board = %{capacity: Snapshot.capacity_terms(ws, 2, []), slot_holders: ["bd-a", "bd-b"]}
      hold = CapacityExplainer.hold(:no_slot, board)

      assert hold.summary =~ "All 2 slots on the available machines are in use"
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

    test "a quota hold's summary is plain words whatever the gate's sentence contains" do
      reasons = [
        "claude:default 7d 20% ≥ paced 20%",
        "7d quota warning (weekly_warning_policy: hold)",
        "claude:default 7d exhausted (status=rejected)",
        "claude:default 7d 20% ≥ paced 20%; codex:work at capacity " <>
          "(no concurrency slot left (max_concurrent / share))"
      ]

      for reason <- reasons do
        hold = CapacityExplainer.hold({:quota, reason}, %{})

        assert hold.kind == :quota
        assert hold.details == reason
        refute hold.summary =~ "="
        refute hold.summary =~ "_"
        refute hold.summary =~ "max_concurrent"
        refute hold.summary =~ "("
        assert hold.summary =~ "too used up to start new work right now"
      end

      assert CapacityExplainer.hold({:quota, List.last(reasons)}, %{}).summary =~
               "The Claude and Codex quotas are too used up"

      assert CapacityExplainer.hold({:quota, "7d quota warning"}, %{}).summary =~
               "The provider's quota is too used up"
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

  describe "a guardrail hold (bd-atll60, G13)" do
    test "no eligible model says so, and what to do" do
      hold =
        CapacityExplainer.hold({:guardrail, "no eligible model: codex: D3 exceeds D1"}, %{},
          raw: "held — guardrail (…)"
        )

      assert hold.kind == :guardrail
      assert hold.badge == "No eligible model"
      assert hold.summary =~ "D3 exceeds D1"
    end

    test "a permission awaiting a grant has its own badge" do
      hold = CapacityExplainer.hold({:guardrail, "awaiting operator grant: prod_ssh"}, %{})

      assert hold.kind == :guardrail
      assert hold.badge == "Awaiting grant"
      assert hold.summary =~ "prod_ssh"
    end
  end
end
