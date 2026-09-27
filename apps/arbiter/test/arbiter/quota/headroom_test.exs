defmodule Arbiter.Quota.HeadroomTest do
  @moduledoc """
  bd-40pzpj AC4: "most quota left" is headroom against the gate's own
  threshold — `threshold_now − used` on the binding window, with
  `threshold_now` from `Arbiter.Quota.Gate.pace/6` (paced or flat, composed
  `min(account, workspace)`).
  """
  use ExUnit.Case, async: true

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Quota.Headroom
  alias Arbiter.Tasks.Workspace

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp account(config \\ %{}), do: %ProviderAccount{id: "acct", quota_config: config}

  defp ws(quota \\ nil),
    do: %Workspace{id: "ws", config: if(quota, do: %{"quota" => quota}, else: %{})}

  defp claude(u5, u7, opts \\ []) do
    %AnthropicQuota{
      provider: "claude",
      utilization_5h: u5,
      reset_5h_at: Keyword.get(opts, :reset_5h, ahead(9_000)),
      status_5h: "allowed",
      utilization_7d: u7,
      reset_7d_at: Keyword.get(opts, :reset_7d, ahead(302_400)),
      status_7d: "allowed",
      captured_at: now()
    }
  end

  defp agy_bucket(group, window, remaining, reset_at) do
    %{
      "model_id" => "#{group}_#{window}",
      "remaining_percentage" => remaining,
      "reset_at" => DateTime.to_iso8601(reset_at)
    }
  end

  defp agy(gemini_used, claude_gpt_used) do
    %GoogleQuota{
      provider: "antigravity",
      captured_at: now(),
      reset_at: ahead(9_000),
      snapshot: %{
        "models" => [
          agy_bucket("gemini_models", "5h", 100.0 - gemini_used, ahead(9_000)),
          agy_bucket("gemini_models", "weekly", 100.0, ahead(302_400)),
          agy_bucket("claude_and_gpt_models", "5h", 100.0 - claude_gpt_used, ahead(9_000)),
          agy_bucket("claude_and_gpt_models", "weekly", 100.0, ahead(302_400))
        ]
      }
    }
  end

  describe "flat thresholds" do
    test "headroom is the flat ceiling minus used, on the window with the least left" do
      # 5h: 0.85 − 0.40 = 0.45; 7d: 0.90 − 0.50 = 0.40 → the 7d window binds.
      result = Headroom.binding(claude(0.40, 0.50), {account(), ws()})

      assert result.window == "7d"
      assert_in_delta result.headroom, 0.40, 1.0e-9
      assert_in_delta result.threshold, 0.90, 1.0e-9
      assert_in_delta result.used, 0.50, 1.0e-9
      assert result.mode == :flat
    end

    test "a workspace can only tighten the account's ceiling: min(account, workspace)" do
      policy = {account(%{"throttle_threshold" => 0.80}), ws(%{"throttle_threshold" => 0.60})}
      result = Headroom.binding(claude(0.40, 0.10), policy)

      assert result.window == "5h"
      assert_in_delta result.threshold, 0.60, 1.0e-9
      assert_in_delta result.headroom, 0.20, 1.0e-9
    end
  end

  describe "paced thresholds" do
    test "threshold_now is max(floor, elapsed): halfway through both windows the ceiling is 0.5" do
      paced = account(%{"threshold_mode" => "paced"})
      # 5h reset 2.5h out → elapsed 0.5; 7d reset 3.5d out → elapsed 0.5.
      result = Headroom.binding(claude(0.30, 0.10), {paced, ws()})

      assert result.window == "5h"
      assert result.mode == :paced
      assert_in_delta result.threshold, 0.50, 0.01
      assert_in_delta result.headroom, 0.20, 0.01
    end

    test "right after a reset the paced floor applies" do
      paced = account(%{"threshold_mode" => "paced", "paced_floor" => 0.35})
      # 5h reset 4.9h out → elapsed ≈ 0.02 < floor 0.35.
      quota = claude(0.10, 0.0, reset_5h: ahead(17_640))
      result = Headroom.binding(quota, {paced, ws()})

      assert result.window == "5h"
      assert_in_delta result.threshold, 0.35, 1.0e-9
      assert_in_delta result.headroom, 0.25, 1.0e-9
    end

    test "a paced account under a flat, stricter workspace binds at the workspace's ceiling" do
      paced = account(%{"threshold_mode" => "paced"})
      result = Headroom.binding(claude(0.30, 0.10), {paced, ws(%{"throttle_threshold" => 0.40})})

      assert result.window == "5h"
      assert_in_delta result.threshold, 0.40, 1.0e-9
      assert_in_delta result.headroom, 0.10, 1.0e-9
    end
  end

  describe "agy's two pools" do
    test "a gemini model reads the Gemini pool and a claude model the Claude-and-GPT pool" do
      quota = agy(70.0, 10.0)

      gemini = Headroom.binding(quota, {account(), ws()}, model: "gemini-3.1-pro-high")
      claude = Headroom.binding(quota, {account(), ws()}, model: "claude-opus-4-6-thinking")

      assert_in_delta gemini.used, 0.70, 1.0e-9
      assert_in_delta gemini.headroom, 0.15, 1.0e-9
      assert_in_delta claude.used, 0.10, 1.0e-9
      assert_in_delta claude.headroom, 0.75, 1.0e-9
    end
  end

  describe "codex" do
    test "the session window has no length, so a paced account falls back to flat on it" do
      quota = %CodexQuota{
        provider: "codex",
        session_used_percent: 20.0,
        session_reset_at: ahead(3_600),
        weekly_used_percent: 10.0,
        weekly_reset_at: ahead(302_400),
        limit_reached: false,
        captured_at: now()
      }

      result = Headroom.binding(quota, {account(%{"throttle_threshold" => 0.5}), ws()})

      assert result.window == "session"
      assert_in_delta result.headroom, 0.30, 1.0e-9
    end
  end

  describe "unknown headroom" do
    test "no snapshot is unknown, not zero" do
      assert Headroom.binding(nil, {account(), ws()}) == nil
    end

    test "a snapshot with no utilization reading on any window is unknown" do
      assert Headroom.binding(claude(nil, nil), {account(), ws()}) == nil
    end
  end
end
