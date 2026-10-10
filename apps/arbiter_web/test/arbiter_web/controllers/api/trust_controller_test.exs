defmodule ArbiterWeb.Api.TrustControllerTest do
  @moduledoc """
  G18 (bd-7i9pxn): the REST surface behind `arb trust`. Reads and the
  coordinator's decisions on a suspension are coordinator-tier; a promotion is
  operator-only (`ArbiterWeb.ApiPolicy` `:operator`), and the Loop's own apply
  route refuses a `trust_promotion` outright.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Guardrails.Subjects
  alias Arbiter.Guardrails.TrustRecord
  alias Arbiter.Loop
  alias Arbiter.MCP.Scope

  @subject "codex/gpt-5.1-codex"

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "trust-#{n}", prefix: "tr#{n}"})
    {:ok, _} = Subjects.put(%{provider: "codex", tier: :quarantine}, :operator)

    {:ok, record} =
      Ash.create(TrustRecord, %{
        provider: "codex",
        model: "gpt-5.1-codex",
        tier: :quarantine,
        runs: 12,
        clean_runs: 11,
        clean_tickets: 8,
        eligible_for: :probation,
        eligibility: %{"from" => "quarantine", "to" => "probation", "criteria" => []},
        recent_events: [%{"kind" => "permission_denial", "severity" => "minor"}]
      })

    {:ok, proposal} =
      Loop.record(
        %{
          kind: :trust_promotion,
          gist: "promote #{@subject} quarantine → probation",
          category: "trust:quarantine->probation",
          target: @subject,
          scope: :fleet,
          incident_refs: ["run-1", "run-2"],
          task_refs: ["t-1"],
          payload: %{
            "provider" => "codex",
            "model" => "gpt-5.1-codex",
            "from" => "quarantine",
            "to" => "probation"
          },
          origin: "loop.trust",
          workspace_id: ws.id
        },
        evidence_bar: %{min_incidents: 1, min_distinct_tasks: 1}
      )

    %{ws: ws, record: record, proposal: proposal}
  end

  defp tier_now do
    Rules.match(Rules.all(), Guardrails.subject("codex", "gpt-5.1-codex")).tier
  end

  defp operator_conn do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> Scope.mint_coordinator(nil, operator: true))
  end

  describe "GET /api/trust" do
    test "lists every subject's tier and record", %{conn: conn} do
      assert %{"subjects" => [subject]} = conn |> get("/api/trust") |> json_response(200)
      assert subject["subject"] == @subject
      assert subject["tier"] == "quarantine"
      assert subject["record"]["clean_runs"] == 11
      assert [%{"to" => "probation", "state" => "proposed"}] = subject["pending"]
    end

    test "?subject= shows one subject with its recent events and pending proposal", %{
      conn: conn,
      proposal: proposal
    } do
      assert %{"subject" => detail} =
               conn |> get("/api/trust", %{"subject" => @subject}) |> json_response(200)

      assert detail["eligibility"]["eligible_for"] == "probation"
      assert [%{"kind" => "permission_denial"}] = detail["recent_events"]
      assert [%{"id" => id}] = detail["pending"]
      assert id == proposal.id

      assert conn |> get("/api/trust", %{"subject" => "codex/nope"}) |> json_response(404)
    end
  end

  describe "POST /api/trust/promote" do
    test "a coordinator token without operator proof is refused and nothing changes", %{
      conn: conn
    } do
      conn =
        post(conn, "/api/trust/promote", %{
          "subject" => @subject,
          "to" => "probation",
          "reason" => "clean"
        })

      assert json_response(conn, 403)
      assert tier_now() == :quarantine
    end

    test "with operator proof it applies the proposal and records actor operator", %{
      proposal: proposal
    } do
      body =
        operator_conn()
        |> post("/api/trust/promote", %{
          "subject" => @subject,
          "to" => "probation",
          "reason" => "eleven clean runs"
        })
        |> json_response(200)

      assert body["promoted"] == true
      assert body["subject"]["tier"] == "probation"
      assert tier_now() == :probation

      {:ok, applied} = Loop.get_pending(proposal.id)
      assert applied.state == :applied
      assert applied.actor == "operator"

      assert %{"action" => "promoted", "actor" => "operator"} =
               List.last(body["subject"]["history"])
    end

    test "a bad request names what is wrong" do
      body =
        operator_conn()
        |> post("/api/trust/promote", %{"subject" => @subject, "to" => "probation"})
        |> json_response(422)

      assert body["error"]["message"] =~ "reason"
    end
  end

  describe "the Loop's own apply route" do
    test "refuses a trust_promotion, operator proof or not", %{proposal: proposal} do
      for conn <- [operator_conn(), build_conn() |> put_req_header("authorization", "Bearer " <> Scope.mint_coordinator(nil))] do
        body = conn |> post("/api/loop/pending/#{proposal.id}/apply") |> json_response(409)
        assert body["error"]["message"] =~ "arb trust promote"
      end

      assert tier_now() == :quarantine
    end
  end

  describe "POST /api/trust/confirm and /api/trust/dismiss" do
    setup %{record: record} do
      {:ok, _} = Subjects.put(%{provider: "codex", tier: :probation}, :operator)

      {:ok, record} =
        Ash.update(record, %{
          tier: :probation,
          suspended_at: DateTime.utc_now(),
          suspension: %{"kind" => "public_upload_attempt", "run_id" => "r1", "prior_tier" => "probation"}
        })

      %{record: record}
    end

    test "the coordinator dismisses a suspension with a reason", %{conn: conn} do
      body =
        conn
        |> post("/api/trust/dismiss", %{"subject" => @subject, "reason" => "authorised probe"})
        |> json_response(200)

      assert body["subject"]["suspended"] == nil
      assert tier_now() == :probation
    end

    test "the coordinator confirms one: the subject drops to quarantine", %{conn: conn} do
      body = conn |> post("/api/trust/confirm", %{"subject" => @subject}) |> json_response(200)

      assert body["subject"]["tier"] == "quarantine"
      assert tier_now() == :quarantine
    end

    test "a worker token may not", %{ws: ws} do
      {:ok, task} = Ash.create(Arbiter.Tasks.Issue, %{title: "t", workspace_id: ws.id})

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> Scope.mint_worker(task))
        |> post("/api/trust/dismiss", %{"subject" => @subject, "reason" => "mine"})

      assert json_response(conn, 403)
    end
  end
end
