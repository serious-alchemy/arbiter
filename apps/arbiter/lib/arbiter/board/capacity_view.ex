defmodule Arbiter.Board.CapacityView do
  @moduledoc """
  The read model behind every budget display (DC5, bd-2c2a4g;
  `docs/design/provider-dynamic-concurrency.md` §9): the board's capacity
  strip and its popups, `arb scheduler status` / `scheduler_status` /
  `GET /api/scheduler/status`, and `quota_get`'s `budget` block.

  It **only reads**: the budgets `Arbiter.Quota.Budget.Server` published, the
  seats held (`Arbiter.Quota.Seats`), the primary's and the nodes' capacity,
  and the admission shadow's own records. Nothing here decides a dispatch and
  nothing on an admission path calls it (I1, I2, I8; pinned by
  `Arbiter.Quota.BudgetShadowTest`). Every surface goes through this one
  function so the same pool reads the same everywhere.

  ## Shape (`status/1`)

      %{
        admission: %{mode: "shadow", label: "shadow", decides: false, agreement: nil | %{...}},
        pools: [pool],        # one per (account, pool); Budget.to_json/1 plus the display fields
        machines: [machine],  # the primary, then every node
        repos: [],            # DC9 (the repo cap) fills these
        fair_share: []        # DC10 (workspace fair share) fills these
      }

  A pool's `state` is `free`, `full`, `held_pace` (budget 0 because a quota
  window is ahead of its line) or `held_hard` (budget 0 by a hard rule: paused,
  provider refusing, quota stop, unavailable, no reading). `decides` is true
  only under `enforce`: under `legacy` and `shadow` the budgets are shown, but
  today's gate and caps still decide.

  Options (all seams): `:mode`, `:budgets`, `:holders`, `:accounts`, `:local`,
  `:nodes`, `:remote_available?`, `:changes`, `:agreement`.
  """

  require Ash.Query

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Board.AdmissionShadowEvent
  alias Arbiter.Board.WalkInputs
  alias Arbiter.Nodes.LocalCapacity
  alias Arbiter.Nodes.Overview
  alias Arbiter.Nodes.Placement
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server, as: BudgetServer
  alias Arbiter.Quota.Seats

  @hard_zero ~w(paused provider_refusing weekly_warning quota_stop unavailable no_reading error)
  @recent_changes 5

  @doc "The whole view: admission, pools, machines, repos and fair share."
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    mode = mode(opts)

    %{
      admission: admission(mode, opts),
      pools: pools(opts),
      machines: machines(opts),
      repos: [],
      fair_share: []
    }
  end

  @doc "Just the admission block of `status/1`."
  @spec admission(keyword()) :: map()
  def admission(opts \\ []), do: admission(mode(opts), opts)

  @doc """
  The pools of the given accounts, grouped by account, for `quota_get`'s
  `budget` block: `[%{account:, account_id:, mode:, decides:, pools: [pool]}]`
  in the order the ids were given. An account with nothing published has no
  pools.
  """
  @spec account_blocks([String.t()], keyword()) :: [map()]
  def account_blocks(account_ids, opts \\ []) do
    mode = mode(opts)
    accounts = accounts(opts)
    pools = pools(opts)

    for id <- account_ids do
      %{
        account: account_name(Map.get(accounts, id), id),
        account_id: id,
        mode: Atom.to_string(mode),
        decides: mode == :enforce,
        pools: Enum.filter(pools, &(&1.account == id))
      }
    end
  end

  # ---- admission --------------------------------------------------------------

  defp mode(opts) do
    case Keyword.fetch(opts, :mode) do
      {:ok, mode} -> mode
      :error -> safe(fn -> Arbiter.Settings.scheduler_admission() end, :legacy)
    end
  end

  defp admission(mode, opts) do
    %{
      mode: Atom.to_string(mode),
      label: Atom.to_string(mode),
      decides: mode == :enforce,
      agreement: agreement(mode, opts)
    }
  end

  # How often the new walk and today's plan agreed, since the first record of
  # this mode. Read off the hold-change rows `Arbiter.Board.AdmissionShadow`
  # writes; the full comparison is DC7's report.
  defp agreement(mode, opts) when mode in [:shadow, :enforce] do
    case Keyword.fetch(opts, :agreement) do
      {:ok, agreement} -> agreement
      :error -> safe(fn -> read_agreement(Atom.to_string(mode)) end, nil)
    end
  end

  defp agreement(_legacy, _opts), do: nil

  defp read_agreement(policy) do
    comparable =
      AdmissionShadowEvent
      |> Ash.Query.filter(policy == ^policy and comparable == true)
      |> Ash.read!()

    case comparable do
      [] ->
        nil

      rows ->
        %{
          comparable: length(rows),
          agrees: Enum.count(rows, & &1.agrees),
          since: rows |> Enum.map(& &1.at) |> Enum.min(DateTime)
        }
    end
  end

  # ---- pools --------------------------------------------------------------------

  defp pools(opts) do
    accounts = accounts(opts)
    holders = Keyword.get_lazy(opts, :holders, &Seats.holders/0)
    changes = Keyword.get(opts, :changes, &read_changes/1)

    opts
    |> Keyword.get_lazy(:budgets, &BudgetServer.all/0)
    |> Enum.filter(&(&1.policy_workspace == nil))
    |> Enum.map(&pool(&1, Map.get(accounts, &1.account), holders, changes))
    |> Enum.sort_by(&{&1.account_name, &1.pool})
  end

  defp pool(%Budget{} = b, account, holders, changes) do
    name = account_name(account, b.account)
    label = WalkInputs.pool_label(account, b.pool)
    held = Map.get(holders, {b.account, b.pool}, [])

    # Seats are live (`Seats.holders/0`), never the count the budget was computed with.
    b = %{b | seats: length(held), free: free(b.budget, length(held))}

    b
    |> Budget.to_json()
    |> Map.merge(%{
      account_name: name,
      label: label,
      chip_label: chip_label(label),
      state: state(b),
      holders: held,
      recent_changes: changes.({b.account, b.pool, b.policy_workspace}),
      change_command: "arb account set #{name} --max-concurrent N"
    })
  end

  # "antigravity:default gemini" -> "agy gemini"; "claude:default" -> "claude".
  defp chip_label(label) do
    label
    |> String.replace_prefix("antigravity", "agy")
    |> String.replace(":default", "")
  end

  defp free(:unlimited, _seats), do: :unlimited
  defp free(budget, seats), do: max(budget - seats, 0)

  defp state(%Budget{budget: :unlimited}), do: "free"

  defp state(%Budget{budget: 0, binding: binding}) do
    if Budget.binding_text(binding) in @hard_zero, do: "held_hard", else: "held_pace"
  end

  defp state(%Budget{budget: budget, seats: seats}) when seats >= budget, do: "full"
  defp state(_budget), do: "free"

  defp read_changes({account, pool, workspace}),
    do: account |> BudgetServer.changes(pool, workspace) |> Enum.take(@recent_changes)

  defp accounts(opts) do
    opts |> Keyword.get_lazy(:accounts, &read_accounts/0) |> Map.new(&{&1.id, &1})
  end

  defp read_accounts do
    safe(
      fn -> ProviderAccount |> Ash.Query.filter(is_nil(deleted_at)) |> Ash.read!() end,
      []
    )
  end

  defp account_name(%ProviderAccount{provider: provider, slug: slug}, _id),
    do: "#{provider}:#{slug}"

  defp account_name(nil, id), do: id

  # ---- machines -----------------------------------------------------------------

  defp machines(opts) do
    local = Keyword.get_lazy(opts, :local, &local/0)
    [machine("local", "local", local.cap, local.used, "online") | nodes(opts)]
  end

  defp local do
    %{cap: LocalCapacity.cap().cap, used: length(LocalCapacity.holders())}
  end

  defp nodes(opts) do
    remote? = Keyword.get_lazy(opts, :remote_available?, &Placement.remote_execution_available?/0)

    if remote? do
      opts
      |> Keyword.get_lazy(:nodes, &Overview.node_rows/0)
      |> Enum.map(fn row ->
        machine(
          row.id,
          Map.get(row, :name) || row.id,
          Map.get(row, :max),
          Map.get(row, :live) || 0,
          to_string(Map.get(row, :state))
        )
      end)
    else
      []
    end
  end

  defp machine(id, name, cap, live, state) do
    %{
      id: id,
      name: name,
      cap: cap,
      live: live,
      free: if(is_integer(cap), do: max(cap - live, 0)),
      state: state
    }
  end

  defp safe(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
