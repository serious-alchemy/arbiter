defmodule Arbiter.Accounts.SeatCheckTest do
  @moduledoc """
  The per-pool seat check (DC8, design `provider-dynamic-concurrency.md` §3.2,
  §4.4, §6): one more seat may start on an account's pool while the seats held
  there are below `min(budget, max_concurrent, share)`. The budget is the pool's
  published one (the workspace's policy variant when it has one, the exempt
  budget for an own-priority-exempt card); the account ceiling and the link
  share are the optional ceilings over it. Everything is read through seams here.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.SeatCheck
  alias Arbiter.Quota.Budget

  @ws "ws-1"

  defp account(attrs \\ []) do
    struct!(
      %ProviderAccount{
        id: "acct-1",
        provider: :claude,
        slug: "default",
        max_concurrent: nil,
        quota_config: %{}
      },
      attrs
    )
  end

  defp budget(n, attrs \\ []) do
    struct!(
      %Budget{
        account: "acct-1",
        pool: "claude",
        policy_workspace: nil,
        budget: n,
        binding: {:window, "5h"},
        reason: "5h binds"
      },
      attrs
    )
  end

  defp holders(n, pool \\ {"acct-1", "claude"}),
    do: %{pool => Enum.map(1..n//1, &"bd-#{&1}")}

  defp check(account, opts),
    do:
      SeatCheck.check(
        account,
        Keyword.merge([workspace_id: @ws, pool: "claude", share: nil, workspace: nil], opts)
      )

  test "a free seat while the seats are below the budget" do
    assert {:ok, info} = check(account(), budgets: [budget(3)], holders: holders(2))
    assert %{limit: 3, budget: 3, seats: 2, pool: "claude", binding: :budget} = info
  end

  test "full at the budget, naming who holds the seats" do
    assert {:full, info} = check(account(), budgets: [budget(2)], holders: holders(2))
    assert %{limit: 2, seats: 2, holders: ["bd-1", "bd-2"], reason: "5h binds"} = info
  end

  test "a budget of 0 is full with no seat held" do
    assert {:full, %{limit: 0, seats: 0}} =
             check(account(), budgets: [budget(0, binding: :paused)], holders: %{})
  end

  test "the account's max_concurrent is a ceiling over the budget" do
    assert {:full, %{limit: 2, binding: :max_concurrent}} =
             check(account(max_concurrent: 2), budgets: [budget(4)], holders: holders(2))
  end

  test "the link's share is a ceiling too: min(budget, max_concurrent, share)" do
    assert {:full, %{limit: 1, binding: :share, share: 1}} =
             check(account(max_concurrent: 3),
               budgets: [budget(4)],
               holders: holders(1),
               share: 1
             )
  end

  test "a budget below the ceilings binds" do
    assert {:full, %{limit: 1, binding: :budget}} =
             check(account(max_concurrent: 3), budgets: [budget(1)], holders: holders(1), share: 2)
  end

  test "an unlimited budget leaves the ceilings, and with none the pool is unbounded" do
    unmetered = budget(:unlimited, binding: :unmetered)

    assert {:full, %{limit: 2}} =
             check(account(max_concurrent: 2), budgets: [unmetered], holders: holders(2))

    assert {:ok, %{limit: :unlimited}} = check(account(), budgets: [unmetered], holders: holders(9))
  end

  test "with no published budget the ceilings decide, and with none it is unbounded" do
    assert {:full, %{limit: 2, budget: nil}} =
             check(account(max_concurrent: 2), budgets: [], holders: holders(2))

    assert {:ok, %{limit: :unlimited, budget: nil}} =
             check(account(), budgets: [], holders: holders(5))
  end

  test "the workspace's policy variant binds when it has one" do
    variant = budget(1, policy_workspace: @ws)

    assert {:full, %{budget: 1}} =
             check(account(), budgets: [budget(4), variant], holders: holders(1))

    assert {:ok, %{budget: 4}} =
             check(account(),
               budgets: [budget(4), variant],
               holders: holders(1),
               workspace_id: "other-ws"
             )
  end

  test "an own-priority-exempt card is held to the exempt budget" do
    exempting = account(quota_config: %{"pace_exempt_priority" => 0})
    pool_budget = budget(1, exempt_budget: 3)

    assert {:full, %{budget: 1, exempt?: false}} =
             check(exempting, budgets: [pool_budget], holders: holders(1), priority: 2)

    assert {:ok, %{budget: 3, exempt?: true}} =
             check(exempting, budgets: [pool_budget], holders: holders(1), priority: 0)
  end

  test "an exempt card on an account that exempts nothing gets the plain budget" do
    assert {:full, %{budget: 1}} =
             check(account(),
               budgets: [budget(1, exempt_budget: 3)],
               holders: holders(1),
               priority: 0
             )
  end

  test "the excluded ticket's own seats are left out of the count" do
    seated = %{{"acct-1", "claude"} => ["bd-1", "bd-1#review-1", "bd-2"]}

    assert {:ok, %{seats: 1, holders: ["bd-2"]}} =
             check(account(), budgets: [budget(2)], holders: seated, exclude_task: "bd-1")
  end

  test "another pool's seats do not count" do
    assert {:ok, %{seats: 0}} =
             check(account(),
               budgets: [budget(1)],
               holders: holders(3, {"acct-1", "other"})
             )
  end

  describe "a nil pool (no predicted model, §3.1)" do
    setup do
      agy = account(provider: :antigravity, slug: "agy")

      budgets = [
        budget(4, pool: "antigravity:gemini_models"),
        budget(1, pool: "antigravity:claude_and_gpt_models")
      ]

      %{agy: agy, budgets: budgets}
    end

    test "takes the account's lowest budget, and counts that pool's seats", ctx do
      seated = holders(1, {"acct-1", "antigravity:claude_and_gpt_models"})

      assert {:full, %{pool: "antigravity:claude_and_gpt_models", budget: 1, seats: 1}} =
               check(ctx.agy, budgets: ctx.budgets, holders: seated, pool: nil)
    end

    test "with no budget at all, the provider's default pool", ctx do
      assert {:ok, %{pool: "antigravity:gemini_models", budget: nil}} =
               check(ctx.agy, budgets: [], holders: %{}, pool: nil)
    end
  end

  test "room?/2 is the check's yes or no" do
    assert SeatCheck.room?(account(),
             workspace_id: @ws,
             pool: "claude",
             share: nil,
             budgets: [budget(2)],
             holders: holders(1)
           )

    refute SeatCheck.room?(account(),
             workspace_id: @ws,
             pool: "claude",
             share: nil,
             budgets: [budget(1)],
             holders: holders(1)
           )
  end

  describe "describe/1" do
    test "names the pool, the seats and what binds" do
      {:full, info} = check(account(), budgets: [budget(2)], holders: holders(2))
      assert SeatCheck.describe(info) =~ "claude:default"
      assert SeatCheck.describe(info) =~ "2 of 2 seats"
      assert SeatCheck.describe(info) =~ "5h binds"
    end

    test "names a ceiling when it binds" do
      {:full, info} = check(account(max_concurrent: 1), budgets: [budget(3)], holders: holders(1))
      assert SeatCheck.describe(info) =~ "max_concurrent 1"
    end
  end
end
