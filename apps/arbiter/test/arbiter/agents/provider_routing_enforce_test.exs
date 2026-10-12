defmodule Arbiter.Agents.ProviderRoutingEnforceTest do
  @moduledoc """
  Implementer routing's availability under `scheduler_admission: enforce` (DC8,
  design `provider-dynamic-concurrency.md` §7 "R5 and R6 routing", E12): for an
  account in `enforce`, feasibility is a free seat on the candidate's pool
  (`Arbiter.Accounts.SeatCheck`) and the quota gate keeps only its hard rules.
  So an account past its paced line stays a candidate while its pool has a
  seat, an account whose pool is full drops `at_capacity`, and `capacity` is
  the sum of free seats. A follow-up role is never dropped for a full pool: it
  holds its ticket's seat already (I9). Under `legacy` nothing changes.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Quota.{AnthropicQuota, Budget, CodexQuota}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    on_exit(fn ->
      Arbiter.Settings.set_scheduler_admission(nil)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    ws =
      Ash.create!(Workspace, %{
        name: "pre-#{System.unique_integer([:positive])}",
        config: %{"routing" => %{"provider_selection" => "most_quota"}}
      })

    paced =
      account!(:claude, "paced", %{quota_config: %{"threshold_mode" => "paced"}})

    codex = account!(:codex, "codex", %{max_concurrent: 3})
    allow!(ws, paced, 0)
    allow!(ws, codex, 1)

    task = Ash.create!(Issue, %{title: "route me", workspace_id: ws.id})
    %{ws: ws, paced: paced, codex: codex, task: task}
  end

  defp account!(provider, slug, attrs) do
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

  # 0.40 used with 4.9 h to go: past the paced 0.35 floor.
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

  defp budget(account, pool, n),
    do: %Budget{
      account: account.id,
      pool: pool,
      budget: n,
      binding: {:window, "5h"},
      reason: "5h"
    }

  # The claude pool has 2 free seats; codex's is full (1 of 1).
  defp opts(ctx, extra \\ []) do
    quotas = %{ctx.paced.id => ahead_of_pace(), ctx.codex.id => fresh_codex()}

    seat_opts = [
      budgets: [budget(ctx.paced, "claude", 2), budget(ctx.codex, "codex", 1)],
      holders: %{{ctx.codex.id, "codex"} => ["bd-other"]}
    ]

    Keyword.merge(
      [quota_fun: &Map.get(quotas, &1.id), gemini_code: "antigravity", seat_opts: seat_opts],
      extra
    )
  end

  defp reasons(entries), do: Map.new(entries, &{&1.account.id, &1.reason})

  test "legacy: the paced line drops claude, codex has headroom under max_concurrent", ctx do
    result = ProviderRouting.availability(ctx.ws, ctx.task, opts(ctx))

    assert Enum.map(result.available, & &1.account.id) == [ctx.codex.id]
    assert reasons(result.dropped) == %{ctx.paced.id => "quota_held"}
  end

  test "enforce: a free seat is feasibility — past the line stays, a full pool drops", ctx do
    {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)
    result = ProviderRouting.availability(ctx.ws, ctx.task, opts(ctx))

    assert Enum.map(result.available, & &1.account.id) == [ctx.paced.id]
    assert reasons(result.dropped) == %{ctx.codex.id => "at_capacity"}
    assert [%{detail: detail}] = result.dropped
    assert detail =~ "1 of 1 seats"
    # The capacity is the free seats.
    assert result.capacity == 2
  end

  test "enforce: a hard rule still drops", ctx do
    {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)
    refusing = %{ahead_of_pace() | status_5h: "rejected"}
    quotas = %{ctx.paced.id => refusing, ctx.codex.id => fresh_codex()}

    result =
      ProviderRouting.availability(
        ctx.ws,
        ctx.task,
        opts(ctx, quota_fun: &Map.get(quotas, &1.id))
      )

    assert reasons(result.dropped)[ctx.paced.id] == "quota_held"
  end

  test "enforce: a follow-up role is never dropped for a full pool", ctx do
    {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)
    result = ProviderRouting.availability(ctx.ws, ctx.task, opts(ctx, role: :resume))

    assert Enum.sort(Enum.map(result.available, & &1.account.id)) ==
             Enum.sort([ctx.paced.id, ctx.codex.id])
  end

  test "a per-account override: only the enforce account is judged by seats", ctx do
    {:ok, _} = Arbiter.Accounts.edit_account(ctx.codex.id, %{"admission" => "enforce"})
    result = ProviderRouting.availability(ctx.ws, ctx.task, opts(ctx))

    # claude stays legacy (dropped on the line); codex is judged by its full pool.
    assert reasons(result.dropped) == %{
             ctx.paced.id => "quota_held",
             ctx.codex.id => "at_capacity"
           }
  end
end
