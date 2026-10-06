defmodule Arbiter.Quota.Visibility do
  @moduledoc """
  Which providers' quota the dashboard shows (bd-i2gwwn): the one rule the
  status-bar quota chip and the `/usage` "Rate limits" panel both read, through
  `ArbiterWeb.LiveHooks.load_quotas/0` → `list_latest_for_workspace/1`.

  A provider is shown iff

      (detected OR forced on) AND NOT forced off AND NOT in Quota.hidden_providers/0

  * **Detected** (`detected/0`) — named by `Arbiter.Accounts.ProviderSettings.effective/2`
    for either role (implementer, reviewer) on any workspace in the
    installation. That is the attached accounts when a role has any — counted
    only while the account is enabled, not soft-deleted and not merged away —
    else the role's `agent.type` / `review_agent.type`, else the `claude`
    default an unconfigured workspace runs.
  * **Forced on / off** — the install-wide override, `quota_providers_shown`
    and `quota_providers_hidden` (`Arbiter.Settings`, settable with the
    `installation_config_set` MCP tool). Both default to unset: auto-detect.
    Off wins over on.
  * **Hidden** — `Arbiter.Quota.hidden_providers/0`
    wins over everything, the override included. Dropping a provider from
    that list is the whole change to start showing it.

  What does **not** count:

  * A snapshot row on its own. `Arbiter.Quota.CloudProbe` polls every CLI that
    is logged in on the host, used or not, so a row says nothing about use.
  * A bare `WorkspaceProviderAccount` link (no implementer/reviewer position).
    The probe's write path provisions one for every provider it stores a
    snapshot for (`Arbiter.Quota.ensure_account_id/2`), so on a real install a
    bare link is the same signal as a snapshot row. A provider the
    installation genuinely runs is named by `effective/2` anyway — that is
    also how `Arbiter.Accounts.Enablement` decides which `<provider>:default`
    accounts to join.
  * Whether the CLI is on the server's PATH. `agent.type` `"gemini"` maps to
    `antigravity` through `ProviderSettings.agent_type/1`'s table, not through
    `Arbiter.Quota.provider_code/1`, which asks whether `agy` resolves.

  A shown provider with no snapshot row yet is listed as a `no_data: true`
  view rather than dropped, so a just-configured provider reads "no data yet".

  `GET /api/quota`, `arb quota` and the `quota_get` MCP tool do not go
  through here: they stay the raw view of every captured provider.
  """

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  require Ash.Query

  # Every quota provider code, as `ProviderAccount.provider` atoms.
  @providers [:claude, :codex, :antigravity]

  @doc "The quota provider codes the override settings accept."
  @spec provider_codes() :: [String.t()]
  def provider_codes, do: Enum.map(@providers, &Atom.to_string/1)

  @doc """
  The rule, pure: `detected` plus `shown`, minus `hidden` and minus
  `always_hidden`, deduplicated, `claude` first and the rest alphabetical
  (the order `Arbiter.Quota.list_latest/2` sorts views in).
  """
  @spec rule([String.t()], [String.t()], [String.t()], [String.t()]) :: [String.t()]
  def rule(detected, shown, hidden, always_hidden) do
    (detected ++ shown)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in hidden or &1 in always_hidden))
    |> Enum.sort_by(&{&1 != "claude", &1})
  end

  @doc "The providers to show: `rule/4` over `detected/0` and the override."
  @spec providers() :: [String.t()]
  def providers do
    %{shown: shown, hidden: hidden} = Arbiter.Settings.quota_provider_overrides()
    rule(detected(), shown || [], hidden || [], Quota.hidden_providers())
  end

  @doc """
  The providers this installation runs, before the override and the hidden
  list: everything `ProviderSettings.effective/2` names, for both roles, over
  every workspace. `[]` when there are no workspaces.

  A failed read raises rather than answering `[]`: "this installation uses
  nothing" would hide every provider and tell `/usage` to say "No providers
  configured", where the top bar's load turns a raise into its "quota
  unavailable" retry notice.
  """
  @spec detected() :: [String.t()]
  def detected do
    # One read of every link for every workspace, not one per workspace and
    # role: this runs on a cold top-bar load.
    links =
      WorkspaceProviderAccount
      |> Ash.Query.load(:provider_account)
      |> Ash.read!()
      |> Enum.group_by(& &1.workspace_id)

    Workspace
    |> Ash.read!()
    |> Enum.flat_map(fn ws ->
      ws_links = Map.get(links, ws.id, [])

      Enum.flat_map(
        ProviderSettings.roles(),
        &ProviderSettings.effective(ws, &1, ws_links).candidates
      )
    end)
    |> Enum.flat_map(&candidate_provider/1)
    |> rule([], [], [])
  end

  # An attached (or config-named, metered) account counts only while usable.
  defp candidate_provider(%{account: %ProviderAccount{} = account}) do
    if account.enabled and is_nil(account.deleted_at) and is_nil(account.merged_into_id),
      do: [Atom.to_string(account.provider)],
      else: []
  end

  defp candidate_provider(%{agent_type: type}) do
    case Enum.find(@providers, &(ProviderSettings.agent_type(&1) == type)) do
      nil -> []
      provider -> [Atom.to_string(provider)]
    end
  end

  @doc """
  `Arbiter.Quota.list_latest_for_workspace/2` narrowed to `providers/0`, in
  that order, with a `no_data: true` blank view (carrying the workspace and
  its install-default `gate_policy`) for a shown provider that has no snapshot
  row yet, then grok's ledger estimate when the workspace has it enabled.
  """
  @spec list_latest_for_workspace(String.t() | nil, keyword()) :: [map()]
  def list_latest_for_workspace(workspace_id, opts \\ []) do
    visible = providers()
    excluded = provider_codes() -- visible

    views =
      Quota.list_latest_for_workspace(
        workspace_id,
        Keyword.put(opts, :exclude_providers, excluded)
      )

    by_provider = Map.new(views, &{&1.provider, &1})

    # grok is not a quota provider code: its entry is the workspace opt-in's
    # ledger estimate, listed after the polled providers when switched on.
    grok = Enum.filter(views, &(&1.provider == "grok"))

    case visible do
      [] ->
        grok

      visible ->
        Enum.map(visible, fn provider ->
          Map.get_lazy(by_provider, provider, fn -> no_data_view(workspace_id, provider) end)
        end) ++ grok
    end
  end

  defp no_data_view(workspace_id, provider) do
    provider
    |> Quota.blank_view()
    |> Map.merge(%{
      workspace_id: workspace_id,
      no_data: true,
      gate_policy: Quota.gate_policy(nil, nil)
    })
  end
end
