defmodule Arbiter.ReleaseCompetenceMatrixTest do
  @moduledoc """
  bd-dde4l7: the candidate competence matrix's operator workflow through
  `Arbiter.Release` — seed a candidate, promote it (keeping the old live
  matrix for rollback) or discard it.
  """
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureIO

  alias Arbiter.Release
  alias Arbiter.Settings

  defp task(id, provider, model, difficulty) do
    %{
      task_id: id,
      provider: provider,
      model: model,
      difficulty: difficulty,
      issue_type: "feature",
      attempts: 1,
      review_rounds: 2,
      fix_passes: 1,
      reviewed?: true,
      first_round_approved?: true,
      difficulty_raised?: false,
      hours_to_close: 2.0,
      cost_usd: 5.0
    }
  end

  defp seed(opts, provider, model, difficulty) do
    tasks = for i <- 1..5, do: task("#{provider}-#{i}", provider, model, difficulty)

    capture_io(fn ->
      send(
        self(),
        {:seeded, Release.seed_competence_matrix([start: false, tasks: tasks, min_n: 5] ++ opts)}
      )
    end)

    assert_received {:seeded, {:ok, rows}}
    rows
  end

  test "seed_competence_matrix/1 writes the live matrix by default, the candidate on request" do
    live = seed([], "claude", "claude-sonnet-5", 2)
    assert Settings.competence_matrix() == live
    assert Settings.competence_matrix_candidate() == nil

    candidate = seed([target: :candidate], "codex", "gpt-5", 3)
    assert candidate != live
    assert Settings.competence_matrix() == live
    assert Settings.competence_matrix_candidate() == candidate
  end

  test "promote_candidate_matrix/1 makes the candidate live and keeps the previous live matrix" do
    live = seed([], "claude", "claude-sonnet-5", 2)
    candidate = seed([target: :candidate], "codex", "gpt-5", 3)

    out =
      capture_io(fn ->
        assert {:ok, ^candidate} = Release.promote_candidate_matrix(start: false)
      end)

    assert out =~ "promoted"

    assert Settings.competence_matrix() == candidate
    assert Settings.competence_matrix_previous() == live
    assert Settings.competence_matrix_candidate() == nil
  end

  test "promote_candidate_matrix/1 with no candidate errors and leaves the live matrix" do
    live = seed([], "claude", "claude-sonnet-5", 2)

    capture_io(:stderr, fn ->
      assert {:error, :no_candidate} = Release.promote_candidate_matrix(start: false)
    end)

    assert Settings.competence_matrix() == live
  end

  test "discard_candidate_matrix/1 removes the candidate and leaves the live matrix" do
    live = seed([], "claude", "claude-sonnet-5", 2)
    seed([target: :candidate], "codex", "gpt-5", 3)

    capture_io(fn -> assert :ok = Release.discard_candidate_matrix(start: false) end)

    assert Settings.competence_matrix_candidate() == nil
    assert Settings.competence_matrix() == live
    assert Settings.competence_matrix_previous() == nil
  end

  test "rollback_competence_matrix/1 restores the matrix a promotion replaced" do
    live = seed([], "claude", "claude-sonnet-5", 2)
    seed([target: :candidate], "codex", "gpt-5", 3)
    capture_io(fn -> Release.promote_candidate_matrix(start: false) end)

    capture_io(fn -> assert {:ok, ^live} = Release.rollback_competence_matrix(start: false) end)
    assert Settings.competence_matrix() == live
  end
end
