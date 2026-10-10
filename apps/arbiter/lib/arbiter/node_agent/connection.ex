defmodule Arbiter.NodeAgent.Connection do
  @moduledoc """
  The agent's one outbound channel to the primary (`docs/design/remote-workers.md`
  §4, §6, §10.1): connect, join `node:<node_id>`, `hello`, then heartbeat, and
  come back after any loss.

      connecting ─► joining ─► hello ─► ready ──► (closed) ─► backoff ─► connecting
                                         │
                                         └─ no `hb_ack` for `fence_after` ─► fenced ─► backoff

  * **Reconnect.** Every loss (refused connect, rejected upgrade, a close, a
    missed ack, a join or hello error) schedules the next attempt after
    `Arbiter.NodeAgent.Backoff.delay/2`, 1 s doubling to 30 s with jitter. The
    attempt counter resets only on a `hello_ok`, so a primary that accepts the
    socket and then drops it cannot be hammered at a flat rate.
  * **`hello`.** Version, proto, arch, capability flags, capacity, live runs and
    the readiness report (`PodmanReadiness.diagnose/1`, cached for
    `readiness_ttl_ms`: it starts probe containers, so a reconnect loop must not
    re-run it). It is computed in a task, so a slow podman cannot block the
    process; a `hello_timeout_ms` bounds the whole wait.
  * **Heartbeat.** `hb_interval` seconds from `hello_ok` (default
    `config.hb_interval_ms`). The agent **self-fences** when no ack has arrived
    for `fence_after` (default 60 s): it logs, records `fenced` in the status
    file and drops the connection, so the invariant `fence < lost` (§10.1) holds
    from the agent's side. With no runs yet there is nothing to quiesce.
  * **Upgrade.** A `hello_ok` (or an `upgrade` push) carrying
    `upgrade{version, sha256}` goes to `Arbiter.NodeAgent.Upgrader`; the first
    `hello_ok` of a freshly upgraded agent also confirms the upgrade.
  * **Runs (RW9).** `assign{run, spec}` starts a run (`Arbiter.NodeAgent.Runs`),
    answered by the run's own `run.ready` / `run.refused` push; `cancel`,
    `signal`, `ack{run, offset}` and `exit_ack{run}` address a run by id. The
    run processes send `{:run_push, run, event, payload}` here, and this process
    puts them on the channel (`stdout` as a binary `StdoutFrame`). On `hello_ok`
    every run is re-attached (it resends what the primary has not acknowledged),
    runs the primary does not know are cancelled, and on any loss the runs are
    detached; a **fence** also stops every container (§10.1).
  * **Bridges (RW10).** `Arbiter.NodeAgent.Bridge` owns the per-run listeners and
    their streams; this process attaches it to the channel on `hello_ok`,
    detaches it on any loss, and hands it the `bridge.*` events. Its pushes go
    straight to the socket, not through here.
  * **Restart recovery (RW12, §10.4–10.6).** A `hello_ok` whose per-run verdict is
    `"unknown"` (the primary restarted, or lost the run) **quiesces** that run
    (`Arbiter.NodeAgent.Run.quiesce/1`): container stopped, snapshot bundle and
    transcripts taken locally into `Arbiter.NodeAgent.Retained`, a `retained`
    push. Every `hello` lists what is retained (`inventory.retained`). The primary
    asks for it with `recover{run}` (answered by `recovered{run, …}` once the
    uploads are done) and says it may go with `retained.drop{run}`. A changed
    `boot_epoch` is logged and recorded in the status file. `reap{install,
    live_set}` runs `Arbiter.NodeAgent.Reaper`, install-scoped.
  * Events the later children own (`drain`, `rotate`) are logged and ignored.
  """
  use GenServer

  alias Arbiter.NodeAgent.Backoff
  alias Arbiter.NodeAgent.Bridge
  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Protocol
  alias Arbiter.NodeAgent.Retained
  alias Arbiter.NodeAgent.Run
  alias Arbiter.NodeAgent.Runs
  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.Upgrade
  alias Arbiter.NodeAgent.Upgrader
  alias Arbiter.NodeAgent.WsClient

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "A snapshot for tests and diagnostics (never contains the credential)."
  @spec info(GenServer.server()) :: map()
  def info(server \\ __MODULE__), do: GenServer.call(server, :info)

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)

    state = %{
      config: config,
      status: Keyword.get(opts, :status, Status),
      upgrader: Keyword.get(opts, :upgrader, Upgrader),
      task_supervisor: Keyword.get(opts, :task_supervisor, Arbiter.NodeAgent.TaskSupervisor),
      phase: :connecting,
      client: nil,
      client_ref: nil,
      attempt: 0,
      join_ref: nil,
      hello_ref: nil,
      readiness_task: nil,
      readiness: nil,
      reap_task: nil,
      boot_epoch: nil,
      hb_timer: nil,
      hb_seq: 0,
      hb_refs: MapSet.new(),
      last_ack: nil,
      hello_ok: nil,
      hello_timer: nil,
      retry_timer: nil
    }

    put_status(state, %{
      state: "connecting",
      agent_version: config.version,
      proto: Config.proto(),
      node_id: config.node_id,
      primary_url: config.primary_url
    })

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_call(:info, _from, state) do
    {:reply, Map.take(state, [:phase, :attempt, :hb_seq, :hello_ok, :last_ack]), state}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(%{state | retry_timer: nil})}

  # -- messages from the socket ----------------------------------------------------

  def handle_info({:ws, pid, :open}, %{client: pid} = state), do: {:noreply, state}

  def handle_info({:ws, pid, :closed, reason}, %{client: pid} = state) do
    {:noreply, lost(state, "closed: #{inspect(reason)}")}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{client_ref: ref} = state) do
    {:noreply, lost(%{state | client: nil}, "client exited: #{inspect(reason)}")}
  end

  def handle_info({:ws, pid, :reply, ref, status, response}, %{client: pid} = state) do
    {:noreply, reply(state, ref, status, response)}
  end

  def handle_info({:ws, pid, :push, _topic, event, payload}, %{client: pid} = state) do
    {:noreply, push(state, event, payload)}
  end

  # A message from a client we have already dropped.
  def handle_info({:ws, _stale, _kind, _a}, state), do: {:noreply, state}
  def handle_info({:ws, _stale, _kind, _a, _b}, state), do: {:noreply, state}
  def handle_info({:ws, _stale, _kind, _a, _b, _c}, state), do: {:noreply, state}

  # -- runs (RW9) ----------------------------------------------------------------------

  def handle_info({:run_push, _run, event, payload}, %{phase: :ready, client: client} = state)
      when is_pid(client) do
    WsClient.push(client, Protocol.topic(state.config), event, payload)
    {:noreply, state}
  end

  # Not connected: the run keeps its output and resends on the next attach.
  def handle_info({:run_push, _run, _event, _payload}, state), do: {:noreply, state}

  # -- readiness task ------------------------------------------------------------------

  def handle_info({ref, report}, %{readiness_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    state = %{
      state
      | readiness_task: nil,
        readiness: {report, System.monotonic_time(:millisecond)}
    }

    {:noreply, send_hello(state, report)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{readiness_task: ref} = state) do
    report = readiness_failure("readiness probe crashed: #{inspect(reason)}")
    {:noreply, send_hello(%{state | readiness_task: nil}, report)}
  end

  # -- reaper (RW12) --------------------------------------------------------------------

  def handle_info({ref, result}, %{reap_task: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, reaped(%{state | reap_task: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reap_task: ref} = state) do
    Logger.warning("node agent: reaper crashed: #{inspect(reason, limit: 5)}")
    {:noreply, %{state | reap_task: nil}}
  end

  # -- timers -----------------------------------------------------------------------------

  def handle_info(:heartbeat, %{phase: :ready} = state), do: {:noreply, heartbeat(state)}
  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:hello_timeout, %{phase: phase} = state) when phase in [:joining, :hello] do
    {:noreply, lost(state, "no hello_ok within #{div(state.config.hello_timeout_ms, 1000)}s")}
  end

  def handle_info(:hello_timeout, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{client: client}) when is_pid(client), do: WsClient.close(client)
  def terminate(_reason, _state), do: :ok

  # -- connect ---------------------------------------------------------------------------------

  defp connect(state) do
    config = state.config

    case WsClient.start(
           url: Config.socket_url(config),
           owner: self(),
           proxy: config.proxy,
           connect_timeout_ms: config.connect_timeout_ms
         ) do
      {:ok, client} ->
        ref = Process.monitor(client)
        join_ref = client |> WsClient.join(Protocol.topic(config), %{}) |> ref_or_nil()

        timer = Process.send_after(self(), :hello_timeout, config.hello_timeout_ms)

        put_status(state, %{state: "joining", attempt: state.attempt})

        %{
          state
          | client: client,
            client_ref: ref,
            join_ref: join_ref,
            phase: :joining,
            hello_timer: timer
        }

      {:error, reason} ->
        schedule_retry(state, "connect failed: #{inspect(reason)}")
    end
  end

  # -- replies ---------------------------------------------------------------------------------

  defp reply(%{join_ref: ref} = state, ref, "ok", _response) do
    state = %{state | join_ref: nil, phase: :hello}

    case state.readiness do
      {report, at} ->
        if System.monotonic_time(:millisecond) - at < state.config.readiness_ttl_ms,
          do: send_hello(state, report),
          else: probe_readiness(state)

      nil ->
        probe_readiness(state)
    end
  end

  defp reply(%{join_ref: ref} = state, ref, status, response) do
    lost(state, "join #{status}: #{inspect(response)}")
  end

  defp reply(%{hello_ref: ref} = state, ref, "ok", response) do
    hello_ok(%{state | hello_ref: nil}, response || %{})
  end

  defp reply(%{hello_ref: ref} = state, ref, status, response) do
    lost(%{state | hello_ref: nil}, "hello #{status}: #{inspect(response)}")
  end

  defp reply(state, ref, "ok", _response) do
    if MapSet.member?(state.hb_refs, ref), do: ack(state, ref), else: state
  end

  defp reply(state, _ref, _status, _response), do: state

  defp push(state, "hello_ok", payload) when state.phase == :hello, do: hello_ok(state, payload)
  defp push(state, "hb_ack", _payload) when state.phase == :ready, do: ack(state, nil)

  defp push(state, "upgrade", payload) do
    request_upgrade(state, payload)
    state
  end

  defp push(state, "assign", %{"run" => run, "spec" => spec}) when is_map(spec) do
    case backend(state).start_run(%{spec: Map.put(spec, "run", run), opts: run_opts(state)}) do
      {:ok, _run} ->
        :ok

      {:error, :already_running} ->
        # A repeated assign (the primary asked again after a blip): say where it is.
        Run.attach(run)

      {:error, {:refused, reason}} ->
        Logger.warning("node agent: refused run #{inspect(run)}: #{inspect(reason, limit: 5)}")

        send(
          self(),
          {:run_push, run, "run.refused",
           %{"run" => run, "reason" => "bad_spec", "detail" => inspect(reason, limit: 10)}}
        )

      {:error, reason} ->
        send(
          self(),
          {:run_push, run, "run.refused",
           %{"run" => run, "reason" => "unschedulable", "detail" => inspect(reason, limit: 10)}}
        )
    end

    state
  end

  defp push(state, "cancel", %{"run" => run} = payload) do
    case backend(state).stop({run, payload["reason"] || "cancelled"}) do
      :ok -> :ok
      {:error, :not_found} -> send(self(), {:run_push, run, "run.gone", %{"run" => run}})
    end

    state
  end

  # bd-9rrrgk: the primary wants a command run in a run's container (the pre-push
  # recipe). It can take minutes, so it runs off this process and answers with an
  # `exec.result`: `status` + `output`, or an `error` when it could not be started.
  @max_exec_seconds 3600
  defp push(state, "exec", %{"run" => run, "id" => id, "command" => command, "timeout_s" => secs})
       when is_binary(run) and is_binary(id) and is_binary(command) and is_integer(secs) and
              secs > 0 do
    me = self()
    backend = backend(state)
    opts = run_opts(state)
    secs = min(secs, @max_exec_seconds)

    Task.Supervisor.start_child(state.task_supervisor, fn ->
      result =
        case exec(backend, run, command, secs, opts) do
          {output, status} when is_binary(output) and is_integer(status) ->
            %{"status" => status, "output" => output}

          {:error, reason} ->
            %{"error" => inspect(reason, limit: 10, printable_limit: 300)}
        end

      send(me, {:run_push, run, "exec.result", Map.merge(result, %{"run" => run, "id" => id})})
    end)

    state
  end

  # RW11: the primary wants a checkpoint now.

  defp push(state, "collect", %{"run" => run, "kind" => "checkout"}) do
    backend(state).collect(run, kind: "checkout")
    state
  end

  defp push(state, "signal", %{"run" => run, "signal" => signal})
       when signal in ["TERM", "KILL"] do
    backend(state).signal(run, signal)
    state
  end

  defp push(state, "ack", %{"run" => run, "offset" => offset}) when is_integer(offset) do
    Run.ack(run, offset)
    state
  end

  defp push(state, "exit_ack", %{"run" => run}) do
    Run.ack_exit(run)
    state
  end

  # RW12: the primary wants a retained run's work (the uploads go through the ordinary
  # endpoints, off this process); `recovered` says they are done.
  defp push(state, "recover", %{"run" => run}) when is_binary(run) do
    config = state.config
    me = self()

    Task.Supervisor.start_child(state.task_supervisor, fn ->
      result =
        case Retained.pull(config, run) do
          {:ok, parts} -> parts
          {:error, reason} -> %{"error" => Atom.to_string(reason)}
        end

      send(me, {:run_push, run, "recovered", Map.put(result, "run", run)})
    end)

    state
  end

  # bd-24o760: the primary decided a held run is to be collected, not kept.
  defp push(state, "quiesce", %{"run" => run}) when is_binary(run) do
    Logger.warning("node agent: primary asked to quiesce run #{run} for recovery")
    Run.quiesce(run)
    state
  end

  defp push(state, "retained.drop", %{"run" => run}) when is_binary(run) do
    Retained.drop(state.config, run)
    state
  end

  defp push(%{reap_task: nil} = state, "reap", %{"install" => install, "live_set" => live})
       when is_binary(install) and is_list(live) do
    run_opts = state.config.run_opts || []

    opts =
      run_opts
      |> Keyword.take([:podman, :runner, :runtime_dir, :reap_min_age_s])
      |> rename_min_age()

    config = state.config

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        config.backend.reap(%{
          config: config,
          request: %{install: install, live_set: Enum.filter(live, &is_binary/1)},
          opts: opts
        })
      end)

    %{state | reap_task: task.ref}
  end

  defp push(state, "reap", _payload), do: state

  defp push(state, "bridge." <> _ = event, payload) when state.phase == :ready do
    Bridge.from_primary(bridge(state), event, payload)
    state
  end

  defp push(state, event, _payload) do
    Logger.debug("node agent: ignoring #{inspect(event)} (not handled by this agent version)")
    state
  end

  # -- hello ------------------------------------------------------------------------------------

  defp probe_readiness(state) do
    backend = state.config.backend
    fun = state.config.readiness_fun || (&backend.readiness/0)

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        try do
          fun.()
        rescue
          error -> readiness_failure("readiness probe raised: #{Exception.message(error)}")
        end
      end)

    %{state | readiness_task: task.ref}
  end

  defp readiness_failure(detail) do
    %{
      ready: false,
      installed: false,
      checks: [%{id: "readiness", name: "readiness", status: "fail", detail: detail, hint: nil}]
    }
  end

  defp send_hello(%{client: client, phase: phase} = state, report)
       when is_pid(client) and phase == :hello do
    payload = Protocol.hello(state.config, jsonable(report))
    ref = client |> WsClient.push(Protocol.topic(state.config), "hello", payload) |> ref_or_nil()
    put_status(state, %{state: "hello_sent", readiness_ready: report_ready(report)})
    %{state | hello_ref: ref}
  end

  # The connection was lost while the probe ran: the next connection sends hello.
  defp send_hello(state, _report), do: state

  defp report_ready(%{ready: ready}), do: ready
  defp report_ready(%{"ready" => ready}), do: ready
  defp report_ready(_), do: nil

  # Atom-keyed maps with atom values go through JSON as strings; make the shape
  # explicit here rather than relying on Jason's coercion at the call site.
  defp jsonable(report), do: report |> Jason.encode!() |> Jason.decode!()

  defp hello_ok(state, payload) do
    config = state.config
    hb_interval_ms = seconds_to_ms(payload["hb_interval"], config.hb_interval_ms)
    fence_after_ms = seconds_to_ms(payload["fence_after"], config.fence_after_ms)

    cancel(state.hello_timer)

    # Seeded with `hb_interval_ms` so the timer below has the same value the
    # fence check measures against.
    config = %{config | hb_interval_ms: hb_interval_ms, fence_after_ms: fence_after_ms}

    state = %{
      state
      | config: config,
        phase: :ready,
        attempt: 0,
        hello_ok: payload,
        hello_timer: nil,
        last_ack: now(),
        hb_timer: Process.send_after(self(), :heartbeat, hb_interval_ms)
    }

    put_status(state, %{
      state: "ready",
      attempt: 0,
      last_hello_ok_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      boot_epoch: payload["boot_epoch"],
      effective_max_workers: payload["max_workers"]
    })

    if Upgrade.confirm(config) == :confirmed,
      do: Logger.info("node agent upgrade to #{config.version} confirmed")

    request_upgrade(state, payload["upgrade"])
    attach_runs(payload["runs"])
    Bridge.attach(bridge(state), state.client, Protocol.topic(config))
    note_boot_epoch(state, payload["boot_epoch"])
  end

  # A new `boot_epoch` is a primary that restarted (§10.4): everything it does not
  # list as known was just quiesced by `attach_runs/1`.
  defp note_boot_epoch(%{boot_epoch: epoch} = state, epoch), do: state

  defp note_boot_epoch(state, epoch) do
    if state.boot_epoch,
      do: Logger.warning("node agent: the primary restarted (boot_epoch changed)")

    put_status(state, %{boot_epoch_changed_at: DateTime.utc_now() |> DateTime.to_iso8601()})
    %{state | boot_epoch: epoch}
  end

  defp backend(state), do: state.config.backend

  defp exec(backend, run, command, secs, opts) do
    Code.ensure_loaded(backend)

    if function_exported?(backend, :exec, 4),
      do: backend.exec(run, command, secs, opts),
      else: {:error, :unsupported}
  rescue
    e -> {:error, {:exec_crashed, Exception.message(e)}}
  end

  defp bridge(state), do: Keyword.get(state.config.run_opts, :bridge, Bridge)

  defp rename_min_age(opts) do
    case Keyword.pop(opts, :reap_min_age_s) do
      {nil, opts} -> opts
      {age, opts} -> Keyword.put(opts, :min_age_s, age)
    end
  end

  defp reaped(state, %{containers: [], pods: [], dirs: []}), do: state

  defp reaped(state, %{containers: containers, pods: pods, dirs: dirs}) do
    send(
      self(),
      {:run_push, nil, "reaped", %{"containers" => containers, "pods" => pods, "dirs" => dirs}}
    )

    state
  end

  defp reaped(state, _error), do: state

  # Re-attach every run (each resends what the primary has not acknowledged).
  # A run the primary says it does not know is not one to keep alive: its owner
  # is gone, so it is quiesced (§10.4): the container is stopped and the work is
  # retained locally for the primary to recover.
  defp attach_runs(verdicts) do
    unknown = for {run, "unknown"} <- verdicts || %{}, do: run
    # bd-24o760: a held run is the primary's, not yet decided: neither quiesced nor attached
    # (it has no stream to resend into) until the primary says `quiesce`.
    held = for {run, "hold"} <- verdicts || %{}, do: run

    Enum.each(held, fn run ->
      Logger.info("node agent: primary is holding run #{run} for recovery")
    end)

    Enum.each(unknown, fn run ->
      Logger.warning("node agent: primary does not know run #{run}; quiescing it")
      Run.quiesce(run)
    end)

    Runs.attach_all(unknown ++ held)
  end

  defp run_opts(state) do
    [config: state.config, sink: self(), node_id: state.config.node_id] ++
      (state.config.run_opts || [])
  end

  defp request_upgrade(_state, nil), do: :ok

  defp request_upgrade(state, %{"version" => _} = spec) do
    Upgrader.request(state.upgrader, spec)
    :ok
  catch
    # No upgrader running (a test that does not start one): nothing to ask.
    :exit, _ -> :ok
  end

  defp request_upgrade(_state, _other), do: :ok

  defp seconds_to_ms(seconds, _default) when is_number(seconds) and seconds > 0,
    do: round(seconds * 1000)

  defp seconds_to_ms(_, default), do: default

  # -- heartbeat + fence ------------------------------------------------------------------------

  defp heartbeat(state) do
    config = state.config

    if now() - state.last_ack >= config.fence_after_ms do
      Logger.warning("node agent fenced: no hb_ack for #{div(config.fence_after_ms, 1000)}s")
      put_status(state, %{fenced_at: DateTime.utc_now() |> DateTime.to_iso8601()})
      # §10.1: by the time the primary declares the node lost, the containers are stopped.
      Runs.fence_all()
      lost(state, "fenced: no hb_ack for #{div(config.fence_after_ms, 1000)}s")
    else
      seq = state.hb_seq + 1

      ref =
        WsClient.push(state.client, Protocol.topic(config), "hb", Protocol.heartbeat(config, seq))

      put_status(state, %{hb_seq: seq})

      %{
        state
        | hb_seq: seq,
          hb_refs: state.hb_refs |> MapSet.put(ref) |> bound(),
          hb_timer: Process.send_after(self(), :heartbeat, config.hb_interval_ms)
      }
    end
  end

  defp ack(state, ref) do
    put_status(state, %{last_hb_ack_at: DateTime.utc_now() |> DateTime.to_iso8601()})
    %{state | last_ack: now(), hb_refs: MapSet.delete(state.hb_refs, ref)}
  end

  # Unacked refs are bounded: a primary that never acks must not grow the set.
  defp bound(refs), do: if(MapSet.size(refs) > 64, do: MapSet.new(), else: refs)

  # -- loss + retry -------------------------------------------------------------------------------

  defp lost(state, reason) do
    Runs.detach_all()
    Bridge.detach(bridge(state))
    if state.client, do: WsClient.close(state.client)
    if state.client_ref, do: Process.demonitor(state.client_ref, [:flush])
    cancel(state.hb_timer)
    cancel(state.hello_timer)

    state = %{
      state
      | client: nil,
        client_ref: nil,
        join_ref: nil,
        hello_ref: nil,
        hb_timer: nil,
        hello_timer: nil,
        hb_refs: MapSet.new(),
        hello_ok: nil
    }

    schedule_retry(state, reason)
  end

  defp schedule_retry(state, reason) do
    delay = Backoff.delay(state.attempt, state.config.backoff)
    Logger.warning("node agent disconnected (#{reason}); retrying in #{delay} ms")

    put_status(state, %{
      state: "backoff",
      attempt: state.attempt + 1,
      next_retry_ms: delay,
      last_error: reason
    })

    %{
      state
      | phase: :backoff,
        attempt: state.attempt + 1,
        retry_timer: Process.send_after(self(), :connect, delay)
    }
  end

  # -- small helpers --------------------------------------------------------------------------------

  defp put_status(state, changes), do: Status.put(state.status, changes)
  # A closed client answers `{:error, :closed}`; its `:closed` message is already
  # on the way and drives the retry, so the ref is simply absent.
  defp ref_or_nil(ref) when is_binary(ref), do: ref
  defp ref_or_nil(_), do: nil

  defp now, do: System.monotonic_time(:millisecond)

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
