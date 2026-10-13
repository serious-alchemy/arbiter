defmodule Arbiter.Quota.QuotaSnapshotTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.QuotaSnapshot

  test ":record stores integer utilization and ceiling as floats" do
    ws =
      Ash.create!(Arbiter.Tasks.Workspace, %{
        name: "qs-#{System.unique_integer([:positive])}",
        prefix: "qs"
      })

    {:ok, account_id} = Arbiter.Accounts.Resolver.ensure_account_id(ws.id, "claude")

    snap =
      Ash.create!(QuotaSnapshot, %{
        provider_account_id: account_id,
        provider: "claude",
        window: "5h",
        utilization: 0,
        ceiling: 1,
        captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    assert snap.utilization === 0.0
    assert snap.ceiling === 1.0
  end
end
