defmodule Arbiter.Board.CapacityViewTest do
  @moduledoc """
  DC5 (bd-2c2a4g; `docs/design/provider-dynamic-concurrency.md` §9):
  `Arbiter.Board.CapacityView`, the one read model behind the board's capacity
  strip, `arb scheduler status` / `scheduler_status` and `quota_get`'s budget.
  It only reads: the budgets the server published, the seats held, the
  machines. Nothing it returns decides a dispatch.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Board.AdmissionShadowEvent
  alias Arbiter.Board.CapacityView
  alias Arbiter.Quota.Budget

  @acct "acct-claude"
  @agy "acct-agy"

  @accounts [
    %ProviderAccount{id: @acct, provider: :claude, slug: "default"},
    %ProviderAccount{id: @agy, provider: :antigravity, slug: "default"}
  ]

  defp budget(overrides) do
    struct!(
      %Budget{
        account: @acct,
        pool: "claude",
        budget: 3,
        seats: 3,
        free: 0,
        binding: :ceiling,
        reason: "ceiling max_concurrent 3 (quota allows 4: 5h binds)",
        ceiling: %{max_concurrent: 3, share: nil},
        computed_at: ~U[2026-10-10 01:40:27Z]
      },
      overrides
    )
  end

  defp status(opts \\ []) do
    base = [
      budgets: [
        budget([]),
        budget(
          account: @agy,
          pool: "antigravity:gemini_models",
          budget: 0,
          seats: 0,
          free: 0,
          binding: {:window, "weekly"},
          reason: "weekly 0.43 used ≥ line 0.42"
        ),
        budget(
          account: @agy,
          pool: "antigravity:claude_and_gpt_models",
          budget: 4,
          seats: 0,
          free: 4,
          binding: {:window, "5h"},
          reason: "5h: room for 4.6 (prior)"
        )
      ],
      holders: %{{@acct, "claude"} => ["bd-aaa", "bd-bbb", "bd-ccc"]},
      accounts: @accounts,
      local: %{cap: 6, used: 3},
      nodes: [],
      mode: :shadow,
      agreement: nil,
      changes: fn _key -> [] end
    ]

    CapacityView.status(Keyword.merge(base, opts))
  end

  defp pool(view, account, pool),
    do: Enum.find(view.pools, &(&1.account == account and &1.pool == pool))

  describe "pools" do
    test "one entry per pool with the integer, the reason and the seats" do
      view = status()
      assert length(view.pools) == 3

      claude = pool(view, @acct, "claude")
      assert claude.budget == 3
      assert claude.seats == 3
      assert claude.free == 0
      assert claude.reason =~ "ceiling max_concurrent 3"
      assert claude.binding == "ceiling"
      assert claude.account_name == "claude:default"
      assert claude.holders == ["bd-aaa", "bd-bbb", "bd-ccc"]
      assert claude.windows == []
    end

    test "labels pools the way the strip names them: claude, agy gemini, agy claude-gpt" do
      view = status()
      assert pool(view, @acct, "claude").chip_label == "claude"
      assert pool(view, @agy, "antigravity:gemini_models").chip_label == "agy gemini"
      assert pool(view, @agy, "antigravity:claude_and_gpt_models").chip_label == "agy claude-gpt"
    end

    test "a non-default account slug is part of the label" do
      view =
        status(
          accounts: [%ProviderAccount{id: @acct, provider: :claude, slug: "work"}],
          budgets: [budget([])]
        )

      assert [%{chip_label: "claude:work", account_name: "claude:work"}] = view.pools
    end

    test "state: free, full, held by pace, held by a hard rule" do
      view =
        status(
          holders: %{{@acct, "free"} => ["a"], {@acct, "full"} => ["a", "b", "c"]},
          budgets: [
            budget(pool: "free", budget: 3, binding: :ceiling),
            budget(pool: "full", budget: 3, binding: :ceiling),
            budget(pool: "pace", budget: 0, seats: 0, binding: {:window, "7d"}),
            budget(pool: "paused", budget: 0, seats: 0, binding: :paused)
          ]
        )

      states = Map.new(view.pools, &{&1.pool, &1.state})

      assert states == %{
               "free" => "free",
               "full" => "full",
               "pace" => "held_pace",
               "paused" => "held_hard"
             }
    end

    test "an unlimited pool is free and renders \"unlimited\"" do
      view =
        status(
          budgets: [budget(budget: :unlimited, free: :unlimited, seats: 5, binding: :unmetered)]
        )

      assert [%{budget: "unlimited", state: "free"}] = view.pools
    end

    test "a policy workspace's budget is not a pool of its own" do
      view = status(budgets: [budget([]), budget(policy_workspace: "ws-1", budget: 1)])
      assert length(view.pools) == 1
    end

    test "carries the recent changes and the command that changes the ceiling" do
      change = %{at: ~U[2026-10-10 02:00:00Z], from: 4, to: 3, reason: "5h line"}

      view =
        status(
          changes: fn
            {@acct, "claude", nil} -> [change]
            _ -> []
          end
        )

      claude = pool(view, @acct, "claude")
      assert claude.recent_changes == [change]
      assert claude.change_command =~ "arb account set claude:default --max-concurrent"
    end

    test "carries a pending rise and the exempt budget" do
      since = ~U[2026-10-10 02:00:00Z]

      view =
        status(budgets: [budget(exempt_budget: 5, pending_rise: %{raw: 4.6, since: since})])

      assert [%{exempt_budget: 5, pending_rise: %{since: ^since}}] = view.pools
    end

    test "is JSON-encodable" do
      assert {:ok, _} = Jason.encode(status())
    end
  end

  describe "machines" do
    test "the primary is a machine with its cap, live runs and free slots" do
      assert [%{id: "local", name: "local", cap: 6, live: 3, free: 3}] = status().machines
    end

    test "every node follows, with its state" do
      nodes = [
        %{id: "n1", name: "box", max: 4, live: 1, state: :online},
        %{id: "n2", name: "gone", max: 2, live: 0, state: :offline}
      ]

      view = status(nodes: nodes, remote_available?: true)

      assert [%{id: "local"}, %{name: "box", cap: 4, live: 1, free: 3, state: "online"}, offline] =
               view.machines

      assert offline.state == "offline"
    end

    test "nodes are left out while remote execution is off" do
      nodes = [%{id: "n1", name: "box", max: 4, live: 1, state: :online}]
      assert [%{id: "local"}] = status(nodes: nodes, remote_available?: false).machines
    end

    test "free never goes below zero" do
      assert [%{free: 0, live: 4}] = status(local: %{cap: 2, used: 4}).machines
    end
  end

  describe "repos and fair share" do
    test "are empty until DC9/DC10 give them a cap" do
      view = status()
      assert view.repos == []
      assert view.fair_share == []
    end
  end

  describe "admission" do
    test "shadow is labelled shadow and decides nothing" do
      assert %{mode: "shadow", label: "shadow", decides: false} = status().admission
    end

    test "legacy and enforce" do
      assert %{mode: "legacy", label: "legacy", decides: false} =
               status(mode: :legacy).admission

      assert %{mode: "enforce", label: "enforce", decides: true} =
               status(mode: :enforce).admission
    end

    test "carries the shadow agreement when given one" do
      agreement = %{comparable: 52, agrees: 47, since: ~U[2026-10-12 00:00:00Z]}
      assert %{agreement: ^agreement} = status(agreement: agreement).admission
    end

    test "agreement is read from the admission shadow events of the current mode" do
      record = fn attrs ->
        Ash.create!(
          AdmissionShadowEvent,
          Map.merge(
            %{
              at: DateTime.utc_now(),
              policy: "shadow",
              agrees: true,
              comparable: true,
              legacy: %{},
              walk: %{},
              budgets: []
            },
            attrs
          ),
          action: :record
        )
      end

      early = ~U[2026-10-01 00:00:00.000000Z]
      record.(%{at: early})
      record.(%{agrees: false})
      record.(%{comparable: false, agrees: false})
      record.(%{policy: "enforce"})

      view =
        CapacityView.status(
          budgets: [],
          holders: %{},
          accounts: [],
          local: %{cap: 1, used: 0},
          nodes: [],
          mode: :shadow
        )

      assert %{comparable: 2, agrees: 1, since: since} = view.admission.agreement
      assert DateTime.compare(since, early) == :eq
    end

    test "no agreement under legacy, and none before any event" do
      assert status(mode: :legacy).admission.agreement == nil

      view =
        CapacityView.status(
          budgets: [],
          holders: %{},
          accounts: [],
          local: %{cap: 1, used: 0},
          nodes: [],
          mode: :shadow
        )

      assert view.admission.agreement == nil
    end
  end

  describe "account_blocks/2 (quota_get)" do
    test "one block per account, with its pools and the mode" do
      blocks =
        CapacityView.account_blocks(
          [@acct, @agy],
          budgets: status_budgets(),
          holders: %{},
          accounts: @accounts,
          mode: :shadow,
          changes: fn _ -> [] end
        )

      assert [claude, agy] = blocks
      assert %{account: "claude:default", account_id: @acct, mode: "shadow"} = claude
      assert [%{pool: "claude", budget: 3}] = claude.pools
      assert length(agy.pools) == 2
    end

    test "an account with no published budget yields an empty pool list" do
      assert [%{account_id: "nope", pools: []}] =
               CapacityView.account_blocks(["nope"],
                 budgets: [],
                 holders: %{},
                 accounts: [],
                 mode: :legacy,
                 changes: fn _ -> [] end
               )
    end
  end

  defp status_budgets do
    [
      budget([]),
      budget(account: @agy, pool: "antigravity:gemini_models", budget: 0),
      budget(account: @agy, pool: "antigravity:claude_and_gpt_models", budget: 4)
    ]
  end
end
