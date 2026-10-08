defmodule Arbiter.Boot.ReconcileSweepTest do
  @moduledoc """
  RW12 ordering tests (`docs/design/remote-workers.md` §10.5): node recovery
  completes before `Workers.Reconciler` marks runs interrupted or resumes
  anything, and before `Boot.ResumeGate` opens; a recovery that is slow, fails or
  finds nothing still lets the sweep finish.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Boot.{ReconcileSweep, ResumeGate}
  alias Arbiter.Nodes
  alias Arbiter.Nodes.Registry
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.{Reconciler, Run}

  import Arbiter.LifecycleFixtures, only: [put_state!: 3]

  defmodule RecordingReconciler do
    @moduledoc false
    def reconcile_orphaned_runs(_), do: note(:orphans)
    def reconcile_shutdown_casualties(_), do: note(:casualties)
    def sweep_worker_scopes(_), do: note(:scopes)
    def reconcile_ci_waits(_), do: note(:ci_waits)
    def reconcile_review_passes(_), do: note(:passes)
    def restarted_ids(_), do: []
    def reconcile_open_pr_tasks(_), do: note(:open_prs)
    def reconcile_resumable_tasks(_), do: note(:resume)

    defp note(step) do
      send(Application.fetch_env!(:arbiter, :sweep_test_pid), {:step, step})
      {:ok, 0}
    end
  end

  # The real Reconciler, with its resume swapped for a message: what the sweep does to
  # rows and tickets is real, only the dispatch is not.
  defmodule ResumeCountingReconciler do
    @moduledoc false
    defdelegate reconcile_orphaned_runs(opts), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_shutdown_casualties(opts), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_ci_waits(opts), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_review_passes(opts), to: Arbiter.Workers.Reconciler
    defdelegate restarted_ids(lists), to: Arbiter.Workers.Reconciler
    defdelegate reconcile_open_pr_tasks(opts), to: Arbiter.Workers.Reconciler

    # Never the real systemd user manager: the sweep would `systemctl --user stop`
    # every live `arb-run-*` scope on the host (bd-8h3h3z). Same sweep, `:cmd` stubbed.
    def sweep_worker_scopes(opts) do
      scope_opts = [systemctl: "systemctl-stub", cmd: fn _bin, _args, _opts -> {"", 0} end]
      Arbiter.Workers.Reconciler.sweep_worker_scopes(Keyword.put(opts, :scope_opts, scope_opts))
    end

    def reconcile_resumable_tasks(opts) do
      test = Application.fetch_env!(:arbiter, :sweep_test_pid)

      resume = fn %Issue{id: id} ->
        send(test, {:resumed, id})
        {:ok, %{task_id: id}}
      end

      Arbiter.Workers.Reconciler.reconcile_resumable_tasks(Keyword.put(opts, :resume_fun, resume))
    end
  end

  @reconcile_steps ~w(orphans casualties scopes ci_waits passes open_prs resume)a

  setup do
    Application.put_env(:arbiter, :sweep_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:arbiter, :sweep_test_pid)
      ResumeGate.open()

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)
  end

  defp sweep_opts(recovery),
    do: [primary?: true, reconciler: RecordingReconciler, recovery: recovery]

  defp drain_steps(acc \\ []) do
    receive do
      {:step, step} -> drain_steps([step | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "no reconcile step runs while recovery is still in flight; all run once it returns" do
    test = self()

    recovery = fn _opts ->
      send(test, {:recovery, :started, self()})

      receive do
        :release -> send(test, {:recovery, :done})
      end

      {:ok, %{}}
    end

    ResumeGate.close()
    sweep = Task.async(fn -> ReconcileSweep.run(sweep_opts(recovery)) end)

    assert_receive {:recovery, :started, recovery_pid}
    # the race: give every reconcile step the chance to run early
    refute_receive {:step, _}, 200
    refute ResumeGate.open?()

    send(recovery_pid, :release)
    assert_receive {:recovery, :done}
    Task.await(sweep)

    assert drain_steps() == @reconcile_steps
    assert ResumeGate.open?()
  end

  test "a recovery that raises or exits does not stop the sweep" do
    for recovery <- [fn _ -> raise "boom" end, fn _ -> exit(:kaboom) end, fn _ -> :garbage end] do
      ReconcileSweep.steps(sweep_opts(recovery))
      assert drain_steps() == @reconcile_steps
    end
  end

  test "the real recovery, with a node that never returns, still lets the sweep finish in budget" do
    {:ok, %{token: t}} = Nodes.mint_join_token([name: "never"], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(t)

    run =
      Ash.create!(Run, %{
        task_id: "bd-sweep-1",
        base_task_id: "bd-sweep-1",
        repo: "trib/repo",
        kind: :implement,
        provider: "claude",
        state: :working,
        node_id: node.id,
        started_at: DateTime.utc_now()
      })

    recovery = fn opts ->
      Nodes.Recovery.await(Keyword.merge(opts, node_timeout_ms: 150, total_timeout_ms: 300))
    end

    started = System.monotonic_time(:millisecond)
    ReconcileSweep.steps(sweep_opts(recovery))
    assert System.monotonic_time(:millisecond) - started < 3_000

    assert drain_steps() == @reconcile_steps
    # recovery ran first and classified the lost node's run; the sweep then found nothing to do
    assert %{outcome: :interrupted, stop_category: "node_lost"} = Ash.get!(Run, run.id)
  end

  defp node_run!(node, task_id, state \\ :working) do
    Ash.create!(Run, %{
      task_id: task_id,
      base_task_id: task_id,
      repo: "trib/repo",
      kind: :implement,
      provider: "claude",
      state: state,
      node_id: node.id,
      started_at: DateTime.utc_now()
    })
  end

  defp active_ticket! do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "sweep-ws-2691",
        prefix: "sw"
      })

    {:ok, issue} = Ash.create(Issue, %{title: "remote work", workspace_id: ws.id})
    put_state!(issue, :active, [])
  end

  defp enroll!(name) do
    {:ok, %{token: t}} = Nodes.mint_join_token([name: name], "operator:test")
    {:ok, %{node: node}} = Nodes.redeem_join_token(t)
    node
  end

  describe "a run that belongs to a node" do
    test "a node that never returns: the run ends interrupted (node_lost) and its ticket is resumed exactly once" do
      issue = active_ticket!()
      run = node_run!(enroll!("never-back"), issue.id)

      recovery = fn opts ->
        Nodes.Recovery.await(Keyword.merge(opts, node_timeout_ms: 150, total_timeout_ms: 300))
      end

      ReconcileSweep.steps(
        primary?: true,
        reconciler: ResumeCountingReconciler,
        recovery: recovery
      )

      issue_id = issue.id
      assert_received {:resumed, ^issue_id}
      refute_received {:resumed, _}

      assert %{state: :finished, outcome: :interrupted, stop_category: "node_lost"} =
               Ash.get!(Run, run.id)
    end

    test "while Recovery has not settled the run, the sweep neither interrupts it nor resumes its ticket" do
      issue = active_ticket!()
      owned = node_run!(enroll!("owned"), issue.id)

      # a Recovery that cannot say what became of the run (it crashed: `await/1` then
      # reports nothing), which is not the same as the run being lost or recovered
      ReconcileSweep.steps(
        primary?: true,
        reconciler: ResumeCountingReconciler,
        recovery: fn _opts -> {:ok, %{}} end
      )

      refute_received {:resumed, _}
      assert %{state: :working, outcome: nil} = Ash.get!(Run, owned.id)
    end

    test "once Recovery has collected it, the run is interrupted for the resume and the ticket resumed once" do
      issue = active_ticket!()
      run = node_run!(enroll!("collected"), issue.id)

      ReconcileSweep.steps(
        primary?: true,
        reconciler: ResumeCountingReconciler,
        recovery: fn _opts -> {:ok, %{run.id => :collected}} end
      )

      issue_id = issue.id
      assert_received {:resumed, ^issue_id}
      refute_received {:resumed, _}

      assert %{state: :finished, outcome: :interrupted, failure_reason: "server restarted"} =
               Ash.get!(Run, run.id)
    end

    test "a run on a node is not mistaken for a local one by the orphan sweep alone" do
      issue = active_ticket!()
      run = node_run!(enroll!("direct"), issue.id)

      assert {:ok, 0} = Reconciler.reconcile_orphaned_runs(primary?: true, skip_run_ids: [run.id])
      assert %{state: :working} = Ash.get!(Run, run.id)
    end
  end

  test "a non-primary instance skips recovery as it skips the Reconciler" do
    test = self()
    recovery = fn opts -> send(test, {:recovery_opts, opts}) && {:ok, :skipped} end

    ReconcileSweep.steps(Keyword.put(sweep_opts(recovery), :primary?, false))
    assert_received {:recovery_opts, [primary?: false]}
  end
end
