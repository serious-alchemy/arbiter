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
    tmp =
      Path.join(
        System.tmp_dir!(),
        "prepush-gate-#{System.unique_integer([:positive])}-#{:erlang.phash2(self())}"
      )

    File.mkdir_p!(tmp)
    {repo, remote} = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"gate/repo" => repo})

    on_exit(fn -> File.rm_rf(tmp) end)

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

    test "a failing check keeps the pass from reporting done", %{repo: repo, remote: remote} do
      ws = workspace(%{"prepush_check" => "echo still-red; exit 1"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, Map.put(fix_pass_meta(), :prepush_nudge_cap, 0))
      done(pid)
      wait_until(fn -> failed?(pid) end)

      snap = Worker.state(pid)
      assert snap.meta.commit_gate_reason == :prepush_failed
      refute snap.meta[:result] == :pass_finished

      # Not pushed: remote never saw the branch
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      refute refs =~ "bd-gate/#{task.id}"
    end

    test "a passing check lets the pass finish and pushes to remote", %{
      repo: repo,
      remote: remote
    } do
      ws = workspace(%{"prepush_check" => "exit 0"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, fix_pass_meta())
      ref = Process.monitor(pid)
      done(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
      assert latest_run(task).outcome == :succeeded

      # Pushed to remote
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      assert refs =~ "bd-gate/#{task.id}"
    end

    test "the failure is sent back to the fix-pass session under its own cap", %{
      repo: repo,
      remote: remote
    } do
      ws = workspace(%{"prepush_check" => "echo fix-pass-red; exit 1"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid =
        start_worker(
          task,
          repo,
          path,
          Map.merge(fix_pass_meta(), %{prepush_nudge_cap: 1})
        )

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
      assert snap.meta.commit_gate_reason == :prepush_failed

      # Nudge prompt was appended to the run prompt and mentions fix-pass instructions
      assert {:ok, prompt} = Arbiter.Worker.PromptLog.read(snap.run_id)
      assert prompt =~ "fix-pass-red"
      assert prompt =~ "the arbiter pushes"
      refute prompt =~ "no PR has been opened"

      # Remote branch was NOT pushed
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      refute refs =~ "bd-gate/#{task.id}"
    end

    test "send-back recovers when check becomes green; remote is updated only after check passes",
         %{repo: repo, remote: remote} do
      ws = workspace(%{"prepush_check" => "test -f fixed.txt"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid =
        start_worker(
          task,
          repo,
          path,
          Map.merge(fix_pass_meta(), %{prepush_nudge_cap: 1})
        )

      # Attempt 1 leaves fixed.txt missing (prepush check fails).
      # Attempt 2 creates fixed.txt so the re-check passes.
      script =
        "if [ -f marker.tmp ]; then touch fixed.txt; else touch marker.tmp; fi; printf 'arb %s\\n' done"

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: path,
          command: ["sh", "-c", script]
        )

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000

      assert latest_run(task).outcome == :succeeded

      # The remote branch was pushed after going green
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      assert refs =~ "bd-gate/#{task.id}"
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

  describe "a ReviewGate fix round" do
    test "a failing check keeps the fix round from routing on; failure is sent back to session",
         %{repo: repo, remote: remote} do
      ws = workspace(%{"prepush_check" => "echo 'fix-round-red'; exit 1"})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid =
        start_worker(task, repo, path, %{
          role: :implementer,
          review_gate_fix_round_attempts: 1,
          prepush_nudge_cap: 1
        })

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
      assert snap.meta.commit_gate_reason == :prepush_failed

      # Remote was not updated
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      refute refs =~ "bd-gate/#{task.id}"
    end
  end

  describe "the pre_push_checks recipe (bd-8wdrql)" do
    alias Arbiter.Workers.PrepushSteps

    defp recipe(steps, extra \\ %{}),
      do: workspace(Map.merge(%{"pre_push_checks" => steps}, extra))

    defp step(name, cmd, extra \\ %{}), do: Map.merge(%{"name" => name, "cmd" => cmd}, extra)

    defp steps_of(pid), do: pid |> Worker.state() |> Map.fetch!(:run_id) |> PrepushSteps.list()

    test "a red step is caught before the push, every step's result is recorded on the run",
         %{repo: repo, remote: remote} do
      ws =
        recipe([
          step("format", "echo 'mix format: 2 files need formatting'; exit 1"),
          step("compile", "true"),
          step("credo", "echo 'credo: unused alias'; exit 2")
        ])

      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{prepush_nudge_cap: 0})
      done(pid)
      wait_until(fn -> failed?(pid) end)

      snap = Worker.state(pid)
      assert snap.meta.commit_gate_reason == :prepush_failed

      # Both failing steps are in the escalation, not just the first.
      esc = escalation(ws, task)
      assert esc.body =~ "2 files need formatting"
      assert esc.body =~ "credo: unused alias"

      assert [
               %{name: "format", status: :failed, exit_status: 1, attempt: 1},
               %{name: "compile", status: :passed, attempt: 1},
               %{name: "credo", status: :failed, exit_status: 2, attempt: 1}
             ] = steps_of(pid)

      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      refute refs =~ "bd-gate/#{task.id}"
    end

    test "a green recipe routes on to the review gate and records passed steps", %{repo: repo} do
      ws = recipe([step("format", "true"), step("compile", "true")])
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      assert [%{status: :passed, name: "format"}, %{status: :passed, name: "compile"}] =
               steps_of(pid)
    end

    test "the failure goes back to the SAME session; the push waits for the fix", %{
      repo: repo,
      remote: remote,
      tmp: tmp
    } do
      marker = Path.join(tmp, "first-run-marker")
      ws = recipe([step("format", "echo needs-format; test -f fixed.txt"), step("ok", "true")])
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{})

      # First run: leaves a marker, prints done. The send-back relaunches this
      # same command, which now "fixes" the tree. (`git` ignores untracked
      # files for the gate: the fixed file is committed by the script.)
      script =
        "if [ -f #{marker} ]; then touch fixed.txt; git add -A; git -c user.email=a@b -c user.name=n commit -q -m fix; " <>
          "else touch #{marker}; fi; printf 'arb %s\\n' done"

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: path,
          command: ["sh", "-c", script]
        )

      wait_until(fn -> at_review_gate?(pid) end)

      snap = Worker.state(pid)
      assert snap.meta.prepush_nudge_attempts == 1

      steps = steps_of(pid)

      assert [
               {1, "format", :failed},
               {1, "ok", :passed},
               {2, "format", :passed},
               {2, "ok", :passed}
             ] =
               Enum.map(steps, &{&1.attempt, &1.name, &1.status})

      # Nothing was pushed by the gate itself; the review gate pushes.
      {refs, 0} = git(["ls-remote", "--heads", remote], repo)
      refute refs =~ "never-pushed"
    end

    test "pre_push_max_attempts bounds the send-backs, then it escalates", %{repo: repo} do
      ws = recipe([step("format", "echo red; exit 1")], %{"pre_push_max_attempts" => 1})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{})

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
      assert escalation(ws, task)
      # Two gate passes: the first red, the post-send-back one red again.
      assert steps_of(pid) |> Enum.map(& &1.attempt) |> Enum.uniq() == [1, 2]
    end

    test "touched steps see the files the branch changed against the target", %{
      repo: repo,
      tmp: tmp
    } do
      marker = Path.join(tmp, "touched.txt")

      ws =
        recipe([step("touched", "echo {files} > #{marker}", %{"scope" => "touched"})])

      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid = start_worker(task, repo, path, %{})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      assert File.read!(marker) == "real_work.txt\n"
    end

    test "an infra error (the sandbox refusing) fails open and is recorded", %{repo: repo} do
      ws = recipe([step("format", "true")])
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      exec = fn _command, _timeout_s -> {:error, :podman_gone} end
      pid = start_worker(task, repo, path, %{prepush_exec: exec})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      assert [%{name: "format", status: :error}] = steps_of(pid)
    end

    test "a sandboxed run's steps go through the exec hook, not the host", %{repo: repo, tmp: tmp} do
      host_marker = Path.join(tmp, "ran-on-host")
      ws = recipe([step("format", "touch #{host_marker}")])
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      test_pid = self()

      exec = fn command, timeout_s ->
        send(test_pid, {:exec, command, timeout_s})
        {"", 0}
      end

      pid = start_worker(task, repo, path, %{prepush_exec: exec})
      done(pid)
      wait_until(fn -> at_review_gate?(pid) end)

      assert_received {:exec, command, timeout_s}
      assert command =~ host_marker
      assert timeout_s <= 120
      refute File.exists?(host_marker)
    end

    test "a ReviewGate fix round is held to the same recipe", %{repo: repo} do
      ws = recipe([step("format", "echo fix-round-red; exit 1")], %{"pre_push_max_attempts" => 1})
      task = new_task(ws)
      path = committed_worktree(repo, "bd-gate/#{task.id}")

      pid =
        start_worker(task, repo, path, %{role: :implementer, review_gate_fix_round_attempts: 1})

      {:ok, _port} =
        Arbiter.Worker.ClaudeSession.start(
          owner: pid,
          worktree_path: path,
          command: ["sh", "-c", "printf 'arb %s\\n' done"]
        )

      wait_until(fn -> failed?(pid) end)
      assert Worker.state(pid).meta.commit_gate_reason == :prepush_failed
      assert [%{name: "format", status: :failed} | _] = steps_of(pid)
    end
  end
end
