defmodule Arbiter.Worker.TestRunnerTest do
  @moduledoc """
  bd-57nhsi: `Worker.test_runner/1` hands the `run_tests` MCP tool the same place
  to run a command that the pre-push check uses for the run: its sandbox, its
  node, or the host worktree.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  setup do
    dir = Path.join(System.tmp_dir!(), "test-runner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "tr-#{System.unique_integer([:positive])}", prefix: "tr"})

    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: :feature})
    %{dir: dir, task: put_state!(task, :active), ws: ws}
  end

  defp start_worker(ctx, meta) do
    {:ok, pid} =
      Worker.start(
        task_id: ctx.task.id,
        repo: "tr/repo",
        workspace_id: ctx.task.workspace_id,
        meta: Map.merge(%{target_branch: "main", review_spawn: false}, meta)
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  test "an unknown task has no runner" do
    assert Worker.test_runner("bd-nonesuch") == {:error, :no_worker}
  end

  test "a run without a worktree has no runner", ctx do
    start_worker(ctx, %{})

    assert Worker.test_runner(ctx.task.id) == {:error, :no_worktree}
  end

  test "an unsandboxed run executes in its worktree on the host", ctx do
    start_worker(ctx, %{worktree_path: ctx.dir})

    assert {:ok, %{exec: exec, worktree: worktree, target: "main"}} =
             Worker.test_runner(ctx.task.id)

    assert worktree == ctx.dir
    assert {out, 0} = exec.("pwd", 10)
    assert String.trim(out) == Path.expand(ctx.dir) or String.trim(out) =~ Path.basename(ctx.dir)
  end

  test "the host runner hands the command the run's TMPDIR", ctx do
    tmp = Path.join(ctx.dir, "run-tmp")
    File.mkdir_p!(tmp)

    start_worker(ctx, %{
      worktree_path: ctx.dir,
      claude_spawn: %{cd: ctx.dir, env: [{"TMPDIR", tmp}]}
    })

    {:ok, %{exec: exec}} = Worker.test_runner(ctx.task.id)

    assert {out, 0} = exec.("echo $TMPDIR", 10)
    assert String.trim(out) == tmp
  end

  test "a run with an exec seam uses it (sandbox or node)", ctx do
    test_pid = self()

    exec = fn command, seconds ->
      send(test_pid, {:exec, command, seconds})
      {"ok", 0}
    end

    start_worker(ctx, %{worktree_path: ctx.dir, prepush_exec: exec})

    assert {:ok, %{exec: runner_exec}} = Worker.test_runner(ctx.task.id)
    assert {"ok", 0} = runner_exec.("mix test", 30)
    assert_received {:exec, "mix test", 30}
  end

  test "a remote run with no node is an error from the exec, never a host run", ctx do
    start_worker(ctx, %{worktree_path: ctx.dir, claude_spawn: %{remote: %{node: nil}}})

    {:ok, %{exec: exec}} = Worker.test_runner(ctx.task.id)
    assert {:error, :remote_run_unknown} = exec.("mix test", 30)
  end
end
