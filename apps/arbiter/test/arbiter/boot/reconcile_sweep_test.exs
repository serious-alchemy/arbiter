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
  alias Arbiter.Workers.Run

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

  test "a non-primary instance skips recovery as it skips the Reconciler" do
    test = self()
    recovery = fn opts -> send(test, {:recovery_opts, opts}) && {:ok, :skipped} end

    ReconcileSweep.steps(Keyword.put(sweep_opts(recovery), :primary?, false))
    assert_received {:recovery_opts, [primary?: false]}
  end
end
