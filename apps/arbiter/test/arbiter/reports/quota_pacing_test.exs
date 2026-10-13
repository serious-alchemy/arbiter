defmodule Arbiter.Reports.QuotaPacingTest do
  use ExUnit.Case, async: true

  alias Arbiter.Reports.QuotaPacing

  defp row(attrs),
    do: Map.merge(%{at: ~U[2026-10-13 10:00:00Z], utilization: 0.5, ceiling: 0.85}, attrs)

  test "points/1 formats float utilization and ceiling as percent" do
    assert [%{value: 50.0, ceiling: 85.0}] = QuotaPacing.points([row(%{})])
  end

  test "points/1 accepts integer utilization and ceiling" do
    assert [%{value: 0.0, ceiling: 100.0}] =
             QuotaPacing.points([row(%{utilization: 0, ceiling: 1})])

    QuotaPacing.points([row(%{utilization: 0, ceiling: 1})])

    assert [%{value: 100.0, ceiling: 0.0}] =
             QuotaPacing.points([row(%{utilization: 1, ceiling: 0})])
  end

  test "points/1 keeps a nil ceiling nil and tolerates nil utilization" do
    assert [%{value: 0.0, ceiling: nil}] =
             QuotaPacing.points([row(%{utilization: nil, ceiling: nil})])
  end
end
