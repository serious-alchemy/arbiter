defmodule Arbiter.Quota.ScopedPollTest do
  @moduledoc """
  bd-e0b7so AC1/AC5: a polled `/api/oauth/usage` body's `weekly_scoped` limits
  are persisted on the quota row (`scoped_limits`), replaced by every poll that
  reports `limits[]`, left alone by one that does not, and an unmatched scope is
  logged once.
  """
  # async: false — the OAuthUsage 429 cooldown lives in :persistent_term.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Quota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.OAuthUsageFixtures
  alias Arbiter.Tasks.Workspace

  setup do
    on_exit(fn -> Quota.OAuthUsage.reset_cooldown!("test-token") end)
    :ok
  end

  defp poll!(ws, body) do
    Req.Test.stub(Quota.OAuthUsage.HTTP, fn conn -> Req.Test.json(conn, body) end)

    {:ok, quota} =
      Quota.capture_oauth_usage(quota_account_id!(ws.id),
        token: "test-token",
        plug: {Req.Test, Quota.OAuthUsage.HTTP}
      )

    quota
  end

  defp workspace!, do: Ash.create!(Workspace, %{name: "default"})

  test "the recorded live shape persists its Fable window" do
    quota = poll!(workspace!(), OAuthUsageFixtures.five_hour_null())

    assert [%{"scope" => "Fable", "utilization" => +0.0, "status" => "allowed"}] =
             quota.scoped_limits

    assert %Snapshot{scoped: [%{scope: "Fable", label: "7d (Fable)"}]} =
             Snapshot.normalize(quota, model: "claude-fable-5-1")
  end

  test "serialize_quota/1 shows every scoped window, matched or not (AC5)" do
    body =
      Map.update!(OAuthUsageFixtures.scoped_exhausted(), "limits", fn limits ->
        limits ++
          [
            %{
              "kind" => "weekly_scoped",
              "group" => "weekly",
              "percent" => 40,
              "severity" => "normal",
              "resets_at" => "2026-11-02T15:59:59.560724+00:00",
              "scope" => %{"model" => %{"id" => nil, "display_name" => "Mythos"}},
              "is_active" => false
            }
          ]
      end)

    serialized = body |> then(&poll!(workspace!(), &1)) |> Quota.serialize_quota()

    assert [
             %{scope: "Fable", label: "7d (Fable)", status: "rejected", matched: true},
             %{scope: "Mythos", status: "allowed", matched: false, is_active: false}
           ] = serialized.scoped

    assert is_binary(hd(serialized.scoped).reset_at)
  end

  test "the legacy shape persists none" do
    quota = poll!(workspace!(), OAuthUsageFixtures.legacy())
    assert quota.scoped_limits == []
  end

  test "a later poll that no longer reports the scoped limit clears it" do
    ws = workspace!()
    assert [_] = poll!(ws, OAuthUsageFixtures.scoped_exhausted()).scoped_limits
    assert poll!(ws, OAuthUsageFixtures.legacy()).scoped_limits == []
  end

  test "a body with no limits[] leaves the stored scoped windows alone" do
    ws = workspace!()
    assert [_] = poll!(ws, OAuthUsageFixtures.scoped_exhausted()).scoped_limits

    body = Map.put(OAuthUsageFixtures.five_hour_null(), "limits", nil)
    assert [%{"scope" => "Fable", "status" => "rejected"}] = poll!(ws, body).scoped_limits
  end

  test "an unmatched scope is logged once, however many polls report it" do
    ws = workspace!()
    scope = "Mythos#{System.unique_integer([:positive])}"

    body =
      Map.update!(OAuthUsageFixtures.five_hour_null(), "limits", fn limits ->
        Enum.map(limits, fn
          %{"kind" => "weekly_scoped"} = l ->
            put_in(l, ["scope", "model", "display_name"], scope)

          l ->
            l
        end)
      end)

    log = capture_log(fn -> poll!(ws, body) end)
    assert log =~ "unmatched"
    assert log =~ scope

    again = capture_log(fn -> poll!(ws, body) end)
    refute again =~ scope
  end
end
