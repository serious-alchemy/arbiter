defmodule Arbiter.Loop.ProposalsDifficultyFeedTest do
  @moduledoc """
  bd-druqc1 (R12, paced-quota-routing-signals §3.2): cells with a high
  "difficulty raised" rate become `:difficulty_override` proposals through the
  Loop's PendingWrite flow. Proposals only; the layer off changes nothing.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.{Apply, PendingWrite, Proposals, Report}

  defp report, do: struct(Report, [])

  defp task(i, raised?, attrs \\ %{}) do
    Map.merge(
      %{
        task_id: "bd-t#{i}",
        provider: "claude",
        model: "claude-haiku-4-5",
        difficulty: 2,
        issue_type: "feature",
        weight: 1.0,
        difficulty_raised?: raised?,
        reviewed?: false,
        first_round_approved?: nil,
        review_rounds: 0,
        fix_passes: 0,
        attempts: 1,
        hours_to_close: nil,
        cost_usd: nil,
        runs: %{},
        draw: %{}
      },
      attrs
    )
  end

  # 10 tasks (the ladder's min n), `raised` of them corrected upward.
  defp cell_tasks(raised, attrs \\ %{}) do
    for i <- 1..10, do: task(i, i <= raised, attrs)
  end

  defp feed(tasks), do: Proposals.candidates(report(), difficulty_cells: tasks)

  test "no feed input: candidates are exactly what they were (layer off)" do
    assert Proposals.candidates(report()) == []
    assert Proposals.candidates(report(), difficulty_cells: []) == []
  end

  test "a cell with a high raised rate and n >= min_n yields a fleet :difficulty_override" do
    assert [c] = feed(cell_tasks(5))
    assert c.kind == :difficulty_override
    assert c.scope == :fleet
    assert c.difficulty == 2
    assert c.payload["cell"]["model"] == "claude-haiku-4-5"
    assert c.payload["n"] == 10
    assert_in_delta c.payload["difficulty_raised_rate"], 0.5, 1.0e-9
    assert c.payload["reason"] == "raised_rate"
    assert Enum.sort(c.task_refs) == Enum.sort(for i <- 1..5, do: "bd-t#{i}")
  end

  test "low-rate and under-sampled cells yield nothing" do
    assert feed(cell_tasks(1)) == []
    assert feed(Enum.take(cell_tasks(10), 9)) == []
  end

  test "the feed's payload is never auto-applicable (no task_id)" do
    [c] = feed(cell_tasks(6))

    assert {:error, _} =
             Apply.payload_ready?(%PendingWrite{kind: :difficulty_override, payload: c.payload})
  end

  test "record_all persists it as a pending, unapplied row" do
    {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "feed-ws", prefix: "feed"})

    %{rows: rows, dropped: []} =
      Proposals.record_all(report(), workspace_id: ws.id, difficulty_cells: cell_tasks(5))

    assert [row] = rows
    assert row.kind == :difficulty_override
    refute row.state == :applied
    assert row.applied_at == nil

    # Re-running over the same evidence reinforces rather than duplicating.
    %{rows: [again]} =
      Proposals.record_all(report(), workspace_id: ws.id, difficulty_cells: cell_tasks(5))

    assert again.id == row.id
    assert length(Ash.read!(PendingWrite)) == 1
  end
end
