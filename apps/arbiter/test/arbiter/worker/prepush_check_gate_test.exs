defmodule Arbiter.Worker.PrepushCheckGateTest do
  @moduledoc """
  bd-28c6qo (GitHub #24): the worker commit gate runs `worker.prepush_check`
  before a branch is routed on to the review gate / merger (which is what
  pushes it and opens the PR), and before a CI fix pass reports done.

  A red check goes back to the same worker session; nothing is routed on. An
  unset key changes nothing.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)

    remote = Path.join(dir, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(["remote", "add", "origin", remote], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)
    {repo, remote}
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "prepush-gate-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    {repo, remote} = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"gate/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo, remote: remote, tmp: tmp}
  end

  defp workspace(worker_config) do
    config = %{"review" => %{"required" => true}}
    config = if worker_config, do: Map.put(config, "worker", worker_config), else: config

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pp-ws-#{System.unique_integer([:positive])}",
        prefix: "pp",
        config: config
      })

    ws
  end

  defp committed_worktree(repo, branch) do
    {:ok, path} = Worktree.create(repo, branch, "main")
    {_, 0} = git(["config", "user.email", "wt@example.com"], path)
    {_, 0} = git(["config", "user.name", "WT"], path)
    {_, 0} = git(["config", "commit.gpgsign", "false"], path)
    File.write!(Path.join(path, "real_work.txt"), "real\n")
    {_, 0} = git(["add", "real_work.txt"], path)
    {_, 0} = git(["commit", "-q", "-m", "real work"], path)
    path
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "prepush task", workspace_id: ws.id, issue_type: :feature})

    put_state!(task, :active)
  end

  defp start_worker(task, repo, path, extra_meta) do
    meta =
      Map.merge(
        %{
          branch: "bd-gate/#{task.id}",
          repo_path: repo,
          worktree_path: path,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_spawn: false,
          commit_nudge_cap: 0
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "gate/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    pid
  end

  defp done(pid), do: send(pid, {:__claude_session_done__, "arb " <> "done"})

  defp failed?(pid), do: match?(%{state: :finished, outcome: :failed}, Worker.state(pid))

  defp at_review_gate?(pid),
    do: match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid))

  defp escalation(ws, task) do
    Message.inbox("admiral", workspace_id: ws.id)
    |> Enum.find(&(&1.kind == :escalation and &1.directive_ref == task.id))
  end

  describe "the main run" do
    test "a failing check parks the worker with its output; nothing is routed on or pushed",
         %{repo: repo, remote: remote} do
      ws = workspace(%{"prepush_check" => "echo 'lint: unused variable foo'; exit 2"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")
      Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:done:#{ws.id}")

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> failed?(pid) end)

      snap = Worker.state(pid)
      refute snap.waiting_on == :review_gate
      assert snap.meta.failure_reason == :prepush_check_failed
      assert snap.meta.commit_gate_reason == :prepush_failed
      refute_received {:worker_done, _}

      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.state == :closed
      assert reloaded.notes =~ "lint: unused variable foo"

      esc = escalation(ws, task)
      assert esc
      assert esc.body =~ "lint: unused variable foo"

      # Not pushed: the remote never saw the branch.
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      refute refs =~ "bd-gate/#{task.id}"
    end

    test "the failure is sent back to the SAME session, under its own cap", %{repo: repo} do
      ws = workspace(%{"prepush_check" => "echo red; exit 1"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 1})

      # A real session that prints the sentinel and exits; the send-back
      # relaunches that same command (a fixture argv has no prompt slot).
      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: path,
          command: ["sh", "-c", "printf 'arb %s\\n' done"]
        )

      wait_until(fn -> failed?(pid) end)

      snap = Worker.state(pid)
      assert snap.meta.prepush_nudge_attempts == 1
      assert snap.meta.commit_gate_detail == :cap_exhausted
      # The commit gate's own counter is untouched.
      refute Map.has_key?(snap.meta, :commit_nudge_attempts)

      assert_receive {:event, %{topic: "gate_cap_hit", gate: "commit_gate"} = event}
      assert event.rounds == 1
      assert event.cap == 1
    end

    test "a passing check routes to the review gate, having run in the worktree", %{
      repo: repo,
      tmp: tmp
    } do
      marker = Path.join(tmp, "ran-in")
      ws = workspace(%{"prepush_check" => "pwd > #{marker}"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      assert File.read!(marker) |> String.trim() |> Path.basename() == Path.basename(path)
      refute Map.has_key?(Worker.state(pid).meta, :commit_gate_reason)
    end

    test "a per-repo command overrides the workspace one", %{repo: repo} do
      ws =
        workspace(%{
          "prepush_check" => "exit 0",
          "repos" => %{"repo" => %{"prepush_check" => "echo repo-red; exit 1"}}
        })

      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")
      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> failed?(pid) end)

      assert Worker.state(pid).meta.commit_gate_reason == :prepush_failed
    end

    test "unset config changes nothing: no check, straight to the review gate", %{repo: repo} do
      ws = workspace(nil)
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      meta = Worker.state(pid).meta
      refute Map.has_key?(meta, :prepush_nudge_attempts)
      refute Map.has_key?(meta, :prepush_ref)
      refute Map.has_key?(meta, :commit_gate_reason)
    end

    test "the commit gate still runs first: an uncommitted tree never reaches the check", %{
      repo: repo,
      tmp: tmp
    } do
      marker = Path.join(tmp, "should-not-exist")
      ws = workspace(%{"prepush_check" => "touch #{marker}"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")
      File.write!(Path.join(path, "dirty.txt"), "uncommitted\n")

      pid = start_worker(task, repo, path, %{})
      done(pid)
      wait_until(fn -> failed?(pid) end)

      assert Worker.state(pid).meta.commit_gate_reason == :uncommitted
      refute File.exists?(marker)
    end

    test "a review-only worker never runs the check", %{repo: repo, tmp: tmp} do
      marker = Path.join(tmp, "reviewer-should-not-run-it")
      ws = workspace(%{"prepush_check" => "touch #{marker}; exit 1"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{review_only: true})
      done(pid)
      _ = :sys.get_state(pid)
      refute File.exists?(marker)
      refute match?(%{meta: %{commit_gate_reason: :prepush_failed}}, Worker.state(pid))
    end
  end

  describe "timeout and infra-error policy" do
    test "a timeout fails open by default: the work proceeds to the review gate", %{repo: repo} do
      ws = workspace(%{"prepush_check" => "sleep 30", "prepush_check_timeout_seconds" => 1})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      refute Map.has_key?(Worker.state(pid).meta, :commit_gate_reason)
    end

    test "on_timeout \"fail\" treats a timeout as a failed check, naming the timeout",
         %{repo: repo} do
      ws =
        workspace(%{
          "prepush_check" => "echo slow-step; sleep 30",
          "prepush_check_timeout_seconds" => 1,
          "prepush_check_on_timeout" => "fail"
        })

      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> failed?(pid) end)

      assert Worker.state(pid).meta.commit_gate_reason == :prepush_failed
      {:ok, reloaded} = Ash.get(Issue, task.id)
      assert reloaded.notes =~ "timed out after 1s"
      assert reloaded.notes =~ "slow-step"
    end

    test "a command sh cannot run (127) is an infra error and fails open", %{repo: repo} do
      ws = workspace(%{"prepush_check" => "definitely-not-a-real-binary-xyz"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)
    end
  end

  describe "a CI fix pass" do
    defp fix_pass_meta, do: %{role: :fix_pass}

    defp latest_run(task) do
      Arbiter.Workers.Run
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.read!()
      |> List.first()
    end

    test "a failing check keeps the pass from reporting done", %{repo: repo} do
      ws = workspace(%{"prepush_check" => "echo still-red; exit 1"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, Map.put(fix_pass_meta(), :prepush_nudge_cap, 0))
      done(pid)
      wait_until(fn -> failed?(pid) end)

      snap = Worker.state(pid)
      assert snap.meta.commit_gate_reason == :prepush_failed
      refute snap.meta[:result] == :pass_finished
    end

    test "a passing check lets the pass finish as before", %{repo: repo} do
      ws = workspace(%{"prepush_check" => "exit 0"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, fix_pass_meta())
      ref = Process.monitor(pid)
      done(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
      assert latest_run(task).outcome == :succeeded
    end

    test "unset config: the pass finishes exactly as before", %{repo: repo} do
      ws = workspace(nil)
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, fix_pass_meta())
      ref = Process.monitor(pid)
      done(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
      assert latest_run(task).outcome == :succeeded
    end
  end
end
