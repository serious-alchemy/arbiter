defmodule Arbiter.Worker.DispatchInspectPlacementTest do
  @moduledoc """
  bd-6ypj2y: a `task` / `research` ticket on podman Claude runs in a **read-only
  clone of the target branch tip** (the inspect checkout), which is what makes it a
  node candidate: the node is seeded from it, nothing is collected back, and any
  commit the agent makes there dies with the clone.

  Drives the real `Dispatch.dispatch/2` to the `podman run` argv (the `podman`
  binary and egress run are stand-ins). The node is a pool row with no session, so
  the placement is tried (`ensure_node_capacity/2` picked it) and refused, and the
  run falls back to the primary in the very same checkout.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Worktree

  @repo ResumeSlotFixture.repo()

  setup do
    sandbox = ResumeSlotFixture.setup_repo!()
    Application.put_env(:arbiter, :conductor_system_max_concurrent, 10)

    for {key, value} <- [
          worker_container_available: true,
          worker_container_network_available: true,
          worker_deps_cache: false
        ] do
      previous = Application.fetch_env(:arbiter, key)
      Application.put_env(:arbiter, key, value)

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, key, v)
          :error -> Application.delete_env(:arbiter, key)
        end
      end)
    end

    dir = Path.join(sandbox.worktree_root, "inspect-stand-in")
    File.mkdir_p!(dir)
    proxy = Path.join(dir, "proxy.sock")
    bridge = Path.join(dir, "arb.sock")
    File.write!(proxy, "")
    File.write!(bridge, "")

    log = Path.join(dir, "podman.log")
    podman = Path.join(dir, "podman")

    File.write!(podman, """
    #!/bin/sh
    { printf 'CALL\\0'; for a in "$@"; do printf '%s\\0' "$a"; done; printf 'END\\0'; } >> #{log}
    exit 0
    """)

    File.chmod!(podman, 0o755)
    ports = [free_port(), free_port()]

    egress = fn _opts ->
      {:ok, [proxy_socket: proxy, proxy_port: hd(ports), bridges: [{List.last(ports), bridge}]],
       "rtest"}
    end

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "inspect-#{System.unique_integer([:positive])}",
        prefix: "in#{System.unique_integer([:positive])}",
        config: %{"worker" => %{"placement" => "prefer_remote"}}
      })

    opts = [
      repo: @repo,
      start_driver: false,
      preflight: false,
      start_claude: true,
      force: true,
      security: %{"sandbox" => %{"backend" => "podman"}},
      image: "localhost/arb-test/claude:1",
      podman: podman,
      egress: egress,
      nodes: [ghost_node()]
    ]

    %{ws: ws, opts: opts, log: log, repo_path: sandbox.repo}
  end

  defp ghost_node do
    %{
      id: "n-ghost",
      name: "ghost-node",
      state: :online,
      health: :ready,
      max: 2,
      live: 0,
      workspace_ids: [],
      labels: [],
      caps: %{}
    }
  end

  defp free_port do
    {:ok, sock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(sock)
    :gen_tcp.close(sock)
    port
  end

  defp await_agent_exit(port) do
    ref = Port.monitor(port)
    assert_receive {:DOWN, ^ref, :port, ^port, _}, 5_000
  end

  defp stop_worker(task_id) do
    case Worker.whereis(task_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Worker.stop(pid, :normal)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    end
  end

  defp ticket!(ws, type, title) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: title,
        workspace_id: ws.id,
        issue_type: type,
        acceptance: "- findings in notes"
      })

    task
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    String.trim(out)
  end

  defp run_calls(log) do
    case File.read(log) do
      {:ok, raw} -> raw |> String.split(<<0>>) |> Enum.count(&(&1 == "run"))
      {:error, _} -> 0
    end
  end

  for type <- [:research, :task] do
    test "a #{type} ticket is placed (tried on the node) and gets a read-only clone of the target tip",
         %{ws: ws, opts: opts, log: log, repo_path: repo_path} do
      task = ticket!(ws, unquote(type), "inspect #{unquote(type)}")
      tip = git!(repo_path, ["rev-parse", "main"])

      output =
        capture_log(fn ->
          assert {:ok, %{claude_port: port}} = Dispatch.dispatch(task.id, opts)
          await_agent_exit(port)
          assert run_calls(log) > 0
          stop_worker(task.id)
        end)

      # A node was picked and refused it: that is a placement, not a local-only run.
      assert output =~ "falling back to the primary"

      path = task |> BranchNamer.derive() |> Worktree.inspect_path()
      assert PrivateClone.clone?(path)
      assert PrivateClone.read_only?(path)
      assert git!(path, ["rev-parse", "HEAD"]) == tip
      # No task branch was cut for a ticket that delivers nothing.
      assert git!(repo_path, ["branch", "--list", BranchNamer.derive(task)]) == ""
    end
  end

  test "a commit the agent makes in the clone is discarded and can never be pushed",
       %{ws: ws, opts: opts, repo_path: repo_path} do
    task = ticket!(ws, :research, "agent commits")
    tip = git!(repo_path, ["rev-parse", "main"])

    refs_before =
      git!(repo_path, [
        "for-each-ref",
        "--format=%(refname) %(objectname)",
        "refs/heads",
        "refs/remotes"
      ])

    capture_log(fn ->
      assert {:ok, %{claude_port: port}} = Dispatch.dispatch(task.id, opts)
      await_agent_exit(port)
      stop_worker(task.id)
    end)

    path = task |> BranchNamer.derive() |> Worktree.inspect_path()
    File.write!(Path.join(path, "agent.txt"), "the agent was here\n")
    git!(path, ["add", "agent.txt"])

    git!(path, [
      "-c",
      "user.name=agent",
      "-c",
      "user.email=agent@example.com",
      "commit",
      "-q",
      "-m",
      "agent edit"
    ])

    refute git!(path, ["rev-parse", "HEAD"]) == tip

    # Neither a sync back to the main repo nor a push has anywhere to go.
    assert {:error, :read_only_clone} = PrivateClone.sync_back(path)

    assert {_out, code} =
             System.cmd("git", ["push", "origin", "HEAD:refs/heads/stolen"],
               cd: path,
               stderr_to_stdout: true
             )

    assert code != 0

    assert git!(repo_path, [
             "for-each-ref",
             "--format=%(refname) %(objectname)",
             "refs/heads",
             "refs/remotes"
           ]) == refs_before

    # The clone is dropped with its commit; the main repo never saw it.
    assert :ok = Worktree.cleanup(path)
    refute File.exists?(path)

    assert git!(repo_path, [
             "for-each-ref",
             "--format=%(refname) %(objectname)",
             "refs/heads",
             "refs/remotes"
           ]) == refs_before

    assert git!(repo_path, ["rev-parse", "main"]) == tip
  end

  test "a re-dispatch replaces the previous clone with a fresh one at the current tip",
       %{ws: ws, opts: opts, repo_path: repo_path} do
    task = ticket!(ws, :research, "twice")

    capture_log(fn ->
      assert {:ok, %{claude_port: port}} = Dispatch.dispatch(task.id, opts)
      await_agent_exit(port)
      stop_worker(task.id)
    end)

    path = task |> BranchNamer.derive() |> Worktree.inspect_path()
    File.write!(Path.join(path, "stale.txt"), "left by the first run\n")

    capture_log(fn ->
      assert {:ok, %{claude_port: port}} = Dispatch.dispatch(task.id, opts)
      await_agent_exit(port)
      stop_worker(task.id)
    end)

    assert PrivateClone.read_only?(path)
    refute File.exists?(Path.join(path, "stale.txt"))
    assert git!(path, ["rev-parse", "HEAD"]) == git!(repo_path, ["rev-parse", "main"])
  end
end
