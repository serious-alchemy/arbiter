defmodule Arbiter.Worker.ReviewGateRefusedFixRoundTest do
  @moduledoc """
  bd-dylogx: a fix-round implementer whose placement a node refuses with a hold reason
  (`startup_failed`, `placement_timeout`, ...) never started, so the gate asks again up to a
  bound instead of parking the ticket as "revise could not start". Past the bound, or on a
  spawn error that is not a refusal, the ticket parks as before.

  The refusal is a stub over the gate's `:session_start` seam; the reviewer (the first
  session start) runs the real fixture.
  """

  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog
  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.CircuitBreaker
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{ClaudeSession, PrivateClone, ReviewGate}

  @two_rounds Path.expand("../../fixtures/review_two_rounds.sh", __DIR__)
  @revise_hang Path.expand("../../fixtures/revise_hang.sh", __DIR__)

  @startup_failed {:claude_start_failed,
                   {:remote_placement_failed,
                    {:refused, "startup_failed", "the pod ended before its worker started"}}}

  setup do
    CircuitBreaker.reset_all()
    on_exit(&CircuitBreaker.reset_all/0)

    tmp = Path.join(System.tmp_dir!(), "rg-refused-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)
    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-refused-#{System.unique_integer([:positive])}",
        prefix: "rr",
        config: %{"review" => %{"required" => true, "require_ci_green" => false}}
      })

    %{repo: repo, tmp: tmp, ws: ws}
  end

  test "a startup_failed refusal is retried and the retried round runs", ctx do
    {start, calls} = stub_start([{:error, @startup_failed}])
    rig = rig(ctx, "feature/rr-1")

    log =
      capture_log(fn ->
        gate = start_gate(rig, ctx, session_start: start, fix_refusal_max_retries: 2)
        wait_until(fn -> calls_made(calls) >= 3 and live_impl?(gate) end)

        state = :sys.get_state(gate)
        assert state.phase == :revising
        assert String.ends_with?(state.current_id, "#impl1#r1")
        stop_gate(gate)
      end)

    assert log =~ "implementer start refused (startup_failed"
    assert log =~ "retrying 1/2"
  end

  test "the ticket parks once the retry bound is exhausted", ctx do
    {start, calls} = stub_start(List.duplicate({:error, @startup_failed}, 5))
    rig = rig(ctx, "feature/rr-2")

    capture_log(fn ->
      gate = start_gate(rig, ctx, session_start: start, fix_refusal_max_retries: 1)
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 10_000
    end)

    # reviewer + first attempt + one retry
    assert calls_made(calls) == 3
  end

  test "a spawn error that is not a hold reason parks without retrying", ctx do
    {start, calls} = stub_start([{:error, :boom}])
    rig = rig(ctx, "feature/rr-3")

    capture_log(fn ->
      gate = start_gate(rig, ctx, session_start: start, fix_refusal_max_retries: 2)
      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 10_000
    end)

    assert calls_made(calls) == 2
  end

  # ---- helpers -----------------------------------------------------------

  # The first call (the reviewer) is real; then each scripted result is returned in turn
  # and, once the script is spent, the real start runs.
  defp stub_start(script) do
    {:ok, agent} = Agent.start_link(fn -> %{n: 0, script: script} end)

    start = fn opts ->
      step =
        Agent.get_and_update(agent, fn %{n: n, script: s} = st ->
          cond do
            n == 0 -> {:real, %{st | n: 1}}
            s == [] -> {:real, %{st | n: n + 1}}
            true -> {hd(s), %{st | n: n + 1, script: tl(s)}}
          end
        end)

      if step == :real, do: ClaudeSession.start(opts), else: step
    end

    {start, agent}
  end

  defp calls_made(agent), do: Agent.get(agent, & &1.n)

  defp live_impl?(gate) do
    case :sys.get_state(gate) do
      %{current_id: id} when is_binary(id) -> Worker.whereis(id) != nil
      _ -> false
    end
  end

  defp stop_gate(gate) do
    ref = Process.monitor(gate)

    try do
      GenServer.stop(gate, :normal)
    catch
      :exit, _ -> :ok
    end

    assert_receive {:DOWN, ^ref, :process, ^gate, _}, 5_000
  end

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
  defp git!(args, repo), do: {_, 0} = git(args, repo)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(["config", "user.email", "repo@example.com"], repo)
    git!(["config", "user.name", "Repo"], repo)
    git!(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(["add", "README.md"], repo)
    git!(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(["remote", "add", "origin", bare], repo)
    git!(["fetch", "-q", "origin"], repo)
    repo
  end

  defp rig(ctx, branch) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "refused fix round",
        workspace_id: ctx.ws.id,
        issue_type: :feature
      })

    task = put_state!(task, :active)

    git!(["checkout", "-q", "-b", branch], ctx.repo)
    File.write!(Path.join(ctx.repo, "feature.txt"), "worker work\n")
    git!(["add", "feature.txt"], ctx.repo)
    git!(["commit", "-q", "-m", "feature work"], ctx.repo)
    git!(["push", "-q", "origin", branch], ctx.repo)
    git!(["checkout", "-q", "main"], ctx.repo)

    {:ok, wt} = PrivateClone.attach(ctx.repo, branch, "main")
    git!(["config", "commit.gpgsign", "false"], wt)
    git!(["fetch", "-q", "origin", branch], wt)
    git!(["branch", "-q", "--set-upstream-to=origin/" <> branch, branch], wt)

    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ctx.ws.id,
        meta: %{
          branch: branch,
          repo_path: ctx.repo,
          worktree_path: wt,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    %{task: task, branch: branch, wt: wt, author: author}
  end

  defp start_gate(rig, ctx, opts) do
    {:ok, gate} =
      ReviewGate.start(
        Keyword.merge(
          [
            author: rig.author,
            task_id: rig.task.id,
            workspace_id: ctx.ws.id,
            repo: "trib/repo",
            worktree_path: rig.wt,
            branch: rig.branch,
            target_branch: "main",
            timeout_ms: 15_000,
            command: [@two_rounds, Path.join(ctx.tmp, "marker-#{rig.task.id}"), rig.branch],
            command_provider: "claude",
            revise_command: [@revise_hang],
            rounds: 2
          ],
          opts
        )
      )

    gate
  end

  defp wait_until(fun, timeout \\ 8_000) do
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
