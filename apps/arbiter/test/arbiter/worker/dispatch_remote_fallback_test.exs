defmodule Arbiter.Worker.DispatchRemoteFallbackTest do
  @moduledoc """
  bd-373tce: under `worker.placement: prefer_remote`, a dispatch that has an existing
  local checkout must neither lose its work nor crash the run.

    * a checkout holding uncommitted work stays on the primary (the seed carries
      commits, not the work tree);
    * a run a node cannot take (refused as `unschedulable`, or unreachable) falls
      back to the primary instead of failing the worker as `spawn_failed`.

  Drives the real `Dispatch.dispatch/2` to the `podman run` argv; the `podman`
  binary and egress run are stand-ins (`:podman` / `:egress` spawn options), and
  the node is a pool row with no session behind it, so any attempt to place on it
  is refused.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Dispatch
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

    dir = Path.join(sandbox.worktree_root, "fallback-stand-in")
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
        name: "fallback-#{System.unique_integer([:positive])}",
        prefix: "fb#{System.unique_integer([:positive])}",
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

  # A node the pool offers but that has no session: placing a run on it is refused.
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

  defp run_calls(log) do
    case File.read(log) do
      {:ok, raw} -> raw |> String.split(<<0>>) |> Enum.count(&(&1 == "run"))
      {:error, _} -> 0
    end
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met within timeout")
      true -> Process.sleep(20) && wait_until(fun, tries - 1)
    end
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

  defp ticket!(ws, title) do
    {:ok, task} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- fallback fixture"})

    task
  end

  # What an earlier local run leaves: the ticket's private clone, with an uncommitted edit.
  defp dirty_checkout!(task, repo_path) do
    branch = BranchNamer.derive(task)
    {:ok, path} = Worktree.create(repo_path, branch, "main", layout: :private_clone)
    File.write!(Path.join(path, "uncommitted.txt"), "work in progress\n")
    path
  end

  test "a ticket whose local checkout holds uncommitted work stays on the primary",
       %{ws: ws, opts: opts, log: log, repo_path: repo_path} do
    task = ticket!(ws, "dirty checkout")
    path = dirty_checkout!(task, repo_path)

    output =
      capture_log(fn ->
        assert {:ok, %{worker_pid: pid, worktree_path: ^path}} =
                 Dispatch.dispatch(task.id, opts)

        assert is_pid(pid)
        wait_until(fn -> run_calls(log) > 0 end)
        stop_worker(task.id)
      end)

    # Kept local up front: placement never tried the node, so nothing fell back.
    refute output =~ "falling back to the primary"
    assert File.read!(Path.join(path, "uncommitted.txt")) == "work in progress\n"
  end

  test "a node that refuses the run falls back to the primary instead of crashing it",
       %{ws: ws, opts: opts, log: log} do
    task = ticket!(ws, "node refuses")

    output =
      capture_log(fn ->
        assert {:ok, %{worker_pid: pid, worktree_path: path}} = Dispatch.dispatch(task.id, opts)
        assert is_pid(pid)

        # The agent really started, on the primary.
        wait_until(fn -> run_calls(log) > 0 end)
        assert File.dir?(path)
        assert Ash.get!(Issue, task.id).state == :active
        assert Process.alive?(pid)
        stop_worker(task.id)
      end)

    assert output =~ "falling back to the primary"
  end

  test "under remote_only a node refusal is not run on the primary", %{opts: opts, log: log} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "fallback-ro-#{System.unique_integer([:positive])}",
        prefix: "fr#{System.unique_integer([:positive])}",
        config: %{"worker" => %{"placement" => "remote_only"}}
      })

    task = ticket!(ws, "remote only refused")

    capture_log(fn ->
      assert {:error, {:claude_start_failed, _}} = Dispatch.dispatch(task.id, opts)
    end)

    assert run_calls(log) == 0
  end
end
