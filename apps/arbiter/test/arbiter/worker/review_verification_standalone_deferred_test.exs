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

  test "CoordinatorOnlyFindings does not treat it as an unmet coordinator-blocked line" do
    refute CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(@findings)
  end
end
