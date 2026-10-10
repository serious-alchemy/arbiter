defmodule Arbiter.Quota.Budget.ServerTest do
  @moduledoc """
  DC3 (bd-6c8g4t; design §3.6-§3.8): `Budget.Server` holds the published budget
  per (account, pool, policy) in ETS, recomputes on a quota capture, on a
  timer and at a window reset, applies hysteresis, and announces a change as
  `{:budget_changed, key, from, to, reason}` on the `board` topic. The inputs
  are injected, so the tests drive it with plain snapshots and a pinned clock.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Server
  alias Arbiter.Quota.Gate.Snapshot

  @now ~U[2026-10-10 01:40:27Z]
  @account "acct-1"

  setup do
    {:ok, agent} =
      Agent.start_link(fn -> %{used: 0.19, now: @now, hard: nil, pools: ["claude"]} end)

    Phoenix.PubSub.subscribe(Arbiter.PubSub, "board")
    test = self()

    inputs = fn calibration ->
      send(test, :inputs_read)
      state = Agent.get(agent, & &1)

      for pool <- state.pools do
        %{
          account_id: @account,
          account: %ProviderAccount{
            provider: :claude,
            max_concurrent: nil,
            quota_config: %{"threshold_mode" => "paced"}
          },
          pool: pool,
          rates: for({{@account, ^pool, w}, r} <- calibration.rates, into: %{}, do: {w, r}),
          quota: snapshot(state.used, state.now),
          now: state.now,
          seats: 0,
          hard: state.hard
        }
      end
    end

    %{agent: agent, inputs: inputs}
  end

  defp snapshot(used, now) do
    %Snapshot{
      provider: "claude",
      utilization: used,
      status: "allowed",
      reset_at: DateTime.add(now, 3 * 3600, :second),
      captured_at: now,
      capture_source: "oauth_poll",
      window_label: "5h",
      secondary_utilization: 0.10,
      secondary_status: "allowed",
      secondary_reset_at: DateTime.add(now, 3 * 86_400, :second),
      secondary_window_label: "7d"
    }
  end

  defp start(ctx, extra \\ []) do
    name = :"budget_server_#{System.unique_integer([:positive])}"
    table = :"budget_table_#{System.unique_integer([:positive])}"

    defaults = [
      name: name,
      table: table,
      inputs: ctx.inputs,
      tick_ms: :never,
      calibration: :never,
      enabled: true
    ]

    opts = extra ++ defaults

    start_supervised!({Server, opts})
    {name, table}
  end

  defp set(ctx, changes), do: Agent.update(ctx.agent, &Map.merge(&1, Map.new(changes)))

  test "publishes an integer budget with its reason per pool", ctx do
    {server, table} = start(ctx)
    :ok = Server.recompute(server)

    assert %Budget{budget: n, reason: reason, pool: "claude", account: @account} =
             Server.get(@account, "claude", nil, table)

    assert is_integer(n) and n > 0
    assert is_binary(reason) and reason != ""
    assert Server.all(table) |> length() == 1
  end

  test "announces the first publish and a fall at once, on the board topic", ctx do
    {server, table} = start(ctx)
    :ok = Server.recompute(server)

    assert_receive {:budget_changed, %{account: @account, pool: "claude"}, nil, first, _reason}
    assert first == Server.get(@account, "claude", nil, table).budget

    set(ctx, used: 0.55)
    :ok = Server.recompute(server)

    assert_receive {:budget_changed, %{pool: "claude"}, ^first, fell, reason}
    assert fell < first
    assert is_binary(reason)
    assert Server.get(@account, "claude", nil, table).budget == fell
  end

  test "an unchanged budget announces nothing", ctx do
    {server, _table} = start(ctx)
    :ok = Server.recompute(server)
    assert_receive {:budget_changed, _, nil, _, _}

    :ok = Server.recompute(server)
    refute_receive {:budget_changed, _, _, _, _}, 50
  end

  test "a rise waits out hysteresis: not on the first recompute, once the dwell has passed",
       ctx do
    {server, table} = start(ctx)
    set(ctx, used: 0.55)
    :ok = Server.recompute(server)
    assert_receive {:budget_changed, _, nil, low, _}

    # utilisation drops: raw clears B + 1.25 comfortably, but is only pending
    set(ctx, used: 0.10)
    :ok = Server.recompute(server)
    refute_receive {:budget_changed, _, _, _, _}, 50
    held = Server.get(@account, "claude", nil, table)
    assert held.budget == low
    assert %{since: _} = held.pending_rise

    # a minute later it is published
    set(ctx, now: DateTime.add(@now, 61, :second))
    :ok = Server.recompute(server)
    assert_receive {:budget_changed, _, ^low, rose, _}
    assert rose > low
  end

  test "a hard zero is published at once", ctx do
    {server, table} = start(ctx)
    :ok = Server.recompute(server)
    assert_receive {:budget_changed, _, nil, _, _}

    set(ctx, hard: :paused)
    :ok = Server.recompute(server)

    assert_receive {:budget_changed, _, _, 0, reason}
    assert reason =~ "paused"
    assert %Budget{budget: 0, binding: :paused} = Server.get(@account, "claude", nil, table)
  end

  test "a pool that stops being reported is dropped", ctx do
    {server, table} = start(ctx)
    set(ctx, pools: ["claude", "other"])
    :ok = Server.recompute(server)
    assert length(Server.all(table)) == 2

    set(ctx, pools: ["claude"])
    :ok = Server.recompute(server)
    assert Server.get(@account, "other", nil, table) == nil
    assert length(Server.all(table)) == 1
  end

  test "a card with no predicted model takes the lowest budget among the account's pools", ctx do
    {server, table} = start(ctx)
    set(ctx, pools: ["antigravity:gemini_models", "antigravity:claude_and_gpt_models"])
    :ok = Server.recompute(server)

    budgets = Server.for_account(@account, table)
    assert length(budgets) == 2

    assert Server.lookup(@account, nil, nil, table).budget ==
             budgets |> Enum.map(& &1.budget) |> Enum.min()

    assert Server.lookup(@account, "antigravity:gemini_models", nil, table).pool ==
             "antigravity:gemini_models"

    assert Server.lookup("nobody", nil, nil, table) == nil
  end

  test "reads are safe before the table exists" do
    assert Server.get("x", "claude", nil, :no_such_budget_table) == nil
    assert Server.all(:no_such_budget_table) == []
  end

  describe "calibration (§3.6)" do
    @rung0 %{
      account_id: @account,
      pool: "claude",
      window: "5h",
      horizon_hours: 2.0,
      rung: 0,
      rho: 0.2,
      raw_rho: 0.2,
      floored?: false,
      passed_over: [],
      fit: %{background_share_per_hour: 0.0}
    }

    test "a calibration result reaches the published window's rho", ctx do
      {server, table} = start(ctx, calibration: fn -> [@rung0] end)
      await_calibration(server)

      assert %{rho_source: :fit, rho: 0.2} = window(table, "5h")
    end

    test "a calibration that raises is survived: the server stays up and priors stand", ctx do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {server, table} = start(ctx, calibration: fn -> raise "calibration boom" end)
          pid = GenServer.whereis(server)
          ref = Process.monitor(pid)
          await_calibration(server)

          refute_received {:DOWN, ^ref, :process, ^pid, _}
          :ok = Server.recompute(server)
          assert %{rho_source: :prior} = window(table, "5h")
        end)

      assert log =~ "calibration failed"
    end
  end

  # init queues :calibrate ahead of any call, so once :sys.get_state returns the
  # task is running (or done); poll until its result or crash has been handled.
  defp await_calibration(server, tries \\ 200) do
    case :sys.get_state(server) do
      %{calibration_task: nil} ->
        :ok

      _ when tries == 0 ->
        flunk("calibration never finished")

      _ ->
        Process.sleep(10)
        await_calibration(server, tries - 1)
    end
  end

  defp window(table, label) do
    budget = Server.get(@account, "claude", nil, table)
    Enum.find(budget.windows, &(&1.window == label))
  end

  describe "triggers (§3.6)" do
    test "a timer tick recomputes", ctx do
      start(ctx, tick_ms: 10)
      assert_receive :inputs_read, 500
      assert_receive :inputs_read, 500
    end

    test "a quota capture recomputes", ctx do
      {server, _table} = start(ctx)
      :ok = Server.recompute(server)
      flush_inputs()

      Phoenix.PubSub.broadcast(
        Arbiter.PubSub,
        Server.capture_topic(),
        {:quota_captured, @account}
      )

      assert_receive :inputs_read, 500
    end

    test "Quota.Broadcast announces a capture for the account" do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Server.capture_topic())
      Arbiter.Quota.Broadcast.quota_updated(@account, %{})
      assert_receive {:quota_captured, @account}
    end

    test "a disabled server never reads its inputs", ctx do
      {server, table} = start(ctx, enabled: false)
      :ok = Server.recompute(server)
      refute_receive :inputs_read, 50
      assert Server.all(table) == []
    end

    test "a window reset arms a recompute for just after it", ctx do
      {server, _table} = start(ctx)
      :ok = Server.recompute(server)
      # the 5h window resets in 3 h; the 7d one in 3 days: the earliest wins
      assert_in_delta Server.next_reset_ms(server), 3 * 3600 * 1000 + 60_000, 2_000
    end
  end

  defp flush_inputs do
    receive do
      :inputs_read -> flush_inputs()
    after
      0 -> :ok
    end
  end
end
