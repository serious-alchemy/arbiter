defmodule Arbiter.Worker.ReviewGateStallTest do
  @moduledoc """
  bd-7xtz6w: a ReviewGate that stalls must not park its author forever.

  The incident (bd-45tkhq, 2026-09-21): after round 2's implementer exited, the
  gate crashed launching the round-3 reviewer (`Arbiter.Worker.start/1` was
  momentarily undefined during a code reload). The gate's per-pass timeout is a
  `Process.send_after/3` to the gate itself, so it died with the gate; the
  author's `:DOWN` backstop did not fire either, and the author sat
  `:waiting` on the review gate for 3+ hours with nothing in flight — while
  `worker_resume` refused to touch it because the run "was waiting on the
  review gate".

  Covered here:

    * a crash while spawning a pass is reported by the gate as a verdict (a
      recorded round + a named park), not a silent gate death;
    * an author whose gate is gone — or alive but stalled with no pass in
      flight — clears itself on its own liveness check rather than waiting;
    * a gate with a genuine reviewer in flight is left alone, and the resume
      guard still refuses to stop it.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.{ClaudeSession, Dispatch, ReviewGate}

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-stall-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"stall/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "stall-ws-#{System.unique_integer([:positive])}",
        prefix: "st",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  describe "a crash while spawning a pass (the bd-45tkhq shape)" do
    setup do
      :meck.new(ClaudeSession, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload() end)

      :meck.expect(ClaudeSession, :start, fn _opts ->
        # What a code reload mid-spawn looked like in the incident.
        raise UndefinedFunctionError, module: Arbiter.Worker, function: :start, arity: 1
      end)

      :ok
    end

    test "is reported as a recorded, named park instead of killing the gate",
         %{repo: repo, ws: ws} do
      {task, pid} = start_live_gate(repo, ws)
      wait_finished(pid)

      # The gate itself reported: the park names the reviewer that could not
      # be started, rather than the generic `:inconclusive` a gate death leaves.
      task = Ash.get!(Issue, task.id)
      assert task.attention_cause == :reviewer_failed

      [round] = rounds(task.id)
      assert round.role in [:review, "review"]
      assert round.findings =~ "UndefinedFunctionError"
    end
  end

  describe "the author's liveness check" do
    test "parks an author whose gate is gone even when the :DOWN never matched",
         %{repo: repo, ws: ws} do
      {task, pid} = start_live_gate(repo, ws, %{review_gate_liveness_ms: 50})
      gate = wait_until_review_gate()

      # Reproduce the incident's end state: the author's monitor ref no longer
      # matches, so the `:DOWN` falls through to the catch-all — and the gate
      # is dead with no reviewer in flight.
      :sys.replace_state(pid, fn s -> %{s | meta: Map.delete(s.meta, :review_gate_ref)} end)
      # Between callbacks first (bd-jw7cb0): the gate is still launching its
      # reviewer, and a gate killed mid-query takes the test's sandbox
      # connection with it — the author's park and this test's own reads then
      # fail with OwnershipError. Suspended, it dies holding nothing.
      :sys.suspend(gate, 5_000)
      Process.exit(gate, :kill)

      wait_finished(pid)

      task = Ash.get!(Issue, task.id)
      assert task.attention_cause == :inconclusive
    end

    test "times out a live gate that has no pass in flight", %{repo: repo, ws: ws} do
      {task, pid} =
        start_live_gate(repo, ws, %{review_gate_liveness_ms: 50, review_gate_stall_ms: 300})

      gate = wait_until_review_gate()
      gate_ref = Process.monitor(gate)

      # A gate wedged inside a callback: alive, but it can neither answer nor
      # process its own per-pass timer.
      :sys.suspend(gate)

      wait_finished(pid)
      assert_receive {:DOWN, ^gate_ref, :process, ^gate, _}, 1_000

      task = Ash.get!(Issue, task.id)
      assert task.attention_cause == :reviewer_timeout
    end

    test "leaves a gate with a genuine reviewer in flight alone", %{repo: repo, ws: ws} do
      {task, pid} =
        start_live_gate(repo, ws, %{review_gate_liveness_ms: 50, review_gate_stall_ms: 300})

      gate = wait_until_review_gate()

      # Several liveness ticks and well past the stall limit.
      Process.sleep(800)

      assert Process.alive?(gate)
      assert %{state: :waiting, waiting_on: :review_gate} = Worker.state(pid)

      # And the resume guard refuses to stop it, naming live evidence.
      assert {false, msg} = Dispatch.resumable_status(task.id)
      assert msg =~ "review gate"
      refute msg =~ "arb worker list"
    end
  end

  describe "the resume guard" do
    test "does not refuse on the author's waiting state alone", %{repo: repo, ws: ws} do
      task = new_task(ws)
      pid = start_parked_author(task, repo)

      # No gate process, no reviewer or implementer pass: nothing is in flight.
      assert %{state: :waiting, waiting_on: :review_gate} = Worker.state(pid)
      assert {true, nil} = Dispatch.resumable_status(task.id)
    end

    test "refuses when a review pass for the task is live", %{repo: repo, ws: ws} do
      task = new_task(ws)
      _pid = start_parked_author(task, repo)

      review_id = ReviewGate.reviewer_task_id(task.id)

      {:ok, reviewer} =
        Worker.start(
          task_id: review_id,
          repo: "stall/repo",
          workspace_id: nil,
          meta: %{role: :reviewer, reviews: task.id}
        )

      on_exit(fn -> safe_stop(reviewer) end)
      :ok = Worker.advance(reviewer, :reviewing)

      assert {false, msg} = Dispatch.resumable_status(task.id)
      assert msg =~ review_id
      refute msg =~ "arb worker list"
    end
  end

  # ---- helpers -------------------------------------------------------------

  # A parked author finishes its run but stays resident (`:finished`).
  defp wait_finished(pid) do
    wait_until(fn -> match?(%{state: :finished}, Worker.state(pid)) end, 5_000)
  end

  defp rounds(task_id) do
    Arbiter.ReviewGate.Round
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  # An author through a real ReviewGate whose reviewer lingers (`sleep 10`), so
  # the gate stays alive while a test probes it.
  defp start_live_gate(repo, ws, extra_meta \\ %{}) do
    task = new_task(ws)
    branch = "feature/stall"
    :ok = seed_feature_branch(repo, branch)
    sleep = System.find_executable("sleep") || "/bin/sleep"

    meta =
      Map.merge(
        %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          worktree_path: repo,
          review_command: [sleep, "10"],
          review_timeout_ms: 30_000
        },
        extra_meta
      )

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "stall/repo", workspace_id: ws.id, meta: meta)

    on_exit(fn ->
      review_id = ReviewGate.reviewer_task_id(task.id)
      if rp = Worker.whereis(review_id), do: safe_stop(rp)
      safe_stop(pid)
    end)

    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    {task, pid}
  end

  # An author parked on the review gate with no gate spawned at all.
  defp start_parked_author(task, repo) do
    branch = "feature/parked"
    :ok = seed_feature_branch(repo, branch)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "stall/repo",
        workspace_id: task.workspace_id,
        meta: %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> safe_stop(pid) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{waiting_on: :review_gate}, Worker.state(pid)) end)
    pid
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "stall task", workspace_id: ws.id, issue_type: :bug})

    task = put_state!(task, :active)
    task
  end

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
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  defp wait_until(fun, timeout \\ 4_000) do
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

  defp wait_until_review_gate(timeout \\ 4_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      Arbiter.Worker.Supervisor
      |> DynamicSupervisor.which_children()
      |> Enum.find_value(fn
        {_, p, _, [Arbiter.Worker.ReviewGate]} when is_pid(p) -> p
        _ -> nil
      end)
    end)
    |> Enum.find(fn pid ->
      cond do
        is_pid(pid) -> true
        System.monotonic_time(:millisecond) > deadline -> flunk("no ReviewGate appeared")
        true -> Process.sleep(15) && false
      end
    end)
  end
end
