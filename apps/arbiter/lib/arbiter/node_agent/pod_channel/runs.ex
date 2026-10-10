defmodule Arbiter.NodeAgent.PodChannel.Runs do
  @moduledoc """
  The controller's table of the runs it assigned
  (`docs/design/remote-workers.md` §16 K§9.2, K§9.3, K§12), and the only place a
  run's per-run secrets and certificates live: **in this process's memory**. Nothing
  here is written to a store, a Secret, a ConfigMap or the pod spec; the one thing
  a Kubernetes object carries is the single-use boot nonce.

  A leaf certificate chains to the install's CA for *any* run the CA ever signed
  for, and a handshake proves nothing more than that. What makes a connection "a
  live run this controller assigned, as a bridge its spec names" is this table:

    * `register/3` is the controller's `assign`: it mints one leaf per bridge in
      the run's spec (`CN` run, `OU` bridge) plus a `control` leaf for `:9444`,
      all valid until `deadline`, and issues the boot nonce;
    * `bind_pod_ip/3` is the informer reporting `status.podIP`: from then the nonce
      can be redeemed (from that address only) and the leaves used (from it only);
    * `redeem/3` is `/boot`: the tar of certificates, secrets and seed files
      (`Arbiter.NodeAgent.PodChannel.BootBundle`);
    * `authorize/4` is the check both listeners make on a peer certificate: the run
      is registered and not past its deadline, the certificate is **byte-identical
      to the leaf this table minted** for that run and name, the name is one of the
      spec's bridges (`:bridge`) or `control` (`:control`; the two are never
      interchangeable), and the peer address is the pod's;
    * `release/2` forgets the run (its leaves stop working at once, whatever their
      expiry), drops its nonce and ends any waiting command poll.

  The run table also holds each run's **command mailbox** (`push_command/3`,
  `await_commands/3`): what the controller tells the in-pod snapshotter over
  `GET :9444/commands`, long-polled.
  """

  use GenServer

  alias Arbiter.NodeAgent.PodChannel.{BootBundle, BootNonce, Cert}
  alias Arbiter.NodeAgent.RunSpec

  @control "control"
  @skew_s 60
  @max_timer_ms 2_000_000_000

  @type kind :: :bridge | :control

  # ---- API ---------------------------------------------------------------------------

  @doc """
  Options: `:ca` (required, `Arbiter.NodeAgent.PodChannel.Cert.t()`), `:name`
  (default this module; `nil` for none), `:boot_ttl_ms`, `:now` (a `fun() ->
  DateTime`, for tests).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  The controller assigned `spec`'s run; its pod must be gone by `deadline`.
  `{:ok, nonce}` is what goes in the pod spec as `ARB_BOOT_NONCE`.
  """
  @spec register(GenServer.server(), RunSpec.t(), DateTime.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def register(server \\ __MODULE__, %RunSpec{} = spec, %DateTime{} = deadline),
    do: GenServer.call(server, {:register, spec, deadline})

  @doc "The informer reported `run`'s pod IP."
  @spec bind_pod_ip(GenServer.server(), String.t(), :inet.ip_address()) :: :ok
  def bind_pod_ip(server \\ __MODULE__, run, ip), do: GenServer.call(server, {:bind, run, ip})

  @doc """
  Redeem a boot nonce presented from `peer_ip`: `{:ok, run, tar}`, or
  `{:error, :unknown | :expired | :unbound | :wrong_ip}`.
  """
  @spec redeem(GenServer.server(), String.t(), :inet.ip_address()) ::
          {:ok, String.t(), binary()} | {:error, BootNonce.reason()}
  def redeem(server \\ __MODULE__, nonce, peer_ip),
    do: GenServer.call(server, {:redeem, nonce, peer_ip})

  @doc """
  May the peer that presented certificate `der` from `peer_ip` use the `kind`
  channel? `{:ok, %{run:, name:}}` or `{:error, reason}` (`:bad_certificate`,
  `:unknown_run`, `:unknown_bridge`, `:wrong_purpose`, `:leaf_mismatch`,
  `:wrong_ip`).
  """
  @spec authorize(GenServer.server(), kind(), binary(), :inet.ip_address() | nil) ::
          {:ok, %{run: String.t(), name: String.t()}} | {:error, atom()}
  def authorize(server \\ __MODULE__, kind, der, peer_ip) when kind in [:bridge, :control],
    do: GenServer.call(server, {:authorize, kind, der, peer_ip})

  @doc "The run is over: forget it."
  @spec release(GenServer.server(), String.t()) :: :ok
  def release(server \\ __MODULE__, run), do: GenServer.call(server, {:release, run})

  @doc "Queue a command (a JSON-able map) for the run's snapshotter."
  @spec push_command(GenServer.server(), String.t(), map()) :: :ok | {:error, :unknown_run}
  def push_command(server \\ __MODULE__, run, command),
    do: GenServer.call(server, {:push_command, run, command})

  @doc """
  The queued commands, or what arrives within `wait_ms`: `{:ok, commands}` (empty
  when the wait ran out), `{:error, :unknown_run}`.
  """
  @spec await_commands(GenServer.server(), String.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, :unknown_run}
  def await_commands(server \\ __MODULE__, run, wait_ms),
    do: GenServer.call(server, {:await, run, wait_ms}, wait_ms + 5_000)

  @doc "The ids of the runs in the table."
  @spec live_runs(GenServer.server()) :: [String.t()]
  def live_runs(server \\ __MODULE__), do: GenServer.call(server, :live_runs)

  @doc "How many command polls `run` has open (diagnostics, tests)."
  @spec waiting(GenServer.server(), String.t()) :: non_neg_integer()
  def waiting(server \\ __MODULE__, run), do: GenServer.call(server, {:waiting, run})

  # ---- server ------------------------------------------------------------------------

  @impl true
  def init(opts) do
    nonce_opts =
      Keyword.take(opts, [:boot_ttl_ms]) |> Enum.map(fn {:boot_ttl_ms, v} -> {:ttl_ms, v} end)

    {:ok,
     %{
       ca: Keyword.fetch!(opts, :ca),
       now: Keyword.get(opts, :now, &DateTime.utc_now/0),
       nonces: BootNonce.new(nonce_opts),
       runs: %{}
     }}
  end

  @impl true
  def handle_call({:register, spec, deadline}, _from, state) do
    case register_run(state, spec, deadline) do
      {:ok, nonce, state} -> {:reply, {:ok, nonce}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:bind, run, ip}, _from, state) do
    runs =
      case state.runs do
        %{^run => r} -> Map.put(state.runs, run, %{r | pod_ip: ip})
        runs -> runs
      end

    {:reply, :ok, %{state | runs: runs, nonces: BootNonce.bind(state.nonces, run, ip)}}
  end

  def handle_call({:redeem, nonce, peer_ip}, _from, state) do
    {result, nonces} = BootNonce.redeem(state.nonces, nonce, peer_ip)
    state = %{state | nonces: nonces}

    with {:ok, run} <- result,
         %{spec: spec, leaves: leaves} <- state.runs[run] do
      {:reply, {:ok, run, BootBundle.build(spec, leaves)}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      nil -> {:reply, {:error, :unknown}, state}
    end
  end

  def handle_call({:authorize, kind, der, peer_ip}, _from, state),
    do: {:reply, authorize_peer(state, kind, der, peer_ip), state}

  def handle_call({:release, run}, _from, state), do: {:reply, :ok, drop(state, run)}

  def handle_call({:push_command, run, command}, _from, state) do
    case state.runs do
      %{^run => r} -> {:reply, :ok, put_run(state, run, deliver(r, command))}
      _ -> {:reply, {:error, :unknown_run}, state}
    end
  end

  def handle_call({:await, run, wait_ms}, from, state) do
    case state.runs do
      %{^run => %{commands: [_ | _] = commands} = r} ->
        {:reply, {:ok, commands}, put_run(state, run, %{r | commands: []})}

      %{^run => r} ->
        ref = make_ref()
        timer = Process.send_after(self(), {:poll_timeout, run, ref}, wait_ms)
        {:noreply, put_run(state, run, %{r | waiters: r.waiters ++ [{from, ref, timer}]})}

      _ ->
        {:reply, {:error, :unknown_run}, state}
    end
  end

  def handle_call(:live_runs, _from, state), do: {:reply, Map.keys(state.runs), state}

  def handle_call({:waiting, run}, _from, state),
    do:
      {:reply, state.runs |> Map.get(run, %{waiters: []}) |> Map.fetch!(:waiters) |> length(),
       state}

  @impl true
  def handle_info({:expire, run}, state), do: {:noreply, drop(state, run)}

  def handle_info({:poll_timeout, run, ref}, state) do
    case state.runs do
      %{^run => r} ->
        {mine, rest} = Enum.split_with(r.waiters, fn {_, wref, _} -> wref == ref end)
        Enum.each(mine, fn {from, _, _} -> GenServer.reply(from, {:ok, []}) end)
        {:noreply, put_run(state, run, %{r | waiters: rest})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ---- registration ------------------------------------------------------------------

  defp register_run(state, %RunSpec{run: run} = spec, deadline) do
    now = state.now.()
    names = Enum.map(spec.bridges, & &1.name)

    cond do
      Map.has_key?(state.runs, run) -> {:error, :already_registered}
      @control in names -> {:error, :reserved_bridge_name}
      DateTime.compare(deadline, now) != :gt -> {:error, :deadline_passed}
      true -> mint(state, spec, names, now, deadline)
    end
  end

  defp mint(state, spec, names, now, deadline) do
    not_before = DateTime.add(now, -@skew_s)

    leaves =
      for ou <- names ++ [@control], into: %{} do
        {ou, Cert.leaf(state.ca, spec.run, ou, not_before, deadline)}
      end

    {nonce, nonces} = BootNonce.issue(state.nonces, spec.run)
    ms = min(max(DateTime.diff(deadline, now, :millisecond), 0), @max_timer_ms)
    timer = Process.send_after(self(), {:expire, spec.run}, ms)

    run = %{
      spec: spec,
      bridges: MapSet.new(names),
      leaves: leaves,
      deadline: deadline,
      pod_ip: nil,
      commands: [],
      waiters: [],
      timer: timer
    }

    {:ok, nonce, %{state | nonces: nonces, runs: Map.put(state.runs, spec.run, run)}}
  end

  # ---- authorization -----------------------------------------------------------------

  defp authorize_peer(state, kind, der, peer_ip) do
    with {:ok, %{cn: run, ou: ou}} <- subject(der),
         {:ok, r} <- fetch(state, run),
         :ok <- purpose(kind, ou, r),
         :ok <- same_leaf(r, ou, der),
         :ok <- same_pod(r, peer_ip) do
      {:ok, %{run: run, name: ou}}
    end
  end

  defp subject(der) do
    case Cert.subject(der) do
      %{cn: cn, ou: ou} when is_binary(cn) and is_binary(ou) -> {:ok, %{cn: cn, ou: ou}}
      _ -> {:error, :bad_certificate}
    end
  rescue
    _ -> {:error, :bad_certificate}
  catch
    _, _ -> {:error, :bad_certificate}
  end

  defp fetch(state, run) do
    with %{deadline: deadline} = r <- state.runs[run],
         :gt <- DateTime.compare(deadline, state.now.()) do
      {:ok, r}
    else
      _ -> {:error, :unknown_run}
    end
  end

  defp purpose(:bridge, @control, _r), do: {:error, :wrong_purpose}
  defp purpose(:control, @control, _r), do: :ok

  defp purpose(kind, ou, r) do
    cond do
      not MapSet.member?(r.bridges, ou) -> {:error, :unknown_bridge}
      kind == :control -> {:error, :wrong_purpose}
      true -> :ok
    end
  end

  defp same_leaf(r, ou, der) do
    case r.leaves do
      %{^ou => %{der: ^der}} -> :ok
      _ -> {:error, :leaf_mismatch}
    end
  end

  # The leaves are only delivered by `/boot`, which needs the IP bound, so an
  # unbound run presenting one is an anomaly: refuse.
  defp same_pod(%{pod_ip: ip}, ip) when not is_nil(ip), do: :ok
  defp same_pod(_r, _peer_ip), do: {:error, :wrong_ip}

  # ---- commands ----------------------------------------------------------------------

  defp deliver(%{waiters: [{from, _ref, timer} | rest]} = r, command) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:ok, [command]})
    %{r | waiters: rest}
  end

  defp deliver(r, command), do: %{r | commands: r.commands ++ [command]}

  # ---- housekeeping ------------------------------------------------------------------

  defp put_run(state, run, r), do: %{state | runs: Map.put(state.runs, run, r)}

  defp drop(state, run) do
    case Map.pop(state.runs, run) do
      {nil, _} ->
        state

      {r, runs} ->
        Process.cancel_timer(r.timer)

        Enum.each(r.waiters, fn {from, _ref, timer} ->
          Process.cancel_timer(timer)
          GenServer.reply(from, {:error, :unknown_run})
        end)

        %{state | runs: runs, nonces: BootNonce.revoke(state.nonces, run)}
    end
  end
end
