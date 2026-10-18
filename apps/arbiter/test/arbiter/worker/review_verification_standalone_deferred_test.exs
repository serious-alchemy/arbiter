defmodule Arbiter.Worker.ReviewVerificationStandaloneDeferredTest do
  @moduledoc "#958: a standalone `- [DEFERRED]` line is a disposition, not unmet or malformed."
  use ExUnit.Case, async: true

  alias Arbiter.Worker.{CoordinatorOnlyFindings, ReviewVerification}

  @findings """
  VERDICT: APPROVE
  CRITERIA:
  - [MET] AC1: done
  - [DEFERRED] AC2: observe after deploy — cannot be checked pre-merge
  """

  test "ReviewVerification counts it as a criterion, not as unmet" do
    assert ReviewVerification.criteria_present?(@findings)
    refute ReviewVerification.unmet_criteria?(@findings)
    assert ReviewVerification.criteria_counts(@findings) == {2, 0}
  end

  test "CoordinatorOnlyFindings treats it as coordinator-blocked (deferral unavailable)" do
    assert CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(@findings,
             standalone_deferred: true
           )
  end

  test "without the APPROVE-path opt a standalone [DEFERRED] is not coordinator-blocked" do
    refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(
             "VERDICT: REQUEST_CHANGES\n" <>
               @findings <> "1. Severity: Medium. foo.ex:12 — nil crash\n"
           )
  end

  test "tags that only appear in prose or backticks do not park" do
    findings = """
    VERDICT: REQUEST_CHANGES
    CRITERIA:
    - [NOT MET] AC1: handle nil in foo.ex — fixable
    Prose: use `[NEEDS-COORDINATOR]` or `[DEFERRED]` only for post-merge items.
    """

    refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(findings)

    approve = """
    VERDICT: APPROVE
    CRITERIA:
    - [MET] AC1
    - [NOT MET] [DEFERRED] AC2 live only
    Note: the `[NEEDS-COORDINATOR]` tag was not used here.
    """

    assert {:defer, ["AC2 live only"]} = Arbiter.Worker.DeferredCriteria.classify(approve)
  end

  test "an untagged [NOT MET] beside a standalone [DEFERRED] still goes to the implementer" do
    refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(
             @findings <> "- [NOT MET] AC3: missing code\n",
             standalone_deferred: true
           )
  end
end
