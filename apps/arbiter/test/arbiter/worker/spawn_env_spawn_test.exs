defmodule Arbiter.Worker.SpawnEnvSpawnTest do
  # bd-7r0qrj (GitHub #143): spawn each adapter's worker command for real (a
  # stub CLI that dumps its own environment) with the server's master secrets
  # and operator handles set, and assert what actually reaches the child.
  #
  # async: false — mutates the process-global OS environment, the shared
  # sandbox, and the global worker registry.
  use Arbiter.DataCase, async: false

  @moduletag :capture_log
  @moduletag :tmp_dir

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.Codex
  alias Arbiter.Agents.Gemini
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

  @server_env %{
    "ARBITER_CLOAK_KEY" => "leak-cloak",
    "SECRET_KEY_BASE" => "leak-skb",
    "DATABASE_PATH" => "/leak/live.sqlite3",
    "RELEASE_COOKIE" => "leak-cookie",
    "SSH_AUTH_SOCK" => "/leak/ssh-agent.sock",
    "DBUS_SESSION_BUS_ADDRESS" => "unix:path=/leak/nonexistent-bus",
    "ARBITER_SESSIONS_ROOT" => "/leak/sessions",
    "CLAUDE_CODE_OAUTH_TOKEN" => "leak-server-claude",
    "OPENAI_API_KEY" => "leak-server-openai",
    "GEMINI_API_KEY" => "leak-server-gemini",
    # bd-asawcq: an operator who exported a coordinator ARB_TOKEN into the
    # server's environment must not hand it to every worker.
    "ARB_TOKEN" => "leak-server-arb-token"
  }

  @leaked_values Map.values(@server_env)

  setup %{tmp_dir: tmp_dir} do
    previous = Map.new(@server_env, fn {k, _} -> {k, System.get_env(k)} end)
    System.put_env(@server_env)

    on_exit(fn ->
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    dumper = Path.join(tmp_dir, "env_dumper.sh")
    File.write!(dumper, "#!/bin/sh\nenv > \"$1.tmp\"\nmv \"$1.tmp\" \"$1\"\nexit 0\n")
    File.chmod!(dumper, 0o755)

    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    %{dumper: dumper, sup: sup}
  end

  # A workspace linked to a claude, a codex and an antigravity account, each
  # with its own credential — the shape that used to hand all three to every
  # worker.
  defp linked_workspace! do
    {:ok, ws} = Ash.create(Workspace, %{name: "spawn-env-#{System.unique_integer([:positive])}"})

    for {provider, kind, env_var, secret} <- [
          {:claude, :oauth_token, "CLAUDE_CODE_OAUTH_TOKEN", "own-claude-token"},
          {:codex, :api_key, "OPENAI_API_KEY", "own-openai-key"},
          {:antigravity, :api_key, "ANTIGRAVITY_API_KEY", "own-antigravity-key"}
        ] do
      account =
        Ash.create!(ProviderAccount, %{
          provider: provider,
          slug: "se-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        Accounts.rotate_credential(account.id, %{kind: kind, env_var: env_var, secret: secret})

      Ash.create!(WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: provider,
        provider_account_id: account.id
      })
    end

    ws
  end

  # Spawn `provider`'s stub worker the way Dispatch does (adapter `spawn_env/1`
  # as the caller-explicit :env) and return the child's environment as a map.
  defp spawn_child_env!(ctx, adapter, provider, ws, adapter_opts \\ [], session_opts \\ []) do
    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})

    {:ok, pid} =
      DynamicSupervisor.start_child(
        ctx.sup,
        {Worker, [task_id: task.id, repo: "arbiter", workspace_id: ws.id]}
      )

    :ok = Worker.advance(pid, :implement)
    dump = Path.join(ctx.tmp_dir, "env-#{provider}-#{System.unique_integer([:positive])}")

    {:ok, _port} =
      ClaudeSession.start(
        [
          owner: pid,
          worktree_path: ctx.tmp_dir,
          command: [ctx.dumper, dump],
          provider: provider,
          env: adapter.spawn_env([workspace: ws, worktree_path: ctx.tmp_dir] ++ adapter_opts)
        ] ++ session_opts
      )

    wait_for_file!(dump)

    dump
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      [k, v] = String.split(line, "=", parts: 2)
      {k, v}
    end)
  end

  defp wait_for_file!(path, tries \\ 100) do
    cond do
      File.exists?(path) ->
        :ok

      tries == 0 ->
        flunk("stub worker never dumped its env to #{path}")

      true ->
        Process.sleep(50)
        wait_for_file!(path, tries - 1)
    end
  end

  defp assert_no_server_secrets(env) do
    for name <- ~w(ARBITER_CLOAK_KEY SECRET_KEY_BASE RELEASE_COOKIE SSH_AUTH_SOCK
                   DBUS_SESSION_BUS_ADDRESS ARBITER_SESSIONS_ROOT) do
      refute Map.has_key?(env, name), "#{name} reached the worker child"
    end

    # DevServerEnv's task-scoped throwaway is the only DATABASE_PATH a worker
    # may see — never the server's own.
    refute env["DATABASE_PATH"] == "/leak/live.sqlite3"
    assert env["DATABASE_PATH"] =~ "arbiter_worker_verify_"

    for value <- @leaked_values, {name, got} <- env do
      refute got == value, "server value for #{name} reached the worker child"
    end
  end

  test "a Claude worker gets its own token and neither a Codex nor a Gemini credential", ctx do
    ws = linked_workspace!()
    env = spawn_child_env!(ctx, Claude, "claude", ws)

    assert_no_server_secrets(env)
    assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "own-claude-token"
    refute Map.has_key?(env, "OPENAI_API_KEY")
    refute Map.has_key?(env, "CODEX_API_KEY")
    refute Map.has_key?(env, "GEMINI_API_KEY")
    refute Map.has_key?(env, "ANTIGRAVITY_API_KEY")
  end

  test "a worker gets its own task's ARB_TOKEN, never the server's (bd-asawcq)", ctx do
    ws = linked_workspace!()
    env = spawn_child_env!(ctx, Claude, "claude", ws, [], arb_token: "the-worker-token")

    assert env["ARB_TOKEN"] == "the-worker-token"

    without = spawn_child_env!(ctx, Claude, "claude", ws)
    refute Map.has_key?(without, "ARB_TOKEN")
  end

  test "a Codex worker gets its own key and no Claude or Gemini credential", ctx do
    ws = linked_workspace!()
    env = spawn_child_env!(ctx, Codex, "codex", ws, api_key: "own-openai-key")

    assert_no_server_secrets(env)
    assert env["OPENAI_API_KEY"] == "own-openai-key"
    refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
    refute Map.has_key?(env, "ANTHROPIC_API_KEY")
    refute Map.has_key?(env, "GEMINI_API_KEY")
    refute Map.has_key?(env, "ANTIGRAVITY_API_KEY")
  end

  test "an agy (Gemini) worker gets no CLAUDE_CODE_OAUTH_TOKEN and no Codex key", ctx do
    ws = linked_workspace!()
    env = spawn_child_env!(ctx, Gemini, "gemini", ws, api_key: "own-gemini-key")

    assert_no_server_secrets(env)
    assert env["GEMINI_API_KEY"] == "own-gemini-key"
    assert env["ANTIGRAVITY_API_KEY"] == "own-antigravity-key"
    refute Map.has_key?(env, "CLAUDE_CODE_OAUTH_TOKEN")
    refute Map.has_key?(env, "OPENAI_API_KEY")
    refute Map.has_key?(env, "CODEX_API_KEY")
  end

  test "the worker keeps what it needs to run: PATH, HOME, ARB_WORKER_BEAD_ID", ctx do
    ws = linked_workspace!()
    env = spawn_child_env!(ctx, Claude, "claude", ws)

    assert env["PATH"] == System.get_env("PATH")
    assert env["HOME"] == System.get_env("HOME")
    assert is_binary(env["ARB_WORKER_BEAD_ID"])
  end

  test "a workspace worker_env var (e.g. a tracker token) still reaches the worker", ctx do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "spawn-env-tracker-#{System.unique_integer([:positive])}",
        worker_env: %{"GH_TOKEN" => %{"value" => "ws-gh-token", "secret" => true}}
      })

    env = spawn_child_env!(ctx, Codex, "codex", ws, api_key: "k")

    assert env["GH_TOKEN"] == "ws-gh-token"
    assert_no_server_secrets(env)
  end

  # The name-based drop only knows the standard credential vars. A credential
  # stored under any other name must still stay with its own provider's workers,
  # so the filter is also applied at the source, by the owning account's provider.
  describe "credentials under non-standard env_var names" do
    defp linked_custom_workspace! do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "spawn-env-custom-#{System.unique_integer([:positive])}"})

      for {provider, kind, env_var, secret} <- [
            {:claude, :oauth_token, "CLAUDE_CODE_OAUTH_TOKEN", "own-claude-token"},
            {:codex, :api_key, "MY_CUSTOM_CODEX_KEY", "custom-codex-secret"},
            {:antigravity, :api_key, "GOOGLE_API_KEY", "custom-agy-secret"}
          ] do
        account =
          Ash.create!(ProviderAccount, %{
            provider: provider,
            slug: "sc-#{System.unique_integer([:positive])}"
          })

        {:ok, _} =
          Accounts.rotate_credential(account.id, %{kind: kind, env_var: env_var, secret: secret})

        Ash.create!(WorkspaceProviderAccount, %{
          workspace_id: ws.id,
          provider: provider,
          provider_account_id: account.id
        })
      end

      ws
    end

    test "a credential linked to Codex under a custom name does not reach a Claude worker", ctx do
      env = spawn_child_env!(ctx, Claude, "claude", linked_custom_workspace!())

      assert env["CLAUDE_CODE_OAUTH_TOKEN"] == "own-claude-token"
      refute Map.has_key?(env, "MY_CUSTOM_CODEX_KEY")
      refute Map.has_key?(env, "GOOGLE_API_KEY")
      refute "custom-codex-secret" in Map.values(env)
      refute "custom-agy-secret" in Map.values(env)
    end

    test "it reaches the Codex worker only; the antigravity one reaches only agy", ctx do
      ws = linked_custom_workspace!()

      codex = spawn_child_env!(ctx, Codex, "codex", ws, api_key: "k")
      assert codex["MY_CUSTOM_CODEX_KEY"] == "custom-codex-secret"
      refute Map.has_key?(codex, "GOOGLE_API_KEY")
      refute Map.has_key?(codex, "CLAUDE_CODE_OAUTH_TOKEN")

      agy = spawn_child_env!(ctx, Gemini, "gemini", ws, api_key: "k")
      assert agy["GOOGLE_API_KEY"] == "custom-agy-secret"
      refute Map.has_key?(agy, "MY_CUSTOM_CODEX_KEY")
      refute Map.has_key?(agy, "CLAUDE_CODE_OAUTH_TOKEN")
    end
  end
end
