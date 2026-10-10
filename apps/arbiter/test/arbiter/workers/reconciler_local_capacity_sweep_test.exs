defmodule Arbiter.Workers.ReconcilerLocalCapacitySweepTest do
  @moduledoc """
  bd-b2iigy: after a primary restart with more resumable runs than the local cap
  allows, the resume sweep resumes at most the cap's worth (counting runs
  already live), highest ticket priority first, and defers the rest to the
  scheduler (`held_for: :local_capacity`). Nothing deferred is lost or resumed
  twice — a remote run Recovery collected included.

  Real tickets, worktrees and workers (`Arbiter.Test.ResumeSlotFixture`); the
  restart is simulated by stopping every worker, which is exactly the state a
  boot finds (ticket In progress, no worker).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Boot.ReconcileSweep
  alias Arbiter.Nodes
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.{ResumeSlotFixture, StubResumeDeferrer}
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.{Reconciler, Run}

  # The real Reconciler for rows and tickets; only the systemd scope sweep is
  # stubbed (it would `systemctl --user stop` every live `arb-run-*` on the host).
  defmodule SweepReconciler do
    @moduledoc false
    defdelegate reconcile_orphaned_runs(opts), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_shutdown_casualties(opts), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_ci_waits(opts), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_review_passes(opts), to: Arbiter.Workers.Reconciler
    defdelegate restarted_ids(lists), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_open_pr_tasks(opts), to: Arbiter.Workers.Reconciler

    def sweep_worker_scopes(opts) do
      scope_opts = [systemctl: "systemctl-stub", cmd: fn _bin, _args, _opts -> {"", 0} end]
      Arbiter.Workers.Reconciler.sweep_worker_scopes(Keyword.put(opts, :scope_opts, scope_opts))
    end

    def reconcile_resumable_tasks(opts) do
      resume = fn issue ->
        Arbiter.Workers.Reconciler.default_resume(issue,
          start_driver: false,
          claude_command: ["sleep", "5"]
        )
      end

      Arbiter.Workers.Reconciler.reconcile_resumable_tasks(Keyword.put(opts, :resume_fun, resume))
    end
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "local-cap-sweep-#{System.unique_integer([:positive])}",
        prefix: "lcs#{System.unique_integer([:positive])}"
      })

    ResumeSlotFixture.setup_repo!()
    # Far from full unless a test caps the primary itself.
    ResumeSlotFixture.put_local_cap(nil)
    StubResumeDeferrer.reset()
    on_exit(fn -> Arbiter.Settings.set_nodes_local_max_workers(nil) end)
    %{ws: ws}
  end

  defp cap!(n), do: {:ok, ^n} = Arbiter.Nodes.set_local_max_workers(n, nil)

  # A mid-flight ticket the restart cut off: In progress, its worker gone.
  defp cut_off!(ws, title, priority) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, priority: priority})

    first = ResumeSlotFixture.park!(issue, nil)
    ref = Process.monitor(first.worker_pid)
    :ok = Worker.stop(first.worker_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert Worker.whereis(issue.id) == nil
    issue
  end

  defp resumed_sweep do
    resume = fn issue ->
      Reconciler.default_resume(issue, start_driver: false, claude_command: ["sleep", "5"])
    end

    Reconciler.reconcile_resumable_tasks(resume_fun: resume)
  end

  test "resumes the cap's worth, P0 first, and defers the rest in priority order", %{ws: ws} do
    p3 = cut_off!(ws, "P3 chore", 3)
    p0 = cut_off!(ws, "P0 outage", 0)
    p2 = cut_off!(ws, "P2 feature", 2)
    p1 = cut_off!(ws, "P1 bug", 1)

    cap!(2)
    assert {:ok, report} = resumed_sweep()

    assert report.resumed == 2
    assert report.deferred == 2
    assert report.escalated == 0
    assert report.restarted == [p0.id, p1.id]

    assert report.not_restarted == [
             %{task_id: p2.id, reason: :deferred},
             %{task_id: p3.id, reason: :deferred}
           ]

    # Exactly the cap's worth is running on the primary.
    assert Worker.whereis(p0.id)
    assert Worker.whereis(p1.id)
    assert Worker.whereis(p2.id) == nil
    assert Worker.whereis(p3.id) == nil

    assert StubResumeDeferrer.deferred_resume_ids() == [p2.id, p3.id]

    for {_id, _kind, opts} <- StubResumeDeferrer.deferrals() do
      assert opts[:held_for] == :local_capacity
      assert opts[:resume_origin] == :automatic
    end
  end

  test "runs already live count against the cap", %{ws: ws} do
    {:ok, running} = Ash.create(Issue, %{title: "already running", workspace_id: ws.id})
    ResumeSlotFixture.admit!(ws, running)
    cut_off = cut_off!(ws, "cut off", 2)
    other = cut_off!(ws, "cut off too", 2)

    cap!(2)
    assert {:ok, %{resumed: 1, deferred: 1}} = resumed_sweep()

    assert Worker.whereis(running.id)
    assert Worker.whereis(cut_off.id)
    assert Worker.whereis(other.id) == nil
    assert StubResumeDeferrer.deferred_resume_ids() == [other.id]
  end

  test "with no override the hardware suggestion is far from full, so nothing is deferred", %{ws: ws} do
    a = cut_off!(ws, "a", 2)
    b = cut_off!(ws, "b", 2)

    assert {:ok, %{resumed: 2, deferred: 0}} = resumed_sweep()
    assert Worker.whereis(a.id) && Worker.whereis(b.id)
    assert StubResumeDeferrer.deferrals() == []
  end

  test "a deferred ticket is neither lost nor double-resumed", %{ws: ws} do
    runner = cut_off!(ws, "first", 1)
    waiting = cut_off!(ws, "waiting", 2)

    cap!(1)
    assert {:ok, %{resumed: 1, deferred: 1}} = resumed_sweep()
    first_pid = Worker.whereis(runner.id)
    assert is_pid(first_pid)

    # The deferred ticket is still In progress, with no worker: held, not lost.
    assert Ash.get!(Issue, waiting.id).state == :active
    assert Worker.whereis(waiting.id) == nil

    # A second sweep (another boot step, a retry) neither double-resumes the
    # running ticket nor double-queues the deferred one.
    assert {:ok, %{resumed: 0, deferred: 1}} = resumed_sweep()
    assert Worker.whereis(runner.id) == first_pid
    assert StubResumeDeferrer.deferred_resume_ids() == [waiting.id]

    # A slot frees; the scheduler's replay resumes it exactly once.
    :ok = Worker.stop(first_pid, :normal)
    replay = [resume_origin: :automatic, slot_admitted: true, start_driver: false]

    assert {:ok, %{worker_pid: pid}} =
             Dispatch.resume(waiting.id, replay ++ [claude_command: ["sleep", "5"]])

    assert Worker.whereis(waiting.id) == pid

    assert {:error, {:worker_active, _}} =
             Dispatch.resume(waiting.id, replay ++ [claude_command: ["sleep", "5"]])
  end

  describe "a remote run Recovery collected" do
    # The boot order: Recovery first, then the Reconciler sweeps.
    test "is deferred like any other when the primary is full, then resumed once", %{ws: ws} do
      {:ok, running} = Ash.create(Issue, %{title: "local runner", workspace_id: ws.id})
      ResumeSlotFixture.admit!(ws, running)
      remote = cut_off!(ws, "was on a node", 1)

      {:ok, %{token: token}} = Nodes.mint_join_token([name: "oryx"], "operator:test")
      {:ok, %{node: node}} = Nodes.redeem_join_token(token)

      run = Ash.read!(Run) |> Enum.filter(&(&1.task_id == remote.id)) |> List.first()

      run =
        run
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:node_id, node.id)
        |> Ash.Changeset.force_change_attribute(:state, :working)
        |> Ash.Changeset.force_change_attribute(:outcome, nil)
        |> Ash.Changeset.force_change_attribute(:completed_at, nil)
        |> Ash.update!()

      cap!(1)

      ReconcileSweep.steps(
        primary?: true,
        reconciler: SweepReconciler,
        recovery: fn _opts -> {:ok, %{run.id => :collected}} end
      )

      assert %{outcome: :interrupted} = Ash.get!(Run, run.id)
      assert Ash.get!(Issue, remote.id).state == :active
      assert Worker.whereis(remote.id) == nil
      assert StubResumeDeferrer.deferred_resume_ids() == [remote.id]

      # Room opens up: the deferred resume is replayed once and runs.
      :ok = Worker.stop(running.id, :normal)

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.resume(remote.id,
                 resume_origin: :automatic,
                 slot_admitted: true,
                 start_driver: false,
                 claude_command: ["sleep", "5"]
               )

      assert Worker.whereis(remote.id) == pid
    end
  end

  test "the sweep with the default resume reports a held ticket as deferred, not escalated",
       %{ws: ws} do
    _ = cut_off!(ws, "only one", 2)
    _ = cut_off!(ws, "and another", 2)
    cap!(0)

    assert {:ok, %{resumed: 0, deferred: 2, escalated: 0}} = resumed_sweep()
  end
end
