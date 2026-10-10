defmodule Arbiter.Board.FastLaneTest do
  @moduledoc """
  bd-741sid (ticket lifecycle 4/13), acceptance 7: the fast lane.

  A CI fix pass on a ticket returning from Merging is an ordinary run, and a
  Merging ticket holds no slot — so at a full cap the pass waits for one. It
  waits in the scheduler's fast lane, and when a slot frees it starts ahead of
  every Ready ticket.
  """

  # async: false — flips app env and runs a real pass worker under the global
  # supervisor.
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  setup do
    tmp = Path.join(System.tmp_dir!(), "fl-#{System.unique_integer([:positive])}")
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
    put_app_env(:arbiter, :repo_paths, %{"fl/repo" => repo})
    # max_concurrent = 1.
    put_local_cap(1)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "fl-#{System.unique_integer([:positive])}", prefix: "fl"})

    %{ws: ws, repo: repo}
  end

  defp ticket(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- ok"})
    Ash.update!(issue, %{}, action: :promote)
  end

  defp stop_run(task_id) do
    case Worker.whereis(task_id) do
      nil -> :ok
      pid -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
    end
  end

  test "a ticket returning from Merging starts before a Ready ticket when the slot frees",
       %{ws: ws, repo: repo} do
    # The one slot is held by a ticket In progress.
    holder = ws |> ticket("holding the slot") |> Ash.update!(%{}, action: :start)

    # A ticket whose PR went red: Merging, holding no slot.
    returning =
      ws
      |> ticket("returning from Merging")
      |> Ash.update!(%{}, action: :start)
      |> Ash.update!(%{pr_ref: "#91"}, action: :open_pr)

    {_, 0} = System.cmd("git", ["-C", repo, "branch", BranchNamer.derive(returning)])
    on_exit(fn -> stop_run(returning.id) end)

    # A Ready ticket, queued first in line for a slot.
    ready = ticket(ws, "ready and waiting")
    assert ready.state == :queued

    test_pid = self()

    {:ok, autopilot} =
      Autopilot.start_link(
        name: nil,
        paused: false,
        interval_ms: :never,
        topics: [],
        follow_up: false,
        dispatch: fn id ->
          send(test_pid, {:ready_dispatched, id})
          {:error, :not_in_this_test}
        end
      )

    # Its Watchdog asks for a fix pass; the cap is full, so it waits.
    assert {:ok, %{deferred: true}} =
             FixPassDispatcher.dispatch(%{
               task_id: returning.id,
               workspace_id: ws.id,
               repo: "fl/repo",
               checks: [],
               start_claude: false,
               pr_status: fn -> {:ok, %{status: :open, pipeline: :failed}} end,
               defer_resume: &Autopilot.defer_resume(autopilot, &1, &2, &3)
             })

    assert Ash.get!(Issue, returning.id).state == :merging
    assert Autopilot.status(autopilot).deferred_resumes == [returning.id]
    assert Worker.whereis(returning.id) == nil

    # While the slot is held, nothing moves.
    assert :idle = Autopilot.tick(autopilot)
    refute_received {:ready_dispatched, _}

    # The slot frees.
    Ash.update!(Ash.get!(Issue, holder.id), %{}, action: :close)

    # The returning ticket's run starts first...
    assert {:resumed, id} = Autopilot.tick(autopilot, 10_000)
    assert id == returning.id

    back = Ash.get!(Issue, returning.id)
    assert back.state == :active
    assert %{meta: %{role: :fix_pass}} = Worker.state(Worker.whereis(returning.id))

    # ...and it holds the slot, so the Ready ticket is still waiting.
    assert :idle = Autopilot.tick(autopilot)
    refute_received {:ready_dispatched, _}
    assert Ash.get!(Issue, ready.id).state == :queued
  end
end
