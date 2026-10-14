defmodule Arbiter.Tasks.ReviewGateNotConvergedAttentionTest do
  @moduledoc """
  bd-2j64q6: a ReviewGate that parks a ticket without converging is a gate
  decision for the coordinator, not a crashed run to resume — and a real crash
  keeps reading as `run_crashed`.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.EscalationKind
  alias Arbiter.Tasks.{Attention, AttentionSweep, Issue, Workspace}
  alias Arbiter.Workflows.ReviewGateFixRoundDispatcher

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rgnc-ws-#{System.unique_integer([:positive])}", prefix: "rg"})

    {:ok, ticket} = Ash.create(Issue, %{title: "gate parked", workspace_id: ws.id})
    %{ws: ws, ticket: put_state!(ticket, :active)}
  end

  defp attention(ticket) do
    Attention.current(Ash.get!(Issue, ticket.id), workers: [], now: DateTime.utc_now())
  end

  test "the owner table names a gate decision, not a resume" do
    row =
      Enum.find(
        Arbiter.Tasks.Lifecycle.Attention.table(),
        &(&1.cause == :review_gate_not_converged)
      )

    assert %{owner: :coordinator, waiting_on: :gate_decision} = row
    assert row.reason =~ "ReviewGate"
  end

  test "raising the cause reads as review_gate_not_converged with the finding as its reason",
       %{ticket: ticket} do
    detail = "VERDICT: REQUEST_CHANGES — [NEEDS-COORDINATOR] AC3 verifiable only after deploy"
    {:ok, _} = Attention.raise_cause(ticket.id, :review_gate_not_converged, detail)

    assert %{
             cause: :review_gate_not_converged,
             waiting_on: :gate_decision,
             owner: :coordinator,
             reason: ^detail
           } = attention(ticket)
  end

  test "the sweep promotes it as itself, never relabelling it run_crashed", %{ticket: ticket} do
    {:ok, _} = Attention.raise_cause(ticket.id, :review_gate_not_converged, "the finding")

    stale = DateTime.add(DateTime.utc_now(), -5 * 3600, :second)
    issue = Ash.get!(Issue, ticket.id)

    Ecto.Adapters.SQL.query!(
      Arbiter.Repo,
      "UPDATE issues SET attention_since = $1 WHERE id = $2",
      [stale, issue.id]
    )

    assert %{promoted: [promoted]} =
             AttentionSweep.run(workers: [], workspace_id: ticket.workspace_id)

    assert promoted == ticket.id

    assert %{cause: :review_gate_not_converged, waiting_on: :gate_decision, owner: :operator} =
             attention(ticket)
  end

  test "a genuine crash is still run_crashed / resume", %{ticket: ticket} do
    {:ok, _} = Attention.raise_cause(ticket.id, :run_crashed)
    assert %{cause: :run_crashed, waiting_on: :resume} = attention(ticket)
  end

  test "the exhausted-rounds escalation reaches the coordinator mailbox", %{
    ws: ws,
    ticket: ticket
  } do
    assert :ok =
             ReviewGateFixRoundDispatcher.escalate_exhausted(
               ticket.id,
               ws.id,
               0,
               :needs_coordinator
             )

    assert Enum.any?(
             Arbiter.Messages.Message.inbox("admiral", workspace_id: ws.id),
             &(&1.task_ref == ticket.id and &1.escalation_kind == :fix_rounds_exhausted)
           )

    assert :fix_rounds_exhausted in EscalationKind.ticket_kinds()
  end
end
