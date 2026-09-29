defmodule Arbiter.Worker.ReviewGateTicketVerdictTest.VanishingAuthor do
  @moduledoc """
  An author alive when the ReviewGate starts and gone by the time the gate's
  verdict call runs — stops on the first call it receives, so `report/2`'s
  second (verdict) call deterministically exits `:noproc`.
  """
  use GenServer

  def start, do: GenServer.start(__MODULE__, :ok)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call(_msg, _from, state), do: {:stop, :normal, state}
end

defmodule Arbiter.Worker.ReviewGateTicketVerdictTest do
  @moduledoc """
  bd-741sid (ticket lifecycle 4/13), acceptance 5: the ReviewGate reports to
  the ticket. A verdict whose author run is no longer resident is applied to
  the ticket, and the bd-3wumco late approval — a round rejects, a later round
  approves — still reaches PR open.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker
  alias Arbiter.Worker.{ReviewGate, Watchdog}
  alias Arbiter.Worker.ReviewGateTicketVerdictTest.VanishingAuthor

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)

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

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
  end

  setup do
    StubMerger.reset()
    tmp = Path.join(System.tmp_dir!(), "rgtv-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"rgtv/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{repo: repo}
  end

  defp workspace(config) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rgtv-#{System.unique_integer([:positive])}",
        prefix: "rv",
        config: config
      })

    ws
  end

  defp active_ticket(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "reviewed", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    on_exit(fn -> stop(Watchdog.whereis(task.id)) end)
    task
  end

  defp stop(nil), do: :ok

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
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

  defp main_run(task_id) do
    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^task_id and kind == :implement and role == "base")
    |> Ash.read!()
    |> List.first()
  end

  # An author that finished its work and is waiting on the ReviewGate; the
  # gate is driven by hand (`review_spawn: false`), exactly as it reports.
  defp parked_author(ws, task, meta) do
    meta =
      Map.merge(
        %{
          branch: "feature/rev",
          target_branch: "main",
          review_required: true,
          review_spawn: false
        },
        meta
      )

    {:ok, pid} =
      Worker.start(task_id: task.id, repo: "rgtv/repo", workspace_id: ws.id, meta: meta)

    on_exit(fn -> stop(pid) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(pid)) end)
    pid
  end

  describe "a later round's approval with no author resident (bd-3wumco)" do
    test "the rejected round is overturned and the PR opens", _ctx do
      ws = workspace(%{"review" => %{"required" => true}, "merge" => %{"auto_merge" => false}})
      task = active_ticket(ws)
      StubMerger.next_open_ref("!rg1")

      author =
        parked_author(ws, task, %{
          merger_adapter_override: StubMerger,
          merger_workspace_override: ws,
          watchdog_interval_ms: 20,
          watchdog_initial_delay_ms: 0
        })

      # Round 1 rejects: the author's run ends failed on it...
      :ok =
        Worker.review_gate_verdict(author, {:request_changes, "VERDICT: REQUEST_CHANGES\n- fix"})

      wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(author)) end)
      assert main_run(task.id).outcome == :failed

      # ...and is gone before the next round reports (its fix round stopped it).
      :ok = GenServer.stop(author, :normal)
      assert Worker.whereis(task.id) == nil

      # A later round approves — reported to the ticket, not to a resident author.
      assert :ok = ReviewGate.deliver_verdict(task.id, author, {:approve, "VERDICT: APPROVE"})

      reloaded = ticket(task.id)
      assert reloaded.state == :merging
      assert reloaded.pr_ref == "!rg1"
      assert is_pid(Watchdog.whereis(task.id))
      assert Worker.whereis(task.id) == nil

      assert %{"verdict" => "approve", "reconciled_from" => "review_gate_rejected"} =
               reloaded.review_gate_state

      # The rejected run is the run that produced the approved code: finished
      # and successful now, with the PR on it.
      run = main_run(task.id)
      assert run.outcome == :succeeded
      assert is_nil(run.failure_reason)
      assert run.mr_ref == "!rg1"

      assert Enum.any?(
               Message.inbox(Message.coordinator_ref(), workspace_id: ws.id),
               &(&1.subject =~ "reconciled to APPROVE")
             )
    end

    test "a verdict for a round a newer run superseded is not applied over it", _ctx do
      ws = workspace(%{"review" => %{"required" => true}})
      task = active_ticket(ws)
      {:ok, gone} = VanishingAuthor.start()
      GenServer.stop(gone, :normal)

      {:ok, newer} = Worker.start(task_id: task.id, repo: "rgtv/repo", workspace_id: ws.id)
      on_exit(fn -> stop(newer) end)
      :ok = Worker.advance(newer, :implement)

      assert {:error, {:superseded_by_run, ^newer}} =
               ReviewGate.deliver_verdict(task.id, gone, {:approve, "VERDICT: APPROVE"})

      assert ticket(task.id).state == :active
    end

    test "a rejection with no author resident is recorded on the ticket and escalated", _ctx do
      ws = workspace(%{"review" => %{"required" => true}})
      task = active_ticket(ws)
      {:ok, gone} = VanishingAuthor.start()
      GenServer.stop(gone, :normal)

      assert :ok =
               ReviewGate.deliver_verdict(
                 task.id,
                 gone,
                 {:request_changes, "VERDICT: REQUEST_CHANGES\n- still broken"},
                 %{branch: "feature/rev"}
               )

      reloaded = ticket(task.id)
      assert reloaded.state == :active
      assert %{"verdict" => "request_changes"} = reloaded.review_gate_state

      assert Enum.any?(
               Message.inbox(Message.coordinator_ref(), workspace_id: ws.id),
               &(&1.task_ref == task.id and &1.kind == :escalation)
             )
    end
  end

  describe "a live gate whose author is gone at the report" do
    test "applies the approval to the ticket, which merges (Direct) and closes",
         %{repo: repo} do
      ws = workspace(%{"review" => %{"required" => true}})
      task = active_ticket(ws)
      branch = "feature/rev"
      :ok = seed_feature_branch(repo, branch)

      {:ok, author} = VanishingAuthor.start()
      on_exit(fn -> if Process.alive?(author), do: Process.exit(author, :kill) end)

      {:ok, gate} =
        ReviewGate.start(
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "rgtv/repo",
          worktree_path: repo,
          branch: branch,
          target_branch: "main",
          rounds: 1,
          timeout_ms: 5_000,
          command: [@reviewer, "APPROVE"]
        )

      ref = Process.monitor(gate)
      assert_receive {:DOWN, ^ref, :process, ^gate, _}, 8_000

      refute Process.alive?(author)
      wait_until(fn -> ticket(task.id).state == :closed end)
      assert merge_commit_count(repo) == 1
    end
  end
end
