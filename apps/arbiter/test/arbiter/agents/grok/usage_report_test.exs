defmodule Arbiter.Agents.Grok.UsageReportTest do
  use ExUnit.Case, async: true

  alias Arbiter.Agents.Grok.UsageReport

  # Real `grok usage <session-id>` output from the bd-7nbwix probe session
  # (local, 0 tokens).
  @fixtures Path.expand("../../../fixtures/grok", __DIR__)
  @report @fixtures |> Path.join("usage_report.json") |> File.read!()

  test "argv/1 is `grok usage <session>` and refuses a session id that is not a plain id" do
    assert UsageReport.argv("01a0fa94-3009") == {:ok, ["grok", "usage", "01a0fa94-3009"]}
    assert UsageReport.argv("../x; rm") == {:error, :invalid_session_id}
    assert UsageReport.argv("") == {:error, :invalid_session_id}
  end

  test "parse/1 splits cached from uncached input (the report's inputTokens includes cache reads)" do
    assert {:ok, report} = UsageReport.parse(@report)
    assert report.session_id == "01a0fa94-3009-7fd0-a16d-988b53534054"
    assert report.model == "grok-4.7"
    assert report.tokens_in == 29_112
    assert report.cache_read_tokens == 31_872
    assert report.tokens_out == 658
    assert report.reasoning_tokens == 393
    assert report.total_tokens == 61_642
    assert report.model_calls == 4
    assert_in_delta report.cost_usd, 0.078108, 1.0e-9
  end

  test "its uncached/cached split agrees with the stream's result.usage" do
    result =
      @fixtures
      |> Path.join("success_stream.jsonl")
      |> File.stream!()
      |> Enum.map(&Jason.decode!/1)
      |> List.last()

    {:ok, report} = UsageReport.parse(@report)
    assert report.tokens_in == result["usage"]["input_tokens"]
    assert report.cache_read_tokens == result["usage"]["cache_read_input_tokens"]
    assert report.tokens_out == result["usage"]["output_tokens"]
  end

  test "parse/1 rejects anything that is not a usage report" do
    assert UsageReport.parse("not json") == {:error, :invalid_report}
    assert UsageReport.parse(~s({"session":{}})) == {:error, :invalid_report}
  end
end
