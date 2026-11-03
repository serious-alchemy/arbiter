defmodule Arbiter.Quota.ScopedAdmissionTest do
  @moduledoc """
  bd-e0b7so AC3, AC4: the scoped weekly windows reach admission as nested
  windows of the one `claude` pool. `Budget.Inputs` makes a scoped input per
  window, `Budget.Server` publishes it beside the pool's budget (never as a
  pool), and `SeatCheck` holds a card on the scoped model while another model
  on the same account takes a seat. Seats are counted once, on `claude`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.SeatCheck
  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Inputs
  alias Arbiter.Quota.Budget.Server
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Seats

  @fable "claude-fable-5-1"
  @opus "claude-opus-5-5"
  @account "acct-1"

  defp account!(attrs \\ %{}) do
    Ash.create!(
      ProviderAccount,
      Map.merge(%{provider: :claude, slug: "sc-#{System.unique_integer([:positive])}"}, attrs)
    )
  end

  defp quota!(account, scoped_limits) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Ash.create!(
      AnthropicQuota,
      %{
        provider_account_id: account.id,
        provider: "claude",
        utilization_7d: 0.10,
        status_7d: "allowed",
        reset_7d_at: DateTime.add(now, 3 * 86_400, :second),
        captured_at: now,
        capture_source: "oauth_poll",
        scoped_limits: scoped_limits
      },
      action: :record_oauth_snapshot
    )
  end

  defp window(scope, util, extra \\ %{}) do
    Map.merge(
      %{
        "scope" => scope,
        "utilization" => util,
        "status" => "allowed",
        "reset_at" => nil,
        "is_active" => false
      },
      extra
    )
  end

  defp for_account(inputs, account), do: Enum.filter(inputs, &(&1.account_id == account.id))

  describe "Budget.Inputs.gather/1" do
    test "a scoped window adds one input of the same pool, for the card's model" do
      account = account!()
      quota!(account, [window("Fable", 0.9), window("Mythos", 0.9)])

      assert [base, scoped] = Inputs.gather() |> for_account(account) |> Enum.sort_by(& &1.scope)
      assert %{pool: "claude", scope: nil, model: :unscoped} = base
      assert %{pool: "claude", scope: "Fable", model: "Fable"} = scoped
      assert scoped.seats == base.seats
    end

    test "no scoped window: the pool's input is what it always was" do
      account = account!()
      quota!(account, [])
      assert [%{pool: "claude", scope: nil, model: nil}] = Inputs.gather() |> for_account(account)
    end
  end

  describe "Budget.Server" do
    setup do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      snapshot = fn fable ->
        %Snapshot{
          provider: "claude",
          captured_at: now,
          capture_source: "oauth_poll",
          secondary_utilization: 0.10,
          secondary_status: "allowed",
          secondary_reset_at: DateTime.add(now, 3 * 86_400, :second),
          secondary_window_label: "7d",
          scoped: [
            %{
              scope: "Fable",
              label: "7d (Fable)",
              utilization: fable,
              status: "allowed",
              reset_at: DateTime.add(now, 3 * 86_400, :second),
              active?: false
            }
          ]
        }
      end

      inputs = fn _calibration ->
        base = %{
          account_id: @account,
          account: %ProviderAccount{
            provider: :claude,
            max_concurrent: nil,
            quota_config: %{"threshold_mode" => "paced"}
          },
          pool: "claude",
          quota: snapshot.(0.95),
          now: now,
          seats: 1
        }

        [Map.put(base, :model, :unscoped), Map.merge(base, %{model: "Fable", scope: "Fable"})]
      end

      table = :"scoped_table_#{System.unique_integer([:positive])}"

      server =
        start_supervised!(
          {Server,
           name: :"scoped_server_#{System.unique_integer([:positive])}",
           table: table,
           inputs: inputs,
           tick_ms: :never,
           calibration: :never,
           weights: :never,
           enabled: true}
        )

      :ok = Server.recompute(server)
      %{table: table}
    end

    test "the scoped variant is not a pool: all/1 and for_account/2 list one budget", %{table: t} do
      assert [%Budget{pool: "claude", scope: nil}] = Server.all(t)
      assert [%Budget{scope: nil}] = Server.for_account(@account, t)
      assert [%Budget{scope: "Fable", pool: "claude"}] = Server.scoped(@account, "claude", nil, t)
    end

    test "for_model/5 holds the scoped model and serves the others", %{table: t} do
      base = Server.get(@account, "claude", nil, t)
      assert base.budget >= 1

      scoped = Server.for_model(@account, "claude", nil, @fable, t)
      assert scoped.scope == "Fable"
      assert scoped.budget == 0
      assert scoped.quota_binding == "7d (Fable)"

      assert Server.for_model(@account, "claude", nil, @opus, t).budget == base.budget
      assert Server.for_model(@account, "claude", nil, :unscoped, t).budget == base.budget
      assert Server.for_model(@account, "claude", nil, nil, t).budget == 0
    end

    test "no budget published for the pool is still nil", %{table: t} do
      assert Server.for_model("nope", "claude", nil, @fable, t) == nil
    end
  end

  describe "SeatCheck (AC3, AC4)" do
    defp acct,
      do: %ProviderAccount{id: @account, provider: :claude, slug: "default", quota_config: %{}}

    defp budget(n, attrs) do
      struct!(
        %Budget{
          account: @account,
          pool: "claude",
          policy_workspace: nil,
          budget: n,
          binding: {:window, "7d"},
          reason: "7d binds"
        },
        attrs
      )
    end

    defp check(opts),
      do:
        SeatCheck.check(
          acct(),
          Keyword.merge([workspace_id: nil, pool: "claude", share: nil, workspace: nil], opts)
        )

    test "a card on the scoped model is full while another model takes a seat" do
      budgets = [
        budget(3, []),
        budget(0, scope: "Fable", binding: {:window, "7d (Fable)"}, reason: "7d (Fable) binds")
      ]

      holders = %{{@account, "claude"} => [{"bd-1", @opus}]}

      assert {:full, fable} = check(budgets: budgets, holders: holders, model: @fable)
      assert fable.reason =~ "7d (Fable) binds"

      assert {:ok, opus} = check(budgets: budgets, holders: holders, model: @opus)
      assert opus.budget == 3
      assert opus.pool == "claude"
    end

    test "a card with no predicted model takes the worst of all" do
      budgets = [budget(3, []), budget(0, scope: "Fable")]
      assert {:full, _} = check(budgets: budgets, holders: %{}, model: nil)
    end

    test "with no scoped variant the check is unchanged" do
      assert {:ok, %{budget: 3, limit: 3}} =
               check(budgets: [budget(3, [])], holders: %{}, model: @fable)
    end

    test "seats are one count on the claude pool whatever their models" do
      entries = [
        %{
          registry_key: "t1",
          workspace_id: "ws",
          provider: "claude",
          account_id: @account,
          pool: "claude",
          model: @fable
        },
        %{
          registry_key: "t2",
          workspace_id: "ws",
          provider: "claude",
          account_id: @account,
          pool: "claude",
          model: @opus
        }
      ]

      held = Seats.seats(entries, MapSet.new(["t1", "t2"]))
      assert Map.keys(held) == [{@account, "claude"}]
      assert Seats.tally(held) == %{{@account, "claude"} => 2}

      budgets = [budget(5, []), budget(1, scope: "Fable")]

      # The scoped variant is a different budget for the same two seats: no
      # seat is counted twice, none moves to a pool of its own.
      assert {:full, fable} = check(budgets: budgets, holders: held, model: @fable)
      assert {:ok, opus} = check(budgets: budgets, holders: held, model: @opus)
      assert fable.seats == 2 and opus.seats == 2
      assert fable.pool == "claude" and opus.pool == "claude"
    end
  end
end
