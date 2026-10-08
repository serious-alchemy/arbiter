defmodule ArbiterCli.Cmd.LoopTest do
  use ArbiterCli.CliCase, async: false

  setup do
    prev = System.get_env("ARB_WORKSPACE")
    System.delete_env("ARB_WORKSPACE")

    on_exit(fn ->
      if prev,
        do: System.put_env("ARB_WORKSPACE", prev),
        else: System.delete_env("ARB_WORKSPACE")
    end)

    :ok
  end

  alias ArbiterCli.Cmd.Loop

  test "loop analyze prints the markdown report" do
    stub_post(
      "/api/loop/analyze",
      %{
        "markdown" => "# Loop-analysis report — last 7d\n\nbody",
        "usage_event_id" => "ev-1",
        "summary" => %{"totals" => %{"failed" => 2}}
      },
      200
    )

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--since", "7d"]) end)
    assert exit_code == 0
    assert out =~ "Loop-analysis report"
    refute out =~ "usage_event_id"
  end

  test "loop with no subcommand defaults to analyze" do
    stub_post(
      "/api/loop/analyze",
      %{"markdown" => "# report", "usage_event_id" => "e", "summary" => %{}},
      200
    )

    {out, _err, exit_code} = capture(fn -> Loop.run([]) end)
    assert exit_code == 0
    assert out =~ "report"
  end

  test "loop analyze --json prints the raw envelope" do
    stub_post(
      "/api/loop/analyze",
      %{
        "markdown" => "# report",
        "usage_event_id" => "ev-9",
        "summary" => %{"totals" => %{"failed" => 1}}
      },
      200
    )

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--json"]) end)
    assert exit_code == 0
    assert out =~ "usage_event_id"
    assert out =~ "ev-9"
  end

  test "loop analyze POSTs --since in the body (the route writes a usage row)" do
    stub_routes([
      {{"post", "/api/loop/analyze"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body)["since"] == "24h"

         Req.Test.json(conn, %{
           "markdown" => "# report",
           "usage_event_id" => "x",
           "summary" => %{}
         })
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--since", "24h"]) end)
    assert exit_code == 0
  end

  # bd-4f6opo — `--discover` is the opt-in model pass: a body param on the
  # analyze POST, absent unless the flag is given.
  test "loop analyze sends no discover param without --discover" do
    stub_routes([
      {{"post", "/api/loop/analyze"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         refute Map.has_key?(Jason.decode!(body), "discover")

         Req.Test.json(conn, %{
           "markdown" => "# report",
           "usage_event_id" => "x",
           "summary" => %{}
         })
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Loop.run(["analyze"]) end)
    assert exit_code == 0
  end

  test "loop analyze --discover sends discover: true and prints the section" do
    stub_routes([
      {{"post", "/api/loop/analyze"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body)["discover"] == true

         Req.Test.json(conn, %{
           "markdown" =>
             "# report\n\n## Candidate detectors (discovery Stage 1 — opt-in model pass)",
           "usage_event_id" => "x",
           "summary" => %{}
         })
       end}
    ])

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--discover"]) end)
    assert exit_code == 0
    assert out =~ "Candidate detectors"
  end

  test "loop analyze --propose --discover posts discover: true in the body" do
    stub_routes([
      {{"post", "/api/loop/propose"},
       fn conn ->
         {:ok, body, conn} = Plug.Conn.read_body(conn)
         assert Jason.decode!(body)["discover"] == true

         Req.Test.json(conn, %{
           "markdown" => "# report",
           "usage_event_id" => "x",
           "summary" => %{},
           "proposals" => []
         })
       end}
    ])

    {_out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--propose", "--discover"]) end)
    assert exit_code == 0
  end

  # bd-9j2g3x — `--propose` is a different verb on a different route from the
  # report-only analyze.
  test "loop analyze --propose posts to /api/loop/propose and lists what it queued" do
    stub_post(
      "/api/loop/propose",
      %{
        "markdown" => "# report",
        "usage_event_id" => "ev-p",
        "summary" => %{},
        "proposals" => [
          %{
            "id" => "p-1",
            "state" => "hypothesis",
            "kind" => "skill_patch",
            "evidence_count" => 1,
            "distinct_tasks" => 1,
            "gist" => "working-practice guardrail for: inert at runtime"
          }
        ]
      },
      200
    )

    {out, _err, exit_code} = capture(fn -> Loop.run(["analyze", "--propose"]) end)

    assert exit_code == 0
    assert out =~ "Queued proposals (1)"
    assert out =~ "hypothesis"
    assert out =~ "1i/1t"
    assert out =~ "arb loop apply"
  end

  describe "the proposal queue" do
    test "loop pending lists the queue" do
      stub_get("/api/loop/pending", %{
        "pending" => [
          %{
            "id" => "p-1",
            "state" => "proposed",
            "kind" => "difficulty_override",
            "evidence_count" => 3,
            "distinct_tasks" => 2,
            "gist" => "raise difficulty on bd-x: D1 → D2"
          }
        ],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      assert out =~ "p-1"
      assert out =~ "proposed"
      assert out =~ "3i/2t"
      assert out =~ "D1 → D2"
    end

    # Amendment D: an approver must see the recurring price next to the
    # evidence, not have to open the row to discover a fleet-wide prompt
    # addition costs tokens on every dispatch from here on.
    test "loop pending prices each proposal's recurring context cost" do
      stub_get("/api/loop/pending", %{
        "pending" => [
          %{
            "id" => "p-1",
            "state" => "proposed",
            "kind" => "skill_patch",
            "evidence_count" => 3,
            "distinct_tasks" => 2,
            "context_cost_tokens" => 120,
            "gist" => "always run mix precommit before pushing"
          },
          %{
            "id" => "p-2",
            "state" => "proposed",
            "kind" => "difficulty_override",
            "evidence_count" => 3,
            "distinct_tasks" => 2,
            "context_cost_tokens" => 0,
            "gist" => "raise difficulty on bd-x: D1 → D2"
          }
        ],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      assert out =~ "+120ctx"
      # Blast radius 1 is genuinely free forever; say so rather than print "0".
      assert out =~ "free"
    end

    # bd-bldypb: a row whose payload can't satisfy its kind's apply
    # preconditions is marked beside the state, so an operator can tell
    # which rows are actionable without pressing apply on each one.
    test "loop pending marks a payload-less row as needing authoring" do
      stub_get("/api/loop/pending", %{
        "pending" => [
          %{
            "id" => "p-1",
            "state" => "proposed",
            "kind" => "skill_patch",
            "evidence_count" => 4,
            "distinct_tasks" => 3,
            "needs_authoring" => true,
            "gist" => "missing test coverage"
          },
          %{
            "id" => "p-2",
            "state" => "proposed",
            "kind" => "difficulty_override",
            "evidence_count" => 1,
            "distinct_tasks" => 1,
            "needs_authoring" => false,
            "gist" => "raise difficulty on bd-x: D1 → D2"
          }
        ],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      lines = String.split(out, "\n", trim: true)
      gapped_line = Enum.find(lines, &String.contains?(&1, "p-1"))
      override_line = Enum.find(lines, &String.contains?(&1, "p-2"))

      assert gapped_line =~ "needs authoring"
      refute override_line =~ "needs authoring"
    end

    test "loop pending names the evidence bar when the queue is empty" do
      stub_get("/api/loop/pending", %{
        "pending" => [],
        "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["pending"]) end)

      assert exit_code == 0
      assert out =~ "no queued loop proposals"
      assert out =~ "3 incidents"
      assert out =~ "2 distinct tasks"
    end

    test "loop diff prints the unified diff and the evidence behind it" do
      stub_get("/api/loop/pending/p-1", %{
        "pending" => %{
          "id" => "p-1",
          "state" => "proposed",
          "kind" => "difficulty_override",
          "scope" => "task",
          "gist" => "raise difficulty on bd-x",
          "evidence_count" => 3,
          "distinct_tasks" => 2,
          "target_metric" => "rework rate",
          "baseline" => "42.0%",
          "context_cost_tokens" => 0,
          "diff" => "--- a/task\n+++ b/task\n-difficulty: 1\n+difficulty: 2\n"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-1"]) end)

      assert exit_code == 0
      assert out =~ "+difficulty: 2"
      assert out =~ "3 incident(s) across 2 distinct task(s)"
      assert out =~ "rework rate"
      assert out =~ "42.0%"
      # A routing change alters which model runs, not what is in the prompt.
      assert out =~ "context cost: 0 tokens"
    end

    test "loop diff spells out the standing cost of a fleet-wide clause" do
      stub_get("/api/loop/pending/p-3", %{
        "pending" => %{
          "id" => "p-3",
          "state" => "proposed",
          "kind" => "skill_patch",
          "scope" => "fleet",
          "gist" => "always run mix precommit before pushing",
          "evidence_count" => 4,
          "distinct_tasks" => 3,
          "context_cost_tokens" => 120,
          "diff" => "--- a/skill\n+++ b/skill\n+always run mix precommit\n"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-3"]) end)

      assert exit_code == 0
      assert out =~ "context cost: ~120 token(s) added to every dispatch"
    end

    test "loop diff surfaces why a hypothesis is not applicable" do
      stub_get("/api/loop/pending/p-2", %{
        "pending" => %{
          "id" => "p-2",
          "state" => "hypothesis",
          "kind" => "skill_patch",
          "scope" => "fleet",
          "gist" => "guardrail",
          "evidence_count" => 1,
          "distinct_tasks" => 1,
          "diff" => nil,
          "inapplicable_reason" =>
            "1 incident across 1 distinct task — needs 3 incidents across 2 distinct tasks"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-2"]) end)

      assert exit_code == 0
      assert out =~ "not applicable"
      assert out =~ "needs 3 incidents"
      assert out =~ "no diff"
    end

    test "loop diff surfaces why a proposed row needs authoring (bd-bldypb)" do
      stub_get("/api/loop/pending/p-4", %{
        "pending" => %{
          "id" => "p-4",
          "state" => "proposed",
          "kind" => "skill_patch",
          "scope" => "task",
          "gist" => "missing test coverage",
          "evidence_count" => 1,
          "distinct_tasks" => 1,
          "diff" => nil,
          "needs_authoring" => true,
          "authoring_gap" =>
            "this proposal names no target skill: the loop does not yet map a finding " <>
              "category to a skill"
        }
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-4"]) end)

      assert exit_code == 0
      assert out =~ "needs authoring"
      assert out =~ "names no target skill"
      assert out =~ "no diff"
    end

    test "loop apply posts to the per-row apply route" do
      stub_post(
        "/api/loop/pending/p-1/apply",
        %{"pending" => %{"id" => "p-1", "gist" => "raise difficulty on bd-x"}, "applied" => true},
        200
      )

      {out, _err, exit_code} = capture(fn -> Loop.run(["apply", "p-1"]) end)

      assert exit_code == 0
      assert out =~ "applied p-1"
    end

    test "loop reject passes the reason through" do
      stub_routes([
        {{"post", "/api/loop/pending/p-1/reject"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           assert Jason.decode!(body)["reason"] == "handled by hand"

           Req.Test.json(conn, %{
             "pending" => %{"id" => "p-1", "gist" => "g"},
             "rejected" => true
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn -> Loop.run(["reject", "p-1", "--reason", "handled by hand"]) end)

      assert exit_code == 0
      assert out =~ "rejected p-1"
    end

    test "loop apply all fetches the proposed rows and applies each one" do
      stub_routes([
        {{"get", "/api/loop/pending"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           assert conn.query_params["state"] == "proposed"

           Req.Test.json(conn, %{
             "pending" => [
               %{"id" => "p-1", "gist" => "one"},
               %{"id" => "p-2", "gist" => "two"}
             ],
             "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
           })
         end},
        {{"post", "/api/loop/pending/p-1/apply"},
         fn conn -> Req.Test.json(conn, %{"pending" => %{"id" => "p-1", "gist" => "one"}}) end},
        {{"post", "/api/loop/pending/p-2/apply"},
         fn conn -> Req.Test.json(conn, %{"pending" => %{"id" => "p-2", "gist" => "two"}}) end}
      ])

      {out, _err, exit_code} = capture(fn -> Loop.run(["apply", "all"]) end)

      assert exit_code == 0
      assert out =~ "applied p-1"
      assert out =~ "applied p-2"
    end

    test "loop diff --json prints the full row" do
      stub_get("/api/loop/pending/p-1", %{
        "pending" => %{"id" => "p-1", "state" => "proposed", "diff" => "--- a\n+++ b\n"}
      })

      {out, _err, exit_code} = capture(fn -> Loop.run(["diff", "p-1", "--json"]) end)

      assert exit_code == 0
      assert %{"id" => "p-1", "diff" => "--- a\n+++ b\n"} = Jason.decode!(out)
    end

    test "loop apply all --json emits one array of the applied rows" do
      stub_routes([
        {{"get", "/api/loop/pending"},
         {%{"pending" => [%{"id" => "p-1", "gist" => "one"}, %{"id" => "p-2", "gist" => "two"}]},
          200}},
        {{"post", "/api/loop/pending/p-1/apply"},
         {%{"pending" => %{"id" => "p-1", "state" => "applied"}}, 200}},
        {{"post", "/api/loop/pending/p-2/apply"},
         {%{"pending" => %{"id" => "p-2", "state" => "applied"}}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Loop.run(["apply", "all", "--json"]) end)

      assert exit_code == 0
      assert [%{"id" => "p-1"}, %{"id" => "p-2"}] = Jason.decode!(out)
    end

    test "loop apply all keeps going past a failed row, then exits non-zero" do
      stub_routes([
        {{"get", "/api/loop/pending"},
         {%{"pending" => [%{"id" => "p-1", "gist" => "one"}, %{"id" => "p-2", "gist" => "two"}]},
          200}},
        {{"post", "/api/loop/pending/p-1/apply"},
         {%{"error" => %{"type" => "conflict", "message" => "cannot be applied"}}, 409}},
        {{"post", "/api/loop/pending/p-2/apply"},
         {%{"pending" => %{"id" => "p-2", "gist" => "two", "state" => "applied"}}, 200}}
      ])

      {out, err, exit_code} = capture(fn -> Loop.run(["apply", "all"]) end)

      assert exit_code == 1
      assert out =~ "applied p-2"
      assert err =~ "p-1"
      assert err =~ "1 of 2"
    end

    test "loop apply all --json lists the failed row as an error entry and exits non-zero" do
      stub_routes([
        {{"get", "/api/loop/pending"},
         {%{"pending" => [%{"id" => "p-1", "gist" => "one"}, %{"id" => "p-2", "gist" => "two"}]},
          200}},
        {{"post", "/api/loop/pending/p-1/apply"},
         {%{"error" => %{"type" => "conflict", "message" => "cannot be applied"}}, 409}},
        {{"post", "/api/loop/pending/p-2/apply"},
         {%{"pending" => %{"id" => "p-2", "gist" => "two", "state" => "applied"}}, 200}}
      ])

      {out, _err, exit_code} = capture(fn -> Loop.run(["apply", "all", "--json"]) end)

      assert exit_code == 1
      assert [failed, ok] = Jason.decode!(out)
      assert failed["id"] == "p-1"
      assert failed["error"] =~ "cannot be applied"
      assert ok["id"] == "p-2"
    end

    test "loop pending and apply all reject an unknown --state before any request" do
      {_out, err, exit_code} = capture(fn -> Loop.run(["pending", "--state", "bogus"]) end)
      assert exit_code == 1
      assert err =~ "unknown state"
      assert err =~ "proposed"

      {_out, err, exit_code} = capture(fn -> Loop.run(["apply", "all", "--state", "bogus"]) end)
      assert exit_code == 1
      assert err =~ "unknown state"
    end

    test "loop pending accepts a comma-separated list of valid states" do
      stub_routes([
        {{"get", "/api/loop/pending"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           assert conn.query_params["state"] == "proposed,hypothesis"
           Req.Test.json(conn, %{"pending" => []})
         end}
      ])

      {_out, _err, exit_code} =
        capture(fn -> Loop.run(["pending", "--state", "proposed,hypothesis"]) end)

      assert exit_code == 0
    end

    test "loop diff without an id is a usage error" do
      {_out, err, exit_code} = capture(fn -> Loop.run(["diff"]) end)
      assert exit_code == 1
      assert err =~ "usage: arb loop diff"
    end
  end

  test "loop propose routing posts the tier spec and prints the proposal" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-default", "name" => "default", "prefix" => "bd"}]}, 200}},
      {{"post", "/api/loop/propose/routing"},
       {%{"pending" => %{"id" => "p-9", "gist" => "route D3 to standard/high"}}, 200}}
    ])

    {out, _err, exit_code} =
      capture(fn ->
        Loop.run(~w(propose routing --workspace default --difficulty 3
                    --model-tier standard --thinking high))
      end)

    assert exit_code == 0
    assert out =~ "proposed p-9"
  end

  describe "loop canary status" do
    test "prints both arms and verdict progress" do
      arm = fn d, c ->
        %{
          "dispatches" => d,
          "tasks" => d,
          "reviewed_tasks" => d,
          "first_pass_convergence" => c,
          "review_rounds" => d + 1,
          "cost_usd" => 12.5,
          "cost_per_round" => 0.5
        }
      end

      stub_get(
        "/api/loop/canary",
        %{
          "running" => true,
          "status" => %{
            "proposal_id" => "p-9",
            "proposal_state" => "proposed",
            "difficulty" => 3,
            "rule" => %{"model_tier" => "standard", "thinking" => "high"},
            "started_at" => "2026-09-29T00:00:00Z",
            "age_days" => 2.34,
            "expires_at" => "2026-10-13T00:00:00Z",
            "min_dispatches" => 20,
            "dispatches_left" => 8,
            "auto_promote" => false,
            "verdict" => "insufficient_data",
            "canary" => arm.(12, 0.75),
            "control" => arm.(14, 0.5)
          }
        },
        200
      )

      {out, _err, exit_code} = capture(fn -> Loop.run(~w(canary status)) end)

      assert exit_code == 0
      assert out =~ "p-9"
      assert out =~ "until a verdict is possible: 8"
      assert out =~ "canary   dispatches=12"
      assert out =~ "first-pass=75.0%"
      assert out =~ "control  dispatches=14"
      assert out =~ "you decide"
    end

    test "prints the server's message when no canary is running" do
      stub_get(
        "/api/loop/canary",
        %{"running" => false, "message" => "no canary is running"},
        200
      )

      {out, _err, exit_code} = capture(fn -> Loop.run(~w(canary status)) end)
      assert exit_code == 0
      assert out =~ "no canary is running"
    end
  end

  test "unknown subcommand errors" do
    {_out, err, exit_code} = capture(fn -> Loop.run(["frobnicate"]) end)
    assert exit_code == 1
    assert err =~ "unknown"
  end

  test "--help prints usage without hitting the API" do
    {out, _err, exit_code} = capture(fn -> Loop.run(["--help"]) end)
    assert exit_code == 0
    assert out =~ "arb loop analyze"
  end

  describe "workspace plumbing (-w and --workspace)" do
    test "arb loop propose routing -w X --difficulty 2 --model-tier T sends resolved workspace" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"post", "/api/loop/propose/routing"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:routing_body, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"pending" => %{"id" => "p-10", "gist" => "route D2 to standard"}})
         end}
      ])

      {out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main(
            ~w(loop propose routing -w custom --difficulty 2 --model-tier standard)
          )
        end)

      assert exit_code == 0
      assert out =~ "proposed p-10"
      assert_received {:routing_body, body}
      assert body["workspace_id"] == "ws-custom"
      assert body["difficulty"] == 2
      assert body["model_tier"] == "standard"
    end

    test "arb loop pending -w X sends resolved workspace_id query param" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"get", "/api/loop/pending"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           send(test_pid, {:pending_params, conn.query_params})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "pending" => [],
             "evidence_bar" => %{"min_incidents" => 3, "min_distinct_tasks" => 2}
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main(~w(loop pending -w custom))
        end)

      assert exit_code == 0
      assert out =~ "no queued loop proposals"
      assert_received {:pending_params, %{"workspace_id" => "ws-custom"}}
    end

    test "arb loop apply all -w X sends resolved workspace_id query param" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"get", "/api/loop/pending"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           send(test_pid, {:apply_all_params, conn.query_params})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"pending" => []})
         end}
      ])

      {out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main(~w(loop apply all -w custom))
        end)

      assert exit_code == 0
      assert out =~ "nothing to apply"
      assert_received {:apply_all_params, %{"workspace_id" => "ws-custom", "state" => "proposed"}}
    end

    # AC 3 (P-23): `arb loop apply all -w X` only touches X. The stub plays the
    # server's workspace filter, so a request that failed to carry the
    # workspace would be handed (and would apply) the other workspace's rows.
    test "arb loop apply all -w X applies only X's proposals" do
      test_pid = self()

      rows = [
        %{"id" => "x-1", "workspace_id" => "ws-x", "gist" => "mine"},
        %{"id" => "y-1", "workspace_id" => "ws-y", "gist" => "theirs"}
      ]

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{
            "data" => [
              %{"id" => "ws-x", "name" => "x", "prefix" => "xx"},
              %{"id" => "ws-y", "name" => "y", "prefix" => "yy"}
            ]
          }, 200}},
        {{"get", "/api/loop/pending"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           ws = conn.query_params["workspace_id"]
           visible = Enum.filter(rows, fn r -> is_nil(ws) or r["workspace_id"] == ws end)
           Req.Test.json(conn, %{"pending" => visible})
         end},
        {{"post", "/api/loop/pending/x-1/apply"},
         fn conn ->
           send(test_pid, {:applied, "x-1"})
           Req.Test.json(conn, %{"pending" => %{"id" => "x-1", "gist" => "mine"}})
         end},
        {{"post", "/api/loop/pending/y-1/apply"},
         fn conn ->
           send(test_pid, {:applied, "y-1"})
           Req.Test.json(conn, %{"pending" => %{"id" => "y-1", "gist" => "theirs"}})
         end}
      ])

      {out, _err, exit_code} =
        capture(fn -> ArbiterCli.Main.main(~w(loop apply all -w x)) end)

      assert exit_code == 0
      assert out =~ "applied x-1"
      assert_received {:applied, "x-1"}
      refute_received {:applied, "y-1"}
    end

    test "arb loop analyze -w X sends resolved workspace_id in the body" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"post", "/api/loop/analyze"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:analyze_params, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{
             "markdown" => "# report",
             "usage_event_id" => "ev-1",
             "summary" => %{}
           })
         end}
      ])

      {out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main(~w(loop analyze -w custom))
        end)

      assert exit_code == 0
      assert out =~ "report"
      assert_received {:analyze_params, %{"workspace_id" => "ws-custom"}}
    end

    test "arb loop canary status -w X sends resolved workspace_id query param" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"get", "/api/loop/canary"},
         fn conn ->
           conn = Plug.Conn.fetch_query_params(conn)
           send(test_pid, {:canary_params, conn.query_params})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"running" => false, "message" => "no canary is running"})
         end}
      ])

      {out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main(~w(loop canary status -w custom))
        end)

      assert exit_code == 0
      assert out =~ "no canary is running"
      assert_received {:canary_params, %{"workspace_id" => "ws-custom"}}
    end

    test "arb loop propose repo-doc-patch -w X sends resolved workspace_id" do
      test_pid = self()

      stub_routes([
        {{"get", "/api/workspaces"},
         {%{"data" => [%{"id" => "ws-custom", "name" => "custom", "prefix" => "cx"}]}, 200}},
        {{"post", "/api/loop/propose/repo_doc_patch"},
         fn conn ->
           {:ok, body, conn} = Plug.Conn.read_body(conn)
           send(test_pid, {:repo_doc_body, Jason.decode!(body)})

           conn
           |> Plug.Conn.put_status(200)
           |> Req.Test.json(%{"pending" => %{"id" => "p-11", "gist" => "repo doc patch"}})
         end}
      ])

      {out, _err, exit_code} =
        capture(fn ->
          ArbiterCli.Main.main([
            "loop",
            "propose",
            "repo-doc-patch",
            "-w",
            "custom",
            "--repo",
            "myrepo",
            "--lesson",
            "test lesson"
          ])
        end)

      assert exit_code == 0
      assert out =~ "proposed p-11"
      assert_received {:repo_doc_body, body}
      assert body["workspace_id"] == "ws-custom"
      assert body["repo"] == "myrepo"
      assert body["lesson"] == "test lesson"
    end
  end
end
