defmodule ArbiterWeb.Api.SchedulerControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Board.Autopilot

  setup do
    # Start an autopilot instance for testing
    pid =
      start_supervised!(
        {Autopilot,
         name: nil,
         paused: false,
         interval_ms: :never,
         snapshot: fn opts ->
           %{
             ready: [],
             running: [],
             waiting: [],
             closed_today: [],
             promote: nil,
             slots_total: 4,
             slots_free: 4,
             quota: :ok,
             paused: opts[:paused],
             now: DateTime.utc_now()
           }
         end}
      )

    on_exit(fn ->
      # Reset the global Autopilot singleton to paused state to prevent test pollution
      Autopilot.pause(Autopilot)
    end)

    {:ok, pid: pid}
  end

  describe "POST /api/scheduler/pause" do
    test "pauses the scheduler", %{conn: conn} do
      :ok = Autopilot.resume()
      assert false == Autopilot.paused?()

      conn = post(conn, "/api/scheduler/pause")

      assert %{
               "paused" => true,
               "changed_by" => "coordinator via api",
               "changed_at" => changed_at
             } =
               json_response(conn, 200)

      assert is_binary(changed_at)
      assert Autopilot.paused?() == true
    end
  end

  describe "surface attribution (bd-cl6zjn)" do
    test "a caller-supplied surface is ignored (P-07); the route's own is recorded", %{conn: conn} do
      :ok = Autopilot.resume()

      conn = post(conn, "/api/scheduler/pause", %{"surface" => "cli"})

      assert %{"changed_by" => "coordinator via api"} = json_response(conn, 200)

      assert [%{paused: true, actor: "coordinator", surface: "api"} | _] =
               Arbiter.Settings.scheduler_changes()
    end

    test "a resume is audited with its surface", %{conn: conn} do
      :ok = Autopilot.pause()

      post(conn, "/api/scheduler/resume")

      assert [%{paused: false, surface: "api"} | _] = Arbiter.Settings.scheduler_changes()
    end
  end

  describe "POST /api/scheduler/resume" do
    test "resumes the scheduler", %{conn: conn} do
      :ok = Autopilot.pause()
      assert true == Autopilot.paused?()

      conn = post(conn, "/api/scheduler/resume")

      assert %{
               "paused" => false,
               "changed_by" => "coordinator via api",
               "changed_at" => changed_at
             } =
               json_response(conn, 200)

      assert is_binary(changed_at)
      assert Autopilot.paused?() == false
    end
  end

  describe "GET /api/scheduler/status" do
    test "returns the current pause state", %{conn: conn} do
      :ok = Autopilot.pause()

      conn = get(conn, "/api/scheduler/status")

      assert %{"paused" => true} = json_response(conn, 200)
    end

    test "returns running state", %{conn: conn} do
      :ok = Autopilot.resume()

      conn = get(conn, "/api/scheduler/status")

      assert %{"paused" => false, "state" => "running", "safe_to_restart" => false} =
               body = json_response(conn, 200)

      # bd-36ytcl: an idle worker is simply not in flight; there is no
      # separate `parked` list.
      refute Map.has_key?(body, "parked")
    end

    # bd-9fgg04: paused is not idle — live work keeps it draining.
    test "a paused scheduler with live work is draining, and lists it", %{conn: conn} do
      :ok = Autopilot.pause()
      test_pid = self()

      runner =
        spawn_link(fn ->
          Arbiter.Board.Drain.track(:review_reply, %{task_id: "bd-sched-api"}, fn ->
            send(test_pid, :running)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :running

      conn = get(conn, "/api/scheduler/status")

      assert %{
               "paused" => true,
               "state" => "draining",
               "safe_to_restart" => false,
               "in_flight" => in_flight
             } = json_response(conn, 200)

      assert Enum.any?(
               in_flight,
               &match?(%{"kind" => "review_reply", "task_id" => "bd-sched-api"}, &1)
             )

      send(runner, :release)
    end
  end

  # DC5 (bd-2c2a4g, design §9): the budgets ride the status body, labelled shadow.
  describe "GET /api/scheduler/status budgets (DC5)" do
    setup do
      :ok = :meck.new(Arbiter.Board.CapacityView, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Arbiter.Board.CapacityView) end)

      view = %{
        admission: %{mode: "shadow", label: "shadow", decides: false, agreement: nil},
        pools: [
          %{
            account: "acct-1",
            pool: "antigravity:gemini_models",
            budget: 0,
            seats: 0,
            free: 0,
            binding: "window:weekly",
            reason: "weekly 0.43 used ≥ line 0.42",
            state: "held_pace"
          }
        ],
        machines: [%{id: "local", name: "local", cap: 6, live: 3, free: 3, state: "online"}],
        repos: [],
        fair_share: []
      }

      :meck.expect(Arbiter.Board.CapacityView, :status, fn -> view end)
      :ok
    end

    test "carries admission, budgets, machines, repos and fair_share", %{conn: conn} do
      body = conn |> get("/api/scheduler/status") |> json_response(200)

      assert %{"label" => "shadow", "decides" => false} = body["admission"]

      assert [
               %{
                 "pool" => "antigravity:gemini_models",
                 "budget" => 0,
                 "binding" => "window:weekly",
                 "reason" => "weekly 0.43 used ≥ line 0.42",
                 "state" => "held_pace"
               }
             ] = body["budgets"]

      assert [%{"id" => "local", "cap" => 6, "live" => 3, "free" => 3}] = body["machines"]
      assert body["repos"] == []
      assert body["fair_share"] == []
    end

    test "pause and resume answer with the same body", %{conn: conn} do
      assert %{"admission" => %{"label" => "shadow"}, "budgets" => [_]} =
               conn |> post("/api/scheduler/pause") |> json_response(200)
    end
  end

  describe "internal failures are 5xx, not 400 (P-19)" do
    setup do
      :ok = :meck.new(Arbiter.Board.Drain, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Arbiter.Board.Drain) end)
    end

    test "a raise in status is 500", %{conn: conn} do
      :meck.expect(Arbiter.Board.Drain, :status, fn -> raise "boom" end)
      assert json_response(get(conn, "/api/scheduler/status"), 500)
    end

    test "an exit in status is 503", %{conn: conn} do
      :meck.expect(Arbiter.Board.Drain, :status, fn -> exit(:timeout) end)
      assert json_response(get(conn, "/api/scheduler/status"), 503)
    end
  end
end
