defmodule Arbiter.Accounts.SeatCheck do
  @moduledoc """
  The per-pool seat check (DC8, bd-30d5qo; `docs/design/provider-dynamic-concurrency.md`
  §3.2, §4.4, §6): may one more seat start on an account's pool?

      seats(account, pool) < min(budget, max_concurrent, share)

  with the budget term weighted (DC11, below):

      Σ weights(seats) + w_new ≤ budget      and      seats < min(max_concurrent, share)

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

  **Weighted seats (DC11, bd-8lsfey).** A seat weighs `ρ_m / ρ̄` from R3's
  per-model draw (`Arbiter.Quota.SeatWeights`, calibrated by the budget server),
  so a premium-model seat takes more than one seat-equivalent of the budget. A
  model with no calibrated weight, or none named, weighs 1: with no weights
  calibrated for the pool the check is exactly `seats < budget`. The ceilings
  count seats whatever they weigh (I3). A pool with no seat in use admits one card
  however heavy it weighs, while its budget is at least 1.

  A `nil` pool (no predicted model) takes the account's lowest published budget
  and counts that pool's seats (§3.1).

  It decides only under `scheduler_admission: enforce`: `Admission`,
  `Arbiter.Worker.ResumeSlot`, provider and reviewer routing ask it only for an
  account in `enforce` (`Arbiter.Accounts.AdmissionMode`). Under `legacy` and
  `shadow` nothing calls it (I1, `Arbiter.Board.AdmissionLegacyTest`). It reads;
  it never reserves (`Admission` does, under its per-account lock), and nothing
  that stops a run reads it (I8).

  Options: `:workspace_id`, `:pool`, `:priority` (the ticket's own),
  `:exclude_task`, `:model` (the card's, for its weight), and the seams `:budgets` (a list of `Budget` structs in place
  of the published table), `:holders` (`Seats.seats/0`'s map of `{holder, model}`, or bare holder ids), `:weights`
  (a `%{model => weight}` map, or a function of the window label), `:share` and
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
  alias Arbiter.Quota.SeatWeights

  @epsilon 1.0e-9

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
          load: number(),
          weight: number(),
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
    seated = seated(account.id, pool, Keyword.get(opts, :exclude_task), opts)
    holders = Enum.map(seated, &elem(&1, 0))
    {load, weight} = load(seated, account.id, pool, budget, opts)

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
      load: load,
      weight: weight,
      reason: budget && budget.reason
    }

    if free?(info, budget_value), do: {:ok, info}, else: {:full, info}
  end

  @doc "Whether `check/2` finds a free seat."
  @spec room?(ProviderAccount.t(), keyword()) :: boolean()
  def room?(%ProviderAccount{} = account, opts \\ []), do: match?({:ok, _}, check(account, opts))

  @doc """
  How many more seats like this card's fit on the pool (`:unlimited` when
  nothing bounds it): the ceilings' room in seats, and the budget's room in
  the new seat's weights (DC11). The scheduler walk's capacity for the pool.
  """
  @spec free_seats(info()) :: non_neg_integer() | :unlimited
  def free_seats(%{limit: :unlimited}), do: :unlimited

  def free_seats(%{seats: seats, max_concurrent: max_concurrent, share: share} = info) do
    by_count = for c <- [max_concurrent, share], is_integer(c), do: max(c - seats, 0)
    by_budget = if is_integer(info.budget), do: [budget_room(info)], else: []

    case by_count ++ by_budget do
      [] -> :unlimited
      rooms -> Enum.min(rooms)
    end
  end

  # An empty pool still fits one card, however heavy (see `free?/2`).
  defp budget_room(%{budget: budget, seats: 0} = info) when budget >= 1,
    do: max(fit(info), 1)

  defp budget_room(info), do: max(fit(info), 0)

  defp fit(%{budget: budget, load: load, weight: weight}),
    do: floor((budget - load) / weight + @epsilon)

  @doc """
  The live seat holders per pool (`Arbiter.Quota.Seats.holders/0`), for a caller
  that checks several pools in one decision and passes them as `:holders`, so
  the registry and the tickets are read once rather than once per pool.
  """
  @spec holders() :: %{Seats.pool_key() => [{String.t(), String.t() | nil}]}
  def holders, do: Seats.seats()

  @doc """
  A pool held at a **hard zero** (§3.5) by a rule the quota gate still keeps
  under `enforce` — the provider refusing, a weekly warning on hold — shaped as
  a full check with `phrase` as its reason. `Dispatch` refuses a fresh dispatch
  with it before the pool's published budget has caught up with the reading.
  `account` may be `nil` (a provider with no account behind it).
  """
  @spec hard_zero(
          ProviderAccount.t() | nil,
          atom() | String.t() | nil,
          String.t() | nil,
          String.t()
        ) ::
          info()
  def hard_zero(account, provider, pool, phrase) do
    pool = pool || ModelFamily.classify((account && account.provider) || provider, nil).pool

    %{
      account_id: account && account.id,
      account: if(account, do: label(account), else: to_string(provider)),
      pool: pool,
      label: if(account, do: WalkInputs.pool_label(account, pool), else: to_string(provider)),
      limit: 0,
      budget: 0,
      exempt?: false,
      max_concurrent: account && account.max_concurrent,
      share: nil,
      binding: :budget,
      seats: 0,
      holders: [],
      load: 0,
      weight: 1,
      reason: phrase
    }
  end

  @doc """
  One line for a held card or a refusal: the pool, its seats against the
  limit, and what binds it — `claude:default: 3 of 3 seats (5h binds)`,
  `claude:default: 2 of 2 seats (max_concurrent 2)`.
  """
  @spec describe(info()) :: String.t()
  def describe(%{label: label, seats: seats, limit: limit, load: load} = info)
      when load != seats do
    "#{label}: #{seats} seats weighing #{Float.round(load * 1.0, 2)} of #{limit_text(limit)} (#{why(info)})"
  end

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

  # The ceilings count seats (I3); the budget compares the weighted load, with
  # the new seat's weight, against the published budget (DC11). An empty pool
  # admits a card heavier than the budget whenever the budget is at least 1: a
  # model that weighs more than the whole budget must not starve. A hard zero
  # still refuses.
  defp free?(%{seats: seats, load: load, weight: weight} = info, budget_value) do
    ceilings_free? =
      Enum.all?([info.max_concurrent, info.share], &(not is_integer(&1) or seats < &1))

    ceilings_free? and budget_free?(budget_value, seats, load, weight)
  end

  defp budget_free?(budget, _seats, _load, _weight) when not is_integer(budget), do: true
  defp budget_free?(budget, 0, _load, _weight) when budget >= 1, do: true
  defp budget_free?(budget, _seats, load, weight), do: load + weight <= budget + @epsilon

  # `[{holder, model}]` of the pool, the excluded ticket's seats left out. The
  # `:holders` seam may carry bare holder ids (no model known).
  defp seated(account_id, pool, exclude, opts) do
    opts
    |> Keyword.get_lazy(:holders, &Seats.seats/0)
    |> Map.get({account_id, pool}, [])
    |> Enum.map(fn
      {holder, model} -> {holder, model}
      holder -> {holder, nil}
    end)
    |> Enum.reject(fn {holder, _model} ->
      is_binary(exclude) and Seats.base_task_id(holder) == exclude
    end)
  end

  # `{Σ weights, w_new}` (DC11). With no weights calibrated for the pool every
  # seat weighs 1 and this is the seat count: phase 1.
  defp load(seated, account_id, pool, budget, opts) do
    window = budget && budget.quota_binding

    case weights(account_id, pool, window, opts) do
      weights when weights == %{} ->
        {length(seated), 1}

      weights ->
        floor = SeatWeights.floor_ratio(budget)
        weigh = &SeatWeights.weight(weights, &1, floor)
        load = seated |> Enum.map(fn {_holder, model} -> weigh.(model) end) |> Enum.sum()
        {load, weigh.(Keyword.get(opts, :model))}
    end
  end

  # The `:weights` seam is a map, or a function of the window label.
  defp weights(account_id, pool, window, opts) do
    case Keyword.fetch(opts, :weights) do
      {:ok, fun} when is_function(fun, 1) -> fun.(window)
      {:ok, weights} when is_map(weights) -> weights
      _ -> BudgetServer.seat_weights(account_id, pool, window)
    end
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
