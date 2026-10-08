defmodule Arbiter.Worker.ReviewGateSendBackTest do
  @moduledoc """
  bd-651ine / #529: a `send_back` resolution is not a pass. A ticket the gate
  parked after a REQUEST_CHANGES, whose implementer then pushed a fix commit and
  was resumed, must get a reviewer round on the new head before anything merges.

  This pins the Worker's own completion path (local `Direct` merger): a resumed
  implementer's `arb done` re-enters the ReviewGate. That path was already
  correct — this test passes on the fork point — so it is a regression pin, NOT
  the reproduction of the incident. The reproduction is the production lane
  (open PR, `via_review_gate` Watchdog / MergeQueue) in
  `Arbiter.Worker.WatchdogReviewAuthorizationTest` and
  `Arbiter.Workflows.MergeQueueReviewAuthorizationTest`, which fail without the
  `MergeAuthorization` check and the review-round routing.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)
  @revise Path.expand("../../fixtures/revise.sh", __DIR__)

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

  defp commit_on_branch(repo, branch, file, body) do
    {_, 0} = git(["checkout", "-q", "-B", branch, branch], repo)
    File.write!(Path.join(repo, file), body)
    {_, 0} = git(["add", file], repo)
    {_, 0} = git(["commit", "-q", "-m", "work: #{file}"], repo)
    {sha, 0} = git(["rev-parse", "HEAD"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    String.trim(sha)
  end

  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end

  defp review_rows(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "send_back-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "sendback-ws-#{System.unique_integer([:positive])}",
        prefix: "sb",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "send-back task", workspace_id: ws.id, issue_type: :feature})

    %{repo: repo, ws: ws, task: put_state!(task, :active)}
  end

  defp meta(repo, task, branch, review_command) do
    %{
      branch: branch,
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      worktree_path: repo,
      review_timeout_ms: 5_000,
      review_rounds: 2,
      review_command: review_command,
      revise_command: [@revise]
    }
  end

  defp run_author(task, meta, outcome) do
    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})

    wait_until(
      fn -> match?(%{state: :finished, outcome: ^outcome}, Worker.state(pid)) end,
      15_000
    )

    pid
  end

  test "a send_back resolution + resume + implementer done runs a reviewer round on the new head",
       %{repo: repo, task: task} do
    branch = "feature/send-back"
    :ok = seed_feature_branch(repo, branch)

    # Round 1 REQUEST_CHANGES; the fix round changes nothing, so the gate parks.
    pid1 = run_author(task, meta(repo, task, branch, [@reviewer, "REQUEST_CHANGES"]), :failed)
    assert Ash.get!(Issue, task.id).attention_cause == :commit_gate_no_changes
    assert [%{verdict: :request_changes}] = review_rows(task.id)
    assert merge_commit_count(repo) == 0
    GenServer.stop(pid1, :normal)

    # The implementer's fix lands, the coordinator sends the ticket back.
    _ = commit_on_branch(repo, branch, "fix.txt", "the fix\n")

    {:ok, _} =
      Resolutions.record(%{
        task_id: task.id,
        decision: "send_back",
        reasoning: "fix the findings and report done so the gate re-reviews"
      })

    # `arb worker resume` -> the implementer reports done.
    run_author(task, meta(repo, task, branch, [@reviewer, "APPROVE"]), :succeeded)

    rows = review_rows(task.id)

    assert [%{verdict: :request_changes}, %{verdict: :approve}] = rows,
           "expected a second reviewer round on the new head, got #{inspect(Enum.map(rows, & &1.verdict))}"

    assert merge_commit_count(repo) == 1
  end
end
