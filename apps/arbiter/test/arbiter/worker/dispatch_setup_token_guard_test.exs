defmodule Arbiter.Worker.DispatchSetupTokenGuardTest do
  @moduledoc """
  bd-80ecol: a Claude dispatch whose workspace resolves no setup token is
  refused before anything spawns — an auth-shaped hold plus exactly one
  escalation naming the fix — instead of the worker being handed a copy of
  the operator's `.credentials.json` (mode B, whose refresh-token rotation
  locks the operator out).
  """
  use Arbiter.DataCase, async: false

  @moduletag :capture_log

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{Dispatch, StopReason}

  require Ash.Query

  setup do
    prev_repos = Application.get_env(:arbiter, :repo_paths)
    prev_isolate = Application.get_env(:arbiter, :worker_isolate_config)
    prev_dir = Application.get_env(:arbiter, :worker_config_dir)

    prev_env =
      for var <- ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR), into: %{} do
        {var, System.get_env(var)}
      end

    # A fake operator config dir holding a login, and an isolated worker dir.
    # Isolation is on so a mode-B copy, if one happened, would land in `target`.
    base = Path.join(System.tmp_dir!(), "dstg-#{System.unique_integer([:positive])}")
    source = Path.join(base, "operator")
    target = Path.join(base, "worker")
    File.mkdir_p!(source)
    File.write!(Path.join(source, ".credentials.json"), ~s({"refreshToken":"operator"}))

    Application.put_env(:arbiter, :repo_paths, %{"test/repo" => "/tmp"})
    Application.put_env(:arbiter, :worker_isolate_config, true)
    Application.put_env(:arbiter, :worker_config_dir, target)
    System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")
    System.delete_env("ANTHROPIC_API_KEY")
    System.put_env("CLAUDE_CONFIG_DIR", source)

    on_exit(fn ->
      restore_app(:repo_paths, prev_repos)
      restore_app(:worker_isolate_config, prev_isolate)
      restore_app(:worker_config_dir, prev_dir)

      Enum.each(prev_env, fn
        {var, nil} -> System.delete_env(var)
        {var, v} -> System.put_env(var, v)
      end)

      File.rm_rf!(base)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "setup-token-ws-#{System.unique_integer([:positive])}"})

    {:ok, ws: ws, target: target}
  end

  defp restore_app(key, nil), do: Application.delete_env(:arbiter, key)
  defp restore_app(key, val), do: Application.put_env(:arbiter, key, val)

  defp account(slug) do
    {:ok, acct} = Ash.create(ProviderAccount, %{provider: :claude, slug: slug, enabled: true})
    acct
  end

  defp credential(account) do
    {:ok, _} =
      Ash.create(ProviderCredential, %{
        provider_account_id: account.id,
        kind: :oauth_token,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        fingerprint: Base.encode16(:crypto.hash(:sha256, "setup-token"), case: :lower),
        active: true,
        secret: "setup-token"
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

  defp task(ws, title \\ "setup-token guard") do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    task
  end

  # The real-agent path (`start_claude: true`) with the guard on, stopping short
  # of a worktree: a dispatch the guard lets through fails on :missing_worktree.
  defp dispatch(task) do
    Dispatch.dispatch(task.id,
      force: true,
      repo: "test/repo",
      start_driver: false,
      start_claude: true,
      provision_worktree: false
    )
  end

  defp escalations(ws) do
    Message
    |> Ash.Query.filter(workspace_id == ^ws.id and kind == :escalation)
    |> Ash.read!()
    |> Enum.filter(&(&1.subject =~ "setup token"))
  end

  defp assert_refused_untouched(task, result) do
    assert {:error, {:setup_token_missing, %StopReason{category: :auth_expired} = reason}} =
             result

    {:ok, reloaded} = Ash.get(Issue, task.id)
    assert reloaded.state == task.state
    assert Worker.whereis(task.id) == nil
    reason
  end

  describe "provider accounts" do
    test "an account with no credential rows refuses, escalates once, copies nothing", %{
      ws: ws,
      target: target
    } do
      link(ws, account("bare"))
      t1 = task(ws)

      reason = assert_refused_untouched(t1, dispatch(t1))
      assert reason.remediation =~ "arb account rotate claude:bare --kind oauth_token"

      # A retry of the same task, and a second task in the same workspace, are
      # held too — without a second page.
      assert_refused_untouched(t1, dispatch(t1))
      t2 = task(ws, "second")
      assert_refused_untouched(t2, dispatch(t2))

      assert [page] = escalations(ws)
      assert page.body =~ "arb account rotate claude:bare"
      assert page.to_ref == Message.coordinator_ref()

      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "a workspace with no account join refuses and names attach + rotate", %{
      ws: ws,
      target: target
    } do
      t = task(ws)

      reason = assert_refused_untouched(t, dispatch(t))
      assert reason.remediation =~ "arb account attach #{ws.id} claude"

      assert [page] = escalations(ws)
      assert page.body =~ "arb account attach #{ws.id} claude"
      refute File.exists?(Path.join(target, ".credentials.json"))
    end

    test "mode A — a joined account with a setup token dispatches as before", %{ws: ws} do
      acct = account("good")
      credential(acct)
      link(ws, acct)
      t = task(ws)

      assert {:error, :missing_worktree} = dispatch(t)
      assert escalations(ws) == []
    end
  end

  # P13 (bd-9gqj8e): the flag-off legacy chain is gone, so what used to let
  # an un-migrated workspace dispatch no longer does.
  describe "legacy credential sources no longer count" do
    test "a server-env setup token alone refuses, naming attach + rotate", %{ws: ws} do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "server-token")
      t = task(ws)

      reason = assert_refused_untouched(t, dispatch(t))
      assert reason.remediation =~ "arb account attach #{ws.id} claude"
      assert [_page] = escalations(ws)
    end

    test "a worker_env token alone refuses, naming the migration", %{ws: ws} do
      ws
      |> Ash.Changeset.for_update(:update, %{
        worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "blob", "secret" => true}}
      })
      |> Ash.update!()

      t = task(ws)

      reason = assert_refused_untouched(t, dispatch(t))
      assert reason.remediation =~ "arbiter.accounts.migrate"
      assert [_page] = escalations(ws)
    end
  end

  test "a non-Claude dispatch is not subject to the guard", %{ws: ws} do
    t = task(ws)

    assert {:error, :missing_worktree} =
             Dispatch.dispatch(t.id,
               force: true,
               repo: "test/repo",
               start_driver: false,
               start_claude: true,
               provision_worktree: false,
               agent_type: :codex
             )
  end
end
