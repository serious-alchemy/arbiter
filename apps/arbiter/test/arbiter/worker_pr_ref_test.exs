defmodule Arbiter.WorkerPrRefTest do
  @moduledoc """
  bd-7b46wd: when the worker opens its own PR/MR (the worker finished and the
  branch is integrated through the configured merger), the opened ref must be
  persisted onto the task's `pr_ref`.

  This is the single signal the workspace MergeQueue reads to ADOPT an already-open
  PR (`MergeQueue.existing_mr_ref/1`) instead of opening a duplicate. Without it
  the Watchdog-merged PR is invisible to the MergeQueue: it falls through to
  `open_mr_for/3`, fails opening a second PR on the already-merged branch, and
  the task is never auto-closed — exactly the recurring silent-stall the task
  describes.
  """

  # DataCase (async: false → shared sandbox) so the worker process started under
  # the DynamicSupervisor reaches the same DB connection, and StubMerger is a
  # singleton named Agent.
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Workers.Run
  alias Arbiter.Test.StubMerger

  # Park the ticket's Watchdog far in the future so it doesn't merge (and close
  # the task) while we assert on the recorded pr_ref.
  @parked %{
    adapter: StubMerger,
    workspace: nil,
    interval_ms: 1_000_000,
    initial_delay_ms: 1_000_000,
    max_polls: :infinity
  }

  setup do
    StubMerger.reset()
    {:ok, ws} = Ash.create(Workspace, %{name: "pr-ref-ws", prefix: "pr"})
    {:ok, task} = Ash.create(Issue, %{title: "record my pr_ref", workspace_id: ws.id})
    put_state!(task, :active)
    on_exit(fn -> stop_watchdog(task.id) end)
    {:ok, ws: ws, task: task}
  end

  defp stop_watchdog(task_id) do
    case Watchdog.whereis(task_id) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  test "open_mr records the opened ref onto the task's pr_ref", %{ws: ws, task: task} do
    StubMerger.next_open_ref("#1234")

    {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)

    :ok = Worker.advance(worker_pid, :running)
    ref = Process.monitor(worker_pid)

    assert {:ok, "#1234"} =
             Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

    # The task now carries the PR ref so the MergeQueue adopts it instead of
    # opening a duplicate.
    {:ok, reloaded} = Ash.get(Issue, task.id)
    assert reloaded.pr_ref == "#1234"
    # The task is not closed yet: the run has ended (bd-741sid) and the
    # ticket's Watchdog watches the PR.
    assert reloaded.state == :merging
    assert_receive {:DOWN, ^ref, :process, ^worker_pid, :normal}, 1_000
    assert Watchdog.alive?(task.id)
  end

  test "open_mr also records the ref onto this run's durable Workers.Run row (bd-6h4ia3)", %{
    ws: ws,
    task: task
  } do
    StubMerger.next_open_ref("#5678")

    {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
    on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)

    :ok = Worker.advance(worker_pid, :running)

    assert {:ok, "#5678"} =
             Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

    [run] =
      Run
      |> Ash.Query.filter(task_id == ^task.id)
      |> Ash.read!()

    assert run.mr_ref == "#5678"
    assert run.merger_url == "https://stub.example/mr/#5678"
  end

  # bd-842qio (ticket lifecycle 1/13, AC7): the PR-opened path is the
  # `open_pr` transition.
  describe "the ticket's lifecycle state" do
    test "opening the PR moves an active ticket to :merging", %{ws: ws, task: task} do
      assert Ash.get!(Issue, task.id).state == :active
      StubMerger.next_open_ref("#4321")

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
      on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)
      :ok = Worker.advance(worker_pid, :running)

      assert {:ok, "#4321"} = Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

      reloaded = Ash.get!(Issue, task.id)

      assert {reloaded.state, reloaded.pr_ref} == {:merging, "#4321"}

      assert :open_pr in version_actions(task.id)
    end

    test "re-adopting the PR on a ticket already :merging keeps it there and records the ref",
         %{ws: ws, task: task} do
      {:ok, _} = Issue |> Ash.get!(task.id) |> Ash.update(%{pr_ref: "#8765"}, action: :open_pr)
      StubMerger.next_open_ref("#8765")

      {:ok, worker_pid} = Worker.start(task_id: task.id, repo: "arbiter", workspace_id: ws.id)
      on_exit(fn -> if Process.alive?(worker_pid), do: GenServer.stop(worker_pid, :normal) end)
      :ok = Worker.advance(worker_pid, :running)

      assert {:ok, "#8765"} = Worker.open_mr(worker_pid, "bd-branch", "title", "body", @parked)

      reloaded = Ash.get!(Issue, task.id)
      assert {reloaded.state, reloaded.pr_ref} == {:merging, "#8765"}
    end
  end

  defp version_actions(issue_id) do
    Issue.Version
    |> Ash.Query.filter(version_source_id == ^issue_id)
    |> Ash.read!()
    |> Enum.map(& &1.version_action_name)
  end
end
