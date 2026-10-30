defmodule Arbiter.Tasks.AcceptanceLintTest do
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.AcceptanceLint

  @flagged [
    "- After deploy, the dashboard is green",
    "- Works in prod for a week",
    "- The pipeline shows all jobs passing",
    "- Pipeline logs show no errors",
    "- CI reports 0 failures",
    "- 50 runs of the loop all pass",
    "- Passes 20 times in a row",
    "- Latency within 5% on CI",
    "- The operator confirms the rollout",
    "- Dashboard shows the new metric"
  ]

  @clean [
    "- `mix test` passes",
    "- The function returns {:ok, _} for valid input",
    "- A unit test covers the nil case",
    "- The CLI prints a warning",
    "- Runs the loop once without error"
  ]

  for line <- @flagged do
    test "flags #{inspect(line)}" do
      assert [warning] = AcceptanceLint.lint(unquote(line))
      assert warning =~ unquote(line |> String.trim_leading("- "))
      assert warning =~ "deployment_notes"
    end
  end

  for line <- @clean do
    test "does not flag #{inspect(line)}" do
      assert AcceptanceLint.lint(unquote(line)) == []
    end
  end

  test "only flagged lines are named in a mixed block" do
    text = "- `mix test` passes\n- After deploy, check prod\n- Unit test added"
    assert [w] = AcceptanceLint.lint(text)
    assert w =~ "After deploy, check prod"
    refute w =~ "Unit test added"
  end

  test "nil and blank are clean" do
    assert AcceptanceLint.lint(nil) == []
    assert AcceptanceLint.lint("  ") == []
  end
end
