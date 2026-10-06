defmodule Arbiter.Accounts.LegacyChainRemovedTest do
  @moduledoc """
  P13 (bd-9gqj8e): the flip release. Provider accounts are the only source
  of a spawn's provider credential — there is no flag to turn them off, and
  `ConfigDir`'s pre-P4 legacy chain (workspace `worker_env` → server env →
  install-wide unambiguous workspace token) is gone.

  Every test here plants the legacy sources a flag-off install used to read
  (a `CLAUDE_CODE_OAUTH_TOKEN` in the server's own environment, one in a
  workspace's `worker_env`) and asserts that no spawn path picks them up:
  each authenticates from the account, or carries no credential at all.

  The spawn paths are driven for real where they can be — the watchdog's
  `Preflight` probe and the code-review check both exec a stub `claude` on
  `PATH` that records the `CLAUDE_CODE_OAUTH_TOKEN` it was started with.
  """
  # async: false — mutates PATH and the server environment.
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.MissingCredentialError
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.Preflight
  alias Arbiter.Quota
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.WorkerEnv
  alias Arbiter.Workflows.CodeReview.Checks

  @oauth_var "CLAUDE_CODE_OAUTH_TOKEN"
  @server_token "legacy-server-env-token"

  setup do
    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_invoker = Application.get_env(:arbiter, :code_review_invoker)

    prev_env =
      for var <- [@oauth_var, "ANTHROPIC_API_KEY", "PATH"], into: %{} do
        {var, System.get_env(var)}
      end

    Application.put_env(:arbiter, :worker_isolate_config, false)
    Application.delete_env(:arbiter, :code_review_invoker)
    System.delete_env("ANTHROPIC_API_KEY")
    # The legacy chain's source 2: a flag-off install handed this to every
    # spawn whose workspace carried no token of its own.
    System.put_env(@oauth_var, @server_token)

    on_exit(fn ->
      restore_app(:worker_isolate_config, prev_isolate)
      restore_app(:code_review_invoker, prev_invoker)

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
    Ash.create!(Workspace, %{name: "p13-#{uniq()}", worker_env: worker_env})
  end

  defp blob_token_workspace(token) do
    workspace(%{@oauth_var => %{"value" => token, "secret" => true}})
  end

  # `ws` joined to a fresh Claude account holding `secret` as its active
  # setup token.
  defp on_account(ws, secret) do
    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "p13-#{uniq()}"})

    Ash.create!(ProviderCredential, %{
      provider_account_id: account.id,
      kind: :oauth_token,
      env_var: @oauth_var,
      fingerprint: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
      secret: secret
    })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    account
  end

  # A stub `claude` first on PATH: records the setup token it was started
  # with, then answers like a successful `--print` round-trip.
  defp stub_claude!(dir) do
    record = Path.join(dir, "token")
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "claude"), """
    #!/bin/sh
    printf '%s' "${#{@oauth_var}-<unset>}" > '#{record}'
    cat >/dev/null
    echo '{"type":"result","subtype":"success","is_error":false,"result":"pong"}'
    """)

    File.chmod!(Path.join(bin, "claude"), 0o755)
    System.put_env("PATH", bin <> ":" <> System.get_env("PATH", ""))
    record
  end

  describe "the legacy chain is gone" do
    test "the server environment token is never a spawn credential" do
      ws = workspace()

      assert ConfigDir.oauth_token(ws) == nil
      assert ConfigDir.oauth_token() == nil
      # Unset explicitly, so the BEAM's own env cannot leak into the child.
      assert ConfigDir.env(ws) == [{@oauth_var, false}]
      assert ConfigDir.env() == [{@oauth_var, false}]
    end

    test "a sole workspace blob token is not the install-wide answer" do
      _ws = blob_token_workspace("only-blob-token")

      assert ConfigDir.oauth_token() == nil
    end

    test "a workspace whose worker_env alone carries the token raises, never reads it" do
      ws = blob_token_workspace("stranded-blob-token")

      assert_raise MissingCredentialError, fn -> ConfigDir.oauth_token(ws) end
      assert_raise MissingCredentialError, fn -> ConfigDir.env(ws.id) end
    end
  end

  describe "every spawn path authenticates from the account" do
    test "worker: Claude.spawn_env/1 and WorkerEnv.resolve/1 carry the account token" do
      ws = blob_token_workspace("stale-blob-token")
      on_account(ws, "worker-account-token")
      {:ok, task} = Ash.create(Issue, %{title: "p13", workspace_id: ws.id})

      assert Claude.spawn_env(workspace: ws) == [
               {@oauth_var, "worker-account-token"},
               {"KUBECONFIG", "/dev/null"}
             ]

      {pairs, secrets} = WorkerEnv.resolve(task.id)
      assert pairs == [{@oauth_var, "worker-account-token"}]
      assert secrets == ["worker-account-token"]
    end

    @tag :tmp_dir
    @tag :capture_log
    test "watchdog probe: the workspace-less Preflight runs on the install-wide account token",
         %{tmp_dir: tmp_dir} do
      record = stub_claude!(tmp_dir)
      _stray = blob_token_workspace("stray-blob-token")
      on_account(workspace(), "install-account-token")

      assert :ok = Preflight.check(Claude, timeout_ms: 10_000)
      assert File.read!(record) == "install-account-token"
    end

    @tag :tmp_dir
    @tag :capture_log
    test "watchdog probe: declines when only legacy sources hold a token", %{tmp_dir: tmp_dir} do
      record = stub_claude!(tmp_dir)
      _stray = blob_token_workspace("stray-blob-token")

      assert {:error, {:no_setup_token, _summary}} = Claude.auth_probe_argv([])

      assert {:error, %Arbiter.Worker.StopReason{category: category}} =
               Preflight.check(Claude, timeout_ms: 10_000)

      refute category == :auth_expired
      refute File.exists?(record)
    end

    @tag :tmp_dir
    @tag :capture_log
    test "review check: the reviewer spawn carries its workspace account token",
         %{tmp_dir: tmp_dir} do
      record = stub_claude!(tmp_dir)
      ws = blob_token_workspace("stale-blob-token")
      on_account(ws, "review-account-token")

      Checks.run("diff --git a/x b/x\n+changed\n", %{workspace: ws})

      assert File.read!(record) == "review-account-token"
    end

    @tag :tmp_dir
    @tag :capture_log
    test "review check: a workspace-less review never falls back to the server token",
         %{tmp_dir: tmp_dir} do
      record = stub_claude!(tmp_dir)

      Checks.run("diff --git a/x b/x\n+changed\n", %{})

      assert File.read!(record) == "<unset>"
    end

    # The quota poll relabels a 401 on the operator's credentials file as a
    # lapsed operator login only when the account's workers run on a setup
    # token of their own. That is the account's `:oauth_token` row alone: a
    # server-env token no worker reads any more vouches for nothing.
    @tag :tmp_dir
    test "quota probe: worker auth is judged by the account, not the server env token",
         %{tmp_dir: tmp_dir} do
      account_id =
        Ash.create!(ProviderAccount, %{provider: :claude, slug: "p13-quota-#{uniq()}"}).id

      File.write!(
        Path.join(tmp_dir, ".credentials.json"),
        Jason.encode!(%{"claudeAiOauth" => %{"accessToken" => "p13-seeded-token"}})
      )

      on_exit(fn -> Arbiter.Quota.OAuthUsage.reset_cooldown!("p13-seeded-token") end)

      Req.Test.stub(Arbiter.Quota.OAuthUsage.HTTP, fn conn ->
        Plug.Conn.send_resp(conn, 401, "")
      end)

      assert {:error, {:http_error, 401}} =
               Quota.capture_oauth_usage(account_id,
                 source_dir: tmp_dir,
                 plug: {Req.Test, Arbiter.Quota.OAuthUsage.HTTP}
               )
    end
  end
end
