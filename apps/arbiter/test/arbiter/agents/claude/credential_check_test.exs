defmodule Arbiter.Agents.Claude.CredentialCheckTest do
  @moduledoc """
  bd-80ecol: "does a Claude spawn for this workspace have a credential of its
  own?" — the question the dispatch guard and `arb server doctor` ask now that
  a token-less spawn is no longer quietly handed a copy of the operator's
  `.credentials.json` (mode B).
  """
  use Arbiter.DataCase, async: false

  @moduletag :capture_log

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.Claude.CredentialCheck
  alias Arbiter.Tasks.Workspace

  setup do
    prev_flag = Application.get_env(:arbiter, :provider_accounts_enabled)

    # Both are routinely present in a worker's own shell; either would answer
    # the check for every test in this file.
    prev_env =
      for var <- ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY), into: %{} do
        {var, System.get_env(var)}
      end

    Enum.each(prev_env, fn {var, _} -> System.delete_env(var) end)

    on_exit(fn ->
      case prev_flag do
        nil -> Application.delete_env(:arbiter, :provider_accounts_enabled)
        v -> Application.put_env(:arbiter, :provider_accounts_enabled, v)
      end

      Enum.each(prev_env, fn
        {var, nil} -> System.delete_env(var)
        {var, v} -> System.put_env(var, v)
      end)
    end)

    :ok
  end

  defp flag(on?), do: Application.put_env(:arbiter, :provider_accounts_enabled, on?)

  defp workspace(attrs \\ %{}) do
    {:ok, ws} =
      Ash.create(
        Workspace,
        Map.merge(%{name: "credcheck-#{System.unique_integer([:positive])}"}, attrs)
      )

    ws
  end

  defp account(opts \\ []) do
    {:ok, acct} =
      Ash.create(ProviderAccount, %{
        provider: :claude,
        slug: Keyword.get(opts, :slug, "acct-#{System.unique_integer([:positive])}"),
        enabled: Keyword.get(opts, :enabled, true)
      })

    acct
  end

  defp credential(account, env_var \\ "CLAUDE_CODE_OAUTH_TOKEN", secret \\ "setup-token") do
    {:ok, _} =
      Ash.create(ProviderCredential, %{
        provider_account_id: account.id,
        kind: if(env_var == "ANTHROPIC_API_KEY", do: :api_key, else: :oauth_token),
        env_var: env_var,
        fingerprint: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
        active: true,
        secret: secret
      })

    :ok
  end

  defp link(ws, account) do
    {:ok, _} =
      Ash.create(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })

    :ok
  end

  describe "provider accounts on" do
    setup do
      flag(true)
      :ok
    end

    test "a workspace joined to an account with a setup token is ok (mode A)" do
      ws = workspace()
      acct = account()
      credential(acct)
      link(ws, acct)

      assert CredentialCheck.check(ws) == :ok
    end

    test "an account with no credential rows is missing and names the rotate fix" do
      ws = workspace()
      acct = account(slug: "nocred")
      link(ws, acct)

      assert {:missing, missing} = CredentialCheck.check(ws)
      assert missing.reason == :no_credential
      assert missing.account == "nocred"
      assert missing.workspace_id == ws.id
      assert missing.fix =~ "arb account rotate claude:nocred --kind oauth_token"
      assert missing.fix =~ "--env-var CLAUDE_CODE_OAUTH_TOKEN"
    end

    test "a parked account is missing even with a credential, and says it is parked" do
      ws = workspace()
      acct = account(slug: "parked", enabled: false)
      credential(acct)
      link(ws, acct)

      assert {:missing, %{reason: :account_disabled, account: "parked"} = missing} =
               CredentialCheck.check(ws)

      assert missing.fix =~ "parked"
    end

    test "a workspace with no account join is missing and names attach + rotate" do
      ws = workspace()

      assert {:missing, missing} = CredentialCheck.check(ws)
      assert missing.reason == :no_account
      assert missing.account == nil
      assert missing.fix =~ "arb account attach #{ws.id} claude <slug>"
      assert missing.fix =~ "arb account rotate claude:<slug> --kind oauth_token"
    end

    test "a token still in worker_env but on no account is missing, not a raise" do
      ws =
        workspace(%{
          worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "blob", "secret" => true}}
        })

      assert {:missing, %{reason: :credential_not_migrated} = missing} =
               CredentialCheck.check(ws)

      assert missing.fix =~ "arbiter.accounts.migrate"
    end

    test "an account-supplied ANTHROPIC_API_KEY is a credential of the workspace's own" do
      ws = workspace()
      acct = account()
      credential(acct, "ANTHROPIC_API_KEY", "sk-ant-key")
      link(ws, acct)

      assert CredentialCheck.check(ws) == :ok
    end

    test "a workspace-less check takes the install-wide account credential" do
      acct = account()
      credential(acct)
      link(workspace(), acct)

      assert CredentialCheck.check(nil) == :ok
    end

    test "a workspace-less check with no account credential is missing" do
      assert {:missing, %{reason: :no_install_credential, workspace_id: nil}} =
               CredentialCheck.check(nil)
    end
  end

  describe "provider accounts off" do
    setup do
      flag(false)
      :ok
    end

    test "a worker_env token is ok" do
      ws =
        workspace(%{
          worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "ws-token", "secret" => true}}
        })

      assert CredentialCheck.check(ws) == :ok
    end

    test "a server-env token is ok" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")
      assert CredentialCheck.check(workspace()) == :ok
    end

    test "no token anywhere is missing and names both fixes" do
      ws = workspace()

      assert {:missing, missing} = CredentialCheck.check(ws)
      assert missing.reason == :no_token
      assert missing.fix =~ "CLAUDE_CODE_OAUTH_TOKEN"
      assert missing.fix =~ "claude setup-token"
    end

    test "a worker_env ANTHROPIC_API_KEY is a credential of the workspace's own" do
      ws =
        workspace(%{
          worker_env: %{"ANTHROPIC_API_KEY" => %{"value" => "sk-ant", "secret" => true}}
        })

      assert CredentialCheck.check(ws) == :ok
    end
  end

  describe "API keys, either flag" do
    test "a server-env ANTHROPIC_API_KEY is inherited by every spawn, so it is ok" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-server")
      assert CredentialCheck.check(workspace()) == :ok
      assert CredentialCheck.check(nil) == :ok
    end

    test "an agent credentials_ref that resolves is ok" do
      ws =
        workspace(%{
          config: %{"agent" => %{"type" => "claude", "config" => %{"credentials_ref" => "lit"}}}
        })

      assert CredentialCheck.check(ws) == :ok
    end

    test "an agent credentials_ref pointing at an unset env var is not" do
      ws =
        workspace(%{
          config: %{
            "agent" => %{
              "type" => "claude",
              "config" => %{"api_keys" => ["env:ARBITER_TEST_UNSET_KEY_80ECOL"]}
            }
          }
        })

      assert {:missing, _} = CredentialCheck.check(ws)
    end
  end

  describe "workspace_report/0" do
    test "lists each Claude workspace with no credential, and skips the rest" do
      flag(true)
      ok_ws = workspace()
      acct = account()
      credential(acct)
      link(ok_ws, acct)

      missing_ws = workspace()

      _codex_only =
        workspace(%{
          config: %{"agent" => %{"type" => "codex"}, "review_agent" => %{"type" => "codex"}}
        })

      report = CredentialCheck.workspace_report()

      assert report.checked == 2
      assert [%{workspace_id: id, provider: :claude, reason: :no_account}] = report.missing
      assert id == missing_ws.id
    end

    test "a Claude reviewer alone makes the workspace a Claude workspace" do
      flag(true)

      ws =
        workspace(%{
          config: %{"agent" => %{"type" => "codex"}, "review_agent" => %{"type" => "claude"}}
        })

      assert %{checked: 1, missing: [%{workspace_id: id}]} = CredentialCheck.workspace_report()
      assert id == ws.id
    end
  end
end
