defmodule Arbiter.Worker.ReviewGateArbTokenTest do
  @moduledoc """
  bd-asawcq: `/api` needs a bearer token, so a ReviewGate revise-round
  implementer — which works the task exactly like its first-round worker and
  may run `arb ticket update` / `arb message` — gets that task's own
  worker-tier token as `ARB_TOKEN`, never a coordinator one. The reviewer gets
  none: it only reads the diff and prints a verdict.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  @reviewer Path.expand("../../fixtures/review_record_arb_token.sh", __DIR__)
  @implementer Path.expand("../../fixtures/revise_record_arb_token.sh", __DIR__)

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg_arb_token-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)

    on_exit(fn ->
      # Allow any child processes spawned by the worker to finish writing to tmp.
      # The worker's on_exit above waits for the worker to terminate, but
      # child processes may still be cleaning up or writing files.
      # Retry with backoff to handle races with async writes.
      retry_rm_rf(tmp)
    end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, Path.join(tmp, "origin.git")])
    {_, 0} = git(["remote", "add", "origin", Path.join(tmp, "origin.git")], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)

    {_, 0} = git(["checkout", "-q", "-b", "feature/rev"], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-arb-token-#{System.unique_integer([:positive])}",
        prefix: "rt",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "arb token", workspace_id: ws.id, issue_type: :feature})

    %{repo: repo, ws: ws, task: put_state!(task, :active)}
  end

  test "the implementer pass gets its task's worker token; the reviewer gets none",
       %{repo: repo, ws: ws, task: task} do
    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: "feature/rev",
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_rounds: 2,
          worktree_path: repo,
          review_command: [@reviewer],
          revise_command: [@implementer],
          review_timeout_ms: 10_000
        }
      )

    on_exit(fn ->
      # Collect all process monitors before stopping.
      # We must wait for the ReviewGate and any spawned reviewer/implementer
      # workers to terminate before removing tmp, so they don't race with rm_rf.
      refs = collect_and_stop_processes(pid)
      wait_for_processes(refs)
    end)

    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})

    implementer_file = Path.join([repo, ".git", "implementer_arb_token"])
    reviewer_file = Path.join([repo, ".git", "reviewer_arb_token"])
    wait_until(fn -> File.exists?(implementer_file) end, 10_000)

    assert File.read!(reviewer_file) == "<unset>"

    assert {:ok,
            %Scope{tier: :worker, task_id: task_id, workspace_id: ws_id, can_dispatch: false}} =
             Scope.from_token(File.read!(implementer_file))

    assert task_id == task.id
    assert ws_id == ws.id
  end

  defp wait_until(fun, timeout) do
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

  defp collect_and_stop_processes(worker_pid) do
    # Collect monitors for all processes that need to stop.
    refs = []

    # Try to get the ReviewGate pid from the worker's state before it dies.
    # The worker spawns a ReviewGate when review is required.
    review_gate_pid =
      if Process.alive?(worker_pid) do
        try do
          case Worker.state(worker_pid) do
            %{meta: %{review_gate_pid: pid}} when is_pid(pid) -> pid
            _ -> nil
          end
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end
      else
        nil
      end

    # Monitor and stop the ReviewGate first if it exists.
    # We must stop it before the worker so its child processes (reviewer/implementer)
    # receive the stop signal and can clean up.
    refs =
      if review_gate_pid && Process.alive?(review_gate_pid) do
        ref = Process.monitor(review_gate_pid)
        GenServer.stop(review_gate_pid, :normal)
        [ref | refs]
      else
        refs
      end

    # Stop the main worker if it's still alive
    refs =
      if Process.alive?(worker_pid) do
        ref = Process.monitor(worker_pid)
        GenServer.stop(worker_pid, :normal)
        [ref | refs]
      else
        refs
      end

    refs
  end

  defp wait_for_processes(refs, timeout_ms \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_processes_loop(refs, deadline)
  end

  defp wait_for_processes_loop([], _deadline), do: :ok

  defp wait_for_processes_loop(refs, deadline) do
    remaining_ms = max(0, deadline - System.monotonic_time(:millisecond))

    if remaining_ms <= 0 do
      # Timeout: processes did not terminate. This is a real failure, not silent cleanup.
      raise "Timed out waiting for processes to terminate: #{inspect(refs)}"
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          remaining_refs = List.delete(refs, ref)
          wait_for_processes_loop(remaining_refs, deadline)
      after
        min(1000, remaining_ms) ->
          wait_for_processes_loop(refs, deadline)
      end
    end
  end

  defp retry_rm_rf(path, attempt \\ 1, max_attempts \\ 10) do
    # After processes have been awaited in on_exit hooks, rm_rf should succeed.
    # Retry with backoff in case of transient lock contention, but raise on final failure.
    result = File.rm_rf(path)

    case result do
      {:ok, _files} ->
        :ok

      _ ->
        if attempt < max_attempts do
          # Exponential backoff: 50ms, 100ms, 200ms, 400ms, 800ms...
          backoff_ms = 50 * Integer.pow(2, attempt - 1)
          Process.sleep(backoff_ms)
          retry_rm_rf(path, attempt + 1, max_attempts)
        else
          raise "Failed to remove #{path} after #{max_attempts} attempts: #{inspect(result)}"
        end
    end
  end
end
