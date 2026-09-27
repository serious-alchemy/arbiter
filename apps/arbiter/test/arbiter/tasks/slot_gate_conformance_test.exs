defmodule Arbiter.Tasks.SlotGateConformanceTest do
  @moduledoc """
  bd-aw2cyt: there is one answer to "how many slots are free", and the board
  does not keep a second copy of it.

  The Conductor used to be a second dispatcher with its own slot arithmetic,
  and this file pinned the two together. #1965 deleted it, so the pairing that
  matters now is the board's rendered `slots_free` (tickets In progress,
  bd-asxw4e) and `agents_live` (live agent sessions, unchanged since
  bd-aw2cyt) against
  the shared predicates in `Arbiter.Tasks.SlotGate` — the things
  `Board.Autopilot` gates a new dispatch on. If `derive/1` ever grows its own
  rule again, these worlds catch it.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.SlotGate

  @now ~U[2026-09-16 22:25:00Z]

  defp worker(task_id, status, attrs) do
    Map.merge(
      %{
        task_id: task_id,
        registry_key: task_id,
        status: status,
        role: nil,
        workspace_id: "ws-1",
        current_step: :implement,
        started_at: @now,
        step_started_at: @now,
        mr_ref: nil,
        merger_url: nil,
        agent_live: false,
        meta: %{}
      },
      attrs
    )
  end

  # Every shape the ticket names, plus the ones that used to be counted wrong.
  defp worlds do
    [
      {"empty", []},
      {"author with a live agent", [worker("bd-1", :running, %{agent_live: true})]},
      {"author whose agent exited", [worker("bd-1", :running, %{agent_live: false})]},
      {":awaiting with no agent", [worker("bd-1", :awaiting, %{agent_live: false})]},
      {":awaiting_review with no agent",
       [worker("bd-1", :awaiting_review, %{agent_live: false})]},
      {"liveness unknown", [Map.delete(worker("bd-1", :running, %{}), :agent_live)]},
      {"author quiet under a live reviewer",
       [
         worker("bd-1", :awaiting_review_gate, %{agent_live: false}),
         worker("bd-1#review", :running, %{
           role: :reviewer,
           agent_live: true,
           meta: %{role: :reviewer, reviews: "bd-1"}
         })
       ]},
      {"implementer round",
       [
         worker("bd-1", :awaiting_review_gate, %{agent_live: false}),
         worker("bd-1#review#impl1", :running, %{
           role: :implementer,
           agent_live: true,
           meta: %{role: :implementer, revises: "bd-1"}
         })
       ]},
      {"CI fix pass beside a second author",
       [
         worker("bd-1", :awaiting_review, %{agent_live: false}),
         worker("bd-1", :running, %{
           registry_key: "bd-1:fixpass",
           role: :fix_pass,
           agent_live: true,
           meta: %{role: :fix_pass}
         }),
         worker("bd-2", :running, %{agent_live: true})
       ]},
      {"conflict resolver",
       [
         worker("bd-1", :awaiting_review, %{agent_live: false}),
         worker("bd-1", :running, %{
           registry_key: "bd-1:conflict",
           role: :conflict_resolver,
           agent_live: true,
           meta: %{role: :conflict_resolver}
         })
       ]}
    ]
  end

  defp ticket(id, state) do
    %{
      id: id,
      title: "Task #{id}",
      state: state,
      status: Arbiter.Tasks.Lifecycle.legacy_fields(state).status,
      priority: 2,
      issue_type: :task,
      workspace_id: "ws-1",
      refined: state != :backlog,
      created_at: @now,
      updated_at: @now,
      closed_at: nil
    }
  end

  # bd-asxw4e: the tickets beside each worker world — bd-1 in every state, and
  # a second ticket In progress or not.
  defp ticket_worlds do
    for state <- Arbiter.Tasks.Lifecycle.states(), other <- [:active, :queued] do
      {"bd-1 #{state}, bd-2 #{other}", [ticket("bd-1", state), ticket("bd-2", other)]}
    end
  end

  for basis <- [:agents, :issues] do
    test "the board's slot arithmetic is SlotGate's, under #{basis}" do
      basis = unquote(basis)

      for {name, workers} <- worlds(),
          {ticket_name, tickets} <- ticket_worlds(),
          total <- [0, 1, 2, 4] do
        name = "#{name} / #{ticket_name}"

        board =
          Snapshot.derive(%{
            issues: tickets,
            workers: workers,
            blocked_by: %{},
            changed_files: %{},
            now: @now,
            slots_total: total,
            slot_basis: basis,
            quota: :ok,
            paused: false
          })

        assert board.slots_free == SlotGate.slots_free(total, tickets),
               "board disagrees with SlotGate on free slots for #{name} (total=#{total}, basis=#{basis})"

        assert board.slots_used == SlotGate.slots_used(tickets),
               "board disagrees with SlotGate on tickets In progress for #{name} (total=#{total}, basis=#{basis})"

        assert board.agents_live == SlotGate.occupied(workers, basis),
               "board disagrees with SlotGate on agent occupancy for #{name} (total=#{total}, basis=#{basis})"

        refute board.slots_free < 0
      end
    end
  end

  test "a cap full of tickets In progress leaves nothing to promote, and a merging one does not" do
    ready = %{
      id: "bd-ready",
      title: "Ready",
      status: :open,
      priority: 1,
      difficulty: 2,
      issue_type: :task,
      workspace_id: "ws-1",
      refined: true,
      description: nil,
      acceptance: nil,
      notes: nil,
      created_at: @now,
      updated_at: @now,
      closed_at: nil
    }

    common = %{
      issues: [ready],
      blocked_by: %{},
      changed_files: %{},
      now: @now,
      slots_total: 1,
      slot_basis: :agents,
      quota: :ok,
      paused: false
    }

    # bd-asxw4e: an In progress ticket holds its slot with or without a live
    # agent; once it is Merging, the slot is free whatever worker lingers.
    for agent_live <- [true, false] do
      held =
        common
        |> Map.put(:issues, [ready, ticket("bd-1", :active)])
        |> Map.put(:workers, [worker("bd-1", :running, %{agent_live: agent_live})])
        |> Snapshot.derive()

      assert held.slots_free == 0
      assert held.promote == nil
    end

    merging =
      common
      |> Map.put(:issues, [ready, ticket("bd-1", :merging)])
      |> Map.put(:workers, [worker("bd-1", :awaiting_review, %{agent_live: false})])
      |> Snapshot.derive()

    assert merging.slots_free == 1
    assert merging.promote == ready.id
  end
end
