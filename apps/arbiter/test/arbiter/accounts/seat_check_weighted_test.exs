defmodule Arbiter.Accounts.SeatCheckWeightedTest do
  @moduledoc """
  DC11 (bd-8lsfey; design `provider-dynamic-concurrency.md` §3.4 phase 2, §8
  R11): under `enforce` the budget term of the seat check compares
  `Σ weights + w_new ≤ budget`, a seat weighing `ρ_m / ρ̄` from R3's per-model
  draw (`Arbiter.Quota.SeatWeights`). The ceilings (`max_concurrent`, `share`)
  still count seats (I3). With no weights the check is phase 1's, unchanged.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.SeatCheck
  alias Arbiter.Quota.Budget

  @ws "ws-1"
  @pool {"acct-1", "claude"}

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
        quota_binding: "5h",
        reason: "5h binds"
      },
      attrs
    )
  end

  defp check(opts, account \\ account()) do
    SeatCheck.check(
      account,
      Keyword.merge([workspace_id: @ws, pool: "claude", share: nil, workspace: nil], opts)
    )
  end

  # Holders as `Seats.seats/0` shapes them: `{holder, model}`.
  defp held(models),
    do: %{
      @pool => models |> Enum.with_index(1) |> Enum.map(fn {model, i} -> {"bd-#{i}", model} end)
    }

  @weights %{"opus" => 2.0, "haiku" => 0.5}

  test "no weights: the weighted check is phase 1's, and the load is the seat count" do
    assert {:ok, %{seats: 2, load: 2, weight: 1}} =
             check(budgets: [budget(3)], holders: held(["opus", "opus"]), weights: %{})

    assert {:full, %{seats: 3, load: 3}} =
             check(budgets: [budget(3)], holders: held(["opus", "opus", "opus"]), weights: %{})
  end

  test "an unweighted model, or none named, weighs 1" do
    opts = [holders: held(["sonnet", nil]), weights: @weights, model: "sonnet"]

    assert {:ok, %{seats: 2, load: 2.0, weight: 1.0}} = check([budgets: [budget(3)]] ++ opts)
    assert {:full, %{seats: 2, load: 2.0}} = check([budgets: [budget(2)]] ++ opts)
  end

  test "heavy seats fill the budget before the seat count does" do
    # Two opus seats weigh 4 of a budget of 5; a third opus seat would make 6.
    assert {:full, %{seats: 2, load: 4.0, weight: 2.0, limit: 5}} =
             check(
               budgets: [budget(5)],
               holders: held(["opus", "opus"]),
               weights: @weights,
               model: "opus"
             )

    # A light card still fits beside them: 4 + 0.5 ≤ 5.
    assert {:ok, %{load: 4.0, weight: 0.5}} =
             check(
               budgets: [budget(5)],
               holders: held(["opus", "opus"]),
               weights: @weights,
               model: "haiku"
             )
  end

  test "light seats leave room past the seat count" do
    assert {:full, _} = check(budgets: [budget(2)], holders: held(["haiku", "haiku"]))

    assert {:ok, %{seats: 2, load: 1.0, weight: 0.5}} =
             check(
               budgets: [budget(2)],
               holders: held(["haiku", "haiku"]),
               weights: @weights,
               model: "haiku"
             )
  end

  test "I3: the ceilings still bound the seats however light they weigh" do
    held = held(["haiku", "haiku"])

    assert {:full, %{binding: :max_concurrent, seats: 2}} =
             check(
               [budgets: [budget(4)], holders: held, weights: @weights, model: "haiku"],
               account(max_concurrent: 2)
             )

    assert {:full, %{binding: :share}} =
             check(
               budgets: [budget(4)],
               holders: held,
               weights: @weights,
               model: "haiku",
               share: 2
             )
  end

  test "no seat weighs less than the floor ρ_min / ρ̄ of the binding window" do
    windows = [%{window: "5h", rho: 0.1, rho_min: 0.04, status: :ok}]

    assert {:ok, %{weight: weight, load: load}} =
             check(
               budgets: [budget(2, windows: windows)],
               holders: held(["tiny"]),
               weights: %{"tiny" => 0.01},
               model: "tiny"
             )

    assert_in_delta weight, 0.4, 1.0e-9
    assert_in_delta load, 0.4, 1.0e-9
  end

  test "the floor defaults to a quarter when the budget names no window rate" do
    assert {:ok, %{weight: 0.25}} =
             check(
               budgets: [budget(2)],
               holders: %{},
               weights: %{"tiny" => 0.01},
               model: "tiny"
             )
  end

  test "an empty pool admits a card heavier than the budget; a hard zero still refuses" do
    heavy = %{"opus" => 3.0}

    assert {:ok, %{weight: 3.0}} =
             check(budgets: [budget(2)], holders: %{}, weights: heavy, model: "opus")

    assert {:full, _} =
             check(
               budgets: [budget(2)],
               holders: held(["haiku"]),
               weights: heavy,
               model: "opus"
             )

    assert {:full, %{limit: 0}} =
             check(
               budgets: [budget(0, binding: :paused)],
               holders: %{},
               weights: heavy,
               model: "opus"
             )
  end

  test "the exempt budget is weighed the same way" do
    exempting = account(quota_config: %{"pace_exempt_priority" => 0})
    pool_budget = budget(1, exempt_budget: 5)

    assert {:ok, %{exempt?: true, load: 4.0}} =
             check(
               [
                 budgets: [pool_budget],
                 holders: held(["opus", "opus"]),
                 weights: @weights,
                 model: "haiku",
                 priority: 0
               ],
               exempting
             )
  end

  test "holders are named by id, and the excluded ticket's own seats are left out" do
    assert {:ok, %{holders: ["bd-2"], seats: 1, load: 2.0}} =
             check(
               budgets: [budget(5)],
               holders: held(["haiku", "opus"]),
               weights: @weights,
               model: "haiku",
               exclude_task: "bd-1"
             )
  end

  test "plain id holders (no model known) weigh 1" do
    assert {:full, %{seats: 2, load: 2.0}} =
             check(
               budgets: [budget(2)],
               holders: %{@pool => ["bd-1", "bd-2"]},
               weights: @weights,
               model: "haiku"
             )
  end

  test "weights are read for the budget's binding window" do
    test = self()

    lookup = fn window ->
      send(test, {:window, window})
      @weights
    end

    assert {:ok, _} =
             check(budgets: [budget(3)], holders: %{}, weights: lookup, model: "opus")

    assert_received {:window, "5h"}
  end

  test "describe/1 says when the seats are weighed" do
    {:full, info} =
      check(
        budgets: [budget(3)],
        holders: held(["opus", "opus"]),
        weights: @weights,
        model: "opus"
      )

    assert SeatCheck.describe(info) =~ "2 seats weighing 4.0 of 3"

    {:full, plain} = check(budgets: [budget(2)], holders: held([nil, nil]))
    assert SeatCheck.describe(plain) =~ "2 of 2 seats"
  end

  describe "free_seats/1: how many more seats of this card fit" do
    defp free(opts, account \\ account()) do
      {_verdict, info} = check(opts, account)
      SeatCheck.free_seats(info)
    end

    test "unweighted it is the limit less the seats; unlimited stays unlimited" do
      assert free(budgets: [budget(5)], holders: held([nil, nil])) == 3
      assert free(budgets: [budget(2)], holders: held([nil, nil, nil])) == 0
      assert free([budgets: [budget(5)], holders: held([nil])], account(max_concurrent: 2)) == 1
      assert free(budgets: [], holders: held([nil])) == :unlimited
    end

    test "weighted it is the budget left over the new seat's weight, bounded by the ceilings" do
      opts = [budgets: [budget(6)], holders: held(["opus"]), weights: @weights]

      # 6 - 2 = 4 of budget left: two more opus seats, eight haiku.
      assert free(opts ++ [model: "opus"]) == 2
      assert free(opts ++ [model: "haiku"]) == 8
      assert free(opts ++ [model: "haiku"], account(max_concurrent: 3)) == 2
    end

    test "an empty pool fits one card heavier than the budget" do
      assert free(budgets: [budget(2)], holders: %{}, weights: %{"opus" => 3.0}, model: "opus") ==
               1
    end
  end
end
