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

  # bd-21r811: no podman secret carries a scoped git key to a node, so the walk
  # must not offer a node to an implementer whose repo has one.
  describe "a repo with a scoped git credential" do
    @scoped %{
      "git_credentials" => %{
        "repos" => %{"tonic" => %{"kind" => "deploy_key", "key_secret" => "TONIC_KEY"}}
      }
    }
    @rows [%{id: "oryx", name: "oryx", state: :online, health: :ready, max: 3, live: 0}]

    defp scoped_walk(mode, creds, issue_attrs \\ %{}) do
      ws =
        workspace!(
          Map.merge(creds, %{
            "worker" => %{"placement" => mode},
            "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
          })
        )

      claude = account!(:claude, "default")
      link!(ws, claude)
      ticket = issue!(ws, Map.merge(%{repo: "tonic"}, issue_attrs))

      walk =
        gather(ws, [ticket],
          budgets: [budget(claude, "claude", 9)],
          remote_available?: true,
          nodes: @rows
        )

      {ticket, walk}
    end

    test "prefer_remote: the implementer is offered the primary only" do
      {ticket, walk} = scoped_walk("prefer_remote", @scoped)
      assert [%{nodes: [["local"]]}] = walk.candidates.(card(ticket))
    end

    test "remote_only: the implementer has no machine, and the explainer names why" do
      {ticket, walk} = scoped_walk("remote_only", @scoped)
      assert [%{nodes: [], hold: :scoped_git_credential}] = walk.candidates.(card(ticket))

      plan = Scheduler.plan(%{ready: [card(ticket)], running: [], walk: walk})
      assert plan.promote == nil
      assert inspect(plan) =~ "scoped git credential"
    end

    test "an inspect-only (research) run stays remote-eligible" do
      {ticket, walk} = scoped_walk("prefer_remote", @scoped, %{issue_type: :research})
      assert [%{nodes: [["oryx"], ["local"]]}] = walk.candidates.(card(ticket))
    end

    test "a repo on legacy_operator places as before" do
      legacy = %{"git_credentials" => %{"legacy_operator" => true}}
      {ticket, walk} = scoped_walk("prefer_remote", legacy)
      assert [%{nodes: [["oryx"], ["local"]]}] = walk.candidates.(card(ticket))

      {ticket, walk} = scoped_walk("remote_only", legacy)
      assert [%{nodes: [["oryx"]]}] = walk.candidates.(card(ticket))
    end
  end

  # DC9 (bd-7oy77e): the repo cap, `worker.repos.<repo>.max_concurrent`.
  describe "the repo layer" do
    @capped %{"worker" => %{"repos" => %{"vstim" => %{"max_concurrent" => 2}}}}

    test "a capped repo is a set with its runs now; an uncapped one is absent" do
      ws =
        workspace!(%{
          "worker" => %{
            "repos" => %{"vstim" => %{"max_concurrent" => 2}, "arbiter" => %{"seed_paths" => []}}
          }
        })

      walk = gather(ws, [], budgets: [], repo_counts: %{{ws.id, "vstim"} => 1})

      assert walk.repos == %{{ws.id, "vstim"} => %{cap: 2, used: 1, label: "vstim"}}
    end

    test "no cap anywhere: no repo set, and no run is counted" do
      ws = workspace!()
      other = workspace!(%{"worker" => %{"repos" => %{"vstim" => %{"seed_paths" => []}}}})
      boom = fn -> raise "the repo cap is unset: nothing to count" end
      ticket = issue!(ws, %{repo: "vstim"})

      walk = gather(ws, [ticket], budgets: [], repo_counts: boom)
      assert walk.repos == %{}

      # The workspace's candidates name no repo either.
      assert [%{pool: {:unmetered, "claude"}} = candidate] = walk.candidates.(card(ticket))
      refute Map.has_key?(candidate, :repo)
      assert gather(other, [], budgets: [], repo_counts: boom).repos == %{}
    end

    test "a card's candidates name its (workspace, repo)" do
      ws = workspace!(@capped)
      ticket = issue!(ws, %{repo: "vstim"})

      walk = gather(ws, [ticket], budgets: [], repo_counts: %{})

      assert [%{repo: repo}] = walk.candidates.(card(ticket))
      assert repo == {ws.id, "vstim"}
    end

    test "the walk skips a card whose repo is at its cap and places the next card" do
      ws = workspace!(@capped)
      full = issue!(ws, %{repo: "vstim", priority: 1})
      other = issue!(ws, %{repo: "elsewhere", priority: 2})

      walk =
        gather(ws, [full, other], budgets: [], repo_counts: %{{ws.id, "vstim"} => 2})

      plan = Scheduler.plan(%{ready: [card(full), card(other)], running: [], walk: walk})

      assert plan.promote == other.id

      assert %{state: :blocked, wait_cause: {:capacity, :repo}, reason: reason} =
               Enum.find(plan.entries, &(&1.id == full.id))

      assert reason == "repo vstim: 2 of 2 implementer runs"
    end

    test "a repo with room places the card and counts it for the next" do
      ws = workspace!(@capped)
      a = issue!(ws, %{repo: "vstim", priority: 1})
      b = issue!(ws, %{repo: "vstim", priority: 2})
      c = issue!(ws, %{repo: "vstim", priority: 3})

      walk = gather(ws, [a, b, c], budgets: [], repo_counts: %{{ws.id, "vstim"} => 1})
      plan = Scheduler.plan(%{ready: Enum.map([a, b, c], &card/1), running: [], walk: walk})

      assert plan.promote == a.id

      assert %{state: :blocked, wait_cause: {:capacity, :repo}} =
               Enum.find(plan.entries, &(&1.id == b.id))
    end
  end

  describe "workspace fair share (DC10)" do
    defp fair_setup(split) do
      a = workspace!()
      b = workspace!()
      claude = account!(:claude, "shared", %{budget_split: split})
      link!(a, claude, %{weight: 3})
      link!(b, claude)
      {a, b, claude}
    end

    defp fair_card(issue), do: Map.put(card(issue), :priority, issue.priority)

    test "a fair account's pool carries each workspace's seats, weight and name" do
      {a, b, claude} = fair_setup(:fair)
      held_a = issue!(a)
      held_b = issue!(b)
      key = {claude.id, "claude"}

      walk =
        gather(a, [],
          budgets: [budget(claude, "claude", 4)],
          seats: %{key => 3},
          holders: %{key => [held_a.id, held_a.id <> "#review", held_b.id]}
        )

      assert %{seats: seats, weights: weights, labels: labels} = walk.pools[key].fair
      assert seats == %{a.id => 2, b.id => 1}
      assert weights == %{a.id => 3, b.id => 1}
      assert labels == %{a.id => a.name, b.id => b.name}
    end

    test "a queue account's pool carries no fair share" do
      {a, _b, claude} = fair_setup(:queue)

      walk = gather(a, [], budgets: [budget(claude, "claude", 4)], holders: %{})

      refute Map.has_key?(walk.pools[{claude.id, "claude"}], :fair)
    end

    test "two workspaces on one account: the one at its weighted share yields" do
      {a, b, claude} = fair_setup(:fair)
      key = {claude.id, "claude"}
      running = issue!(a)
      queued_a = issue!(a, %{priority: 2})
      queued_b = issue!(b, %{priority: 2})

      # 4 seats, weights 3:1 → shares 3 and 1. a holds 3, b holds none.
      walk =
        gather(a, [queued_a, queued_b],
          budgets: [budget(claude, "claude", 4)],
          seats: %{key => 3},
          holders: %{key => [running.id, running.id <> "#review", running.id <> ":fixpass"]}
        )

      plan =
        Scheduler.plan(%{
          ready: [fair_card(queued_a), fair_card(queued_b)],
          running: [],
          walk: walk
        })

      assert plan.promote == queued_b.id

      assert %{wait_cause: {:capacity, :provider}, reason: reason} =
               Enum.find(plan.entries, &(&1.id == queued_a.id))

      assert reason =~ "fair share"
    end

    test "on a queue account the same board is decided by the order" do
      {a, b, claude} = fair_setup(:queue)
      key = {claude.id, "claude"}
      queued_a = issue!(a, %{priority: 2})
      queued_b = issue!(b, %{priority: 2})

      walk =
        gather(a, [queued_a, queued_b],
          budgets: [budget(claude, "claude", 4)],
          seats: %{key => 3},
          holders: %{}
        )

      plan =
        Scheduler.plan(%{
          ready: [fair_card(queued_a), fair_card(queued_b)],
          running: [],
          walk: walk
        })

      assert plan.promote == queued_a.id
    end
  end
end
