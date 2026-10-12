defmodule Arbiter.Accounts.SeatCheck do
  @moduledoc """
  The per-pool seat check (DC8, bd-30d5qo; `docs/design/provider-dynamic-concurrency.md`
  §3.2, §4.4, §6): may one more seat start on an account's pool?

      seats(account, pool) < min(budget, max_concurrent, share)

    * **`budget`** — the pool's published `Arbiter.Quota.Budget`
      (`Arbiter.Quota.Budget.Server`): the workspace's policy variant when the
      workspace sets its own `quota` config, else the account's own. A card whose
      own priority the account exempts from the paced line (R7) is held to the
      pool's `exempt_budget` instead. A pool with no published budget (the server
      has not computed yet) leaves the ceilings to decide: an unreadable budget
      fails open to them, as an unreadable count does in `Arbiter.Accounts.Admission`.
    * **`max_concurrent` and `share`** — the account's ceiling and the
      workspace link's share (`Arbiter.Accounts.Concurrency.limit/2`'s terms),
      optional ceilings over the budget (§6). With none set and no budget, the
      pool is unbounded here; the node layer still bounds it.
    * **`seats`** — counted live (`Arbiter.Quota.Seats`), never from a snapshot,
      leaving out the seats of the ticket being admitted (`:exclude_task`).

  A `nil` pool (no predicted model) takes the account's lowest published budget
  and counts that pool's seats (§3.1).

  It decides only under `scheduler_admission: enforce`: `Admission`,
  `Arbiter.Worker.ResumeSlot`, provider and reviewer routing ask it only for an
  account in `enforce` (`Arbiter.Accounts.AdmissionMode`). Under `legacy` and
  `shadow` nothing calls it (I1, `Arbiter.Board.AdmissionLegacyTest`). It reads;
  it never reserves (`Admission` does, under its per-account lock), and nothing
  that stops a run reads it (I8).

  Options: `:workspace_id`, `:pool`, `:priority` (the ticket's own),
  `:exclude_task`, and the seams `:budgets` (a list of `Budget` structs in place
  of the published table), `:holders` (`Seats.holders/0`'s map), `:share` and
  `:workspace` (the policy half `Gate.pace_exempt?/2` narrows the exemption by).
  """

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Board.WalkInputs
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server, as: BudgetServer
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Seats

  @type binding :: :budget | :max_concurrent | :share | nil

  @type info :: %{
          account_id: String.t(),
          account: String.t(),
          pool: String.t() | nil,
          label: String.t(),
          limit: non_neg_integer() | :unlimited,
          budget: non_neg_integer() | :unlimited | nil,
          exempt?: boolean(),
          max_concurrent: pos_integer() | nil,
          share: pos_integer() | nil,
          binding: binding(),
          seats: non_neg_integer(),
          holders: [String.t()],
          reason: String.t() | nil
        }

  @doc """
  `{:ok, info}` while the pool has a free seat, `{:full, info}` when it has
  none. See the moduledoc for the terms and options.
  """
  @spec check(ProviderAccount.t(), keyword()) :: {:ok, info()} | {:full, info()}
  def check(%ProviderAccount{} = account, opts \\ []) do
    ws_id = Keyword.get(opts, :workspace_id)
    budget = find_budget(account, Keyword.get(opts, :pool), ws_id, opts)
    pool = Keyword.get(opts, :pool) || pool_of(budget, account)
    exempt? = exempt?(account, ws_id, budget, Keyword.get(opts, :priority), opts)
    budget_value = budget_value(budget, exempt?)
    share = Keyword.get_lazy(opts, :share, fn -> Resolver.share(ws_id, account.provider) end)
    {limit, binding} = limit(budget_value, account.max_concurrent, share)
    holders = holders(account.id, pool, Keyword.get(opts, :exclude_task), opts)

    info = %{
      account_id: account.id,
      account: label(account),
      pool: pool,
      label: WalkInputs.pool_label(account, pool),
      limit: limit,
      budget: budget_value,
      exempt?: exempt?,
      max_concurrent: account.max_concurrent,
      share: share,
      binding: binding,
      seats: length(holders),
      holders: holders,
      reason: budget && budget.reason
    }

    if free?(limit, length(holders)), do: {:ok, info}, else: {:full, info}
  end

  @doc "Whether `check/2` finds a free seat."
  @spec room?(ProviderAccount.t(), keyword()) :: boolean()
  def room?(%ProviderAccount{} = account, opts \\ []), do: match?({:ok, _}, check(account, opts))

  @doc """
  One line for a held card or a refusal: the pool, its seats against the
  limit, and what binds it — `claude:default: 3 of 3 seats (5h binds)`,
  `claude:default: 2 of 2 seats (max_concurrent 2)`.
  """
  @spec describe(info()) :: String.t()
  def describe(%{label: label, seats: seats, limit: limit} = info) do
    "#{label}: #{seats} of #{limit_text(limit)} seats (#{why(info)})"
  end

  # ---- the terms --------------------------------------------------------------

  defp find_budget(account, pool, ws_id, opts) do
    budgets = Keyword.get(opts, :budgets)
    variant = ws_id && lookup(budgets, account.id, pool, ws_id)
    variant || lookup(budgets, account.id, pool, nil)
  end

  defp lookup(nil, account_id, pool, policy_ws),
    do: BudgetServer.lookup(account_id, pool, policy_ws)

  defp lookup(budgets, account_id, nil, policy_ws) when is_list(budgets) do
    budgets
    |> Enum.filter(&(&1.account == account_id and &1.policy_workspace == policy_ws))
    |> Budget.lowest()
  end

  defp lookup(budgets, account_id, pool, policy_ws) when is_list(budgets) do
    Enum.find(
      budgets,
      &(&1.account == account_id and &1.pool == pool and &1.policy_workspace == policy_ws)
    )
  end

  defp pool_of(%Budget{pool: pool}, _account) when is_binary(pool), do: pool

  defp pool_of(_budget, %ProviderAccount{provider: provider}),
    do: ModelFamily.classify(provider, nil).pool

  # R7: the exempt budget binds an own-priority-exempt card, when the pool has one.
  defp exempt?(account, ws_id, %Budget{exempt_budget: exempt}, priority, opts)
       when is_integer(exempt) and is_integer(priority) do
    workspace = Keyword.get_lazy(opts, :workspace, fn -> workspace(ws_id) end)
    Gate.pace_exempt?({account, workspace}, priority)
  end

  defp exempt?(_account, _ws_id, _budget, _priority, _opts), do: false

  # `Gate.pace_exempt?/2` reads the workspace's `quota` config to narrow the
  # account's grant; an unreadable workspace narrows nothing.
  defp workspace(nil), do: nil

  defp workspace(ws_id) do
    case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp budget_value(nil, _exempt?), do: nil
  defp budget_value(%Budget{exempt_budget: exempt}, true), do: exempt
  defp budget_value(%Budget{budget: budget}, false), do: budget

  # `min` over the terms that are set; the first one at the minimum names the
  # binding, the budget ahead of the ceilings.
  defp limit(budget, max_concurrent, share) do
    [budget: budget, max_concurrent: max_concurrent, share: share]
    |> Enum.filter(fn {_term, value} -> is_integer(value) end)
    |> case do
      [] -> {:unlimited, nil}
      terms -> terms |> Enum.min_by(&elem(&1, 1)) |> then(fn {term, n} -> {n, term} end)
    end
  end

  defp free?(:unlimited, _seats), do: true
  defp free?(limit, seats), do: seats < limit

  defp holders(account_id, pool, exclude, opts) do
    opts
    |> Keyword.get_lazy(:holders, &Seats.holders/0)
    |> Map.get({account_id, pool}, [])
    |> Enum.reject(&(is_binary(exclude) and Seats.base_task_id(&1) == exclude))
  end

  # ---- words ------------------------------------------------------------------

  defp label(%ProviderAccount{provider: provider, slug: slug}), do: "#{provider}:#{slug}"

  defp limit_text(:unlimited), do: "unlimited"
  defp limit_text(n), do: Integer.to_string(n)

  defp why(%{binding: :max_concurrent, max_concurrent: n}), do: "max_concurrent #{n}"
  defp why(%{binding: :share, share: n}), do: "this workspace's share #{n}"
  defp why(%{binding: :budget, exempt?: true} = info), do: "exempt budget; " <> reason(info)
  defp why(%{budget: nil}), do: "no published budget"
  defp why(info), do: reason(info)

  defp reason(%{reason: reason}) when is_binary(reason) and reason != "", do: reason
  defp reason(%{budget: budget}), do: "budget #{inspect(budget)}"
end
