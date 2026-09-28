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

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Watchdog}
  alias Arbiter.Workflows.MergeQueue.{ConflictResolver, FixPassDispatcher, PassAdmission}

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

  # bd-741sid, review round 1 (finding 3): the pass holds its slot from the
  # moment it is admitted, so the scheduler cannot count the slot free while
  # the pass is provisioned, and a pass that never starts gives it back.
  describe "the slot an admitted pass holds" do
    test "the ticket is In progress before the pass is provisioned", %{ws: ws, repo: repo} do
      issue = merging_ticket(ws, repo)
      me = self()

      assert {:ok, :started} =
               PassAdmission.with_slot(issue, fn ->
                 send(me, {:while_starting, Ash.get!(Issue, issue.id).state})
                 {:ok, :started}
               end)

      assert_received {:while_starting, :active}
      assert Ash.get!(Issue, issue.id).state == :active
    end

    test "a pass that never starts puts the ticket back in Merging", %{ws: ws, repo: repo} do
      issue = merging_ticket(ws, repo)
      inert_lane!(issue)

      assert {:error, {:worktree_failed, _}} =
               FixPassDispatcher.dispatch(%{
                 task_id: issue.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 branch: "no-such-branch",
                 checks: [],
                 start_claude: false
               })

      assert Ash.get!(Issue, issue.id).state == :merging
      assert Worker.whereis(issue.id) == nil
      assert List.last(version_actions(issue.id)) == :open_pr
    end

    test "a pass whose agent cannot start is finished as failed, not left starting on the ticket",
         %{ws: ws, repo: repo} do
      issue = merging_ticket(ws, repo)
      inert_lane!(issue)

      assert {:error, {:claude_start_failed, {:executable_not_found, _}}} =
               FixPassDispatcher.dispatch(%{
                 task_id: issue.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 checks: [],
                 claude_command: ["/nonexistent/arbiter-pass-agent"]
               })

      pid = Worker.whereis(issue.id)
      on_exit(fn -> stop_quietly(pid) end)
      assert %{state: :finished, outcome: :failed} = Worker.state(pid)
      assert Ash.get!(Issue, issue.id).state == :merging
    end

    test "a ticket another run took to work meanwhile keeps its slot", %{ws: ws, repo: repo} do
      issue = merging_ticket(ws, repo)

      assert {:error, :refused} =
               PassAdmission.with_slot(issue, fn ->
                 {:ok, pid} =
                   Worker.start(task_id: issue.id, repo: "test/repo", workspace_id: ws.id)

                 :ok = Worker.advance(pid, :implement)
                 on_exit(fn -> stop_quietly(pid) end)
                 {:error, :refused}
               end)

      assert Ash.get!(Issue, issue.id).state == :active
    end

    test "a ticket already In progress is not sent to Merging when its pass fails",
         %{ws: ws, repo: repo} do
      issue = ws |> merging_ticket(repo) |> Ash.update!(%{}, action: :return_to_work)

      assert {:error, :boom} = PassAdmission.with_slot(issue, fn -> {:error, :boom} end)
      assert Ash.get!(Issue, issue.id).state == :active
    end

    test "a ticket pulled out of the merge queue gets no pass", %{ws: ws, repo: repo} do
      issue = merging_ticket(ws, repo)
      :ok = PullRequest.pull(issue.id)

      assert {:error, :pulled} =
               FixPassDispatcher.dispatch(%{
                 task_id: issue.id,
                 workspace_id: ws.id,
                 repo_path: repo,
                 repo: "test/repo",
                 checks: [],
                 start_claude: false
               })

      assert Ash.get!(Issue, issue.id).state == :merging
      assert Worker.whereis(issue.id) == nil
    end
  end

  # A ticket that goes back to Merging has its Watchdog restarted from the
  # row: give it a lane on the stub forge that never polls in a test's time.
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
