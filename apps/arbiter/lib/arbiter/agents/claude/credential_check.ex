defmodule Arbiter.Agents.Claude.CredentialCheck do
  @moduledoc """
  Does a Claude spawn for this workspace carry a credential of its own?
  (bd-80ecol)

  ## Why this exists

  Claude rotates the refresh token of an interactive OAuth grant on every
  refresh. Two holders of the same grant's `.credentials.json` therefore
  race: the first to refresh revokes the other's copy, and that holder stays
  locked out until the operator re-authenticates by hand (bd-6umoh9). Workers
  run on a setup token (`CLAUDE_CODE_OAUTH_TOKEN`, no refresh token — "mode
  A"), but `Arbiter.Agents.Claude.ConfigDir` used to fall back to copying the
  operator's own `.credentials.json` into the worker config dir ("mode B")
  whenever no token resolved — a revoked or missing account credential, or a
  workspace that lost its account join. The fallback was silent and brought
  the lockout straight back.

  `ConfigDir` no longer copies anything. This module is the other half: it
  answers, before anything spawns, whether the spawn will authenticate at all,
  so the answer "no" is a refused dispatch with a named fix
  (`Arbiter.Worker.Dispatch`'s auth guard), a probe that declines to run
  (`Arbiter.Agents.Claude.auth_probe_argv/1`), and a line in
  `arb server doctor` — never a copied login.

  ## What counts as a credential

  Exactly what a spawn's environment would carry:

    * the setup token `ConfigDir.oauth_token/1` resolves — the workspace's
      provider account with `:provider_accounts_enabled` on; with it off, the
      legacy chain (workspace `worker_env`, the server env, the install-wide
      unambiguous workspace token);
    * or an `ANTHROPIC_API_KEY`: in the server's own environment (every spawn
      inherits it), supplied by the workspace's provider account (flag on) or
      `worker_env` (flag off), or named by the workspace's `agent.config`
      `credentials_ref` / `api_keys` (`Arbiter.Agents.Claude.Config`).

  An API key never needed mode B, so a workspace that runs on one is not
  refused.

  With the flag on, a workspace whose `worker_env` still carries a token no
  account supplies makes `ConfigDir.oauth_token/1` raise
  `Arbiter.Accounts.MissingCredentialError`; here that is a `:missing` answer
  (`:credential_not_migrated`) rather than a raise, so the dispatch guard can
  hold and escalate it like any other missing credential.
  """

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.MissingCredentialError
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Agents
  alias Arbiter.Agents.Claude.Config
  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Tasks.Workspace

  @token_var "CLAUDE_CODE_OAUTH_TOKEN"
  @api_key_var "ANTHROPIC_API_KEY"
  @setup_token_hint "<token from `claude setup-token`>"

  @typedoc """
  Why no credential resolved:

    * `:no_account` — flag on, the workspace has no Claude account join.
    * `:no_credential` — flag on, the joined account has no active setup token.
    * `:account_disabled` — flag on, the joined account is parked.
    * `:credential_not_migrated` — flag on, the token is still only in the
      workspace's `worker_env` (`MissingCredentialError`).
    * `:no_install_credential` — flag on, no workspace in hand and no single
      install-wide account credential.
    * `:no_token` — flag off, nothing in the legacy chain.
  """
  @type reason ::
          :no_account
          | :no_credential
          | :account_disabled
          | :credential_not_migrated
          | :no_install_credential
          | :no_token

  @type missing :: %{
          provider: :claude,
          workspace_id: String.t() | nil,
          workspace: String.t() | nil,
          account: String.t() | nil,
          reason: reason(),
          summary: String.t(),
          fix: String.t()
        }

  @doc """
  `:ok` when a Claude spawn for `workspace` (a struct, or `nil` for a
  workspace-less spawn) would carry a setup token or an API key of its own;
  otherwise `{:missing, missing}`, naming why and the command that fixes it.
  Never raises.
  """
  @spec check(Workspace.t() | String.t() | nil) :: :ok | {:missing, missing()}
  def check(workspace_id) when is_binary(workspace_id), do: check(load(workspace_id))

  def check(workspace) do
    case setup_token(workspace) do
      {:ok, _token} ->
        :ok

      {:error, detail} ->
        if api_key?(workspace), do: :ok, else: {:missing, missing(workspace, detail)}
    end
  end

  @doc """
  The `arb server doctor` answer: how many workspaces run Claude (as their
  worker or their reviewer), and every one of them with no credential of its
  own — the workspaces that used to fall into copying the operator's
  `.credentials.json`, and whose Claude dispatch is now held.

  Raises if the workspaces cannot be read; the caller (the doctor endpoint)
  must report "could not check", never a false all-clear.
  """
  @spec workspace_report() :: %{checked: non_neg_integer(), missing: [missing()]}
  def workspace_report do
    claude = Workspace |> Ash.read!() |> Enum.filter(&claude_workspace?/1)

    missing =
      Enum.flat_map(claude, fn ws ->
        case check(ws) do
          :ok -> []
          {:missing, missing} -> [missing]
        end
      end)

    %{checked: length(claude), missing: missing}
  end

  @doc "Whether `workspace` runs Claude as its worker or its reviewer."
  @spec claude_workspace?(Workspace.t()) :: boolean()
  def claude_workspace?(%Workspace{} = ws),
    do: :claude in Agents.agent_pool(ws) or :claude in Agents.reviewer_pool(ws)

  # ---- setup token ---------------------------------------------------------

  defp setup_token(workspace) do
    case ConfigDir.oauth_token(workspace) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :none}
    end
  rescue
    e in MissingCredentialError -> {:error, {:not_migrated, e}}
  end

  # ---- API key -------------------------------------------------------------

  defp api_key?(workspace) do
    present?(System.get_env(@api_key_var)) or workspace_api_key?(workspace) or
      Config.api_key_configured?(workspace)
  end

  defp workspace_api_key?(%Workspace{} = ws) do
    if Accounts.enabled?() do
      match?({:ok, _}, Credentials.workspace_credential(ws.id, @api_key_var))
    else
      ws |> Workspace.worker_env_map() |> Map.get(@api_key_var) |> present?()
    end
  rescue
    _ -> false
  end

  defp workspace_api_key?(_), do: false

  defp present?(value), do: is_binary(value) and value != ""

  # ---- the answer ----------------------------------------------------------

  defp missing(workspace, detail) do
    {reason, account} = diagnose(workspace, detail)
    ws_id = workspace_id(workspace)
    ws_name = workspace_name(workspace)

    %{
      provider: :claude,
      workspace_id: ws_id,
      workspace: ws_name,
      account: account && account.slug,
      reason: reason,
      summary: summary(reason, ws_name || ws_id, account),
      fix: fix(reason, ws_id, account)
    }
  end

  defp diagnose(_workspace, {:not_migrated, _}), do: {:credential_not_migrated, nil}

  defp diagnose(workspace, :none) do
    cond do
      not Accounts.enabled?() ->
        {:no_token, nil}

      is_nil(workspace) ->
        {:no_install_credential, nil}

      true ->
        case Resolver.account(workspace.id, :claude) do
          nil -> {:no_account, nil}
          %ProviderAccount{enabled: false} = account -> {:account_disabled, account}
          %ProviderAccount{} = account -> {:no_credential, account}
        end
    end
  end

  defp summary(reason, ws_label, account) do
    scope = if ws_label, do: "workspace #{ws_label}", else: "a workspace-less spawn"

    "no Claude setup token resolves for #{scope}: " <>
      case reason do
        :no_account -> "it has no Claude provider account attached"
        :no_credential -> "account claude:#{account.slug} has no active #{@token_var}"
        :account_disabled -> "account claude:#{account.slug} is parked (enabled: false)"
        :credential_not_migrated -> "its #{@token_var} is still only in worker_env"
        :no_install_credential -> "no single install-wide Claude account credential exists"
        :no_token -> "no #{@token_var} in its worker_env or the server environment"
      end
  end

  defp fix(:no_credential, _ws_id, account), do: rotate(account.slug)

  defp fix(:account_disabled, _ws_id, account) do
    "Account claude:#{account.slug} is parked, so it supplies no credential. Un-park it, " <>
      "or attach an enabled account, then make sure it holds a setup token: " <>
      rotate(account.slug)
  end

  defp fix(:no_account, ws_id, _account) do
    "`arb account attach #{ws_id} claude <slug>` (create the account first with " <>
      "`arb account create claude <slug>` if it does not exist), then " <> rotate("<slug>")
  end

  defp fix(:credential_not_migrated, _ws_id, _account) do
    "Run `mix arbiter.accounts.migrate` (a release install: `Arbiter.Release.accounts_migrate/1`) " <>
      "so the workspace's token becomes an account credential, or " <> rotate("<slug>")
  end

  defp fix(:no_install_credential, _ws_id, _account) do
    "Give the install one Claude account that holds a setup token: " <> rotate("<slug>")
  end

  defp fix(:no_token, _ws_id, _account) do
    "Set #{@token_var}=#{@setup_token_hint} in the workspace's worker_env or in " <>
      "~/.arbiter/arbiter.env (then restart), or enable provider accounts and " <>
      rotate("<slug>")
  end

  defp rotate(slug) do
    "`arb account rotate claude:#{slug} --kind oauth_token --env-var #{@token_var} " <>
      "--secret #{@setup_token_hint}`"
  end

  # An id that does not load is checked as a workspace-less spawn — the same
  # degradation `ConfigDir.oauth_token/1` applies to it.
  defp load(id) do
    case Ash.get(Workspace, id) do
      {:ok, %Workspace{} = ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp workspace_id(%Workspace{id: id}), do: id
  defp workspace_id(_), do: nil

  defp workspace_name(%Workspace{name: name}), do: name
  defp workspace_name(_), do: nil
end
