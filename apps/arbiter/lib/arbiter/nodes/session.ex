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

  ## Messages to the channel

  `{:node_session, :drain}` / `{:node_session, :undrain}` and
  `{:node_session, {:disconnect, reason}}` with `reason` one of `:revoked`,
  `:lost`, `:superseded`. The channel owns turning those into pushes and a
  socket close; the session never touches a socket.

  ## Events broadcast on `Arbiter.Nodes.topic/0`

  `{:node_state, id, :online | :suspect}`, `{:node_connection, id, :up | :down}`,
  `{:node_draining, id, boolean}`, `{:node_lost, id, run_ids}` and — from
  `Arbiter.Nodes.revoke/2` — `{:node_revoked, id}`.
  """

  use GenServer, restart: :temporary

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Hello, Liveness, Node, Skew}

  @default_tick_ms 5_000

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
    runs: %{}
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
  Out-of-band news for the session: `:drain`, `:undrain` or
  `{:disconnect, reason}` (revoke). Asynchronous; a call made afterwards *by the
  same process* observes it.
  """
  @spec notify(pid(), :drain | :undrain | {:disconnect, atom()}) :: :ok
  def notify(pid, message), do: GenServer.cast(pid, message)

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
      last_hb: clock.()
    }

    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_call({:attach, channel, params}, _from, state) do
    state = state |> take_over(channel) |> apply_hello(params)
    verdicts = Hello.verdicts(Hello.run_ids(params["runs"]))

    record(state, :connected, %{
      "agent_version" => state.agent_version,
      "proto" => state.proto,
      "health" => Atom.to_string(state.health),
      "boot_epoch" => Nodes.boot_epoch()
    })

    broadcast({:node_connection, state.node_id, :up})
    broadcast({:node_state, state.node_id, :online})

    {:reply, {:ok, %{pid: self(), hello_ok: hello_ok(state, verdicts)}}, state}
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

  def handle_info(_other, state), do: {:noreply, state}

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
        runs: hello_runs(params["runs"]),
        operator_max: node && node.max_workers,
        draining?: not is_nil(node) and node.status == :draining,
        thresholds: Liveness.current(),
        state: :online,
        fenced?: false,
        last_hb: state.clock.()
    }
  end

  defp hello_runs(runs) when is_list(runs) do
    for %{"id" => id} = run <- runs, is_binary(id), into: %{}, do: {id, run}
  end

  defp hello_runs(_), do: %{}

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
      free_mem: state.free_mem,
      load: state.load,
      silence_ms: state.clock.() - state.last_hb
    }
  end

  # ---- plumbing ------------------------------------------------------------

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
