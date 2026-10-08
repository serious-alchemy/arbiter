defmodule Arbiter.Nodes.RateLimitTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.RateLimit

  setup do
    name = :"rate_limit_#{System.unique_integer([:positive])}"
    start_supervised!({RateLimit, name: name})
    {:ok, server: name}
  end

  @t0 1_000_000

  describe ":pair" do
    test "allows 5 pairing requests per source per 10 minutes", %{server: s} do
      for _ <- 1..5, do: assert(:ok = RateLimit.check(:pair, "100.64.0.1", server: s, now_ms: @t0))

      assert {:error, {:rate_limited, retry}} =
               RateLimit.check(:pair, "100.64.0.1", server: s, now_ms: @t0)

      assert retry in 1..600
      assert :ok = RateLimit.check(:pair, "100.64.0.2", server: s, now_ms: @t0)
    end
  end

  describe ":pair_poll" do
    test "allows 60 polls a minute per source", %{server: s} do
      for _ <- 1..60, do: assert(:ok = RateLimit.check(:pair_poll, "a", server: s, now_ms: @t0))

      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:pair_poll, "a", server: s, now_ms: @t0)

      assert :ok = RateLimit.check(:pair_poll, "b", server: s, now_ms: @t0)
    end

    test "10 failed polls in 10 minutes block that source only", %{server: s} do
      for _ <- 1..10, do: RateLimit.record_failure(:pair_poll, "bad", server: s, now_ms: @t0)

      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:pair_poll, "bad", server: s, now_ms: @t0)

      assert :ok = RateLimit.check(:pair_poll, "good", server: s, now_ms: @t0)
    end
  end

  describe ":enroll" do

    test "allows 10 attempts a minute globally, then 429s with a Retry-After", %{server: s} do
      for _ <- 1..10,
          do: assert(:ok = RateLimit.check(:enroll, "100.64.0.1", server: s, now_ms: @t0))

      assert {:error, {:rate_limited, retry}} =
               RateLimit.check(:enroll, "100.64.0.2", server: s, now_ms: @t0)

      assert retry in 1..60
    end

    test "the global bucket refills over the minute", %{server: s} do
      for _ <- 1..10, do: RateLimit.check(:enroll, "a", server: s, now_ms: @t0)
      assert {:error, {:rate_limited, _}} = RateLimit.check(:enroll, "a", server: s, now_ms: @t0)

      assert :ok = RateLimit.check(:enroll, "a", server: s, now_ms: @t0 + 7_000)

      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:enroll, "a", server: s, now_ms: @t0 + 7_000)

      assert :ok = RateLimit.check(:enroll, "a", server: s, now_ms: @t0 + 70_000)
    end

    test "5 failures in 10 minutes block that source only", %{server: s} do
      for _ <- 1..5, do: RateLimit.record_failure(:enroll, "bad", server: s, now_ms: @t0)

      assert {:error, {:rate_limited, retry}} =
               RateLimit.check(:enroll, "bad", server: s, now_ms: @t0)

      assert retry > 0
      assert :ok = RateLimit.check(:enroll, "good", server: s, now_ms: @t0)
    end

    test "four failures do not block", %{server: s} do
      for _ <- 1..4, do: RateLimit.record_failure(:enroll, "bad", server: s, now_ms: @t0)

      assert :ok = RateLimit.check(:enroll, "bad", server: s, now_ms: @t0)
    end

    test "a source's failures age out", %{server: s} do
      for _ <- 1..5, do: RateLimit.record_failure(:enroll, "bad", server: s, now_ms: @t0)
      assert {:error, _} = RateLimit.check(:enroll, "bad", server: s, now_ms: @t0)

      assert :ok = RateLimit.check(:enroll, "bad", server: s, now_ms: @t0 + 11 * 60_000)
    end
  end

  describe ":mint" do
    test "is 20 an hour per actor", %{server: s} do
      for _ <- 1..20,
          do: assert(:ok = RateLimit.check(:mint, "operator:cli", server: s, now_ms: @t0))

      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:mint, "operator:cli", server: s, now_ms: @t0)

      assert :ok = RateLimit.check(:mint, "operator:other", server: s, now_ms: @t0)
    end
  end

  describe ":socket_connect" do
    test "30 failures a minute globally close the door, checks cost nothing", %{server: s} do
      for _ <- 1..100,
          do: assert(:ok = RateLimit.check(:socket_connect, "x", server: s, now_ms: @t0))

      for _ <- 1..30, do: RateLimit.record_failure(:socket_connect, "x", server: s, now_ms: @t0)

      assert {:error, {:rate_limited, _}} =
               RateLimit.check(:socket_connect, "y", server: s, now_ms: @t0)
    end
  end

  test "reset/1 forgets everything", %{server: s} do
    for _ <- 1..5, do: RateLimit.record_failure(:enroll, "bad", server: s, now_ms: @t0)
    assert {:error, _} = RateLimit.check(:enroll, "bad", server: s, now_ms: @t0)

    :ok = RateLimit.reset(server: s)
    assert :ok = RateLimit.check(:enroll, "bad", server: s, now_ms: @t0)
  end

  test "idle buckets are swept so a key flood cannot grow the table forever", %{server: s} do
    for n <- 1..50, do: RateLimit.record_failure(:enroll, "src-#{n}", server: s, now_ms: @t0)
    assert RateLimit.size(server: s) == 50

    assert :ok = RateLimit.sweep(server: s, now_ms: @t0 + 60 * 60_000)
    assert RateLimit.size(server: s) == 0
  end

  test "an unknown rule is a programming error" do
    assert_raise FunctionClauseError, fn -> RateLimit.check(:nope, "k", []) end
  end
end
