defmodule Arbiter.Worker.CompletionMergeTest do
  @moduledoc """
  End-to-end proof for bd-7qq81g: a `--with-claude` dispatch on the default
  (Direct) domain must integrate the branch into the target line when the
  worker finishes — a real `git merge --no-ff` commit on `main` — rather than
  closing the task without merging.
  """

  # DataCase (async: false → shared sandbox) so the worker/driver/watchdog
  # processes under the DynamicSupervisor reach the same DB connection.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Messages.Message
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  @fixture Path.expand("../../fixtures/commit_and_done.sh", __DIR__)

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    # Clone into a bare repo so the worktree code can fetch origin/main.
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  defp wait_until(fun, timeout \\ 2_000) do
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

  # Teardown writes into the tmp root after the task is closed, from more than
  # one process: the Driver reaps the worktree (a `cleanup-dirty-probe` git call
  # plus `git worktree remove`), and the task's Watchdog — which performs the
  # `:close` on a direct merge — runs `CleanupWorktree` (dirty probe, private
  # clone sync-back) in its own `after_transaction` hook, i.e. AFTER the DB row
  # already reads `:closed`. Block until the worker, the Driver and every other
  # process registered under the task are down, so the setup's `rm_rf!` cannot
  # race those writes.
  defp drain(%{worker_pid: worker, driver_pid: driver, task: %{id: task_id}}) do
    if Process.alive?(worker), do: GenServer.stop(worker, :normal)
    await_down([worker, driver])

    pids = for {_key, pid} <- Arbiter.Worker.Registry.all_for(task_id), do: pid

    for pid <- pids, Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 10_000)
      catch
        :exit, _ -> :ok
      end
    end

    await_down(pids)
  end

  defp await_down(pids) do
    for pid <- pids, is_pid(pid) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 10_000
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "completion-merge-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"merge/repo" => repo})

    on_exit(fn ->
      File.rm_rf!(tmp)
    end)

    # Plain workspace → merger_strategy/1 falls back to :direct.
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "merge-ws-#{System.unique_integer([:positive])}",
        prefix: "mg"
      })

    %{repo: repo, ws: ws}
  end

  test "a --with-claude completion merges the branch into main with a --no-ff commit",
       %{repo: repo, ws: ws} do
    {:ok, task} =
      Ash.create(Issue, %{title: "integrate me", workspace_id: ws.id, issue_type: :feature})

    {:ok, result} =
      Dispatch.dispatch(task.id,
        force: true,
        repo: "merge/repo",
        start_claude: true,
        claude_command: [@fixture],
        interval_ms: 10,
        max_ticks: 200
      )

    on_exit(fn -> drain(result) end)

    # Wait for the whole path: worker done → Direct merge → task closes.
    # We use the task's DB status (not worker in-memory state) because the
    # StopWorker after-action kills the worker process right after close_task
    # returns — checking Worker.state/1 would raise if we arrive slightly late.
    wait_until(fn ->
      match?({:ok, %Issue{state: :closed}}, Ash.get(Issue, task.id))
    end)

    # main now carries a real merge commit (two parents) — not a fast-forward.
    {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    assert String.trim(merges) == "1"

    # ...and the worker's work landed on main via that merge.
    {tree, 0} = git(["ls-tree", "--name-only", "main"], repo)
    assert tree =~ "worker_work.txt"
  end

  # bd-4wy1w1 (P5): the same completion when the worker ran in a private clone
  # (git layout B, a `sandbox.backend: podman` workspace). Its commit exists
  # only in the clone until the branch is synced back, and the Direct merger
  # looks the branch up by name in the main repo.
  test "a worker in a private clone has its branch synced back and merged into main",
       %{repo: repo} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "merge-b-ws-#{System.unique_integer([:positive])}",
        prefix: "mb",
        config: %{"agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}}
      })

    {:ok, task} =
      Ash.create(Issue, %{
        title: "integrate from a clone",
        workspace_id: ws.id,
        issue_type: :feature
      })

    {:ok, result} =
      Dispatch.dispatch(task.id,
        force: true,
        repo: "merge/repo",
        start_claude: true,
        claude_command: [@fixture],
        interval_ms: 10,
        max_ticks: 200
      )

    on_exit(fn -> drain(result) end)

    assert Arbiter.Worker.PrivateClone.clone?(result.worktree_path)

    wait_until(fn ->
      match?({:ok, %Issue{state: :closed}}, Ash.get(Issue, task.id))
    end)

    {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    assert String.trim(merges) == "1"
    {tree, 0} = git(["ls-tree", "--name-only", "main"], repo)
    assert tree =~ "worker_work.txt"
  end

  test "a merge failure surfaces as a failure_reason and does NOT complete the worker",
       %{repo: repo, ws: ws} do
    {:ok, task} =
      Ash.create(Issue, %{title: "conflict me", workspace_id: ws.id, issue_type: :feature})

    # Create the source branch so it exists, but point target_branch at a branch
    # that does not — the Direct adapter's `git checkout <target>` then fails
    # deterministically (no race with the fixture). Drive the worker directly
    # so we control its meta.
    {_, 0} = git(["branch", "feature/x"], repo)

    meta = %{
      branch: "feature/x",
      repo_path: repo,
      target_branch: "no-such-target",
      merge_title: "Merge #{task.id}"
    }

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "merge/repo", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)

    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

    snap = Worker.state(pid)
    assert {:merge_failed, _reason} = snap.meta.failure_reason
    # Critically: not silently :completed.
    refute snap.outcome == :succeeded

    # bd-8rrn9t: a non-conflict merge failure must escalate to the coordinator
    # too, not just fail silently — an approved run whose merge step fails
    # can leave a real PR stranded and needs a human to notice.
    escalations = Message.inbox("admiral", workspace_id: ws.id)
    escalation = Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))
    assert escalation
    assert escalation.body =~ "feature/x"
  end

  test "a conflicting auto-merge aborts, keeps main clean, escalates, and does NOT close the task",
       %{repo: repo, ws: ws} do
    # bd-1rhyla: a conflicted auto-merge once left main half-merged + uncompilable
    # and took the live server down. Prove the full recovery contract end-to-end.
    {:ok, task} =
      Ash.create(Issue, %{
        title: "conflict me for real",
        workspace_id: ws.id,
        issue_type: :feature
      })

    # Diverging edits to the same file on both branches → a genuine merge conflict.
    {_, 0} = git(["checkout", "-q", "-b", "feature/conflict"], repo)
    File.write!(Path.join(repo, "README.md"), "from feature\n")
    {_, 0} = git(["commit", "-q", "-am", "feature edit"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    File.write!(Path.join(repo, "README.md"), "from main\n")
    {_, 0} = git(["commit", "-q", "-am", "main edit"], repo)

    {head_before, 0} = git(["rev-parse", "HEAD"], repo)

    meta = %{
      branch: "feature/conflict",
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}"
    }

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "merge/repo", workspace_id: ws.id, meta: meta)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

    # 1. main is unchanged + compilable: HEAD didn't move, no merge commit, tree clean.
    {head_after, 0} = git(["rev-parse", "HEAD"], repo)
    assert head_after == head_before
    {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    assert String.trim(merges) == "0"
    assert {"", 0} = git(["status", "--porcelain"], repo)
    refute File.read!(Path.join(repo, "README.md")) =~ "<<<<<<<"

    # 2. the task is NOT closed (parked for rebase) — and the worker failed, not completed.
    snap = Worker.state(pid)
    assert snap.outcome == :failed
    assert snap.meta.failure_reason == :merge_conflict
    {:ok, reloaded} = Ash.get(Issue, task.id)
    refute reloaded.state == :closed
    assert reloaded.notes =~ "Merge conflict"
    assert reloaded.notes =~ "README.md"

    # 3. the Coordinator inbox got an escalation naming the conflicting files.
    escalations = Message.inbox("admiral", workspace_id: ws.id)
    escalation = Enum.find(escalations, &(&1.kind == :escalation and &1.directive_ref == task.id))
    assert escalation
    assert escalation.body =~ "README.md"
    assert escalation.body =~ "feature/conflict"
  end
end
