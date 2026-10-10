defmodule Arbiter.NodeAgent.K8s.Controller do
  @moduledoc """
  The k8s controller core (`docs/design/remote-workers.md` K§3 and K§4, ticket K5):
  the run table of the in-cluster agent. One bare Pod per run; the pod informer is the
  only source of truth about what a pod is doing.

  ## What it owns

    * **Admission** (`assign/3`): the Lease, the config, an informer that has synced,
      then `Arbiter.NodeAgent.K8s.Admission` (`running + pending < max_concurrent`
      and `ResourceQuota` headroom ≥ 1), else `{:error, {:refuse, :no_capacity,
      detail}}`. A `403` from the API server over quota is the same refusal.
    * **Lifecycle**: every informer event is folded through the pure
      `Arbiter.NodeAgent.K8s.PodState`. A pod is `pending` until the scheduler placed
      it and `starting` until the **worker container is running**; only then is
      `run.ready` sent. `schedule_s` after creation a pod that is still unscheduled is
      deleted and the assign refused `unschedulable` (the scheduler's message
      verbatim), so a pending pod is never reported running and never waits forever.
    * **Cancel / teardown** (`cancel/4`, `signal/3`): one `DELETE` of the pod, with the
      pod's grace period when the snapshotter should finalise (`collect: true`,
      `signal TERM`), else 0.
    * **Adoption**: a pod carrying this install's and node's labels and a run label
      that the table does not know is adopted from whatever state it is in. A controller
      restart therefore deletes nothing and loses nothing: `Informer.subscribe/2` hands
      over the pods, they become runs, and `attach_all/2` re-announces them when the
      primary asks.
    * **The sweeper** (`reap/2`): `Arbiter.NodeAgent.K8s.Sweeper` selects pods whose run
      is outside the primary's live set; they are deleted with the pod's grace period
      (the SIGTERM path, so the snapshotter can upload a salvage checkpoint). Nothing
      here runs on its own initiative: `reap{install, live_set}` only arrives from the
      primary, and only when it is the single primary (`SingleInstance.primary?/1`).
    * **Finished pods**: after `exit_ack`, a pod that exited 0 is deleted at once; a
      failed one is kept `retain_failed_s` for `kubectl describe`/`logs`.

  ## The Lease

  `:lease` (a `Arbiter.NodeAgent.K8s.Lease`, or `nil` for none) is consulted on every
  assign, every reap and every retention delete. Without it the controller **assigns
  nothing and reaps nothing**; cancels and signals of runs it already owns still go
  through (stopping a run is never the unsafe direction), and it keeps observing.

  ## What it does not do (yet)

  Log streaming into `stdout` frames (K§3.4) and holding `exit` until the final
  checkpoint has been forwarded (K§10.3) are not in this module, and neither is the
  node-agent boot that wires it to `Arbiter.NodeAgent.Connection` and
  `Arbiter.NodeAgent.PodChannel` (`Arbiter.NodeAgent.Backend.K8s` is the seam). A pod
  adopted after a restart is also unknown to the pod channel's in-memory run table
  (K6 mints leaves in memory), so its bridges stay down until that table can be
  rebuilt; the pod itself runs on.

  ## Messages out

  Pushes go to `:sink` (the connection) as `{:run_push, run, event, payload}`:
  `"run.ready"`, `"run.refused"`, `"exit"`, and `"capacity"` (run `nil`) when the
  ConfigMap changes. `:observer` (tests, diagnostics) additionally gets
  `{:run_observed, run, tag, resource_version}` after each pod event is folded in.

  Options: `:client`, `:informer`, `:config_loader`, `:readiness` (a
  `Arbiter.NodeAgent.K8s.ReadinessMonitor`: `report/1` carries its `degraded` and check
  list, and each of its runs is pushed as `"readiness"`), `:lease` (pid/name or `nil`),
  `:pod_channel` (`{module, server}` with `register/3`, `bind_pod_ip/3`, `release/2`;
  default `Arbiter.NodeAgent.PodChannel.Runs`), `:identity` (`registry`, `install_id`,
  `node_id`, `owner_uid`, `bridge_addr`, `gate_addr`, `own_pod`, `own_uid`,
  `max_wall_s`), `:sink`, `:observer`, `:now_fun`, `:tick_ms` (default 5 000; `nil`
  for none, tests call `tick/1`), `:protect_s` (default 60), `:name`.
  """

  use GenServer

  alias Arbiter.NodeAgent.K8s.Admission
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.ControllerConfig
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.NodeAgent.K8s.Lease
  alias Arbiter.NodeAgent.K8s.PodSpec
  alias Arbiter.NodeAgent.K8s.PodState
  alias Arbiter.NodeAgent.K8s.Quota
  alias Arbiter.NodeAgent.K8s.ReadinessMonitor
  alias Arbiter.NodeAgent.K8s.RunReport
  alias Arbiter.NodeAgent.K8s.Sweeper
  alias Arbiter.NodeAgent.PodChannel.Runs, as: PodRuns
  alias Arbiter.NodeAgent.RunSpec

  require Logger

  @install_label "arbiter.dev/install"
  @node_label "arbiter.dev/node"
  @run_label "arbiter.dev/run"
  @deadline_slack_s 1800
  @default_tick_ms 5_000
  @default_protect_s 60

  @type refusal :: {:refuse, :no_capacity | :bad_spec | :unschedulable, String.t()}

  # --- API ----------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :id, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Admit and create the pod for `spec` (the decoded `assign` spec, with its `"run"`).
  `{:ok, run}` once the pod exists; it is **pending**, and `run.ready` follows when the
  worker container runs. `{:error, {:refuse, reason, detail}}`, or
  `{:error, :already_running}`.
  """
  @spec assign(GenServer.server(), map(), keyword()) ::
          {:ok, String.t()} | {:error, refusal() | :already_running}
  def assign(controller \\ __MODULE__, spec, opts \\ []),
    do: GenServer.call(controller, {:assign, spec, opts}, 60_000)

  @doc """
  Delete the run's pod. `collect: true` gives it the pod's grace period (the
  snapshotter finalises on SIGTERM); the default is grace 0.
  """
  @spec cancel(GenServer.server(), String.t(), String.t(), keyword()) ::
          :ok | {:error, :not_found}
  def cancel(controller \\ __MODULE__, run, reason, opts \\ []),
    do: GenServer.call(controller, {:cancel, run, reason, opts}, 60_000)

  @doc "TERM deletes with the pod's grace period; KILL deletes with grace 0."
  @spec signal(GenServer.server(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def signal(controller \\ __MODULE__, run, signal) when signal in ["TERM", "KILL"],
    do: GenServer.call(controller, {:signal, run, signal}, 60_000)

  @doc "The primary acknowledged the run's `exit`: its pod may now be cleaned up."
  @spec exit_ack(GenServer.server(), String.t()) :: :ok
  def exit_ack(controller \\ __MODULE__, run), do: GenServer.call(controller, {:exit_ack, run})

  @doc """
  The channel is (back) up: say again what the primary may have missed (`run.ready`,
  `exit`, `run.refused`) for every run but `skip`.
  """
  @spec attach_all(GenServer.server(), [String.t()]) :: :ok
  def attach_all(controller \\ __MODULE__, skip \\ []),
    do: GenServer.call(controller, {:attach_all, skip})

  @doc """
  The primary's `reap{install, live_set}`. `%{containers: [], pods: names, dirs: []}`
  (the machine reaper's shape), `{:error, :not_leader}` without the Lease,
  `{:error, :install_mismatch | :no_install}`.
  """
  @spec reap(GenServer.server(), map()) :: map() | {:error, atom()}
  def reap(controller \\ __MODULE__, request), do: GenServer.call(controller, {:reap, request})

  @doc """
  What `hello` and `hb` carry: `%{runs: [...], capacity: hb.capacity, degraded:
  [...]}`.
  """
  @spec report(GenServer.server()) :: %{
          runs: [map()],
          capacity: map(),
          degraded: [String.t()],
          readiness: map() | nil
        }
  def report(controller \\ __MODULE__), do: GenServer.call(controller, :report)

  @doc "Ids of the runs the table holds."
  @spec run_ids(GenServer.server()) :: [String.t()]
  def run_ids(controller \\ __MODULE__), do: GenServer.call(controller, :run_ids)

  @doc "The run's exit payload once it has exited, else `nil`."
  @spec outcome(GenServer.server(), String.t()) :: map() | nil
  def outcome(controller \\ __MODULE__, run), do: GenServer.call(controller, {:outcome, run})

  @doc "Run one housekeeping pass now: quota, timeouts, retention, retried deletes."
  @spec tick(GenServer.server()) :: :ok
  def tick(controller \\ __MODULE__), do: GenServer.call(controller, :tick, 60_000)

  # --- server -------------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      client: Keyword.fetch!(opts, :client),
      informer: Keyword.fetch!(opts, :informer),
      loader: Keyword.fetch!(opts, :config_loader),
      lease: opts[:lease],
      readiness: opts[:readiness],
      channel: Keyword.get(opts, :pod_channel, {PodRuns, PodRuns}),
      identity: Keyword.fetch!(opts, :identity),
      sink: opts[:sink],
      observer: opts[:observer],
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      tick_ms: Keyword.get(opts, :tick_ms, @default_tick_ms),
      protect_s: Keyword.get(opts, :protect_s, @default_protect_s),
      runs: %{},
      reaping: MapSet.new(),
      quota: :unknown,
      synced?: false
    }

    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    :ok = ConfigLoader.subscribe(state.loader, self())
    if state.readiness, do: :ok = ReadinessMonitor.subscribe(state.readiness, self())
    {:ok, pods} = Informer.subscribe(state.informer, self())
    state = %{state | synced?: Informer.synced?(state.informer)}
    state = Enum.reduce(pods, state, &on_pod_event(:added, &1, &2))
    {:noreply, state |> refresh_quota() |> schedule_tick()}
  end

  @impl true
  def handle_call({:assign, spec, opts}, _from, state) do
    state = if opts[:sink], do: %{state | sink: opts[:sink]}, else: state
    {reply, state} = do_assign(spec, state)
    {:reply, reply, state}
  end

  def handle_call({:cancel, run, reason, opts}, _from, state) do
    case Map.fetch(state.runs, run) do
      {:ok, entry} ->
        grace = if opts[:collect], do: grace_s(state), else: 0
        {:reply, :ok, put_entry(state, cancel_entry(state, entry, reason, grace))}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:signal, run, signal}, _from, state) do
    case Map.fetch(state.runs, run) do
      {:ok, entry} ->
        grace = if signal == "TERM", do: grace_s(state), else: 0
        {:reply, :ok, put_entry(state, delete_pod(state, entry, grace))}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:exit_ack, run}, _from, state) do
    state =
      case Map.fetch(state.runs, run) do
        {:ok, %{phase: :exited} = entry} -> cleanup_exited(state, %{entry | acked?: true})
        _ -> state
      end

    {:reply, :ok, state}
  end

  def handle_call({:attach_all, skip}, _from, state) do
    for {run, entry} <- state.runs, run not in skip, do: announce(state, entry)
    {:reply, :ok, state}
  end

  def handle_call({:reap, request}, _from, state) do
    {reply, state} = do_reap(request, state)
    {:reply, reply, state}
  end

  def handle_call(:report, _from, state), do: {:reply, build_report(state), state}
  def handle_call(:run_ids, _from, state), do: {:reply, Map.keys(state.runs), state}

  def handle_call({:outcome, run}, _from, state) do
    reply =
      case state.runs do
        %{^run => %{exit: exit}} -> exit
        _ -> nil
      end

    {:reply, reply, state}
  end

  def handle_call(:tick, _from, state), do: {:reply, :ok, housekeeping(state)}

  @impl true
  def handle_info({:pod_event, _informer, type, pod}, state),
    do: {:noreply, on_pod_event(type, pod, state)}

  def handle_info({:pod_synced, _informer}, state), do: {:noreply, %{state | synced?: true}}

  def handle_info({:controller_config, _loader, _config}, state) do
    state = refresh_quota(state)
    push(state, nil, "capacity", build_report(state).capacity)
    {:noreply, state}
  end

  def handle_info({:k8s_readiness, _monitor, report}, state) do
    push(state, nil, "readiness", %{
      "degraded" => report.degraded,
      "readiness" => ReadinessMonitor.hello_readiness(report)
    })

    {:noreply, state}
  end

  def handle_info(:tick, state), do: {:noreply, state |> housekeeping() |> schedule_tick()}
  def handle_info(_other, state), do: {:noreply, state}

  # --- assign -------------------------------------------------------------------

  defp do_assign(spec, state) do
    with :ok <- gate_leader(state),
         {:ok, config} <- gate_config(state),
         :ok <- gate_synced(state),
         {:ok, run_spec} <- validate_spec(spec),
         :ok <- gate_unknown(state, run_spec),
         state = refresh_quota(state, config),
         :ok <- gate_admission(state, config),
         {:ok, state, entry} <- create(state, config, run_spec) do
      {{:ok, entry.run}, put_entry(state, entry)}
    else
      {:error, _} = error -> {error, state}
    end
  end

  defp gate_leader(state) do
    if leader?(state),
      do: :ok,
      else: {:error, {:refuse, :no_capacity, "not the active controller (lease not held)"}}
  end

  defp gate_config(state) do
    case ConfigLoader.current(state.loader) do
      {:ok, config} -> {:ok, config}
      {:error, :no_config} -> {:error, {:refuse, :no_capacity, "no valid controller config"}}
    end
  end

  defp gate_synced(%{synced?: true}), do: :ok

  defp gate_synced(_state),
    do: {:error, {:refuse, :no_capacity, "pod informer has not synced yet"}}

  defp validate_spec(spec) do
    case RunSpec.validate(spec) do
      {:ok, run_spec} -> {:ok, run_spec}
      {:error, reason} -> {:error, {:refuse, :bad_spec, inspect(reason, limit: 10)}}
    end
  end

  defp gate_unknown(state, run_spec) do
    case state.runs do
      %{} = runs when is_map_key(runs, run_spec.run) -> {:error, :already_running}
      _ -> :ok
    end
  end

  defp gate_admission(state, config) do
    case Admission.decide(facts(state, config)) do
      :ok -> :ok
      {:refuse, reason, detail} -> {:error, {:refuse, reason, detail}}
    end
  end

  defp create(state, config, run_spec) do
    now = state.now_fun.()
    deadline = DateTime.add(now, state.identity.max_wall_s + @deadline_slack_s, :second)

    with {:ok, nonce} <- register(state, run_spec, deadline),
         {:ok, pod} <- build(state, config, run_spec, nonce),
         {:ok, created} <- create_pod(state, pod) do
      {:ok, state, new_entry(run_spec.run, created, now)}
    else
      {:error, reason} ->
        release(state, run_spec.run)
        {:error, reason}
    end
  end

  defp register(state, run_spec, deadline) do
    {mod, server} = state.channel

    case mod.register(server, run_spec, deadline) do
      {:ok, nonce} -> {:ok, nonce}
      {:error, reason} -> {:error, {:refuse, :no_capacity, "pod channel: #{inspect(reason)}"}}
    end
  end

  defp build(state, config, run_spec, nonce) do
    facts =
      state.identity
      |> Map.take(~w(registry install_id node_id owner_uid bridge_addr gate_addr max_wall_s)a)
      |> Map.put(:boot_nonce, nonce)

    case PodSpec.build(run_spec, ControllerConfig.pod_config(config, facts)) do
      {:ok, pod} ->
        {:ok, pod}

      {:error, {:bad_spec, reason}} ->
        {:error, {:refuse, :bad_spec, inspect(reason, limit: 10)}}

      {:error, {:bad_config, reason}} ->
        {:error, {:refuse, :bad_spec, "config: #{inspect(reason)}"}}
    end
  end

  defp create_pod(state, pod) do
    case Client.create_pod(state.client, pod) do
      {:ok, created} ->
        {:ok, created}

      {:error, :already_exists} ->
        {:error, :already_running}

      {:error, {:forbidden, message}} ->
        {:error, forbidden(message)}

      {:error, {:invalid, message}} ->
        {:error, {:refuse, :bad_spec, message}}

      {:error, other} ->
        {:error, {:refuse, :no_capacity, "kubernetes API: #{inspect(other, limit: 5)}"}}
    end
  end

  # The API server enforces the quota too: a POST over it is a synchronous 403.
  defp forbidden(message) do
    if message =~ ~r/quota/i,
      do: {:refuse, :no_capacity, message},
      else: {:refuse, :bad_spec, "forbidden: " <> message}
  end

  defp new_entry(run, pod, now) do
    %{
      run: run,
      pod: pod["metadata"]["name"],
      uid: pod["metadata"]["uid"],
      phase: :live,
      state: :pending,
      detail: %{},
      assigned_at: now,
      created_at: now,
      cancelled: nil,
      expected_delete?: false,
      retry_delete: nil,
      ready_sent?: false,
      exit: nil,
      exited_at: nil,
      acked?: false,
      gone?: false,
      last_pod: pod,
      bound_ip: nil,
      refusal: nil,
      registered?: true
    }
  end

  # --- pod events -----------------------------------------------------------------

  defp on_pod_event(type, pod, state) do
    labels = get_in(pod, ["metadata", "labels"]) || %{}
    uid = get_in(pod, ["metadata", "uid"])

    cond do
      not ours?(labels, state.identity) -> state
      MapSet.member?(state.reaping, uid) -> forget_reaped(state, type, uid)
      true -> fold_pod(type, pod, labels[@run_label], state)
    end
  end

  defp ours?(labels, identity) do
    labels[@install_label] == identity.install_id and labels[@node_label] == identity.node_id and
      is_binary(labels[@run_label]) and labels[@run_label] != ""
  end

  defp forget_reaped(state, :deleted, uid),
    do: %{state | reaping: MapSet.delete(state.reaping, uid)}

  defp forget_reaped(state, _type, _uid), do: state

  defp fold_pod(:deleted, pod, run, state) do
    pod_uid = pod["metadata"]["uid"]

    case state.runs do
      %{^run => %{uid: uid} = entry} when uid in [nil, pod_uid] ->
        {entry, state} = observe_deleted(entry, pod, state)
        state |> put_entry(entry) |> observed(run, :deleted, resource_version(pod))

      _ ->
        state
    end
  end

  defp fold_pod(_type, pod, run, state) do
    pod_uid = pod["metadata"]["uid"]

    case state.runs do
      %{^run => %{uid: uid} = entry} when uid in [nil, pod_uid] ->
        observe_pod(%{entry | uid: pod_uid, last_pod: pod}, pod, state)

      %{^run => _stale} ->
        state

      _ ->
        observe_pod(adopt(pod, run, state), pod, state)
    end
  end

  # A pod this table does not know, labelled as ours: a controller restart (or a
  # primary-side re-assign we never saw). Adopted in whatever state it is in.
  defp adopt(pod, run, state) do
    now = state.now_fun.()
    entry = new_entry(run, pod, now)

    %{
      entry
      | assigned_at: nil,
        created_at: parse_time(pod["metadata"]["creationTimestamp"]) || now,
        registered?: false
    }
  end

  defp observe_pod(entry, pod, state) do
    config = current_config(state)
    ps = PodState.observe(pod, observe_opts(state, config))

    {entry, state} = apply_state(entry, ps, state, config)
    {entry, state} = bind_ip(entry, pod, state)
    state |> put_entry(entry) |> observed(entry.run, tag(ps), resource_version(pod))
  end

  defp observed(state, run, tag, rv) do
    if state.observer, do: send(state.observer, {:run_observed, run, tag, rv})
    state
  end

  defp tag({tag, _}), do: tag

  defp resource_version(pod), do: get_in(pod, ["metadata", "resourceVersion"])

  # The pod the API reported DELETED.
  defp observe_deleted(entry, pod, state) do
    config = current_config(state)

    case PodState.deleted(pod, [expected?: entry.expected_delete?] ++ observe_opts(state, config)) do
      :gone -> gone(%{entry | last_pod: pod}, state)
      ps -> pod_gone(entry, ps, pod, state, config)
    end
  end

  defp pod_gone(entry, ps, pod, state, config) do
    {entry, state} = apply_state(%{entry | last_pod: pod}, ps, state, config)
    mark_gone(entry, state)
  end

  # The pod is gone and we asked for it: a cancelled run reports its exit; a run we
  # refused, or one whose exit is already out, just leaves the table.
  defp gone(%{phase: :live, cancelled: reason} = entry, state) when is_binary(reason) do
    {entry, state} = finish_exit(entry, RunReport.cancelled(entry), state)
    mark_gone(entry, state)
  end

  defp gone(entry, state), do: mark_gone(entry, state)

  defp mark_gone(entry, state) do
    entry = %{entry | gone?: true}

    # An exit the primary has not acknowledged yet stays until `exit_ack/2`.
    if entry.phase == :exited and not entry.acked?,
      do: {entry, state},
      else: {nil, drop(state, entry)}
  end

  defp drop(state, entry) do
    release(state, entry.run)
    %{state | runs: Map.delete(state.runs, entry.run)}
  end

  # --- state transitions ----------------------------------------------------------

  # Once a run's outcome is out (or it was refused) the pod's later states change nothing.
  defp apply_state(%{phase: phase} = entry, _ps, state, _config) when phase != :live,
    do: {entry, state}

  defp apply_state(entry, {:pending, info} = ps, state, config) do
    entry = %{entry | state: :pending, detail: info}

    if unschedulable_for_too_long?(entry, info, state, config) do
      refuse(entry, :unschedulable, schedule_detail(info, config), state)
    else
      _ = ps
      {entry, state}
    end
  end

  defp apply_state(entry, {:starting, info}, state, _config),
    do: {%{entry | state: :starting, detail: info}, state}

  defp apply_state(entry, {:running, _}, state, _config) do
    entry = %{entry | state: :running, detail: %{}}

    if entry.ready_sent? do
      {entry, state}
    else
      push(state, entry.run, "run.ready", RunReport.ready(entry))
      {%{entry | ready_sent?: true}, state}
    end
  end

  defp apply_state(entry, {:terminating, _}, state, _config),
    do: {%{entry | state: :terminating}, state}

  defp apply_state(entry, {:exit, _} = ps, state, _config),
    do: finish_exit(entry, RunReport.exit(entry, ps), state)

  defp apply_state(entry, {:interrupted, _} = ps, state, _config),
    do: finish_exit(entry, RunReport.exit(entry, ps), state)

  defp apply_state(entry, {:refuse, info}, state, _config),
    do: refuse(entry, info.reason, info.detail, state)

  defp unschedulable_for_too_long?(_entry, _info, _state, nil), do: false
  defp unschedulable_for_too_long?(_entry, %{reason: :queued}, _state, _config), do: false

  defp unschedulable_for_too_long?(entry, _info, state, config) do
    DateTime.diff(state.now_fun.(), entry.created_at) >= config.timeouts["schedule_s"]
  end

  defp schedule_detail(%{message: message}, _config) when is_binary(message) and message != "",
    do: message

  defp schedule_detail(_info, config),
    do: "the pod was not scheduled within #{config.timeouts["schedule_s"]}s"

  defp finish_exit(entry, payload, state) do
    push(state, entry.run, "exit", payload)
    release(state, entry.run)

    {%{entry | phase: :exited, state: :exited, exit: payload, exited_at: state.now_fun.()}, state}
  end

  # The run never started: tell the primary, take the pod away.
  defp refuse(entry, reason, detail, state) do
    push(state, entry.run, "run.refused", RunReport.refused(reason, detail))
    release(state, entry.run)
    entry = %{entry | phase: :refused, state: :refused, refusal: {reason, detail}}
    {delete_pod(state, entry, 0), state}
  end

  defp bind_ip(%{registered?: true, phase: :live} = entry, pod, state) do
    with ip when is_binary(ip) <- get_in(pod, ["status", "podIP"]),
         true <- ip != entry.bound_ip,
         {:ok, parsed} <- :inet.parse_address(String.to_charlist(ip)) do
      {mod, server} = state.channel
      mod.bind_pod_ip(server, entry.run, parsed)
      {%{entry | bound_ip: ip}, state}
    else
      _ -> {entry, state}
    end
  end

  defp bind_ip(entry, _pod, state), do: {entry, state}

  # --- deleting pods -------------------------------------------------------------

  defp cancel_entry(state, %{phase: :live} = entry, reason, grace) do
    delete_pod(state, %{entry | cancelled: reason, state: :terminating}, grace)
  end

  # A finished or refused run: cancel is just "clean it up now".
  defp cancel_entry(state, entry, _reason, _grace), do: delete_pod(state, entry, 0)

  # Returns the entry; a failed API call is retried by `housekeeping/1`.
  defp delete_pod(state, entry, grace) do
    entry = %{entry | expected_delete?: true}

    case Client.delete_pod(state.client, entry.pod, grace_period_seconds: grace, uid: entry.uid) do
      {:ok, _} ->
        %{entry | retry_delete: nil}

      {:error, reason} ->
        Logger.warning(
          "k8s controller: delete of pod #{entry.pod} failed (#{inspect(reason, limit: 5)}); will retry"
        )

        %{entry | retry_delete: grace}
    end
  end

  defp cleanup_exited(state, entry) do
    cond do
      entry.gone? -> drop(state, entry)
      not leader?(state) -> put_entry(state, entry)
      retention_over?(state, entry) -> put_entry(state, delete_pod(state, entry, 0))
      true -> put_entry(state, entry)
    end
  end

  defp retention_over?(state, entry) do
    retain = if clean_exit?(entry), do: 0, else: retain_failed_s(state)
    DateTime.diff(state.now_fun.(), entry.exited_at) >= retain
  end

  defp clean_exit?(%{exit: %{"status" => 0, "cancelled" => false}}), do: true
  defp clean_exit?(_), do: false

  # --- the sweeper ----------------------------------------------------------------

  defp do_reap(%{install: install}, state) when install in [nil, ""],
    do: {{:error, :no_install}, state}

  defp do_reap(%{install: install}, %{identity: %{install_id: own}} = state) when install != own,
    do: {{:error, :install_mismatch}, state}

  defp do_reap(request, state) do
    if leader?(state) do
      selection = select_orphans(request, state)
      state = Enum.reduce(selection, state, &quiesce_orphan/2)
      {%{containers: [], pods: Enum.map(selection, & &1.name), dirs: []}, state}
    else
      {{:error, :not_leader}, state}
    end
  end

  defp select_orphans(request, state) do
    state.informer
    |> Informer.pods()
    |> Sweeper.select(
      install: state.identity.install_id,
      node: state.identity.node_id,
      live_set: request[:live_set] || request["live_set"] || [],
      protected: protected_runs(state),
      own_pod: state.identity[:own_pod],
      own_uid: state.identity[:own_uid]
    )
  end

  # SIGTERM path: the pod's own grace period, so the snapshotter can upload a salvage
  # checkpoint. The run leaves the table (the primary does not know it) and its pod is
  # remembered by uid so the events of its termination do not adopt it again.
  defp quiesce_orphan(%{name: name, uid: uid, run: run}, state) do
    case Client.delete_pod(state.client, name, grace_period_seconds: grace_s(state), uid: uid) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("k8s controller: sweep of #{name}: #{inspect(reason)}")
    end

    release(state, run)

    %{
      state
      | runs: Map.delete(state.runs, run),
        reaping: if(uid, do: MapSet.put(state.reaping, uid), else: state.reaping)
    }
  end

  defp protected_runs(state) do
    for {run, %{assigned_at: %DateTime{} = at}} <- state.runs,
        DateTime.diff(state.now_fun.(), at) < state.protect_s,
        do: run
  end

  # --- housekeeping -----------------------------------------------------------------

  defp schedule_tick(%{tick_ms: ms} = state) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :tick, ms)
    state
  end

  defp schedule_tick(state), do: state

  defp housekeeping(state) do
    state = refresh_quota(state)

    state.runs
    |> Map.values()
    |> Enum.reduce(state, &tend/2)
  end

  # One run's periodic pass: re-evaluate time-based rows (schedule/pull timeouts), retry
  # a failed delete, and clean up what has been acknowledged.
  defp tend(entry, state) do
    config = current_config(state)
    entry = Map.get(state.runs, entry.run, entry)

    {entry, state} =
      if entry.phase == :live and entry.last_pod do
        ps = PodState.observe(entry.last_pod, observe_opts(state, config))
        apply_state(entry, ps, state, config)
      else
        {entry, state}
      end

    state = put_entry(state, entry)
    entry = retry_delete(state, entry)
    state = put_entry(state, entry)

    if entry.phase == :exited and entry.acked?, do: cleanup_exited(state, entry), else: state
  end

  defp retry_delete(state, %{retry_delete: grace} = entry) when is_integer(grace) do
    if leader?(state) or entry.cancelled, do: delete_pod(state, entry, grace), else: entry
  end

  defp retry_delete(_state, entry), do: entry

  # --- capacity ---------------------------------------------------------------------

  defp refresh_quota(state), do: refresh_quota(state, current_config(state))

  defp refresh_quota(state, nil), do: state

  defp refresh_quota(state, config) do
    quota =
      case Client.list_resource_quotas(state.client) do
        {:ok, items} -> Quota.headroom(items, Quota.demand(config))
        {:error, _} -> :unknown
      end

    %{state | quota: quota}
  end

  defp facts(state, config) do
    live = for {_run, %{phase: :live} = entry} <- state.runs, do: entry

    %{
      max_concurrent: config.max_concurrent,
      running: Enum.count(live, &(&1.state in [:running, :terminating])),
      pending: Enum.count(live, &(&1.state in [:pending, :starting])),
      unschedulable:
        Enum.count(
          live,
          &(&1.state == :pending and Map.get(&1.detail, :reason) == :unschedulable)
        ),
      headroom: state.quota,
      draining?: false
    }
  end

  defp build_report(state) do
    runs =
      state.runs |> Map.values() |> Enum.sort_by(& &1.run) |> Enum.map(&RunReport.inventory/1)

    capacity =
      case current_config(state) do
        nil -> %{}
        config -> Admission.capacity(facts(state, config))
      end

    {degraded, readiness} = readiness_facts(state)

    %{
      runs: runs,
      capacity: capacity,
      degraded: Enum.uniq(ConfigLoader.degraded(state.loader) ++ degraded),
      readiness: readiness
    }
  end

  # K13: the readiness monitor's verdict (`degraded: netpol_unenforced`, the check list). A
  # controller started without one (tests of the run table) reports neither.
  defp readiness_facts(%{readiness: nil}), do: {[], nil}

  defp readiness_facts(%{readiness: monitor}) do
    report = ReadinessMonitor.report(monitor)
    {report.degraded, ReadinessMonitor.hello_readiness(report)}
  end

  defp announce(state, %{phase: :live, state: :running} = entry),
    do: push(state, entry.run, "run.ready", RunReport.ready(entry))

  defp announce(state, %{phase: :exited, exit: exit} = entry),
    do: push(state, entry.run, "exit", exit)

  defp announce(state, %{phase: :refused, refusal: {reason, detail}} = entry),
    do: push(state, entry.run, "run.refused", RunReport.refused(reason, detail))

  defp announce(_state, _entry), do: :ok

  # --- small helpers ----------------------------------------------------------------

  defp put_entry(state, nil), do: state
  defp put_entry(state, entry), do: %{state | runs: Map.put(state.runs, entry.run, entry)}

  defp current_config(state) do
    case ConfigLoader.current(state.loader) do
      {:ok, config} -> config
      {:error, :no_config} -> nil
    end
  end

  defp observe_opts(state, nil), do: [now: state.now_fun.()]

  defp observe_opts(state, config),
    do: [now: state.now_fun.(), pull_timeout_s: config.timeouts["pull_s"]]

  defp grace_s(state), do: timeout(state, "grace_s", 120)
  defp retain_failed_s(state), do: timeout(state, "retain_failed_s", 300)

  defp timeout(state, key, default) do
    case current_config(state) do
      nil -> default
      config -> config.timeouts[key] || default
    end
  end

  defp leader?(%{lease: nil}), do: true
  defp leader?(%{lease: lease}), do: Lease.held?(lease)

  defp release(state, run) do
    {mod, server} = state.channel
    mod.release(server, run)
  end

  defp push(%{sink: sink}, run, event, payload) when is_pid(sink),
    do: send(sink, {:run_push, run, event, payload})

  defp push(_state, _run, _event, _payload), do: :ok

  defp parse_time(nil), do: nil

  defp parse_time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, time, _} -> time
      _ -> nil
    end
  end
end
