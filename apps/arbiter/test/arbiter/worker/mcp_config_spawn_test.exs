defmodule Arbiter.Worker.MCPConfigSpawnTest do
  @moduledoc """
  bd-7e8ezw / #2045: every Claude spawn path that gets an isolated worktree
  must hand the agent a working Arbiter MCP config — a `.mcp.json` carrying a
  freshly minted worker token, passed **explicitly** via `--mcp-config`.

  Two separate failures made fix-pass workers report the `arbiter` server as
  not connected:

    * `FixPassDispatcher` never minted a token or wrote `.mcp.json` at all, so
      a fix pass ran with no config, or with the original run's stale file
      (its 4h worker lease long expired).
    * Claude Code applies the *main checkout's* `.claude/settings.local.json`
      to every git worktree of the repo. A `disabledMcpjsonServers:
      ["arbiter"]` there drops the worktree's auto-loaded `.mcp.json` without
      a word, which hit every worker in that workspace. Servers passed with
      `--mcp-config` are not subject to that list.

  Both paths run against `Arbiter.TestSandbox`'s stubbed agent binaries, which
  log their argv, so no real CLI is ever spawned.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Agents
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.MergeQueue.ConflictResolver
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  setup do
    # bd-80ecol: the stub `claude` runs the real-agent path, whose dispatch
    # guard refuses a spawn with no credential of its own.
    claude_credential_env!()

    # The claude stub also records the ARB_TOKEN it was spawned with
    # (bd-asawcq), before its argv line so a test that waits for the argv
    # line can read both.
    sandbox =
      TestSandbox.provision!("mcp-config-spawn",
        stub: %{
          "claude" => """
          echo "claude-env ARB_TOKEN=${ARB_TOKEN}" >> "$(dirname "$0")/../cli-calls.log"
          echo "claude $@" >> "$(dirname "$0")/../cli-calls.log"
          echo "arb done"
          exit 0
          """
        }
      )

    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{"test/repo" => sandbox.repo})

    # config/test.exs turns per-spawn `.mcp.json` injection off.
    prior = Application.get_env(:arbiter, Arbiter.MCP)
    Application.put_env(:arbiter, Arbiter.MCP, Keyword.put(prior || [], :inject_config, true))

    CredentialWatchdog.mark_recovered(Agents.Claude)
    _ = :sys.get_state(CredentialWatchdog)

    # Registered after `provision!/1`, so it runs first (on_exit is LIFO):
    # adopt and stop every worker before the sandbox is deleted.
    on_exit(fn ->
      Application.put_env(:arbiter, Arbiter.MCP, prior)
      TestSandbox.own_live_workers!(sandbox)
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "ws-mcp-spawn-#{System.unique_integer([:positive])}",
        prefix: "mcs",
        config: %{
          "agent" => %{"type" => "claude"},
          "repo_paths" => %{"test/repo" => sandbox.repo}
        }
      })

    %{sandbox: sandbox, ws: ws}
  end

  # The prompt only offers the `arb` CLI fallback to a session that positively
  # has no Arbiter MCP tools, so a failed config write must say so.
  test "inject_config flags a failed write with mcp_tools?: false, a good write does not",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "no mcp", workspace_id: ws.id})
    opts = [repo: "test/repo", agent_type: :claude]

    missing = Path.join(sandbox.worktree_root, "does-not-exist-#{task.id}")
    failed = Dispatch.inject_mcp_config(task, missing, opts)
    assert failed[:mcp_tools?] == false
    refute Keyword.has_key?(failed, :mcp_config)

    good = Dispatch.inject_mcp_config(task, sandbox.repo, opts)
    assert Keyword.has_key?(good, :mcp_config)
    refute Keyword.has_key?(good, :mcp_tools?)

    # No worktree → skipped, not flagged.
    skipped = Dispatch.inject_mcp_config(task, nil, opts)
    refute Keyword.has_key?(skipped, :mcp_config)
    refute Keyword.has_key?(skipped, :mcp_tools?)
  end

  # bd-asawcq: `/api` needs a bearer token, so the worker's own `arb` gets
  # its worker token as ARB_TOKEN — the same one its MCP config carries —
  # whether or not an MCP config could be written (agy with no isolated
  # `$HOME`, a review with no worktree).
  test "inject_config hands back the worker token for ARB_TOKEN, written or not",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "arb token", workspace_id: ws.id})
    opts = [repo: "test/repo", agent_type: :claude]
    task_id = task.id

    good = Dispatch.inject_mcp_config(task, sandbox.repo, opts)
    assert {:ok, %Scope{tier: :worker, task_id: ^task_id}} = Scope.from_token(good[:arb_token])
    assert_mcp_token!(good[:mcp_config], good[:arb_token])

    missing = Path.join(sandbox.worktree_root, "does-not-exist-#{task.id}")

    for wt <- [missing, nil] do
      out = Dispatch.inject_mcp_config(task, wt, opts)
      assert {:ok, %Scope{tier: :worker, task_id: ^task_id}} = Scope.from_token(out[:arb_token])
    end
  end

  test "a CI fix pass writes a fresh worker token and passes it via --mcp-config",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "fix ci", workspace_id: ws.id})
    branch = "task-#{task.id}"
    :ok = TestSandbox.seed_branch!(sandbox, branch)

    {:ok, %{worker_pid: pid, worktree_path: wt}} =
      FixPassDispatcher.dispatch(%{
        task: task,
        repo: "test/repo",
        repo_path: sandbox.repo,
        branch: branch,
        target_branch: "main",
        workspace: ws
      })

    TestSandbox.own!(sandbox, pid)

    config_path = Path.join(wt, ".mcp.json")
    wait_until(fn -> claude_logged?(sandbox, "--mcp-config #{config_path}") end)

    assert File.read!(sandbox.log) =~ "--mcp-config #{config_path}"
    assert_valid_worker_token!(config_path, task.id)
    assert_spawned_with_arb_token!(sandbox, config_path)
  end

  test "a merge-conflict resolver writes a fresh worker token and passes it via --mcp-config",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "resolve conflict", workspace_id: ws.id})
    branch = "task-#{task.id}"
    :ok = TestSandbox.seed_branch!(sandbox, branch)

    # Move main past the branch, or the resolver has nothing to do (:no_op).
    File.write!(Path.join(sandbox.repo, "other.txt"), "other\n")

    for args <- [
          ["add", "other.txt"],
          ["commit", "-q", "-m", "other"],
          ["push", "-q", "origin", "main"]
        ] do
      {_, 0} = System.cmd("git", ["-C", sandbox.repo | args], stderr_to_stdout: true)
    end

    {:ok, %{worker_pid: pid, worktree_path: wt}} =
      ConflictResolver.dispatch(%{
        task: task,
        repo: "test/repo",
        repo_path: sandbox.repo,
        branch: branch,
        target_branch: "main",
        workspace: ws
      })

    TestSandbox.own!(sandbox, pid)

    config_path = Path.join(wt, ".mcp.json")
    wait_until(fn -> claude_logged?(sandbox, "--mcp-config #{config_path}") end)

    assert File.read!(sandbox.log) =~ "--mcp-config #{config_path}"
    assert_valid_worker_token!(config_path, task.id)
    assert_spawned_with_arb_token!(sandbox, config_path)
  end

  test "a fresh work dispatch passes its injected config via --mcp-config",
       %{sandbox: sandbox, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "do work", workspace_id: ws.id})

    {:ok, result} =
      Dispatch.dispatch(task.id,
        force: true,
        repo: "test/repo",
        start_driver: false,
        start_claude: true
      )

    TestSandbox.own!(sandbox, result.worker_pid)

    config_path = Path.join(result.worktree_path, ".mcp.json")
    wait_until(fn -> claude_logged?(sandbox, "--mcp-config #{config_path}") end)

    assert File.read!(sandbox.log) =~ "--mcp-config #{config_path}"
    assert_valid_worker_token!(config_path, task.id)
    assert_spawned_with_arb_token!(sandbox, config_path)
  end

  defp assert_valid_worker_token!(config_path, task_id) do
    %{"mcpServers" => %{"arbiter" => %{"headers" => %{"Authorization" => "Bearer " <> token}}}} =
      config_path |> File.read!() |> Jason.decode!()

    assert {:ok, %Scope{tier: :worker, task_id: ^task_id}} = Scope.from_token(token)
  end

  defp assert_mcp_token!(config_path, token) do
    %{"mcpServers" => %{"arbiter" => %{"headers" => %{"Authorization" => "Bearer " <> written}}}} =
      config_path |> File.read!() |> Jason.decode!()

    assert written == token
  end

  defp assert_spawned_with_arb_token!(sandbox, config_path) do
    # A dispatch may spawn the agent more than once (a follow-up turn after
    # the first exits); every spawn carries the worker token.
    tokens = for "claude-env ARB_TOKEN=" <> token <- TestSandbox.calls(sandbox), do: token
    assert tokens != []
    Enum.each(tokens, &assert_mcp_token!(config_path, &1))
  end

  # Waits for the text the test goes on to assert, not merely for a spawn: the
  # argv is multi-line and under full-suite load the assertion once read the
  # log before the `--mcp-config` flag was in it (seen once in `mix precommit`).
  defp claude_logged?(sandbox, text),
    do: File.exists?(sandbox.log) and File.read!(sandbox.log) =~ text

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end
end
