defmodule Arbiter.NodeAgent.K8s.ReadinessMonitor do
  @moduledoc """
  Keeps the cluster's readiness current (`docs/design/remote-workers.md` k8s §9.4,
  ticket K13): it runs `Arbiter.NodeAgent.K8s.Canary` and
  `Arbiter.NodeAgent.K8s.Readiness` **at start, on every controller config change
  (`{:controller_config, loader, config}`, as `ConfigLoader` sends) and every 10
  minutes**, and publishes the result to its subscribers as
  `{:k8s_readiness, server, report}`.

  ## The report

      %{degraded: ["netpol_unenforced"] | [],
        checks: [Readiness check, …],   # netpol first
        at: DateTime | nil,              # when the last run finished
        canary: Canary result | nil}

  `degraded` is what the controller puts in `hello`/`hb` (`Controller.report/1`);
  `hello_readiness/1` is the `readiness` block of `hello`.

  ## Fail closed

  `degraded: ["netpol_unenforced"]` is the **default**: before the first canary has
  finished, and whenever the policy is not *proven* enforced. A run that **connected**
  anywhere sets it at once. A run that could not complete (`:inconclusive`: quota full,
  image pull, scheduling, the API refusing) neither proves nor disproves anything, so
  an earlier `:enforced` verdict is **kept** for `stale_after_ms` (default three
  intervals, 30 min) and shown as a warning; after that the node is degraded. A cluster
  that never passed has nothing to keep. The per-pod gate (`PodScripts.gate/0`) is the
  other half: a pod started while the CNI does not enforce fails closed on its own.

  ## The listener

  The `controller_port` probe only proves something if a socket accepts there, so with
  `:listen_port` the monitor opens a TCP listener that accepts and closes (port `0`
  for tests; `listen_port/1` says which).

  Options: `:client` (required), `:config_fun` (`fn -> {:ok, pod_config} | {:error, _}`,
  required: the `PodSpec` config for this run, with a fresh `boot_nonce`), `:image`
  (the digest-pinned worker image), `:targets` (`Canary.targets_from_env/1`),
  `:interval_ms` (default 600 000; `nil` for none), `:stale_after_ms`, `:poll_ms` /
  `:timeout_ms` (the canary's), `:listen_port`, `:notify` (a pid, also `subscribe/2`),
  `:config_loader` (a `ConfigLoader`: the monitor subscribes itself at start, so a
  restarted monitor re-subscribes and a config change re-runs the canary),
  `:now_ms_fun` (monotonic ms), `:autostart` (default true: run at start), `:name`.
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Readiness

  require Logger

  @default_interval_ms 600_000
  @unenforced "netpol_unenforced"

  @type report :: %{
          degraded: [String.t()],
          checks: [map()],
          at: DateTime.t() | nil,
          canary: Canary.result() | nil
        }

  # --- API ----------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if opts[:name], do: [name: opts[:name]], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "The current report (never blocks on a run in flight)."
  @spec report(GenServer.server()) :: report()
  def report(server), do: GenServer.call(server, :report)

  @doc "Also send `{:k8s_readiness, server, report}` to `pid` after each run."
  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc "Run now and return the report when the run is done (a run in flight is waited for)."
  @spec refresh(GenServer.server()) :: report()
  def refresh(server), do: GenServer.call(server, :refresh, 300_000)

  @doc "The port of the canary listener, or `nil` without `:listen_port`."
  @spec listen_port(GenServer.server()) :: :inet.port_number() | nil
  def listen_port(server), do: GenServer.call(server, :listen_port)

  @doc ~S|The `readiness` block of `hello`: `%{"ready" => no check failed, "checks" => checks}`.|
  @spec hello_readiness(report()) :: map()
  def hello_readiness(%{checks: checks}),
    do: %{"ready" => Enum.all?(checks, &(&1["status"] != "fail")), "checks" => checks}

  # --- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    now_ms_fun = Keyword.get(opts, :now_ms_fun, fn -> System.monotonic_time(:millisecond) end)

    state = %{
      client: Keyword.fetch!(opts, :client),
      loader: opts[:config_loader],
      config_fun: Keyword.fetch!(opts, :config_fun),
      image: opts[:image],
      targets: Keyword.get(opts, :targets, %{}),
      interval_ms: interval,
      stale_after_ms: Keyword.get(opts, :stale_after_ms, (interval || @default_interval_ms) * 3),
      canary_opts: Keyword.take(opts, [:poll_ms, :timeout_ms]),
      now_ms_fun: now_ms_fun,
      subscribers: opts |> Keyword.get(:notify) |> List.wrap(),
      listener: nil,
      run: nil,
      rerun?: false,
      waiters: [],
      # The latest finished run, and the latest conclusive :enforced one with when it ran.
      latest: nil,
      enforced: nil,
      checks: [],
      at: nil
    }

    state = open_listener(state, opts[:listen_port])
    if Keyword.get(opts, :autostart, true), do: send(self(), :run)
    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, %{loader: nil} = state), do: {:noreply, state}

  def handle_continue(:subscribe, %{loader: loader} = state) do
    :ok = ConfigLoader.subscribe(loader, self())
    {:noreply, state}
  end

  @impl true
  def handle_call(:report, _from, state), do: {:reply, build_report(state), state}
  def handle_call(:listen_port, _from, state), do: {:reply, listener_port(state), state}

  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscribers: Enum.uniq([pid | state.subscribers])}}

  def handle_call(:refresh, from, state) do
    state = %{state | waiters: [from | state.waiters]}

    case state.run do
      nil -> {:noreply, start_run(state)}
      _running -> {:noreply, %{state | rerun?: true}}
    end
  end

  @impl true
  def handle_info(:run, %{run: nil} = state), do: {:noreply, state |> start_run() |> schedule()}
  def handle_info(:run, state), do: {:noreply, schedule(%{state | rerun?: true})}

  def handle_info({:controller_config, _loader, _config}, %{run: nil} = state),
    do: {:noreply, start_run(state)}

  def handle_info({:controller_config, _loader, _config}, state),
    do: {:noreply, %{state | rerun?: true}}

  def handle_info({ref, outcome}, %{run: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_run(state, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{ref: ref}} = state) do
    outcome = {:inconclusive_run, {:crashed, reason}}
    {:noreply, finish_run(state, outcome)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listener: {socket, _acceptor}}), do: :gen_tcp.close(socket)
  def terminate(_reason, _state), do: :ok

  # --- runs ---------------------------------------------------------------------

  defp start_run(state) do
    %{client: client, config_fun: config_fun, image: image, targets: targets} = state
    canary_opts = [image: image, targets: targets] ++ state.canary_opts

    task =
      Task.async(fn ->
        try do
          case config_fun.() do
            {:ok, config} ->
              canary = Canary.run(client, config, canary_opts)
              {:ok, canary, Readiness.run(client, config, canary, image: image)}

            {:error, reason} ->
              {:inconclusive_run, {:config, reason}}
          end
        rescue
          error -> {:inconclusive_run, {:raised, Exception.message(error)}}
        catch
          # An exit or throw (a GenServer.call timeout, Req exiting) is as inconclusive as a
          # raise; the task is linked, so uncaught it would take the monitor down with it.
          kind, reason -> {:inconclusive_run, {kind, reason}}
        end
      end)

    %{state | run: task}
  end

  defp finish_run(state, outcome) do
    {canary, checks} =
      case outcome do
        {:ok, canary, checks} -> {canary, checks}
        {:inconclusive_run, reason} -> {inconclusive(reason), []}
      end

    now = state.now_ms_fun.()

    state = %{
      state
      | run: nil,
        latest: canary,
        checks: checks,
        at: DateTime.utc_now(),
        enforced: if(canary.outcome == :enforced, do: {canary, now}, else: state.enforced)
    }

    report = build_report(state)
    for pid <- state.subscribers, do: send(pid, {:k8s_readiness, self(), report})
    for from <- state.waiters, do: GenServer.reply(from, report)
    state = %{state | waiters: []}

    if state.rerun?, do: start_run(%{state | rerun?: false}), else: state
  end

  defp inconclusive(reason) do
    %{
      outcome: :inconclusive,
      open: [],
      skipped: [],
      bridge: nil,
      reason: reason,
      pull: :unknown
    }
  end

  defp schedule(%{interval_ms: nil} = state), do: state

  defp schedule(%{interval_ms: ms} = state) do
    Process.send_after(self(), :run, ms)
    state
  end

  # --- report -------------------------------------------------------------------

  defp build_report(%{latest: nil} = state) do
    %{
      degraded: [@unenforced],
      checks: [Readiness.netpol(nil) | state.checks],
      at: nil,
      canary: nil
    }
  end

  defp build_report(state) do
    {degraded, netpol} = verdict(state)
    %{degraded: degraded, checks: [netpol | state.checks], at: state.at, canary: state.latest}
  end

  # A conclusive latest verdict stands. An inconclusive one defers to a fresh enforced one.
  defp verdict(%{latest: %{outcome: :enforced} = latest}), do: {[], Readiness.netpol(latest)}

  defp verdict(%{latest: %{outcome: :unenforced} = latest}),
    do: {[@unenforced], Readiness.netpol(latest)}

  defp verdict(%{latest: latest, enforced: enforced} = state) do
    case enforced do
      {kept, at} ->
        age = state.now_ms_fun.() - at

        if age <= state.stale_after_ms do
          note =
            "kept: the latest canary run was inconclusive (#{inspect(latest.reason, limit: 5)}), " <>
              "last enforced #{div(age, 1000)}s ago"

          check = kept |> Readiness.netpol(note) |> downgrade()
          {[], check}
        else
          {[@unenforced], Readiness.netpol(latest)}
        end

      nil ->
        {[@unenforced], Readiness.netpol(latest)}
    end
  end

  defp downgrade(%{"status" => "ok"} = check), do: %{check | "status" => "warn"}
  defp downgrade(check), do: check

  # --- listener -----------------------------------------------------------------

  defp open_listener(state, nil), do: state

  defp open_listener(state, port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, backlog: 16]) do
      {:ok, socket} ->
        acceptor = spawn_link(fn -> accept_loop(socket) end)
        %{state | listener: {socket, acceptor}}

      {:error, reason} ->
        Logger.warning("canary listener on #{port} failed: #{inspect(reason)}")
        state
    end
  end

  defp accept_loop(socket) do
    case :gen_tcp.accept(socket) do
      {:ok, conn} ->
        :gen_tcp.close(conn)
        accept_loop(socket)

      {:error, _closed} ->
        :ok
    end
  end

  defp listener_port(%{listener: nil}), do: nil

  defp listener_port(%{listener: {socket, _}}) do
    {:ok, port} = :inet.port(socket)
    port
  end
end
