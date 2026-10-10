defmodule Arbiter.Quota.SnapshotSpendCapTest do
  @moduledoc """
  `quota_get` / `GET /api/quota` carry the spend state of every capped account
  (bd-a6grlr): cap, window, metered spend, in-flight estimate, whether fresh
  dispatches are being held and why.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Quota.Snapshot
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  defp setup_account(config, spent) do
    n = System.unique_integer([:positive])
    ws = Ash.create!(Workspace, %{name: "qs-#{n}", prefix: "qs#{n}"})
    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "qs-#{n}", quota_config: config})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    Ash.create!(Event, %{
      task_id: "bd-qs-#{n}",
      source: :task,
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      workspace_id: ws.id,
      cost_usd: spent,
      occurred_at: DateTime.utc_now()
    })

    {ws, account}
  end

  test "for_workspace lists a held cap with its reason" do
    {ws, account} = setup_account(%{"spend_cap" => 20.0, "spend_metered" => true}, 25.0)

    assert %{spend_caps: [cap]} = Snapshot.for_workspace(ws.id)
    assert cap["account"] == "claude:#{account.slug}"
    assert cap["holding"] == true
    assert cap["spent_usd"] == 25.0
    assert cap["reason"] =~ "spend cap $20.00/week reached"
  end

  test "for_workspace reports a cap on a non-metered account as no metered spend" do
    {ws, _} = setup_account(%{"spend_cap" => 20.0, "spend_metered" => false}, 400.0)
    assert %{spend_caps: [%{"state" => "no_metered_spend", "holding" => false}]} = Snapshot.for_workspace(ws.id)
  end

  test "for_workspace: no capped account, no entries" do
    {ws, _} = setup_account(%{}, 400.0)
    assert %{spend_caps: []} = Snapshot.for_workspace(ws.id)
  end

  test "for_account carries the one account's cap" do
    {_ws, account} = setup_account(%{"spend_cap" => 20.0, "spend_metered" => true}, 3.0)
    assert %{spend_caps: [%{"spent_usd" => 3.0, "holding" => false}]} = Snapshot.for_account(account)
  end
end
