defmodule Arbiter.Nodes.Session do
  @moduledoc """
  One process per node that has connected (`docs/design/remote-workers.md` §3,
  §4.2, §10.1–10.3). It owns what the primary knows of the node *between*
  channel connections, so a socket blip (§10.2) loses nothing: the run table,
  the liveness state and the drain flag live here, and the channel
  (`ArbiterWeb.NodeChannel`) is a thin pipe attached to it.

  ## Liveness

  Every `hb` stamps `last_hb` (a monotonic clock). A tick every few seconds
  compares the silence to `Arbiter.Nodes.Liveness`:

    * **suspect** (30 s): not assignable; a heartbeat clears it.
    * **fenced** (`fence_after_s`, 60 s): the agent has by now stopped its own
      containers; recorded once as a `fenced` event.
    * **lost** (`lost_after_s`, 90 s): a `node_lost` event, `{:node_lost, id,
      run_ids}` on `Arbiter.Nodes.topic/0` so the runs' owners interrupt them
      (§10.3), the channel is told to disconnect, and the session stops. The
      invariant `fence_after_s < lost_after_s` makes the container dead before
      anything is re-dispatched.

  Silence is measured by the session's own monotonic clock, never a node's, so
  neither side depends on a shared clock.

  ## Runs placed on the node (RW9)

  `assign/5` puts a run on the node: it registers the run in a
  `Arbiter.Nodes.RunStreams` table, pushes `assign{run, spec}` and answers when
  the node says `run.ready` (or `run.refused`). From then on the node's `stdout`
  frames and `exit` come in through `node_event/3` and the owner (the Worker)
  gets Port-shaped messages (`Arbiter.Worker.Executor.Node`); the table, like
  the rest of the session, survives a channel blip, and the node resends what
  was not acknowledged. When the session ends (node lost, revoked) every live
  run ends for its owner too, flagged `node_lost?`; and an owner that dies has
  its runs cancelled.

  ## Restart recovery and reaping (RW12)

  A run is `known` to a node's `hello` iff this session holds it (§10.4). A run the
  session does not hold whose persisted `worker_runs` row is live and names this node is
  **`hold`** (bd-24o760): the hello can beat `Arbiter.Nodes.Recovery` (the boot sweep
  runs while the endpoint comes up), so the verdict is read from the row, never from what
  recovery has loaded, and the node is not told "unknown" for it. The agent leaves a held
  run running (unattached, not quiesced) until `recover/4` asks for its work (the session
  pushes `quiesce`, then `recover` once it is `retained`), or `hold_ms` (default 150 s,
  above Recovery's 90 s budget) runs out and the session quiesces it like an unknown run;
  each held run is quiesced once. Only agents advertising `caps["run_hold"]` are sent
  `hold`. The rest the
  agent quiesces and reports `retained` (stored here, also read from `hello`'s
  `inventory.retained`). `recover/4` asks for a retained run's work and, while it
  lasts, lets the upload endpoints accept it (`checkout_context/2`); see
  `Arbiter.Nodes.Recovery`. The session also sends `reap{install, live_set}` on every
  `hello` and periodically (`Arbiter.Nodes.Reaping`), and records `retained`,
  `recovered` and `reaped` node events.

  ## Messages to the channel

  `{:node_session, :drain}` / `{:node_session, :undrain}` and
  `{:node_session, {:disconnect, reason}}` with `reason` one of `:revoked`,
  `:lost`, `:superseded`, and `{:node_session, {:upgrade, payload}}` and `{:node_session, {:push, event, payload}}`
  (the run protocol: `assign`, `cancel`, `signal`, `ack`, `exit_ack`). The channel owns
  turning those into pushes and a socket close; the session never touches a socket.

  ## Events broadcast on `Arbiter.Nodes.topic/0`

  `{:node_state, id, :online | :suspect}`, `{:node_connection, id, :up | :down}`,
  `{:node_draining, id, boolean}`, `{:node_lost, id, run_ids}` and — from
  `Arbiter.Nodes` — `{:node_revoked, id}` and `{:node_enrolled, id, join_token_id}`.
  """

  use GenServer, restart: :temporary

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Hello, Liveness, Node, Reaping, RunStreams, Skew}

  @default_tick_ms 5_000
  @default_reap_interval_ms 10 * 60_000
  @default_prepare_timeout_ms 25 * 60_000
  @default_hold_ms 150_000

  defstruct [
    :node_id,
    :name,
    :operator_max,
    :clock,
    :tick_ms,
    :thresholds,
    :channel,
    :channel_ref,
    :last_hb,
    :agent_version,
    :proto,
    :free_mem,
    :load,
    allow_skew?: false,
    state: :online,
    fenced?: false,
    draining?: false,
    health: :ready,
    caps: %{},
    capacity: %{},
    runs: %{},
    streams: %RunStreams{},
    # RW11: `run => the primary's checkout context` (home clone, branch, base),
    # and the callers waiting on a checkout ingest, `run => [from]`.
    checkouts: %{},
    collectors: %{},
    # RW12: what the agent retained (`run => report`), the recoveries in flight
    # (`run => %{ctx, waiters, phase, checkout}`) and the periodic reap.
    retained: %{},
    recoveries: %{},
    # bd-24o760: runs the agent lists that have a live row on this node but no stream here
    # (`run => timer`): held, neither known nor quiesced, until Recovery asks for them or
    # `hold_ms` runs out; `hold_expired` are the ones that ran out (told "unknown" next hello).
    held: %{},
    hold_expired: MapSet.new(),
    hold_ms: @default_hold_ms,
    reap_interval_ms: :infinity
  ]

  # ---- client API ----------------------------------------------------------

  @doc false
  def start_link({%Node{id: id} = node, opts}) do
    GenServer.start_link(__MODULE__, {node, opts}, name: via(id))
  end

  defp via(node_id), do: {:via, Registry, {Arbiter.Nodes.Registry, node_id}}

  @doc "Attach `channel` with the node's `hello` params. See `Arbiter.Nodes.Registry.attach/4`."
  @spec attach(pid(), pid(), map()) :: {:ok, %{pid: pid(), hello_ok: map()}}
  def attach(pid, channel, params), do: GenServer.call(pid, {:attach, channel, params})

  @doc """
  A heartbeat from the node (`pid` or node id). `{:ok, ack}` carries what the
  channel replies with; `{:error, :revoked}` means the node was revoked behind
  the session's back — the session has told its channel to disconnect and
  stopped (the fallback for a missed revoke broadcast); `{:error, :no_session}`
  means no session exists for the id.
  """
  @spec heartbeat(pid() | String.t(), map()) :: {:ok, map()} | {:error, :revoked | :no_session}
  def heartbeat(pid, payload) when is_pid(pid), do: GenServer.call(pid, {:heartbeat, payload})

  def heartbeat(node_id, payload) when is_binary(node_id) do
    case Nodes.Registry.lookup(node_id) do
      nil -> {:error, :no_session}
      pid -> heartbeat(pid, payload)
    end
  end

  @doc "What the primary currently knows of the node, or `nil` when it has no session."
  @spec snapshot(pid() | String.t()) :: map() | nil
  def snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :snapshot)

  def snapshot(node_id) when is_binary(node_id) do
    case Nodes.Registry.lookup(node_id) do
      nil -> nil
      pid -> snapshot(pid)
    end
  end

  @doc "Whether new work may be placed on this node now."
  @spec assignable?(pid()) :: boolean()
  def assignable?(pid), do: GenServer.call(pid, :assignable?)

  @doc """
  Out-of-band news for the session: `:drain`, `:undrain`, `{:disconnect, reason}`
  (revoke), `{:operator_max, n | nil}` (the operator edited the node's cap) or
  `{:upgrade, %{"version", "sha256"}}` (forwarded to the channel). Asynchronous;
  a call made afterwards *by the same process* observes it.
  """
  @spec notify(
          pid(),
          :drain
          | :undrain
          | {:disconnect, atom()}
          | {:operator_max, pos_integer() | nil}
          | {:upgrade, map()}
        ) :: :ok
  def notify(pid, message), do: GenServer.cast(pid, message)

  @doc """
  Place run `run` (a decoded `RunSpec` map) on the node, owned by `owner`.
  Blocks until the node reports the container started (`{:ok, handle}`) or
  refuses (`{:error, {:refused, reason, detail}}`); `{:error, :not_connected}`
  when no channel is attached; `{:error, :prepare_timeout}` after
  `:prepare_timeout_ms`; `{:error, :already_placed}` for a run id in use.
  """
  @spec assign(pid(), String.t(), map(), pid(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def assign(pid, run, spec, owner, opts \\ []),
    do: GenServer.call(pid, {:assign, run, spec, owner, opts}, :infinity)

  @doc """
  The checkout context the primary placed `run` with (`assign/5`'s `:checkout`:
  `%{home, branch, base, seeded_paths}`), or `:error` for a run the session does
  not hold. `ArbiterWeb.NodeController` authorizes the seed and checkout
  endpoints with it: the run must be assigned to *this* node's session.
  """
  @spec checkout_context(pid(), String.t()) :: {:ok, map()} | :error
  def checkout_context(pid, run), do: GenServer.call(pid, {:checkout_context, run})

  @doc """
  Ask the node to upload a checkpoint of `run` now (`kind` is `:checkout`) and wait for
  the primary's ingest of it: `{:ok, result}`, `{:error, reason}` from the ingest, or
  `{:error, :unknown_run | :run_gone | :timeout | :not_connected}`.
  """
  @spec collect(pid(), String.t(), :checkout, timeout()) :: {:ok, term()} | {:error, term()}
  def collect(pid, run, :checkout = kind, timeout \\ 120_000) do
    GenServer.call(pid, {:collect, run, kind}, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  `ArbiterWeb.NodeController` reports the outcome of an ingest: answers whoever is in
  `collect/4`, and records a rejection as a `checkout_rejected` node event.
  """
  @spec checkout_done(pid(), String.t(), {:ok, term()} | {:error, term()}) :: :ok
  def checkout_done(pid, run, result), do: GenServer.cast(pid, {:checkout_done, run, result})

  @doc """
  Recover a run the node **retained** across a primary restart (RW12, §10.4): ask the
  agent to upload its transcripts and checkout bundle, which the upload endpoints
  accept for `run` against `ctx` (`%{home, branch, base, seeded_paths, config_dir}`,
  the context `prepare/3`'s `:checkout` carries) while the recovery lasts. Waits for
  the agent's `recovered` report.

  Returns `{:ok, %{agent: parts, checkout: ingest_result | nil}}`;
  `{:error, :not_on_node}` when the agent neither retains nor still holds the run;
  `{:error, {:recovery_failed, details}}` when an upload was refused; and
  `{:error, :timeout | :not_connected | :node_lost | :already_recovering}`. A run the
  agent is still quiescing is asked for as soon as it reports `retained`.
  """
  @spec recover(pid(), String.t(), map(), timeout()) :: {:ok, map()} | {:error, term()}
  def recover(pid, run, ctx, timeout \\ 60_000) do
    GenServer.call(pid, {:recover, run, ctx}, timeout)
  catch
    :exit, {:timeout, _} ->
      recover_abort(pid, run)
      {:error, :timeout}

    :exit, _ ->
      {:error, :no_session}
  end

  @doc "Withdraw a recovery (its budget ran out): the upload endpoints stop accepting `run`."
  @spec recover_abort(pid(), String.t()) :: :ok
  def recover_abort(pid, run), do: GenServer.cast(pid, {:recover_abort, run})

  @doc "Tell the agent it may delete what it retained of `run` (and forget it here)."
  @spec drop_retained(pid(), String.t()) :: :ok
  def drop_retained(pid, run), do: GenServer.call(pid, {:drop_retained, run})

  @doc "Send the node a `reap` now (what the periodic timer does). `:ok` even when reaping is off."
  @spec reap_now(pid()) :: :ok
  def reap_now(pid), do: GenServer.call(pid, :reap_now)

  @doc """
  Send the node a `reap` against an explicit `live_set` (`Arbiter.Worker.Executor.reap/2`).
  `{:error, :disabled}` when this instance may not reap (not the primary, or off).
  """
  @spec reap(pid(), [String.t()]) :: :ok | {:error, :disabled | :not_connected}
  def reap(pid, live_set), do: GenServer.call(pid, {:reap, live_set})

  @doc "A run event from the node, via the channel: `run.ready`, `run.refused`, `stdout`, `exit`."
  @spec node_event(pid(), String.t(), term()) :: :ok
  def node_event(pid, event, payload), do: GenServer.cast(pid, {:node_event, event, payload})

  @doc "Ask the node to stop `run` (idempotent; remembered across a reconnect)."
  @spec cancel_run(pid(), String.t(), String.t()) :: :ok
  def cancel_run(pid, run, reason), do: GenServer.cast(pid, {:cancel_run, run, reason})

  @doc "Send `signal` (TERM or KILL) to the run's container."
  @spec signal_run(pid(), String.t(), String.t()) :: :ok
  def signal_run(pid, run, signal), do: GenServer.cast(pid, {:signal_run, run, signal})

  @doc "The recorded outcome of an ended run: `{:ok, map}`, `:pending` or `:error`."
  @spec run_outcome(pid(), String.t()) :: {:ok, map()} | :pending | :error
  def run_outcome(pid, run), do: GenServer.call(pid, {:run_outcome, run})

  @doc "Whether the node still has `run` running (assigned and not ended)."
  @spec run_live?(pid(), String.t()) :: boolean()
  def run_live?(pid, run), do: GenServer.call(pid, {:run_live?, run})

  @doc """
  The primary's own socket for `name` of `run`, for a stream the node asks to
  open (`Arbiter.Nodes.Bridge`): `{:error, :unknown_run | :run_ended |
  :unknown_bridge}` unless the run is placed on this node and declared that name.
  """
  @spec bridge_target(pid(), String.t(), String.t()) :: {:ok, Path.t()} | {:error, atom()}
  def bridge_target(pid, run, name), do: GenServer.call(pid, {:bridge_target, run, name})

  @doc """
  The run's owner is going away and leaves the run to the node (RW12 §10.4: the primary
  is stopping). Synchronous, so it lands before the owner's `DOWN`, which would
  otherwise cancel the run (`owner_down`) and have the node remove its container.
  """
  @spec abandon_run(pid(), String.t()) :: :ok
  def abandon_run(pid, run), do: GenServer.call(pid, {:abandon_run, run})

  @doc "Forget an ended run."
  @spec release_run(pid(), String.t()) :: :ok
  def release_run(pid, run), do: GenServer.cast(pid, {:release_run, run})

  @doc "Run the liveness check now (what the timer does). Returns the resulting state."
  @spec tick(pid()) :: Liveness.state()
  def tick(pid), do: GenServer.call(pid, :tick)

  # ---- server --------------------------------------------------------------

  @impl true
  def init({%Node{} = node, opts}) do
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)

    state = %__MODULE__{
      node_id: node.id,
      name: node.name,
      operator_max: node.max_workers,
      draining?: node.status == :draining,
      clock: clock,
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      thresholds: Liveness.current(),
      allow_skew?: Keyword.get(opts, :allow_skew, false),
      last_hb: clock.(),
      reap_interval_ms: Keyword.get(opts, :reap_interval_ms, @default_reap_interval_ms),
      hold_ms: Keyword.get(opts, :hold_ms, @default_hold_ms)
    }

    {:ok, state |> schedule_tick() |> schedule_reap()}
  end

  @impl true
  def handle_call({:attach, channel, params}, _from, state) do
    state = state |> take_over(channel) |> apply_hello(params)

    # A run is "known" iff this session holds it: its Worker placed it in this BEAM
    # (§10.4). A live `worker_runs` row is not enough: after a primary restart the row
    # is still live but its Worker is gone, and the agent must quiesce the run rather
    # than reattach it.
    #
    # bd-24o760: a live row on THIS node with no stream here is a restart that Recovery has
    # not got to yet (the hello can beat it): the verdict comes from the persisted row, so it
    # is "hold", never "unknown". The agent leaves the run running and unattached; Recovery's
    # `recover` quiesces it and takes its work, and `hold_ms` bounds the wait.
    ids = params |> hello_run_list() |> Hello.run_ids()
    state = release_gone_holds(state, ids)
    {verdicts, state} = hello_verdicts(state, ids)

    # Runs we hold that the agent no longer has are over; cancels it may have
    # missed are asked again.
    {streams, lost} = RunStreams.reconcile(state.streams, Hello.run_ids(hello_run_list(params)))
    state = run_effects(%{state | streams: streams}, lost)
    run_effects(state, RunStreams.reattach(state.streams))

    record(state, :connected, %{
      "agent_version" => state.agent_version,
      "proto" => state.proto,
      "health" => Atom.to_string(state.health),
      "boot_epoch" => Nodes.boot_epoch()
    })

    broadcast({:node_connection, state.node_id, :up})
    broadcast({:node_state, state.node_id, :online})

    {:reply, {:ok, %{pid: self(), hello_ok: hello_ok(state, verdicts)}}, send_reap(state)}
  end

  def handle_call({:heartbeat, payload}, _from, state) do
    case Nodes.get_node(state.node_id) do
      %Node{status: status} = node when status != :revoked ->
        state = state |> sync_node(node) |> stamp(payload)
        {:reply, {:ok, ack(payload)}, state}

      _revoked_or_gone ->
        notify_channel(state, {:disconnect, :revoked})
        {:stop, :normal, {:error, :revoked}, state}
    end
  end

  def handle_call({:assign, _run, _spec, _owner, _opts}, _from, %{channel: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:assign, run, spec, owner, opts}, from, state) do
    case RunStreams.fetch(state.streams, run) do
      {:ok, _} ->
        {:reply, {:error, :already_placed}, state}

      :error ->
        Process.monitor(owner)
        # What `Arbiter.Worker.Executor.Node` calls `stop/1` and `signal/2` with.
        handle = {:remote, {state.node_id, run, make_ref()}}
        ms = Keyword.get(opts, :prepare_timeout_ms, @default_prepare_timeout_ms)
        Process.send_after(self(), {:prepare_timeout, run}, ms)

        bridges = bridge_map(spec)

        state = %{
          state
          | streams: RunStreams.open(state.streams, run, handle, owner, from, bridges),
            checkouts: put_checkout(state.checkouts, run, Keyword.get(opts, :checkout))
        }

        notify_channel(state, {:push, "assign", %{"run" => run, "spec" => spec}})
        {:noreply, state}
    end
  end

  def handle_call({:checkout_context, run}, _from, state) do
    with {:ok, _stream} <- RunStreams.fetch(state.streams, run),
         {:ok, ctx} <- Map.fetch(state.checkouts, run) do
      {:reply, {:ok, ctx}, state}
    else
      _ -> {:reply, recovery_context(state, run), state}
    end
  end

  def handle_call({:recover, _run, _ctx}, _from, %{channel: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:recover, run, ctx}, from, state) do
    cond do
      Map.has_key?(state.recoveries, run) ->
        {:reply, {:error, :already_recovering}, state}

      Map.has_key?(state.retained, run) ->
        {:noreply, start_recovery(state, run, ctx, from)}

      # The agent still has it, so it is being quiesced: asked for once it says retained.
      Map.has_key?(state.runs, run) ->
        recovery = %{ctx: ctx, waiters: [from], phase: :waiting, checkout: nil}
        state = %{state | recoveries: Map.put(state.recoveries, run, recovery)}
        {:noreply, quiesce_held(state, run)}

      true ->
        {:reply, {:error, :not_on_node}, state}
    end
  end

  def handle_call({:drop_retained, run}, _from, state) do
    notify_channel(state, {:push, "retained.drop", %{"run" => run}})
    {:reply, :ok, %{state | retained: Map.delete(state.retained, run)}}
  end

  def handle_call(:reap_now, _from, state), do: {:reply, :ok, send_reap(state)}

  def handle_call({:reap, _live_set}, _from, %{channel: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  def handle_call({:reap, live_set}, _from, state) do
    case Reaping.payload(live_set) do
      nil -> {:reply, {:error, :disabled}, state}
      payload -> {:reply, :ok, tap(state, &notify_channel(&1, {:push, "reap", payload}))}
    end
  end

  def handle_call({:collect, _run, _kind}, _from, %{channel: nil} = state),
    do: {:reply, {:error, :not_connected}, state}

  # A read-only checkout (a reviewer's clone, bd-cgdhlu) uploads no bundle, so there is
  # no ingest to wait for: nothing to collect.
  def handle_call({:collect, run, kind}, from, state) do
    cond do
      not (Map.has_key?(state.checkouts, run) and
               match?({:ok, _}, RunStreams.fetch(state.streams, run))) ->
        {:reply, {:error, :unknown_run}, state}

      Map.get(state.checkouts[run], :read_only?, false) ->
        {:reply, {:ok, :read_only}, state}

      true ->
        notify_channel(state, {:push, "collect", %{"run" => run, "kind" => Atom.to_string(kind)}})

        {:noreply,
         %{state | collectors: Map.update(state.collectors, run, [from], &[from | &1])}}
    end
  end

  def handle_call({:bridge_target, run, name}, _from, state),
    do: {:reply, RunStreams.bridge_target(state.streams, run, name), state}

  def handle_call({:run_outcome, run}, _from, state),
    do: {:reply, RunStreams.outcome(state.streams, run), state}

  def handle_call({:abandon_run, run}, _from, state),
    do: {:reply, :ok, %{state | streams: RunStreams.abandon(state.streams, run)}}

  def handle_call({:run_live?, run}, _from, state),
    do: {:reply, run in RunStreams.live(state.streams), state}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}
  def handle_call(:assignable?, _from, state), do: {:reply, assignable_state?(state), state}

  def handle_call(:tick, _from, state) do
    case check(state) do
      {:cont, state} -> {:reply, state.state, state}
      {:stop, state} -> {:stop, :normal, :lost, state}
    end
  end

  @impl true
  def handle_cast(:drain, state), do: {:noreply, set_draining(state, true)}
  def handle_cast(:undrain, state), do: {:noreply, set_draining(state, false)}
  def handle_cast({:operator_max, n}, state), do: {:noreply, %{state | operator_max: n}}

  def handle_cast({:node_event, event, payload}, state),
    do: {:noreply, node_event_apply(state, event, payload)}

  def handle_cast({:cancel_run, run, reason}, state) do
    {streams, effects} = RunStreams.cancel(state.streams, run, reason)
    {:noreply, run_effects(%{state | streams: streams}, effects)}
  end

  def handle_cast({:signal_run, run, signal}, state) do
    if run in RunStreams.live(state.streams),
      do: notify_channel(state, {:push, "signal", %{"run" => run, "signal" => signal}})

    {:noreply, state}
  end

  def handle_cast({:release_run, run}, state), do: {:noreply, drop_run(state, run)}

  def handle_cast({:recover_abort, run}, state) do
    {recovery, recoveries} = Map.pop(state.recoveries, run)
    if recovery, do: Enum.each(recovery.waiters, &GenServer.reply(&1, {:error, :timeout}))
    {:noreply, %{state | recoveries: recoveries}}
  end

  def handle_cast({:checkout_done, run, result}, state) do
    state = note_recovered_checkout(state, run, result)
    {waiters, collectors} = Map.pop(state.collectors, run, [])
    Enum.each(waiters, &GenServer.reply(&1, result))

    case result do
      {:error, reason} ->
        record(state, :checkout_rejected, %{"run" => run, "reason" => inspect(reason, limit: 10)})

      {:ok, _} ->
        :ok
    end

    {:noreply, %{state | collectors: collectors}}
  end

  def handle_cast({:upgrade, payload}, state) do
    notify_channel(state, {:upgrade, payload})
    {:noreply, state}
  end

  def handle_cast({:disconnect, reason}, state) do
    notify_channel(state, {:disconnect, reason})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:tick, state) do
    case check(schedule_tick(state)) do
      {:cont, state} -> {:noreply, state}
      {:stop, state} -> {:stop, :normal, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{channel_ref: ref} = state) do
    record(state, :disconnected, %{"reason" => inspect(reason)})
    broadcast({:node_connection, state.node_id, :down})
    {:noreply, %{state | channel: nil, channel_ref: nil}}
  end

  # A run's owner (the Worker) died: its runs are cancelled and forgotten.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state =
      Enum.reduce(RunStreams.owned_by(state.streams, pid), state, fn run, acc ->
        {streams, effects} = RunStreams.cancel(acc.streams, run, "owner_down")
        run_effects(drop_run(%{acc | streams: streams}, run), effects)
      end)

    {:noreply, state}
  end

  # A hold ran out with nobody asking for the run: it is quiesced like an unknown one.
  def handle_info({:hold_expired, run}, state) do
    if Map.has_key?(state.held, run) and not Map.has_key?(state.recoveries, run) do
      state = %{
        state
        | held: Map.delete(state.held, run),
          hold_expired: MapSet.put(state.hold_expired, run)
      }

      {:noreply, push_quiesce(state, run)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:reap, state), do: {:noreply, state |> send_reap() |> schedule_reap()}

  def handle_info({:prepare_timeout, run}, state) do
    case RunStreams.fetch(state.streams, run) do
      {:ok, %{state: :assigned, waiter: waiter}} when not is_nil(waiter) ->
        GenServer.reply(waiter, {:error, :prepare_timeout})
        {streams, effects} = RunStreams.cancel(state.streams, run, "prepare_timeout")
        {:noreply, run_effects(drop_run(%{state | streams: streams}, run), effects)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # The session ends (node lost, revoked, stopped): nothing will report these
    # runs again, so each ends for its owner rather than leave a Worker waiting.
    {_streams, effects} = RunStreams.node_lost(state.streams)
    run_effects(%{state | channel: nil}, effects)

    for {_run, recovery} <- state.recoveries,
        from <- recovery.waiters,
        do: GenServer.reply(from, {:error, :node_lost})

    :ok
  end

  # ---- run events -----------------------------------------------------------------

  defp node_event_apply(state, "run.ready", %{"run" => run}),
    do: apply_streams(state, RunStreams.ready(state.streams, run))

  defp node_event_apply(state, "run.refused", %{"run" => run} = payload),
    do: apply_streams(state, RunStreams.refused(state.streams, run, payload))

  # A cancel for a run the agent no longer has: it is over.
  defp node_event_apply(state, "run.gone", %{"run" => run}) do
    gone = %{
      "status" => 255,
      "oom" => false,
      "size" => 0,
      "cancelled" => true,
      "reason" => "gone"
    }

    apply_streams(state, RunStreams.exit(state.streams, run, gone))
  end

  defp node_event_apply(state, "exit", %{"run" => run} = payload),
    do: apply_streams(state, RunStreams.exit(state.streams, run, payload))

  defp node_event_apply(state, "stdout", {:binary, frame}) do
    case Arbiter.Nodes.StdoutFrame.decode(frame) do
      {:ok, run, offset, bytes} ->
        apply_streams(state, RunStreams.data(state.streams, run, offset, bytes))

      {:error, :bad_frame} ->
        state
    end
  end

  # RW12: the agent quiesced a run the primary does not know and kept its work.
  defp node_event_apply(state, "retained", %{"run" => run} = report) do
    record(state, :retained, %{"run" => run, "report" => report})
    state = %{state | retained: Map.put(state.retained, run, report)}
    state = forget_hold(state, run)

    case Map.fetch(state.recoveries, run) do
      {:ok, %{phase: :waiting, ctx: ctx, waiters: [from | _]}} ->
        start_recovery(%{state | recoveries: Map.delete(state.recoveries, run)}, run, ctx, from)

      _ ->
        state
    end
  end

  defp node_event_apply(state, "recovered", %{"run" => run} = parts),
    do: finish_recovery(state, run, parts)

  defp node_event_apply(state, "reaped", %{} = report) do
    record(state, :reaped, Map.take(report, ~w(containers pods dirs)))
    state
  end

  defp node_event_apply(state, _event, _payload), do: state

  # ---- recovery ----------------------------------------------------------------------

  defp start_recovery(state, run, ctx, from) do
    notify_channel(state, {:push, "recover", %{"run" => run}})
    recovery = %{ctx: ctx, waiters: [from], phase: :pulling, checkout: nil}
    %{state | recoveries: Map.put(state.recoveries, run, recovery)}
  end

  defp recovery_context(state, run) do
    case Map.get(state.recoveries, run) do
      %{phase: :pulling, ctx: ctx} -> {:ok, ctx}
      _ -> :error
    end
  end

  # The ingest's own verdict (the upload endpoint reports it here).
  defp note_recovered_checkout(state, run, result) do
    case Map.fetch(state.recoveries, run) do
      {:ok, recovery} ->
        %{state | recoveries: Map.put(state.recoveries, run, %{recovery | checkout: result})}

      :error ->
        state
    end
  end

  defp finish_recovery(state, run, parts) do
    case Map.pop(state.recoveries, run) do
      {nil, _} ->
        state

      {%{waiters: waiters, checkout: checkout}, recoveries} ->
        agent = Map.delete(parts, "run")
        ok? = recovery_ok?(agent, checkout)

        reply =
          if ok?,
            do: {:ok, %{agent: agent, checkout: ingested(checkout)}},
            else: {:error, {:recovery_failed, %{agent: agent, checkout: checkout}}}

        Enum.each(waiters, &GenServer.reply(&1, reply))

        if ok? do
          record(state, :recovered, %{"run" => run, "agent" => agent})
          %{state | recoveries: recoveries, retained: Map.delete(state.retained, run)}
        else
          %{state | recoveries: recoveries}
        end
    end
  end

  defp recovery_ok?(agent, checkout) do
    not Map.has_key?(agent, "error") and agent["transcripts"] in ["ok", "none"] and
      agent["checkout"] in ["ok", "none"] and not match?({:error, _}, checkout)
  end

  defp ingested({:ok, result}), do: result
  defp ingested(_none), do: nil

  # ---- reaping -----------------------------------------------------------------------

  defp send_reap(%{channel: nil} = state), do: state

  defp send_reap(state) do
    case Reaping.request(RunStreams.live(state.streams)) do
      nil -> state
      payload -> tap(state, &notify_channel(&1, {:push, "reap", payload}))
    end
  end

  defp schedule_reap(%{reap_interval_ms: :infinity} = state), do: state

  defp schedule_reap(%{reap_interval_ms: ms} = state) do
    Process.send_after(self(), :reap, ms)
    state
  end

  defp apply_streams(state, {streams, effects}),
    do: run_effects(%{state | streams: streams}, effects)

  defp run_effects(state, effects) do
    Enum.each(effects, fn
      {:reply, from, value} -> GenServer.reply(from, value)
      {:send, nil, _message} -> :ok
      {:send, pid, message} -> send(pid, message)
      {:push, event, payload} -> notify_channel(state, {:push, event, payload})
    end)

    state
  end

  # ---- attach / hello ------------------------------------------------------

  # A new connection replaces the old one: the old channel is told to go (it may
  # be a half-open socket the node already abandoned) and its monitor dropped so
  # its eventual exit is not read as the node disconnecting.
  defp take_over(state, channel) do
    if state.channel_ref, do: Process.demonitor(state.channel_ref, [:flush])

    if is_pid(state.channel) and state.channel != channel do
      send(state.channel, {:node_session, {:disconnect, :superseded}})
    end

    %{state | channel: channel, channel_ref: Process.monitor(channel)}
  end

  defp hello_verdicts(state, ids) do
    holds? = state.caps["run_hold"] != nil

    Enum.reduce(ids, {%{}, state}, fn id, {verdicts, acc} ->
      cond do
        match?({:ok, _}, RunStreams.fetch(acc.streams, id)) ->
          {Map.put(verdicts, id, "known"), acc}

        Map.has_key?(acc.held, id) ->
          {Map.put(verdicts, id, "hold"), acc}

        holds? and not MapSet.member?(acc.hold_expired, id) and live_row_here?(acc, id) ->
          {Map.put(verdicts, id, "hold"), hold(acc, id)}

        true ->
          {Map.put(verdicts, id, "unknown"), acc}
      end
    end)
  end

  # Whether `run` has a row in a live state that says it is on this node.
  defp live_row_here?(state, run) do
    case Ash.get(Arbiter.Workers.Run, run) do
      {:ok, %{node_id: node_id, state: row_state}} ->
        node_id == state.node_id and Arbiter.Workers.RunState.live?(row_state)

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp hold(state, run) do
    timer = Process.send_after(self(), {:hold_expired, run}, state.hold_ms)
    %{state | held: Map.put(state.held, run, timer)}
  end

  # Holds for runs the agent no longer has are over.
  defp release_gone_holds(state, ids) do
    {gone, held} = Map.split_with(state.held, fn {run, _} -> run not in ids end)
    Enum.each(gone, fn {_run, timer} -> Process.cancel_timer(timer) end)
    %{state | held: held, hold_expired: MapSet.intersection(state.hold_expired, MapSet.new(ids))}
  end

  defp forget_hold(state, run) do
    case Map.pop(state.held, run) do
      {nil, _} ->
        state

      {timer, held} ->
        Process.cancel_timer(timer)
        %{state | held: held}
    end
  end

  # Recovery wants a held run's work: the agent quiesces it and reports `retained`.
  defp quiesce_held(state, run) do
    case Map.pop(state.held, run) do
      {nil, _} ->
        state

      {timer, held} ->
        Process.cancel_timer(timer)
        push_quiesce(%{state | held: held}, run)
    end
  end

  defp push_quiesce(state, run) do
    notify_channel(state, {:push, "quiesce", %{"run" => run}})
    state
  end

  defp apply_hello(state, params) do
    node = Nodes.get_node(state.node_id)
    agent = %{version: params["agent_version"], proto: params["proto"]}

    %{
      state
      | agent_version: params["agent_version"],
        proto: params["proto"],
        health: Skew.health(agent, Skew.primary()),
        caps: map(params["caps"]),
        capacity: map(params["capacity"]),
        runs: hello_runs(hello_run_list(params)),
        retained: hello_retained(params),
        operator_max: node && node.max_workers,
        draining?: not is_nil(node) and node.status == :draining,
        thresholds: Liveness.current(),
        state: :online,
        fenced?: false,
        last_hb: state.clock.()
    }
  end

  # The agent reports its runs under `inventory.runs`; a bare `runs` is accepted too.
  defp hello_run_list(params),
    do: params["runs"] || get_in(params, ["inventory", "runs"])

  defp hello_runs(runs) when is_list(runs) do
    for %{"id" => id} = run <- runs, is_binary(id), into: %{}, do: {id, run}
  end

  defp hello_runs(_), do: %{}

  # `inventory.retained`: what the agent quiesced and still holds (RW12).
  defp hello_retained(params) do
    case get_in(params, ["inventory", "retained"]) do
      list when is_list(list) ->
        for %{"run" => run} = r <- list, is_binary(run), into: %{}, do: {run, r}

      _ ->
        %{}
    end
  end

  defp hello_ok(state, verdicts) do
    t = state.thresholds

    %{
      "boot_epoch" => Nodes.boot_epoch(),
      "hb_interval" => t.hb_interval_s,
      "fence_after" => t.fence_after_s,
      "lost_after" => t.lost_after_s,
      "health" => Atom.to_string(state.health),
      "draining" => state.draining?,
      "max_workers" => max_workers(state),
      "runs" => verdicts
    }
    |> put_upgrade(state.health)
  end

  # A drain, or a node the skew rules keep new work off, takes no new runs
  # (§13: "a drain sets effective to 0 for new work"); runs it already has go on.
  defp max_workers(state) do
    if state.draining? or not Skew.assignable?(state.health, state.allow_skew?),
      do: 0,
      else: Hello.effective_max_workers(state.operator_max, state.capacity)
  end

  # §6: an outdated or ahead agent is told the version to move to (a downgrade
  # after a rollback is the same message). Cluster nodes upgrade by image and
  # ignore it.
  defp put_upgrade(ok, health) when health in [:outdated, :ahead] do
    case Nodes.Agent.artifact() do
      {:ok, %{version: version, sha256: sha}} ->
        Map.put(ok, "upgrade", %{"version" => version, "sha256" => sha})

      _ ->
        ok
    end
  end

  defp put_upgrade(ok, _health), do: ok

  # ---- heartbeat -----------------------------------------------------------

  defp stamp(state, payload) do
    state = %{
      state
      | last_hb: state.clock.(),
        fenced?: false,
        runs: heartbeat_runs(payload["runs"], state.runs),
        free_mem: payload["free_mem"] || state.free_mem,
        load: payload["load"] || state.load
    }

    if state.state == :suspect do
      broadcast({:node_state, state.node_id, :online})
      %{state | state: :online}
    else
      state
    end
  end

  # `hb` carries the node's whole per-run table: it replaces ours. A heartbeat
  # without one leaves the table alone.
  defp heartbeat_runs(runs, _old) when is_map(runs), do: runs
  defp heartbeat_runs(runs, _old) when is_list(runs), do: hello_runs(runs)
  defp heartbeat_runs(_none, old), do: old

  defp ack(payload) do
    %{"seq" => payload["seq"], "boot_epoch" => Nodes.boot_epoch()}
  end

  # A drain made while this node was disconnected, or behind the session's back.
  defp sync_node(state, %Node{} = node) do
    draining? = node.status == :draining

    if draining? != state.draining?, do: set_draining(state, draining?), else: state
  end

  # ---- liveness ------------------------------------------------------------

  defp check(state) do
    silence = state.clock.() - state.last_hb
    t = state.thresholds

    case Liveness.classify(t, silence) do
      :lost -> {:stop, state |> fence(silence) |> lose(silence)}
      :suspect -> {:cont, state |> suspect() |> fence(silence)}
      :online -> {:cont, state}
    end
  end

  defp suspect(%{state: :suspect} = state), do: state

  defp suspect(state) do
    broadcast({:node_state, state.node_id, :suspect})
    %{state | state: :suspect}
  end

  defp fence(%{fenced?: true} = state, _silence), do: state

  defp fence(state, silence) do
    if Liveness.fenced?(state.thresholds, silence) do
      record(state, :fenced, %{
        "silence_s" => div(silence, 1000),
        "fence_after_s" => state.thresholds.fence_after_s
      })

      %{state | fenced?: true}
    else
      state
    end
  end

  defp lose(state, silence) do
    run_ids = state.runs |> Map.keys() |> Enum.sort()

    record(state, :node_lost, %{
      "runs" => run_ids,
      "silence_s" => div(silence, 1000),
      "lost_after_s" => state.thresholds.lost_after_s
    })

    broadcast({:node_lost, state.node_id, run_ids})
    notify_channel(state, {:disconnect, :lost})
    state
  end

  defp schedule_tick(%{tick_ms: :infinity} = state), do: state

  defp schedule_tick(%{tick_ms: ms} = state) do
    Process.send_after(self(), :tick, ms)
    state
  end

  # ---- drain ---------------------------------------------------------------

  defp set_draining(%{draining?: draining?} = state, draining?), do: state

  defp set_draining(state, draining?) do
    notify_channel(state, if(draining?, do: :drain, else: :undrain))
    broadcast({:node_draining, state.node_id, draining?})
    %{state | draining?: draining?}
  end

  # ---- reads ---------------------------------------------------------------

  defp assignable_state?(state) do
    not is_nil(state.channel) and state.state == :online and not state.draining? and
      Skew.assignable?(state.health, state.allow_skew?)
  end

  defp snapshot_of(state) do
    %{
      node_id: state.node_id,
      name: state.name,
      state: state.state,
      connected?: not is_nil(state.channel),
      draining?: state.draining?,
      health: state.health,
      assignable?: assignable_state?(state),
      agent_version: state.agent_version,
      proto: state.proto,
      caps: state.caps,
      capacity: state.capacity,
      max_workers: max_workers(state),
      runs: state.runs,
      retained: state.retained,
      free_mem: state.free_mem,
      load: state.load,
      silence_ms: state.clock.() - state.last_hb
    }
  end

  # ---- plumbing ------------------------------------------------------------

  # Forget a run; whatever streams it still has open on the channel end with it.
  defp drop_run(state, run) do
    notify_channel(state, {:run_over, run})
    {waiters, collectors} = Map.pop(state.collectors, run, [])
    Enum.each(waiters, &GenServer.reply(&1, {:error, :run_gone}))

    %{
      state
      | streams: RunStreams.drop(state.streams, run),
        checkouts: Map.delete(state.checkouts, run),
        collectors: collectors
    }
  end

  defp put_checkout(checkouts, run, %{} = ctx), do: Map.put(checkouts, run, ctx)
  defp put_checkout(checkouts, _run, _none), do: checkouts

  # `%{name => path}` of the per-run sockets a spec declares.
  defp bridge_map(%{"bridges" => bridges}) when is_list(bridges) do
    for %{"name" => name, "path" => path} <- bridges,
        is_binary(name),
        is_binary(path),
        into: %{},
        do: {name, path}
  end

  defp bridge_map(_spec), do: %{}

  defp notify_channel(%{channel: pid}, message) when is_pid(pid),
    do: send(pid, {:node_session, message})

  defp notify_channel(_state, _message), do: :ok

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Arbiter.PubSub, Nodes.topic(), message)

  defp record(state, kind, detail),
    do: Nodes.record(kind, state.node_id, Actor.label(Actor.node(state.name)), detail)

  defp map(m) when is_map(m), do: m
  defp map(_), do: %{}

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
