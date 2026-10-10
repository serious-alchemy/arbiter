defmodule Arbiter.Agents.ProviderRoutingSpendCapTest do
  @moduledoc """
  An account past its dollar spend cap (bd-a6grlr) is dropped as `quota_held`
  for a fresh implementer, so routing sends the ticket to another account
  rather than holding it; a follow-up role is never spend-dropped.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event, as: UsageEvent

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)

    ws =
      Ash.create!(Workspace, %{
        name: "prs-#{System.unique_integer([:positive])}",
        config: %{"routing" => %{"provider_selection" => "most_quota"}}
      })

    %{ws: ws}
  end

  defp account!(ws, provider, position, config \\ %{}) do
    account =
      Ash.create!(ProviderAccount, %{
        provider: provider,
        slug: "#{provider}-#{System.unique_integer([:positive])}",
        quota_config: config
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: provider,
      provider_account_id: account.id,
      implementer_position: position
    })

    account
  end

  defp spend!(account, cost) do
    Ash.create!(UsageEvent, %{
      task_id: "bd-l-#{System.unique_integer([:positive])}",
      source: :task,
      step: :work,
      provider: to_string(account.provider),
      provider_account_id: account.id,
      cost_usd: cost,
      occurred_at: DateTime.utc_now()
    })
  end

  defp dropped_reasons(decision),
    do: Map.new(decision["dropped"], &{&1["account_slug"], &1["reason"]})

  test "a capped account over its cap is dropped for a fresh implementer", %{ws: ws} do
    capped = account!(ws, :claude, 0, %{"spend_cap" => 10.0, "spend_metered" => true})
    open = account!(ws, :codex, 1)
    spend!(capped, 12.0)
    task = Ash.create!(Issue, %{title: "route me", workspace_id: ws.id})

    decision = ProviderRouting.evaluate(ws, task, quota_fun: fn _ -> nil end, gemini_code: "antigravity")

    assert dropped_reasons(decision)[capped.slug] == "quota_held"

    detail = Enum.find(decision["dropped"], &(&1["account_slug"] == capped.slug))["detail"]
    assert detail =~ "spend cap $10.00/week reached"
    assert Enum.map(decision["candidates"], & &1["account_slug"]) == [open.slug]
  end

  test "under the cap it stays a candidate", %{ws: ws} do
    capped = account!(ws, :claude, 0, %{"spend_cap" => 10.0, "spend_metered" => true})
    spend!(capped, 2.0)
    task = Ash.create!(Issue, %{title: "route me", workspace_id: ws.id})

    decision = ProviderRouting.evaluate(ws, task, quota_fun: fn _ -> nil end, gemini_code: "antigravity")

    refute Map.has_key?(dropped_reasons(decision), capped.slug)
  end

  test "a follow-up role is not spend-dropped", %{ws: ws} do
    capped = account!(ws, :claude, 0, %{"spend_cap" => 10.0, "spend_metered" => true})
    spend!(capped, 12.0)
    task = Ash.create!(Issue, %{title: "started", workspace_id: ws.id})

    decision =
      ProviderRouting.evaluate(ws, task,
        quota_fun: fn _ -> nil end,
        gemini_code: "antigravity",
        role: :resume
      )

    refute Map.has_key?(dropped_reasons(decision), capped.slug)
  end
end
