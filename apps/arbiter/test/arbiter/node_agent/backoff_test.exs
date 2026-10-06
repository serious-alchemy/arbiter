defmodule Arbiter.NodeAgent.BackoffTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.Backoff

  # Deterministic jitter: the lowest / highest value `rand` may return.
  defp low, do: fn _ -> 0 end
  defp high, do: fn n -> n end

  test "grows 1s, 2s, 4s … and is capped at 30s" do
    ceilings = for attempt <- 0..8, do: Backoff.delay(attempt, rand: high())
    assert ceilings == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000, 30_000]
  end

  test "jitter only ever shortens the delay, down to three quarters of the ceiling" do
    assert Backoff.delay(0, rand: low()) == 750
    assert Backoff.delay(3, rand: low()) == 6_000
    assert Backoff.delay(20, rand: low()) == 22_500
  end

  test "the real random source stays inside the jitter window" do
    for _ <- 1..200 do
      d = Backoff.delay(2)
      assert d >= 3_000 and d <= 4_000
    end
  end

  test "base and max are configurable (tests and the agent's own loop use small ones)" do
    assert Backoff.delay(0, base: 10, max: 40, rand: high()) == 10
    assert Backoff.delay(5, base: 10, max: 40, rand: high()) == 40
  end

  test "an absurd attempt count does not overflow" do
    assert Backoff.delay(10_000, rand: high()) == 30_000
  end
end
