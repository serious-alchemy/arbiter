defmodule Arbiter.Workflows.MergeQueue.PassDispatchLifecycleTest do
  @moduledoc """
  bd-842qio (ticket lifecycle 1/13, AC7): a CI fix pass or a conflict resolver
  dispatched on a `:merging` ticket takes it back to `:active` through the
  `return_to_work` transition.

  Both passes spawn through their production entry points with
  `start_claude: false` (their documented test escape) against a real git repo,
  like `Arbiter.Board.DrainTest`.
  """

  # async: false — spawns workers under the global Arbiter.Worker.Supervisor and
  # flips :worktree_root app env.
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Workflows.MergeQueue.{ConflictResolver, FixPassDispatcher}

  setup do
    tmp = Path.join(System.tmp_dir!(), "pdl-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)

    for args <- [
          ["init", "-q", "-b", "main", repo],
          ["-C", repo, "config", "user.email", "t@e.com"],
          ["-C", repo, "config", "user.name", "T"],
          ["-C", repo, "config", "commit.gpgsign", "false"]
        ] do
      {_, 0} = System.cmd("git", args)
    end

    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pdl-ws-#{System.unique_integer([:positive])}",
        prefix: "pdl#{System.unique_integer([:positive])}"
      })

    {:ok, ws: ws, repo: repo}
  end

  # A ticket with an open PR: promote → start → open_pr, and a branch to pass on.
  defp merging_ticket(ws, repo) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "has a PR", workspace_id: ws.id, acceptance: "- works"})

    {_, 0} = System.cmd("git", ["-C", repo, "branch", BranchNamer.derive(issue)])

    issue
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)
    |> Ash.update!(%{pr_ref: "#77"}, action: :open_pr)
  end

  defp fix_pass!(ws, repo, issue) do
    {:ok, %{worker_pid: pid}} =
      FixPassDispatcher.dispatch(%{
        task_id: issue.id,
        workspace_id: ws.id,
        repo_path: repo,
        repo: "test/repo",
        checks: [],
        start_claude: false
      })

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp conflict_pass!(ws, repo, issue) do
    {:ok, %{worker_pid: pid}} =
      ConflictResolver.resolve(%{
        task_id: issue.id,
        workspace_id: ws.id,
        repo_path: repo,
        repo: "test/repo",
        start_claude: false
      })

    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  test "a CI fix pass on a merging ticket takes it back to :active", %{ws: ws, repo: repo} do
    issue = merging_ticket(ws, repo)
    assert issue.state == :merging

    fix_pass!(ws, repo, issue)

    reloaded = Ash.get!(Issue, issue.id)
    assert {reloaded.state, reloaded.status, reloaded.pr_ref} == {:active, :in_progress, "#77"}
    assert List.last(version_actions(issue.id)) == :return_to_work
  end

  test "a conflict resolver on a merging ticket takes it back to :active", %{ws: ws, repo: repo} do
    issue = merging_ticket(ws, repo)

    conflict_pass!(ws, repo, issue)

    assert Ash.get!(Issue, issue.id).state == :active
    assert List.last(version_actions(issue.id)) == :return_to_work
  end

  test "a pass on a ticket that is not merging still dispatches and writes no transition",
       %{ws: ws, repo: repo} do
    issue = ws |> merging_ticket(repo) |> Ash.update!(%{}, action: :return_to_work)
    assert issue.state == :active
    before = version_actions(issue.id)

    fix_pass!(ws, repo, issue)

    assert Ash.get!(Issue, issue.id).state == :active
    assert version_actions(issue.id) == before
  end

  defp version_actions(issue_id) do
    Issue.Version
    |> Ash.Query.filter(version_source_id == ^issue_id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!()
    |> Enum.map(& &1.version_action_name)
  end

  defp stop_quietly(pid),
    do: Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
end
