defmodule Arbiter.Worker.DispatchAccountAdmissionTest do
  @moduledoc """
  The account cap holds on every path that admits a run (bd-8suxac, #207).

  The 2026-10-01 20:11Z incident: `claude:default` at `max_concurrent=2`, two
  Claude runs live (both `arb worker resume`d), and four more Claude workers
  started in three minutes. The server log blamed nobody in particular
  (`origin=Dispatch.start_worker/3`), but the `dispatch_forced` audit rows named
  them: every one was `dispatched_by: "pr_patrol"` — a PRPatrol follow-up
  forced out of Backlog through `Dispatch.dispatch/2`, which never asked the
  account anything. Autopilot, which does ask, admitted none of them.

  So: the two resumed runs *were* counted (hypothesis 1 is false), a fresh
  dispatch's `provider: nil` row *is* counted against the workspace default
  (hypothesis 2 is false), and a non-board dispatch path bypassed the check
  (hypothesis 3). The first block pins 1 and 2 as regression tests; the rest
  cover the gate every fresh admission now passes, and the reservation that
  makes an admitted dispatch count before its worker registers.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.Concurrency
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.ResumeSlotFixture
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch

  require Ash.Query

  @repo ResumeSlotFixture.repo()

  setup do
    ResumeSlotFixture.setup_repo!()
    # The scheduler cap is for machine load; the account cap is under test.

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "admission-#{System.unique_integer([:positive])}",
        prefix: "adm#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "adm-#{System.unique_integer([:positive])}",
        max_concurrent: 2
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    %{ws: ws, account: account}
  end

  # ---- fixtures -------------------------------------------------------------

  defp backlog!(ws, title) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    issue
  end

  defp ready!(ws, title) do
    {:ok, created} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- admission fixture"})

    {:ok, issue} = Ash.update(created, %{}, action: :promote_to_ready)
    issue
  end

  # An In-progress ticket whose worker has gone: the ticket stays `:active`,
  # its worktree is preserved, no process is left. Its first dispatch is
  # fixture, so it goes over a full account rather than be refused.
  defp interrupted!(ws, title) do
    issue = backlog!(ws, title)

    {:ok, first} =
      Dispatch.dispatch(issue.id,
        force: true,
        force_slot: true,
        repo: @repo,
        start_driver: false
      )

    ref = Process.monitor(first.worker_pid)
    :ok = Worker.stop(issue.id, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    assert Ash.get!(Issue, issue.id).state == :active
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
        dispatch: fn id -> send(test, {:dispatched, id}) && {:ok, %{task_id: id}} end
      )

    pid
  end

  defp refute_admits(ready) do
    autopilot = start_autopilot()
    _ = Autopilot.tick(autopilot, 10_000)
    ready_id = ready.id
    refute_received {:dispatched, ^ready_id}
  end

  defp events(ws, topic) do
    Arbiter.Events.Record
    |> Ash.Query.filter(workspace_id == ^ws.id and topic == ^topic)
    |> Ash.read!()
  end

  # ---- AC1: two live Claude runs fill a max_concurrent=2 account --------------

  describe "two live Claude runs on a max_concurrent=2 account" do
    test "(a) both `arb worker resume`d: Autopilot admits nothing more", ctx do
      %{ws: ws, account: account} = ctx
      a = interrupted!(ws, "resumed A")
      b = interrupted!(ws, "resumed B")
      ready = ready!(ws, "fresh ready card")

      for issue <- [a, b] do
        assert {:ok, %{worker_pid: pid}} =
                 Dispatch.resume(issue.id, start_driver: false, resume_origin: :human)

        assert is_pid(pid)
      end

      assert Concurrency.live_count(account) == 2
      refute_admits(ready)
    end

    test "(b) both `arb worker resume --model`d (the REST session resume): Autopilot admits nothing more",
         ctx do
      %{ws: ws, account: account} = ctx
      a = interrupted!(ws, "resumed A")
      b = interrupted!(ws, "resumed B")
      ready = ready!(ws, "fresh ready card")

      for issue <- [a, b] do
        {:ok, _} =
          Ash.create(UsageEvent, %{
            task_id: issue.id,
            workspace_id: ws.id,
            repo: @repo,
            step: :work,
            provider: "claude",
            session_id: "sess-#{System.unique_integer([:positive])}",
            occurred_at: DateTime.utc_now()
          })

        # What `POST /api/workers/:id/resume` with `model` hands Dispatch.
        assert {:ok, %{worker_pid: pid}} =
                 Dispatch.resume_session(issue.id,
                   model: "opus",
                   resume_origin: :human,
                   slot_override_actor: "api",
                   start_driver: false,
                   preflight: false
                 )

        assert is_pid(pid)
      end

      assert Concurrency.live_count(account) == 2
      refute_admits(ready)
    end

    test "(c) both fresh board dispatches, registered with no provider: Autopilot admits nothing more",
         ctx do
      %{ws: ws, account: account} = ctx
      first = ready!(ws, "board A")
      second = ready!(ws, "board B")
      ready = ready!(ws, "fresh ready card")

      for issue <- [first, second] do
        assert {:ok, %{worker_pid: pid}} =
                 Dispatch.dispatch(issue.id,
                   dispatched_by: "autopilot",
                   repo: @repo,
                   start_driver: false
                 )

        # Hypothesis 2's shape: no provider on the registry row...
        assert %{provider: nil} =
                 Enum.find(
                   Arbiter.Worker.Registry.live_dispatches(),
                   &(&1.pid == pid)
                 )
      end

      # ...which counts against the workspace's default (Claude) account.
      assert Concurrency.live_count(account) == 2
      refute_admits(ready)
    end
  end

  # ---- hypothesis 3: a non-board fresh dispatch ------------------------------

  describe "a fresh dispatch on a full account" do
    setup %{ws: ws} do
      for title <- ["live A", "live B"] do
        issue = backlog!(ws, title)
        {:ok, _} = Dispatch.dispatch(issue.id, force: true, repo: @repo, start_driver: false)
      end

      :ok
    end

    test "a PRPatrol follow-up forced out of Backlog is refused, and nothing starts", ctx do
      %{ws: ws, account: account} = ctx
      follow_up = backlog!(ws, "PR #1: follow-up")

      assert {:error, {:account_at_capacity, info}} =
               Dispatch.dispatch(follow_up.id,
                 force: true,
                 dispatched_by: "pr_patrol",
                 repo: @repo,
                 start_driver: false
               )

      assert info.task_id == follow_up.id
      assert info.cap == 2
      assert length(info.holders) == 2

      assert Worker.whereis(follow_up.id) == nil
      assert Ash.get!(Issue, follow_up.id).state == :backlog
      assert Concurrency.live_count(account) == 2
      # The refusal names the cap and how to override it.
      assert Admission.refusal_message(info) =~ "its cap is 2"
    end

    test "a manual dispatch of a Ready ticket is refused the same way", ctx do
      %{ws: ws} = ctx
      ready = ready!(ws, "manual")

      assert {:error, {:account_at_capacity, _}} =
               Dispatch.dispatch(ready.id, dispatched_by: "mcp", repo: @repo, start_driver: false)

      assert Ash.get!(Issue, ready.id).state == :queued
    end

    test "`force_slot` goes over the cap, and the override is recorded", ctx do
      %{ws: ws, account: account} = ctx
      ready = ready!(ws, "manual over cap")

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.dispatch(ready.id,
                 dispatched_by: "http_api",
                 force_slot: true,
                 slot_override_actor: "api",
                 repo: @repo,
                 start_driver: false
               )

      assert is_pid(pid)
      assert Concurrency.live_count(account) == 3

      assert [event] = events(ws, "account_cap_override")
      assert event.payload["task_id"] == ready.id
      assert event.payload["cap"] == 2
      assert event.payload["actor"] == "api"
      # Subscribable, like `slot_cap_override`.
      assert "account_cap_override" in Arbiter.Events.valid_topics()
    end

    test "a resume of an In-progress ticket is not refused (stranding work is worse)", ctx do
      %{ws: ws, account: account} = ctx
      a = interrupted!(ws, "resumed over cap")

      assert {:ok, %{worker_pid: pid}} =
               Dispatch.resume(a.id, start_driver: false, resume_origin: :human)

      assert is_pid(pid)
      assert Concurrency.live_count(account) == 3
    end
  end

  # ---- AC2: an admission counts from the moment it is admitted ---------------

  describe "an admitted dispatch counts before its worker registers" do
    # Hold an admission open in its own process, as a dispatch does between the
    # gate and `Worker.start/1`.
    defp hold_admission(issue) do
      test = self()

      pid =
        spawn(fn ->
          send(test, {:admitted, self(), Admission.admit(issue, :claude)})

          receive do
            :release -> :ok
          end
        end)

      assert_receive {:admitted, ^pid, result}, 5_000
      {pid, result}
    end

    test "the next planning pass sees it", ctx do
      %{ws: ws, account: account} = ctx
      live = backlog!(ws, "live")
      {:ok, _} = Dispatch.dispatch(live.id, force: true, repo: @repo, start_driver: false)
      ready = ready!(ws, "fresh ready card")

      {holder, result} = hold_admission(backlog!(ws, "admitted, not yet registered"))
      assert {:ok, :admitted} = result

      assert Concurrency.live_count(account) == 2
      assert Concurrency.headroom(ws.id, :claude) == 0
      refute_admits(ready)

      # The reservation dies with its process: the slot comes back.
      ref = Process.monitor(holder)
      send(holder, :release)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}, 5_000
      _ = :sys.get_state(Admission.Registry)
      assert Concurrency.live_count(account) == 1
    end

    test "a burst of concurrent admissions admits exactly the headroom", ctx do
      %{ws: ws, account: account} = ctx
      issues = for n <- 1..6, do: backlog!(ws, "burst #{n}")

      results = issues |> Enum.map(fn issue -> Task.async(fn -> hold_admission(issue) end) end)
      held = Enum.map(results, &Task.await(&1, 10_000))

      admitted = Enum.count(held, &match?({_, {:ok, :admitted}}, &1))
      refused = Enum.count(held, &match?({_, {:error, {:account_at_capacity, _}}}, &1))

      assert {admitted, refused} == {2, 4}
      assert Concurrency.live_count(account) == 2

      Enum.each(held, fn {pid, _} -> send(pid, :release) end)
    end

    test "it keeps counting while its worker is registered but has not stamped its context",
         ctx do
      %{ws: ws, account: account} = ctx
      issue = backlog!(ws, "registered, init still running")

      {holder, result} = hold_admission(issue)
      assert {:ok, :admitted} = result
      assert Concurrency.live_count(account) == 1

      # A worker's `{:via, Registry, …}` name registers before `Worker.init/1`
      # runs; its dispatch context is stamped only after the run-row insert.
      test = self()

      worker =
        spawn(fn ->
          {:ok, _} = Registry.register(Arbiter.Worker.Registry, issue.id, nil)
          send(test, {:registered, self()})

          receive do
            :stamp ->
              Arbiter.Worker.Registry.put_dispatch(issue.id, ws.id, "claude")
              send(test, {:stamped, self()})
          end

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:registered, ^worker}, 5_000
      assert Concurrency.live_count(account) == 1
      assert Concurrency.headroom(ws.id, :claude) == 1

      send(worker, :stamp)
      assert_receive {:stamped, ^worker}, 5_000
      # Stamped: the worker counts, the reservation no longer does.
      assert Concurrency.live_count(account) == 1

      send(holder, :release)
      send(worker, :stop)
    end

    test "an admission that has registered its worker counts once, not twice", ctx do
      %{ws: ws, account: account} = ctx
      issue = backlog!(ws, "registered")

      assert {:ok, :admitted} = Admission.admit(issue, :claude)
      assert Concurrency.live_count(account) == 1

      {:ok, _} = Dispatch.dispatch(issue.id, force: true, repo: @repo, start_driver: false)
      # This process still holds its reservation; the worker supersedes it.
      assert Concurrency.live_count(account) == 1
      Admission.release(issue.id)
      assert Concurrency.live_count(account) == 1
    end
  end

  describe "a provider constraint (bd-13pqcp)" do
    test "an account on an excluded provider is refused, reserves nothing, and force does not override it",
         %{ws: ws, account: account} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "constrained",
          workspace_id: ws.id,
          provider_constraint: %{"exclude" => ["claude"]}
        })

      assert {:error, {:provider_constraint, :claude, phrase}} =
               Admission.admit(task, :claude, account: account)

      assert phrase =~ "held — provider constraint (exclude claude"

      assert {:error, {:provider_constraint, :claude, _}} =
               Admission.admit(task, :claude, account: account, force: true)

      assert Admission.pending() |> Enum.all?(&(&1.registry_key != task.id))
    end

    test "an account on an allowed provider is admitted as before", %{ws: ws, account: account} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "constrained",
          workspace_id: ws.id,
          provider_constraint: %{"require" => ["claude"]}
        })

      assert {:ok, :admitted} = Admission.admit(task, :claude, account: account)
      Admission.release(task.id)
    end

    test "a ticket without a constraint is admitted as before", %{ws: ws, account: account} do
      task = backlog!(ws, "plain")
      assert {:ok, :admitted} = Admission.admit(task, :claude, account: account)
      Admission.release(task.id)
    end
  end
end
