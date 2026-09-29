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

  # A worker snapshot in one of its run's states. `:question` and
  # `:review_gate` are a `:waiting` run and what it waits on; `:succeeded` is
  # a finished run (an author that opened its PR, bd-741sid).
  defp worker(task_id, state, attrs) do
    Map.merge(
      Map.merge(
        %{
          task_id: task_id,
          registry_key: task_id,
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
        run_fields(state)
      ),
      attrs
    )
  end

  defp run_fields(:question), do: %{state: :waiting, waiting_on: :question, outcome: nil}
  defp run_fields(:review_gate), do: %{state: :waiting, waiting_on: :review_gate, outcome: nil}
  defp run_fields(:succeeded), do: %{state: :finished, waiting_on: nil, outcome: :succeeded}
  defp run_fields(state), do: %{state: state, waiting_on: nil, outcome: nil}

  # Every shape the ticket names, plus the ones that used to be counted wrong.
  defp worlds do
    [
      {"empty", []},
      {"author with a live agent", [worker("bd-1", :working, %{agent_live: true})]},
      {"author whose agent exited", [worker("bd-1", :working, %{agent_live: false})]},
      {"waiting on a question with no agent", [worker("bd-1", :question, %{agent_live: false})]},
      {"finished author (PR opened) with no agent",
       [worker("bd-1", :succeeded, %{agent_live: false})]},
      {"liveness unknown", [Map.delete(worker("bd-1", :working, %{}), :agent_live)]},
      {"author quiet under a live reviewer",
       [
         worker("bd-1", :review_gate, %{agent_live: false}),
         worker("bd-1#review", :working, %{
           role: :reviewer,
           agent_live: true,
           meta: %{role: :reviewer, reviews: "bd-1"}
         })
       ]},
      {"implementer round",
       [
         worker("bd-1", :review_gate, %{agent_live: false}),
         worker("bd-1#review#impl1", :working, %{
           role: :implementer,
           agent_live: true,
           meta: %{role: :implementer, revises: "bd-1"}
         })
       ]},
      {"CI fix pass beside a second author",
       [
         worker("bd-1", :succeeded, %{agent_live: false}),
         worker("bd-1", :working, %{
           registry_key: "bd-1:fixpass",
           role: :fix_pass,
           agent_live: true,
           meta: %{role: :fix_pass}
         }),
         worker("bd-2", :working, %{agent_live: true})
       ]},
      {"conflict resolver",
       [
         worker("bd-1", :succeeded, %{agent_live: false}),
         worker("bd-1", :working, %{
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
      priority: 2,
      issue_type: :task,
      workspace_id: "ws-1",
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

  test "the board's slot arithmetic is SlotGate's" do
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
          quota: :ok,
          paused: false
        })

      assert board.slots_free == SlotGate.slots_free(total, tickets),
             "board disagrees with SlotGate on free slots for #{name} (total=#{total})"

      assert board.slots_used == SlotGate.slots_used(tickets),
             "board disagrees with SlotGate on tickets In progress for #{name} (total=#{total})"

      assert board.agents_live == SlotGate.occupied(workers),
             "board disagrees with SlotGate on agent occupancy for #{name} (total=#{total})"

      refute board.slots_free < 0
    end
  end

  test "a cap full of tickets In progress leaves nothing to promote, and a merging one does not" do
    ready = %{
      id: "bd-ready",
      title: "Ready",
      state: :queued,
      priority: 1,
      difficulty: 2,
      issue_type: :task,
      workspace_id: "ws-1",
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
      quota: :ok,
      paused: false
    }

    # bd-asxw4e: an In progress ticket holds its slot with or without a live
    # agent; once it is Merging, the slot is free whatever worker lingers.
    for agent_live <- [true, false] do
      held =
        common
        |> Map.put(:issues, [ready, ticket("bd-1", :active)])
        |> Map.put(:workers, [worker("bd-1", :working, %{agent_live: agent_live})])
        |> Snapshot.derive()

      assert held.slots_free == 0
      assert held.promote == nil
    end

    merging =
      common
      |> Map.put(:issues, [ready, ticket("bd-1", :merging)])
      |> Map.put(:workers, [worker("bd-1", :succeeded, %{agent_live: false})])
      |> Snapshot.derive()

    assert merging.slots_free == 1
    assert merging.promote == ready.id
  end
end
