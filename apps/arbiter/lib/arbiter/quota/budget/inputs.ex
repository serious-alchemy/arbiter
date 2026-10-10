defmodule Arbiter.Quota.Budget.Inputs do
  @moduledoc """
  Reads the live state `Arbiter.Quota.Budget.compute/1` needs, one input map per
  (account, pool, policy workspace) (bd-6c8g4t, DC3; design §3.1-§3.6). Used by
  `Arbiter.Quota.Budget.Server`; read-only.

    * **Pools** — one per account, from `ModelFamily.classify/2`; agy has two.
      Each agy pool reads the quota row with a model that picks its bucket
      group (`Snapshot.normalize/2`'s `:model`).
    * **Policy variants** — the account's own policy (`policy_workspace: nil`),
      plus each linked workspace that sets its own `quota` config, because the
      line composes `min(account, workspace)`. Such a variant carries that
      link's `share`.
    * **Seats** — until DC4 stamps pools on the registry, the account's live
      count (`Concurrency.live_count/1`). For agy that counts both pools'
      work against each, which is the safe side.
    * **Hard zeros** — an operator pause or a quota-stop hold
      (`Providers.Pause`), a broken circuit, an open auth hold or an expired
      credential. The quota row's own refusals are read by `Budget` itself.
    * **`ρ`, `b`, `H`** — from `BudgetCalibration.calibrate/0`, run off the server
      at boot and daily; until it has run (and where it has nothing), the prior.
      `b` is used only where the fit measured a seat (rung 0): a degenerate fit
      hands the whole draw to `b`, which would zero the budget.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.ModelFamily
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Providers.Pause
  alias Arbiter.Quota
  alias Arbiter.Quota.BudgetCalibration

  @agy_pools [
    {"antigravity:gemini_models", "gemini-2.5-pro"},
    {"antigravity:claude_and_gpt_models", "claude-sonnet-4-5"}
  ]

  @adapters %{
    claude: {Arbiter.Agents.Claude, :claude},
    codex: {Arbiter.Agents.Codex, :codex},
    antigravity: {Arbiter.Agents.Gemini, :gemini},
    grok: {Arbiter.Agents.Grok, :grok}
  }

  @type calibration :: %{
          rates: %{{String.t(), String.t(), String.t()} => map()},
          background: %{{String.t(), String.t(), String.t()} => float()},
          horizons: %{String.t() => float()}
        }

  @doc "No calibration yet: every window uses its prior, `b` is 0 and `H` is 2 h."
  @spec empty_calibration() :: calibration()
  def empty_calibration, do: %{rates: %{}, background: %{}, horizons: %{}}

  @doc "`BudgetCalibration.calibrate/0`, for the server to run off its own process."
  @spec calibrate() :: [BudgetCalibration.result()]
  def calibrate, do: BudgetCalibration.calibrate()

  @doc """
  Index `BudgetCalibration.calibrate/1` results by `{account_id, pool, window}`.
  """
  @spec index_calibration([BudgetCalibration.result()]) :: calibration()
  def index_calibration(results) when is_list(results) do
    Enum.reduce(results, empty_calibration(), fn r, acc ->
      key = {r.account_id, r.pool, r.window}

      acc = put_in(acc.horizons[r.pool], r.horizon_hours)

      case r.rung do
        nil ->
          acc

        rung ->
          resolution = Map.take(r, [:rung, :rho, :raw_rho, :floored?, :passed_over])
          acc = put_in(acc.rates[key], resolution)
          if rung == 0, do: put_in(acc.background[key], background(r.fit)), else: acc
      end
    end)
  end

  defp background(%{background_share_per_hour: b}) when is_number(b), do: max(b, 0.0)
  defp background(_fit), do: 0.0

  @doc "One input map per (account, pool, policy workspace) for `Budget.compute/1`."
  @spec gather(calibration()) :: [map()]
  def gather(calibration \\ empty_calibration()) do
    now = DateTime.utc_now()

    ProviderAccount
    |> Ash.Query.filter(enabled == true and is_nil(deleted_at))
    |> Ash.read!()
    |> Enum.flat_map(&account_inputs(&1, calibration, now))
  end

  defp account_inputs(%ProviderAccount{} = account, calibration, now) do
    quota = latest_quota(account)
    hard = hard(account)
    seats = Concurrency.live_count(account)
    workspaces = Resolver.workspaces(account.id)

    for {pool, model} <- pools(account),
        {workspace, share} <- variants(account, workspaces) do
      %{
        account_id: account.id,
        account: account,
        workspace: workspace,
        policy_workspace: workspace && workspace.id,
        share: share,
        pool: pool,
        model: model,
        quota: quota,
        metered?: Quota.provider_code(account.provider) != nil,
        now: now,
        seats: seats,
        hard: hard,
        horizon: Map.get(calibration.horizons, pool),
        rates: window_map(calibration.rates, account.id, pool),
        background: window_map(calibration.background, account.id, pool)
      }
    end
  end

  defp pools(%ProviderAccount{provider: :antigravity}), do: @agy_pools

  defp pools(%ProviderAccount{provider: provider}) do
    case ModelFamily.classify(provider, nil).pool do
      pool when is_binary(pool) -> [{pool, nil}]
      _ -> []
    end
  end

  # The account's own policy, then every linked workspace that sets its own.
  defp variants(account, workspaces) do
    own =
      for ws <- workspaces,
          match?(%{"quota" => %{} = q} when map_size(q) > 0, ws.config),
          do: {ws, Resolver.share(ws.id, account.provider)}

    [{nil, nil} | own]
  end

  defp window_map(index, account_id, pool) do
    for {{^account_id, ^pool, window}, value} <- index, into: %{}, do: {window, value}
  end

  defp latest_quota(account) do
    Quota.latest_for_provider(account.id, account.provider)
  rescue
    e ->
      Logger.debug("Budget.Inputs: no quota row for #{account.id}: #{Exception.message(e)}")
      nil
  end

  # §3.5: the hard zeros the quota row cannot tell us about.
  defp hard(%ProviderAccount{} = account) do
    case Pause.for_account(account) do
      %{kind: :quota} -> :quota_stop
      %{} -> :paused
      nil -> if unavailable?(account), do: :unavailable
    end
  rescue
    _ -> nil
  end

  defp unavailable?(%ProviderAccount{provider: provider}) do
    case Map.get(@adapters, provider) do
      {adapter, type} ->
        AuthHold.open?(adapter) or CredentialWatchdog.expired?(adapter) or
          not ProviderPool.healthy?(type)

      nil ->
        false
    end
  end
end
