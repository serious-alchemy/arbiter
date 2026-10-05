defmodule Arbiter.Worker.MemoryCapWorkerTest do
  # bd-6zuoo6: the Worker half of the per-spawn memory cap, against fake
  # `systemd-run` / `systemctl` scripts, so it runs everywhere. What it proves:
  #
  #   * the agent really is launched THROUGH the scope wrapper (the fake logs the
  #     argv it was given, and execs the rest);
  #   * the scope unit lands on the Run row (AC3);
  #   * a scope systemd reports `Result=oom-kill` fails the run with the typed
  #     `memory_cap_exceeded` category and a "memory cap exceeded" reason (AC1),
  #     instead of a bare "killed by signal 9";
  #   * a plain SIGKILL, with no oom-kill result, stays `:killed`.
  #
  # The real-kernel half (a process that truly outgrows MemoryMax is killed
  # alone) is `Arbiter.Integration.WorkerMemoryCapTest`, tagged `:live_systemd`.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.MemoryScope
  alias Arbiter.Workers.Run
  require Ash.Query

  setup do
    dir = Path.join(System.tmp_dir!(), "mcw#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    systemd_run = Path.join(dir, "systemd-run")
    systemctl = Path.join(dir, "systemctl")
    argv_log = Path.join(dir, "argv.log")
    oom_marker = Path.join(dir, "oom")
    reset_marker = Path.join(dir, "reset")
    stop_log = Path.join(dir, "stop.log")

    # Mirrors the real argv shape: `--user --scope … -p K=V … <env> -u VAR <cmd…>`.
    File.write!(systemd_run, """
    #!/bin/sh
    case "$*" in *memory.max*) echo 1073741824; exit 0 ;; esac
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) shift 2 ;;
        --*) shift ;;
        *) break ;;
      esac
    done
    case "$*" in *printf*) ;; *) echo "$@" >> '#{argv_log}' ;; esac
    exec "$@"
    """)

    File.write!(systemctl, """
    #!/bin/sh
    case "$2" in
      show)
        if [ -f '#{oom_marker}' ]; then
          printf 'Result=oom-kill\\nMemoryPeak=2147483648\\n'
        else
          printf 'Result=success\\nMemoryPeak=1048576\\n'
        fi ;;
      reset-failed) touch '#{reset_marker}' ;;
      stop) echo "$3" >> '#{stop_log}' ;;
    esac
    """)

    File.chmod!(systemd_run, 0o755)
    File.chmod!(systemctl, 0o755)

    saved = %{
      xdg: System.get_env("XDG_RUNTIME_DIR"),
      max: System.get_env("ARBITER_WORKER_MEMORY_MAX"),
      app_max: Application.get_env(:arbiter, :worker_memory_max)
    }

    System.put_env("XDG_RUNTIME_DIR", dir)
    System.delete_env("ARBITER_WORKER_MEMORY_MAX")
    Application.put_env(:arbiter, :worker_memory_max, "1G")
    Application.put_env(:arbiter, :systemd_run, systemd_run)
    Application.put_env(:arbiter, :systemctl, systemctl)
    MemoryScope.reset_probe()

    on_exit(fn ->
      restore_env("XDG_RUNTIME_DIR", saved.xdg)
      restore_env("ARBITER_WORKER_MEMORY_MAX", saved.max)

      if saved.app_max,
        do: Application.put_env(:arbiter, :worker_memory_max, saved.app_max),
        else: Application.delete_env(:arbiter, :worker_memory_max)

      Application.delete_env(:arbiter, :systemd_run)
      Application.delete_env(:arbiter, :systemctl)
      MemoryScope.reset_probe()
      File.rm_rf(dir)
    end)

    {:ok,
     dir: dir,
     stop_log: stop_log,
     argv_log: argv_log,
     oom_marker: oom_marker,
     reset_marker: reset_marker}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp run_agent(command) do
    task_id = "bd-memcap-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :claude)

    {:ok, _port} =
      ClaudeSession.start(owner: pid, worktree_path: System.tmp_dir!(), command: command)

    deadline = System.monotonic_time(:millisecond) + 5_000
    state = wait_finished(pid, deadline)

    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    {state, run, task_id}
  end

  defp wait_finished(pid, deadline) do
    case Worker.state(pid) do
      %{state: :finished} = s ->
        s

      _ ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("worker never finished")
        Process.sleep(20)
        wait_finished(pid, deadline)
    end
  end

  test "the agent runs through the scope wrapper and the scope is recorded on the run",
       %{argv_log: argv_log} do
    {_state, run, task_id} = run_agent(["sh", "-c", "echo hi $5; exit 3"])

    assert [scope] = run.cgroup_scopes
    assert scope =~ ~r/\Aarb-run-#{task_id}-[0-9a-f]{8}\.scope\z/

    # What the fake `systemd-run` was left to exec: XDG_RUNTIME_DIR stripped
    # again for the agent, then the agent's own argv, untouched.
    assert File.read!(argv_log) =~
             ~r{/env -u XDG_RUNTIME_DIR \S*/sh -c echo hi \$5; exit 3}
  end

  # bd-6zm33r AC1 (wiring half; the real-process half is the :live_systemd test).
  test "the run's scope is stopped once the agent exits, on any outcome",
       %{stop_log: stop_log} do
    {_state, run, _task_id} = run_agent(["sh", "-c", "exit 0"])
    assert [scope] = run.cgroup_scopes
    assert File.read!(stop_log) |> String.split("\n", trim: true) == [scope]

    {_state, run, _task_id} = run_agent(["sh", "-c", "exit 3"])
    assert [scope2] = run.cgroup_scopes
    assert File.read!(stop_log) |> String.split("\n", trim: true) == [scope, scope2]
  end

  # bd-6zm33r AC1, teardown path: the worker is stopped while the agent still runs,
  # so no :exit_status ever arrives; `terminate/2` must stop the scope itself.
  test "the run's scope is stopped when the worker is torn down with the agent still running",
       %{stop_log: stop_log} do
    task_id = "bd-memcap-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    :ok = Worker.advance(pid, :claude)

    {:ok, _port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: ["sh", "-c", "sleep 30"]
      )

    _ = :sys.get_state(pid)
    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    assert [scope] = run.cgroup_scopes
    refute File.exists?(stop_log)

    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert File.read!(stop_log) |> String.split("\n", trim: true) == [scope]
  end

  test "a scope systemd OOM-killed fails the run as memory_cap_exceeded",
       %{oom_marker: oom_marker, reset_marker: reset_marker} do
    File.write!(oom_marker, "")

    {state, run, _task_id} = run_agent(["sh", "-c", "echo growing; kill -9 $$"])

    assert state.outcome == :failed
    assert state.meta.stop_reason.category == :memory_cap_exceeded

    assert run.outcome == :failed
    assert run.stop_category == "memory_cap_exceeded"
    assert run.failure_reason =~ "memory cap exceeded"
    assert run.failure_reason =~ "MemoryMax=1G"
    assert run.exit_code == 137
    assert File.exists?(reset_marker), "the failed scope must be reset-failed"
  end

  test "a plain SIGKILL with no oom-kill result is still just :killed" do
    {state, run, _task_id} = run_agent(["sh", "-c", "kill -9 $$"])

    assert state.meta.stop_reason.category == :killed
    assert run.stop_category == "killed"
  end

  test "with the cap disabled the agent is spawned bare and no scope is recorded" do
    Application.put_env(:arbiter, :worker_memory_max, "off")

    {_state, run, _task_id} = run_agent(["sh", "-c", "exit 2"])

    assert run.cgroup_scopes in [nil, []]
  end
end
