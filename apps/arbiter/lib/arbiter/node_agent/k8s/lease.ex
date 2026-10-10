defmodule Arbiter.NodeAgent.K8s.Lease do
  @moduledoc """
  The single-active-controller guard (`docs/design/remote-workers.md` K§3.5): a
  `coordination.k8s.io` Lease, renewed every 10 s, so a node partition cannot leave
  two controllers sharing one credential. `Recreate` handles the ordinary restart;
  the Lease handles the partition.

  The install pre-creates the Lease `arbiter-controller` and the Role grants
  `get`/`update` on that one name, so this never creates. Each cycle (`tick/1`):

    1. `GET` the Lease.
    2. If it names us, renew it; if nobody holds it, take it; if another holds it,
       take it **only** after we have watched its `(holder, renewTime)` stay
       unchanged for a whole lease duration. The age is our own monotonic
       observation, never a comparison of the server's timestamp against our clock,
       so clock skew between nodes cannot make us steal a live lease (the
       client-go leader-election rule).
    3. The `PUT` carries the `resourceVersion` we read: a `409` means someone else
       wrote first, and we do not hold it.

  **Stepping down.** `held?/1` is true only while we hold the lease *and* have
  renewed within `:renew_deadline_ms` (default 20 s, two missed renewals). A
  conflict, another holder, or a deadline passed without a successful renew sets it
  false and sends `{:lease, lease, :lost}` to `:notify`; the controller then stops
  assigning and reaping. An API error alone does not step down before the
  deadline (a blip is not a partition), and an unreachable API never *grants* the
  lease. Winning it sends `{:lease, lease, :acquired}`.

  A clean stop hands the Lease back (`holderIdentity: ""`), so the replacement
  controller does not wait out the duration.

  Options: `:client`, `:identity` (required; the pod name), `:lease_name` (default
  `arbiter-controller`), `:interval_ms` (default 10 000; `nil` for none, tests call
  `tick/1`), `:lease_duration_ms` (default 30 000), `:renew_deadline_ms`
  (default 20 000), `:clock` (a `fun() -> ms`, monotonic; tests drive it), `:notify`,
  `:name`.
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.Client

  require Logger

  @default_lease "arbiter-controller"
  @default_interval_ms 10_000
  @default_duration_ms 30_000
  @default_deadline_ms 20_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc "Whether this controller is the active one right now."
  @spec held?(GenServer.server()) :: boolean()
  def held?(lease \\ __MODULE__) do
    GenServer.call(lease, :held?)
  catch
    # No Lease process at all: nobody is guarding, so nobody holds.
    :exit, _ -> false
  end

  @doc "Run one acquire/renew cycle now. `:held` or `:standby`."
  @spec tick(GenServer.server()) :: :held | :standby
  def tick(lease \\ __MODULE__), do: GenServer.call(lease, :tick, 30_000)

  # -- server -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      client: Keyword.fetch!(opts, :client),
      identity: Keyword.fetch!(opts, :identity),
      lease_name: Keyword.get(opts, :lease_name, @default_lease),
      interval: Keyword.get(opts, :interval_ms, @default_interval_ms),
      duration_ms: Keyword.get(opts, :lease_duration_ms, @default_duration_ms),
      deadline_ms: Keyword.get(opts, :renew_deadline_ms, @default_deadline_ms),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      notify: opts[:notify],
      held?: false,
      last_renew: nil,
      observed: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:held?, _from, state), do: {:reply, held_now?(state), state}

  def handle_call(:tick, _from, state) do
    state = cycle(state)
    {:reply, if(state.held?, do: :held, else: :standby), state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> cycle() |> schedule()}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{held?: true} = state), do: release(state)
  def terminate(_reason, _state), do: :ok

  # -- the cycle ----------------------------------------------------------------

  defp schedule(%{interval: ms} = state) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
    state
  end

  defp schedule(state), do: state

  defp cycle(state) do
    case Client.get_lease(state.client, state.lease_name) do
      {:ok, lease} -> decide(state, lease)
      {:error, reason} -> failed(state, reason)
    end
  end

  defp decide(state, lease) do
    spec = lease["spec"] || %{}
    holder = spec["holderIdentity"]
    state = observe(state, {holder, spec["renewTime"]})

    cond do
      holder == state.identity -> write(state, lease, :renew)
      holder in [nil, ""] -> write(state, lease, :acquire)
      expired?(state) -> write(state, lease, :acquire)
      true -> step_down(state)
    end
  end

  defp observe(%{observed: {record, _at}} = state, record), do: state
  defp observe(state, record), do: %{state | observed: {record, state.clock.()}}

  defp expired?(%{observed: {_record, at}} = state), do: state.clock.() - at >= state.duration_ms

  defp write(state, lease, mode) do
    spec = lease["spec"] || %{}
    stamp = timestamp()
    changed_holder? = spec["holderIdentity"] != state.identity

    new_spec =
      spec
      |> Map.merge(%{
        "holderIdentity" => state.identity,
        "leaseDurationSeconds" => max(div(state.duration_ms + 999, 1000), 1),
        "renewTime" => stamp
      })
      |> then(fn s ->
        if mode == :acquire or changed_holder?,
          do:
            s
            |> Map.put("acquireTime", stamp)
            |> Map.put("leaseTransitions", (spec["leaseTransitions"] || 0) + 1),
          else: s
      end)

    case Client.update_lease(state.client, Map.put(lease, "spec", new_spec)) do
      {:ok, written} ->
        record = {new_spec["holderIdentity"], new_spec["renewTime"]}
        _ = written
        won(%{state | observed: {record, state.clock.()}})

      {:error, :conflict} ->
        step_down(state)

      {:error, reason} ->
        failed(state, reason)
    end
  end

  defp won(state) do
    was = state.held?
    state = %{state | held?: true, last_renew: state.clock.()}
    if not was, do: tell(state, :acquired)
    state
  end

  defp step_down(%{held?: true} = state) do
    Logger.warning("k8s controller: lost the #{state.lease_name} lease; standing down")
    tell(state, :lost)
    %{state | held?: false, last_renew: nil}
  end

  defp step_down(state), do: state

  # An error talking to the API: a blip keeps what we hold until the renew deadline.
  defp failed(state, reason) do
    Logger.warning("k8s controller: lease #{state.lease_name}: #{inspect(reason, limit: 5)}")

    if state.held? and state.clock.() - state.last_renew >= state.deadline_ms,
      do: step_down(state),
      else: state
  end

  defp held_now?(%{held?: false}), do: false
  defp held_now?(state), do: state.clock.() - state.last_renew < state.deadline_ms

  defp release(state) do
    with {:ok, lease} <- Client.get_lease(state.client, state.lease_name),
         true <- get_in(lease, ["spec", "holderIdentity"]) == state.identity do
      Client.update_lease(state.client, put_in(lease, ["spec", "holderIdentity"], ""))
    end

    :ok
  end

  defp tell(%{notify: pid}, event) when is_pid(pid), do: send(pid, {:lease, self(), event})
  defp tell(_state, _event), do: :ok

  # MicroTime: RFC 3339 with exactly six fractional digits.
  defp timestamp do
    now = DateTime.utc_now()
    {micro, _} = now.microsecond
    DateTime.to_iso8601(%{now | microsecond: {micro, 6}})
  end
end
