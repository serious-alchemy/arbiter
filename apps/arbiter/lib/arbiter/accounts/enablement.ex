defmodule Arbiter.Accounts.Enablement do
  @moduledoc """
  Classifies this install's provider-account posture at boot (bd-cvvb02;
  `docs/provider-account-design.md` §7.5).

  Provider accounts are **always on**: since the P13 flip (bd-9gqj8e) there
  is no provider-accounts flag and no legacy credential chain to
  fall back to — a spawn's provider credential comes from its workspace's
  account and nowhere else. What is still re-derived on every boot, by
  `Arbiter.Boot.ProviderAccounts`, is which of three populations the install
  is in, from what the database and the server environment say:

    * **Already migrated** — an un-restored `provider_account_migration_backups`
      row exists (`Arbiter.Accounts.Migrate` writes one per workspace before
      it touches that workspace's `worker_env`; a rollback marks it restored).
      → `:migrated`. Nothing is joined automatically: the links are the
      operator's.
    * **Un-migrated legacy credentials** — no migration record, and a legacy
      credential exists: a workspace whose `worker_env` carries an
      allowlisted provider-credential key (`Arbiter.Accounts.Census.credential_keys/0`)
      that no account supplies to it, or a `CLAUDE_CODE_OAUTH_TOKEN` in the
      server's own environment. → `:unmigrated_legacy_credentials`, with a
      boot warning naming them, and `arb server doctor` reports `[fail]`
      pointing at `docs/provider-accounts-release-runbook.md`. Every spawn in
      such a workspace raises `Arbiter.Accounts.MissingCredentialError`
      (which the dispatch guard holds and escalates), and the server-env
      token is read by nothing. Before P13 this population was held on the
      legacy chain; the flip release requires migrating it first.
    * **Fresh** — neither of the above. → `:no_legacy_credentials`, and every
      workspace — the existing ones at boot, and each one created afterwards
      — is joined to `<provider>:default` for the providers it runs
      (`Arbiter.Accounts.Resolver.ensure_account_id/2`). A join carries no
      credential of its own; `arb server doctor`'s Claude credential check
      names the `arb account rotate` that adds one.

  The retired `ARBITER_PROVIDER_ACCOUNTS` switch is no longer read; a server
  environment that still sets it gets a boot warning, since an explicit `0`
  used to mean "keep the legacy chain" and no longer can.

  Until the boot has classified the install, `status/0` answers
  `:unresolved` and `auto_join?/0` is `false` — which is also what a
  `bin/arbiter eval` or a `mix arbiter.accounts.*` task (neither starts the
  boot children) sees.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.ProviderAccountMigrationBackup
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Tasks.Workspace

  @resolution_key :provider_accounts_resolution
  @server_token_var "CLAUDE_CODE_OAUTH_TOKEN"
  @retired_switch_var "ARBITER_PROVIDER_ACCOUNTS"
  @runbook "docs/provider-accounts-release-runbook.md"

  @type decision ::
          :migrated
          | :no_legacy_credentials
          | :unmigrated_legacy_credentials
          | :unresolved

  @type resolution :: %{
          decision: decision(),
          stranded_workspaces: [String.t()],
          server_env_token?: boolean()
        }

  @doc "The runbook an operator is pointed at when accounts are held off."
  @spec runbook() :: String.t()
  def runbook, do: @runbook

  @doc """
  Classify the install for this boot and record the answer (see the
  moduledoc). Logs one line — a warning when legacy credentials are
  stranded — plus a warning if the retired `ARBITER_PROVIDER_ACCOUNTS`
  switch is still set. Never raises: a detection failure is recorded as
  `:unmigrated_legacy_credentials`, loudly, so nothing is auto-joined.
  """
  @spec resolve() :: resolution()
  def resolve do
    resolution = detect()

    Application.put_env(:arbiter, @resolution_key, resolution)
    log(resolution)
    warn_retired_switch()
    resolution
  end

  @doc """
  Classify the install from the database and server environment, without
  recording anything. See the moduledoc for the three populations.
  """
  @spec detect() :: resolution()
  def detect do
    stranded = stranded_workspaces()
    server_token? = server_env_token?()

    decision =
      cond do
        migration_record?() -> :migrated
        stranded != [] or server_token? -> :unmigrated_legacy_credentials
        true -> :no_legacy_credentials
      end

    %{
      decision: decision,
      stranded_workspaces: stranded,
      server_env_token?: server_token?
    }
  rescue
    e ->
      Logger.warning(
        "Arbiter.Accounts.Enablement: could not classify this install (#{inspect(e)}); " <>
          "treating it as un-migrated, so no workspace is joined to a default account — " <>
          "see #{@runbook}"
      )

      %{
        decision: :unmigrated_legacy_credentials,
        stranded_workspaces: [],
        server_env_token?: false
      }
  end

  @doc """
  What `arb server doctor` reports: the recorded decision plus a *live*
  re-read of the workspaces a spawn would fail on, so a straggler added since
  boot is still named.
  """
  @spec status() :: %{
          decision: decision(),
          stranded_workspaces: [String.t()],
          server_env_token?: boolean()
        }
  def status do
    decision =
      case Application.get_env(:arbiter, @resolution_key) do
        %{decision: decision} -> decision
        _ -> :unresolved
      end

    %{
      decision: decision,
      stranded_workspaces: stranded_workspaces(),
      server_env_token?: server_env_token?()
    }
  end

  @doc """
  Whether workspaces are joined to `<provider>:default` automatically: only
  when the boot classified a fresh install. A migrated install's links are
  the operator's.
  """
  @spec auto_join?() :: boolean()
  def auto_join? do
    match?(%{decision: :no_legacy_credentials}, Application.get_env(:arbiter, @resolution_key))
  end

  @doc """
  Join every workspace to `<provider>:default` for each provider it runs.
  Returns one `{workspace_id, provider, :ok | {:error, reason}}` per join.
  """
  @spec join_defaults() :: [{String.t(), atom(), :ok | {:error, term()}}]
  def join_defaults do
    Workspace |> Ash.read!() |> Enum.flat_map(&join_default/1)
  end

  @doc """
  Join one workspace to `<provider>:default` for each provider its
  implementer and reviewer settings resolve to (`claude` when it names
  none). Idempotent: an existing link is kept, and
  `Arbiter.Accounts.Resolver.ensure_account_id/2` adopts the provider's sole
  enabled account before it mints `default`.
  """
  @spec join_default(Workspace.t()) :: [{String.t(), atom(), :ok | {:error, term()}}]
  def join_default(%Workspace{} = ws) do
    ws
    |> providers()
    |> Enum.map(fn provider ->
      case Resolver.ensure_account_id(ws.id, provider) do
        {:ok, _account_id} ->
          {ws.id, provider, :ok}

        {:error, reason} = error ->
          Logger.warning(
            "Arbiter.Accounts.Enablement: could not join workspace #{ws.name} to " <>
              "#{provider}:default (#{inspect(reason)})"
          )

          {ws.id, provider, error}
      end
    end)
  end

  defp providers(ws) do
    ProviderSettings.roles()
    |> Enum.flat_map(&ProviderSettings.effective(ws, &1).candidates)
    |> Enum.map(& &1.provider)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> case do
      [] -> [:claude]
      providers -> providers
    end
  end

  defp migration_record? do
    ProviderAccountMigrationBackup
    |> Ash.Query.filter(is_nil(restored_at))
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> Kernel.!=([])
  end

  # Workspaces whose `worker_env` carries a provider-credential key no account
  # supplies to them — exactly the ones
  # `Arbiter.Worker.WorkerEnv` / `ConfigDir.oauth_token/1` raise
  # `MissingCredentialError` for. Key names come from `worker_env_meta`, so
  # nothing is decrypted to answer the common "no credential keys" case.
  defp stranded_workspaces do
    credential_keys = Census.credential_keys()

    Workspace
    |> Ash.read!()
    |> Enum.filter(fn ws ->
      case ws
           |> Workspace.worker_env_keys()
           |> Enum.map(& &1.name)
           |> Enum.filter(&Map.has_key?(credential_keys, &1)) do
        [] ->
          false

        keys ->
          supplied = ws.id |> Credentials.workspace_pairs() |> MapSet.new(&elem(&1, 0))
          Enum.any?(keys, &(not MapSet.member?(supplied, &1)))
      end
    end)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp server_env_token? do
    System.get_env(@server_token_var) not in [nil, ""]
  end

  defp log(%{decision: :unmigrated_legacy_credentials} = resolution) do
    Logger.warning(
      "Provider accounts: this install still carries legacy provider credentials " <>
        "(#{describe_legacy(resolution)}) and has no provider-account migration record. " <>
        "Provider accounts are the only credential source since the P13 flip, so every " <>
        "spawn in those workspaces raises MissingCredentialError and a server-env " <>
        "#{@server_token_var} is read by nothing. Migrate with #{@runbook} " <>
        "(census → migrate → restart)."
    )
  end

  defp log(%{decision: decision}) do
    Logger.info("Provider accounts: #{decision}")
  end

  defp warn_retired_switch do
    case System.get_env(@retired_switch_var) do
      unset when unset in [nil, ""] ->
        :ok

      value ->
        Logger.warning(
          "#{@retired_switch_var}=#{value} is set in the server environment but is no longer " <>
            "read: provider accounts are always on since the P13 flip and there is no legacy " <>
            "credential chain to fall back to. Remove it from the server's env file."
        )
    end
  end

  defp describe_legacy(%{stranded_workspaces: stranded, server_env_token?: server_token?}) do
    workspaces =
      case stranded do
        [] -> []
        names -> ["workspace worker_env: #{Enum.join(names, ", ")}"]
      end

    server = if server_token?, do: ["#{@server_token_var} in the server environment"], else: []

    case workspaces ++ server do
      [] -> "unknown — the install could not be classified"
      sources -> Enum.join(sources, "; ")
    end
  end
end
