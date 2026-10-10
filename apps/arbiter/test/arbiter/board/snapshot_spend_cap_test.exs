defmodule Arbiter.Board.SnapshotSpendCapTest do
  @moduledoc """
  The board holds Ready tickets (Autopilot promotes nothing) while the default
  provider's account is past its dollar spend cap (bd-a6grlr) - with the cap's
  own reason, so `arb scheduler status` says why - even with no quota snapshot.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event, as: UsageEvent

  defp setup_account(config, spent) do
    n = System.unique_integer([:positive])
    ws = Ash.create!(Workspace, %{name: "bss-#{n}", prefix: "bss#{n}"})

    account =
      Ash.create!(ProviderAccount, %{provider: :claude, slug: "bss-#{n}", quota_config: config})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    if spent > 0 do
      Ash.create!(UsageEvent, %{
        task_id: "bd-l-#{n}",
        source: :task,
        step: :work,
        provider: "claude",
        provider_account_id: account.id,
        workspace_id: ws.id,
        cost_usd: spent,
        occurred_at: DateTime.utc_now()
      })
    end

    ws
  end

  test "held with the spend-cap reason once the cap is reached, with no quota snapshot" do
    ws = setup_account(%{"spend_cap" => 20.0, "spend_metered" => true}, 25.0)

    assert {:hold, reason} = Snapshot.quota_hold(ws.id)
    assert reason =~ "spend cap $20.00/week reached ($25.00 spent)"
    assert reason =~ "resets"
  end

  test "not held under the cap" do
    ws = setup_account(%{"spend_cap" => 20.0, "spend_metered" => true}, 5.0)
    assert Snapshot.quota_hold(ws.id) == :ok
  end

  test "not held on notional (non-metered) spend" do
    ws = setup_account(%{"spend_cap" => 1.0, "spend_metered" => false}, 400.0)
    assert Snapshot.quota_hold(ws.id) == :ok
  end

  test "no cap, no hold" do
    ws = setup_account(%{}, 400.0)
    assert Snapshot.quota_hold(ws.id) == :ok
  end
end
