defmodule Arbiter.Workers.CurrentFinishedTest do
  @moduledoc """
  bd-2j64q6: a finished run the worker still holds (a ReviewGate-parked
  author) read as `completed_at: nil` and kept the last thing its agent said
  — "wrapping up" — in `activity`, so `worker_list` / `worker_show` looked as
  if the gate had not finished.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.{Current, Run}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "cur-ws-#{System.unique_integer([:positive])}", prefix: "cu"})

    {:ok, ticket} = Ash.create(Issue, %{title: "parked by the gate", workspace_id: ws.id})
    %{ws: ws, ticket: ticket}
  end

  defp run_row(ticket, ws, attrs) do
    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: ticket.id,
          repo: "arbiter",
          workspace_id: ws.id,
          kind: :implement,
          state: :finished,
          outcome: :failed,
          role: "base",
          started_at: DateTime.add(DateTime.utc_now(), -600, :second),
          completed_at: DateTime.add(DateTime.utc_now(), -60, :second)
        },
        attrs
      )
    )
  end

  defp snapshot(ticket, run, attrs) do
    Map.merge(
      %{
        task_id: ticket.id,
        registry_key: ticket.id,
        role: nil,
        workspace_id: ticket.workspace_id,
        kind: :implement,
        state: :finished,
        outcome: :failed,
        waiting_on: nil,
        agent_live: false,
        started_at: run.started_at,
        run_id: run.id,
        meta: %{activity: "wrapping up", failure_reason: :review_gate_rejected}
      },
      attrs
    )
  end

  test "a finished live run carries its row's completed_at and a finished activity", %{
    ws: ws,
    ticket: ticket
  } do
    run = run_row(ticket, ws, %{})
    live = [snapshot(ticket, run, %{})]

    assert %{completed_at: completed_at, meta: meta, source: :live} =
             Current.current_run(ticket.id, live)

    assert completed_at == run.completed_at
    assert meta.activity == "finished (failed)"
    assert meta.failure_reason == :review_gate_rejected
  end

  test "a run that is still working keeps its agent's activity and no completed_at", %{
    ws: ws,
    ticket: ticket
  } do
    run = run_row(ticket, ws, %{state: :working, outcome: nil, completed_at: nil})
    live = [snapshot(ticket, run, %{state: :working, outcome: nil})]

    assert %{completed_at: nil, meta: %{activity: "wrapping up"}} =
             Current.current_run(ticket.id, live)
  end
end
