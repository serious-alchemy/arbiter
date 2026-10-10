defmodule Arbiter.Quota.Budget.Server do
  @moduledoc """
  Holds the published provider budgets (bd-6c8g4t, DC3 of
  `docs/design/provider-dynamic-concurrency.md` §3.6-§3.7).

  One `Arbiter.Quota.Budget` per (account, pool, policy workspace) sits in an
  ETS table (`get/4`, `lookup/4`, `all/1`, `for_account/2`). The server
  recomputes them:

    * on every quota capture, `{:quota_captured, account_id}` on
      `capture_topic/0`, which `Arbiter.Quota.Broadcast` sends beside the
      per-workspace `quota_updated`;
    * every `interval_ms` (60 s): the paced line moves continuously;
    * just after each window's `reset_at` (+ 60 s), by a timer re-armed on every
      pass.

  Every pass runs `Budget.compute/1` and `Budget.publish/3`, so the published
  value has the hysteresis of §3.7: a fall at once, a rise only past a
  quarter-seat margin on two recomputes a minute apart, a hard zero at once. A
  change is announced as

      {:budget_changed, %{account:, pool:, policy_workspace:}, from, to, reason}

  on the `board` topic (`from` is `nil` for a pool's first budget). A rise is a
  freed seat, which Autopilot will treat as one when DC6 wires it; nothing
  subscribes for that yet.

  ## Nothing reads it for a decision

  Until DC8 no admission, gate, dispatch or scheduler path may read these
  budgets (invariants I1, I2, I8; pinned by `Arbiter.Quota.BudgetShadowTest`).
  Its readers are the board and CLI displays DC5 adds. A budget never stops
  running work.

  ## Options

    * `:name`, `:table` — the registered name and ETS table name.
    * `:inputs` — `(calibration -> [map])`, the per-pool inputs for
      `Budget.compute/1`, each also carrying `:account_id` and `:pool`. The
      default is `Arbiter.Quota.Budget.Inputs.gather/1`.
    * `:calibration` — `(-> [BudgetCalibration.result])` or `:never`; run at boot
      and daily off the server process (`ρ`, `b` and `H` move slowly, §3.6).
    * `:tick_ms` (default from `config :arbiter, :quota_budget_server`) — or
      `:never`. `:enabled` (default `true`): a disabled server computes nothing.
  """

  use GenServer

  require Logger

  alias Arbiter.Quota.Budget
  alias Arbiter.Quota.Budget.Inputs

  @table :arbiter_quota_budgets
  @board_topic "board"
  @default_tick_ms 60_000
  @initial_delay_ms 5_000
  @calibration_every_ms 24 * 3_600_000
  @reset_margin_ms 60_000

  # ---- reads (ETS, no process call) ------------------------------------------

  @doc "The PubSub topic a quota capture is announced on."
  @spec capture_topic() :: String.t()
  def capture_topic, do: Arbiter.Quota.Broadcast.capture_topic()

  @doc "The published budget of `account_id`'s `pool` under `policy_workspace`, or `nil`."
  @spec get(String.t(), String.t(), String.t() | nil, atom()) :: Budget.t() | nil
  def get(account_id, pool, policy_workspace \\ nil, table \\ @table) do
    case :ets.lookup(table, {account_id, pool, policy_workspace}) do
      [{_key, budget}] -> budget
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Every published budget."
  @spec all(atom()) :: [Budget.t()]
  def all(table \\ @table) do
    table |> :ets.tab2list() |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  @doc "The published budgets of one account, one per pool."
  @spec for_account(String.t(), atom()) :: [Budget.t()]
  def for_account(account_id, table \\ @table) do
    Enum.filter(all(table), &(&1.account == account_id and &1.policy_workspace == nil))
  end

  @doc """
  The budget a card is held to on `account_id`: its `pool`'s, or, when the card's
  predicted model is `nil`, the lowest among the account's pools (§3.1).
  """
  @spec lookup(String.t(), String.t() | nil, String.t() | nil, atom()) :: Budget.t() | nil
  def lookup(account_id, pool, policy_workspace \\ nil, table \\ @table)

  def lookup(account_id, nil, policy_workspace, table) do
    table
    |> all()
    |> Enum.filter(&(&1.account == account_id and &1.policy_workspace == policy_workspace))
    |> Budget.lowest()
  end

  def lookup(account_id, pool, policy_workspace, table),
    do: get(account_id, pool, policy_workspace, table)

  # ---- control ---------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Recompute and publish now, and wait for it."
  @spec recompute(GenServer.server()) :: :ok
  def recompute(server \\ __MODULE__), do: GenServer.call(server, :recompute, 30_000)

  @doc "Milliseconds until the timer armed for the next window reset fires, or `nil`."
  @spec next_reset_ms(GenServer.server()) :: non_neg_integer() | nil
  def next_reset_ms(server \\ __MODULE__), do: GenServer.call(server, :next_reset_ms)

  # ---- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    config = Application.get_env(:arbiter, :quota_budget_server, [])
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    state = %{
      table: table,
      enabled: setting(:enabled, opts, config, true),
      tick_ms: setting(:interval_ms, opts, config, @default_tick_ms, :tick_ms),
      inputs: Keyword.get(opts, :inputs, &Inputs.gather/1),
      calibration_fun: Keyword.get(opts, :calibration, &Inputs.calibrate/0),
      calibration: Inputs.empty_calibration(),
      calibration_task: nil,
      hysteresis: %{},
      trusted: %{},
      reset_timer: nil,
      next_reset_at: nil
    }

    if state.enabled do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, capture_topic())
      schedule_tick(state.tick_ms, min_delay(state.tick_ms))
      send(self(), :calibrate)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:recompute, _from, state), do: {:reply, :ok, recompute_state(state)}

  def handle_call(:next_reset_ms, _from, %{next_reset_at: nil} = state),
    do: {:reply, nil, state}

  def handle_call(:next_reset_ms, _from, %{reset_timer: timer} = state) do
    {:reply, Process.read_timer(timer) || 0, state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = recompute_state(state)
    schedule_tick(state.tick_ms, state.tick_ms)
    {:noreply, state}
  end

  def handle_info({:quota_captured, _account_id}, state), do: {:noreply, recompute_state(state)}
  def handle_info(:reset_due, state), do: {:noreply, recompute_state(%{state | reset_timer: nil})}

  def handle_info(:calibrate, %{calibration_fun: :never} = state), do: {:noreply, state}

  def handle_info(:calibrate, %{calibration_task: nil} = state) do
    fun = state.calibration_fun
    # Not linked: a calibration that raises (DB timeout at boot, bad edge data)
    # must reach the :DOWN clause below, not take this server and its ETS table
    # down with it.
    task = Task.Supervisor.async_nolink(Arbiter.TaskSupervisor, fn -> fun.() end)
    Process.send_after(self(), :calibrate, @calibration_every_ms)
    {:noreply, %{state | calibration_task: task.ref}}
  end

  def handle_info(:calibrate, state), do: {:noreply, state}

  def handle_info({ref, results}, %{calibration_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | calibration_task: nil, calibration: Inputs.index_calibration(results)}
    {:noreply, recompute_state(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{calibration_task: ref} = state) do
    Logger.warning(
      "Arbiter.Quota.Budget.Server: calibration failed (#{inspect(reason)}); priors stay"
    )

    {:noreply, %{state | calibration_task: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ---- recompute -------------------------------------------------------------

  defp recompute_state(%{enabled: false} = state), do: state

  defp recompute_state(state) do
    case safe_inputs(state) do
      {:ok, inputs} ->
        {state, keys} =
          Enum.reduce(inputs, {state, MapSet.new()}, fn input, {state, keys} ->
            {key, state} = publish_one(state, input)
            {state, MapSet.put(keys, key)}
          end)

        state |> drop_missing(keys) |> arm_reset_timer()

      # A failed read keeps what is published rather than clearing it.
      :error ->
        state
    end
  end

  defp safe_inputs(state) do
    {:ok, state.inputs.(state.calibration)}
  rescue
    e ->
      Logger.warning(
        "Arbiter.Quota.Budget.Server: reading inputs failed: #{Exception.message(e)}"
      )

      :error
  catch
    :exit, reason ->
      Logger.warning("Arbiter.Quota.Budget.Server: reading inputs failed: #{inspect(reason)}")
      :error
  end

  # A pool the inputs no longer report (account disabled, workspace unlinked) is
  # unpublished.
  defp drop_missing(state, keys) do
    gone =
      for {key, _budget} <- :ets.tab2list(state.table), not MapSet.member?(keys, key), do: key

    Enum.each(gone, &:ets.delete(state.table, &1))

    %{
      state
      | hysteresis: Map.drop(state.hysteresis, gone),
        trusted: Map.drop(state.trusted, gone)
    }
  end

  # One pool's failure is that pool's alone (bd-1p8cxk): it is logged and
  # published as an `:error` budget, and the other pools publish as usual. The
  # server must not crash on its own computation; nothing reads it for a
  # decision.
  defp publish_one(state, input) do
    key = {input.account_id, input.pool, Map.get(input, :policy_workspace)}
    compute_and_publish(state, key, input)
  rescue
    e -> publish_error(state, input, Exception.message(e))
  catch
    kind, reason -> publish_error(state, input, "#{kind}: #{inspect(reason)}")
  end

  defp publish_error(state, input, message) do
    key = {Map.get(input, :account_id), Map.get(input, :pool), Map.get(input, :policy_workspace)}
    {account, pool, workspace} = key

    Logger.error(
      "Arbiter.Quota.Budget.Server: computing the budget of #{inspect(key)} failed: #{message}"
    )

    old = get(account, pool, workspace, state.table)

    errored = %Budget{
      account: account,
      pool: pool,
      policy_workspace: workspace,
      budget: (old && old.budget) || 0,
      binding: :error,
      reason: "budget computation failed: #{message}",
      computed_at: DateTime.utc_now()
    }

    :ets.insert(state.table, {key, errored})
    if old == nil or old.binding != :error, do: announce(key, old, errored)

    {key, state}
  end

  defp compute_and_publish(state, key, input) do
    previous = Map.get(state.trusted, key)
    old = get(elem(key, 0), elem(key, 1), elem(key, 2), state.table)

    computed = Budget.compute(Map.put(input, :previous, previous))

    {published, hyst} =
      Budget.publish(
        computed,
        Map.get(state.hysteresis, key, Budget.new_hysteresis()),
        computed.computed_at
      )

    :ets.insert(state.table, {key, published})

    if old == nil or old.budget != published.budget, do: announce(key, old, published)

    trusted =
      if published.binding in [
           :no_reading,
           :unmetered,
           :provider_refusing,
           :weekly_warning,
           :paused,
           :quota_stop,
           :unavailable
         ],
         do: state.trusted,
         else:
           Map.put(state.trusted, key, %{
             budget: published.budget,
             trusted_at: computed.computed_at
           })

    {key, %{state | hysteresis: Map.put(state.hysteresis, key, hyst), trusted: trusted}}
  end

  defp announce({account, pool, policy_workspace}, old, %Budget{} = published) do
    Phoenix.PubSub.broadcast(
      Arbiter.PubSub,
      @board_topic,
      {:budget_changed, %{account: account, pool: pool, policy_workspace: policy_workspace},
       old && old.budget, published.budget, published.reason}
    )
  end

  # ---- timers ----------------------------------------------------------------

  defp arm_reset_timer(state) do
    if state.reset_timer, do: Process.cancel_timer(state.reset_timer)

    soonest =
      state.table
      |> all()
      |> Enum.flat_map(& &1.windows)
      |> Enum.flat_map(fn w ->
        if is_number(w[:reset_in_h]) and w.reset_in_h > 0, do: [w.reset_in_h], else: []
      end)
      |> Enum.min(fn -> nil end)

    case soonest do
      nil ->
        %{state | reset_timer: nil, next_reset_at: nil}

      hours ->
        ms = round(hours * 3_600_000) + @reset_margin_ms
        %{state | reset_timer: Process.send_after(self(), :reset_due, ms), next_reset_at: ms}
    end
  end

  defp schedule_tick(:never, _delay), do: :ok
  defp schedule_tick(_tick_ms, delay), do: Process.send_after(self(), :tick, delay)

  defp min_delay(:never), do: 0
  defp min_delay(tick_ms), do: min(tick_ms, @initial_delay_ms)

  defp setting(key, opts, config, default, opt_key \\ nil) do
    Keyword.get(opts, opt_key || key, Keyword.get(config, key, default))
  end
end
