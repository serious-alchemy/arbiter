defmodule Arbiter.Nodes.PlacementWatch do
  @moduledoc """
  The primary's account of every remote placement attempt (bd-cch1jh): one entry from
  the moment a run is sent toward a node until it is placed, refused or given up on.

  A placement used to be only as bounded as its slowest step. The primary's own half
  (egress, the image plan, published CLI files, the checkout veto) and the wait for the
  node's answer (`Arbiter.Nodes.Session.assign/5` blocks `:infinity`) had no common clock,
  so a step that never returned left the run `starting (no agent)  node=placing: <node>`
  with its seat held and nothing in the log. The `Session`'s own watchdogs only start once
  the run has been assigned.

  An attempt now has three parts:

    * `begin/1` registers it and logs `placement started` (task, node, run);
    * `step/3` runs one phase under the attempt's **single deadline**
      (`config :arbiter, :node_placement, placement_timeout_ms:`, default 30 minutes: the
      node's 25 minute prepare budget plus the primary's own half). Time spent in an
      earlier step is not given again to the next. A phase that overruns is killed and
      answers `{:error, {:remote_placement_failed, {:placement_timeout, stage, ms}}}`, a
      placement failure like any other, so the caller's fallback (the primary, or a hold
      for `remote_only`) takes it from there;
    * `finish/2` unregisters it and logs the outcome, once: `placement placed`,
      `placement refused` (the node's reason and detail), `placement timed out` or
      `placement failed`.

  The attempt begins where the node is chosen (`watch/4`: `Worker.Dispatch`, the conflict
  and fix passes; `ClaudeSession.start/1` for any other caller), so the deadline covers
  building the session opts and the git credential, not only the prepare and assign steps.
  `Arbiter.Nodes.Refusal` turns the timeout into a `placement_timeout` hold for the callers
  that cannot fall back to the primary.

  `in_flight/0`, `stuck/0` and `stuck_runs/2` are what `GET /api/nodes` and `arb doctor`
  read: an attempt still registered past its timeout is a placement the deadline did not
  end, and a run still `placing` past it is one whatever step it hung in.

  The table lives in this process (a `GenServer` under `Arbiter.Nodes.Supervisor`); it
  monitors the attempting process and drops an entry whose process died, and every
  function degrades to "not tracked" if it is not running, so tracking can never fail a
  placement.
  """

  use GenServer

  require Logger

  @default_timeout_ms 30 * 60_000
  @backstop_grace_ms 2_000

  defstruct [:ref, :task_id, :node, :run, :started, :timeout_ms]

  @type t :: %__MODULE__{}

  # ---- the attempt ---------------------------------------------------------------

  @doc """
  Register an attempt and log its start. Options: `:task_id`, `:node` (`%{id, name}`),
  `:run` (the run id, once known), `:timeout_ms` (default `timeout_ms/0`).
  """
  @spec begin(keyword()) :: t()
  def begin(opts) do
    attempt = %__MODULE__{
      ref: make_ref(),
      task_id: Keyword.get(opts, :task_id),
      node: Keyword.get(opts, :node),
      run: Keyword.get(opts, :run),
      started: now(),
      timeout_ms: Keyword.get_lazy(opts, :timeout_ms, &timeout_ms/0)
    }

    tracked(fn -> GenServer.call(__MODULE__, {:register, attempt, self()}) end)
    Logger.info("placement started #{describe(attempt)}")
    attempt
  end

  @doc "Note the run id once the primary's half has minted it."
  @spec put_run(t(), String.t() | nil) :: t()
  def put_run(%__MODULE__{} = attempt, run) do
    tracked(fn -> GenServer.cast(__MODULE__, {:update, attempt.ref, %{run: run}}) end)
    %{attempt | run: run}
  end

  @doc """
  Run `fun` as the attempt's `stage` under what is left of its deadline. Returns what `fun`
  returns, or the `:placement_timeout` error when the deadline passes first (the task is
  killed). An exception in `fun` is raised in the caller, as if it had run inline.
  """
  @spec step(t(), atom(), (-> result)) :: result | {:error, term()} when result: term()
  def step(%__MODULE__{} = attempt, stage, fun) when is_function(fun, 0),
    do: step(attempt, stage, fun, 0)

  # `grace` lets the attempt-level backstop (`watch/4`) outlast the steps inside it, so a
  # step that overruns reports its own stage first.
  defp step(%__MODULE__{} = attempt, stage, fun, grace) do
    tracked(fn -> GenServer.cast(__MODULE__, {:update, attempt.ref, %{stage: stage}}) end)

    case attempt.timeout_ms do
      :infinity ->
        fun.()

      ms ->
        remaining = max(attempt.started + ms - now(), 0) + grace
        run_bounded(fun, remaining, stage, ms)
    end
  end

  # The phase runs in its own process so a deadline can end it; what it returns, raises or
  # exits with is replayed in the caller. `$callers` keeps what the phase reads (a test's
  # sandboxed connection, say) reachable as it was inline.
  defp run_bounded(fun, remaining, stage, ms) do
    parent = self()
    ref = make_ref()
    callers = [parent | Process.get(:"$callers", [])]

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)

        outcome =
          try do
            {:ok, fun.()}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        send(parent, {ref, outcome})
      end)

    receive do
      {^ref, {:ok, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {^ref, {:raised, kind, reason, stacktrace}} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit(reason)
    after
      remaining ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, {:remote_placement_failed, {:placement_timeout, stage, ms}}}
    end
  end

  @doc """
  Watch a whole spawn from the moment its node was chosen (bd-3jjt3p). `build` makes the
  spawn's session opts (`{:ok, opts} | {:error, _}`) and runs as the attempt's
  `:session_opts` step; `start` then spawns with those opts plus `placement_attempt:`
  (so `Arbiter.Worker.ClaudeSession` adds its own steps to *this* deadline rather than
  beginning a later one). The attempt is finished once, with the start's outcome.

  A `nil` node is not a placement: `build` and `start` run unwatched. Returns the start's
  result, or `{:build_error, reason}` when `build` failed (including its timeout,
  `{:remote_placement_failed, {:placement_timeout, :session_opts, ms}}`), so a caller can
  tell a step that never reached the node from a start the node refused.
  """
  @spec watch(
          map() | nil,
          String.t() | nil,
          (-> {:ok, keyword()} | {:error, term()}),
          (keyword() ->
             result)
        ) ::
          result | {:build_error, term()}
        when result: term()
  def watch(nil, _task_id, build, start) do
    case build.() do
      {:ok, opts} -> start.(opts)
      {:error, reason} -> {:build_error, reason}
    end
  end

  def watch(node, task_id, build, start) do
    attempt = begin(task_id: task_id, node: node)

    case step(attempt, :session_opts, build) do
      {:ok, opts} ->
        opts = Keyword.put(opts, :placement_attempt, attempt)

        # The whole spawn is also under one attempt-level timer: a gap between the steps
        # (or a step nobody wrapped) can no longer hold the run in `placing` for ever.
        result = step(attempt, :start, fn -> start.(opts) end, @backstop_grace_ms)

        with {:error, {:remote_placement_failed, {:placement_timeout, :start, _}}} <- result do
          cancel_on_node(attempt, node)
        end

        finish(attempt, result)

      {:error, reason} ->
        finish(attempt, {:error, reason})
        {:build_error, reason}
    end
  end

  # The backstop ended a spawn the node may already know of: tell it to drop the run.
  defp cancel_on_node(attempt, node) do
    run =
      with list when is_list(list) <- tracked(fn -> GenServer.call(__MODULE__, :list) end),
           {%__MODULE__{run: run}, _stage} <-
             Enum.find(list, fn {a, _} -> a.ref == attempt.ref end) do
        run
      else
        _ -> nil
      end

    if is_binary(run), do: Arbiter.Worker.Executor.Node.cancel_placement(node, run)
    :ok
  catch
    _, _ -> :ok
  end

  @doc "End the attempt: unregister it and log the outcome. Returns `result` unchanged."
  @spec finish(t(), result) :: result when result: term()
  def finish(%__MODULE__{} = attempt, result) do
    # the registered copy knows the run id `put_run/2` learnt after this struct was made
    attempt =
      case tracked(fn -> GenServer.call(__MODULE__, {:unregister, attempt.ref}) end) do
        %__MODULE__{} = registered -> registered
        _ -> attempt
      end

    log_outcome(attempt, result)
    result
  end

  defp log_outcome(attempt, {:ok, _}),
    do: Logger.info("placement placed #{describe(attempt)} #{elapsed(attempt)}")

  defp log_outcome(attempt, {:error, {:remote_placement_failed, {:placement_timeout, stage, ms}}}) do
    Logger.warning(
      "placement timed out #{describe(attempt)} stage=#{stage} after #{ms}ms; " <>
        "failing over"
    )
  end

  defp log_outcome(attempt, {:error, {:remote_placement_failed, {:refused, reason, detail}}}),
    do: log_refused(attempt, reason, detail)

  defp log_outcome(attempt, {:error, {:refused, reason, detail}}),
    do: log_refused(attempt, reason, detail)

  defp log_outcome(attempt, {:error, reason}) do
    Logger.warning(
      "placement failed #{describe(attempt)} #{elapsed(attempt)}: #{inspect(reason, limit: 10)}"
    )
  end

  defp log_outcome(attempt, other) do
    Logger.warning("placement failed #{describe(attempt)}: #{inspect(other, limit: 10)}")
  end

  defp log_refused(attempt, reason, detail) do
    Logger.warning(
      "placement refused #{describe(attempt)} reason=#{reason} detail=#{inspect(detail, limit: 10)}"
    )
  end

  defp describe(%__MODULE__{task_id: task, node: node, run: run}) do
    "task=#{task || "?"} node=#{node_label(node)} run=#{run || "?"}"
  end

  defp elapsed(%__MODULE__{started: started}), do: "in #{now() - started}ms"

  defp node_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp node_label(%{id: id}) when is_binary(id), do: id
  defp node_label(id) when is_binary(id), do: id
  defp node_label(_), do: "?"

  # ---- what doctor reads ---------------------------------------------------------

  @doc """
  The placement budget: `config :arbiter, :node_placement, placement_timeout_ms:`
  (default 30 minutes, or `:infinity`).
  """
  @spec timeout_ms() :: pos_integer() | :infinity
  def timeout_ms do
    :arbiter
    |> Application.get_env(:node_placement, [])
    |> Keyword.get(:placement_timeout_ms, @default_timeout_ms)
  end

  @doc "Every attempt in flight: `%{task_id, node_id, node_name, run, stage, age_ms, timeout_ms}`."
  @spec in_flight() :: [map()]
  def in_flight do
    case tracked(fn -> GenServer.call(__MODULE__, :list) end) do
      list when is_list(list) -> Enum.map(list, &view/1)
      _ -> []
    end
  end

  @doc "The in-flight attempts older than their own timeout: placements the deadline did not end."
  @spec stuck() :: [map()]
  def stuck do
    Enum.filter(in_flight(), fn %{age_ms: age, timeout_ms: ms} -> is_integer(ms) and age >= ms end)
  end

  @doc """
  The runs left in `placing` (bd-3jjt3p): a worker snapshot (`Arbiter.Worker.list_children/0`)
  that is still `:starting`, was placed on a node (`meta.placed_node_id`) and has no
  `node_id` yet, for longer than `timeout` (default `timeout_ms/0`). Read from the
  workers, not from the attempts: a step that hung before `begin/1` (or an attempt the
  table lost) leaves no entry in `in_flight/0` but the run still shows `placing`.
  Entries have `in_flight/0`'s shape, with `stage: :placing`.
  """
  @spec stuck_runs([map()], pos_integer() | :infinity) :: [map()]
  def stuck_runs(snapshots, timeout \\ timeout_ms())

  def stuck_runs(_snapshots, :infinity), do: []

  def stuck_runs(snapshots, timeout) when is_list(snapshots) do
    now = DateTime.utc_now()

    for %{state: :starting, meta: %{placed_node_id: node_id} = meta, started_at: %DateTime{} = at} =
          snap <- snapshots,
        is_binary(node_id),
        not is_binary(Map.get(meta, :node_id)),
        age = DateTime.diff(now, at, :millisecond),
        age >= timeout do
      %{
        task_id: Map.get(snap, :task_id),
        node_id: node_id,
        node_name: nil,
        run: Map.get(snap, :run_id),
        stage: :placing,
        age_ms: age,
        timeout_ms: timeout
      }
    end
  end

  defp view({%__MODULE__{} = attempt, stage}) do
    %{
      task_id: attempt.task_id,
      node_id: node_field(attempt.node, :id),
      node_name: node_field(attempt.node, :name),
      run: attempt.run,
      stage: stage,
      age_ms: now() - attempt.started,
      timeout_ms: attempt.timeout_ms
    }
  end

  defp node_field(%{} = node, key), do: Map.get(node, key)
  defp node_field(id, :id) when is_binary(id), do: id
  defp node_field(_node, _key), do: nil

  defp now, do: System.monotonic_time(:millisecond)

  defp tracked(fun) do
    fun.()
  catch
    :exit, _ -> :untracked
  end

  # ---- server --------------------------------------------------------------------

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{attempts: %{}, monitors: %{}}}

  @impl true
  def handle_call({:register, %__MODULE__{ref: ref} = attempt, pid}, _from, state) do
    monitor = Process.monitor(pid)

    state = %{
      state
      | attempts: Map.put(state.attempts, ref, {attempt, :started}),
        monitors: Map.put(state.monitors, monitor, ref)
    }

    {:reply, :ok, state}
  end

  def handle_call({:unregister, ref}, _from, state) do
    registered =
      case state.attempts do
        %{^ref => {attempt, _stage}} -> attempt
        _ -> nil
      end

    {:reply, registered, drop(state, ref)}
  end

  def handle_call(:list, _from, state), do: {:reply, Map.values(state.attempts), state}

  @impl true
  def handle_cast({:update, ref, changes}, state) do
    attempts =
      case state.attempts do
        %{^ref => {attempt, stage}} ->
          attempt =
            if Map.has_key?(changes, :run), do: %{attempt | run: changes.run}, else: attempt

          Map.put(state.attempts, ref, {attempt, Map.get(changes, :stage, stage)})

        _ ->
          state.attempts
      end

    {:noreply, %{state | attempts: attempts}}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor) do
      {nil, _} -> {:noreply, state}
      {ref, monitors} -> {:noreply, %{drop(state, ref) | monitors: monitors}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp drop(state, ref) do
    {monitor, _} = Enum.find(state.monitors, {nil, nil}, fn {_m, r} -> r == ref end)
    if monitor, do: Process.demonitor(monitor, [:flush])

    %{
      state
      | attempts: Map.delete(state.attempts, ref),
        monitors: Map.delete(state.monitors, monitor)
    }
  end
end
