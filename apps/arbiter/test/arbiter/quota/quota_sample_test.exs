defmodule Arbiter.Quota.QuotaSampleTest do
  @moduledoc """
  Tests for `Arbiter.Quota.QuotaSample` (bd-3qfc81, R2).

  Append-only history of every quota capture across providers:
  (account, bucket, window, used, reset, captured_at) with configurable retention.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.{CloudCode, Codex, QuotaSample}
  alias Arbiter.Tasks.Workspace

  @headers [
    {"anthropic-ratelimit-unified-5h-utilization", "0.24"},
    {"anthropic-ratelimit-unified-5h-reset", "1782247200"},
    {"anthropic-ratelimit-unified-5h-status", "allowed"},
    {"anthropic-ratelimit-unified-7d-utilization", "0.08"},
    {"anthropic-ratelimit-unified-7d-reset", "1782748800"},
    {"anthropic-ratelimit-unified-7d-status", "allowed"},
    {"anthropic-ratelimit-unified-representative-claim", "five_hour"},
    {"anthropic-ratelimit-unified-overage-status", "rejected"},
    {"content-type", "application/json"}
  ]

  defp workspace!(name \\ "default") do
    Ash.create!(Workspace, %{name: name})
  end

  defp agy_usage_body(groups) do
    %{"command" => %{"data" => %{"groups" => groups}}}
  end

  defp agy_opts(groups) do
    [
      agy_usage_probe: fn ->
        {:ok, agy_usage_body(groups)}
      end
    ]
  end

  describe "resource and schema" do
    test "creates a quota sample and exposes attributes and calculations" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(now, 3600, :second)

      sample =
        Ash.create!(QuotaSample, %{
          provider_account_id: account_id,
          bucket: "claude",
          window: "5h",
          used: 0.25,
          reset_at: reset_at,
          captured_at: now
        })

      assert sample.provider_account_id == account_id
      assert sample.account_id == account_id
      assert sample.account == account_id
      assert sample.bucket == "claude"
      assert sample.window == "5h"
      assert sample.used == 0.25
      assert sample.reset_at == reset_at
      assert sample.reset == reset_at
      assert sample.captured_at == now
    end

    test "accepts account and reset aliases on create" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      reset_at = DateTime.add(now, 3600, :second)

      sample =
        Ash.create!(QuotaSample, %{
          account_id: account_id,
          bucket: "claude",
          window: "5h",
          used: 0.50,
          reset: reset_at,
          captured_at: now
        })

      assert sample.provider_account_id == account_id
      assert sample.reset_at == reset_at
    end
  end

  describe "captures append history" do
    test "Anthropic capture appends one row per (account, bucket, window)" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")

      assert {:ok, _} = Quota.capture(ws.id, @headers)

      samples = QuotaSample.history(account_id)
      assert length(samples) == 2

      s_5h = Enum.find(samples, &(&1.window == "5h"))
      s_7d = Enum.find(samples, &(&1.window == "7d"))

      assert s_5h.provider_account_id == account_id
      assert s_5h.bucket == "claude"
      assert s_5h.used == 0.24
      assert %DateTime{} = s_5h.reset_at

      assert s_7d.provider_account_id == account_id
      assert s_7d.bucket == "claude"
      assert s_7d.used == 0.08
      assert %DateTime{} = s_7d.reset_at

      # A second capture appends another two rows rather than overwriting
      updated_headers =
        List.keyreplace(
          @headers,
          "anthropic-ratelimit-unified-5h-utilization",
          0,
          {"anthropic-ratelimit-unified-5h-utilization", "0.35"}
        )

      assert {:ok, _} = Quota.capture(ws.id, updated_headers)

      all_samples = QuotaSample.history(account_id)
      assert length(all_samples) == 4
      assert Enum.map(all_samples, & &1.window) == ["5h", "7d", "5h", "7d"]
    end

    test "Antigravity refresh appends one row per (account, bucket, window)" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "antigravity")

      groups = [
        %{
          "name" => "Gemini Models",
          "buckets" => [
            %{
              "window" => "5h",
              "remaining_fraction" => 0.8,
              "reset_time" => "2026-10-04T12:00:00Z"
            },
            %{
              "window" => "weekly",
              "remaining_fraction" => 0.6,
              "reset_time" => "2026-10-08T12:00:00Z"
            }
          ]
        },
        %{
          "name" => "Claude and GPT models",
          "buckets" => [
            %{
              "window" => "5h",
              "remaining_fraction" => 0.9,
              "reset_time" => "2026-10-04T14:00:00Z"
            },
            %{
              "window" => "weekly",
              "remaining_fraction" => 0.7,
              "reset_time" => "2026-10-09T12:00:00Z"
            }
          ]
        }
      ]

      assert %{} = CloudCode.refresh(ws.id, :antigravity, agy_opts(groups))

      samples = QuotaSample.history(account_id)
      assert length(samples) == 4

      # 2 buckets x 2 windows
      gemini_5h = Enum.find(samples, &(&1.bucket == "gemini_models" and &1.window == "5h"))

      gemini_weekly =
        Enum.find(samples, &(&1.bucket == "gemini_models" and &1.window == "weekly"))

      claude_5h =
        Enum.find(samples, &(&1.bucket == "claude_and_gpt_models" and &1.window == "5h"))

      claude_weekly =
        Enum.find(samples, &(&1.bucket == "claude_and_gpt_models" and &1.window == "weekly"))

      assert gemini_5h
      assert_in_delta gemini_5h.used, 0.20, 0.001
      assert gemini_weekly
      assert_in_delta gemini_weekly.used, 0.40, 0.001
      assert claude_5h
      assert_in_delta claude_5h.used, 0.10, 0.001
      assert claude_weekly
      assert_in_delta claude_weekly.used, 0.30, 0.001
    end

    test "Codex fetch appends one row per (account, bucket, window)" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "codex")

      fetch! = fn ws, body ->
        Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn -> Req.Test.json(conn, body) end)

        assert %{codex: %{}} =
                 Codex.fetch(ws.id, credentials: %{access_token: "t", account_id: "a"})
      end

      fetch!.(ws, %{
        "plan_type" => "plus",
        "rate_limit" => %{
          "primary_window" => %{"used_percent" => 35, "reset_at" => 1_784_000_000},
          "secondary_window" => %{"used_percent" => 60, "reset_at" => 1_784_500_000}
        }
      })

      samples = QuotaSample.history(account_id)
      assert length(samples) == 2

      primary = Enum.find(samples, &(&1.bucket == "codex" and &1.window in ["5h", "session"]))
      weekly = Enum.find(samples, &(&1.bucket == "codex" and &1.window == "weekly"))

      assert primary
      assert_in_delta primary.used, 0.35, 0.001
      assert weekly
      assert_in_delta weekly.used, 0.60, 0.001
    end
  end

  describe "time-range reads and queries" do
    test "filters by since, until, bucket, window, order, and limit" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")

      base_time = ~U[2026-10-01 10:00:00Z]

      # Insert 5 samples at 1-hour intervals
      for i <- 0..4 do
        t = DateTime.add(base_time, i * 3600, :second)

        Ash.create!(QuotaSample, %{
          provider_account_id: account_id,
          bucket: "claude",
          window: if(rem(i, 2) == 0, do: "5h", else: "7d"),
          used: 0.1 * (i + 1),
          reset_at: DateTime.add(t, 18_000, :second),
          captured_at: t
        })
      end

      # All samples, default asc
      all = QuotaSample.history(account_id)
      assert length(all) == 5

      assert Enum.map(all, & &1.captured_at) ==
               Enum.sort_by(all, & &1.captured_at) |> Enum.map(& &1.captured_at)

      # Desc order
      desc = QuotaSample.history(account_id, order: :desc)
      assert length(desc) == 5
      assert List.first(desc).captured_at == DateTime.add(base_time, 4 * 3600, :second)

      # Time range: since and until
      since_t = DateTime.add(base_time, 3600, :second)
      until_t = DateTime.add(base_time, 3 * 3600, :second)
      filtered = QuotaSample.history(account_id, since: since_t, until: until_t)
      assert length(filtered) == 3

      # Filter by window
      only_5h = QuotaSample.history(account_id, window: "5h")
      assert length(only_5h) == 3
      assert Enum.all?(only_5h, &(&1.window == "5h"))

      # Limit
      limited = QuotaSample.history(account_id, limit: 2)
      assert length(limited) == 2
    end
  end

  describe "retention" do
    test "prune removes rows older than configurable retention days" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old_time = DateTime.add(now, -35 * 86_400, :second)
      recent_time = DateTime.add(now, -5 * 86_400, :second)

      Ash.create!(QuotaSample, %{
        provider_account_id: account_id,
        bucket: "claude",
        window: "5h",
        used: 0.10,
        captured_at: old_time
      })

      Ash.create!(QuotaSample, %{
        provider_account_id: account_id,
        bucket: "claude",
        window: "5h",
        used: 0.20,
        captured_at: recent_time
      })

      assert length(QuotaSample.history(account_id)) == 2

      # Prune with retention_days: 30
      QuotaSample.prune(retention_days: 30)

      remaining = QuotaSample.history(account_id)
      assert length(remaining) == 1
      assert hd(remaining).used == 0.20
    end
  end

  describe "no-regression invariant (§9)" do
    test "recording quota samples does not alter headroom or gate calculations" do
      ws = workspace!()
      {:ok, account_id} = Quota.ensure_account_id(ws.id, "claude")

      assert {:ok, q1} = Quota.capture(ws.id, @headers)
      policy = Quota.gate_policy(account_id, ws)
      headroom_before = Quota.Headroom.binding(q1, policy)

      # QuotaSample recorded
      samples = QuotaSample.history(account_id)
      assert length(samples) == 2

      # Headroom is unchanged
      headroom_after = Quota.Headroom.binding(q1, policy)
      assert headroom_before == headroom_after
    end
  end
end
