defmodule Arbiter.SettingsCompetenceMatrixTest do
  @moduledoc """
  bd-biycyw (R6): install-wide storage for the competence matrix.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Settings

  describe "competence_matrix" do
    test "defaults to nil when unset" do
      assert Settings.competence_matrix() == nil
    end

    test "persists and updates the competence matrix" do
      rows = [
        %{
          "match" => %{
            "provider" => "antigravity",
            "model" => "gemini-3.8-flash-low",
            "difficulty" => 1
          },
          "n" => 13,
          "rung" => 1,
          "author_runs" => 2.69,
          "review_runs" => 1.69,
          "time_to_close_median_hours" => 1.1
        }
      ]

      assert {:ok, persisted} = Settings.set_competence_matrix(rows)
      assert persisted == rows
      assert Settings.competence_matrix() == rows

      # Clearing resets to nil.
      assert {:ok, nil} = Settings.set_competence_matrix(nil)
      assert Settings.competence_matrix() == nil
    end
  end

  describe "candidate matrix (bd-dde4l7)" do
    defp row(author_runs) do
      %{
        "match" => %{"provider" => "claude", "model" => "sonnet", "difficulty" => 2},
        "n" => 20,
        "rung" => 1,
        "author_runs" => author_runs,
        "review_runs" => 1.5,
        "time_to_close_median_hours" => 1.0
      }
    end

    test "candidate and previous default to nil and are independent of the live matrix" do
      assert Settings.competence_matrix_candidate() == nil
      assert Settings.competence_matrix_previous() == nil

      {:ok, _} = Settings.set_competence_matrix([row(2.0)])
      {:ok, _} = Settings.set_competence_matrix_candidate([row(3.0)])

      assert Settings.competence_matrix() == [row(2.0)]
      assert Settings.competence_matrix_candidate() == [row(3.0)]
      assert Settings.competence_matrix_previous() == nil
    end

    test "the candidate is validated like the live matrix" do
      assert {:error, _} = Settings.set_competence_matrix_candidate([%{"n" => 3}])
      assert Settings.competence_matrix_candidate() == nil
    end

    test "promote makes the candidate live, keeps the old live for rollback, clears the candidate" do
      {:ok, _} = Settings.set_competence_matrix([row(2.0)])
      {:ok, _} = Settings.set_competence_matrix_candidate([row(3.0)])

      assert {:ok, [promoted]} = Settings.promote_competence_matrix_candidate()
      assert promoted["author_runs"] == 3.0

      assert Settings.competence_matrix() == [row(3.0)]
      assert Settings.competence_matrix_previous() == [row(2.0)]
      assert Settings.competence_matrix_candidate() == nil
    end

    test "promote over an unset live matrix keeps an empty previous (defaults only)" do
      {:ok, _} = Settings.set_competence_matrix_candidate([row(3.0)])
      assert {:ok, _} = Settings.promote_competence_matrix_candidate()
      assert Settings.competence_matrix_previous() == []
    end

    test "promote with no candidate is refused and changes nothing" do
      {:ok, _} = Settings.set_competence_matrix([row(2.0)])
      assert {:error, :no_candidate} = Settings.promote_competence_matrix_candidate()
      assert Settings.competence_matrix() == [row(2.0)]
      assert Settings.competence_matrix_previous() == nil
    end

    test "rollback restores the previous live matrix and keeps the replaced one to roll forward" do
      {:ok, _} = Settings.set_competence_matrix([row(2.0)])
      {:ok, _} = Settings.set_competence_matrix_candidate([row(3.0)])
      {:ok, _} = Settings.promote_competence_matrix_candidate()

      assert {:ok, [restored]} = Settings.rollback_competence_matrix()
      assert restored["author_runs"] == 2.0
      assert Settings.competence_matrix() == [row(2.0)]
      assert Settings.competence_matrix_previous() == [row(3.0)]
    end

    test "rollback with nothing previous is refused" do
      assert {:error, :no_previous} = Settings.rollback_competence_matrix()
    end
  end
end
