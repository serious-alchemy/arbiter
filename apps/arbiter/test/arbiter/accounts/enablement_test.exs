defmodule Arbiter.Accounts.EnablementTest do
  @moduledoc """
  bd-cvvb02, P13 (bd-9gqj8e): provider accounts are always on — there is no
  flag and no legacy credential chain — and the boot classifies each install
  into one of three populations:

    * **fresh** — no legacy credential anywhere: every workspace is joined to
      `<provider>:default`;
    * **un-migrated legacy credentials** — a workspace `worker_env` or the
      server env still carries a provider credential and there is no
      migration record: a boot warning (and a doctor `[fail]`) naming them,
      since nothing reads them any more;
    * **already migrated** — an un-restored migration backup exists; nothing
      is auto-joined.
  """
  # async: false — toggles Application env and System env other tests read.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Accounts.Enablement
  alias Arbiter.Accounts.MissingCredentialError
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
  @retired_var "ARBITER_PROVIDER_ACCOUNTS"

  setup do
    prev_resolution = Application.get_env(:arbiter, :provider_accounts_resolution)
    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_env = for var <- [@oauth_var, @retired_var], into: %{}, do: {var, System.get_env(var)}

    Application.put_env(:arbiter, :worker_isolate_config, false)
    Application.delete_env(:arbiter, :provider_accounts_resolution)
    Enum.each(prev_env, fn {var, _} -> System.delete_env(var) end)

    on_exit(fn ->
      restore_app(:provider_accounts_resolution, prev_resolution)
      restore_app(:worker_isolate_config, prev_isolate)

      Enum.each(prev_env, fn
        {var, nil} -> System.delete_env(var)
        {var, value} -> System.put_env(var, value)
      end)
    end)

    :ok
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app(key, val), do: Application.put_env(:arbiter, key, val)

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

  describe "before the boot has classified the install" do
    test "status is unresolved and nothing is auto-joined" do
      assert Enablement.status().decision == :unresolved
      refute Enablement.auto_join?()
      assert linked_account(workspace(), :claude) == nil
    end
  end

  describe "the retired ARBITER_PROVIDER_ACCOUNTS switch" do
    test "config no longer carries the flag" do
      for file <- ~w(config.exs runtime.exs test.exs) do
        config = File.read!(Path.join([File.cwd!(), "../../config", file]))
        refute config =~ "provider_accounts_enabled", "#{file} still configures the flag"
        refute config =~ @retired_var, "#{file} still reads #{@retired_var}"
      end
    end

    test "an explicit 0 no longer keeps a legacy chain: the boot warns and it is ignored" do
      ws = workspace()
      System.put_env(@retired_var, "0")

      log =
        capture_log(fn ->
          assert %{decision: :no_legacy_credentials} = Enablement.resolve()
        end)

      assert log =~ "[warning]"
      assert log =~ "#{@retired_var}=0"
      assert log =~ "no longer read"
      assert Enablement.join_defaults() == [{ws.id, :claude, :ok}]
    end

    test "unset, the boot says nothing about it" do
      log = capture_log(fn -> Enablement.resolve() end)
      refute log =~ @retired_var
    end
  end

  describe "fresh install" do
    test "no workspaces at all is fresh" do
      assert %{decision: :no_legacy_credentials} = Enablement.resolve()
      assert Enablement.auto_join?()
    end

    test "workspaces without any provider credential are joined to <provider>:default" do
      ws = workspace(%{"LOG_LEVEL" => %{"value" => "debug"}})

      assert %{decision: :no_legacy_credentials} = Enablement.resolve()
      assert Enablement.auto_join?()

      assert Enablement.join_defaults() == [{ws.id, :claude, :ok}]
      assert linked_account(ws, :claude) == {:claude, "default"}
    end

    test "the boot child classifies and joins the existing workspaces on the primary" do
      ws = workspace()

      assert BootProviderAccounts.start_link(primary?: true) == :ignore
      assert Enablement.status().decision == :no_legacy_credentials
      assert linked_account(ws, :claude) == {:claude, "default"}
    end

    test "a non-primary boot classifies but writes nothing" do
      ws = workspace()

      assert BootProviderAccounts.start_link(primary?: false) == :ignore
      assert Enablement.status().decision == :no_legacy_credentials
      assert linked_account(ws, :claude) == nil
    end

    test "a workspace created after boot is joined to claude:default" do
      Enablement.resolve()

      ws = workspace()
      assert linked_account(ws, :claude) == {:claude, "default"}
    end

    test "a workspace whose credential its account already supplies is not legacy" do
      ws = token_workspace("same-token")
      account_with_credential(ws, "same-token")

      assert %{decision: :no_legacy_credentials, stranded_workspaces: []} = Enablement.resolve()
    end
  end

  describe "legacy credentials and no migration record" do
    test "a workspace worker_env credential is named in a loud boot warning" do
      ws = token_workspace()

      log =
        capture_log(fn ->
          assert %{decision: :unmigrated_legacy_credentials} = resolution = Enablement.resolve()
          assert resolution.stranded_workspaces == [ws.name]
        end)

      assert log =~ "[warning]"
      assert log =~ ws.name
      assert log =~ "MissingCredentialError"
      assert log =~ "docs/provider-accounts-release-runbook.md"
    end

    test "nothing falls back to the legacy token: the spawn raises instead" do
      ws = token_workspace("legacy-blob-token")
      {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
      capture_log(fn -> Enablement.resolve() end)

      assert_raise MissingCredentialError, fn -> ConfigDir.oauth_token(ws) end
      assert_raise MissingCredentialError, fn -> WorkerEnv.resolve(task.id) end
    end

    test "a server-env-only token is named, and is not a spawn credential" do
      workspace()
      System.put_env(@oauth_var, "server-env-token")

      log =
        capture_log(fn ->
          assert %{decision: :unmigrated_legacy_credentials, server_env_token?: true} =
                   Enablement.resolve()
        end)

      assert log =~ "#{@oauth_var} in the server environment"
      assert ConfigDir.oauth_token(nil) == nil
    end

    test "a fully rolled-back migration counts as no migration record" do
      ws = token_workspace()
      backup(ws, restored: true)

      capture_log(fn ->
        assert %{decision: :unmigrated_legacy_credentials} = Enablement.resolve()
      end)
    end

    test "nothing is auto-joined" do
      ws = token_workspace()

      capture_log(fn -> assert BootProviderAccounts.start_link(primary?: true) == :ignore end)

      refute Enablement.auto_join?()
      assert linked_account(ws, :claude) == nil
      assert linked_account(workspace(), :claude) == nil
    end

    test "status reports it for the doctor" do
      ws = token_workspace()
      capture_log(fn -> Enablement.resolve() end)

      assert %{decision: :unmigrated_legacy_credentials, stranded_workspaces: [name]} =
               Enablement.status()

      assert name == ws.name
    end
  end

  describe "already migrated install" do
    test "an un-restored migration backup is :migrated" do
      ws = workspace()
      backup(ws)

      assert %{decision: :migrated} = Enablement.resolve()
    end

    test "a leftover server-env token does not change a migrated install's decision" do
      ws = workspace()
      backup(ws)
      System.put_env(@oauth_var, "inert-server-token")

      assert %{decision: :migrated, server_env_token?: true} = Enablement.resolve()
    end

    test "a migrated install is not auto-joined — its links are the operator's" do
      ws = workspace()
      backup(ws)

      assert BootProviderAccounts.start_link(primary?: true) == :ignore
      refute Enablement.auto_join?()
      assert linked_account(ws, :claude) == nil
    end

    test "status still names a straggler added since the migration" do
      backup(workspace())
      Enablement.resolve()
      ws = token_workspace()

      assert %{decision: :migrated, stranded_workspaces: [name]} = Enablement.status()
      assert name == ws.name
    end
  end
end
