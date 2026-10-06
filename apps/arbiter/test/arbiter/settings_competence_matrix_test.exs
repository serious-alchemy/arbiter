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
end
