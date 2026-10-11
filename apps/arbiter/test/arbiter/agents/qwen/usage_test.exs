defmodule Arbiter.Agents.Qwen.UsageTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Qwen
  alias Arbiter.Agents.Qwen.RetryHold
  alias Arbiter.Agents.Qwen.SessionFile
  alias Arbiter.Agents.Qwen.Usage

  # Hand-authored fixtures, not live captures: see fixtures/qwen/README.md.
  @fixtures Path.expand("../../../fixtures/qwen", __DIR__)

  defp run_fixture(name, opts) do
    session = Qwen.init_session(opts)

    @fixtures
    |> Path.join(name)
    |> File.stream!()
    |> Enum.reduce(session, fn line, s ->
      {_display, s} = Qwen.parse_line(s, String.trim_trailing(line, "\n"))
      s
    end)
  end

  defp session_file(name), do: Path.join(@fixtures, name)

  describe "SessionFile" do
    test "sums api_response telemetry, splitting cached input and skipping other records" do
      assert {:ok, totals} = SessionFile.read(session_file("success_session.jsonl"))
      assert totals.tokens_in == 1300
      assert totals.cache_read_tokens == 1200
      assert totals.tokens_out == 52
      assert totals.thinking_tokens == 8
      assert totals.api_calls == 2
      assert totals.model == "qwen3-coder:30b"
    end

    test "tolerates a torn last line from a killed run" do
      assert {:ok, %{api_calls: 2, tokens_in: 1000}} =
               SessionFile.read(session_file("turn_limit_53_session.jsonl"))
    end

    test "missing file or no telemetry is :none" do
      assert SessionFile.read("/nonexistent/qwen.jsonl") == :none
      assert SessionFile.read(nil) == :none
      assert SessionFile.parse("{\"type\":\"user\"}\n") == :none
    end
  end

  describe "usage_attrs/1 reconcile" do
    test "completed run: stream and session file agree, thinking tokens come from the file" do
      session =
        run_fixture("success.jsonl", session_file: session_file("success_session.jsonl"))

      usage = Qwen.usage_attrs(session)
      assert usage.tokens_in == 1300
      assert usage.cache_read_tokens == 1200
      assert usage.tokens_out == 52
      assert usage.thinking_tokens == 8
      assert usage.usage_source == :reconciled
      assert usage.raw["usage_reconcile"]["drift"] == %{}
    end

    test "killed run: no result line, the session file is the record and drift is reported" do
      session =
        run_fixture("turn_limit_53.jsonl",
          session_file: session_file("turn_limit_53_session.jsonl")
        )

      usage = Qwen.usage_attrs(session)
      assert usage.tokens_in == 1000
      assert usage.tokens_out == 55
      assert usage.cache_read_tokens == 900
    end

    test "a stream that never produced usage falls back to the session file alone" do
      usage = Usage.reconcile(%{}, SessionFile.read(session_file("success_session.jsonl")))
      assert usage.tokens_out == 52
      assert usage.usage_source == :session_file
    end

    test "disagreement is recorded, with the session file winning" do
      {:ok, file} = SessionFile.read(session_file("success_session.jsonl"))

      usage =
        Usage.reconcile(%{tokens_in: 1400, tokens_out: 52, cache_read_tokens: 1200}, {:ok, file})

      assert usage.tokens_in == 1300
      assert usage.raw["usage_reconcile"]["drift"] == %{"tokens_in" => 100}
    end

    test "without a session file the normalised stream stands" do
      usage = Qwen.usage_attrs(run_fixture("success.jsonl", []))
      assert usage.tokens_in == 1300
      assert usage.usage_source == :stream
    end
  end

  describe "price/2" do
    test "unmetered endpoints record exactly zero" do
      usage = Usage.price(%{tokens_in: 1000, tokens_out: 10}, %{unmetered: true})
      assert usage.cost_usd == 0.0
      assert usage.cost_note =~ "unmetered"
    end

    test "priced endpoints compute from per-million rates" do
      endpoint = %{pricing: %{input: 1.0, output: 4.0, cache_read: 0.5}}

      usage =
        Usage.price(
          %{tokens_in: 1_000_000, tokens_out: 500_000, cache_read_tokens: 2_000_000},
          endpoint
        )

      assert_in_delta usage.cost_usd, 1.0 + 2.0 + 1.0, 1.0e-9
    end

    test "an endpoint with no pricing leaves cost unknown, never free" do
      refute Map.has_key?(Usage.price(%{tokens_in: 5}, %{base_url: "http://x"}), :cost_usd)
      refute Map.has_key?(Usage.price(%{tokens_in: 5}, nil), :cost_usd)
    end

    test "usage_attrs prices from the session's endpoint" do
      session = run_fixture("success.jsonl", endpoint: %{unmetered: true})
      assert Qwen.usage_attrs(session).cost_usd == 0.0
    end
  end

  describe "RetryHold" do
    test "parses the retry notice" do
      assert {:ok, %{delay_s: 12, attempt: 3, max: 10}} =
               RetryHold.parse("Retrying in 12s (attempt 3/10)...")

      assert {:ok, %{delay_s: 90}} = RetryHold.parse("Retrying in 1m 30s (attempt 7/10)")
      assert RetryHold.parse("all good") == :error
    end

    test "a streak that spends the wall-time budget flags a hold" do
      session = %{provider: "qwen"}
      budget_ms = RetryHold.budget_s() * 1000

      session = RetryHold.track(session, "Retrying in 5s (attempt 1/10)", 0)
      refute session[:qwen_retry_hold]

      session = RetryHold.track(session, "Retrying in 20s (attempt 2/10)", 1_000)
      refute session[:qwen_retry_hold]

      session = RetryHold.track(session, "Retrying in 40s (attempt 3/10)", budget_ms - 10_000)
      assert %{attempts: 3} = session[:qwen_retry_hold]

      reason = RetryHold.stop_reason(session.qwen_retry_hold, 143)
      assert reason.category == :quota_exhausted
      assert %DateTime{} = reason.retry_after
    end

    test "an answered request resets the streak" do
      session = RetryHold.track(%{}, "Retrying in 5s (attempt 1/10)", 0)
      assert session.qwen_retry
      refute RetryHold.reset(session)[:qwen_retry]
    end

    test "flows through parse_line from raw stderr lines" do
      session = Qwen.init_session([])
      {_, session} = Qwen.parse_line(session, "Retrying in 9999s (attempt 2/10)")
      assert session[:qwen_retry_hold]
    end
  end
end
