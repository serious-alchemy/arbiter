defmodule Arbiter.Quota.SpendWatchTest do
  @moduledoc """
  The operator is paged when an account's metered spend reaches 80% of its
  dollar cap and again when the cap is reached (bd-a6grlr); the pages clear
  with their condition (the window resets, the cap is raised).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Alerts
  alias Arbiter.Quota.SpendWatch
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  defp account!(config) do
    n = System.unique_integer([:positive])
    ws = Ash.create!(Workspace, %{name: "sw-#{n}", prefix: "sw#{n}"})
    account = Ash.create!(ProviderAccount, %{provider: :claude, slug: "sw-#{n}", quota_config: config})

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    {ws, account}
  end

  defp spend!(account, ws, cost, at \\ DateTime.utc_now()) do
    Ash.create!(Event, %{
      task_id: "bd-sw-#{System.unique_integer([:positive])}",
      source: :task,
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      workspace_id: ws.id,
      cost_usd: cost,
      occurred_at: at
    })
  end

  defp keys, do: Alerts.active(kind: :spend_cap) |> Enum.map(& &1.key) |> Enum.sort()

  test "pages once at 80% of the cap, with the figures" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 16.5)

    :ok = SpendWatch.sweep()

    assert keys() == ["#{account.id}:warning"]
    [alert] = Alerts.active(kind: :spend_cap)
    assert alert.workspace_id == ws.id
    assert alert.subject =~ "80%"
    assert alert.detail =~ "$16.50"
    assert alert.detail =~ "$20.00/week"
  end

  test "below 80% pages nothing" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 10.0)
    :ok = SpendWatch.sweep()
    assert keys() == []
  end

  test "pages again when the cap is reached, replacing the 80% page" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 17.0)
    :ok = SpendWatch.sweep()
    assert keys() == ["#{account.id}:warning"]

    spend!(account, ws, 4.0)
    :ok = SpendWatch.sweep()

    assert keys() == ["#{account.id}:reached"]
    [alert] = Alerts.active(kind: :spend_cap)
    assert alert.subject =~ "reached"
    assert alert.detail =~ "Fresh dispatches on this account are held"
  end

  test "a sweep repeating the same condition refreshes one alert, not a second" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 25.0)
    :ok = SpendWatch.sweep()
    :ok = SpendWatch.sweep()
    assert keys() == ["#{account.id}:reached"]
  end

  test "clears when the cap is raised past the spend" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 25.0)
    :ok = SpendWatch.sweep()
    assert keys() == ["#{account.id}:reached"]

    Ash.update!(account, %{quota_config: %{"spend_cap" => 100.0, "spend_metered" => true}})
    :ok = SpendWatch.sweep()
    assert keys() == []
  end

  test "clears when the window has rolled (spend now counted only inside the window)" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 25.0)
    :ok = SpendWatch.sweep()
    assert keys() == ["#{account.id}:reached"]

    # Next week: the same ledger row is before the new window's start.
    next_week = DateTime.add(DateTime.utc_now(), 8, :day)
    :ok = SpendWatch.sweep(status_opts: [now: next_week])
    assert keys() == []
  end

  test "clears when the cap is removed" do
    {ws, account} = account!(%{"spend_cap" => 20.0, "spend_metered" => true})
    spend!(account, ws, 25.0)
    :ok = SpendWatch.sweep()
    Ash.update!(account, %{quota_config: %{}})
    :ok = SpendWatch.sweep()
    assert keys() == []
  end

  test "notional spend on a non-metered account never pages" do
    {ws, account} = account!(%{"spend_cap" => 1.0, "spend_metered" => false})
    spend!(account, ws, 400.0)
    :ok = SpendWatch.sweep()
    assert keys() == []
  end
end
