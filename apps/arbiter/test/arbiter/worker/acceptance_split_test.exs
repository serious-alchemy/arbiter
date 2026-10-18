defmodule Arbiter.Worker.AcceptanceSplitTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.AcceptanceSplit
  alias Arbiter.Worker.ReviewVerification

  test "filing rule states both halves and the issue_type rule" do
    r = AcceptanceSplit.filing_rule()
    assert r =~ "`deployment_notes` holds what can only be checked after merge or deploy"
    assert r =~ "test X covers Y"
    assert r =~ "`task` is research/ops only, with no diff"
    assert r =~ "OWN work type"
  end

  test "planner block" do
    b = AcceptanceSplit.planner_block()
    assert b =~ "NEVER put those in `acceptance`"
    assert b =~ "work type of the CHILD"
    assert b =~ "`task` only for research"
  end

  test "implementer block" do
    b = AcceptanceSplit.implementer_block()
    assert b =~ "do not fake"
    assert b =~ "suggest moving it to"
    assert b =~ "`deployment_notes`"
  end

  test "reviewer block" do
    b = AcceptanceSplit.reviewer_block()
    assert b =~ "NOT a reason for REQUEST_CHANGES"
    assert b =~ "`[DEFERRED]`"
  end

  test "ticket_create / batch tool descriptions carry the rule" do
    for name <- ["ticket_create", "ticket_create_batch"] do
      tool = Enum.find(Arbiter.MCP.Catalog.all(), &(&1.name == name))
      assert tool.description =~ "ACCEPTANCE vs DEPLOYMENT_NOTES"
      assert tool.description =~ "OWN work type"
    end
  end

  test "reviewer criteria prompt carries DEFERRED rule" do
    assert ReviewVerification.criteria_block() =~ "NOT a reason for REQUEST_CHANGES"

    assert ReviewVerification.criteria_block() =~
             AcceptanceSplit.reviewer_block()
             |> String.trim()
             |> String.split("\n")
             |> hd()
             |> String.trim()

    assert ReviewVerification.criteria_block() =~ "- [DEFERRED] <criterion>"
    assert ReviewVerification.criteria_block() =~ "`[N/A]`, `[DEFERRED]`"
  end

  test "an all-DEFERRED APPROVE breakdown is recognised and not unmet" do
    findings = "VERDICT: APPROVE\n\nCRITERIA:\n- [DEFERRED] prod timing — post-merge only\n"
    assert ReviewVerification.criteria_present?(findings)
    refute ReviewVerification.unmet_criteria?(findings)
  end

  describe "rendered prompts" do
    alias Arbiter.Tasks.Issue
    alias Arbiter.Worker.PromptBuilder

    defp issue(type) do
      %Issue{
        id: "bd-split1",
        title: "T",
        description: "D",
        acceptance: "test X covers Y",
        issue_type: type,
        tracker_type: :none
      }
    end

    test "research/planner prompt teaches filing children" do
      p = PromptBuilder.prompt_for_task(issue(:research), [])
      assert p =~ "FILING CHILD TICKETS"
      assert p =~ "work type of the CHILD"
      assert p =~ "NEVER put those in `acceptance`"
    end

    test "implementer prompt teaches unverifiable ACs and the PR body note" do
      p = PromptBuilder.prompt_for_task(issue(:bug), worktree_path: "/tmp/wt")
      assert p =~ "ACCEPTANCE CRITERIA YOU CANNOT VERIFY IN THE WORKTREE"
      assert p =~ "do not fake"
      assert p =~ "**Not verifiable pre-merge**"
      assert p =~ "`deployment_notes`"
    end
  end
end
