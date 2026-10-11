defmodule Arbiter.Loop.ProposalsCompetenceMatrixTest do
  @moduledoc """
  bd-d5rdsc (R13, paced-quota-routing-signals §3.3, §11): `SubjectStats`
  measurements become `:competence_matrix` PendingWrites through the Loop's
  proposal flow. Proposals only; the layer off changes nothing.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Routing.Competence
  alias Arbiter.Loop.{Apply, PendingWrite, Proposals, Report}
  alias Arbiter.Settings

  defp report, do: struct(Report, [])

  defp task(i, attrs) do
    Map.merge(
      %{
        task_id: "bd-t#{i}",
        provider: "claude",
        model: "claude-sonnet-5-5",
        difficulty: 1,
        issue_type: "feature",
        weight: 1.0,
        difficulty_raised?: false,
        reviewed?: true,
        first_round_approved?: true,
        review_rounds: 1,
        fix_passes: 0,
        attempts: 1,
        hours_to_close: 1.0,
        cost_usd: 0.5,
        runs: %{},
        draw: %{}
      },
      attrs
    )
  end

  # 10 tasks (the ladder's min n) in one cell; every one needed `review_rounds`
  # review rounds, far above any live row's figure.
  defp cell(attrs \\ %{}), do: for(i <- 1..10, do: task(i, attrs))

  defp feed(tasks, opts \\ []),
    do: Proposals.candidates(report(), [competence_cells: tasks] ++ opts)

  test "no feed input: candidates are exactly what they were (layer off)" do
    assert Proposals.candidates(report()) == []
    assert Proposals.candidates(report(), competence_cells: []) == []
  end

  test "a measured cell the live matrix has no row for yields a fleet :competence_matrix" do
    assert [c] = feed(cell(%{model: "claude-fable-9", review_rounds: 3, attempts: 2}))
    assert c.kind == :competence_matrix
    assert c.scope == :fleet
    assert c.difficulty == 1
    assert c.category == "competence matrix D1"
    assert c.payload["difficulty"] == 1
    assert [row] = c.payload["rows"]

    assert row["match"] == %{
             "provider" => "claude",
             "model" => "claude-fable-9",
             "difficulty" => 1
           }

    assert row["review_runs"] == 3.0
    assert row["author_runs"] == 2.0
    assert length(c.task_refs) == 10
  end

  test "under-sampled cells yield nothing" do
    assert feed(Enum.take(cell(%{model: "claude-fable-9"}), 9)) == []
  end

  test "a cell matching the live row within the thresholds yields nothing" do
    live = [
      %{
        "match" => %{"provider" => "claude", "model" => "claude-sonnet-5-5", "difficulty" => 1},
        "author_runs" => 1.0,
        "review_runs" => 1.0,
        "round_1_approve" => 1.0
      }
    ]

    assert feed(cell(), competence_rows: live) == []
  end

  test "a cell whose figures moved beyond the threshold against its live row yields a proposal" do
    live = [
      %{
        "match" => %{"provider" => "claude", "model" => "claude-sonnet-5-5", "difficulty" => 1},
        "author_runs" => 1.0,
        "review_runs" => 1.0,
        "round_1_approve" => 1.0
      }
    ]

    tasks = cell(%{review_rounds: 2, first_round_approved?: false})
    assert [c] = feed(tasks, competence_rows: live)
    assert c.baseline =~ "claude/claude-sonnet-5-5"
  end

  test "one proposal per difficulty" do
    tasks =
      cell(%{model: "claude-fable-9", difficulty: 0}) ++
        for(i <- 11..20, do: task(i, %{model: "claude-fable-9", difficulty: 2}))

    assert [d0, d2] = feed(tasks)
    assert {d0.difficulty, d2.difficulty} == {0, 2}
  end

  test "the proposal's payload is ready to apply" do
    [c] = feed(cell(%{model: "claude-fable-9"}))
    assert :ok = Apply.payload_ready?(%PendingWrite{kind: :competence_matrix, payload: c.payload})

    assert {:error, _} =
             Apply.payload_ready?(%PendingWrite{kind: :competence_matrix, payload: %{}})

    assert {:error, _} =
             Apply.payload_ready?(%PendingWrite{
               kind: :competence_matrix,
               payload: %{"rows" => [%{"no_match" => 1}]}
             })
  end

  test "record_all persists a :proposed row that reinforces rather than duplicates" do
    {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "cm-ws", prefix: "cmw"})
    tasks = cell(%{model: "claude-fable-9"})

    %{rows: [row], dropped: []} =
      Proposals.record_all(report(), workspace_id: ws.id, competence_cells: tasks)

    assert row.kind == :competence_matrix
    assert row.state == :proposed
    assert row.applied_at == nil
    assert row.context_cost_tokens == 0

    %{rows: [again]} =
      Proposals.record_all(report(), workspace_id: ws.id, competence_cells: tasks)

    assert again.id == row.id
    assert length(Ash.read!(PendingWrite)) == 1
  end

  test "applying merges the rows into the live matrix and keeps the previous one" do
    {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "cm-ws2", prefix: "cmx"})

    %{rows: [row]} =
      Proposals.record_all(report(),
        workspace_id: ws.id,
        competence_cells: cell(%{model: "claude-fable-9", review_rounds: 3})
      )

    assert Settings.competence_matrix() in [nil, []]
    assert {:ok, applied} = Arbiter.Loop.apply_pending(row.id, actor: "op")
    assert applied.state == :applied

    assert [live] = Settings.competence_matrix()
    assert live["match"]["model"] == "claude-fable-9"
    assert Settings.competence_matrix_previous() == []

    found =
      Competence.lookup(Competence.rows(), %{
        provider: "claude",
        model: "claude-fable-9",
        difficulty: 1
      })

    assert found.rung == 1
    assert found.review_runs == 3.0
  end

  test "merge_competence_rows replaces a row with the same match and keeps the others" do
    a = %{"match" => %{"provider" => "claude", "model" => "m-a", "difficulty" => 1}, "n" => 1}
    b = %{"match" => %{"provider" => "claude", "model" => "m-b", "difficulty" => 1}, "n" => 1}
    {:ok, _} = Settings.set_competence_matrix([a, b])

    {:ok, merged} = Settings.merge_competence_rows([Map.put(a, "n", 2)])
    assert Enum.sort_by(merged, & &1["match"]["model"]) == [Map.put(a, "n", 2), b]
    assert Settings.competence_matrix_previous() == [a, b]
  end
end
