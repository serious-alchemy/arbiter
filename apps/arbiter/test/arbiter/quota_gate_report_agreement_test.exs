defmodule Arbiter.QuotaGateReportAgreementTest do
  @moduledoc """
  bd-aw325c (#568): `arb quota` / `quota_get` said "gating dispatch: none" while
  a resume was refused `{:quota_held, id}`. The report must agree with what the
  dispatch gate does: a paused account gates dispatch (the pause gate also
  answers `:quota_held`), and a workspace on the account with a tighter ceiling
  than the one the report happens to read is listed, not hidden. The refusal
  names its gate and the numbers.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Quota
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Dispatch

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp account! do
    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "claude-#{System.unique_integer([:positive])}"
      })

    Ash.create!(AnthropicQuota, %{
      provider_account_id: account.id,
      provider: "claude",
      utilization_5h: 0.10,
      reset_5h_at: DateTime.add(now(), 10_000, :second),
      status_5h: "allowed",
      utilization_7d: 0.37,
      reset_7d_at: DateTime.add(now(), 300_000, :second),
      status_7d: "allowed",
      captured_at: now()
    })

    account
  end

  defp link!(account, name, config) do
    ws = Ash.create!(Workspace, %{name: name, config: config})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id,
      implementer_position: 0
    })

    ws
  end

  describe "Quota.serialize/3 gating fields" do
    test "a workspace on the account with a tighter weekly ceiling is listed" do
      account = account!()
      _loose = link!(account, "aaa-loose", %{})
      tight = link!(account, "zzz-tight", %{"quota" => %{"weekly_threshold" => 0.3}})

      serialized = Quota.serialize(account.id)

      # The workspace the report reads (alphabetically first) is not gated...
      assert serialized.gating_window == nil

      # ...but the one dispatch would read for `zzz-tight` is, and says so.
      assert [%{workspace_id: ws_id, workspace: "zzz-tight", window: "7d", reason: reason}] =
               serialized.gating_workspaces

      assert ws_id == tight.id
      assert reason =~ "7d"
    end

    test "no workspace is gated: the list is empty" do
      account = account!()
      _ws = link!(account, "only", %{})
      assert Quota.serialize(account.id).gating_workspaces == []
    end

    test "a paused account is reported as gating dispatch" do
      account = account!()
      _ws = link!(account, "only", %{})
      {:ok, _} = Arbiter.Providers.Pause.pause(account.id, reason: "jail escape", by: "test")

      serialized = Quota.serialize(account.id)
      assert serialized.gating_window == "paused"
      assert serialized.gating_reason =~ "paused"
      assert serialized.gating_reason =~ "jail escape"
    end
  end

  describe "Dispatch.quota_held_message/2" do
    test "a quota-gate hold names the gate, window, used and threshold" do
      reason = %{
        window: "7d",
        signal: :utilization,
        utilization: 0.49,
        threshold: 0.442,
        mode: :paced,
        phrase: "claude:default 7d quota 49% ≥ paced 44.2%"
      }

      msg = Dispatch.quota_held_message("bd-x", reason)
      assert msg =~ "quota gate"
      assert msg =~ "7d"
      assert msg =~ "49"
      assert msg =~ "44.2"
      assert msg =~ "force_quota"
    end

    test "a pause hold names the pause gate and says force_quota does not lift it" do
      msg =
        Dispatch.quota_held_message("bd-x", %{
          gate: :pause,
          phrase: "held — claude paused: jail escape"
        })

      assert msg =~ "pause gate"
      assert msg =~ "jail escape"
      assert msg =~ "does not"
    end

    test "no recorded hold still names the gate" do
      assert Dispatch.quota_held_message("bd-x", nil) =~ "quota gate"
    end
  end
end
