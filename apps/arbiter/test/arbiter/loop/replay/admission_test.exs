defmodule Arbiter.Loop.Replay.AdmissionTest do
  @moduledoc """
  bd-c7lx65 (R15; `docs/design/paced-quota-routing-signals.md` §7.3, re-scoped by
  `docs/design/provider-dynamic-concurrency.md` §8): a replay spends only quota
  that would expire. It is admitted only while every pool it draws on has room
  under `explore/2` of that pool's budget (half the expiring headroom, in
  seats) beside the replays already running there. The budgets here are real
  `Budget.compute/1` results, so the test reads the same expiring headroom the
  budget publishes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Loop.Replay.Admission
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server, as: BudgetServer
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-10-10 01:40:27Z]
  @five_hours 5 * 3600

  defp account(max_concurrent \\ nil),
    do: %ProviderAccount{
      provider: :claude,
      quota_config: %{"threshold_mode" => "paced"},
      max_concurrent: max_concurrent
    }

  defp snapshot(used_5h, used_7d, reset_5h_s, reset_7d_s) do
    %Snapshot{
      provider: "claude",
      utilization: used_5h,
      status: "allowed",
      reset_at: DateTime.add(@now, reset_5h_s, :second),
      captured_at: @now,
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: used_7d,
      secondary_status: "allowed",
      secondary_reset_at: DateTime.add(@now, reset_7d_s, :second),
      secondary_window_label: "7d"
    }
  end

  # A quiet pool: both windows barely used, nothing running. `BudgetTest`'s
  # "explore is half of it" fixture, where `explore/2` is 2.
  defp quiet(account_id \\ "acct-claude", overrides \\ []) do
    [
      account: account(),
      account_id: account_id,
      pool: "claude",
      quota: snapshot(0.10, 0.10, @five_hours, 3 * 86_400),
      now: @now,
      seats: 0,
      horizon: 2.0
    ]
    |> Keyword.merge(overrides)
    |> Budget.compute()
  end

  # A busy pool near its line: §3.8 Example A's live readings with three seats.
  defp busy(account_id) do
    Budget.compute(
      account: account(3),
      account_id: account_id,
      pool: "codex",
      quota: %{
        snapshot(0.19, 0.49, 3 * 3600, 2 * 86_400)
        | reset_at: ~U[2026-10-10 04:40:00Z],
          secondary_reset_at: ~U[2026-10-12 16:00:00Z]
      },
      now: @now,
      seats: 3,
      horizon: 2.0
    )
  end

  defp budgets(map), do: fn account_id, pool -> Map.get(map, {account_id, pool}) end

  describe "check/3" do
    test "admits a replay while its pool has expiring headroom to explore" do
      budget = quiet()
      assert Budget.explore(budget) == 2

      assert {:ok, [entry]} =
               Admission.check(
                 [{"acct-claude", "claude"}],
                 budgets(%{{"acct-claude", "claude"} => budget})
               )

      assert %{account_id: "acct-claude", pool: "claude", explore: 2, running: 0, admitted: true} =
               entry

      assert entry.expiring["5h"] > 0
      assert entry.expiring["7d"] > 0
    end

    test "refuses a pool with no expiring headroom: the draw would come out of quota live work needs" do
      budget = busy("acct-codex")
      assert Budget.explore(budget) == 0

      assert {:refused, reason, [entry]} =
               Admission.check(
                 [{"acct-codex", "codex"}],
                 budgets(%{{"acct-codex", "codex"} => budget})
               )

      assert reason =~ "acct-codex/codex"
      assert reason =~ "no expiring headroom"
      assert %{explore: 0, admitted: false} = entry
    end

    test "a hard zero refuses even a quiet pool" do
      budget = quiet("acct-claude", hard: :paused)

      assert {:refused, reason, [%{binding: "paused"}]} =
               Admission.check(
                 [{"acct-claude", "claude"}],
                 budgets(%{{"acct-claude", "claude"} => budget})
               )

      assert reason =~ "no expiring headroom"
    end

    test "replays already running on the pool count against its exploration budget" do
      key = {"acct-claude", "claude"}
      lookup = budgets(%{key => quiet()})

      assert {:ok, [%{running: 1}]} = Admission.check([key], lookup, %{key => 1})

      assert {:refused, reason, [%{running: 2, explore: 2, admitted: false}]} =
               Admission.check([key], lookup, %{key => 2})

      assert reason =~ "2 replays running"
    end

    test "no budget is no admission: nothing is published outside the live node" do
      assert {:refused, reason, [%{explore: 0, admitted: false, binding: nil}]} =
               Admission.check([{"acct-claude", "claude"}], fn _, _ -> nil end)

      assert reason =~ "no published budget"
    end

    test "the scoring reviewer's pool needs expiring headroom too" do
      lookup =
        budgets(%{
          {"acct-claude", "claude"} => quiet(),
          {"acct-codex", "codex"} => busy("acct-codex")
        })

      assert {:refused, reason, [implementer, reviewer]} =
               Admission.check([{"acct-claude", "claude"}, {"acct-codex", "codex"}], lookup)

      assert reason =~ "acct-codex/codex"
      assert implementer.admitted
      refute reviewer.admitted
    end

    test "one pool serving both sides is one seat, counted once" do
      key = {"acct-claude", "claude"}

      assert {:ok, [_one]} = Admission.check([key, key], budgets(%{key => quiet()}), %{key => 1})
    end
  end

  describe "published/4" do
    test "reads what the budget server publishes for the pool: the workspace's policy, else the account's" do
      now = DateTime.utc_now()

      account = %ProviderAccount{
        id: Ecto.UUID.generate(),
        provider: :claude,
        quota_config: %{"threshold_mode" => "paced"}
      }

      quota = %{
        snapshot(0.10, 0.10, @five_hours, 3 * 86_400)
        | captured_at: now,
          reset_at: DateTime.add(now, @five_hours),
          secondary_reset_at: DateTime.add(now, 3 * 86_400)
      }

      inputs = fn _calibration ->
        [
          %{
            account_id: account.id,
            account: account,
            pool: "claude",
            quota: quota,
            now: now,
            seats: 0,
            horizon: 2.0
          }
        ]
      end

      table = :replay_admission_budgets

      start_supervised!(
        {BudgetServer,
         name: :replay_admission_budget_server,
         table: table,
         inputs: inputs,
         enabled: true,
         tick_ms: :never,
         calibration: :never}
      )

      :ok = BudgetServer.recompute(:replay_admission_budget_server)

      # No policy of its own for this workspace: the account's budget applies.
      assert %Budget{account: id} =
               Admission.published(account.id, "claude", "ws-1", table: table)

      assert id == account.id
      assert Admission.published(account.id, "gemini", "ws-1", table: table) == nil

      assert {:ok, [%{explore: 2, admitted: true}]} =
               Admission.check(
                 [{account.id, "claude"}],
                 &Admission.published(&1, &2, "ws-1", table: table)
               )
    end
  end

  describe "running/2" do
    test "counts each running replay once on every pool it holds" do
      rows = [
        %{account_id: "a", pool: "claude", reviewer_account_id: "b", reviewer_pool: "codex"},
        %{account_id: "a", pool: "claude", reviewer_account_id: "a", reviewer_pool: "claude"},
        %{account_id: "b", pool: "codex", reviewer_account_id: nil, reviewer_pool: nil}
      ]

      assert Admission.running(rows) == %{{"a", "claude"} => 2, {"b", "codex"} => 2}
    end
  end

  describe "spend restricted to expiring headroom (§7.3)" do
    property "an admitted replay's draw, with the others running, fits in half of every window's expiring headroom" do
      check all(
              used_5h <- float(min: 0.0, max: 1.0),
              used_7d <- float(min: 0.0, max: 1.0),
              reset_5h_s <- integer(60..@five_hours),
              reset_7d_s <- integer(3600..(7 * 86_400)),
              seats <- integer(0..4),
              running <- integer(0..3),
              max_runs: 200
            ) do
        budget =
          Budget.compute(
            account: account(),
            account_id: "acct",
            pool: "claude",
            quota: snapshot(used_5h, used_7d, reset_5h_s, reset_7d_s),
            now: @now,
            seats: seats,
            horizon: 2.0
          )

        key = {"acct", "claude"}

        case Admission.check([key], budgets(%{key => budget}), %{key => running}) do
          {:ok, _} ->
            for w <- budget.windows, w.status == :ok, is_number(w.expiring) do
              assert (running + 1) * w.rho * budget.horizon <= w.expiring / 2 + 1.0e-9
            end

          {:refused, _reason, _entries} ->
            assert Budget.explore(budget) <= running
        end
      end
    end
  end
end
