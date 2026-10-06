defmodule Arbiter.Sessions.LaunchProviders do
  @moduledoc """
  Which session providers the launch form offers (bd-8qoxst) — the rule behind
  both `/sessions` and the session dock's New session panel, and the one the
  server re-applies to a submit.

  The candidates are the `:session_provider` registry
  (`Arbiter.Sessions.Session.providers/0`), so a new adapter shows up without
  touching the form. For each, an adapter that answers the optional
  `Arbiter.Sessions.Provider` callbacks is judged on:

  **Offered at all** — otherwise the provider is left out:

    * an account exists for it (`account_provider/0`) that is neither
      soft-deleted, merged away nor parked (`enabled: false`) — and, when the
      launch is bound to a workspace, is the one *that workspace* is joined
      to (`Arbiter.Accounts.Resolver`). A cross-workspace launch (`nil`) needs
      any such account;
    * its CLI (`executable/0`) resolves on `PATH`. A provider that is
      configured but whose CLI is not installed can only fail after launch, so
      it is left out rather than shown greyed.

  **Enabled right now** — otherwise the entry is `disabled?: true` with a
  short `reason`, in this precedence:

    * an open `Arbiter.Agents.AuthHold` for its `agent_adapter/0`;
    * an `Arbiter.Agents.CredentialWatchdog` expiry for it;
    * a `:strict` workspace (`permissions.mode`) whose adapter reports
      `Arbiter.Agents.write_confinement/2` of `:none` — the fail-closed gate
      a worker dispatch applies, surfaced here before the click.

  An account's own credential rows are *not* a signal: mode B seeds the
  operator's credentials rather than reading the account's, and a fresh
  `<provider>:default` join carries none.

  Test seams (`opts`, all optional): `:find_executable` (1-arity, default the
  `:sessions_find_executable` app env, else `System.find_executable/1`),
  `:auth_hold` / `:watchdog` (server names or pids) and `:write_confinement`
  (2-arity).
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents
  alias Arbiter.Agents.AuthHold
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Sessions.Provider
  alias Arbiter.Sessions.Session
  alias Arbiter.Tasks.Workspace

  @default "claude_code"

  @type entry :: %{
          provider: String.t(),
          label: String.t(),
          disabled?: boolean(),
          reason: String.t() | nil
        }

  @doc """
  The providers to offer for a launch bound to `workspace_id` (`nil` for
  cross-workspace), in registry order. See the moduledoc.
  """
  @spec list(String.t() | nil, keyword()) :: [entry()]
  def list(workspace_id \\ nil, opts \\ []) do
    workspace = workspace(workspace_id)

    for key <- Session.providers(),
        adapter = Provider.adapter(key),
        offered?(adapter, workspace_id, opts) do
      reason = disabled_reason(adapter, workspace, opts)

      %{
        provider: Atom.to_string(key),
        label: label(adapter, key),
        disabled?: reason != nil,
        reason: reason
      }
    end
  end

  @doc """
  The provider a fresh form pre-selects: `claude_code` when it is enabled,
  else the first enabled one, else `nil` (nothing can launch).
  """
  @spec default([entry()]) :: String.t() | nil
  def default(entries) do
    enabled = for %{disabled?: false, provider: provider} <- entries, do: provider
    if @default in enabled, do: @default, else: List.first(enabled)
  end

  @doc """
  Whether `provider` (the raw form value) is offered **and** enabled for
  `workspace_id` — the server-side check on a submit.
  """
  @spec selectable?(term(), String.t() | nil, keyword()) :: boolean()
  def selectable?(provider, workspace_id, opts \\ [])
      when is_binary(provider) or is_nil(provider) do
    Enum.any?(list(workspace_id, opts), &(&1.provider == provider and not &1.disabled?))
  end

  # ---- offered -------------------------------------------------------------

  defp offered?(adapter, workspace_id, opts),
    do: account_configured?(adapter, workspace_id) and cli_present?(adapter, opts)

  defp account_configured?(adapter, workspace_id) do
    case optional(adapter, :account_provider) do
      nil ->
        true

      provider when is_nil(workspace_id) ->
        Accounts.list_accounts(provider: provider) |> Enum.any?(&usable_account?/1)

      provider ->
        usable_account?(Resolver.account(workspace_id, provider))
    end
  end

  defp usable_account?(%ProviderAccount{enabled: true, deleted_at: nil, merged_into_id: nil}),
    do: true

  defp usable_account?(_), do: false

  defp cli_present?(adapter, opts) do
    case optional(adapter, :executable) do
      nil -> true
      executable -> finder(opts).(executable) != nil
    end
  end

  defp finder(opts) do
    Keyword.get_lazy(opts, :find_executable, fn ->
      Application.get_env(:arbiter, :sessions_find_executable, &System.find_executable/1)
    end)
  end

  # ---- disabled ------------------------------------------------------------

  defp disabled_reason(adapter, workspace, opts) do
    case optional(adapter, :agent_adapter) do
      nil ->
        nil

      agent ->
        auth_hold_reason(agent, opts) || expiry_reason(agent, opts) ||
          confinement_reason(agent, workspace, opts)
    end
  end

  defp auth_hold_reason(agent, opts) do
    case AuthHold.held(agent, Keyword.get(opts, :auth_hold, AuthHold)) do
      nil -> nil
      %{deaths: deaths} -> "auth hold open after #{deaths} auth failures"
      _ -> "auth hold open"
    end
  end

  defp expiry_reason(agent, opts) do
    if CredentialWatchdog.expired?(agent, Keyword.get(opts, :watchdog, CredentialWatchdog)),
      do: "credential expired"
  end

  defp confinement_reason(_agent, nil, _opts), do: nil

  defp confinement_reason(agent, %Workspace{} = workspace, opts) do
    policy = SecurityPolicy.resolve(workspace)
    confinement = Keyword.get(opts, :write_confinement, &Agents.write_confinement/2)

    if policy.permissions.mode == :strict and confinement.(agent, policy) == :none,
      do: "strict workspace: cannot confine writes on this host"
  end

  # ---- helpers -------------------------------------------------------------

  defp workspace(nil), do: nil

  defp workspace(id) do
    case Accounts.get_workspace(id) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp label(adapter, key), do: optional(adapter, :label) || Atom.to_string(key)

  # An adapter may omit any of the optional callbacks.
  defp optional(adapter, callback) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, callback, 0),
      do: apply(adapter, callback, [])
  end
end
