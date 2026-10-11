defmodule Arbiter.Loop.Replay.Admission do
  @moduledoc """
  An offline replay spends only quota that would expire (R15, bd-c7lx65;
  `docs/design/paced-quota-routing-signals.md` §7.3, re-scoped by
  `docs/design/provider-dynamic-concurrency.md` §8).

  Expiring headroom has one definition, the budget's: `Budget.expiring/2`, what
  would reset unused at the current seats. Exploration may take at most half
  of it, which is `Budget.explore/2`: `floor(min over windows of expiring /
  (2·ρ·H))` seats. A replay holds one seat on every pool it draws on (the
  replayed model's, and the scoring reviewer's), from admission to its end, so
  it is admitted only while, on each of those pools,

      replays already running + 1 ≤ explore(budget)

  The budget is the one `Arbiter.Quota.Budget.Server` publishes in the live
  node (`published/3`), computed at the live seats, which do not include
  replays: exploration is bounded by what live work leaves unused, and the
  replays running count against it here. Quota near its line, a hard zero
  (paused, the provider refusing, a quota stop, auth or circuit trouble), a
  window with no reading and a pool with no published budget all give
  `explore = 0`, so no replay. Nothing here holds or admits live work.
  """

  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server, as: BudgetServer

  @type pool_key :: {account_id :: String.t(), pool :: String.t()}
  @type budget_fun :: (String.t(), String.t() -> Budget.t() | nil)

  @type entry :: %{
          account_id: String.t(),
          pool: String.t(),
          explore: non_neg_integer(),
          running: non_neg_integer(),
          admitted: boolean(),
          binding: String.t() | nil,
          expiring: %{String.t() => float()},
          reason: String.t()
        }

  @doc """
  Whether a replay drawing on `pools` may start. `budget_fun` returns each
  pool's budget (`published/3` in the live node), `running` the replays already
  running per pool (`running/1`). A pool listed twice (the replayed model and
  the reviewer on one pool) is one seat. Returns every pool's entry, for the
  record; a refusal names the first pool that has no room.
  """
  @spec check([pool_key()], budget_fun(), %{pool_key() => non_neg_integer()}) ::
          {:ok, [entry()]} | {:refused, String.t(), [entry()]}
  def check(pools, budget_fun, running \\ %{}) when is_function(budget_fun, 2) do
    entries =
      pools
      |> Enum.uniq()
      |> Enum.map(fn {account_id, pool} = key ->
        entry(account_id, pool, budget_fun.(account_id, pool), Map.get(running, key, 0))
      end)

    case Enum.reject(entries, & &1.admitted) do
      [] -> {:ok, entries}
      [first | _] -> {:refused, first.reason, entries}
    end
  end

  @doc """
  The published budget for `pool` of `account_id` as it applies in
  `workspace_id`: the workspace's own policy budget when one is published (a
  workspace only ever tightens the account's line), else the account's. `nil`
  where no `Budget.Server` publishes (a `bin/arbiter eval` or mix VM, a test).
  `:table` names another server's ETS table (a test's own).
  """
  @spec published(String.t(), String.t(), String.t() | nil, keyword()) :: Budget.t() | nil
  def published(account_id, pool, workspace_id \\ nil, opts \\ []) do
    get = fn policy_workspace ->
      case Keyword.fetch(opts, :table) do
        {:ok, table} -> BudgetServer.get(account_id, pool, policy_workspace, table)
        :error -> BudgetServer.get(account_id, pool, policy_workspace)
      end
    end

    (workspace_id && get.(workspace_id)) || get.(nil)
  end

  @doc """
  Replays running per pool, from their records (`account_id`/`pool` for the
  replayed model, `reviewer_account_id`/`reviewer_pool` for the scoring
  reviewer). A replay whose two sides share a pool counts once there.
  """
  @spec running([map()]) :: %{pool_key() => non_neg_integer()}
  def running(rows) do
    rows
    |> Enum.flat_map(fn row ->
      [{row.account_id, row.pool}, {row.reviewer_account_id, row.reviewer_pool}]
      |> Enum.filter(fn {account_id, pool} -> is_binary(account_id) and is_binary(pool) end)
      |> Enum.uniq()
    end)
    |> Enum.frequencies()
  end

  defp entry(account_id, pool, nil, running) do
    %{
      account_id: account_id,
      pool: pool,
      explore: 0,
      running: running,
      admitted: false,
      binding: nil,
      expiring: %{},
      reason:
        "no published budget for #{account_id}/#{pool}: a replay reads the budgets the " <>
          "live node publishes, so run it there (bin/arbiter rpc)"
    }
  end

  defp entry(account_id, pool, %Budget{} = budget, running) do
    explore = Budget.explore(budget)
    admitted = running + 1 <= explore

    %{
      account_id: account_id,
      pool: pool,
      explore: explore,
      running: running,
      admitted: admitted,
      binding: Budget.binding_text(budget.binding),
      expiring: expiring(budget),
      reason: reason(account_id, pool, explore, running, budget)
    }
  end

  defp expiring(%Budget{windows: windows} = budget) do
    for %{window: label, status: :ok} <- windows,
        is_binary(label),
        into: %{},
        do: {label, Budget.expiring(budget, label)}
  end

  defp reason(account_id, pool, 0, _running, budget),
    do:
      "#{account_id}/#{pool} has no expiring headroom to explore " <>
        "(binding: #{Budget.binding_text(budget.binding)})"

  defp reason(account_id, pool, explore, running, _budget) when running + 1 > explore,
    do:
      "#{account_id}/#{pool}'s expiring headroom is taken: #{running} replays running " <>
        "against an exploration budget of #{explore}"

  defp reason(account_id, pool, explore, running, _budget),
    do: "#{account_id}/#{pool}: #{explore - running} of #{explore} exploration seats free"
end
