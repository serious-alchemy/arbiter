defmodule ArbiterCli.Cmd.WorkerTest do
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.Worker

  describe "worker show" do
    test "prints the snapshot and output lines" do
      stub_get("/api/workers/bd-001", %{
        "task_id" => "bd-001",
        "kind" => "implement",
        "state" => "working",
        "current_step" => "implement",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:00:00Z",
        "output_lines" => ["hello", "world", "arb done"]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-001"]) end)
      assert exit_code == 0
      assert out =~ "bd-001"
      assert out =~ "Run:        implement working"
      refute out =~ "Status:"
      assert out =~ "hello"
      assert out =~ "arb done"
    end

    test "shows the phase and agent liveness" do
      stub_get("/api/workers/bd-002", %{
        "task_id" => "bd-002",
        "kind" => "implement",
        "state" => "waiting",
        "waiting_on" => "review_gate",
        "phase" => "in_review",
        "phase_label" => "in review",
        "agent_live" => false,
        "current_step" => "implement",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:00:00Z",
        "output_lines" => []
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-002"]) end)
      assert exit_code == 0
      assert out =~ "Phase:"
      assert out =~ "in review"
      assert out =~ "no live agent"
    end

    # bd-6omte4: a fix round the quota gate queued is held, not failed.
    test "says a held fix round is held for quota, with provider and reason" do
      stub_get("/api/workers/bd-003", %{
        "task_id" => "bd-003",
        "source" => "history",
        "kind" => "implement",
        "state" => "finished",
        "outcome" => "failed",
        "phase" => "held_for_quota",
        "phase_label" => "held for quota, will resume",
        "held" => %{
          "intent" => "ReviewGate fix round 2",
          "provider" => "gemini",
          "provider_label" => "Antigravity (agy)",
          "reason" => "quota exhausted",
          "held_since" => "2026-09-25T05:29:00Z"
        },
        "agent_live" => false,
        "repo" => "test/repo",
        "started_at" => "2026-09-25T05:00:00Z",
        "output_lines" => []
      })

      {out, _err, 0} = capture(fn -> Worker.run(["show", "bd-003"]) end)
      assert out =~ "Phase:      held for quota, will resume"

      assert out =~
               "Held:       ReviewGate fix round 2 held for quota on Antigravity (agy) " <>
                 "(quota exhausted), will resume — held since 2026-09-25T05:29:00Z"
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["show"]) end)
      assert exit_code != 0
    end

    test "flags a ticket with no live run and shows completion time" do
      stub_get("/api/workers/bd-003", %{
        "source" => "history",
        "task_id" => "bd-003",
        "kind" => "implement",
        "state" => "finished",
        "outcome" => "failed",
        "current_step" => nil,
        "repo" => "arbiter",
        "started_at" => "2026-05-20T19:00:00Z",
        "completed_at" => "2026-05-20T19:05:00Z",
        "exit_status" => 2,
        "failure_reason" => "claude_crashed",
        "output_lines" => ["boom"]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-003"]) end)
      assert exit_code == 0
      assert out =~ "no live run"
      assert out =~ "Run:        implement finished (failed)"
      assert out =~ "Completed:  2026-05-20T19:05:00Z"
      assert out =~ "claude_crashed"
      assert out =~ "boom"
    end

    test "uses the plain worker/ticket/repo labels" do
      stub_get("/api/workers/bd-004", %{
        "source" => "history",
        "task_id" => "bd-004",
        "kind" => "implement",
        "state" => "finished",
        "outcome" => "failed",
        "repo" => "arbiter",
        "started_at" => "2026-05-20T19:00:00Z",
        "output_lines" => []
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-004"]) end)
      assert exit_code == 0
      assert out =~ "no live run"
      assert out =~ "Ticket:"
      assert out =~ "Repo:"
    end

    test "--json forwards the full snapshot" do
      stub_get("/api/workers/bd-002", %{
        "task_id" => "bd-002",
        "kind" => "implement",
        "state" => "finished",
        "outcome" => "succeeded",
        "output_lines" => ["ok"]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["show", "bd-002", "--json"]) end)
      assert exit_code == 0
      assert {:ok, %{"task_id" => "bd-002"}} = Jason.decode(String.trim(out))
    end
  end

  # bd-1uu19b AC5: the ticket's current run plus its recent runs, each
  # labelled with its kind — no separate history fallback.
  describe "worker show recent runs" do
    test "lists each recent run with its kind, marking the current one" do
      stub_get("/api/workers/bd-020", %{
        "task_id" => "bd-020",
        "kind" => "fix_pass",
        "state" => "working",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:10:00Z",
        "output_lines" => [],
        "runs" => [
          %{
            "run_id" => "run-b",
            "kind" => "fix_pass",
            "state" => "working",
            "started_at" => "2026-05-20T19:10:00Z",
            "current" => true
          },
          %{
            "run_id" => "run-a",
            "kind" => "implement",
            "state" => "finished",
            "outcome" => "succeeded",
            "started_at" => "2026-05-20T19:00:00Z",
            "current" => false
          }
        ]
      })

      {out, _err, 0} = capture(fn -> Worker.run(["show", "bd-020"]) end)
      assert out =~ "Runs (2, newest first):"
      assert out =~ ~r/\* run-b  fix_pass working/
      assert out =~ ~r/  run-a  implement finished \(succeeded\)/
      assert :binary.match(out, "run-b") < :binary.match(out, "run-a")
    end
  end

  describe "worker show cost" do
    test "prints the task's settled + in-flight worker spend" do
      stub_get("/api/workers/bd-009", %{
        "task_id" => "bd-009",
        "kind" => "implement",
        "state" => "working",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:00:00Z",
        "cost_usd" => 3.75,
        "cost_settled_usd" => 2.5,
        "cost_live_usd" => 1.25,
        "cost_live" => true
      })

      {out, _err, 0} = capture(fn -> Worker.run(["show", "bd-009"]) end)
      assert out =~ "Spend:      ~$3.75 (incl. ~$1.25 in flight)"
    end

    test "an unpriced task prints n/a" do
      stub_get("/api/workers/bd-010", %{
        "task_id" => "bd-010",
        "kind" => "implement",
        "state" => "working",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:00:00Z",
        "cost_usd" => nil,
        "cost_unpriced" => true
      })

      {out, _err, 0} = capture(fn -> Worker.run(["show", "bd-010"]) end)
      assert out =~ "Spend:      n/a"
    end
  end

  describe "worker runs" do
    test "lists historical runs newest-first with kind, state, and model" do
      stub_get("/api/workers/history", %{
        "data" => [
          %{
            "id" => "run-2",
            "task_id" => "bd-010",
            "kind" => "review",
            "state" => "finished",
            "outcome" => "succeeded",
            "model" => "claude-opus-4-8",
            "started_at" => "2026-05-20T19:10:00Z",
            "completed_at" => "2026-05-20T19:12:00Z"
          },
          %{
            "id" => "run-1",
            "task_id" => "bd-010",
            "kind" => "implement",
            "state" => "finished",
            "outcome" => "failed",
            "started_at" => "2026-05-20T19:00:00Z",
            "completed_at" => "2026-05-20T19:05:00Z",
            "failure_reason" => "exit code 2",
            "failure_summary" => "VERDICT: REQUEST_CHANGES — needs a guard"
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["runs", "bd-010"]) end)
      assert exit_code == 0
      assert out =~ "Historical runs for bd-010 (2"
      assert out =~ "run-2  review finished (succeeded)"
      assert out =~ "run-1  implement finished (failed)"
      assert out =~ "model=claude-opus-4-8"
      assert out =~ "failure: exit code 2"
      assert out =~ "summary: VERDICT: REQUEST_CHANGES — needs a guard"
      # Newest-first ordering is preserved from the API: review run before main.
      assert :binary.match(out, "run-2") < :binary.match(out, "run-1")
    end

    test "an interrupted run (shut down with the server) is not labelled a failure (bd-aje6fj)" do
      stub_get("/api/workers/history", %{
        "data" => [
          %{
            "id" => "run-3",
            "task_id" => "bd-013",
            "kind" => "implement",
            "state" => "finished",
            "outcome" => "interrupted",
            "started_at" => "2026-09-18T14:00:00Z",
            "completed_at" => "2026-09-18T14:30:00Z",
            "failure_reason" => "server shutdown"
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["runs", "bd-013"]) end)
      assert exit_code == 0
      assert out =~ "implement finished (interrupted)"
      assert out =~ "reason: server shutdown"
      refute out =~ "failure:"
    end

    test "reports when no historical runs exist" do
      stub_get("/api/workers/history", %{"data" => []})

      {out, _err, exit_code} = capture(fn -> Worker.run(["runs", "bd-011"]) end)
      assert exit_code == 0
      assert out =~ "no historical runs"
    end

    test "--json forwards the full list" do
      stub_get("/api/workers/history", %{
        "data" => [%{"id" => "run-9", "task_id" => "bd-012", "kind" => "implement"}]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["runs", "bd-012", "--json"]) end)
      assert exit_code == 0
      assert {:ok, %{"data" => [%{"id" => "run-9"}]}} = Jason.decode(String.trim(out))
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["runs"]) end)
      assert exit_code != 0
    end
  end

  describe "worker list" do
    test "renders a table of active workers" do
      stub_get("/api/workers", %{
        "data" => [
          %{
            "task_id" => "bd-001",
            "kind" => "fix_pass",
            "state" => "working",
            "current_step" => "implement",
            "repo" => "test/repo",
            "started_at" => "2026-05-20T19:00:00Z"
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["list"]) end)
      assert exit_code == 0
      assert out =~ "Active workers (1)"
      assert out =~ "bd-001  fix_pass working"
      refute out =~ "status="
    end

    # bd-aw2cyt: a row whose agent has exited must not read as running work.
    test "renders the phase, and marks a row with no live agent" do
      stub_get("/api/workers", %{
        "data" => [
          %{
            "task_id" => "bd-001",
            "kind" => "implement",
            "state" => "working",
            "phase" => "in_review",
            "phase_label" => "waiting on CI / merge",
            "agent_live" => false,
            "current_step" => "implement",
            "repo" => "test/repo",
            "started_at" => "2026-05-20T19:00:00Z"
          },
          %{
            "task_id" => "bd-002",
            "kind" => "implement",
            "state" => "working",
            "phase" => "implementing",
            "phase_label" => "implementing",
            "agent_live" => true,
            "current_step" => "implement",
            "repo" => "test/repo",
            "started_at" => "2026-05-20T19:00:00Z"
          }
        ]
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["list"]) end)
      assert exit_code == 0
      assert out =~ "phase=in_review"
      assert out =~ "phase=implementing"
      # The dead row is called out; the live one is not.
      [dead, live] = out |> String.split("\n") |> Enum.filter(&(&1 =~ "bd-00"))
      assert dead =~ "no agent"
      refute live =~ "no agent"
    end

    # bd-8vnuy3: the server now sends settled + in-flight spend. A live figure
    # must read as an estimate, an unpriced one as n/a, never as $0.00.
    test "renders live, settled, unpriced and degraded cost distinctly" do
      row = %{
        "kind" => "implement",
        "state" => "working",
        "current_step" => "implement",
        "repo" => "test/repo",
        "started_at" => "2026-05-20T19:00:00Z"
      }

      stub_get("/api/workers", %{
        "data" => [
          Map.merge(row, %{
            "task_id" => "bd-live",
            "cost_usd" => 16.53,
            "cost_live" => true,
            "cost_live_usd" => 2.99
          }),
          Map.merge(row, %{"task_id" => "bd-settled", "cost_usd" => 13.54, "cost_live" => false}),
          Map.merge(row, %{"task_id" => "bd-agy", "cost_usd" => nil, "cost_unpriced" => true}),
          Map.merge(row, %{
            "task_id" => "bd-torn",
            "cost_usd" => 2.0,
            "cost_live" => true,
            "cost_live_usd" => 0.0,
            "cost_degraded" => true
          })
        ]
      })

      {out, _err, 0} = capture(fn -> Worker.run(["list"]) end)
      [live, settled, agy, torn] = out |> String.split("\n") |> Enum.filter(&(&1 =~ "bd-"))

      assert live =~ "cost=~$16.53 (incl. ~$2.99 in flight)"
      assert settled =~ "cost=$13.54"
      refute settled =~ "~"
      assert agy =~ "cost=n/a"
      refute agy =~ "$0.00"
      assert torn =~ "cost=~$2.00"
      assert torn =~ "live read incomplete"
    end

    test "(none) when no active workers" do
      stub_get("/api/workers", %{"data" => []})

      {out, _err, exit_code} = capture(fn -> Worker.run(["list"]) end)
      assert exit_code == 0
      assert out =~ "no active workers"
    end

    test "ls is an alias for list" do
      stub_get("/api/workers", %{"data" => []})

      {out, _err, exit_code} = capture(fn -> Worker.run(["ls"]) end)
      assert exit_code == 0
      assert out =~ "no active workers"
    end
  end

  describe "worker stop" do
    test "POSTs to the stop endpoint" do
      stub_post("/api/workers/bd-003/stop", %{"task_id" => "bd-003", "stopped" => true})

      {out, _err, exit_code} = capture(fn -> Worker.run(["stop", "bd-003"]) end)
      assert exit_code == 0
      assert out =~ "Stopped worker"
      assert out =~ "bd-003"
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["stop"]) end)
      assert exit_code != 0
    end
  end

  describe "worker log" do
    test "prints the run metadata and the full durable transcript, oldest first" do
      stub_get("/api/workers/bd-005/log", %{
        "data" => %{
          "task_id" => "bd-005",
          "run_id" => "run-abc",
          "path" => "/var/arbiter/worker-logs/run-abc.log",
          "exists" => true,
          "line_count" => 3,
          "lines" => ["first", "second", "third"]
        }
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["log", "bd-005"]) end)
      assert exit_code == 0
      assert out =~ "bd-005"
      assert out =~ "run-abc"
      assert out =~ "/var/arbiter/worker-logs/run-abc.log"
      assert out =~ "Full transcript (3 lines"
      assert out =~ "first"
      assert out =~ "third"
    end

    test "reports when no durable transcript exists on disk" do
      stub_get("/api/workers/bd-006/log", %{
        "data" => %{
          "task_id" => "bd-006",
          "run_id" => "run-xyz",
          "path" => "/var/arbiter/worker-logs/run-xyz.log",
          "exists" => false,
          "line_count" => 0,
          "lines" => []
        }
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["log", "bd-006"]) end)
      assert exit_code == 0
      assert out =~ "no durable transcript"
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["log"]) end)
      assert exit_code != 0
    end
  end

  describe "worker review" do
    test "POSTs to the review endpoint with task_id" do
      stub_post("/api/workers/review", %{
        "task_id" => "bd-099",
        "task" => %{"id" => "bd-099"},
        "worker" => %{"pid" => "worker-xyz"}
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["review", "bd-099"]) end)
      assert exit_code == 0
      assert out =~ "Review worker spawned"
      assert out =~ "bd-099"
      assert out =~ "worker-xyz"
    end

    test "forwards --repo flag" do
      stub_post("/api/workers/review", %{
        "task_id" => "bd-100",
        "task" => %{"id" => "bd-100"},
        "worker" => %{"pid" => "worker-abc"}
      })

      {out, _err, exit_code} =
        capture(fn -> Worker.run(["review", "bd-100", "--repo", "my-repo"]) end)

      assert exit_code == 0
      assert out =~ "Review worker spawned"
    end

    test "forwards --model flag" do
      stub_post("/api/workers/review", %{
        "task_id" => "bd-101",
        "task" => %{"id" => "bd-101"},
        "worker" => %{"pid" => "worker-def"}
      })

      {out, _err, exit_code} =
        capture(fn -> Worker.run(["review", "bd-101", "--model", "opus"]) end)

      assert exit_code == 0
      assert out =~ "Review worker spawned"
    end

    test "--json forwards the full payload" do
      stub_post("/api/workers/review", %{
        "task_id" => "bd-102",
        "task" => %{"id" => "bd-102"},
        "worker" => %{"pid" => "worker-ghi"}
      })

      {out, _err, exit_code} =
        capture(fn -> Worker.run(["review", "bd-102", "--json"]) end)

      assert exit_code == 0
      assert {:ok, %{"task_id" => "bd-102"}} = Jason.decode(String.trim(out))
    end

    test "missing task_id returns a friendly error" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["review"]) end)
      assert exit_code != 0
    end

    test "includes worktree_path if present" do
      stub_post("/api/workers/review", %{
        "task_id" => "bd-103",
        "task" => %{"id" => "bd-103"},
        "worker" => %{"pid" => "worker-jkl"},
        "worktree_path" => "/tmp/worktree-123"
      })

      {out, _err, exit_code} = capture(fn -> Worker.run(["review", "bd-103"]) end)
      assert exit_code == 0
      assert out =~ "/tmp/worktree-123"
    end
  end

  describe "unknown subcommand" do
    test "halts with a useful message" do
      {_out, _err, exit_code} = capture(fn -> Worker.run(["wat"]) end)
      assert exit_code != 0
    end

    test "no subcommand at all halts" do
      {_out, _err, exit_code} = capture(fn -> Worker.run([]) end)
      assert exit_code != 0
    end
  end
end
