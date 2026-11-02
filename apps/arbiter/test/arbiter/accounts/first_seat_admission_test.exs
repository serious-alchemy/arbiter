defmodule Arbiter.Accounts.FirstSeatAdmissionTest do
  @moduledoc """
  The first-seat rule's readers (bd-22w64f; design
  `provider-dynamic-concurrency.md` §3.10). Every budget here is the real output
  of `Budget.compute/1` + `Budget.publish/3` for an idle pool under its line
  with raw 0.6, never a hand-built integer, and the readers are exercised
  unchanged: `SeatCheck`, `Admission` (the real reservation), `ResumeSlot`,
  provider routing and reviewer routing. A first-seat pool has one free seat;
  once it is taken a second card is refused, a heavy-weight model included.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.Admission
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.SeatCheck
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.CodexQuota
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ResumeSlot

  @now ~U[2026-10-10 01:40:27Z]

  setup do
    on_exit(fn ->
      Arbiter.Settings.set_scheduler_admission(nil)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    ws =
      Ash.create!(Workspace, %{
        name: "fs-#{System.unique_integer([:positive])}",
        prefix: "fs#{System.unique_integer([:positive])}",
        config: %{
          "routing" => %{"provider_selection" => "most_quota"},
          "review_agent" => %{"type" => ["codex", "gemini", "claude"], "cross_family" => true}
        }
      })

    account = account!(:claude, "fs", %{max_concurrent: 3})
    allow!(ws, account, implementer_position: 0)

    first = Ash.create!(Issue, %{title: "first", workspace_id: ws.id})
    second = Ash.create!(Issue, %{title: "second", workspace_id: ws.id})

    on_exit(fn ->
      Admission.release(first.id)
      Admission.release(second.id)
    end)

    %{ws: ws, account: account, first: first, second: second}
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

  defp allow!(ws, account, positions) do
    Ash.create!(
      WorkspaceProviderAccount,
      Map.merge(
        %{workspace_id: ws.id, provider: account.provider, provider_account_id: account.id},
        Map.new(positions)
      )
    )
  end

  # The first-seat budget of `account`'s `pool`: a fresh window with 10% used,
  # the 5h line at its 35% floor, and a draw of 25%/seat-h, so raw is 0.6.
  defp first_seat_budget(account, pool \\ "claude", seats \\ 0) do
    snapshot = %Snapshot{
      provider: "claude",
      utilization: 0.10,
      status: "allowed",
      reset_at: DateTime.add(@now, 5 * 3600, :second),
      captured_at: @now,
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: 0.10,
      secondary_status: "allowed",
      secondary_reset_at: DateTime.add(@now, 3 * 86_400, :second),
      secondary_window_label: "7d"
    }

    computed =
      Budget.compute(
        account: %ProviderAccount{
          provider: :claude,
          quota_config: %{"threshold_mode" => "paced"},
          max_concurrent: account.max_concurrent
        },
        account_id: account.id,
        pool: pool,
        quota: snapshot,
        now: @now,
        seats: seats,
        horizon: 2.0,
        rates: %{"5h" => %{rho: 0.25}}
      )

    {published, _} = Budget.publish(computed, Budget.new_hysteresis(), @now)
    published
  end

  defp admit(ctx, task, seat_opts, extra \\ []) do
    Admission.admit(
      task,
      :claude,
      [account: ctx.account, mode: :enforce, seat_opts: seat_opts] ++ extra
    )
  end

  describe "SeatCheck and Admission (AC3)" do
    test "the published budget is 1, raw is under 1, and the pool is idle", ctx do
      b = first_seat_budget(ctx.account)

      assert b.raw < 1.0
      assert b.budget == 1
      assert b.reason =~ "first-seat rule"
      assert {:ok, %{seats: 0, limit: 1}} = SeatCheck.check(ctx.account, check_opts(ctx, [b]))
    end

    test "the second card is refused while the first is running", ctx do
      b = first_seat_budget(ctx.account)

      seat_opts = [budgets: [b], holders: %{}]
      assert {:ok, :admitted} = admit(ctx, ctx.first, seat_opts)

      # the real reservation seats on the pool: the second card is refused while
      # the published first-seat budget (1) is still the one in the table...
      assert {:error, {:account_at_capacity, info}} = admit(ctx, ctx.second, budgets: [b])
      assert info.holders == [ctx.first.id]
      assert info.cap == 1

      # ...and after the recompute with the seat taken (budget back to 0)
      assert {:error, {:account_at_capacity, %{holders: [_]}}} =
               admit(ctx, ctx.second, budgets: [first_seat_budget(ctx.account, "claude", 1)])
    end

    test "the second card is refused against the published first-seat budget as well", ctx do
      b = first_seat_budget(ctx.account)
      holders = %{{ctx.account.id, "claude"} => [{ctx.first.id, nil}]}

      assert {:full, %{seats: 1, limit: 1}} =
               SeatCheck.check(ctx.account, check_opts(ctx, [b], holders: holders))
    end

    test "a heavy-weight model takes the one free seat, and a second card is still refused",
         ctx do
      b = first_seat_budget(ctx.account)
      weights = %{"opus" => 3.0}

      # weight 3.0 over a budget of 1: an idle pool still admits one card
      assert {:ok, %{seats: 0, weight: 3.0}} =
               SeatCheck.check(
                 ctx.account,
                 check_opts(ctx, [b], weights: weights, model: "opus")
               )

      holders = %{{ctx.account.id, "claude"} => [{ctx.first.id, "opus"}]}

      for model <- ["opus", "haiku", nil] do
        assert {:full, %{seats: 1}} =
                 SeatCheck.check(
                   ctx.account,
                   check_opts(ctx, [b], holders: holders, weights: weights, model: model)
                 )
      end
    end
  end

  defp check_opts(ctx, budgets, extra \\ []) do
    Keyword.merge(
      [
        workspace_id: ctx.ws.id,
        pool: "claude",
        share: nil,
        workspace: nil,
        budgets: budgets,
        holders: %{}
      ],
      extra
    )
  end

  describe "ResumeSlot (AC8)" do
    test "takes the first seat; a second resume is held", ctx do
      b = first_seat_budget(ctx.account)

      assert {:ok, :acquired} =
               ResumeSlot.admit(ctx.first,
                 account: ctx.account,
                 mode: :enforce,
                 seat_opts: [budgets: [b], holders: %{}]
               )

      held = %{{ctx.account.id, "claude"} => [ctx.first.id]}

      assert {:error, {:slot_cap_full, _}} =
               ResumeSlot.admit(ctx.second,
                 account: ctx.account,
                 mode: :enforce,
                 seat_opts: [budgets: [b], holders: held, pool: "claude"]
               )
    end
  end

  describe "provider routing (AC8)" do
    setup ctx do
      codex = account!(:codex, "codex", %{max_concurrent: 3})
      allow!(ctx.ws, codex, implementer_position: 1)
      {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)
      %{codex: codex}
    end

    defp fresh_codex do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %CodexQuota{
        provider: "codex",
        session_used_percent: 1.0,
        session_reset_at: DateTime.add(now, 3_600, :second),
        weekly_used_percent: 1.0,
        weekly_reset_at: DateTime.add(now, 302_400, :second),
        limit_reached: false,
        captured_at: now
      }
    end

    defp route(ctx, budgets, holders \\ %{}) do
      ProviderRouting.availability(ctx.ws, ctx.first,
        quota_fun: fn account -> account.id == ctx.codex.id && fresh_codex() end,
        gemini_code: "antigravity",
        seat_opts: [budgets: budgets, holders: holders]
      )
    end

    test "a first-seat pool counts as having a free seat", ctx do
      zero = %Budget{account: ctx.codex.id, pool: "codex", budget: 0, reason: "5h"}
      fs = %{first_seat_budget(ctx.codex, "codex") | pool: "codex"}
      claude = first_seat_budget(ctx.account)

      # control: a budget of 0 drops the pool
      dropped = route(ctx, [claude, zero])
      assert Enum.map(dropped.dropped, & &1.account.id) == [ctx.codex.id]

      result = route(ctx, [claude, fs])
      assert ctx.codex.id in Enum.map(result.available, & &1.account.id)
      assert result.capacity >= 2
    end

    test "once the seat is taken the pool drops at_capacity", ctx do
      fs = %{first_seat_budget(ctx.codex, "codex") | pool: "codex"}
      claude = first_seat_budget(ctx.account)

      result = route(ctx, [claude, fs], %{{ctx.codex.id, "codex"} => ["bd-other"]})
      assert Enum.any?(result.dropped, &(&1.account.id == ctx.codex.id))
    end
  end

  describe "reviewer routing (AC8)" do
    setup ctx do
      codex = account!(:codex, "rcodex", %{})
      agy = account!(:antigravity, "ragy", %{})
      allow!(ctx.ws, codex, reviewer_position: 0)
      allow!(ctx.ws, agy, reviewer_position: 1)
      {:ok, _} = Arbiter.Settings.set_scheduler_admission(:enforce)

      task =
        ctx.ws
        |> then(&Ash.create!(Issue, %{title: "review me", workspace_id: &1.id}))
        |> Ash.Changeset.for_update(:pin_implementer, %{implementer_family: "anthropic"})
        |> Ash.update!()

      %{codex: codex, task: task}
    end

    defp codex_quota do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %CodexQuota{
        provider: "codex",
        session_used_percent: 5.0,
        session_reset_at: DateTime.add(now, 3_600, :second),
        weekly_used_percent: 0.0,
        weekly_reset_at: DateTime.add(now, 302_400, :second),
        limit_reached: false,
        captured_at: now
      }
    end

    defp review(ctx, budget) do
      codex_id = ctx.codex.id

      ReviewerRouting.select(ctx.ws, ctx.task,
        quota_fun: fn account -> account && account.id == codex_id && codex_quota() end,
        gemini_code: "antigravity",
        tier: "standard",
        seat_opts: [budgets: [budget], holders: %{}]
      )
    end

    test "a first-seat pool is a free seat, so its reviewer is chosen", ctx do
      zero = %Budget{account: ctx.codex.id, pool: "codex", budget: 0, reason: "5h"}
      fs = %{first_seat_budget(ctx.codex, "codex") | pool: "codex"}

      # control: with no seat on the codex pool the review goes elsewhere
      assert {:ok, %{family: family}} = review(ctx, zero)
      refute family == :openai

      assert {:ok, %{family: :openai}} = review(ctx, fs)
    end
  end
end
