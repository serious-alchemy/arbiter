defmodule Arbiter.Quota.VisibilityTest do
  @moduledoc """
  bd-i2gwwn: the one "which providers does this installation use" rule the
  status-bar quota chip and `/usage` both read — auto-detected from provider
  settings, overridable install-wide, minus the providers hidden pending
  parity (Codex).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Quota
  alias Arbiter.Quota.Visibility
  alias Arbiter.Settings
  alias Arbiter.Tasks.Workspace

  defp workspace!(name \\ "default", config \\ %{}) do
    Ash.create!(Workspace, %{name: name, config: config})
  end

  defp account!(provider, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(%{provider: provider, slug: "vis-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp link!(ws, account, attrs) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        attrs
      )
    )
  end

  describe "rule/4 (the pure combination)" do
    test "detected providers are shown, the always-hidden ones are not" do
      assert Visibility.rule(["claude", "codex"], [], [], ["codex"]) == ["claude"]
    end

    test "forcing on adds a provider auto-detection missed" do
      assert Visibility.rule(["claude"], ["antigravity"], [], []) == ["claude", "antigravity"]
    end

    test "forcing off removes a detected provider, and wins over forcing on" do
      assert Visibility.rule(["claude", "antigravity"], [], ["claude"], []) == ["antigravity"]
      assert Visibility.rule([], ["claude"], ["claude"], []) == []
    end

    test "the always-hidden list wins over forcing on" do
      assert Visibility.rule([], ["codex"], [], ["codex"]) == []
    end

    test "claude sorts first, the rest alphabetically" do
      assert Visibility.rule(["codex", "antigravity", "claude"], [], [], []) ==
               ["claude", "antigravity", "codex"]
    end
  end

  describe "detected/0" do
    test "an unconfigured workspace runs the default claude" do
      workspace!()
      assert Visibility.detected() == ["claude"]
    end

    test "agent.type / review_agent.type name the providers when nothing is attached" do
      workspace!("default", %{
        "agent" => %{"type" => "gemini"},
        "review_agent" => %{"type" => ["gemini"]}
      })

      assert Visibility.detected() == ["antigravity"]
    end

    test "an attached, enabled account names its provider" do
      ws = workspace!()
      link!(ws, account!(:antigravity), %{implementer_position: 0})

      assert Visibility.detected() == ["antigravity"]
    end

    test "a disabled or deleted attached account does not" do
      ws = workspace!()
      link!(ws, account!(:claude), %{implementer_position: 0})
      link!(ws, account!(:antigravity, %{enabled: false}), %{implementer_position: 1})

      deleted =
        account!(:codex) |> Ash.Changeset.for_update(:soft_delete, %{}) |> Ash.update!()

      link!(ws, deleted, %{reviewer_position: 0})

      assert Visibility.detected() == ["claude"]
    end

    test "a bare metering link (what a probe write provisions) does not" do
      ws = workspace!("default", %{"agent" => %{"type" => "claude"}})

      # CloudProbe's write path provisions the link it stores the snapshot on.
      {:ok, _account_id} = Quota.ensure_account_id(ws.id, "antigravity")

      assert Visibility.detected() == ["claude"]
    end

    test "is the union over every workspace in the installation" do
      workspace!("default", %{"agent" => %{"type" => "claude"}})
      workspace!("other", %{"agent" => %{"type" => "gemini"}})

      assert Visibility.detected() == ["claude", "antigravity"]
    end

    test "no workspaces, no providers" do
      assert Visibility.detected() == []
    end
  end

  describe "providers/0 (detection + the install-wide override)" do
    test "defaults to auto-detect" do
      workspace!()
      assert Settings.quota_providers_shown() == nil
      assert Settings.quota_providers_hidden() == nil
      assert Visibility.providers() == ["claude"]
    end

    test "the override forces a provider on and off" do
      workspace!()
      {:ok, ["antigravity"]} = Settings.set_quota_providers_shown(["antigravity"])
      assert Visibility.providers() == ["claude", "antigravity"]

      {:ok, ["claude"]} = Settings.set_quota_providers_hidden(["claude"])
      assert Visibility.providers() == ["antigravity"]
    end

    test "codex stays hidden even when detected or forced on" do
      workspace!("default", %{"agent" => %{"type" => ["claude", "codex"]}})
      {:ok, _} = Settings.set_quota_providers_shown(["codex"])

      assert "codex" in Visibility.detected()
      refute "codex" in Visibility.providers()
    end
  end

  describe "list_latest_for_workspace/1" do
    test "drops an unused provider's snapshot row" do
      ws = workspace!("default", %{"agent" => %{"type" => "gemini"}})
      {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

      assert Quota.list_latest_for_workspace(ws.id) |> Enum.map(& &1.provider) == ["claude"]

      assert Visibility.list_latest_for_workspace(ws.id) |> Enum.map(& &1.provider) == [
               "antigravity"
             ]
    end

    test "a visible provider with no snapshot row gets a no-data view" do
      ws = workspace!("default", %{"agent" => %{"type" => ["claude", "gemini"]}})
      {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

      assert [claude, antigravity] = Visibility.list_latest_for_workspace(ws.id)
      assert %{provider: "claude", utilization_5h: 0.24} = claude
      refute Map.get(claude, :no_data)

      assert %{provider: "antigravity", no_data: true, utilization_5h: nil, workspace_id: ws_id} =
               antigravity

      assert ws_id == ws.id
      assert %{enforcing?: _} = antigravity.gate_policy
    end

    test "nothing visible, nothing listed" do
      ws = workspace!()
      {:ok, _} = Settings.set_quota_providers_hidden(["claude"])
      {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.24"}])

      assert Visibility.list_latest_for_workspace(ws.id) == []
    end
  end

  describe "the override settings" do
    test "reject anything but quota provider codes" do
      assert {:error, :invalid_value} = Settings.set_quota_providers_shown(["gemini"])
      assert {:error, :invalid_value} = Settings.set_quota_providers_hidden("claude")
      assert {:ok, nil} = Settings.set_quota_providers_hidden(nil)
      assert {:ok, []} = Settings.set_quota_providers_shown([])
    end
  end
end
