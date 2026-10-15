defmodule Arbiter.Workers.CurrentCiWaitTest do
  @moduledoc """
  bd-3726k8: a ReviewGate in the pre-review CI wait has no agent and no round,
  so its author read "in review — no live agent", the look of a hung gate. The
  ticket's `ci_wait` marker names what it is doing; `worker list` / `worker show`
  carry it as `ci_wait_label`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.ReviewCi
  alias Arbiter.Workers.{Current, Serializer}

  @sha "210c215f0123456789abcdef0123456789abcdef"

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "cw-ws-#{System.unique_integer([:positive])}", prefix: "cw"})

    {:ok, ticket} = Ash.create(Issue, %{title: "waits on CI", workspace_id: ws.id})
    %{ticket: ticket}
  end

  defp author(ticket, attrs) do
    Map.merge(
      %{
        task_id: ticket.id,
        registry_key: ticket.id,
        role: nil,
        workspace_id: ticket.workspace_id,
        kind: :implement,
        state: :waiting,
        outcome: nil,
        waiting_on: :review_gate,
        agent_live: false,
        started_at: DateTime.utc_now(),
        run_id: nil,
        meta: %{}
      },
      attrs
    )
  end

  defp mark_waiting(ticket, polls) do
    marker =
      ReviewCi.marker(@sha, 1, %{interval_ms: 60_000, max_polls: 30}, %{
        "polls" => polls,
        "max_polls" => 30
      })

    ReviewCi.put_marker(ticket.id, marker)
  end

  test "an author waiting on the gate's CI wait reads as awaiting CI, with the poll count",
       %{ticket: ticket} do
    mark_waiting(ticket, 7)

    assert %{current: %{phase: :in_review, ci_wait_label: label} = view} =
             Current.show(ticket.id, live: [author(ticket, %{})])

    assert label == "awaiting CI on 210c215f (poll 7/30)"
    assert Serializer.summary(view, nil).ci_wait_label == label
    assert [%{ci_wait_label: ^label}] = Current.list(live: [author(ticket, %{})])
  end

  test "no marker, no label: a gate in review stays 'in review'", %{ticket: ticket} do
    assert %{current: %{ci_wait_label: nil}} =
             Current.show(ticket.id, live: [author(ticket, %{})])
  end

  test "a live agent keeps its own phase even with a stale marker", %{ticket: ticket} do
    mark_waiting(ticket, 2)

    assert %{current: %{ci_wait_label: nil}} =
             Current.show(ticket.id, live: [author(ticket, %{agent_live: true})])
  end

  test "progress_label leaves off the poll count for a marker written without one" do
    assert ReviewCi.progress_label(%{sha: @sha}) == "awaiting CI on 210c215f"
  end
end
