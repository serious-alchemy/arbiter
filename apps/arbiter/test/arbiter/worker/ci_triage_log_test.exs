defmodule Arbiter.Worker.CiTriageLogTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.CiTriageLog

  defp ws(config), do: %Workspace{id: "w", config: config}

  describe "budget/2" do
    test "defaults to 2 re-runs per head" do
      assert CiTriageLog.budget(ws(%{}), "o/r") == 2
      assert CiTriageLog.budget(nil, nil) == 2
    end

    test "reads merge.ci.triage_rerun_budget, a repo entry overriding the workspace's" do
      config = %{
        "merge" => %{
          "ci" => %{"triage_rerun_budget" => 3},
          "repos" => %{"o/r" => %{"ci" => %{"triage_rerun_budget" => 0}}}
        }
      }

      assert CiTriageLog.budget(ws(config), "o/r") == 0
      assert CiTriageLog.budget(ws(config), "o/other") == 3
    end

    test "a malformed value falls back to the default" do
      for bad <- ["3", -1, 1.5, nil] do
        config = %{"merge" => %{"ci" => %{"triage_rerun_budget" => bad}}}
        assert CiTriageLog.budget(ws(config), "o/r") == 2
      end
    end
  end

  test "record/4 never raises for a ticket that does not exist" do
    triage = %{class: :needs_agent, reason: "r", evidence: []}
    assert CiTriageLog.record("no-such-ticket", "h1", "action", triage) == :ok
  end
end
