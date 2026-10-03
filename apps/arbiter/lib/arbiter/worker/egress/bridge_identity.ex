defmodule Arbiter.Worker.Egress.BridgeIdentity do
  @moduledoc """
  Who is on the other end of a jailed worker's Arbiter bridge (bd-c1qq7l, G9;
  `docs/design/guardrail-profiles.md` §2.5, §4.4).

  The jailed worker reaches Arbiter through `<run>.arb.sock`, a byte bridge
  (`Arbiter.Worker.Egress.Forward`) that dials the real endpoint on host
  loopback. To the endpoint such a request is indistinguishable from any other
  process on this host, which is anonymous loopback, and loopback is not an
  identity. So the identity is recorded out of band, keyed by the one thing
  the jailed process cannot influence: the TCP connection the bridge itself
  opened.

    * `Forward` dials the endpoint, reads the local `{address, port}` of its
      own upstream socket and calls `register/3` **before any byte is relayed**.
      The kernel guarantees no other process holds that 4-tuple while the
      connection lives, so the endpoint's `peer_data` for that connection
      can only be this bridge's.
    * `ArbiterWeb.WorkerBridge` (an endpoint plug and the `/session` socket)
      calls `resolve/2` with the connection's `peer_data`. A hit means the
      request arrived through a worker bridge and carries that run's scope,
      whatever the client sent in `Authorization`.
    * The run's scope is the worker's own `:worker`-tier token, recorded by
      `put_run/3` when the run starts. It is decoded on **every** resolve, so
      expiry and revocation apply exactly as for a presented token. A run with
      no usable token resolves to an error: the bridge then refuses every
      request. It never falls back to anonymous.

  Entries die with their process: a registered connection when its relaying
  process exits, a run when its owner (the worker) exits or `delete_run/1` is
  called. `resolve/2` also checks the registering process is alive, so a
  connection entry that outlives its process for a moment cannot match a new
  connection that happens to reuse the ephemeral port.

  Writes go through this GenServer; reads hit the `:protected` ETS table
  directly.
  """
  use GenServer

  alias Arbiter.MCP.Scope

  @table __MODULE__

  @type peer :: {:inet.ip_address(), :inet.port_number()}
  @type resolution :: {:ok, Scope.t()} | {:error, atom()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc """
  Records the worker token whose scope the run's bridge connections carry.
  `owner` (a pid) ends the entry when it exits; `nil` leaves that to
  `delete_run/1`. A later call for the same run replaces the token (a resume
  mints a fresh one).
  """
  @spec put_run(String.t(), String.t() | nil, pid() | nil) :: :ok
  def put_run(run_id, token, owner \\ nil) when is_binary(run_id),
    do: GenServer.call(__MODULE__, {:put_run, run_id, token, owner})

  @spec delete_run(String.t()) :: :ok
  def delete_run(run_id) when is_binary(run_id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:delete_run, run_id}),
      else: :ok
  end

  @doc """
  Marks the connection whose bridge-side local end is `peer` as `run_id`'s,
  for as long as `pid` (default: the caller) lives.
  """
  @spec register(String.t(), peer(), pid()) :: :ok | {:error, :unavailable}
  def register(run_id, {_address, _port} = peer, pid \\ self()) when is_binary(run_id) do
    if Process.whereis(__MODULE__),
      do: GenServer.call(__MODULE__, {:register, run_id, peer, pid}),
      else: {:error, :unavailable}
  end

  @doc """
  `:none` when `address`/`port` is not a bridge connection, else
  `{:bridge, run_id, resolution}` where the resolution is the run's worker
  scope or the reason there is none.
  """
  @spec resolve(:inet.ip_address() | term(), integer() | term()) ::
          :none | {:bridge, String.t(), resolution()}
  def resolve(address, port) do
    with [{_, run_id, pid}] <- :ets.lookup(@table, {:conn, address, port}),
         true <- Process.alive?(pid) do
      {:bridge, run_id, run_scope(run_id)}
    else
      _ -> :none
    end
  rescue
    # No table: the egress tree is down, so there are no bridge connections.
    ArgumentError -> :none
  end

  defp run_scope(run_id) do
    case :ets.lookup(@table, {:run, run_id}) do
      [{_, token}] when is_binary(token) -> decode(token)
      _ -> {:error, :no_identity}
    end
  end

  defp decode(token) do
    case Scope.from_token(token) do
      {:ok, %Scope{tier: :worker, task_id: task_id} = scope} when is_binary(task_id) ->
        {:ok, scope}

      {:ok, _other} ->
        {:error, :not_worker_scope}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- server --------------------------------------------------------------

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_run, run_id, token, owner}, _from, monitors) do
    :ets.insert(@table, {{:run, run_id}, token})
    {:reply, :ok, watch(monitors, owner, {:run, run_id})}
  end

  def handle_call({:delete_run, run_id}, _from, monitors) do
    :ets.delete(@table, {:run, run_id})
    {:reply, :ok, monitors}
  end

  def handle_call({:register, run_id, {address, port} = peer, pid}, _from, monitors) do
    :ets.insert(@table, {{:conn, address, port}, run_id, pid})
    {:reply, :ok, watch(monitors, pid, {:conn, peer, pid})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, monitors) do
    case Map.pop(monitors, ref) do
      {{:run, run_id}, rest} ->
        :ets.delete(@table, {:run, run_id})
        {:noreply, rest}

      {{:conn, {address, port}, pid}, rest} ->
        :ets.match_delete(@table, {{:conn, address, port}, :_, pid})
        {:noreply, rest}

      {nil, rest} ->
        {:noreply, rest}
    end
  end

  def handle_info(_msg, monitors), do: {:noreply, monitors}

  defp watch(monitors, pid, what) when is_pid(pid),
    do: Map.put(monitors, Process.monitor(pid), what)

  defp watch(monitors, _none, _what), do: monitors
end
