defmodule Arbiter.Workflows.MergeQueue.ConflictPassRemoteTest do
  @moduledoc """
  bd-bg87oz — a conflict pass placed on a node (`worker.placement`), from the
  primary's side: where it is decided, what the node is seeded with, how the
  pass's result is pushed and how it is judged. The node itself is the `:nodes`
  row handed to placement and the agent's work is git commands in the pass's home
  clone (what a collected checkout leaves there); the node half (the real agent,
  the seed bundle over HTTP, the quarantine) is `ArbiterWeb.RemotePassTest`.

  Real git: a repo, a bare `origin`, and a third party who pushes behind the repo's
  back.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Nodes.Placement
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Watchdog, Worktree}
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.MergeQueue.ConflictResolver

  setup do
    tmp = Path.join(System.tmp_dir!(), "cpr-#{System.unique_integer([:positive])}")
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

    {:ok, ws} = workspace("prefer_remote")
    issue = conflicting_ticket(ws, repo)
    inert_lane!(issue)

    {:ok, ws: ws, repo: repo, issue: issue, branch: BranchNamer.derive(issue), tmp: tmp}
  end

  describe "placement" do
    test "a podman workspace that prefers remote places the pass on a node with room", ctx do
      %{worker_pid: pid} = pass!(ctx, nodes: [node_row()])

      assert %{meta: %{placed_node_id: "node-a", conflict_host_push: true}} = Worker.state(pid)
      # The slot the dispatch reserved is given back once the worker is registered.
      assert Registry.lookup(Placement.Registry, ctx.issue.id) == []
    end

    test "no node with room runs the pass on the primary under prefer_remote", ctx do
      %{worker_pid: pid} = pass!(ctx, nodes: [node_row(live: 2, max: 2)])

      refute Map.has_key?(Worker.state(pid).meta, :placed_node_id)
    end

    test "a local_only workspace never reads the nodes", ctx do
      ctx = placement!(ctx, "local_only")

      %{worker_pid: pid} = pass!(ctx, nodes: fn -> flunk("nodes read for a local_only pass") end)

      refute Map.has_key?(Worker.state(pid).meta, :placed_node_id)
    end

    test "remote_only with no node free holds the pass; the ticket stays in Merging", ctx do
      ctx = placement!(ctx, "remote_only")

      assert {:error, {:no_node_capacity, %{mode: :remote_only}}} =
               resolve(ctx, nodes: [node_row(live: 2, max: 2)])

      assert Ash.get!(Issue, ctx.issue.id).state == :merging
      assert Worker.whereis(ctx.issue.id) == nil
    end

    test "a home clone with uncommitted work stays on the primary", ctx do
      # A first (local) pass leaves its clone dirty.
      %{worker_pid: first, worktree_path: wt} = pass!(placement!(ctx, "local_only"), [])
      :ok = Worker.stop(first, :normal)
      File.write!(Path.join(wt, "scratch.txt"), "work in progress\n")
      ctx = placement!(ctx, "prefer_remote")

      %{worker_pid: pid} = pass!(ctx, nodes: [node_row()])

      refute Map.has_key?(Worker.state(pid).meta, :placed_node_id)
    end
  end

  describe "seeding (the stale-ref bugs, bd-cccm1k / bd-4axlg0)" do
    test "the node is seeded with the branch at its current origin head and origin/<target> at the forge tip",
         ctx do
      {branch_head, main_tip} = third_party_push!(ctx)
      # The repo has not fetched either: both of its refs are stale.
      refute Worktree.remote_head(ctx.repo, ctx.branch) == nil
      {stale_main, 0} = git(ctx.repo, ["rev-parse", "refs/remotes/origin/main"])
      refute String.trim(stale_main) == main_tip

      %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])

      assert git_out(wt, ["rev-parse", "refs/heads/" <> ctx.branch]) == branch_head
      assert git_out(wt, ["rev-parse", "refs/remotes/origin/main"]) == main_tip
      # The lease the host push is pinned to is the head seeded from, not a stale ref.
      assert %{meta: %{conflict_start_head: ^branch_head}} = Worker.state(pid)
    end

    test "a clone that diverged from the forge cannot be seeded: it runs on the primary", ctx do
      %{worker_pid: first, worktree_path: wt} = pass!(placement!(ctx, "local_only"), [])
      :ok = Worker.stop(first, :normal)
      configure!(wt)
      :ok = commit!(wt, "mine.txt", "mine\n", "an unpushed commit")
      _ = third_party_push!(ctx)
      ctx = placement!(ctx, "prefer_remote")

      %{worker_pid: pid} = pass!(ctx, nodes: [node_row()])

      refute Map.has_key?(Worker.state(pid).meta, :placed_node_id)
      assert Registry.lookup(Placement.Registry, ctx.issue.id) == []
    end

    test "a diverged clone under remote_only is an error, nothing is run", ctx do
      %{worker_pid: first, worktree_path: wt} = pass!(placement!(ctx, "local_only"), [])
      :ok = Worker.stop(first, :normal)
      configure!(wt)
      :ok = commit!(wt, "mine.txt", "mine\n", "an unpushed commit")
      _ = third_party_push!(ctx)
      ctx = placement!(ctx, "remote_only")

      assert {:error, {:remote_seed_failed, {:seed_diverged, _, _}}} =
               resolve(ctx, nodes: [node_row()])

      assert Registry.lookup(Placement.Registry, ctx.issue.id) == []
    end
  end

  describe "the host push and the pass's verdict" do
    # The agent's side, as a collected checkout leaves it in the home clone: rebased
    # onto the (seeded) origin/main with the conflict resolved.
    defp resolve_in!(wt) do
      configure!(wt)
      {_, status} = git(wt, ["rebase", "origin/main"])
      assert status != 0
      File.write!(Path.join(wt, "README.md"), "resolved\n")
      {_, 0} = git(wt, ["add", "README.md"])
      {_, 0} = git(wt, ["-c", "core.editor=true", "rebase", "--continue"])
      :ok
    end

    test "the primary pushes the pass's commits with the lease pinned to the seeded head", ctx do
      %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])
      seeded = remote_head(ctx.repo, ctx.branch)
      :ok = resolve_in!(wt)
      assert remote_head(ctx.repo, ctx.branch) == seeded

      done!(pid)

      assert conflict_run!(ctx.issue.id).outcome == :succeeded
      refute remote_head(ctx.repo, ctx.branch) == seeded
      assert Ash.get!(Issue, ctx.issue.id).state == :merging
    end

    test "a third party's push after seeding makes the lease refuse; nothing is clobbered",
         ctx do
      %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])
      :ok = resolve_in!(wt)

      # Someone pushes to the PR branch while the pass is running on the node.
      {intruder, _main} = third_party_push!(ctx, tip_on_main?: false)

      done!(pid)

      assert %{state: :finished, outcome: :failed} = Worker.state(pid)
      assert conflict_run!(ctx.issue.id).failure_reason =~ "push_failed"
      assert remote_head(ctx.repo, ctx.branch) == intruder
    end

    test "the success criterion is the local one: a pushed head that still conflicts with the target fails",
         ctx do
      %{worker_pid: pid, worktree_path: wt} = pass!(ctx, nodes: [node_row()])
      # The pass resolves the conflict against the seeded main...
      :ok = resolve_in!(wt)
      # ...but main moves on after the seed, into the very lines it resolved.
      {_, main_tip} = main_conflicts_again!(ctx)

      done!(pid)

      assert %{state: :finished, outcome: :failed} = Worker.state(pid)
      run = conflict_run!(ctx.issue.id)
      assert run.failure_reason =~ "conflict_unresolved"
      assert run.failure_reason =~ "still conflicts"
      assert run.failure_summary =~ String.slice(main_tip, 0, 8)
    end

    test "a pass that signals done without a push is unresolved, remote or not", ctx do
      %{worker_pid: pid} = pass!(ctx, nodes: [node_row()])

      done!(pid)

      assert %{state: :finished, outcome: :failed} = Worker.state(pid)
      assert conflict_run!(ctx.issue.id).failure_reason =~ "without pushing"
    end
  end

  # ---- fixtures -------------------------------------------------------------

  defp workspace(placement) do
    Ash.create(Workspace, %{
      name: "cpr-ws-#{System.unique_integer([:positive])}",
      prefix: "cpr#{System.unique_integer([:positive])}",
      config: %{
        "worker" => %{"placement" => placement},
        "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
      }
    })
  end

  # The pass reads its workspace off the ticket, so a mode change is made on the
  # workspace itself.
  defp placement!(ctx, mode) do
    config = %{
      "worker" => %{"placement" => mode},
      "agent" => %{"security" => %{"sandbox" => %{"backend" => "podman"}}}
    }

    %{ctx | ws: Ash.update!(ctx.ws, %{config: config}, action: :update)}
  end

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

  defp resolve(ctx, opts) do
    placement = [remote_available?: true] ++ Keyword.take(opts, [:nodes])

    ConflictResolver.resolve(%{
      task_id: ctx.issue.id,
      workspace_id: ctx.ws.id,
      repo_path: ctx.repo,
      repo: "test/repo",
      start_claude: false,
      placement_opts: placement,
      slot_admitted: true
    })
  end

  defp pass!(ctx, opts) do
    {:ok, %{worker_pid: pid} = info} = resolve(ctx, opts)
    on_exit(fn -> stop_quietly(pid) end)
    info
  end

  # A ticket Merging with PR #77 whose branch conflicts with main on README.md.
  defp conflicting_ticket(ws, repo) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "conflicts", workspace_id: ws.id, acceptance: "- works"})

    branch = BranchNamer.derive(issue)
    {_, 0} = git(repo, ["checkout", "-q", "-b", branch])
    :ok = commit!(repo, "README.md", "branch side\n", "branch edit")
    {_, 0} = git(repo, ["push", "-q", "origin", branch])
    {_, 0} = git(repo, ["checkout", "-q", "main"])
    :ok = commit!(repo, "README.md", "main side\n", "main edit")
    {_, 0} = git(repo, ["push", "-q", "origin", "main"])

    issue
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{pr_ref: "#77"}, action: :open_pr)
  end

  # Someone else pushes a commit to the PR branch and (unless told not to) one to main,
  # neither of which the repo has fetched.
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

  # main moves again, rewriting the line the pass resolved.
  defp main_conflicts_again!(ctx) do
    other = Path.join(ctx.tmp, "again-#{System.unique_integer([:positive])}")
    {_, 0} = System.cmd("git", ["clone", "-q", Path.join(ctx.tmp, "remote.git"), other])
    configure!(other)
    :ok = commit!(other, "README.md", "main moved again\n", "main rewrites the line")
    {_, 0} = git(other, ["push", "-q", "origin", "main"])
    {nil, git_out(other, ["rev-parse", "HEAD"])}
  end

  defp done!(pid) do
    ref = Process.monitor(pid)
    send(pid, {:__claude_session_done__, "sentinel"})
    _ = :sys.get_state(pid)
    receive do: ({:DOWN, ^ref, :process, ^pid, _} -> :ok), after: (0 -> :ok)
  catch
    :exit, _ -> :ok
  end

  defp conflict_run!(task_id) do
    [run] =
      Run
      |> Ash.Query.filter(task_id == ^task_id and kind == :conflict)
      |> Ash.Query.sort(started_at: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!()

    run
  end

  defp remote_head(repo, branch), do: Worktree.remote_head(repo, branch)

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
