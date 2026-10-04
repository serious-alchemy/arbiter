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
end
