defmodule Arbiter.Board.SnapshotSevenColumnsTest do
  @moduledoc """
  bd-79w1fs: the seven-column board. Every ticket lands in the column
  `Arbiter.Tasks.Lifecycle.view/2` gives it, carries that column's detail, and
  every ticket with attention is also listed for the Needs-attention swimlane.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-08-22 12:00:00Z]
  @earlier ~U[2026-08-22 09:00:00Z]

  defp issue(id, attrs) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        rank: 1024,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        created_at: @earlier,
        updated_at: @earlier,
        closed_at: nil
      },
      attrs
    )
  end

  defp worker(task_id, state, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: task_id,
        workspace_id: "ws-1",
        current_step: :implement,
        started_at: @earlier,
        step_started_at: @earlier,
        mr_ref: nil,
        merger_url: nil,
        meta: %{},
        state: state,
        waiting_on: if(state == :waiting, do: :question),
        outcome: nil
      },
      attrs
    )
  end

  defp derive(overrides) do
    Snapshot.derive(
      Map.merge(
        %{issues: [], workers: [], blocked_by: %{}, now: @now, slots_total: 4, quota: :ok},
        Map.new(overrides)
      )
    )
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)

  # One ticket per lifecycle column.
  defp fleet do
    [
      issue("bd-backlog", %{state: :backlog}),
      issue("bd-blocked", %{state: :queued}),
      issue("bd-ready", %{state: :queued}),
      issue("bd-active", %{state: :active}),
      issue("bd-merging", %{
        state: :merging,
        pr_ref: "!42",
        merger_status: %{"status" => "open", "approved" => false, "pipeline" => "running"}
      }),
      issue("bd-verifying", %{state: :verifying}),
      issue("bd-closed", %{
        state: :closed,
        close_reason: :wont_do,
        closed_at: ~U[2026-08-22 11:00:00Z]
      })
    ]
  end

  defp fleet_board do
    derive(
      issues: fleet(),
      workers: [worker("bd-active", :working)],
      blocked_by: %{"bd-blocked" => ["bd-ready"]},
      watchdog_live: MapSet.new(["bd-merging"])
    )
  end

  describe "seven columns" do
    test "every ticket lands in its lifecycle column, and only there" do
      board = fleet_board()

      assert ids(board.backlog) == ["bd-backlog"]
      assert ids(board.blocked) == ["bd-blocked"]
      assert ids(board.ready) == ["bd-ready"]
      assert ids(board.in_progress) == ["bd-active"]
      assert ids(board.merging) == ["bd-merging"]
      assert ids(board.verifying) == ["bd-verifying"]
      assert ids(board.closed_today) == ["bd-closed"]

      refute Map.has_key?(board, :running)
      refute Map.has_key?(board, :waiting)
    end

    test "empty/1 has all seven columns and an empty swimlane" do
      board = Snapshot.empty(@now)

      for key <- [:backlog, :blocked, :ready, :in_progress, :merging, :verifying, :closed_today] do
        assert Map.fetch!(board, key) == []
      end

      assert board.attention == []
    end

    test "epics stay off every column" do
      board =
        derive(
          issues: [
            issue("bd-epic", %{issue_type: :epic, state: :queued}),
            issue("bd-epic2", %{issue_type: :epic, state: :backlog})
          ]
        )

      assert board.backlog == [] and board.ready == [] and board.blocked == []
    end
  end

  describe "card detail" do
    test "a Blocked card carries the ids it waits on, and is not in the scheduler's queue" do
      board =
        derive(
          issues: [issue("bd-b", %{state: :queued}), issue("bd-r", %{state: :queued})],
          blocked_by: %{"bd-b" => ["bd-9", "bd-3"]}
        )

      assert [%{id: "bd-b", blocked_by: ["bd-3", "bd-9"]}] = board.blocked
      assert [%{id: "bd-r", state: :next}] = board.ready
      assert board.promote == "bd-r"
    end

    test "In progress and Merging cards carry the computed step" do
      board = fleet_board()

      assert [%{step: :implementing}] = board.in_progress
      assert [%{step: :waiting_ci}] = board.merging
    end

    test "a Closed card carries its close_reason" do
      assert [%{close_reason: :wont_do}] = fleet_board().closed_today
    end

    test "a parked run keeps its ticket In progress, with the coordinator's attention" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active})],
          workers: [worker("bd-a", :waiting)]
        )

      assert [%{id: "bd-a", step: :implementing, attention: attention}] = board.in_progress
      assert %{owner: :coordinator, cause: :run_asked_question} = attention
    end

    test "an In-progress ticket with no run past the grace is still In progress" do
      board = derive(issues: [issue("bd-a", %{state: :active})])

      assert [%{id: "bd-a", attention: %{cause: :run_crashed}}] = board.in_progress
    end

    test "an In-progress ticket inside the dispatch grace is dispatching, with no attention" do
      board =
        derive(issues: [issue("bd-a", %{state: :active, updated_at: @now})])

      assert [%{id: "bd-a", activity: "dispatching", attention: nil}] = board.in_progress
    end
  end

  describe "manual order (priority, then rank)" do
    test "Backlog sorts by priority, then rank, then age" do
      board =
        derive(
          issues: [
            issue("bd-p2-late", %{state: :backlog, priority: 2, rank: 3000}),
            issue("bd-p1", %{state: :backlog, priority: 1, rank: 9000}),
            issue("bd-p2-early", %{state: :backlog, priority: 2, rank: 1000})
          ]
        )

      assert ids(board.backlog) == ["bd-p1", "bd-p2-early", "bd-p2-late"]
    end

    test "Ready is the scheduler's plan order: priority, then rank" do
      board =
        derive(
          issues: [
            issue("bd-c", %{priority: 2, rank: 3000}),
            issue("bd-a", %{priority: 1, rank: 9000}),
            issue("bd-b", %{priority: 2, rank: 1000})
          ]
        )

      assert ids(board.ready) == ["bd-a", "bd-b", "bd-c"]
      assert board.promote == "bd-a"
    end
  end

  describe "the Needs-attention swimlane" do
    test "every ticket with attention is listed with its column, owner and reason" do
      board =
        derive(
          issues: [
            issue("bd-v", %{state: :verifying}),
            issue("bd-m", %{
              state: :merging,
              attention_cause: :awaiting_manual_merge,
              attention_since: @earlier
            }),
            issue("bd-r", %{state: :queued})
          ],
          watchdog_live: MapSet.new(["bd-m"])
        )

      assert [operator, coordinator] = board.attention

      assert %{id: "bd-m", column: :merging, owner: :operator, reason: reason} = operator
      assert reason =~ "a person merges it"
      assert %{id: "bd-v", column: :verifying, owner: :coordinator} = coordinator

      # The card keeps its column and carries the attention too.
      assert [%{id: "bd-m", attention: %{owner: :operator}}] = board.merging
    end

    test "a ticket without attention is not in the swimlane" do
      assert derive(issues: [issue("bd-r", %{state: :queued})]).attention == []
    end
  end
end
