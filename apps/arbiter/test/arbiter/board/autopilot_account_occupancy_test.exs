defmodule Arbiter.Board.AutopilotAccountOccupancyTest do
  @moduledoc """
  A provider account's `max_concurrent` is the operator's quota-pacing lever,
  and it must hold across a restart (bd-35gvrj, #169).

  The 2026-10-01 incident: `claude:default` at `max_concurrent=2` with two
  workers running. The server restarted; the boot reconciler resumed both from
  their preserved worktrees, but Autopilot planned in the gap before the
  resumes registered, saw two `:active` tickets and **zero** live workers on
  the account, and dispatched a third.

  Everything here is real except the agent CLI (a sleeping stub) and the
  Autopilot's dispatch (a message to the test): real git repo, real
  `Dispatch.resume/2` workers, real `Snapshot.load/1`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Boot.ResumeGate
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Workers.Reconciler

  @repo ResumeSlotFixture.repo()

  setup do
    ResumeSlotFixture.setup_repo!()
    # The machine cap is not what is under test; the account cap is.
    ResumeSlotFixture.put_local_cap(5)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "occupancy-#{System.unique_integer([:positive])}",
        prefix: "occ#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "occ-#{System.unique_integer([:positive])}",
        max_concurrent: 2
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    on_exit(fn -> ResumeGate.open() end)
    %{ws: ws, account: account}
  end

  # An In-progress ticket whose worker the "restart" then took away: the
  # ticket stays `:active`, the worktree is preserved, no process is left.
  defp interrupted!(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    {:ok, first} = Dispatch.dispatch(issue.id, force: true, repo: @repo, start_driver: false)
    ref = Process.monitor(first.worker_pid)
    :ok = Worker.stop(issue.id, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert Ash.get!(Issue, issue.id).state == :active
    issue
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- occupancy fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  defp start_autopilot do
    test = self()

    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        interval_ms: :never,
        paused: false,
        topics: [],
        follow_up: false,
        snapshot: &Snapshot.load/1,
        dispatch: fn id ->
          send(test, {:dispatched, id})
          {:ok, %{task_id: id}}
        end
      )

    pid
  end

  test "a boot that resumes two runs at an account cap of 2 dispatches nothing new", ctx do
    %{ws: ws, account: account} = ctx
    a = interrupted!(ws, "interrupted A")
    b = interrupted!(ws, "interrupted B")
    ready = ready!(ws, "fresh ready card")
    autopilot = start_autopilot()

    assert Concurrency.live_count(account) == 0

    # What `Arbiter.Application` does at start, ahead of Autopilot.
    ResumeGate.close()
    test = self()
    release = make_ref()

    # The boot: the reconciler sweep is mid-flight when Autopilot plans.
    boot =
      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, test, self())

        ResumeGate.sweep(fn ->
          send(test, :sweep_started)

          receive do
            ^release -> :ok
          end

          Reconciler.reconcile_resumable_tasks(primary?: true)
        end)
      end)

    assert_receive :sweep_started, 5_000

    # The race window: tickets are `:active`, nothing has registered yet.
    _ = Autopilot.tick(autopilot, 10_000)
    refute_received {:dispatched, _}

    send(boot.pid, release)
    assert {:ok, %{resumed: 2}} = Task.await(boot, 30_000)

    # Both resumes registered on the account...
    assert Concurrency.live_count(account) == 2
    assert Worker.whereis(a.id) && Worker.whereis(b.id)

    # ...and the account is full, so the Ready card still waits.
    _ = Autopilot.tick(autopilot, 10_000)
    ready_id = ready.id
    refute_received {:dispatched, ^ready_id}
  end

  test "`arb worker resume` of an In-progress run is counted on the account", ctx do
    %{ws: ws, account: account} = ctx
    a = interrupted!(ws, "interrupted A")

    assert Concurrency.live_count(account) == 0
    assert {:ok, %{worker_pid: pid}} = Dispatch.resume(a.id, start_driver: false)
    assert Process.alive?(pid)
    assert Concurrency.live_count(account) == 1
  end

  test "a resume that has stopped its prior worker but not yet registered holds the board", ctx do
    %{ws: ws, account: account} = ctx
    a = interrupted!(ws, "interrupted A")
    b = interrupted!(ws, "interrupted B")
    ready = ready!(ws, "fresh ready card")
    assert {:ok, _} = Dispatch.resume(a.id, start_driver: false)
    assert Concurrency.live_count(account) == 1

    autopilot = start_autopilot()
    test = self()

    # `arb worker resume b`, caught between `Dispatch.resume/2` starting and
    # its worker registering — what `Drain.track/3` marks as pending.
    pending =
      Task.async(fn ->
        Arbiter.Board.Drain.track(:dispatch_pending, %{task_id: b.id}, fn ->
          send(test, :pending)

          receive do
            :finish -> :ok
          end
        end)
      end)

    assert_receive :pending, 5_000
    _ = Autopilot.tick(autopilot, 10_000)
    ready_id = ready.id
    refute_received {:dispatched, ^ready_id}

    send(pending.pid, :finish)
    Task.await(pending)
    assert {:ok, _} = Dispatch.resume(b.id, start_driver: false)
    assert Concurrency.live_count(account) == 2
    _ = Autopilot.tick(autopilot, 10_000)
    refute_received {:dispatched, ^ready_id}
  end

  test "resumes over a lowered cap still resume, and nothing new dispatches until below it",
       ctx do
    %{ws: ws, account: account} = ctx
    a = interrupted!(ws, "interrupted A")
    b = interrupted!(ws, "interrupted B")
    ready = ready!(ws, "fresh ready card")

    # The operator lowered the cap while both were running.
    Ash.update!(account, %{max_concurrent: 1})

    # Both still resume: an In-progress ticket is uncapped (stranding work is
    # worse than overshooting a lowered cap).
    assert {:ok, :held} = ResumeSlot.admit(Ash.get!(Issue, a.id), origin: :automatic)
    assert {:ok, %{resumed: 2}} = Reconciler.reconcile_resumable_tasks(primary?: true)
    assert Concurrency.live_count(account) == 2

    autopilot = start_autopilot()
    _ = Autopilot.tick(autopilot, 10_000)
    refute_received {:dispatched, _}

    # One finishes: occupancy 1 == cap 1, still no room.
    stop_and_await(a.id)
    assert Concurrency.live_count(account) == 1
    _ = Autopilot.tick(autopilot, 10_000)
    refute_received {:dispatched, _}

    # The second finishes: below the cap, the Ready card goes.
    stop_and_await(b.id)
    assert Concurrency.live_count(account) == 0
    ready_id = ready.id
    assert {:ok, ^ready_id} = Autopilot.tick(autopilot, 10_000)
    assert_received {:dispatched, ^ready_id}
  end

  defp stop_and_await(task_id) do
    pid = Worker.whereis(task_id)
    ref = Process.monitor(pid)
    :ok = Worker.stop(task_id, :normal)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end
end
