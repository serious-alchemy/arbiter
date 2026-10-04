defmodule Arbiter.Quota.HistoryTest do
  @moduledoc "Append-only quota snapshot history, one row per window per poll (bd-5kt9sk)."
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota
  alias Arbiter.Quota.History
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Tasks.Workspace

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)
    on_exit(fn -> Quota.OAuthUsage.reset_cooldown!("test-token") end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.merge(prior, throttle_threshold: 0.85)
      |> Keyword.drop([:weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp poll!(ws, five_hour, seven_day) do
    now = DateTime.utc_now()

    body = %{
      "five_hour" => %{
        "utilization" => five_hour,
        "resets_at" => now |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
      },
      "seven_day" => %{
        "utilization" => seven_day,
        "resets_at" => now |> DateTime.add(3 * 86_400, :second) |> DateTime.to_iso8601()
      }
    }

    Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn -> Req.Test.json(conn, body) end)

    Quota.capture_oauth_usage(quota_account_id!(ws.id),
      token: "test-token",
      plug: {Req.Test, Quota.OAuthUsage.HTTP}
    )
  end

  test "each poll appends one row per window and never overwrites" do
    ws = Ash.create!(Workspace, %{name: "default"})
    account_id = quota_account_id!(ws.id)

    {:ok, _} = poll!(ws, 20, 8)
    {:ok, _} = poll!(ws, 30, 9)

    rows = History.list(account_id)
    assert length(rows) == 4

    five = Enum.filter(rows, &(&1.window == "5h"))
    seven = Enum.filter(rows, &(&1.window == "7d"))
    assert Enum.map(five, & &1.utilization) == [0.2, 0.3]
    assert Enum.map(seven, & &1.utilization) == [0.08, 0.09]
    assert Enum.all?(rows, &(&1.provider == "claude" and is_float(&1.ceiling)))
    assert Enum.all?(five, &(&1.ceiling == 0.85))
  end

  test "a failed poll writes nothing" do
    ws = Ash.create!(Workspace, %{name: "default"})
    Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

    {:error, _} =
      Quota.capture_oauth_usage(quota_account_id!(ws.id),
        token: "test-token",
        plug: {Req.Test, Quota.OAuthUsage.HTTP}
      )

    assert Ash.read!(QuotaSnapshot) == []
  end

  test "a Codex capture appends its session and weekly windows" do
    prev = Application.get_env(:arbiter, :codex_quota_http_stub)
    Application.put_env(:arbiter, :codex_quota_http_stub, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:arbiter, :codex_quota_http_stub),
        else: Application.put_env(:arbiter, :codex_quota_http_stub, prev)
    end)

    ws = Ash.create!(Workspace, %{name: "codex-ws"})

    Req.Test.stub(Arbiter.Quota.Codex.HTTP, fn conn ->
      Req.Test.json(conn, %{
        "plan_type" => "plus",
        "rate_limit" => %{
          "primary_window" => %{"used_percent" => 10, "reset_at" => 1_782_247_200},
          "secondary_window" => %{"used_percent" => 5, "reset_at" => 1_782_748_800}
        }
      })
    end)

    Arbiter.Quota.Codex.fetch(ws.id, credentials: %{access_token: "t", account_id: "a"})

    rows = History.list(quota_account_id!(ws.id, "codex"))
    assert Enum.map(rows, & &1.window) |> Enum.sort() == ["5h", "weekly"]
    assert Enum.all?(rows, &(&1.provider == "codex"))
  end

  test "a secondary-only poll (no five_hour figure) appends no rows" do
    ws = Ash.create!(Workspace, %{name: "default"})
    account_id = quota_account_id!(ws.id)

    {:ok, _} = poll!(ws, 20, 8)
    assert length(History.list(account_id)) == 2

    Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn ->
      Req.Test.json(conn, %{"extra_usage" => %{"is_enabled" => false}})
    end)

    Quota.capture_oauth_usage(account_id,
      token: "test-token",
      plug: {Req.Test, Quota.OAuthUsage.HTTP}
    )

    assert length(History.list(account_id)) == 2
  end

  describe "bucket, time-range reads and retention (bd-3qfc81, R2)" do
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

    test "a header capture appends one row per window, tagged with its bucket" do
      ws = Ash.create!(Workspace, %{name: "default"})
      account_id = quota_account_id!(ws.id)

      assert {:ok, _} = Quota.capture(ws.id, @headers)
      assert {:ok, _} = Quota.capture(ws.id, @headers)

      rows = History.list(account_id)
      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.bucket == "claude" and &1.provider == "claude"))
      assert History.list(account_id, window: "7d") |> Enum.map(& &1.utilization) == [0.08, 0.08]
    end

    test "an Antigravity refresh appends one row per (model group, window)" do
      ws = Ash.create!(Workspace, %{name: "default"})
      account_id = quota_account_id!(ws.id, "antigravity")

      bucket = fn window, remaining, reset ->
        %{"window" => window, "remaining_fraction" => remaining, "reset_time" => reset}
      end

      groups = [
        %{
          "name" => "Gemini Models",
          "buckets" => [
            bucket.("5h", 0.8, "2026-10-04T12:00:00Z"),
            bucket.("weekly", 0.6, "2026-10-08T12:00:00Z")
          ]
        },
        %{
          "name" => "Claude and GPT models",
          "buckets" => [
            bucket.("5h", 0.9, "2026-10-04T14:00:00Z"),
            bucket.("weekly", 0.7, "2026-10-09T12:00:00Z")
          ]
        }
      ]

      probe = fn -> {:ok, %{"command" => %{"data" => %{"groups" => groups}}}} end
      assert %{} = Arbiter.Quota.CloudCode.refresh(ws.id, :antigravity, agy_usage_probe: probe)

      rows = History.list(account_id)
      assert length(rows) == 4

      assert Enum.sort(Enum.map(rows, &{&1.bucket, &1.window})) == [
               {"claude_and_gpt_models", "5h"},
               {"claude_and_gpt_models", "weekly"},
               {"gemini_models", "5h"},
               {"gemini_models", "weekly"}
             ]

      [row] = History.list(account_id, bucket: "gemini_models", window: "5h")
      assert_in_delta row.utilization, 0.2, 0.001
    end

    test "list/2 honours since and until" do
      ws = Ash.create!(Workspace, %{name: "default"})
      account_id = quota_account_id!(ws.id)
      base = ~U[2026-10-01 10:00:00Z]

      for i <- 0..4 do
        Ash.create!(QuotaSnapshot, %{
          provider_account_id: account_id,
          provider: "claude",
          bucket: "claude",
          window: "5h",
          utilization: 0.1 * (i + 1),
          captured_at: DateTime.add(base, i * 3600, :second)
        })
      end

      since = DateTime.add(base, 3600, :second)
      until = DateTime.add(base, 3 * 3600, :second)
      assert length(History.list(account_id, since: since, until: until)) == 3
    end

    test "prune removes rows past the retention window, scoped when asked" do
      ws = Ash.create!(Workspace, %{name: "default"})
      account_id = quota_account_id!(ws.id)
      other_id = quota_account_id!(ws.id, "codex")
      now = DateTime.truncate(DateTime.utc_now(), :second)

      mk = fn id, days_ago ->
        Ash.create!(QuotaSnapshot, %{
          provider_account_id: id,
          provider: "claude",
          window: "5h",
          utilization: 0.1,
          captured_at: DateTime.add(now, -days_ago * 86_400, :second)
        })
      end

      mk.(account_id, 35)
      mk.(account_id, 5)
      mk.(other_id, 35)

      History.prune(retention_days: 30, provider_account_id: account_id)
      assert length(History.list(account_id)) == 1
      assert length(History.list(other_id)) == 1

      History.prune(retention_days: 30)
      assert History.list(other_id) == []
    end

    test "recording history leaves the gate's view of the quota untouched" do
      ws = Ash.create!(Workspace, %{name: "default"})
      account_id = quota_account_id!(ws.id)

      assert {:ok, q} = Quota.capture(ws.id, @headers)
      policy = Quota.gate_policy(account_id, ws)
      before = Quota.Headroom.binding(q, policy)

      assert length(History.list(account_id)) == 2
      assert Quota.Headroom.binding(q, policy) == before
    end
  end
end
