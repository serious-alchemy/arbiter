defmodule Arbiter.Quota.PriceTest do
  @moduledoc """
  bd-adtnto (R5, design §2.3): the headroom price is `δ / h` per window and the
  max over a pool's trusted windows; it rises continuously as headroom shrinks
  and a pool at or over the paced line (`h <= 0`) is infeasible, never priced.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Quota.Price

  defp window(h),
    do: %{headroom: h * 1.0, window: "5h", threshold: 0.5, used: 0.5 - h, mode: :paced}

  defp pos, do: StreamData.float(min: 1.0e-6, max: 1.0)
  defp draw, do: StreamData.float(min: 0.01, max: 10.0)

  describe "window_price/2" do
    test "is the share of the remaining headroom the draw would use" do
      assert_in_delta Price.window_price(0.30, 0.15), 0.5, 1.0e-12
      assert_in_delta Price.window_price(0.036, 1.0), 1 / 0.036, 1.0e-9
    end

    test "a window at or over the line is infeasible" do
      assert Price.window_price(0.0, 1.0) == :infeasible
      assert Price.window_price(-0.01, 1.0) == :infeasible
    end

    test "a headroom too small to invert is infeasible rather than raising" do
      assert Price.window_price(1.0e-320, 1.0) == :infeasible
    end

    property "I1: price strictly rises as headroom shrinks" do
      check all(lo <- pos(), gap <- pos(), d <- draw()) do
        assert Price.window_price(lo, d) > Price.window_price(lo + gap, d)
      end
    end

    property "I1: price is continuous (price × headroom is the draw)" do
      check all(h <- pos(), d <- draw()) do
        assert_in_delta Price.window_price(h, d) * h, d, d * 1.0e-9
      end
    end

    property "price rises with the draw" do
      check all(h <- pos(), a <- draw(), gap <- draw()) do
        assert Price.window_price(h, a) < Price.window_price(h, a + gap)
      end
    end

    property "I2: at or over the line is infeasible whatever the draw" do
      check all(h <- StreamData.float(max: 0.0), d <- draw()) do
        assert Price.window_price(h, d) == :infeasible
      end
    end
  end

  describe "price/2" do
    test "an empty window list is unknown, not free" do
      assert Price.price([], 1.0) == nil
    end

    test "is the max over windows: the window this draw strains most binds" do
      assert_in_delta Price.price([window(0.45), window(0.40)], 1.0), 1 / 0.40, 1.0e-9
      assert_in_delta Price.price([window(0.05), window(0.90)], 0.1), 0.1 / 0.05, 1.0e-9
    end

    test "without a draw estimate it is 1/h on the binding window" do
      assert_in_delta Price.price([window(0.45), window(0.40)]), 1 / 0.40, 1.0e-9
    end

    test "any infeasible window makes the pool infeasible" do
      assert Price.price([window(0.40), window(0.0)], 1.0) == :infeasible
    end

    property "equals 1/h of the binding window with a unit draw" do
      check all(hs <- StreamData.list_of(pos(), min_length: 1, max_length: 4)) do
        expected = 1 / Enum.min(hs)
        assert_in_delta Price.price(Enum.map(hs, &window/1)), expected, expected * 1.0e-9
      end
    end
  end

  describe "total/1 and over_line?/1" do
    test "pools add up" do
      assert_in_delta Price.total([0.25, 0.5]), 0.75, 1.0e-12
    end

    test "an infeasible or unknown pool poisons the total" do
      assert Price.total([0.25, :infeasible]) == :infeasible
      assert Price.total([0.25, nil]) == nil
      assert Price.total([]) == 0.0
    end

    test "price >= 1 flags a draw expected to cross the line" do
      assert Price.over_line?(1.0)
      assert Price.over_line?(3.2)
      refute Price.over_line?(0.99)
      refute Price.over_line?(nil)
      assert Price.over_line?(:infeasible)
    end
  end
end
