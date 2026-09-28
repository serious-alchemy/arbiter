defmodule Arbiter.Accounts.Enablement do
  @moduledoc """
  Resolves `:provider_accounts_enabled` for this install (bd-cvvb02, the
  v0.2.0 "defaults to on" precondition; `docs/provider-account-design.md`
  §7.5).

  `config/config.exs` ships the flag as `:auto`. `config/runtime.exs` turns an
  explicit `ARBITER_PROVIDER_ACCOUNTS=1/true` or `0/false` into a boolean,
  and a boolean **always wins**: it is used as-is and never second-guessed.
  `:auto` is resolved once per boot by `Arbiter.Boot.ProviderAccounts`, from
  what the database and the server environment say about three populations:

    * **Already migrated** — an un-restored `provider_account_migration_backups`
      row exists (`Arbiter.Accounts.Migrate` writes one per workspace before
      it touches that workspace's `worker_env`; a rollback marks it restored).
      → **on** (`:migrated`), exactly as `ARBITER_PROVIDER_ACCOUNTS=1` today.
      A server-env token left behind is inert with accounts on and does not
      hold it off; the runbook tells the operator to remove it.
    * **Upgrading, un-migrated** — no migration record, and a legacy
      credential exists: a workspace whose `worker_env` carries an
      allowlisted provider-credential key (`Arbiter.Accounts.Census.credential_keys/0`)
      that no account supplies to it, or a `CLAUDE_CODE_OAUTH_TOKEN` in the
      server's own environment. → **off** (`:unmigrated_legacy_credentials`),
      with a boot warning naming what is holding it off, and `arb server
      doctor` reports `[fail]` pointing at
      `docs/provider-accounts-release-runbook.md`. Turning accounts on here
      would raise `Arbiter.Accounts.MissingCredentialError` on every spawn in
      those workspaces (or silently drop the server-env token), so the
      install keeps the legacy chain it already runs on.
    * **Fresh** — neither of the above. → **on**
      (`:no_legacy_credentials`), and every workspace — the existing ones at
      boot, and each one created afterwards — is joined to
      `<provider>:default` for the providers it runs
      (`Arbiter.Accounts.Resolver.ensure_account_id/2`). A join carries no
      credential of its own; `arb server doctor`'s Claude credential check
      names the `arb account rotate` that adds one.

  Staying off rather than refusing to boot is deliberate: a refused boot on
  upgrade takes the dashboard, the API and every running worker down with it
  for a condition the legacy chain handles correctly today, and the fix (the
  runbook's census → migrate) does not need the server to be down until its
  own step 4.

  Until the boot has resolved `:auto`, `Arbiter.Accounts.enabled?/0` answers
  `false` — the conservative side, which is also what a `bin/arbiter eval`
  or a `mix arbiter.accounts.*` task (neither starts the boot children) sees.

  The answer is re-derived on every boot, so migrating (or rolling back) an
  install changes it at the next restart without any extra step.
  """

  require Ash.Query
  require Logger

  alias Arbiter.Accounts.Census
  alias Arbiter.Accounts.Credentials
  alias Arbiter.Accounts.ProviderAccountMigrationBackup
  alias Arbiter.Accounts.ProviderSettings
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Tasks.Workspace

  @flag :provider_accounts_enabled
  @resolution_key :provider_accounts_resolution
  @server_token_var "CLAUDE_CODE_OAUTH_TOKEN"
  @runbook "docs/provider-accounts-release-runbook.md"

  @type decision ::
          :explicit_on
          | :explicit_off
          | :migrated
          | :no_legacy_credentials
          | :unmigrated_legacy_credentials
          | :unresolved

  @type resolution :: %{
          enabled: boolean(),
          decision: decision(),
          stranded_workspaces: [String.t()],
          server_env_token?: boolean()
        }

  @doc "The runbook an operator is pointed at when accounts are held off."
  @spec runbook() :: String.t()
  def runbook, do: @runbook

  @doc """
  The configured value: `true` / `false` (explicit) or `:auto` (the shipped
  default). Anything else is treated as `false`, the pre-v0.2.0 default.
  """
  @spec configured() :: boolean() | :auto
  def configured do
    case Application.get_env(:arbiter, @flag, false) do
      value when is_boolean(value) -> value
      :auto -> :auto
      _ -> false
    end
  end

  @doc """
  Whether provider accounts are on — `Arbiter.Accounts.enabled?/0`'s answer.
  `:auto` is `false` until `resolve/0` has run.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case configured() do
      :auto -> match?(%{enabled: true}, Application.get_env(:arbiter, @resolution_key))
      explicit -> explicit
    end
  end

  @doc """
  Resolve the flag for this boot and record the answer (see the moduledoc).
  An explicit boolean is recorded as-is; `:auto` runs `detect/0`. Logs one
  line — a warning when accounts are held off. Never raises: a detection
  failure resolves off (the legacy chain), loudly.
  """
  @spec resolve() :: resolution()
  def resolve do
    resolution =
      case configured() do
        true -> explicit(:explicit_on)
        false -> explicit(:explicit_off)
        :auto -> detect()
      end

    Application.put_env(:arbiter, @resolution_key, resolution)
    log(resolution)
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
      enabled: decision != :unmigrated_legacy_credentials,
      decision: decision,
      stranded_workspaces: stranded,
      server_env_token?: server_token?
    }
  rescue
    e ->
      Logger.warning(
        "Arbiter.Accounts.Enablement: could not classify this install (#{inspect(e)}); " <>
          "leaving provider accounts off — see #{@runbook}"
      )

      %{
        enabled: false,
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
          configured: boolean() | :auto,
          enabled: boolean(),
          decision: decision(),
          stranded_workspaces: [String.t()],
          server_env_token?: boolean()
        }
  def status do
    decision =
      case Application.get_env(:arbiter, @resolution_key) do
        %{decision: decision} -> decision
        _ -> if configured() == :auto, do: :unresolved, else: explicit_decision(configured())
      end

    %{
      configured: configured(),
      enabled: enabled?(),
      decision: decision,
      stranded_workspaces: stranded_workspaces(),
      server_env_token?: server_env_token?()
    }
  end

  @doc """
  Whether workspaces are joined to `<provider>:default` automatically: only
  when `:auto` resolved a fresh install. A migrated install's links are the
  operator's, and an explicit flag keeps today's behaviour.
  """
  @spec auto_join?() :: boolean()
  def auto_join? do
    configured() == :auto and
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

  defp explicit(decision) do
    %{
      enabled: decision == :explicit_on,
      decision: decision,
      stranded_workspaces: [],
      server_env_token?: false
    }
  end

  defp explicit_decision(true), do: :explicit_on
  defp explicit_decision(false), do: :explicit_off

  defp migration_record? do
    ProviderAccountMigrationBackup
    |> Ash.Query.filter(is_nil(restored_at))
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> Kernel.!=([])
  end

  # Workspaces whose `worker_env` carries a provider-credential key no account
  # supplies to them — with accounts on, exactly the ones
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
      "Provider accounts are OFF on this install: it still carries legacy provider " <>
        "credentials (#{describe_legacy(resolution)}) and has no provider-account migration " <>
        "record, so turning accounts on would fail every spawn that needs one. Workers keep " <>
        "the legacy credential chain. Migrate with #{@runbook} (census → migrate → restart), " <>
        "or set ARBITER_PROVIDER_ACCOUNTS=0 to keep the legacy chain deliberately."
    )
  end

  defp log(%{decision: decision, enabled: enabled?}) do
    Logger.info(
      "Provider accounts are #{if enabled?, do: "on", else: "off"} (#{decision}; " <>
        ":provider_accounts_enabled configured #{inspect(configured())})"
    )
  end

  defp describe_legacy(%{stranded_workspaces: stranded, server_env_token?: server_token?}) do
    workspaces =
      case stranded do
        [] -> []
        names -> ["workspace worker_env: #{Enum.join(names, ", ")}"]
      end

    server = if server_token?, do: ["#{@server_token_var} in the server environment"], else: []

    Enum.join(workspaces ++ server, "; ")
  end
end
