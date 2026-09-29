defmodule Arbiter.Board.SnapshotSlotsTest do
  @moduledoc """
  bd-aw2cyt: a slot is a live agent session in any role, not an author record
  in a live run state, and a card names the phase it is actually in.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-09-16 22:25:00Z]

  defp issue(id, attrs) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        status: :open,
        priority: 2,
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
      },
      attrs
    )
  end

  # An author worker snapshot in one of its run's states. `:question` and
  # `:review_gate` are a `:waiting` run and what it waits on; `:succeeded` and
  # `:failed` are a finished run's outcome.
  defp author(task_id, state, attrs) do
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

  defp run_fields(outcome) when outcome in [:succeeded, :failed],
    do: %{state: :finished, waiting_on: nil, outcome: outcome}

  defp run_fields(state), do: %{state: state, waiting_on: nil, outcome: nil}

  defp reviewer(of, attrs) do
    Map.merge(
      author(of <> "#review", :working, %{
        role: :reviewer,
        meta: %{role: :reviewer, reviews: of}
      }),
      attrs
    )
  end

  defp implementer(of, attrs) do
    Map.merge(
      author(of <> "#review#impl1", :working, %{
        role: :implementer,
        meta: %{role: :implementer, revises: of}
      }),
      attrs
    )
  end

  defp fix_pass(of, attrs) do
    Map.merge(
      author(of, :working, %{
        registry_key: of <> ":fixpass",
        role: :fix_pass,
        meta: %{role: :fix_pass}
      }),
      attrs
    )
  end

  defp conflict(of, attrs) do
    Map.merge(
      author(of, :working, %{
        registry_key: of <> ":conflict",
        role: :conflict_resolver,
        meta: %{role: :conflict_resolver}
      }),
      attrs
    )
  end

  defp derive(overrides) do
    Snapshot.derive(
      Map.merge(
        %{
          issues: [],
          workers: [],
          blocked_by: %{},
          changed_files: %{},
          now: @now,
          slots_total: 4,
          quota: :ok,
          paused: false
        },
        Map.new(overrides)
      )
    )
  end

  defp card(board, column, id) do
    board |> Map.fetch!(column) |> Enum.find(&(&1.id == id))
  end

  describe "agents_live is live agents, not records" do
    test "an author record whose agent has exited holds no live-agent count" do
      # vs-8iqckq on 2026-09-16: a working run record, no process anywhere.
      board = derive(slots_total: 2, workers: [author("bd-1", :working, %{agent_live: false})])

      assert board.agents_live == 0
    end

    test "every live role takes a live-agent count of its own" do
      workers = [
        author("bd-1", :review_gate, %{agent_live: false}),
        reviewer("bd-1", %{agent_live: true}),
        # bd-2's author run finished when it opened its PR (bd-741sid).
        author("bd-2", :succeeded, %{agent_live: false}),
        fix_pass("bd-2", %{agent_live: true}),
        author("bd-3", :working, %{agent_live: true})
      ]

      board = derive(slots_total: 5, workers: workers)

      assert board.agents_live == 3
    end

    test "an implementer round and a conflict resolver each count, but fold into their author's one slot" do
      workers = [
        author("bd-1", :review_gate, %{agent_live: false}),
        implementer("bd-1", %{agent_live: true}),
        author("bd-2", :succeeded, %{agent_live: false}),
        conflict("bd-2", %{agent_live: true})
      ]

      board = derive(slots_total: 4, workers: workers)

      assert board.agents_live == 2
    end
  end

  describe "bd-asxw4e: a slot is a ticket In progress" do
    test "a :merging ticket holds no slot, even with a live CI fix pass on it" do
      board =
        derive(
          slots_total: 1,
          issues: [
            issue("bd-1", %{state: :merging, status: :in_progress, pr_ref: "https://pr/1"}),
            issue("bd-ready", %{state: :queued})
          ],
          workers: [fix_pass("bd-1", %{agent_live: true})]
        )

      assert board.slots_used == 0
      assert board.slots_free == 1
      assert board.promote == "bd-ready"
    end

    test "an :active ticket between ReviewGate rounds with no live agent holds one slot" do
      # The bd-45pwo1 shape: no reviewer / implementer / fix pass live, the
      # author between rounds — and now even no worker row at all.
      for workers <- [[author("bd-1", :working, %{agent_live: false})], []] do
        board =
          derive(
            slots_total: 1,
            issues: [
              issue("bd-1", %{state: :active, status: :in_progress}),
              issue("bd-ready", %{state: :queued})
            ],
            workers: workers
          )

        assert board.agents_live == 0
        assert board.slots_used == 1
        assert board.slots_free == 0
        assert board.promote == nil
      end
    end

    test "a :verifying ticket holds none" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-1", %{state: :verifying, status: :awaiting_verification})]
        )

      assert board.slots_used == 0
      assert board.slots_free == 1
    end

    test "an :active ticket parked on a human keeps its slot" do
      board =
        derive(
          slots_total: 2,
          issues: [issue("bd-1", %{state: :active, status: :in_progress})],
          workers: [author("bd-1", :failed, %{agent_live: false})]
        )

      assert board.slots_used == 1
    end

    test "worker rows alone hold nothing: the count is read off the tickets" do
      board = derive(slots_total: 2, workers: [author("bd-1", :working, %{agent_live: true})])

      assert board.agents_live == 1
      assert board.slots_used == 0
    end

    test "tickets forced over the cap never report negative free slots" do
      issues =
        for id <- ~w(bd-1 bd-2 bd-3), do: issue(id, %{state: :active, status: :in_progress})

      board = derive(slots_total: 1, issues: issues)

      assert board.slots_used == 3
      assert board.slots_free == 0
    end
  end

  describe "slot_basis" do
    @tag :slot_basis
    test ":issues restores the pre-bd-aw2cyt record-based agents-live count" do
      workers = [
        author("bd-1", :working, %{agent_live: false}),
        author("bd-2", :question, %{agent_live: false}),
        reviewer("bd-1", %{agent_live: true})
      ]

      agents = derive(slots_total: 4, workers: workers, slot_basis: :agents)
      issues = derive(slots_total: 4, workers: workers, slot_basis: :issues)

      assert agents.agents_live == 1
      assert issues.agents_live == 2
      # The cap is counted in tickets under either basis.
      assert agents.slots_used == 0
      assert issues.slots_used == 0
    end
  end

  describe "phase on the card" do
    test "a live main agent is :implementing" do
      board = derive(workers: [author("bd-1", :working, %{agent_live: true})])

      assert %{phase: :implementing, agent_live: true} = card(board, :in_progress, "bd-1")
    end

    test "a live reviewer makes the author's card read :in_review" do
      board =
        derive(
          workers: [
            author("bd-1", :review_gate, %{agent_live: false}),
            reviewer("bd-1", %{agent_live: true})
          ]
        )

      assert %{phase: :in_review, agent_live: true} = card(board, :in_progress, "bd-1")
    end

    test "a live implementer round reads :addressing_review" do
      board =
        derive(
          workers: [
            author("bd-1", :review_gate, %{agent_live: false}),
            implementer("bd-1", %{agent_live: true})
          ]
        )

      assert %{phase: :addressing_review} = card(board, :in_progress, "bd-1")
    end

    # bd-741sid: no worker stays resident on an open PR — the Merging ticket
    # itself carries the card.
    test "an open MR with nothing running reads :waiting_ci_merge, and no live agent" do
      board =
        derive(issues: [issue("bd-1", %{state: :merging, status: :in_progress, pr_ref: "#1"})])

      assert %{phase: :waiting_ci_merge, agent_live: false} = card(board, :merging, "bd-1")
    end

    test "a live CI fix pass reads :fixing_ci on the In progress card" do
      # The author's run finished when it opened its PR; the fix pass is the
      # only thing live under the ticket.
      board =
        derive(
          workers: [
            author("bd-1", :succeeded, %{agent_live: false}),
            fix_pass("bd-1", %{agent_live: true})
          ]
        )

      assert %{phase: :fixing_ci, agent_live: true} = card(board, :in_progress, "bd-1")
    end

    test "a question reads :waiting_on_you" do
      board = derive(workers: [author("bd-1", :question, %{agent_live: false})])

      assert %{phase: :waiting_on_you, agent_live: false} = card(board, :in_progress, "bd-1")
    end

    # bd-741sid: the phase names the stage and the card's liveness says whether
    # an agent is behind it — the hand-off phase is gone, and a record between
    # agents only exists for a moment now that every worker stops with its agent.
    test "a running record with no agent is visibly distinguished by its liveness" do
      board = derive(workers: [author("bd-1", :working, %{agent_live: false})])

      c = card(board, :in_progress, "bd-1")
      assert c.agent_live == false
      assert c.phase == :implementing
    end
  end
end
