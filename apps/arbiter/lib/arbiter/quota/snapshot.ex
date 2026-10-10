defmodule Arbiter.Quota.Snapshot do
  @moduledoc """
  The one quota payload builder (P-18, parity audit D-A-5).

  `GET /api/quota` (`ArbiterWeb.Api.QuotaController`, which wraps the map in
  `{data: ...}`) and the MCP `quota_get` tool (which returns it bare) both call
  this module, so the two surfaces can no longer drift: same keys, same
  `spend_cache`-backed account spend, same `held_dispatches` and
  `paused_providers`.

  Keys: `workspace_id`, `workspace`, `requested_workspace`, `account`,
  `workspaces`, `account_policy`, `policy_binding`, `effective_policy`,
  `claude`, `quotas`, `spend_caps` (the dollar spend cap state of each capped
  account, `Arbiter.Quota.SpendCap`), `codex`, `codex_message`, `codex_credentials_expired`,
  `antigravity`, `gemini_credentials_expired`, `held_dispatches`,
  `paused_providers`, and `budget` (DC5: one block per account with its
  provider-concurrency pools, `Arbiter.Board.CapacityView.account_blocks/2`;
  labelled `shadow` until `scheduler_admission` is `enforce`).
  """

  alias Arbiter.Quota
  alias Arbiter.Quota.SpendCap
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.DispatchQueue

  @doc """
  Snapshot for the workspace `ws_id`. `requested_workspace` echoes the ref the
  caller used (nil when it fell back to the default).
  """
  @spec for_workspace(String.t(), String.t() | nil) :: map()
  def for_workspace(ws_id, requested_workspace \\ nil) do
    accounts = Quota.account_ids(ws_id)
    codex = Quota.Codex.serialize_latest(accounts["codex"])

    # Every `account`/`workspaces` block carries each workspace's 30-day spend
    # off `Arbiter.Quota.SpendCache`'s memoized aggregate (bd-4p6pw7); the
    # memo is built once and threaded through all the calls.
    spend = Quota.spend_cache(accounts)

    # §6: the top-level `account` / `workspaces` describe the headline
    # (Claude) provider's account; each `quotas` entry carries its own pair.
    headline = Quota.account_fields(accounts["claude"], "claude", spend)
    workspace = fetch_workspace(ws_id)

    policy =
      Quota.policy_fields(Arbiter.Accounts.Resolver.get(accounts["claude"]), workspace)

    %{
      workspace_id: ws_id,
      workspace: workspace_view(ws_id, workspace),
      requested_workspace: requested_workspace,
      account: headline[:account],
      workspaces: headline[:workspaces] || [],
      account_policy: policy[:account_policy],
      policy_binding: policy[:policy_binding],
      effective_policy: policy[:effective],
      claude:
        Quota.serialize(accounts["claude"], "claude", workspace_id: ws_id, spend_cache: spend),
      quotas: Quota.list_serialized_for_workspace(ws_id, spend_cache: spend),
      spend_caps: spend_caps(Map.values(accounts)),
      budget: budget(Map.values(accounts)),
      codex: codex,
      codex_message: Quota.codex_absence_message(codex),
      # bd-1fpjgx: live off `CredentialWatchdog`'s held state, not the
      # persisted snapshot.
      codex_credentials_expired: Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Codex),
      antigravity: Quota.CloudCode.serialize_latest(accounts["antigravity"], "antigravity"),
      gemini_credentials_expired:
        Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Gemini),
      held_dispatches: held_dispatches(ws_id),
      paused_providers: Arbiter.Providers.Pause.to_json()
    }
  end

  @doc """
  Snapshot for one provider account (`?account=`): no workspace lookup, only
  that account's own provider carries data, `held_dispatches` is `[]`.
  """
  @spec for_account(Arbiter.Accounts.ProviderAccount.t()) :: map()
  def for_account(account) do
    provider = Atom.to_string(account.provider)
    spend = Quota.spend_cache(account.id)
    fields = Quota.account_fields(account.id, provider, spend)
    codex = if provider == "codex", do: Quota.Codex.serialize_latest(account.id)
    policy = Quota.policy_fields(account, nil)

    %{
      workspace_id: nil,
      workspace: nil,
      requested_workspace: nil,
      account: fields[:account],
      workspaces: fields[:workspaces] || [],
      account_policy: policy[:account_policy],
      policy_binding: policy[:policy_binding],
      effective_policy: policy[:effective],
      claude:
        if(provider == "claude",
          do: Quota.serialize(account.id, "claude", spend_cache: spend)
        ),
      quotas: Quota.list_serialized(account.id, spend_cache: spend),
      spend_caps: spend_caps([account.id]),
      budget: budget([account.id]),
      codex: codex,
      codex_message: Quota.codex_absence_message(codex),
      codex_credentials_expired: Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Codex),
      antigravity:
        if(provider == "antigravity",
          do: Quota.CloudCode.serialize_latest(account.id, "antigravity")
        ),
      gemini_credentials_expired:
        Arbiter.Agents.CredentialWatchdog.expired?(Arbiter.Agents.Gemini),
      held_dispatches: [],
      paused_providers: Arbiter.Providers.Pause.to_json()
    }
  end

  # DC5 (bd-2c2a4g): the provider concurrency budget of each account, one block
  # per account with its pools, labelled with the `scheduler_admission` mode
  # (`Arbiter.Board.CapacityView`). Display only: a read that fails is `[]`.
  defp budget(account_ids) do
    account_ids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Arbiter.Board.CapacityView.account_blocks()
  rescue
    _ -> []
  end

  # bd-a6grlr: one entry per capped account, wire-shaped by `SpendCap.to_map/1`
  # plus the account's `provider:slug`. Uncapped accounts are omitted.
  defp spend_caps(account_ids) do
    account_ids
    |> Enum.uniq()
    |> Enum.map(&Arbiter.Accounts.Resolver.get/1)
    |> Enum.flat_map(fn
      nil ->
        []

      account ->
        case SpendCap.status(account) do
          nil -> []
          status -> [status |> SpendCap.to_map() |> Map.put("account", status.account)]
        end
    end)
  rescue
    _ -> []
  end

  defp held_dispatches(ws_id) do
    ws_id
    |> DispatchQueue.held_items()
    |> Enum.sort_by(&DateTime.to_unix(&1.opened_at, :microsecond))
    |> Enum.map(&DispatchQueue.serialize_held/1)
  end

  defp workspace_view(_ws_id, %Workspace{id: id, name: name}), do: %{id: id, name: name}
  defp workspace_view(ws_id, _), do: %{id: ws_id, name: nil}

  defp fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
