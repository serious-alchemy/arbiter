defmodule Arbiter.Worker.TicketWatchdogTest.NoAgentFixPass do
  @moduledoc """
  The production `FixPassDispatcher`, with the agent switched off
  (`start_claude: false`, its documented test escape) — so a test sees the real
  pass run register and the ticket move, without a paid session.
  """
  @behaviour Arbiter.Workflows.MergeQueue.FixPassDispatcher

  @impl true
  def dispatch(args),
    do:
      Arbiter.Workflows.MergeQueue.FixPassDispatcher.dispatch(Map.put(args, :start_claude, false))
end

defmodule Arbiter.Worker.TicketWatchdogTest.NoAgentConflict do
  @moduledoc "The production `ConflictResolver`, agent off — see `NoAgentFixPass`."
  @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

  alias Arbiter.Workflows.MergeQueue.ConflictResolver

  @impl true
  def resolve(args), do: ConflictResolver.resolve(Map.put(args, :start_claude, false))

  @impl true
  def escalate_unresolved(task_id, ws_id, branch, reason),
    do: ConflictResolver.escalate_unresolved(task_id, ws_id, branch, reason)
end

defmodule Arbiter.Worker.TicketWatchdogTest do
  @moduledoc """
  bd-741sid (ticket lifecycle 4/13): the Watchdog is keyed by the ticket and
  drives the ticket.

    * acceptance 3 — started, keyed and restarted by ticket id: with every
      process for a `:merging` ticket dead, a Watchdog restarted from the row
      alone completes the merge;
    * acceptance 4 — one test per PR outcome, through the merger test adapter;
    * acceptance 9 — the Direct strategy takes a ticket through `:merging` to
      `:closed`.
  """

  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{BranchNamer, Dispatch, Watchdog}
  alias Arbiter.Worker.TicketWatchdogTest.{NoAgentConflict, NoAgentFixPass}

  @fixture Path.expand("../../fixtures/commit_and_done.sh", __DIR__)

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  # A working repo with a bare `origin` behind it (the Direct merger pushes).
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

  setup do
    StubMerger.reset()

    tmp = Path.join(System.tmp_dir!(), "tw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"tw/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo}
  end

  defp workspace(config \\ %{}) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "tw-#{System.unique_integer([:positive])}",
        prefix: "tw",
        config: config
      })

    ws
  end

  # A ticket whose PR is open and on its row — the state a run leaves behind
  # when it opens the PR and exits — with nothing running for it.
  defp merging_ticket(ws, repo, mr_ref, lane_opts, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(
          %{title: "watched", workspace_id: ws.id, issue_type: :feature, acceptance: "- ok"},
          attrs
        )
      )

    {_, 0} = git(["branch", BranchNamer.derive(issue)], repo)

    issue
    |> Ash.update!(%{}, action: :promote)
    |> Ash.update!(%{}, action: :start)

    lane =
      PullRequest.lane(
        Keyword.merge(
          [adapter: StubMerger, repo: "tw/repo", interval_ms: 20, initial_delay_ms: 0],
          lane_opts
        )
      )

    {:ok, merging} = Issue.pr_opened(issue.id, mr_ref, merge_watch: lane)
    assert merging.state == :merging

    on_exit(fn -> stop_watchdog(issue.id) end)
    merging
  end

  defp stop_watchdog(task_id) do
    case Watchdog.whereis(task_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp wait_until(fun, timeout \\ 3_000) do
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

  defp ticket(id), do: Ash.get!(Issue, id)

  defp transitions(task_id) do
    Issue.Version
    |> Ash.Query.filter(version_source_id == ^task_id)
    |> Ash.read!()
    |> Enum.map(& &1.version_action_name)
  end

  defp runs(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.read!()
  end

  defp stop_run(task_id) do
    case Worker.whereis(task_id) do
      nil -> :ok
      pid -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
    end
  end

  describe "restarted from the row alone (acceptance 3)" do
    test "with every process for a Merging ticket dead, a Watchdog restarted from the row completes the merge",
         %{repo: repo} do
      ws = workspace(%{"merge" => %{"auto_merge" => false}})
      task = merging_ticket(ws, repo, "!r1", via_review_gate: true)
      StubMerger.queue_get("!r1", [%{status: :open, approved: false, head_sha: "h1"}])

      assert :ok = Worker.restart_watchdog(task.id)
      wait_until(fn -> StubMerger.get_count("!r1") >= 1 end)

      # Everything for the ticket dies: its Watchdog, and there is no worker.
      # Suspended first, so the kill lands between polls rather than mid-write
      # (a kill mid-query takes the test's one sandbox connection with it).
      wd = Watchdog.whereis(task.id)
      ref = Process.monitor(wd)
      :ok = :sys.suspend(wd)
      Process.exit(wd, :kill)
      assert_receive {:DOWN, ^ref, :process, ^wd, :killed}
      wait_until(fn -> is_nil(Watchdog.whereis(task.id)) end)
      assert Worker.whereis(task.id) == nil
      assert Worker.list_children() |> Enum.filter(&(&1.task_id == task.id)) == []

      # The PR merges while nothing is watching it.
      StubMerger.queue_get("!r1", [%{status: :merged}])

      # restart_watchdog/1 takes the ticket id and needs nothing but the row.
      assert :ok = Worker.restart_watchdog(task.id)
      wait_until(fn -> ticket(task.id).state == :closed end)

      assert ticket(task.id).close_reason == :completed
      wait_until(fn -> is_nil(Watchdog.whereis(task.id)) end)
    end

    test "refuses a second Watchdog for a ticket that already has one", %{repo: repo} do
      ws = workspace()
      task = merging_ticket(ws, repo, "!r2", [])
      StubMerger.queue_get("!r2", [%{status: :open, approved: false}])

      assert :ok = Worker.restart_watchdog(task.id)
      assert {:error, :already_running} = Worker.restart_watchdog(task.id)
    end

    test "a ticket without a PR on its row has nothing to watch", %{repo: _repo} do
      ws = workspace()
      {:ok, issue} = Ash.create(Issue, %{title: "no pr", workspace_id: ws.id})
      assert {:error, :no_mr_ref} = Worker.restart_watchdog(issue.id)
    end
  end

  describe "PR outcomes drive the ticket (acceptance 4)" do
    test "merged → closed", %{repo: repo} do
      task = merging_ticket(workspace(), repo, "!m1", [])
      StubMerger.queue_get("!m1", [%{status: :merged}])

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> ticket(task.id).state == :closed end)
      assert ticket(task.id).close_reason == :completed
    end

    test "merged → verifying when the ticket is verify_after_deploy", %{repo: repo} do
      task = merging_ticket(workspace(), repo, "!m2", [], %{verify_after_deploy: true})
      StubMerger.queue_get("!m2", [%{status: :merged}])

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> ticket(task.id).state == :verifying end)
    end

    test "CI failed → back to work, with a fix_pass run registered under the ticket id",
         %{repo: repo} do
      task = merging_ticket(workspace(), repo, "!f1", auto_merge: true, via_review_gate: true)
      on_exit(fn -> stop_run(task.id) end)

      StubMerger.set_failing_checks("!f1", [%{name: "mix test", summary: "boom", url: nil}])

      StubMerger.queue_get("!f1", [
        %{
          status: :open,
          approved: true,
          block_reason: :ci_failed,
          pipeline: :failed,
          head_sha: "h"
        }
      ])

      assert :ok = Watchdog.watch(task.id, fix_pass_dispatcher: NoAgentFixPass)

      # The ticket goes back to work as the pass is admitted, before its run
      # registers (`PassAdmission.with_slot/2`), so wait for the run.
      wait_until(fn -> is_pid(Worker.whereis(task.id)) end)
      assert ticket(task.id).state == :active

      pid = Worker.whereis(task.id)
      assert Worker.state(pid).meta.role == :fix_pass
      assert Enum.any?(runs(task.id), &(&1.worker_type == :fix_pass))
    end

    test "conflict → back to work, with a conflict run registered under the ticket id",
         %{repo: repo} do
      task = merging_ticket(workspace(), repo, "!c1", via_review_gate: true)
      on_exit(fn -> stop_run(task.id) end)

      # main moves on after the branch was cut, so there is something to rebase
      # (the resolver's pre-flight skips a branch with zero divergence).
      File.write!(Path.join(repo, "moved.txt"), "main moved\n")
      {_, 0} = git(["add", "moved.txt"], repo)
      {_, 0} = git(["commit", "-q", "-m", "main moved"], repo)
      {_, 0} = git(["push", "-q", "origin", "main"], repo)

      StubMerger.queue_get("!c1", [
        %{status: :open, approved: true, block_reason: :conflict, base_ref: "main"}
      ])

      assert :ok = Watchdog.watch(task.id, conflict_resolver: NoAgentConflict)

      wait_until(fn -> is_pid(Worker.whereis(task.id)) end)
      assert ticket(task.id).state == :active

      pid = Worker.whereis(task.id)
      assert Worker.state(pid).meta.role == :conflict_resolver
      assert Enum.any?(runs(task.id), &(&1.worker_type == :conflict))
    end

    test "PR closed → back to work, with the pr_closed cause and a page", %{repo: repo} do
      ws = workspace()
      task = merging_ticket(ws, repo, "!x1", [])
      StubMerger.queue_get("!x1", [%{status: :closed}])

      assert :ok = Watchdog.restart(task.id)

      wait_until(fn -> ticket(task.id).state == :active end)
      assert ticket(task.id).attention_cause == :pr_closed

      assert Enum.any?(
               Message.inbox(Message.coordinator_ref(), workspace_id: ws.id),
               &(&1.task_ref == task.id and &1.subject =~ "PR closed")
             )
    end
  end

  describe "the Direct strategy (acceptance 9)" do
    test "a Direct merge takes the ticket through :merging to :closed", %{repo: repo} do
      ws = workspace()

      {:ok, task} =
        Ash.create(Issue, %{title: "direct", workspace_id: ws.id, issue_type: :feature})

      {:ok, result} =
        Dispatch.dispatch(task.id,
          force: true,
          repo: "tw/repo",
          start_claude: true,
          claude_command: [@fixture],
          interval_ms: 10,
          max_ticks: 200
        )

      on_exit(fn -> stop_run(task.id) end)

      # The run ends when its merge is "opened" — Direct merges right there.
      wait_until(fn -> not Process.alive?(result.worker_pid) end, 5_000)
      wait_until(fn -> ticket(task.id).state == :closed end)

      # Through Merging: the open_pr transition, then the close.
      wait_until(fn -> :close in transitions(task.id) end)
      assert :open_pr in transitions(task.id)
      assert Worker.whereis(task.id) == nil

      {merges, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
      assert String.trim(merges) == "1"
    end
  end
end
