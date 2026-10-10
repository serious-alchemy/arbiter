defmodule Arbiter.MCP.TrustToolsTest do
  @moduledoc """
  G18 (bd-7i9pxn, `docs/design/guardrail-profiles.md` §6.4–6.5): the MCP twins of
  `arb trust show`, `arb trust confirm` and `arb trust dismiss`, all
  coordinator-only — and no MCP tool, at any tier, can promote a subject:
  `loop_pending_apply` refuses a `trust_promotion` even for a token carrying
  operator proof, and nothing else writes a tier upward.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.TrustFixtures

  alias Arbiter.Guardrails
  alias Arbiter.Guardrails.Rules
  alias Arbiter.Guardrails.TrustRecord
  alias Arbiter.Loop
  alias Arbiter.MCP.{Catalog, Scope, Tools}

  @subject "codex/gpt-5.1-codex"
  @trust_tools ~w(trust_show trust_confirm trust_dismiss)

  @coordinator %Scope{tier: :coordinator}
  @operator %Scope{tier: :coordinator, operator: true}

  setup do
    ws = workspace!()
    rule!(%{provider: "codex", tier: :quarantine})

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
          origin: "loop.trust"
        },
        evidence_bar: %{min_incidents: 1, min_distinct_tasks: 1}
      )

    %{
      ws: ws,
      record: record,
      proposal: proposal,
      worker: %Scope{tier: :worker, workspace_id: ws.id, task_id: "bd-trust-1"},
      refine: %Scope{tier: :refine, workspace_id: ws.id, issue_id: "bd-trust-1"}
    }
  end

  defp tier_now do
    Rules.match(Rules.all(), Guardrails.subject("codex", "gpt-5.1-codex")).tier
  end

  # The subject at probation, suspended after a critical event.
  defp suspend!(record, prior_tier \\ "probation") do
    rule!(%{provider: "codex", tier: :probation})

    {:ok, record} =
      Ash.update(record, %{
        tier: :probation,
        suspended_at: DateTime.utc_now(),
        suspension: %{
          "id" => "ev-1",
          "kind" => "public_upload_attempt",
          "severity" => "critical",
          "run_id" => "r1",
          "prior_tier" => prior_tier
        }
      })

    record
  end

  describe "trust_show" do
    test "lists every subject's tier, record and pending proposal" do
      assert {:ok, %{subjects: [subject], count: 1}} = Tools.trust_show(@coordinator, %{})

      assert subject.subject == @subject
      assert subject.tier == "quarantine"
      assert subject.record.clean_runs == 11
      assert [%{to: "probation", state: "proposed"}] = subject.pending
    end

    test "`subject` shows one in full: recent events, history and the pending proposal", %{
      proposal: proposal
    } do
      assert {:ok, %{subject: detail}} = Tools.trust_show(@coordinator, %{"subject" => @subject})

      assert detail.eligibility.eligible_for == "probation"
      assert [%{"kind" => "permission_denial"}] = detail.recent_events
      assert detail.history == []
      assert [%{id: id}] = detail.pending
      assert id == proposal.id
    end

    test "an unknown subject is not found, and a malformed one names the shape" do
      assert {:error, {:not_found, message}} =
               Tools.trust_show(@coordinator, %{"subject" => "codex/nope"})

      assert message =~ "codex/nope"

      assert {:error, {:invalid, message}} =
               Tools.trust_show(@coordinator, %{"subject" => "codex"})

      assert message =~ "provider/model"
    end

    test "is reachable through the catalog and its result is JSON-encodable" do
      assert {:ok, data} = Catalog.call(@coordinator, "trust_show", %{"subject" => @subject})
      assert {:ok, _json} = Jason.encode(data)
    end
  end

  describe "trust_confirm" do
    test "confirms a suspension: the subject drops to quarantine, attributed to the caller", %{
      record: record
    } do
      suspend!(record)

      assert {:ok, %{confirmed: true, subject: detail}} =
               Catalog.call(@coordinator, "trust_confirm", %{"subject" => @subject})

      assert detail.tier == "quarantine"
      assert detail.suspended == nil
      assert tier_now() == :quarantine

      assert %{"action" => "confirmed", "actor" => "coordinator", "to" => "quarantine"} =
               List.last(detail.history)
    end

    test "a subject that is not suspended is refused" do
      assert {:tool_error, message, "validation_error"} =
               Catalog.call(@coordinator, "trust_confirm", %{"subject" => @subject})

      assert message =~ "not suspended"
    end

    test "requires a subject" do
      assert {:tool_error, message, _type} = Catalog.call(@coordinator, "trust_confirm", %{})
      assert message =~ "subject"
    end
  end

  describe "trust_dismiss" do
    test "dismisses a suspension as a false positive: the tier it had returns", %{
      record: record
    } do
      suspend!(record)

      assert {:ok, %{dismissed: true, subject: detail}} =
               Catalog.call(@coordinator, "trust_dismiss", %{
                 "subject" => @subject,
                 "reason" => "authorised security probe"
               })

      assert detail.suspended == nil
      assert detail.effective_tier == "probation"
      assert tier_now() == :probation

      assert %{"action" => "dismissed", "reason" => "authorised security probe"} =
               List.last(detail.history)
    end

    test "requires a reason, and changes nothing without one", %{record: record} do
      suspend!(record)

      assert {:tool_error, message, "validation_error"} =
               Catalog.call(@coordinator, "trust_dismiss", %{"subject" => @subject})

      assert message =~ "reason"
      assert %TrustRecord{suspended_at: %DateTime{}} = Arbiter.Loop.Trust.get(@subject)
    end
  end

  describe "tier gating" do
    test "the trust tools are coordinator-only: a worker and a refine session see none", ctx do
      coordinator = @coordinator |> Catalog.visible() |> Enum.map(& &1.name)
      for tool <- @trust_tools, do: assert(tool in coordinator)

      for scope <- [ctx.worker, ctx.refine] do
        names = scope |> Catalog.visible() |> Enum.map(& &1.name)
        assert Enum.filter(names, &String.starts_with?(&1, "trust_")) == []

        for tool <- @trust_tools do
          assert {:rpc_error, -32_003, message} =
                   Catalog.call(scope, tool, %{"subject" => @subject, "reason" => "mine"})

          assert message =~ "not permitted"
        end
      end
    end
  end

  describe "no MCP tool, at any tier, can promote" do
    test "no tier sees a promote tool, operator proof included", ctx do
      for scope <- [ctx.worker, ctx.refine, @coordinator, @operator] do
        names = scope |> Catalog.visible() |> Enum.map(& &1.name)

        assert Enum.filter(names, &String.starts_with?(&1, "trust_")) -- @trust_tools == []

        assert {:rpc_error, -32_602, message} =
                 Catalog.call(scope, "trust_promote", %{
                   "subject" => @subject,
                   "to" => "probation",
                   "reason" => "clean"
                 })

        assert message =~ "Unknown tool"
      end
    end

    test "loop_pending_apply refuses a trust_promotion, operator proof or not", %{
      proposal: proposal
    } do
      for scope <- [@coordinator, @operator] do
        assert {:tool_error, message, "validation_error"} =
                 Catalog.call(scope, "loop_pending_apply", %{"id" => proposal.id})

        assert message =~ "operator-only"
        assert message =~ "arb trust promote"
      end

      assert tier_now() == :quarantine
      assert {:ok, %{state: :proposed}} = Loop.get_pending(proposal.id)
    end

    test "dismissing a suspension never raises the tier, whatever the suspension claims", %{
      record: record
    } do
      # The suspension's `prior_tier` is a record, not a grant: dismissal only
      # ends the overlay, and the subject's own rule (probation) stands.
      suspend!(record, "privileged")

      assert {:ok, %{dismissed: true, subject: detail}} =
               Catalog.call(@coordinator, "trust_dismiss", %{
                 "subject" => @subject,
                 "reason" => "false positive"
               })

      assert tier_now() == :probation
      assert detail.tier == "probation"
    end

    test "a workspace subject cap cannot raise a tier either", %{ws: ws} do
      assert {:ok, _} =
               Catalog.call(@coordinator, "workspace_config_set", %{
                 "workspace" => ws.id,
                 "key" => "guardrails.subjects",
                 "value" => [%{"match" => %{"provider" => "codex"}, "max_tier" => "privileged"}]
               })

      {:ok, ws} = Ash.get(Arbiter.Tasks.Workspace, ws.id)

      assert %{tier: :quarantine} =
               Guardrails.effective(Guardrails.subject("codex", "gpt-5.1-codex"), ws)

      assert tier_now() == :quarantine
    end
  end
end
