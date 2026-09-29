defmodule ArbiterWeb.Api.QueueControllerTest do
  @moduledoc """
  bd-8jixav: `POST /api/queue/:task_id/restart_watchdog` — the REST half of the
  dead-Watchdog recovery, and the endpoint `arb queue restart-watchdog` drives.
  Since bd-741sid the Watchdog is the ticket's, started from its row.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Worker.Watchdog
  alias Arbiter.Test.StubMerger

  setup %{conn: conn} do
    StubMerger.reset()

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "queue-ctrl-ws-#{System.unique_integer([:positive])}",
        prefix: "qc"
      })

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  # bd-741sid: an open PR is its ticket's — Merging, with the PR and the lane
  # its Watchdog watches it on recorded on the row — and nothing watches it
  # until the Watchdog is started from that row. The lane never polls within a
  # test.
  defp merging_ticket(ws, mr_ref) do
    {:ok, task} = Ash.create(Issue, %{title: "queue ctrl", workspace_id: ws.id})
    {:ok, _} = Ash.update(task, %{status: :in_progress})

    {:ok, task} =
      Issue.pr_opened(task.id, mr_ref,
        merger_url: "https://example.test/mr/#{mr_ref}",
        merge_watch:
          PullRequest.lane(
            adapter: StubMerger,
            repo: "qc/repo",
            interval_ms: 600_000,
            initial_delay_ms: 600_000
          )
      )

    task
  end

  # bd-4olwyg AC4: the endpoint `arb queue retry-auto-resolve` drives re-arms an
  # exhausted conflict auto-resolve, not only a `:ci_failed` one.
  defp stop_watchdog(task_id) do
    case Watchdog.whereis(task_id) do
      nil -> :ok
      wd -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, wd)
    end
  end

  describe "POST /api/queue/:task_id/retry_auto_resolve" do
    alias Arbiter.Test.RefusingConflictResolver

    test "re-arms a live watchdog whose conflict auto-resolve is exhausted", %{
      conn: conn,
      ws: ws
    } do
      task = merging_ticket(ws, "!qc-conflict")
      RefusingConflictResolver.arm(task.id, self())

      StubMerger.queue_get("!qc-conflict", [
        %{status: :open, approved: true, block_reason: :conflict}
      ])

      {:ok, wpid} =
        Watchdog.start(
          task_id: task.id,
          mr_ref: "!qc-conflict",
          adapter: StubMerger,
          auto_merge: false,
          interval_ms: 15,
          initial_delay_ms: 0,
          workspace: ws,
          conflict_resolver: RefusingConflictResolver
        )

      on_exit(fn -> stop_watchdog(task.id) end)
      assert is_pid(wpid)

      assert_receive {:conflict_resolve_called, _}, 1_000
      assert_receive {:conflict_escalated, _}, 1_000
      assert Watchdog.parked_on(task.id) == :conflict

      body = conn |> post("/api/queue/#{task.id}/retry_auto_resolve") |> json_response(200)
      assert body == %{"retried" => true, "task_id" => task.id}

      assert_receive {:conflict_resolve_called, _}, 1_000
    end

    test "400s when the watchdog has nothing to re-arm", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc-idle")
      :ok = Watchdog.restart(task.id)
      on_exit(fn -> stop_watchdog(task.id) end)

      body = conn |> post("/api/queue/#{task.id}/retry_auto_resolve") |> json_response(400)
      assert inspect(body) =~ "conflict"
    end
  end

  describe "POST /api/queue/:task_id/restart_watchdog" do
    test "restarts a dead watchdog for a Merging ticket", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc1")
      refute Watchdog.alive?(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"restarted" => true, "task_id" => id} = json_response(conn, 200)
      assert id == task.id
      assert Watchdog.alive?(task.id)
    end

    # bd-741sid, review round 1 (finding 4): `arb queue restart-watchdog` is an
    # operator's own restart, so it puts a ticket pulled out of the merge
    # queue back in it.
    test "puts a ticket pulled out of the merge queue back in it", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc4")
      :ok = PullRequest.pull(task.id)
      assert {:error, :pulled} = Watchdog.restart(task.id)

      on_exit(fn ->
        case Watchdog.whereis(task.id) do
          nil -> :ok
          wd -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, wd)
        end
      end)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"restarted" => true} = json_response(conn, 200)
      assert Watchdog.alive?(task.id)
      refute PullRequest.pulled?(Ash.get!(Issue, task.id))
    end

    test "404s when there is no such ticket", %{conn: conn} do
      conn = post(conn, ~p"/api/queue/no-such-task-xyz/restart_watchdog", %{})
      assert json_response(conn, 404)
    end

    test "409s rather than stacking a second watchdog on one MR", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc2")
      assert :ok = Watchdog.restart(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 409)
      assert msg =~ "already running"
    end

    test "400s when the ticket has no PR on record", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no PR yet", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 400)
      assert msg =~ "no PR on record"
      refute Watchdog.alive?(task.id)
    end

    test "400s once the ticket has left Merging", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc3")
      Ash.update!(Ash.get!(Issue, task.id), %{}, action: :close)

      conn = post(conn, ~p"/api/queue/#{task.id}/restart_watchdog", %{})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 400)
      assert msg =~ "not Merging"
      refute Watchdog.alive?(task.id)
    end
  end

  # bd-a14qd1: `POST /api/queue/:task_id/resume` is gone with the Conductor —
  # it re-dispatched a graph branch, and there are no graphs. The guardrail it
  # carried (bd-5b5hq7) is still exercised by WorkerController's own test.
  describe "POST /api/queue/:task_id/resume (removed, bd-a14qd1)" do
    test "the route and its action are gone" do
      assert Phoenix.Router.route_info(
               ArbiterWeb.Router,
               "POST",
               "/api/queue/bd-1/resume",
               "localhost"
             ) == :error

      refute function_exported?(ArbiterWeb.Api.QueueController, :resume, 2)

      # The sibling queue routes are untouched.
      assert %{plug_opts: :restart_watchdog} =
               Phoenix.Router.route_info(
                 ArbiterWeb.Router,
                 "POST",
                 "/api/queue/bd-1/restart_watchdog",
                 "localhost"
               )
    end
  end

  describe "POST /api/queue/:task_id/rerun_ci (bd-5mzzww / #1448)" do
    test "re-runs CI through the live watchdog and reports the granularity used", %{
      conn: conn,
      ws: ws
    } do
      task = merging_ticket(ws, "!qc-rerun")
      assert :ok = Watchdog.restart(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/rerun_ci", %{"mode" => "all_jobs"})

      assert %{"rerun" => true, "task_id" => id, "mode" => "all_jobs"} = json_response(conn, 200)
      assert id == task.id
      assert [{"!qc-rerun", opts} | _] = StubMerger.ci_reruns()
      assert opts.mode == :all_jobs
    end

    test "404s when no watchdog is running for the task", %{conn: conn} do
      conn = post(conn, ~p"/api/queue/no-such-task-xyz/rerun_ci", %{})
      assert json_response(conn, 404)
    end

    test "400s on an unknown mode before touching the forge", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc-rerun2")
      assert :ok = Watchdog.restart(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/rerun_ci", %{"mode" => "sideways"})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 400)
      assert msg =~ "mode"
      assert StubMerger.ci_reruns() == []
    end
  end

  describe "POST /api/queue/:task_id/mark_ci_external (bd-5mzzww / #1448)" do
    test "404s when no watchdog is running for the task", %{conn: conn} do
      conn =
        post(conn, ~p"/api/queue/no-such-task-xyz/mark_ci_external", %{"note" => "infra is down"})

      assert json_response(conn, 404)
    end

    test "400s without a note — an unevidenced verdict is not actionable", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc-ext1")
      assert :ok = Watchdog.restart(task.id)

      conn = post(conn, ~p"/api/queue/#{task.id}/mark_ci_external", %{})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 400)
      assert msg =~ "note"
    end

    test "400s when the task is not parked on a CI-failed block", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "!qc-ext2")
      assert :ok = Watchdog.restart(task.id)

      conn =
        post(conn, ~p"/api/queue/#{task.id}/mark_ci_external", %{"note" => "infra is down today"})

      assert %{"error" => %{"message" => msg}} = json_response(conn, 400)
      assert msg =~ "ci_failed"
    end
  end
end
