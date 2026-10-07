defmodule ArbiterWeb.Api.ReviewGateRoundControllerTest do
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.ReviewGate.Round

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  defp insert_round!(attrs) do
    base = %{
      task_id: "bd-rest-#{System.unique_integer([:positive])}",
      round: 1,
      role: :review
    }

    {:ok, round} = Ash.create(Round, Map.merge(base, attrs))
    round
  end

  describe "GET /api/review_gate_rounds" do
    test "carries the cross-family audit fields (bd-a1ke2c)", %{conn: conn} do
      task_id = "bd-rest-xfam-#{System.unique_integer([:positive])}"

      insert_round!(%{
        task_id: task_id,
        round: 1,
        verdict: :approve,
        reviewer_provider: "gemini",
        reviewer_family: "google",
        implementer_family: "anthropic",
        same_family_fallback: false,
        converged: true
      })

      conn = get(conn, ~p"/api/review_gate_rounds", %{task_id: task_id})
      {:ok, %{"data" => [r]}} = Jason.decode(conn.resp_body)

      assert r["reviewer_family"] == "google"
      assert r["implementer_family"] == "anthropic"
      assert r["same_family_fallback"] == false
      assert r["same_family_fallback_reason"] == nil
    end

    test "returns rounds for a task, oldest-first", %{conn: conn} do
      task_id = "bd-rest-flow-#{System.unique_integer([:positive])}"

      insert_round!(%{
        task_id: task_id,
        round: 1,
        verdict: :request_changes,
        findings: "VERDICT: REQUEST_CHANGES\n1. fix it",
        finding_count: 1,
        reviewer_model: "claude-sonnet-5",
        cost_usd: 0.1,
        converged: false
      })

      insert_round!(%{
        task_id: task_id,
        round: 2,
        verdict: :approve,
        findings: "VERDICT: APPROVE",
        finding_count: 0,
        reviewer_model: "claude-sonnet-5",
        reviewer_provider: "claude",
        cost_usd: 0.2,
        converged: true
      })

      conn = get(conn, ~p"/api/review_gate_rounds", %{task_id: task_id})
      assert conn.status == 200

      {:ok, parsed} = Jason.decode(conn.resp_body)
      [r1, r2] = parsed["data"]

      assert r1["round"] == 1
      assert r1["verdict"] == "request_changes"
      assert r1["converged"] == false
      assert r2["round"] == 2
      assert r2["verdict"] == "approve"
      assert r2["converged"] == true
      assert r2["reviewer_model"] == "claude-sonnet-5"
      # bd-3hb4ih: which provider ran the pass, so a reviewer print-timeout
      # rotation is readable off this endpoint (the only REST surface for a
      # gate's rounds) without re-reading the transcript.
      assert r2["reviewer_provider"] == "claude"
      assert r1["reviewer_provider"] == nil
      assert r2["cost_usd"] == 0.2
    end

    test "requires task_id", %{conn: conn} do
      conn = get(conn, ~p"/api/review_gate_rounds")
      assert conn.status == 400
    end

    # bd-6d3h8m: an automatic fix round's fresh gate restarts `round` at 1, so
    # sorting on `round` alone (the pre-fix behavior) interleaves it with the
    # original pass instead of reading as two consecutive passes.
    test "a fix round's rounds do not interleave with the original pass's", %{conn: conn} do
      task_id = "bd-rest-fixround-#{System.unique_integer([:positive])}"

      for round <- 1..2 do
        insert_round!(%{
          task_id: task_id,
          round: round,
          fix_round_attempt: 1,
          verdict: :request_changes,
          findings: "pass 2 round #{round}",
          converged: false
        })
      end

      for round <- 1..2 do
        insert_round!(%{
          task_id: task_id,
          round: round,
          fix_round_attempt: 0,
          verdict: :request_changes,
          findings: "pass 1 round #{round}",
          converged: false
        })
      end

      conn = get(conn, ~p"/api/review_gate_rounds", %{task_id: task_id})
      {:ok, parsed} = Jason.decode(conn.resp_body)

      assert Enum.map(parsed["data"], &{&1["fix_round_attempt"], &1["round"], &1["findings"]}) ==
               [
                 {0, 1, "pass 1 round 1"},
                 {0, 2, "pass 1 round 2"},
                 {1, 1, "pass 2 round 1"},
                 {1, 2, "pass 2 round 2"}
               ]
    end
  end

  describe "GET /api/review_gate_rounds report parity with MCP (D-W-21)" do
    test "carries total_count, outcome and resolutions beside data", %{conn: conn} do
      {:ok, ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "ws-rounds-report-#{System.unique_integer([:positive])}"
        })

      {:ok, task} =
        Ash.create(Arbiter.Tasks.Issue, %{title: "rounds report", workspace_id: ws.id})

      task_id = task.id

      for n <- 1..3 do
        insert_round!(%{task_id: task_id, round: n, verdict: :request_changes, converged: false})
      end

      {:ok, _} =
        Arbiter.ReviewGate.Resolutions.record(%{
          "task_id" => task_id,
          "decision" => "amend",
          "reasoning" => "fixed by hand",
          "actor" => "coordinator"
        })

      body = conn |> get(~p"/api/review_gate_rounds", %{task_id: task_id}) |> json_response(200)

      assert length(body["data"]) == 3
      assert body["count"] == 3
      assert body["total_count"] == 3
      assert body["outcome"] == "resolved"
      assert [%{"decision" => "amend"}] = body["resolutions"]
      assert body["resolution"]["decision"] == "amend"
      assert Map.has_key?(body["conflict_review"], "task")
      assert Map.has_key?(hd(body["data"]), "reviewer_tier")
    end

    test "limit keeps the most recent N rounds; total_count still counts them all", %{conn: conn} do
      task_id = "bd-rest-limit-#{System.unique_integer([:positive])}"
      for n <- 1..3, do: insert_round!(%{task_id: task_id, round: n})

      body =
        conn
        |> get(~p"/api/review_gate_rounds", %{task_id: task_id, limit: "2"})
        |> json_response(200)

      assert Enum.map(body["data"], & &1["round"]) == [2, 3]
      assert body["count"] == 2
      assert body["total_count"] == 3
    end

    test "REST and MCP return the same report", %{conn: conn} do
      task_id = "bd-rest-same-#{System.unique_integer([:positive])}"
      insert_round!(%{task_id: task_id, round: 1, verdict: :approve, converged: true})

      rest = conn |> get(~p"/api/review_gate_rounds", %{task_id: task_id}) |> json_response(200)

      {:ok, mcp} =
        Arbiter.MCP.Tools.review_gate_rounds_list(
          %Arbiter.MCP.Scope{tier: :coordinator, can_dispatch: true},
          %{"task_id" => task_id}
        )

      mcp = mcp |> Jason.encode!() |> Jason.decode!()
      assert Map.delete(rest, "data") == Map.delete(mcp, "rounds")
      assert rest["data"] == mcp["rounds"]
    end
  end
end
