defmodule Arbiter.Worker.RepeatUnmetCriterionTest do
  use ExUnit.Case, async: true

  alias Arbiter.Worker.RepeatUnmetCriterion

  @prev """
  CRITERIA:
  - [MET] Tests cover the park
  - [NOT MET] 50/50 local runs pass — no evidence of the runs
  - [NOT MET] Docs updated — missing
  """

  describe "normalize/1" do
    test "ignores whitespace, case, markup and the reason suffix" do
      assert RepeatUnmetCriterion.normalize("  [NOT MET]   50/50  LOCAL runs pass — nope") ==
               RepeatUnmetCriterion.normalize("[MET] 50/50 local runs pass")

      assert RepeatUnmetCriterion.normalize("[NOT MET] [NEEDS-COORDINATOR] Foo bar — x") ==
               "foo bar"
    end
  end

  describe "unmet_criteria/1" do
    test "returns only NOT MET lines" do
      assert [{k1, _}, {k2, _}] = RepeatUnmetCriterion.unmet_criteria(@prev)
      assert k1 == "50/50 local runs pass"
      assert k2 == "docs updated"
    end

    test "nil and non-binary are empty" do
      assert RepeatUnmetCriterion.unmet_criteria(nil) == []
    end
  end

  describe "repeated/2" do
    test "finds a shared criterion despite markup and spacing" do
      cur = "1. [NOT MET]   50/50 LOCAL runs  pass — still none\n- [NOT MET] New thing — x"

      assert [%{criterion: "50/50 local runs pass", previous: p, current: c}] =
               RepeatUnmetCriterion.repeated(@prev, cur)

      assert p =~ "no evidence"
      assert c =~ "still none"
    end

    test "different criteria do not repeat" do
      assert RepeatUnmetCriterion.repeated(@prev, "- [NOT MET] Something else — y") == []
      assert RepeatUnmetCriterion.repeated(nil, "- [NOT MET] a") == []
    end
  end

  test "escalation?/1 keys off the marker" do
    f = RepeatUnmetCriterion.escalation_findings([], "x", "payload")
    assert RepeatUnmetCriterion.escalation?(f)
    refute RepeatUnmetCriterion.escalation?("other")
  end
end
