defmodule Arbiter.Worker.AwaitingOperatorTest do
  @moduledoc """
  #1299: a run that asked the operator for something (`permission_request`) and
  then exited cleanly without `arb done` is parked on that request, not failed
  as `run_crashed` and not auto-resumed: a resume cannot succeed until the
  environment changes. A clean exit with nothing pending is still the early quit
  it always was.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.{Attention, Issue, Permissions, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{ClaudeSession, StopReason}

  describe "StopReason.awaiting_operator/1" do
    test "names what is pending and is neither a crash nor resumable advice" do
      reason = StopReason.awaiting_operator(["prod_ssh", "network:example.com"])

      assert reason.category == :awaiting_operator
      assert reason.exit_status == 0
      assert reason.summary =~ "prod_ssh"
      assert reason.summary =~ "network:example.com"
      assert reason.remediation =~ "Not a crash"
      assert StopReason.label(reason) =~ "operator"
      assert %{category: :awaiting_operator} = StopReason.to_map(reason)
    end
  end

  describe "Worker: a clean exit with a permission request pending" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "await-op-ws-#{System.unique_integer([:positive])}",
          prefix: "ao",
          config: %{}
        })

      dir = Path.join(System.tmp_dir!(), "await-op-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      stub = Path.join(dir, "claude")
      File.write!(stub, "#!/bin/sh\nexit 0\n")
      File.chmod!(stub, 0o755)

      %{ws: ws, dir: dir, stub: stub}
    end

    defp run_to_exit(ws, dir, stub, pending) do
      {:ok, task} =
        Ash.create(Issue, %{title: "needs hex", workspace_id: ws.id, issue_type: :bug})

      task = put_state!(task, :active)

      if pending,
        do: Permissions.record!([%{permission: "prod_ssh", event: :requested}], task.id, :request)

      {:ok, pid} =
        Worker.start(
          task_id: task.id,
          repo: "unknown",
          workspace_id: ws.id,
          meta: %{issue_type: :bug, review_spawn: false}
        )

      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
      :ok = Worker.advance(pid, :claude)

      {:ok, _port} =
        ClaudeSession.start(
          owner: pid,
          worktree_path: dir,
          provider: "claude",
          command: [stub]
        )

      {task, pid}
    end

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
          Process.sleep(25)
          do_wait(fun, deadline)
      end
    end

    test "is parked as awaiting the operator, with no resume and no run_crashed",
         %{ws: ws, dir: dir, stub: stub} do
      {task, pid} = run_to_exit(ws, dir, stub, true)

      wait_until(fn -> match?(%{state: :finished}, Worker.state(pid)) end)

      snap = Worker.state(pid)
      assert snap.outcome == :failed
      assert snap.meta.stop_reason.category == :awaiting_operator
      assert snap.meta.failure_reason =~ "prod_ssh"
      refute Map.get(snap.meta, :resume_attempts, 0) > 0

      issue = Ash.get!(Issue, task.id)
      assert issue.attention_cause == :permission_requested
      assert %{cause: :permission_requested} = Attention.current(issue)
    end

    test "with nothing pending it is still an ordinary early quit", %{
      ws: ws,
      dir: dir,
      stub: stub
    } do
      {_task, pid} = run_to_exit(ws, dir, stub, false)

      # Resumed (not parked): the early-quit path schedules a resume attempt.
      wait_until(fn ->
        snap = Worker.state(pid)
        match?(%{state: :finished}, snap) or Map.get(snap.meta || %{}, :resume_attempts, 0) > 0
      end)

      refute match?(%{meta: %{stop_reason: %{category: :awaiting_operator}}}, Worker.state(pid))
    end
  end
end
