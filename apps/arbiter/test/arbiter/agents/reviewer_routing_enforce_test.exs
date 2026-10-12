defmodule Arbiter.Agents.ReviewerRoutingEnforceTest do
  @moduledoc """
  The ReviewGate reviewer's routing under `scheduler_admission: enforce` (DC8,
  design `provider-dynamic-concurrency.md` §4.5, E10, O2): a reviewer is a
  follow-up of work In progress, so its pool is dropped only on a hard rule —
  never on the paced line — and among the pools it may use, one with a free seat
  is preferred. Under `legacy` the gate's full check and today's ranking stand.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.{ProviderAccount, WorkspaceProviderAccount}
  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Quota.{Budget, CodexQuota, GoogleQuota}
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    on_exit(fn ->
      Arbiter.Settings.set_scheduler_admission(nil)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    :ok
  end

  defp workspace!(types) do
    Ash.create!(Workspace, %{
      name: "rre-#{System.unique_integer([:positive])}",
      config: %{"review_agent" => %{"type" => types, "cross_family" => true}}
    })
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

  defp allow_reviewer!(ws, account, position) do
    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: account.provider,
      provider_account_id: account.id,
      reviewer_position: position
    })
  end

  defp task!(ws) do
    ws
    |> then(&Ash.create!(Issue, %{title: "review me", workspace_id: &1.id}))
    |> Ash.Changeset.for_update(:pin_implementer, %{implementer_family: "anthropic"})
    |> Ash.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp ahead(secs), do: DateTime.add(now(), secs, :second)

  defp agy_quota(gemini_used, reset_in) do
    bucket = fn group, window, used, reset ->
      %{
        "model_id" => "#{group}_#{window}",
        "remaining_percentage" => 100.0 - used,
        "reset_at" => DateTime.to_iso8601(reset)
      }
    end

    %GoogleQuota{
      provider: "antigravity",
      captured_at: now(),
      reset_at: ahead(reset_in),
      snapshot: %{
        "models" => [
          bucket.("gemini_models", "5h", gemini_used, ahead(reset_in)),
          bucket.("gemini_models", "weekly", 0.0, ahead(302_400)),
          bucket.("claude_and_gpt_models", "5h", 0.0, ahead(9_000)),
          bucket.("claude_and_gpt_models", "weekly", 0.0, ahead(302_400))
        ]
      }
    }
  end

  defp codex_quota(session_pct) do
    %CodexQuota{
      provider: "codex",
      session_used_percent: session_pct,
      session_reset_at: ahead(3_600),
      weekly_used_percent: 0.0,
      weekly_reset_at: ahead(302_400),
      limit_reached: false,
      captured_at: now()
    }
  end

  defp opts(pairs, extra \\ []) do
    by_id = Map.new(pairs, fn {account, quota} -> {account.id, quota} end)

    Keyword.merge(
      [
        quota_fun: fn account -> account && Map.get(by_id, account.id) end,
        gemini_code: "antigravity",
        tier: "standard"
      ],
      extra
    )
  end

  describe "a reviewer pool past its paced line" do
    setup do
      ws = workspace!(["gemini", "claude"])

      paced =
        account!(:antigravity, "paced", %{
          quota_config: %{"threshold_mode" => "paced", "paced_floor" => 0.35}
        })

      allow_reviewer!(ws, paced, 0)
      allow_reviewer!(ws, account!(:claude, "claude"), 1)
      # 40% used with 4.9 h to go: past the 0.35 floor, far under any flat ceiling.
      %{ws: ws, paced: paced, opts: opts([{paced, agy_quota(40.0, 17_640)}])}
    end

    test "legacy: dropped quota_held, so the review falls back to the same family", ctx do
      assert {:ok, sel} = ReviewerRouting.select(ctx.ws, task!(ctx.ws), ctx.opts)
      assert sel.same_family_fallback
      assert sel.fallback_reason =~ "quota_held"
    end

    test "enforce: kept — the hard rules alone drop a follow-up's pool", ctx do
      {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)

      assert {:ok, sel} = ReviewerRouting.select(ctx.ws, task!(ctx.ws), ctx.opts)
      refute sel.same_family_fallback
      assert sel.family == :google
    end
  end

  describe "two pools of other families" do
    setup do
      ws = workspace!(["codex", "gemini", "claude"])
      codex = account!(:codex, "codex")
      agy = account!(:antigravity, "agy")
      allow_reviewer!(ws, codex, 0)
      allow_reviewer!(ws, agy, 1)
      allow_reviewer!(ws, account!(:claude, "claude"), 2)

      # Codex has the most headroom; its pool is the full one.
      quotas = [{codex, codex_quota(5.0)}, {agy, agy_quota(50.0, 9_000)}]

      seat_opts = [
        budgets: [%Budget{account: codex.id, pool: "codex", budget: 0, reason: "5h"}],
        holders: %{}
      ]

      %{ws: ws, codex: codex, opts: opts(quotas, seat_opts: seat_opts)}
    end

    test "legacy: the most headroom reviews", ctx do
      assert {:ok, %{family: :openai}} = ReviewerRouting.select(ctx.ws, task!(ctx.ws), ctx.opts)
    end

    test "enforce: a pool with a free seat is preferred", ctx do
      {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)
      assert {:ok, %{family: :google}} = ReviewerRouting.select(ctx.ws, task!(ctx.ws), ctx.opts)
    end
  end
end
