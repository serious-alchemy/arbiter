defmodule Arbiter.Tasks.TrackerAcceptanceTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.{Issue, TrackerAcceptance}
  alias Arbiter.Trackers.{GitHub, Shortcut}

  describe "derive/2" do
    test "Shortcut story tasks become a checklist" do
      story = %{
        "description" => "Some prose",
        "tasks" => [
          %{"description" => "Add the field", "complete" => false},
          %{"description" => "Cover with tests", "complete" => true}
        ]
      }

      assert {:acceptance, text} = TrackerAcceptance.derive(Shortcut, story)
      assert text == "- [ ] Add the field\n- [ ] Cover with tests"
    end

    test "markdown checkboxes in the description become a checklist" do
      issue = %{"body" => "Intro\n\n- [ ] one\n* [x] two\n- not a box"}
      assert {:acceptance, "- [ ] one\n- [ ] two"} = TrackerAcceptance.derive(GitHub, issue)
    end

    test "a recognised section becomes the acceptance text" do
      desc = "Problem text\n\n## Acceptance\nIt does X.\nAnd Y.\n\n## Notes\nignore me"

      assert {:acceptance, "It does X.\nAnd Y."} =
               TrackerAcceptance.derive(GitHub, %{"body" => desc})
    end

    test "inline-label sections are recognised" do
      assert {:acceptance, "bump the cap"} =
               TrackerAcceptance.derive(GitHub, %{"body" => "Bug.\n\nFix: bump the cap"})

      assert {:acceptance, "returns 200"} =
               TrackerAcceptance.derive(GitHub, %{"body" => "Bug.\n\n**Expected:** returns 200"})

      assert {:acceptance, "tests green"} =
               TrackerAcceptance.derive(GitHub, %{"body" => "x\n\nDone when:\ntests green"})
    end

    test "otherwise the explicit tracker-spec waiver" do
      assert {:waived, reason} = TrackerAcceptance.derive(GitHub, %{"body" => "just prose"})
      assert reason == Issue.tracker_spec_waiver()
      assert reason == "tracker story description is the spec"
    end

    test "tracker tasks win over a description section" do
      story = %{
        "description" => "## Acceptance\nfoo",
        "tasks" => [%{"description" => "t1", "complete" => false}]
      }

      assert {:acceptance, "- [ ] t1"} = TrackerAcceptance.derive(Shortcut, story)
    end
  end
end
