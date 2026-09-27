defmodule Arbiter.Quota.GoogleQuotaTest do
  @moduledoc """
  Persistence + read-path tests for the Antigravity quota snapshots
  (bd-ajh7bd). Unlike `Arbiter.Quota.CloudCodeTest` (which is a pure, DB-less
  test of the live HTTP fetch), these exercise `CloudCode.refresh/3` upserting a
  `GoogleQuota` row and the DB read-back accessors, so they use `DataCase`.
  """
  use Arbiter.DataCase, async: false

  import Ecto.Query

  alias Arbiter.Quota.CloudCode
  alias Arbiter.Quota.GoogleQuota
  alias Arbiter.Tasks.Workspace

  defp workspace!(name \\ "default"), do: Ash.create!(Workspace, %{name: name})

  # Antigravity (bd-d7hmqn) no longer fetches over HTTP — it shells out to
  # the `agy` CLI — so its tests stub `agy_usage_probe` instead of `plug`.
  defp antigravity_opts(probe_result), do: [agy_usage_probe: fn -> probe_result end]

  defp agy_usage_body(groups), do: %{"command" => %{"data" => %{"groups" => groups}}}

  # bd-ac53wz: the upstream Gemini CLI provider is dropped, so its Cloud Code
  # probe is gone — only Antigravity (agy) is refreshed.
  describe "refresh/3 (gemini CLI removed)" do
    test "no longer accepts :gemini, and writes no row" do
      ws = workspace!()

      assert_raise FunctionClauseError, fn -> CloudCode.refresh(ws.id, :gemini) end
      assert Repo.aggregate(from(q in "cloud_code_quotas"), :count) == 0
    end

    test "the upstream Gemini CLI fetch is gone from CloudCode" do
      Code.ensure_loaded!(CloudCode)
      refute function_exported?(CloudCode, :gemini, 0)
      refute function_exported?(CloudCode, :gemini, 1)
    end
  end

  describe "refresh/3 (antigravity)" do
    test "persists under the antigravity provider code" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.25, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))

      row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")
      assert %GoogleQuota{provider: "antigravity", used_percent: 75.0} = row
    end

    test "a subsequent degraded fetch (no model data) preserves the last good used_percent/reset_at/snapshot" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.25, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))
      good_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")
      assert good_row.used_percent == 75.0
      refute is_nil(good_row.reset_at)

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:error, {:exit, 1}}))
      degraded_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")

      assert degraded_row.used_percent == good_row.used_percent
      assert degraded_row.reset_at == good_row.reset_at
      assert degraded_row.message =~ "not authenticated"

      # The stored `snapshot` column (what `arb quota`/the MCP tool read back
      # verbatim via `serialize_latest/2`) must carry the *new* degraded
      # message, not the stale good-row copy — only the numeric figures
      # (used_percent/reset_at, asserted above) are preserved.
      assert degraded_row.snapshot["message"] == degraded_row.message

      assert CloudCode.serialize_latest(quota_account_id!(ws.id, "antigravity"), "antigravity")[
               "message"
             ] == degraded_row.message
    end

    test "a degraded fetch that preserves last-good figures also keeps the prior captured_at" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "weekly", "remaining_fraction" => 0.25, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))
      good_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")

      # Backdate the good row's `captured_at` so a later same-second refresh
      # can't accidentally pass this assertion by coincidence.
      backdated = DateTime.add(good_row.captured_at, -3_600, :second)

      {1, nil} =
        Arbiter.Repo.update_all(
          from(q in Arbiter.Quota.GoogleQuota, where: q.id == ^good_row.id),
          set: [captured_at: backdated]
        )

      # bd-au2xhz: a degraded fetch (e.g. a timeout) with no new model data
      # must not stamp `captured_at` with `utc_now()` — that would make stale
      # figures look freshly captured to the Gate/Providers page/`arb quota`.
      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:error, :timeout}))
      degraded_row = CloudCode.latest(quota_account_id!(ws.id, "antigravity"), "antigravity")

      assert degraded_row.captured_at == backdated

      # The stored `snapshot` JSON's own `captured_at` copy — what
      # `serialize_latest/2` returns verbatim to `arb quota --json`,
      # `GET /api/quota` and the MCP quota tool — must agree with the row
      # column rather than being stamped with the failed attempt's `now`.
      assert degraded_row.snapshot["captured_at"] == good_row.snapshot["captured_at"]

      assert CloudCode.serialize_latest(quota_account_id!(ws.id, "antigravity"), "antigravity")[
               "captured_at"
             ] == good_row.snapshot["captured_at"]
    end
  end

  describe "view/1" do
    test "splits an antigravity row's 5h + weekly windows from the gemini_models group" do
      ws = workspace!()

      body =
        agy_usage_body([
          %{
            "name" => "Gemini Models",
            "buckets" => [
              %{"window" => "5h", "remaining_fraction" => 0.75, "reset_time" => "1782250684"},
              %{"window" => "weekly", "remaining_fraction" => 0.4, "reset_time" => "1782250684"}
            ]
          },
          %{
            "name" => "Claude and GPT models",
            "buckets" => [
              %{"window" => "5h", "remaining_fraction" => 1.0, "reset_time" => "1782250684"},
              %{"window" => "weekly", "remaining_fraction" => 1.0, "reset_time" => "1782250684"}
            ]
          }
        ])

      assert CloudCode.refresh(ws.id, :antigravity, antigravity_opts({:ok, body}))

      view =
        quota_account_id!(ws.id, "antigravity")
        |> CloudCode.latest("antigravity")
        |> CloudCode.view()

      assert view.provider == "antigravity"
      assert_in_delta view.utilization_5h, 0.25, 0.0001
      assert %DateTime{} = view.reset_5h_at
      assert_in_delta view.utilization_7d, 0.60, 0.0001
      assert %DateTime{} = view.reset_7d_at
      assert view.primary_label == "5h"
      assert view.secondary_label == "weekly"
      assert length(view.models) == 4
    end

    test "falls back to the collapsed shape when the antigravity snapshot has no parseable buckets" do
      ws = workspace!()

      row =
        Ash.create!(Arbiter.Quota.GoogleQuota, %{
          provider_account_id: quota_account_id!(ws.id, "antigravity"),
          provider: "antigravity",
          used_percent: 42.0,
          reset_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(3600),
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second),
          snapshot: %{"provider" => "antigravity", "models" => []}
        })

      view = CloudCode.view(row)

      assert_in_delta view.utilization_5h, 0.42, 0.0001
      assert view.reset_5h_at == row.reset_at
      assert view.utilization_7d == nil
      assert view.reset_7d_at == nil
      assert view.primary_label == "used"
      assert view.secondary_label == nil
    end
  end
end
