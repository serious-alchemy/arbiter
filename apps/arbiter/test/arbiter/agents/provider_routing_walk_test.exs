defmodule Arbiter.Agents.ProviderRoutingWalkTest do
  @moduledoc """
  `ProviderRouting.availability/3` with `admission: :walk` (DC6,
  provider-dynamic-concurrency §4.2): the scheduler walk asks which accounts a
  ticket is *eligible* for — constraint, guardrails, capability, floor, pause,
  auth, circuit — and leaves capacity and pace to the pool budgets. So an
  account at its `max_concurrent`, or ahead of its paced line, stays a
  candidate; everything else drops exactly as it does for dispatch. Without
  the option nothing changes.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Providers.Pause
  alias Arbiter.Quota.{AnthropicQuota, CodexQuota}
  alias Arbiter.Tasks.{Issue, Workspace}

  @most_quota %{"routing" => %{"provider_selection" => "most_quota"}}

  setup do
    on_exit(fn -> :ets.delete_all_objects(:arbiter_provider_circuit_breakers) end)

    ws =
      Ash.create!(Workspace, %{
        name: "walk-#{System.unique_integer([:positive])}",
        config: @most_quota
      })

    %{ws: ws}
  end

  defp account!(provider, slug, attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(
        %{provider: provider, slug: "#{slug}-#{System.unique_integer([:positive])}"},
        attrs
      )
    )
  end

  defp allow!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      implementer_position: position
    })
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  # Ahead of a paced line: the 5h window resets 4.9 h out, so the line sits at
  # its 0.35 floor and 0.40 used is over it.
  defp ahead_of_pace do
    %AnthropicQuota{
      provider: "claude",
      utilization_5h: 0.40,
      reset_5h_at: ahead(17_640),
      status_5h: "allowed",
      utilization_7d: 0.0,
      reset_7d_at: ahead(302_400),
      status_7d: "allowed",
      captured_at: now()
    }
  end

  defp fresh_codex do
    %CodexQuota{
      provider: "codex",
      session_used_percent: 1.0,
      session_reset_at: ahead(3_600),
      weekly_used_percent: 1.0,
      weekly_reset_at: ahead(302_400),
      limit_reached: false,
      captured_at: now()
    }
  end

  defp opts(pairs, extra \\ []) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)
    Keyword.merge([quota_fun: &Map.get(by_id, &1.id), gemini_code: "antigravity"], extra)
  end

  defp slugs(entries), do: Enum.map(entries, & &1.account.slug)

  test "an account at its cap, or ahead of pace, stays a candidate under the walk", %{ws: ws} do
    paced =
      account!(:claude, "paced", %{
        quota_config: %{"threshold_mode" => "paced", "paced_floor" => 0.35}
      })

    full = account!(:codex, "full", %{max_concurrent: 0})
    allow!(ws, paced, 0)
    allow!(ws, full, 1)

    task = Ash.create!(Issue, %{title: "walk me", workspace_id: ws.id})
    quota = opts([{paced, ahead_of_pace()}, {full, fresh_codex()}])

    # Dispatch's view: both dropped, on capacity and on pace.
    legacy = ProviderRouting.availability(ws, task, quota)
    assert legacy.available == []
    assert Enum.sort(Enum.map(legacy.dropped, & &1.reason)) == ["at_capacity", "quota_held"]

    # The walk's: both eligible, ranked as routing ranks them; the budgets decide.
    walk = ProviderRouting.availability(ws, task, Keyword.put(quota, :admission, :walk))
    assert walk.dropped == []
    assert Enum.sort(slugs(walk.available)) == Enum.sort([paced.slug, full.slug])
    assert Enum.all?(walk.available, &(&1.pool in ["claude", "codex"]))
    assert walk.capacity == nil
  end

  test "a constraint and a pause still drop a candidate under the walk", %{ws: ws} do
    claude = account!(:claude, "claude")
    codex = account!(:codex, "paused")
    allow!(ws, claude, 0)
    allow!(ws, codex, 1)

    {:ok, _} = Pause.pause(codex.id, reason: "maintenance", by: "test")
    on_exit(fn -> Pause.resume(codex.id) end)

    task =
      Ash.create!(Issue, %{
        title: "codex only",
        workspace_id: ws.id,
        provider_constraint: %{"require" => ["codex"]}
      })

    walk = ProviderRouting.availability(ws, task, opts([], admission: :walk))

    assert walk.available == []
    reasons = Map.new(walk.dropped, &{&1.account.slug, &1.reason})
    assert reasons[claude.slug] == "provider_constraint"
    assert reasons[codex.slug] == "paused"
  end
end
