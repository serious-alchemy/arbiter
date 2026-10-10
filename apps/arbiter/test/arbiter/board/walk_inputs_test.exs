defmodule Arbiter.Board.WalkInputsTest do
  @moduledoc """
  What the scheduler walk plans against (DC6, provider-dynamic-concurrency
  §4.1-§4.2): the pools from the published budgets and live seats, the machines,
  and each Ready card's candidates — eligibility only, in the workspace's own
  preference order, with the budget that binds that card.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Board.Scheduler
  alias Arbiter.Board.WalkInputs
  alias Arbiter.Quota.Budget
  alias Arbiter.Tasks.{Issue, Workspace}

  @most_quota %{"routing" => %{"provider_selection" => "most_quota"}}

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)
    :ok
  end

  defp workspace!(config \\ %{}) do
    Ash.create!(Workspace, %{name: "wi-#{System.unique_integer([:positive])}", config: config})
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{slug}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp link!(ws, account, attrs \\ %{}) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  # A Ready ticket: the walk only ever asks about those.
  defp issue!(ws, attrs \\ %{}) do
    created =
      Ash.create!(
        Issue,
        Map.merge(%{title: "walk me", workspace_id: ws.id, acceptance: "- walk fixture"}, attrs)
      )

    Ash.update!(created, %{}, action: :promote_to_ready)
  end

  defp budget(account, pool, budget, attrs \\ %{}) do
    struct!(
      Budget,
      Map.merge(
        %{
          account: account.id,
          pool: pool,
          budget: budget,
          binding: {:window, "5h"},
          reason: "5h binds"
        },
        attrs
      )
    )
  end

  defp gather(ws, issues, opts) do
    WalkInputs.gather(
      ws,
      issues,
      Keyword.merge([seats: %{}, local: %{cap: 6, used: 2}, remote_available?: false], opts)
    )
  end

  defp card(issue), do: %{id: issue.id, workspace_id: issue.workspace_id}

  describe "capacity sets" do
    test "a pool per published account budget, with its live seats and label" do
      ws = workspace!()
      claude = account!(:claude, "default", %{max_concurrent: 3})
      link!(ws, claude)

      walk =
        gather(ws, [],
          budgets: [
            budget(claude, "claude", 3, %{
              exempt_budget: 4,
              ceiling: %{max_concurrent: 3, share: nil}
            })
          ],
          seats: %{{claude.id, "claude"} => 2}
        )

      assert %{
               budget: 3,
               seats: 2,
               exempt_budget: 4,
               label: label,
               reason: "5h binds",
               cap: 3
             } = walk.pools[{claude.id, "claude"}]

      assert label == "claude:#{claude.slug}"
    end

    test "a policy workspace's variant is not a pool of its own" do
      ws = workspace!()
      claude = account!(:claude, "default")
      link!(ws, claude)

      walk =
        gather(ws, [],
          budgets: [
            budget(claude, "claude", 3),
            budget(claude, "claude", 1, %{policy_workspace: ws.id})
          ]
        )

      assert Map.keys(walk.pools) == [{claude.id, "claude"}]
      assert walk.pools[{claude.id, "claude"}].budget == 3
    end

    test "agy's two pools read as gemini and claude-gpt" do
      ws = workspace!()
      agy = account!(:antigravity, "default")

      walk =
        gather(ws, [],
          budgets: [
            budget(agy, "antigravity:gemini_models", 0),
            budget(agy, "antigravity:claude_and_gpt_models", 4)
          ]
        )

      assert walk.pools[{agy.id, "antigravity:gemini_models"}].label ==
               "antigravity:#{agy.slug} gemini"

      assert walk.pools[{agy.id, "antigravity:claude_and_gpt_models"}].label ==
               "antigravity:#{agy.slug} claude-gpt"
    end

    test "the primary is a machine; with remote execution off it is the only one" do
      walk = gather(workspace!(), [], budgets: [])
      assert walk.nodes == %{"local" => %{cap: 6, used: 2, label: "local"}}
    end

    test "an available remote node is a machine, with its reservations counted; others are not" do
      rows = [
        %{id: "n1", name: "box", state: :online, health: :ready, max: 4, live: 1},
        %{id: "n2", name: "gone", state: :offline, health: :ready, max: 4, live: 0},
        %{
          id: "n3",
          name: "tiny",
          state: :online,
          health: :ready,
          max: 2,
          live: 0,
          constrained?: true
        }
      ]

      walk = gather(workspace!(), [], budgets: [], remote_available?: true, nodes: rows)

      assert %{cap: 4, used: 1, label: "box", constrained?: false} = walk.nodes["n1"]
      assert %{label: "tiny", constrained?: true} = walk.nodes["n3"]
      refute Map.has_key?(walk.nodes, "n2")
      assert Map.has_key?(walk.nodes, "local")
    end
  end

  describe "a card's candidates on a workspace that routes by its agent pool (failover)" do
    test "each pool provider's account, on the primary" do
      ws = workspace!()
      claude = account!(:claude, "default")
      link!(ws, claude)
      ticket = issue!(ws)

      walk = gather(ws, [ticket], budgets: [budget(claude, "claude", 3)])

      assert [%{pool: {id, "claude"}, nodes: [["local"]]}] = walk.candidates.(card(ticket))
      assert id == claude.id
    end

    test "a provider with no account is an unmetered pool the machines bound" do
      ws = workspace!()
      ticket = issue!(ws)

      walk = gather(ws, [ticket], budgets: [])

      assert [%{pool: {:unmetered, "claude"}}] = walk.candidates.(card(ticket))
      assert %{budget: :unlimited, seats: 0} = walk.pools[{:unmetered, "claude"}]
    end

    test "a constraint the agent pool cannot meet is the card's own hold" do
      ws = workspace!()
      ticket = issue!(ws, %{provider_constraint: %{"require" => ["codex"]}})

      walk = gather(ws, [ticket], budgets: [])

      assert {:hold, {:provider_constraint, detail}} = walk.candidates.(card(ticket))
      assert detail =~ "require codex"
    end

    test "a policy workspace's budget binds the card there; an exempt card takes the exempt budget" do
      ws = workspace!()

      claude =
        account!(:claude, "default", %{quota_config: %{"pace_exempt_priority" => 0}})

      link!(ws, claude)
      plain = issue!(ws, %{priority: 2})
      urgent = issue!(ws, %{priority: 0})

      walk =
        gather(ws, [plain, urgent],
          budgets: [
            budget(claude, "claude", 3, %{exempt_budget: 5}),
            budget(claude, "claude", 2, %{policy_workspace: ws.id, exempt_budget: 4})
          ]
        )

      assert [%{budget: 2}] = walk.candidates.(card(plain))
      assert [%{budget: 4}] = walk.candidates.(card(urgent))
    end
  end

  describe "a card's candidates on a workspace that routes by quota" do
    test "every eligible account, at its cap or not; the budgets decide the rest" do
      ws = workspace!(@most_quota)
      claude = account!(:claude, "claude", %{max_concurrent: 0})
      codex = account!(:codex, "codex")
      link!(ws, claude, %{implementer_position: 0})
      link!(ws, codex, %{implementer_position: 1})
      ticket = issue!(ws)

      walk =
        gather(ws, [ticket],
          budgets: [budget(claude, "claude", 0), budget(codex, "codex", 2)],
          routing_opts: [quota_fun: fn _ -> nil end, gemini_code: "antigravity"]
        )

      pools = Enum.map(walk.candidates.(card(ticket)), & &1.pool)
      assert Enum.sort(pools) == Enum.sort([{claude.id, "claude"}, {codex.id, "codex"}])
    end

    test "a ticket every account is dropped for by its own constraint holds itself" do
      ws = workspace!(@most_quota)
      claude = account!(:claude, "claude")
      link!(ws, claude, %{implementer_position: 0})
      ticket = issue!(ws, %{provider_constraint: %{"require" => ["codex"]}})

      walk =
        gather(ws, [ticket],
          budgets: [budget(claude, "claude", 3)],
          routing_opts: [quota_fun: fn _ -> nil end, gemini_code: "antigravity"]
        )

      assert {:hold, {:provider_constraint, _}} = walk.candidates.(card(ticket))
    end

    test "a ticket whose every account is paused waits on the provider layer" do
      ws = workspace!(@most_quota)
      claude = account!(:claude, "claude")
      link!(ws, claude, %{implementer_position: 0})
      {:ok, _} = Arbiter.Providers.Pause.pause(claude.id, reason: "maintenance", by: "test")
      on_exit(fn -> Arbiter.Providers.Pause.resume(claude.id) end)
      ticket = issue!(ws)

      walk =
        gather(ws, [ticket],
          budgets: [budget(claude, "claude", 3)],
          routing_opts: [quota_fun: fn _ -> nil end, gemini_code: "antigravity"]
        )

      assert {:none, why} = walk.candidates.(card(ticket))
      assert why =~ "paused"
    end
  end

  describe "node_groups/3: the machines that can run a card, in Placement's preference" do
    @remote %{
      "n1" => %{cap: 4, used: 0, constrained?: false, workspace_ids: []},
      "n2" => %{cap: 4, used: 0, constrained?: true, workspace_ids: []},
      "n3" => %{cap: 4, used: 0, constrained?: false, workspace_ids: ["other-ws"]}
    }

    test "local_only, or a run no node may take, stays on the primary" do
      assert WalkInputs.node_groups(:local_only, true, @remote, "ws") == [["local"]]
      assert WalkInputs.node_groups(:prefer_remote, false, @remote, "ws") == [["local"]]
      assert WalkInputs.node_groups(:remote_only, false, @remote, "ws") == [["local"]]
    end

    test "prefer_remote: unconstrained nodes, then the primary, then constrained nodes" do
      assert WalkInputs.node_groups(:prefer_remote, true, @remote, "ws") ==
               [["n1"], ["local"], ["n2"]]
    end

    test "remote_only never offers the primary; a node pinned elsewhere is not offered" do
      assert WalkInputs.node_groups(:remote_only, true, @remote, "ws") == [["n1"], ["n2"]]

      assert WalkInputs.node_groups(:remote_only, true, @remote, "other-ws") == [
               ["n1", "n3"],
               ["n2"]
             ]

      assert WalkInputs.node_groups(:remote_only, true, %{}, "ws") == []
    end
  end

  # Seen live (v0.2.43): review-side runs count on the primary but its cap never
  # holds them, so the primary sat at 4 of 2 — filling today's install-wide slot
  # total — while a node had room.
  describe "a primary over its own cap" do
    test "a remote-eligible card is offered the node first, and the walk places it there" do
      ws =
        workspace!(%{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
        })

      claude = account!(:claude, "default")
      link!(ws, claude)
      ticket = issue!(ws)

      rows = [
        %{id: "oryx", name: "ryan-oryx-pro", state: :online, health: :ready, max: 3, live: 1}
      ]

      walk =
        gather(ws, [ticket],
          budgets: [budget(claude, "claude", 9)],
          seats: %{{claude.id, "claude"} => 5},
          local: %{cap: 2, used: 4},
          remote_available?: true,
          nodes: rows
        )

      assert %{cap: 2, used: 4} = walk.nodes["local"]
      assert %{cap: 3, used: 1, label: "ryan-oryx-pro"} = walk.nodes["oryx"]
      assert [%{nodes: [["oryx"], ["local"]]}] = walk.candidates.(card(ticket))

      plan = Scheduler.plan(%{ready: [card(ticket)], running: [], walk: walk})

      assert plan.promote == ticket.id
      assert [%{node: "oryx", pool: {account_id, "claude"}}] = plan.placements
      assert account_id == claude.id
    end
  end
end
