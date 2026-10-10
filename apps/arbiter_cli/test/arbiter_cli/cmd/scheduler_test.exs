defmodule ArbiterCli.Cmd.SchedulerTest do
  @moduledoc """
  bd-9fgg04 / #1903: `arb scheduler status` must tell "paused and still
  draining" from "paused and quiescent", and `arb scheduler wait` blocks until
  the second holds.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Scheduler

  @now DateTime.utc_now() |> DateTime.to_iso8601()

  defp body(state, in_flight \\ []) do
    %{
      "state" => state,
      "paused" => state != "running",
      "safe_to_restart" => state == "quiescent",
      "changed_at" => @now,
      "changed_by" => "cli",
      "in_flight" => in_flight,
      "checked_at" => @now
    }
  end

  defp fix_pass do
    %{
      "kind" => "fix_pass",
      "task_id" => "bd-77j2if",
      "registry_key" => "bd-77j2if:fixpass",
      "state" => "working",
      "agent_live" => true,
      "started_at" => DateTime.utc_now() |> DateTime.add(-300) |> DateTime.to_iso8601(),
      "detail" => nil
    }
  end

  # Answers each GET /api/scheduler/status with the next body in `bodies`,
  # repeating the last one.
  defp stub_status_sequence(bodies) do
    counter = :counters.new(1, [])

    stub_routes([
      {{"get", "/api/scheduler/status"},
       fn conn ->
         :counters.add(counter, 1, 1)
         n = :counters.get(counter, 1)
         Req.Test.json(conn, Enum.at(bodies, n - 1, List.last(bodies)))
       end}
    ])

    counter
  end

  setup do
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    :ok
  end

  # DC5 (bd-2c2a4g, design §9): the per-pool budgets, machines and repos.
  describe "status budgets (DC5)" do
    defp capacity_body(admission_overrides \\ %{}) do
      Map.merge(body("running"), %{
        "admission" =>
          Map.merge(
            %{
              "mode" => "shadow",
              "label" => "shadow",
              "decides" => false,
              "agreement" => %{
                "comparable" => 52,
                "agrees" => 47,
                "since" => "2026-10-12T00:00:00Z"
              }
            },
            admission_overrides
          ),
        "budgets" => [
          %{
            "label" => "claude:default",
            "budget" => 3,
            "seats" => 3,
            "free" => 0,
            "state" => "full",
            "reason" => "ceiling max_concurrent 3 (quota allows 4: 5h binds)"
          },
          %{
            "label" => "antigravity:default gemini",
            "budget" => 0,
            "seats" => 0,
            "free" => 0,
            "state" => "held_pace",
            "reason" => "weekly 0.43 used ≥ line 0.42"
          },
          %{
            "label" => "unmetered-pool",
            "budget" => "unlimited",
            "seats" => 2,
            "free" => "unlimited",
            "state" => "free",
            "reason" => "no account: unmetered"
          }
        ],
        "machines" => [
          %{"id" => "local", "name" => "local", "cap" => 6, "live" => 3, "free" => 3},
          %{"id" => "n1", "name" => "box", "cap" => nil, "live" => 1, "free" => nil}
        ],
        "repos" => [%{"label" => "default/vstim", "cap" => 2, "used" => 1}],
        "fair_share" => []
      })
    end

    test "names the admission mode and the shadow agreement" do
      stub_get("/api/scheduler/status", capacity_body())
      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Admission: shadow"
      assert out =~ "agrees on 47 of 52"
      assert out =~ "since 2026-10-12"
      assert out =~ "today's gate and caps still decide"
    end

    test "enforce does not say shadow" do
      stub_get(
        "/api/scheduler/status",
        capacity_body(%{"mode" => "enforce", "label" => "enforce", "decides" => true})
      )

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Admission: enforce"
      refute out =~ "still decide"
    end

    test "lists each provider pool with budget, seats, free and the reason" do
      stub_get("/api/scheduler/status", capacity_body())
      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Providers"
      assert out =~ ~r/claude:default\s+3\s+3\s+0\s+ceiling max_concurrent 3/
      assert out =~ ~r/antigravity:default gemini\s+0\s+0\s+0\s+weekly 0.43 used/
      assert out =~ ~r/unmetered-pool\s+unlimited\s+2\s+unlimited/
    end

    test "lists machines with cap, live runs and free slots" do
      stub_get("/api/scheduler/status", capacity_body())
      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Machines"
      assert out =~ ~r/local\s+6\s+3\s+3/
      assert out =~ ~r/box\s+-\s+1\s+-/
    end

    test "lists repo caps with their implementer runs" do
      stub_get("/api/scheduler/status", capacity_body())
      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Repos"
      assert out =~ ~r/default\/vstim\s+2\s+1/
    end

    test "a server that predates the budgets prints none of it" do
      stub_get("/api/scheduler/status", body("running"))
      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      refute out =~ "Admission"
      refute out =~ "Providers"
      refute out =~ "Machines"
    end

    test "--json passes the new keys through untouched" do
      stub_get("/api/scheduler/status", capacity_body())
      {out, _err, 0} = capture(fn -> Scheduler.run(["status", "--json"]) end)

      decoded = Jason.decode!(out)
      assert decoded["admission"]["label"] == "shadow"
      assert length(decoded["budgets"]) == 3
      assert length(decoded["machines"]) == 2
    end
  end

  describe "status" do
    test "paused and draining names what is still in flight and says it is not safe" do
      stub_get("/api/scheduler/status", body("draining", [fix_pass()]))

      {out, _err, exit_code} = capture(fn -> Scheduler.run(["status"]) end)

      assert exit_code == 0
      assert out =~ "paused, draining"
      assert out =~ "NOT safe to restart"
      assert out =~ "fix_pass"
      assert out =~ "bd-77j2if"
      assert out =~ "5m"
    end

    test "shows when and by whom the pause state last changed" do
      stub_get("/api/scheduler/status", %{
        body("quiescent")
        | "changed_by" => "operator via dashboard"
      })

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Last changed: #{@now} by operator via dashboard"
    end

    test "says so when no change was ever recorded" do
      stub_get("/api/scheduler/status", %{
        body("quiescent")
        | "changed_by" => nil,
          "changed_at" => nil
      })

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Last changed: unknown"
    end

    test "paused and quiescent says safe to restart" do
      stub_get("/api/scheduler/status", body("quiescent"))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "paused, quiescent"
      assert out =~ "safe to restart"
    end

    test "running is not a safe restart point" do
      stub_get("/api/scheduler/status", body("running"))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "running"
      assert out =~ "not a safe restart point"
    end

    # bd-asxw4e: the dispatch cap's count — the tickets In progress.
    test "names the slots used and the tickets holding them" do
      stub_get(
        "/api/scheduler/status",
        Map.merge(body("running"), %{"slots_used" => 2, "slot_holders" => ["bd-a", "bd-b"]})
      )

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Slots used: 2 (bd-a, bd-b)"
    end

    # bd-b2iigy: resumes waiting on the primary's own worker cap.
    test "lists resumes held for local capacity" do
      stub_get(
        "/api/scheduler/status",
        Map.merge(body("running"), %{
          "held_local_capacity" => [
            %{"task_id" => "bd-a", "reason" => "held: local capacity"},
            %{"task_id" => "bd-b", "reason" => "held: local capacity"}
          ]
        })
      )

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "Held: local capacity"
      assert out =~ "2 resume(s)"
      assert out =~ "bd-a"
      assert out =~ "bd-b"
    end

    test "prints no held line when nothing waits on local capacity" do
      stub_get(
        "/api/scheduler/status",
        Map.merge(body("running"), %{"held_local_capacity" => []})
      )

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      refute out =~ "Held:"
    end

    test "a server that predates the slot count prints no slots line" do
      stub_get("/api/scheduler/status", body("running"))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      refute out =~ "Slots used"
    end

    test "a server that predates the drain state is reported unknown, never safe" do
      stub_get("/api/scheduler/status", %{
        "paused" => true,
        "changed_at" => nil,
        "changed_by" => nil
      })

      {out, _err, 0} = capture(fn -> Scheduler.run(["status"]) end)

      assert out =~ "drain state unknown"
      refute out =~ "safe to restart"
    end

    test "--json passes the server body through" do
      stub_get("/api/scheduler/status", body("draining", [fix_pass()]))

      {out, _err, 0} = capture(fn -> Scheduler.run(["status", "--json"]) end)

      assert %{"state" => "draining", "in_flight" => [%{"kind" => "fix_pass"}]} =
               Jason.decode!(out)
    end
  end

  describe "wait" do
    test "polls through draining and exits 0 once quiescent" do
      counter =
        stub_status_sequence([
          body("draining", [fix_pass()]),
          body("draining", [fix_pass()]),
          body("quiescent")
        ])

      {out, _err, exit_code} = capture(fn -> Scheduler.run(["wait", "--interval", "1"]) end)

      assert exit_code == 0
      assert :counters.get(counter, 1) == 3
      assert out =~ "Waiting: paused, draining"
      assert out =~ "paused, quiescent"
      # The unchanged in-flight list is printed once, not on every poll.
      assert length(String.split(out, "Waiting:")) == 2
    end

    test "gives up with exit 124 when the drain outlasts --timeout" do
      stub_status_sequence([body("draining", [fix_pass()])])

      {out, _err, exit_code} = capture(fn -> Scheduler.run(["wait", "--timeout", "0"]) end)

      assert exit_code == 124
      assert out =~ "Timed out"
      assert out =~ "bd-77j2if"
    end

    test "refuses to wait on a running scheduler — exit 2, pause first" do
      stub_status_sequence([body("running")])

      {_out, err, exit_code} = capture(fn -> Scheduler.run(["wait"]) end)

      assert exit_code == 2
      assert err =~ "arb scheduler pause"
    end

    test "does not treat an older server's bare paused flag as quiescent" do
      stub_status_sequence([%{"paused" => true}])

      {_out, err, exit_code} = capture(fn -> Scheduler.run(["wait"]) end)

      assert exit_code == 1
      assert err =~ "drain state unknown"
    end

    test "--json emits only the final body" do
      stub_status_sequence([body("draining", [fix_pass()]), body("quiescent")])

      {out, _err, 0} = capture(fn -> Scheduler.run(["wait", "--json"]) end)

      assert %{"state" => "quiescent", "safe_to_restart" => true} = Jason.decode!(out)
    end
  end

  describe "pause" do
    test "reports the drain state it lands in" do
      stub_post("/api/scheduler/pause", body("draining", [fix_pass()]), 200)

      {out, _err, 0} = capture(fn -> Scheduler.run(["pause"]) end)

      assert out =~ "Board scheduler paused"
      assert out =~ "paused, draining"
      assert out =~ "fix_pass"
    end
  end
end
