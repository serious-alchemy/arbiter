defmodule Arbiter.Workflows.MergeQueue.FixPassRemoteTest do
  @moduledoc """
  bd-bg87oz — a merge-queue CI fix pass placed on a node, from the primary's side:
  where it is decided, what the node is seeded with, and how its commits are
  pushed. The node is the `:nodes` row handed to placement; the agent's work is a
  commit in the pass's home clone (what a collected checkout leaves there). The
  node half is `ArbiterWeb.RemotePassTest`.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Nodes.Placement
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Watchdog, Worktree}
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  setup do
    tmp = Path.join(System.tmp_dir!(), "fpr-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    remote = Path.join(tmp, "remote.git")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    configure!(repo)
    :ok = commit!(repo, "README.md", "hello\n", "i")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(repo, ["remote", "add", "origin", remote])
    {_, 0} = git(repo, ["push", "-q", "origin", "main"])

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "fpr-ws-#{System.unique_integer([:positive])}",
        prefix: "fpr#{System.unique_integer([:positive])}",
        config: %{
          "worker" => %{"placement" => "prefer_remote"},
          "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
        }
      })

    issue = failing_ticket(ws, repo)
    inert_lane!(issue)

    {:ok, ws: ws, repo: repo, issue: issue, branch: BranchNamer.derive(issue), tmp: tmp}
  end

  test "a fix pass is placed on a node with room and its slot is given back", ctx do
    %{worker_pid: pid} = pass!(ctx, nodes: [node_row()])

    assert %{meta: %{placed_node_id: "node-a", role: :fix_pass}} = Worker.state(pid)
    assert Registry.lookup(Placement.Registry, ctx.issue.id) == []
  end

  test "it stays on the primary when no node has room", ctx do
    %{worker_pid: pid} = pass!(ctx, nodes: [node_row(live: 2, max: 2)])

    refute Map.has_key?(Worker.state(pid).meta, :placed_node_id)
  end

  test "the node is seeded with the branch at its current origin head and origin/<target> at the forge tip",
       ctx do
    {branch_head, main_tip} = third_party_push!(ctx)
    {stale_main, 0} = git(ctx.repo, ["rev-parse", "refs/remotes/origin/main"])
    refute String.trim(stale_main) == main_tip

    %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])

    assert git_out(wt, ["rev-parse", "refs/heads/" <> ctx.branch]) == branch_head
    assert git_out(wt, ["rev-parse", "refs/remotes/origin/main"]) == main_tip
    assert %{meta: %{fix_pass_start_head: ^branch_head}} = Worker.state(pid)
  end

  test "the primary pushes the pass's commit, pinned to the head it was seeded from", ctx do
    %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])
    seeded = Worktree.remote_head(ctx.repo, ctx.branch)
    configure!(wt)
    :ok = commit!(wt, "fix.txt", "fixed\n", "the fix")
    fix = git_out(wt, ["rev-parse", "HEAD"])

    done!(pid)

    assert fix_run!(ctx.issue.id).outcome == :succeeded
    refute seeded == fix
    assert Worktree.remote_head(ctx.repo, ctx.branch) == fix
  end

  test "a pass that rewrote its branch is pushed with the lease, a rebase is not 'diverged'",
       ctx do
    %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])
    configure!(wt)
    # The node amended the commit it was seeded with.
    {_, 0} = git(wt, ["commit", "-q", "--amend", "-m", "branch edit, reworded"])
    rewritten = git_out(wt, ["rev-parse", "HEAD"])

    done!(pid)

    assert fix_run!(ctx.issue.id).outcome == :succeeded
    assert Worktree.remote_head(ctx.repo, ctx.branch) == rewritten
  end

  test "a third party's push after seeding makes the lease refuse and nothing is clobbered",
       ctx do
    %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])
    configure!(wt)
    # The pass amended (a rewrite), so a plain push would be rejected anyway; with the
    # lease pinned to the seeded head it is the intruder's commit that is protected.
    {_, 0} = git(wt, ["commit", "-q", "--amend", "-m", "reworded"])
    {intruder, _} = third_party_push!(ctx, tip_on_main?: false)

    done!(pid)

    assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    assert fix_run!(ctx.issue.id).failure_reason =~ "push_failed"
    assert Worktree.remote_head(ctx.repo, ctx.branch) == intruder
  end

  # ---- fixtures -------------------------------------------------------------

  defp node_row(attrs \\ []) do
    Map.merge(
      %{
        id: "node-a",
        name: "a",
        state: :online,
        health: :ready,
        labels: [],
        workspace_ids: [],
        live: 0,
        max: 2
      },
      Map.new(attrs)
    )
  end

  defp pass!(ctx, opts) do
    placement = [remote_available?: true] ++ Keyword.take(opts, [:nodes])

    {:ok, %{worker_pid: pid} = info} =
      FixPassDispatcher.dispatch(%{
        task_id: ctx.issue.id,
        workspace_id: ctx.ws.id,
        repo_path: ctx.repo,
        repo: "test/repo",
        checks: [],
        start_claude: false,
        placement_opts: placement,
        slot_admitted: true,
        pr_status: fn -> {:ok, %{status: :open, pipeline: :failed}} end
      })

    on_exit(fn -> stop_quietly(pid) end)
    info
  end

  # A ticket Merging with PR #77, its branch pushed.
  defp failing_ticket(ws, repo) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "red ci", workspace_id: ws.id, acceptance: "- works"})

    branch = BranchNamer.derive(issue)
    {_, 0} = git(repo, ["checkout", "-q", "-b", branch])
    :ok = commit!(repo, "feature.txt", "feature\n", "branch edit")
    {_, 0} = git(repo, ["push", "-q", "origin", branch])
    {_, 0} = git(repo, ["checkout", "-q", "main"])

    issue
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{pr_ref: "#77"}, action: :open_pr)
  end

  defp third_party_push!(ctx, opts \\ []) do
    other = Path.join(ctx.tmp, "other-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", Path.join(ctx.tmp, "remote.git"), other])
    configure!(other)

    {_, 0} = git(other, ["checkout", "-q", ctx.branch])
    :ok = commit!(other, "third.txt", "third party\n", "third party on the branch")
    {_, 0} = git(other, ["push", "-q", "origin", ctx.branch])
    branch_head = git_out(other, ["rev-parse", "HEAD"])

    main_tip =
      if Keyword.get(opts, :tip_on_main?, true) do
        {_, 0} = git(other, ["checkout", "-q", "main"])
        :ok = commit!(other, "NEWER.md", "newer\n", "main moved")
        {_, 0} = git(other, ["push", "-q", "origin", "main"])
        git_out(other, ["rev-parse", "HEAD"])
      end

    {branch_head, main_tip}
  end

  defp done!(pid) do
    send(pid, {:__claude_session_done__, "sentinel"})
    _ = :sys.get_state(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp fix_run!(task_id) do
    [run] =
      Run
      |> Ash.Query.filter(task_id == ^task_id and kind == :fix_pass)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()

    run
  end

  defp inert_lane!(issue) do
    lane = PullRequest.lane(adapter: StubMerger, interval_ms: 60_000, initial_delay_ms: 60_000)
    Ash.update!(Ash.get!(Issue, issue.id), %{merge_watch: lane}, action: :record_merge_watch)

    on_exit(fn ->
      case Watchdog.whereis(issue.id) do
        nil -> :ok
        pid -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, pid)
      end
    end)
  end

  defp git(path, args), do: System.cmd("git", ["-C", path | args], stderr_to_stdout: true)

  defp git_out(path, args) do
    {out, 0} = git(path, args)
    String.trim(out)
  end

  defp configure!(path) do
    {_, 0} = git(path, ["config", "user.email", "t@e.com"])
    {_, 0} = git(path, ["config", "user.name", "T"])
    {_, 0} = git(path, ["config", "commit.gpgsign", "false"])
    :ok
  end

  defp commit!(path, file, content, msg) do
    File.write!(Path.join(path, file), content)
    {_, 0} = git(path, ["add", file])
    {_, 0} = git(path, ["commit", "-q", "-m", msg])
    :ok
  end

  defp stop_quietly(pid),
    do: Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
end
