defmodule Arbiter.Agents.Claude.ConfigDirWorkspaceTest do
  @moduledoc """
  bd-bw3466: the credential-seeding gate against a *persisted* workspace.

  This file covers the things that need real rows — resolving a workspace by
  **id**, and the install-wide *account* credential that the workspace-less
  call sites (`Arbiter.Agents.CredentialWatchdog`,
  `workflows/code_review/checks.ex`) rely on. Since the P13 flip
  (bd-9gqj8e) that account credential is the only workspace-less source; the
  legacy install-wide `worker_env` token and the server env are gone.

  The load-bearing property here is the **lockstep invariant**: the
  operator's `.credentials.json` is never seeded, and `env/1` emits an
  explicit `{"CLAUDE_CODE_OAUTH_TOKEN", false}` unset rather than merely
  omitting the pair when nothing is configured, so a spawn that carries no
  token also carries an explicit instruction to unset any value it would
  otherwise inherit from the arbiter server's own process environment
  (bd-6umoh9's dual-refresher race). `"env/1: never seeded; a token pair or
  an explicit unset"` below asserts the property directly across every
  shape this file covers.
  """
  # async: false — toggles Application/System env that other tests read.
  use Arbiter.DataCase, async: false

  # The ambiguous-credential case (`Credentials.install_credential/1`) logs a
  # warning by design; capture it so the run stays readable (logs still
  # surface on failure).
  @moduletag :capture_log

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Tasks.Workspace

  setup do
    uniq = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "arbiter-configdir-ws-test-#{uniq}")
    source = Path.join(base, "source")
    target = Path.join(base, "worker")
    File.mkdir_p!(source)
    File.write!(Path.join(source, ".credentials.json"), ~s({"token":"operator"}))

    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_dir = Application.get_env(:arbiter, :worker_config_dir)
    prev_src = System.get_env("CLAUDE_CONFIG_DIR")
    prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")

    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_config_dir, target)
    System.put_env("CLAUDE_CONFIG_DIR", source)
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

    on_exit(fn ->
      restore_app(:worker_isolate_config, prev_isolate)
      restore_app(:worker_config_dir, prev_dir)
      restore_sys("CLAUDE_CONFIG_DIR", prev_src)
      restore_sys("CLAUDE_CODE_OAUTH_TOKEN", prev_token)
      File.rm_rf!(base)
    end)

    {:ok, source: source, target: target}
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app(key, val), do: Application.put_env(:arbiter, key, val)
  defp restore_sys(name, nil), do: System.delete_env(name)
  defp restore_sys(name, val), do: System.put_env(name, val)

  defp workspace_with_env(worker_env \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cfgdir-#{System.unique_integer([:positive])}",
        worker_env: worker_env
      })

    ws
  end

  defp account(opts \\ []) do
    {:ok, acct} =
      Ash.create(ProviderAccount, %{
        provider: :claude,
        slug: "acct-#{System.unique_integer([:positive])}",
        enabled: Keyword.get(opts, :enabled, true)
      })

    acct
  end

  defp credential(account, secret) do
    {:ok, cred} =
      Ash.create(ProviderCredential, %{
        provider_account_id: account.id,
        kind: :oauth_token,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
        active: true,
        secret: secret
      })

    cred
  end

  defp link_account(ws, account) do
    {:ok, link} =
      Ash.create(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: account.provider,
        provider_account_id: account.id
      })

    link
  end

  # A workspace joined to a fresh account holding `token`.
  defp token_workspace(token \\ "ws-oauth-token") do
    ws = workspace_with_env()
    acct = account()
    credential(acct, token)
    link_account(ws, acct)
    ws
  end

  describe "resolving a workspace by id" do
    test "env/1 accepts a workspace id and injects that workspace's token", %{target: target} do
      ws = token_workspace()

      assert ConfigDir.env(ws.id) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "ensure/1 with a workspace id skips seeding .credentials.json", %{target: target} do
      ws = token_workspace()

      assert {:ok, ^target} = ConfigDir.ensure(ws.id)
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "an unknown workspace id resolves no token rather than raising", %{target: target} do
      assert ConfigDir.oauth_token("no-such-workspace") == nil
      assert {:ok, ^target} = ConfigDir.ensure("no-such-workspace")

      refute File.exists?(Path.join(target, ".credentials.json"))
    end
  end

  describe "install-wide account credential for workspace-less call sites" do
    test "ensure/0 never seeds credentials, with or without an account token", %{
      target: target
    } do
      # bd-80ecol: a workspace-less spawn with no token anywhere used to get
      # the operator's grant copied in (mode B). It no longer does...
      assert {:ok, ^target} = ConfigDir.ensure()
      refute File.exists?(Path.join(target, ".credentials.json"))

      # ...and an account token does not change that either.
      _ = token_workspace()

      assert {:ok, ^target} = ConfigDir.ensure()
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "a workspace-less spawn carries the unambiguous install-wide token", %{target: target} do
      acct = account()
      credential(acct, "ws-oauth-token")
      link_account(workspace_with_env(), acct)
      link_account(workspace_with_env(), acct)

      # One account, one token, however many workspaces share it — carry it.
      # Leaving it off would leave the CredentialWatchdog probe with no
      # credential at all.
      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "accounts that disagree leave a workspace-less spawn with no credential", %{
      target: target
    } do
      _ = token_workspace()
      _ = token_workspace("other")

      # Two distinct values: we refuse to guess, so no token is injected —
      # and (bd-80ecol) the operator's credentials are not copied in instead.
      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]

      assert {:ok, ^target} = ConfigDir.ensure()
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "the workspace-bearing spawn is unaffected by an ambiguous install", %{target: target} do
      ws = token_workspace()
      _ = token_workspace("other")

      assert ConfigDir.env(ws) == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", "ws-oauth-token"}
             ]
    end

    test "a workspace blob token is never the install-wide answer", %{target: target} do
      _ =
        workspace_with_env(%{
          "CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "blob-token", "secret" => true}
        })

      assert ConfigDir.env() == [
               {"CLAUDE_CONFIG_DIR", target},
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
             ]
    end

    # bd-80ecol replaced bd-bw3466's "suppressed ⟺ injected" lockstep: the
    # seed is now suppressed for every shape, so a spawn with no token has no
    # credential at all. That is deliberate — `CredentialCheck` refuses the
    # dispatch, and the watchdog probe declines to run (`Claude.auth_probe_argv/1`),
    # instead of either one quietly authenticating as the operator.
    test "ensure/0 never seeds, whatever the install-wide token shape", %{target: target} do
      for build <- [
            fn -> :none end,
            fn -> token_workspace() end,
            fn -> {token_workspace(), token_workspace("other")} end
          ] do
        _ = build.()

        assert {:ok, ^target} = ConfigDir.ensure()
        refute File.exists?(Path.join(target, ".credentials.json"))
      end
    end
  end

  describe "env/1: never seeded; a token pair or an explicit unset" do
    # The property under test (bd-80ecol): for any workspace/account shape
    # the operator's `.credentials.json` is never seeded, and the token pair
    # is either a real token or an explicit `{..., false}` unset — never
    # absent, so a server-process token can't reach the child via
    # Port.open's ambient inheritance (bd-6umoh9).
    defp assert_lockstep(workspace, target) do
      env = ConfigDir.env(workspace)
      token_pair = List.keyfind(env, "CLAUDE_CODE_OAUTH_TOKEN", 0)

      assert {:ok, ^target} = ConfigDir.ensure(workspace)
      refute File.exists?(Path.join(target, ".credentials.json"))

      assert match?({"CLAUDE_CODE_OAUTH_TOKEN", token} when is_binary(token), token_pair) or
               token_pair == {"CLAUDE_CODE_OAUTH_TOKEN", false}
    end

    test "no workspace, no account anywhere", %{target: target} do
      assert_lockstep(nil, target)
    end

    test "workspace joined to an account credential", %{target: target} do
      assert_lockstep(token_workspace(), target)
    end

    test "workspace with no account, server env set", %{target: target} do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")
      ws = workspace_with_env(%{"LOG_LEVEL" => %{"value" => "debug", "secret" => false}})

      assert_lockstep(ws, target)

      assert List.keyfind(ConfigDir.env(ws), "CLAUDE_CODE_OAUTH_TOKEN", 0) ==
               {"CLAUDE_CODE_OAUTH_TOKEN", false}
    end

    test "no workspace, one unambiguous install-wide account credential", %{target: target} do
      _ = token_workspace("install-token")

      assert_lockstep(nil, target)
    end
  end
end
