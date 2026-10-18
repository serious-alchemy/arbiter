defmodule Arbiter.Worker.DeferredCriteriaTest do
  @moduledoc """
  bd-49r9ns: the classification rule behind approving a review whose only
  unmet criteria are post-merge (`[DEFERRED]`), and the opt-out setting.
  Fail-closed: anything ambiguous parks.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.DeferredCriteria

  describe "classify/1" do
    test "defers when the only NOT MET lines are tagged [DEFERRED] and the rest are MET/N/A" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] AC1: gate approves — review_gate.ex:100
      - [N/A] AC2: not applicable
      - [NOT MET] [DEFERRED] AC3: dashboard shows the metric — only observable after deploy
      - [NOT MET] [DEFERRED] AC4: restart picks up the setting
      """

      assert {:defer, [first, second]} = DeferredCriteria.classify(findings)
      assert first =~ "AC3: dashboard shows the metric"
      refute first =~ "[DEFERRED]"
      refute first =~ "[NOT MET]"
      assert second =~ "AC4: restart picks up the setting"
    end

    test "parks when any NOT MET line is untagged (implementer-fixable)" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [NOT MET] [DEFERRED] AC3: only after deploy
      - [NOT MET] AC4: the guard clause is missing
      """

      assert DeferredCriteria.classify(findings) == :park
    end

    test "parks when a NOT MET line is a coordinator-only criterion marked pre-merge" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [NOT MET] [NEEDS-COORDINATOR-PREMERGE] AC3: the operator must register a runner first
      - [NOT MET] [DEFERRED] AC4: only after deploy
      """

      assert DeferredCriteria.classify(findings) == :park
    end

    test "parks on a bare [NEEDS-COORDINATOR] tag: pre/post-merge is ambiguous" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] AC1: done
      - [NOT MET] [NEEDS-COORDINATOR] AC3: needs the coordinator
      """

      assert DeferredCriteria.classify(findings) == :park
    end

    test "parks when the pre-merge tag appears anywhere in the findings" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [NOT MET] [DEFERRED] AC3: only after deploy
      Note: [NEEDS-COORDINATOR-PREMERGE] the runner must exist before merge.
      """

      assert DeferredCriteria.classify(findings) == :park
    end

    test "parks when the deferred tag is not directly after the outcome bracket" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [NOT MET] AC3: [DEFERRED] hidden mid-line
      """

      assert DeferredCriteria.classify(findings) == :park
    end

    test "parks when there is no NOT MET line, no criteria, or the verdict is partial" do
      assert DeferredCriteria.classify("VERDICT: APPROVE\nCRITERIA:\n- [MET] AC1: ok\n") == :park
      assert DeferredCriteria.classify("VERDICT: APPROVE\nlooks good\n") == :park
      assert DeferredCriteria.classify(nil) == :park

      partial = """
      VERDICT: APPROVE
      VERIFICATION: PARTIAL — did not run the suite
      CRITERIA:
      - [NOT MET] [DEFERRED] AC3: only after deploy
      """

      assert DeferredCriteria.classify(partial) == :park
    end
  end

  describe "enabled?/2" do
    defp ws(config), do: %Workspace{config: config}

    test "defaults to on" do
      assert DeferredCriteria.enabled?(ws(%{}), "trib/repo")
    end

    test "workspace-level review.defer_post_merge_criteria: false turns it off" do
      refute DeferredCriteria.enabled?(
               ws(%{"review" => %{"defer_post_merge_criteria" => false}}),
               "trib/repo"
             )
    end

    test "a per-repo entry overrides the workspace value" do
      config = %{
        "review" => %{
          "defer_post_merge_criteria" => true,
          "repos" => %{"trib/repo" => %{"defer_post_merge_criteria" => false}}
        }
      }

      refute DeferredCriteria.enabled?(ws(config), "trib/repo")
      assert DeferredCriteria.enabled?(ws(config), "other/repo")
    end

    test "an unreadable workspace fails closed (off)" do
      refute DeferredCriteria.enabled?(nil, "trib/repo")
    end
  end

  describe "append_notes/3" do
    test "appends a block marked as deferred by ReviewGate round N" do
      notes = DeferredCriteria.append_notes("existing", ["AC3: observe the dashboard"], 2)
      assert notes =~ "existing"
      assert notes =~ "deferred from acceptance by ReviewGate round 2"
      assert notes =~ "- AC3: observe the dashboard"
    end

    test "starts a fresh note when there is none and does not repeat a criterion already recorded" do
      once = DeferredCriteria.append_notes(nil, ["AC3: observe"], 1)
      assert once =~ "- AC3: observe"

      twice = DeferredCriteria.append_notes(once, ["AC3: observe"], 2)
      assert twice == once
    end
  end
end
