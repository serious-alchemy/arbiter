defmodule Arbiter.Accounts.EnablementTest do
  @moduledoc """
  bd-cvvb02: `:provider_accounts_enabled` ships `:auto` (v0.2.0), and the
  boot resolves it per install. Three populations:

    * **fresh** — no legacy credential anywhere: on, and every workspace is
      joined to `<provider>:default`;
    * **upgrading, un-migrated** — a workspace `worker_env` or the server env
      still carries a provider credential and there is no migration record:
      stays **off** with a boot warning (and a doctor `[fail]`), so no spawn
      ever hits `Arbiter.Accounts.MissingCredentialError`;
    * **already migrated** — an un-restored migration backup exists: on,
      exactly as with `ARBITER_PROVIDER_ACCOUNTS=1` today.

  An explicit `ARBITER_PROVIDER_ACCOUNTS=0/1` (a boolean in app env) always
  wins and is never second-guessed.
  """
  # async: false — toggles Application env and System env other tests read.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Accounts
  alias Arbiter.Accounts.Enablement
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderAccountMigrationBackup
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Boot.ProviderAccounts, as: BootProviderAccounts
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.WorkerEnv

  @oauth_var "CLAUDE_CODE_OAUTH_TOKEN"

  setup do
    prev_flag = Application.get_env(:arbiter, :provider_accounts_enabled)
    prev_resolution = Application.get_env(:arbiter, :provider_accounts_resolution)
    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_server_token = System.get_env(@oauth_var)

    Application.put_env(:arbiter, :worker_isolate_config, false)
    Application.delete_env(:arbiter, :provider_accounts_resolution)
    System.delete_env(@oauth_var)

    on_exit(fn ->
      restore_app(:provider_accounts_enabled, prev_flag)
      restore_app(:provider_accounts_resolution, prev_resolution)
      restore_app(:worker_isolate_config, prev_isolate)

      if prev_server_token,
        do: System.put_env(@oauth_var, prev_server_token),
        else: System.delete_env(@oauth_var)
    end)

    :ok
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app(key, val), do: Application.put_env(:arbiter, key, val)

  defp configure(value), do: Application.put_env(:arbiter, :provider_accounts_enabled, value)

  defp uniq, do: System.unique_integer([:positive])

  defp workspace(worker_env \\ %{}) do
    {:ok, ws} = Ash.create(Workspace, %{name: "en-#{uniq()}", worker_env: worker_env})
    ws
  end

  defp token_workspace(token \\ "legacy-blob-token") do
    workspace(%{@oauth_var => %{"value" => token, "secret" => true}})
  end

  defp backup(ws, opts \\ []) do
    {:ok, backup} =
      Ash.create(ProviderAccountMigrationBackup, %{
        workspace_id: ws.id,
        migration_id: "mig-#{uniq()}",
        removed_keys: [@oauth_var],
        worker_env: %{},
        worker_env_meta: %{}
      })

    if Keyword.get(opts, :restored, false),
      do: Ash.update!(backup, %{}, action: :mark_restored),
      else: backup
  end

  defp account_with_credential(ws, secret) do
    {:ok, account} =
      Ash.create(ProviderAccount, %{provider: :claude, slug: "acct-#{uniq()}", enabled: true})

    {:ok, _} =
      Ash.create(ProviderCredential, %{
        provider_account_id: account.id,
        kind: :oauth_token,
        env_var: @oauth_var,
        fingerprint: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
        active: true,
        secret: secret
      })

    {:ok, _} =
      Ash.create(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

    account
  end

  defp linked_account(ws, provider) do
    case Resolver.account(ws.id, provider) do
      %ProviderAccount{} = account -> {account.provider, account.slug}
      nil -> nil
    end
  end

  describe "the shipped default" do
    test "config/config.exs ships :auto, not a hard-coded false" do
      config = File.read!(Path.join(File.cwd!(), "../../config/config.exs"))
      assert config =~ "config :arbiter, :provider_accounts_enabled, :auto"
      refute config =~ "config :arbiter, :provider_accounts_enabled, false"
    end

    test ":auto is off until the boot has resolved it" do
      configure(:auto)
      refute Accounts.enabled?()
      assert Enablement.status().decision == :unresolved
    end
  end

  describe "fresh install (acceptance 1)" do
    test "no workspaces at all resolves on" do
      configure(:auto)

      assert %{enabled: true, decision: :no_legacy_credentials} = Enablement.resolve()
      assert Accounts.enabled?()
    end

    test "workspaces without any provider credential resolve on, and join <provider>:default" do
      ws = workspace(%{"LOG_LEVEL" => %{"value" => "debug"}})
      configure(:auto)

      assert %{enabled: true, decision: :no_legacy_credentials} = Enablement.resolve()
      assert Enablement.auto_join?()

      assert Enablement.join_defaults() == [{ws.id, :claude, :ok}]
      assert linked_account(ws, :claude) == {:claude, "default"}
    end

    test "the boot child resolves and joins the existing workspaces on the primary" do
      ws = workspace()
      configure(:auto)

      assert BootProviderAccounts.start_link(primary?: true) == :ignore
      assert Accounts.enabled?()
      assert linked_account(ws, :claude) == {:claude, "default"}
    end

    test "a non-primary boot resolves the mode but writes nothing" do
      ws = workspace()
      configure(:auto)

      assert BootProviderAccounts.start_link(primary?: false) == :ignore
      assert Accounts.enabled?()
      assert linked_account(ws, :claude) == nil
    end

    test "a workspace created after boot is joined to claude:default" do
      configure(:auto)
      Enablement.resolve()

      ws = workspace()
      assert linked_account(ws, :claude) == {:claude, "default"}
    end

    test "a workspace whose credential its account already supplies is not legacy" do
      ws = token_workspace("same-token")
      account_with_credential(ws, "same-token")
      configure(:auto)

      assert %{enabled: true, stranded_workspaces: []} = Enablement.resolve()
    end
  end

  describe "upgrading install with legacy credentials and no migration record (acceptance 2)" do
    test "a workspace worker_env credential keeps accounts off, with a loud boot warning" do
      ws = token_workspace()
      configure(:auto)

      log =
        capture_log(fn ->
          assert %{enabled: false, decision: :unmigrated_legacy_credentials} =
                   resolution = Enablement.resolve()

          assert resolution.stranded_workspaces == [ws.name]
        end)

      refute Accounts.enabled?()
      assert log =~ "[warning]"
      assert log =~ ws.name
      assert log =~ "docs/provider-accounts-release-runbook.md"
    end

    test "no spawn path raises MissingCredentialError: the legacy chain still serves the token" do
      ws = token_workspace("legacy-blob-token")
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      configure(:auto)
      capture_log(fn -> Enablement.resolve() end)

      assert ConfigDir.oauth_token(ws) == "legacy-blob-token"
      assert {pairs, _secrets} = WorkerEnv.resolve(task.id)
      assert {@oauth_var, "legacy-blob-token"} in pairs
    end

    test "a server-env-only token keeps accounts off too" do
      workspace()
      System.put_env(@oauth_var, "server-env-token")
      configure(:auto)

      capture_log(fn ->
        assert %{
                 enabled: false,
                 decision: :unmigrated_legacy_credentials,
                 server_env_token?: true
               } =
                 Enablement.resolve()
      end)

      refute Accounts.enabled?()
      assert ConfigDir.oauth_token(nil) == "server-env-token"
    end

    test "a fully rolled-back migration counts as no migration record" do
      ws = token_workspace()
      backup(ws, restored: true)
      configure(:auto)

      capture_log(fn ->
        assert %{enabled: false, decision: :unmigrated_legacy_credentials} = Enablement.resolve()
      end)
    end

    test "nothing is auto-joined while held off" do
      ws = token_workspace()
      configure(:auto)

      capture_log(fn -> assert BootProviderAccounts.start_link(primary?: true) == :ignore end)

      refute Enablement.auto_join?()
      assert linked_account(ws, :claude) == nil
      assert linked_account(workspace(), :claude) == nil
    end

    test "status reports the held-off state for the doctor" do
      ws = token_workspace()
      configure(:auto)
      capture_log(fn -> Enablement.resolve() end)

      assert %{
               configured: :auto,
               enabled: false,
               decision: :unmigrated_legacy_credentials,
               stranded_workspaces: [name]
             } = Enablement.status()

      assert name == ws.name
    end
  end

  describe "already migrated install (acceptance 3)" do
    test "an un-restored migration backup resolves on" do
      ws = workspace()
      backup(ws)
      configure(:auto)

      assert %{enabled: true, decision: :migrated} = Enablement.resolve()
      assert Accounts.enabled?()
    end

    test "a leftover server-env token does not hold a migrated install off" do
      ws = workspace()
      backup(ws)
      System.put_env(@oauth_var, "inert-server-token")
      configure(:auto)

      assert %{enabled: true, decision: :migrated} = Enablement.resolve()
    end

    test "a migrated install is not auto-joined — its links are the operator's" do
      ws = workspace()
      backup(ws)
      configure(:auto)

      assert BootProviderAccounts.start_link(primary?: true) == :ignore
      refute Enablement.auto_join?()
      assert linked_account(ws, :claude) == nil
    end
  end

  describe "an explicit ARBITER_PROVIDER_ACCOUNTS always wins (acceptance 3)" do
    test "explicit on stays on even with unmigrated legacy credentials" do
      token_workspace()
      configure(true)

      assert %{enabled: true, decision: :explicit_on} = Enablement.resolve()
      assert Accounts.enabled?()
      refute Enablement.auto_join?()
    end

    test "explicit off stays off on a fresh install" do
      configure(false)

      assert %{enabled: false, decision: :explicit_off} = Enablement.resolve()
      refute Accounts.enabled?()
    end

    test "explicit on writes no links at boot or on create" do
      configure(true)

      assert BootProviderAccounts.start_link(primary?: true) == :ignore
      assert linked_account(workspace(), :claude) == nil
    end
  end

  describe "status/0 with accounts on and a stranded workspace" do
    test "names the workspace a spawn would fail on" do
      ws = token_workspace()
      configure(true)
      Enablement.resolve()

      assert %{enabled: true, stranded_workspaces: [name]} = Enablement.status()
      assert name == ws.name
    end
  end
end
