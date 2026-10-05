defmodule Arbiter.Integration.WorkerMemoryCapTest do
  @moduledoc """
  Live-systemd proof of the per-worker memory cap (bd-6zuoo6, acceptance 1).

  The fake-binary test (`Arbiter.Worker.MemoryCapWorkerTest`) proves the wiring;
  this proves the thing it rests on — that a worker whose process tree outgrows
  `MemoryMax` is killed by the kernel **alone**: a second worker running beside
  it survives, and the run is recorded failed with the memory-cap reason.

  Tagged `:live_systemd` and excluded in `test/test_helper.exs` (it spawns real
  scopes and deliberately drives one into the OOM-killer). Run it deliberately:

      XDG_RUNTIME_DIR=/run/user/$(id -u) \\
        mix test --include live_systemd test/integration/worker_memory_cap_test.exs

  It needs a systemd user manager with the memory controller delegated; the
  `MemoryScope` probe is the precondition, and the test fails loudly (rather
  than passing vacuously) when it does not hold.

  ## Teardown discipline

  Every process is addressed by the exact port / worker pid this test created;
  nothing here matches processes by name.
  """
  use Arbiter.DataCase, async: false

  @moduletag :live_systemd
  @moduletag timeout: 120_000

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.MemoryScope
  alias Arbiter.Workers.Run
  require Ash.Query

  @cap "64M"

  setup do
    saved_max = Application.get_env(:arbiter, :worker_memory_max)
    saved_xdg = System.get_env("XDG_RUNTIME_DIR")

    if is_nil(saved_xdg) do
      dir = MemoryScope.runtime_dir()
      if dir, do: System.put_env("XDG_RUNTIME_DIR", dir)
    end

    Application.put_env(:arbiter, :worker_memory_max, @cap)
    MemoryScope.reset_probe()

    on_exit(fn ->
      if saved_max,
        do: Application.put_env(:arbiter, :worker_memory_max, saved_max),
        else: Application.delete_env(:arbiter, :worker_memory_max)

      if saved_xdg,
        do: System.put_env("XDG_RUNTIME_DIR", saved_xdg),
        else: System.delete_env("XDG_RUNTIME_DIR")

      MemoryScope.reset_probe()
    end)

    case MemoryScope.probe(@cap) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        raise ExUnit.AssertionError,
          message: "this host cannot run a capped scope, so this test proves nothing: #{reason}"
    end
  end

  defp start_agent(command) do
    task_id = "bd-livecap-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    {:ok, port} =
      ClaudeSession.start(owner: pid, worktree_path: System.tmp_dir!(), command: command)

    {pid, task_id, port}
  end

  defp wait(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      fun.() || (Process.sleep(50) && nil)
    end)
    |> Enum.find(fn v -> v || System.monotonic_time(:millisecond) > deadline end)
  end

  test "a worker that outgrows MemoryMax is OOM-killed alone and its run records why" do
    # A bystander in its own scope, alive for the whole test.
    {bystander, _bid, bport} = start_agent(["sh", "-c", "echo alive; sleep 60"])
    {:os_pid, bystander_pid} = Port.info(bport, :os_pid)

    # `tail /dev/zero` never sees a newline, so it buffers without bound.
    {hog, hog_task, _hport} = start_agent(["sh", "-c", "echo growing; tail /dev/zero"])

    assert wait(fn -> match?(%{state: :finished}, Worker.state(hog)) end, 60_000),
           "the runaway worker was never stopped"

    state = Worker.state(hog)
    assert state.outcome == :failed
    assert state.meta.stop_reason.category == :memory_cap_exceeded

    [run] = Run |> Ash.Query.filter(task_id == ^hog_task) |> Ash.read!()
    assert run.outcome == :failed
    assert run.stop_category == "memory_cap_exceeded"
    assert run.failure_reason =~ "memory cap exceeded"
    assert [scope] = run.cgroup_scopes
    assert scope =~ ~r/\Aarb-run-#{hog_task}-[0-9a-f]{8}\.scope\z/

    # Killed alone: the neighbour is untouched, and so is this very VM.
    assert {_, 0} = System.cmd("kill", ["-0", Integer.to_string(bystander_pid)])
    refute match?(%{state: :finished}, Worker.state(bystander))

    # And the failed scope was cleared, not left to accumulate.
    {out, _} =
      System.cmd("systemctl", ["--user", "show", scope, "-p", "LoadState"],
        env: [{"XDG_RUNTIME_DIR", System.get_env("XDG_RUNTIME_DIR")}]
      )

    assert out =~ "LoadState=not-found"
  end

  # bd-6zm33r: the agent exits, but a process it backgrounded stays in the scope
  # (and used to outlive the run). Ending the run stops the scope.
  test "a background process left by the agent dies with the run's scope" do
    pidfile = Path.join(System.tmp_dir!(), "bg#{System.unique_integer([:positive])}.pid")
    on_exit(fn -> File.rm(pidfile) end)

    {pid, task_id, _port} =
      start_agent([
        "sh",
        "-c",
        "sleep 300 </dev/null >/dev/null 2>&1 & echo $! > #{pidfile}; exit 0"
      ])

    assert wait(fn -> match?(%{state: :finished}, Worker.state(pid)) end, 30_000)

    {bg_pid, _} = pidfile |> File.read!() |> String.trim() |> Integer.parse()
    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    assert [scope] = run.cgroup_scopes

    assert wait(fn -> not File.exists?("/proc/#{bg_pid}") end, 10_000),
           "background process #{bg_pid} survived the run"

    {out, _} =
      System.cmd("systemctl", ["--user", "show", scope, "-p", "LoadState"],
        env: [{"XDG_RUNTIME_DIR", System.get_env("XDG_RUNTIME_DIR")}]
      )

    assert out =~ "LoadState=not-found"
  end
end
