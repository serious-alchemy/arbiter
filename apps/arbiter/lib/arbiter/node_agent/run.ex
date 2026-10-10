defmodule Arbiter.NodeAgent.Run do
  @moduledoc """
  One run on a node (`docs/design/remote-workers.md` §7, §10.2): a process per
  `assign` that prepares the container from a validated `Arbiter.NodeAgent.RunSpec`,
  runs it, ships its stdout, and reports how it ended.

  ## Phases

      preparing ──► running ──► exited (until the primary acks the exit) ──► stopped
          │
          └─► refused / cancelled

  `prepare` (in a task, so a long image build never blocks a `cancel`): the
  run's directories under `<node_home>/runs/<run>/`, the image (built from the
  plan the spec carries when the node lacks it), the CLI files
  (`Arbiter.NodeAgent.Files`), prompt and config-dir seeds, the secrets file on
  tmpfs (`Arbiter.NodeAgent.Secrets`), the bridge sockets, the cgroup limits for
  the controllers the user manager delegated (`Arbiter.NodeAgent.Cgroups`) and the
  test-services pod. Then `Arbiter.Worker.Container.wrap/2` builds the argv
  *here*, so the hardening is the local code, and a refusal at any step is a
  `run.refused` push, never a half-started container.

  ## stdout

  The container's stdout+stderr are read as raw chunks into an
  `Arbiter.NodeAgent.StdoutBuffer` (offset-addressed, kept until acked). Frames
  go to the sink only while connected and while fewer than `window` bytes (256
  KiB) are unacked, 16 KiB at a time. `ack/2` slides the window. After a blip
  `attach/1` rewinds to the last ack and resends: the primary drops what it has.
  A buffer that would overflow stops the run rather than drop bytes.

  ## The end

  `podman run` is started **without** `--rm` (`Container` `keep: true`) so
  `.State.OOMKilled` is readable: on exit the agent inspects it, then removes
  the container (and the pod, the secrets directory) and reports
  `exit{run, status, oom, size, cancelled, reason}`. The exit is retained and
  re-sent on every attach until the primary acks it (`ack_exit/1`), so a blip
  across the exit loses neither the status nor the tail of the output. Secrets
  are removed as soon as the container is gone.

  ## Quiesce (RW12, §10.4)

  `quiesce/1` is what a run gets when the primary does not know it (a restart took
  its Worker): the container is stopped, then the snapshot bundle and the
  transcript tarball are taken **locally** into `Arbiter.NodeAgent.Retained`, a
  `retained` push reports them, and the process ends, with no `exit` for the
  primary to ack. A run that had already exited is retained the same way.

  ## Adopt (bd-4p1vui, §10.4.3)

  `adopt/1` is what a run the primary *held* across its restart gets when a new
  Worker takes it over: a run that is still `running` (and not being stopped) is
  attached like a reconnect, and its `run.ready` says `adopted: true` and the
  `acked` offset its stdout resend starts at. Any other run answers
  `adopt.refused{run, reason}` (delivered even while detached), and stays as it is
  for the primary's quiesce, which is the fallback.

  ## Messages to the sink

  `{:run_push, run_id, event, payload}` with `event` one of `"run.ready"`,
  `"run.refused"`, `"stdout"` (`{:binary, frame}`), `"exit"`, `"retained"` and
  `"adopt.refused"`.
  """

  use GenServer, restart: :temporary

  alias Arbiter.NodeAgent.{
    Cgroups,
    Checkout,
    Exec,
    Files,
    Retained,
    RunSpec,
    Secrets,
    StdoutBuffer,
    Transcripts
  }

  alias Arbiter.Nodes.StdoutFrame
  alias Arbiter.Worker.{Container, Image, TestServices}
  alias Arbiter.Worker.ReleaseEnv

  require Logger

  @frame_bytes 16 * 1024
  @window_bytes 256 * 1024
  @default_retention_ms 30 * 60_000

  defstruct [
    :spec,
    :opts,
    :sink,
    :port,
    :task,
    :exit,
    :exit_timer,
    :pod,
    :secrets_file,
    # RW11: the shas the primary has (the prerequisites of every bundle sent back),
    # the checkpoint timer and in-flight upload, and how the last upload ended.
    :known,
    :cp_timer,
    :cp_task,
    :checkout_result,
    phase: :preparing,
    quiesce?: false,
    buffer: nil,
    sent: 0,
    connected?: false,
    cancelled: nil
  ]

  # ---- client ---------------------------------------------------------------------

  @doc false
  def start_link({%RunSpec{} = spec, opts}),
    do: GenServer.start_link(__MODULE__, {spec, opts}, name: via(spec.run))

  def via(run), do: {:via, Registry, {Arbiter.NodeAgent.RunRegistry, run}}

  @doc "Stop the run: remove the container by name; the exit is then reported as cancelled."
  @spec cancel(String.t(), String.t()) :: :ok | {:error, :not_found}
  def cancel(run, reason), do: cast(run, {:cancel, reason})

  @doc "Send `signal` (TERM or KILL) to the container's init."
  @spec signal(String.t(), String.t()) :: :ok | {:error, :not_found}
  def signal(run, signal) when signal in ["TERM", "KILL"], do: cast(run, {:signal, signal})

  @doc "The primary has every stdout byte before `offset`."
  @spec ack(String.t(), non_neg_integer()) :: :ok | {:error, :not_found}
  def ack(run, offset), do: cast(run, {:ack, offset})

  @doc "Take a checkpoint now (RW11): snapshot the shadow and upload it for the primary to ingest."
  @spec collect(String.t()) :: :ok | {:error, :not_found}
  def collect(run), do: cast(run, :collect)

  @doc """
  The primary does not know this run (RW12): stop it and retain its work locally for
  the primary to pull (`Arbiter.NodeAgent.Retained`).
  """
  @spec quiesce(String.t()) :: :ok | {:error, :not_found}
  def quiesce(run), do: cast(run, :quiesce)

  @doc """
  A new Worker on a restarted primary takes this run over (bd-4p1vui): attach it if
  it is running, else answer `adopt.refused`.
  """
  @spec adopt(String.t()) :: :ok | {:error, :not_found}
  def adopt(run), do: cast(run, :adopt)

  @doc "The primary has the `exit`: the run may go."
  @spec ack_exit(String.t()) :: :ok | {:error, :not_found}
  def ack_exit(run), do: cast(run, :ack_exit)

  @doc "The channel is up (again): rewind to the last ack and resend."
  @spec attach(String.t()) :: :ok | {:error, :not_found}
  def attach(run), do: cast(run, :attach)

  @doc "The channel went away: stop sending (output keeps accumulating, bounded)."
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(run), do: cast(run, :detach)

  @doc "What the agent reports for this run in `hello`/`hb`."
  @spec info(String.t()) :: map() | nil
  def info(run) do
    GenServer.call(via(run), :info, 5_000)
  catch
    :exit, _ -> nil
  end

  @doc "The exit report once the container has exited, `nil` before (or for an unknown run)."
  @spec outcome(String.t()) :: map() | nil
  def outcome(run) do
    GenServer.call(via(run), :outcome, 5_000)
  catch
    :exit, _ -> nil
  end

  defp cast(run, message) do
    case Registry.lookup(Arbiter.NodeAgent.RunRegistry, run) do
      [{pid, _}] -> GenServer.cast(pid, message)
      [] -> {:error, :not_found}
    end
  end

  # ---- server ---------------------------------------------------------------------

  @impl true
  def init({spec, opts}) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      spec: spec,
      opts: opts,
      sink: Keyword.get(opts, :sink, Arbiter.NodeAgent.Connection),
      # An `assign` arrives on a live channel.
      connected?: Keyword.get(opts, :connected?, true),
      buffer: StdoutBuffer.new(Keyword.get(opts, :stdout_cap, 64 * 1024 * 1024))
    }

    {:ok, start_prepare(state)}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, report(state), state}
  def handle_call(:outcome, _from, state), do: {:reply, state.exit, state}

  @impl true
  def handle_cast({:cancel, reason}, %{phase: :preparing} = state),
    do: {:noreply, %{state | cancelled: reason}}

  def handle_cast({:cancel, reason}, %{phase: :running} = state) do
    stop_container(state)
    {:noreply, %{state | cancelled: reason}}
  end

  def handle_cast({:cancel, _reason}, state), do: {:noreply, state}

  def handle_cast({:signal, signal}, %{phase: :running} = state) do
    _ = podman(state, ["kill", "--signal", signal, state.spec.name])
    {:noreply, state}
  end

  def handle_cast({:signal, _}, state), do: {:noreply, state}

  def handle_cast(:quiesce, %{phase: :preparing} = state),
    do: {:noreply, %{state | cancelled: state.cancelled || "quiesced"}}

  # Quiesce is only ever asked for on a `hello_ok`, so the channel is up; the run was not
  # `attach`ed (the primary does not know it), but its `retained` report has to get out.
  def handle_cast(:quiesce, %{phase: :running} = state) do
    stop_container(state)

    {:noreply,
     %{state | quiesce?: true, connected?: true, cancelled: state.cancelled || "quiesced"}}
  end

  def handle_cast(:quiesce, %{phase: :exited} = state) do
    if state.exit_timer, do: Process.cancel_timer(state.exit_timer)
    {:stop, :normal, retain(%{state | connected?: true})}
  end

  def handle_cast(:quiesce, state), do: {:noreply, state}

  def handle_cast(:collect, %{phase: :running} = state), do: {:noreply, checkpoint(state)}
  def handle_cast(:collect, state), do: {:noreply, state}

  def handle_cast({:ack, offset}, state) when is_integer(offset) do
    {:noreply, state |> Map.update!(:buffer, &StdoutBuffer.ack(&1, offset)) |> pump()}
  end

  def handle_cast(:ack_exit, %{exit: %{}} = state), do: {:stop, :normal, state}
  def handle_cast(:ack_exit, state), do: {:noreply, state}

  def handle_cast(:attach, state) do
    state = %{state | connected?: true, sent: StdoutBuffer.acked(state.buffer)}

    state =
      case {state.phase, state.exit} do
        {:running, _} ->
          push(state, "run.ready", %{"run" => state.spec.run, "container" => state.spec.name})

        _ ->
          state
      end

    {:noreply, state |> pump() |> resend_exit()}
  end

  def handle_cast(:detach, state), do: {:noreply, %{state | connected?: false}}

  # bd-4p1vui: only a run that is up and not on its way out can be continued.
  def handle_cast(:adopt, %{phase: :running, cancelled: nil, quiesce?: false} = state) do
    acked = StdoutBuffer.acked(state.buffer)
    state = %{state | connected?: true, sent: acked}

    state =
      push(state, "run.ready", %{
        "run" => state.spec.run,
        "container" => state.spec.name,
        "adopted" => true,
        "acked" => acked
      })

    {:noreply, pump(state)}
  end

  def handle_cast(:adopt, state) do
    {:noreply,
     deliver(state, "adopt.refused", %{"run" => state.spec.run, "reason" => adopt_refusal(state)})}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    prepared(result, %{state | task: nil})
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state),
    do: refuse(%{state | task: nil}, :unschedulable, {:prepare_crashed, inspect(reason)})

  def handle_info({ref, result}, %{cp_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | cp_task: nil} |> log_checkpoint(result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{cp_task: %Task{ref: ref}} = state),
    do: {:noreply, %{state | cp_task: nil} |> log_checkpoint({:error, {:crashed, reason}})}

  def handle_info(:checkpoint, %{phase: :running} = state),
    do: {:noreply, state |> checkpoint() |> schedule_checkpoint()}

  def handle_info(:checkpoint, state), do: {:noreply, state}

  def handle_info({port, {:data, bytes}}, %{port: port} = state) do
    case StdoutBuffer.append(state.buffer, bytes) do
      {:ok, buffer, _offset} ->
        {:noreply, pump(%{state | buffer: buffer})}

      {:error, :overflow} ->
        Logger.warning(
          "node agent: run #{state.spec.run} stdout unacknowledged past the cap; stopping it"
        )

        stop_container(state)
        {:noreply, %{state | cancelled: state.cancelled || "stdout_overflow"}}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    case finish(%{state | port: nil}, status) do
      %{phase: :retained} = retained -> {:stop, :normal, retained}
      state -> {:noreply, state}
    end
  end

  def handle_info(:retention_expired, state), do: {:stop, :normal, state}
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Whatever the way out, no container and no secret outlive the process.
    if state.phase in [:preparing, :running], do: stop_container(state)
    cleanup(state)
    :ok
  end

  # ---- prepare ---------------------------------------------------------------------

  defp start_prepare(state) do
    task =
      Task.Supervisor.async_nolink(
        Keyword.get(state.opts, :task_supervisor, Arbiter.NodeAgent.TaskSupervisor),
        fn -> prepare(state.spec, state.opts) end
      )

    %{state | task: task}
  end

  defp prepared({:ok, prepared}, state) do
    state = %{
      state
      | pod: prepared.pod,
        secrets_file: prepared.secrets_file,
        known: prepared.known
    }

    if state.cancelled do
      cancelled_before_start(state)
    else
      case open(state, prepared.argv) do
        {:ok, port} ->
          state = %{state | port: port, phase: :running} |> schedule_checkpoint()

          {:noreply,
           push(state, "run.ready", %{"run" => state.spec.run, "container" => state.spec.name})}

        {:error, reason} ->
          refuse(state, :unschedulable, {:spawn_failed, inspect(reason)})
      end
    end
  end

  defp prepared({:error, {code, detail}}, state), do: refuse(state, code, detail)

  defp refuse(state, code, detail) do
    Logger.warning(
      "node agent: run #{state.spec.run} refused: #{code} #{inspect(detail, limit: 5)}"
    )

    cleanup(state)

    state =
      push(state, "run.refused", %{
        "run" => state.spec.run,
        "reason" => Atom.to_string(code),
        "detail" => inspect(detail, limit: 10)
      })

    # Refusal is an answer, not a result to retain: the primary holds the run.
    {:stop, :normal, %{state | phase: :stopped}}
  end

  defp cancelled_before_start(state) do
    cleanup(state)
    state = %{state | exit: exit_report(state, 137, false)}
    state = state |> push("exit", state.exit) |> arm_retention()
    {:noreply, %{state | phase: :exited}}
  end

  # The preparation, in dependency order. Every failure is `{:error, {code, detail}}`
  # with `code` one of the protocol's refusal reasons.
  defp prepare(%RunSpec{} = spec, opts) do
    config = Keyword.fetch!(opts, :config)
    run_dir = Path.join([config.node_home, "runs", spec.run])

    with {:ok, dirs} <- make_dirs(spec, run_dir),
         {:ok, known} <- seed_shadow(spec, config, dirs),
         :ok <- seed_worktree_files(spec, dirs),
         :ok <- ensure_image(spec, opts),
         {:ok, cli} <- cli_files(spec, config, opts),
         {:ok, prompts} <- prompt_files(spec, run_dir),
         :ok <- seed_config(spec, dirs),
         {:ok, limit_opts} <- limits(spec, opts),
         {:ok, bridge_paths} <- bridges(spec, opts),
         {:ok, secrets_file} <- secrets(spec, opts),
         {:ok, pod, service_env} <- services(spec, opts),
         {:ok, argv} <-
           build_argv(spec, opts, %{
             dirs: dirs,
             config: config,
             cli: cli,
             prompts: prompts,
             limit_opts: limit_opts,
             bridge_paths: bridge_paths,
             secrets_file: secrets_file,
             pod: pod,
             service_env: service_env
           }) do
      {:ok, %{argv: argv, pod: pod, secrets_file: secrets_file, known: known}}
    else
      {:error, {_code, _detail}} = error ->
        # Anything partly made is removed: a refused run leaves no secret behind.
        _ = Secrets.remove(runtime_dir(opts), spec.run)
        error

      {:error, other} ->
        _ = Secrets.remove(runtime_dir(opts), spec.run)
        {:error, {:unschedulable, other}}
    end
  end

  defp make_dirs(spec, run_dir) do
    dirs =
      for %{kind: kind, path: path} <- spec.mounts,
          kind in ~w(worktree home config_dir tmp),
          into: %{} do
        {kind, %{host: Path.join(run_dir, dir_name(kind)), container: path}}
      end

    Enum.reduce_while(dirs, {:ok, dirs}, fn {_kind, %{host: host}}, acc ->
      case File.mkdir_p(host) do
        :ok -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, {:unschedulable, {:run_dir, reason}}}}
      end
    end)
  end

  # RW11: the worktree mount is a shadow clone built from the primary's seed bundle.
  defp seed_shadow(%RunSpec{checkout: nil}, _config, _dirs), do: {:ok, nil}

  defp seed_shadow(%RunSpec{checkout: co, run: run}, config, dirs) do
    shadow = dirs["worktree"].host

    with {:ok, %{known: known}} <-
           Checkout.seed_from_primary(config, Map.put(co, :run, run), shadow),
         :ok <- check_borrowed(shadow, config) do
      {:ok, known}
    else
      {:error, {:unmounted_objects, _} = reason} -> {:error, {:unschedulable, reason}}
      {:error, reason} -> {:error, {:unschedulable, {:seed_failed, reason}}}
    end
  end

  # A host path in the shadow's metadata that the container will not see is a run that
  # cannot use git; refuse it here, loudly, rather than start it (bd-1zp3ji).
  defp check_borrowed(shadow, config) do
    case Checkout.borrowed_objects(shadow) -- [Checkout.store_objects(config)] do
      [] -> :ok
      unmounted -> {:error, {:unmounted_objects, unmounted}}
    end
  end

  # bd-8y8ztm: the untracked agent config the primary injected into its worktree
  # (`.mcp.json`, `.claude/skills/…`) is not in a git bundle, so it travels in the
  # spec and is written into the shadow after the seed. The shadow's own
  # `info/exclude` names it, so a snapshot (`git add -A`) never sweeps it up.
  defp seed_worktree_files(%RunSpec{mounts: mounts}, dirs) do
    with %{files: files} when map_size(files) > 0 <- Enum.find(mounts, &(&1.kind == "worktree")),
         %{host: host} <- dirs["worktree"] do
      with :ok <- write_files(host, files, :worktree_files),
           do: exclude_files(host, Map.keys(files))
    else
      _ -> :ok
    end
  end

  defp write_files(host, files, tag) do
    Enum.reduce_while(files, :ok, fn {name, bytes}, :ok ->
      dest = Path.join(host, name)

      with :ok <- File.mkdir_p(Path.dirname(dest)),
           :ok <- File.write(dest, bytes) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:unschedulable, {tag, reason}}}}
      end
    end)
  end

  defp exclude_files(host, names) do
    info = Path.join(host, ".git/info")

    if File.dir?(info) do
      roots =
        for root <- RunSpec.worktree_file_roots(),
            Enum.any?(names, &(&1 == root or String.starts_with?(&1, root <> "/"))),
            do: root

      case File.write(
             Path.join(info, "exclude"),
             Enum.map_join(roots, "", &("/" <> &1 <> "\n")),
             [:append]
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:unschedulable, {:worktree_files, reason}}}
      end
    else
      :ok
    end
  end

  defp shadow(state),
    do: Path.join([run_config(state).node_home, "runs", state.spec.run, "worktree"])

  defp run_config(state), do: Keyword.fetch!(state.opts, :config)

  defp schedule_checkpoint(%{spec: %{checkout: nil}} = state), do: state

  defp schedule_checkpoint(%{spec: %{checkout: %{interval_ms: ms}}} = state) do
    if state.cp_timer, do: Process.cancel_timer(state.cp_timer)
    %{state | cp_timer: Process.send_after(self(), :checkpoint, ms)}
  end

  # One upload at a time, off the run process: a checkpoint of a 256 MiB bundle
  # must not hold up a cancel or an ack.
  defp checkpoint(%{spec: %{checkout: nil}} = state), do: state
  defp checkpoint(%{cp_task: %Task{}} = state), do: state

  defp checkpoint(state) do
    task =
      Task.Supervisor.async_nolink(
        Keyword.get(state.opts, :task_supervisor, Arbiter.NodeAgent.TaskSupervisor),
        fn -> upload(state) end
      )

    %{state | cp_task: task}
  end

  # The checkout bundle, then the session transcripts (best effort: they are
  # provenance, the bundle is the work).
  defp upload(state) do
    result = upload_checkout(state)

    config_dir = Path.join([run_config(state).node_home, "runs", state.spec.run, "config"])

    with {:error, reason} <- Transcripts.upload(run_config(state), state.spec.run, config_dir) do
      Logger.warning(
        "node agent: run #{state.spec.run} transcript upload failed: #{inspect(reason, limit: 5, printable_limit: 300)}"
      )
    end

    result
  end

  # A read-only checkout (a reviewer's clone, bd-cgdhlu) has no work to hand back:
  # only the transcripts are mirrored.
  defp upload_checkout(%{spec: %{checkout: %{read_only?: true}}}), do: {:ok, :read_only}

  defp upload_checkout(state) do
    Checkout.upload(
      run_config(state),
      %{run: state.spec.run, branch: state.spec.checkout.branch},
      shadow(state),
      state.known || []
    )
  end

  defp log_checkpoint(state, {:ok, _}), do: state

  defp log_checkpoint(state, {:error, reason}) do
    Logger.warning(
      "node agent: run #{state.spec.run} checkpoint failed: #{inspect(reason, limit: 5, printable_limit: 300)}"
    )

    state
  end

  # The container is gone: the last snapshot, before the exit is reported, so the
  # primary has the work by the time its owner hears the run ended.
  defp final_checkout(%{spec: %{checkout: nil}} = state), do: state

  defp final_checkout(state) do
    if state.cp_task, do: Task.shutdown(state.cp_task, :brutal_kill)
    if state.cp_timer, do: Process.cancel_timer(state.cp_timer)

    result =
      case upload(state) do
        {:ok, _} ->
          "ok"

        {:error, reason} ->
          Logger.warning(
            "node agent: run #{state.spec.run} final checkout failed: #{inspect(reason, limit: 5, printable_limit: 300)}"
          )

          "failed: " <> inspect(reason, limit: 5, printable_limit: 200)
      end

    %{state | cp_task: nil, cp_timer: nil, checkout_result: result}
  end

  defp dir_name("config_dir"), do: "config"
  defp dir_name(kind), do: kind

  defp ensure_image(spec, opts) do
    result =
      case Keyword.get(opts, :image_fun) do
        fun when is_function(fun, 2) -> fun.(spec.image, opts)
        nil -> default_image(spec.image, opts)
      end

    case result do
      :ok -> :ok
      {:error, reason} -> {:error, {:image_unavailable, reason}}
    end
  end

  defp default_image(%{tag: tag, plan: nil}, opts) do
    case Container.cmd(runner_opts(opts), podman_path(opts), ["image", "exists", tag],
           timeout: 30_000
         ) do
      {_, 0} -> :ok
      _ -> {:error, {:image_missing, tag}}
    end
  end

  defp default_image(%{tag: tag, plan: %{tag: tag} = plan}, opts) do
    case Image.Builder.ensure(Image.Builder, plan, runner_opts(opts)) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp default_image(_image, _opts), do: {:error, :plan_tag_mismatch}

  defp cli_files(spec, config, opts) do
    fetch = Keyword.get(opts, :files_fun, &Files.ensure(config, &1, &2))

    Enum.reduce_while(spec.mounts, {:ok, []}, fn
      %{kind: "cli", sha256: sha, name: name, path: dest}, {:ok, acc} ->
        case fetch.(sha, name) do
          {:ok, host} -> {:cont, {:ok, acc ++ [{host, dest}]}}
          {:error, reason} -> {:halt, {:error, {:image_unavailable, {:cli_file, name, reason}}}}
        end

      _other, acc ->
        {:cont, acc}
    end)
  end

  defp prompt_files(spec, run_dir) do
    prompts = Enum.filter(spec.mounts, &(&1.kind == "prompt"))
    dir = Path.join(run_dir, "prompt")

    Enum.reduce_while(Enum.with_index(prompts), {:ok, []}, fn {%{path: dest, content: content}, i},
                                                              {:ok, acc} ->
      host = Path.join(dir, "prompt-#{i}")

      with :ok <- File.mkdir_p(dir),
           :ok <- File.write(host, content),
           :ok <- File.chmod(host, 0o644) do
        {:cont, {:ok, acc ++ [{host, dest}]}}
      else
        {:error, reason} -> {:halt, {:error, {:unschedulable, {:prompt, reason}}}}
      end
    end)
  end

  defp seed_config(spec, dirs) do
    with %{files: files} when map_size(files) > 0 <-
           Enum.find(spec.mounts, &(&1.kind == "config_dir")),
         %{host: host} <- dirs["config_dir"] do
      Enum.reduce_while(files, :ok, fn {name, bytes}, :ok ->
        case File.write(Path.join(host, name), bytes) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:unschedulable, {:config_seed, reason}}}}
        end
      end)
    else
      _ -> :ok
    end
  end

  defp limits(spec, opts) do
    delegated =
      case Keyword.get(opts, :delegated_fun) do
        fun when is_function(fun, 0) -> fun.()
        nil -> Cgroups.delegated()
      end

    case Cgroups.limit_opts(spec.limits, delegated) do
      {:ok, limit_opts, dropped} ->
        if dropped != [],
          do:
            Logger.info(
              "node agent: run #{spec.run}: limits #{inspect(dropped)} not delegated; not applied"
            )

        {:ok, limit_opts}

      {:error, :memory_not_delegated} ->
        {:error, {:unschedulable, :memory_not_delegated}}
    end
  end

  # The per-run bridge sockets (RW10): `:bridges_fun` is `Arbiter.NodeAgent.Bridge.listen/2`
  # under the agent. Without a provider a spec that names bridges cannot run here,
  # and says so.
  defp bridges(%{bridges: []}, _opts), do: {:ok, []}

  defp bridges(spec, opts) do
    case Keyword.get(opts, :bridges_fun) do
      fun when is_function(fun, 2) ->
        case fun.(spec.run, spec.bridges) do
          {:ok, paths} when is_list(paths) -> {:ok, Enum.zip(spec.bridges, paths)}
          {:error, reason} -> {:error, {:unschedulable, {:bridges, reason}}}
        end

      nil ->
        {:error, {:unschedulable, :bridges_unavailable}}
    end
  end

  defp secrets(spec, opts) do
    case Secrets.write(
           spec.run,
           spec.secrets,
           Keyword.take(opts, [:runtime_dir, :require_tmpfs, :mountinfo])
         ) do
      {:ok, file} -> {:ok, file}
      {:error, reason} -> {:error, {:unschedulable, reason}}
    end
  end

  defp services(%{services: []}, _opts), do: {:ok, nil, []}

  defp services(spec, opts) do
    with {:ok, services} <- TestServices.resolve(spec.services),
         {:ok, started} <-
           TestServices.start(
             Keyword.merge(runner_opts(opts),
               name: spec.name,
               services: services,
               labels: labels(spec, opts),
               podman: podman_path(opts)
             )
           ) do
      {:ok, started && started.pod, (started && started.env) || []}
    else
      {:error, reason} -> {:error, {:unschedulable, {:test_services, reason}}}
    end
  end

  defp build_argv(spec, opts, parts) do
    %{dirs: dirs, prompts: prompts, bridge_paths: bridge_paths, secrets_file: secrets_file} =
      parts

    store_objects = store_objects(spec, parts.config)

    wrap_opts =
      [
        worktree: dirs["worktree"].host,
        name: spec.name,
        image: spec.image.tag,
        podman: podman_path(opts),
        home: dirs["home"] && dirs["home"].host,
        writable_paths: for(kind <- ~w(config_dir tmp), d = dirs[kind], do: d.host),
        readonly_paths: Enum.map(prompts, &elem(&1, 0)) ++ store_objects,
        cli_mounts: parts.cli,
        bridges: Enum.map(bridge_paths, &elem(&1, 1)),
        env: Map.to_list(spec.env) ++ parts.service_env,
        network: spec.network,
        keep: true,
        labels: labels(spec, opts),
        mount_map: mount_map(dirs, prompts, bridge_paths),
        secrets_file: secrets_file
      ]
      |> Keyword.merge(parts.limit_opts)
      |> then(&if(parts.pod, do: Keyword.put(&1, :pod, parts.pod), else: &1))
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    command = if secrets_file, do: Container.secrets_wrapper(spec.command), else: spec.command
    # bd-9rrrgk: what `Arbiter.NodeAgent.Exec` rebuilds a container from afterwards.
    Exec.remember(spec.run, wrap_opts)

    case Container.wrap(command, wrap_opts) do
      {:ok, argv} -> {:ok, argv}
      {:error, reason} -> {:error, {:unschedulable, {:wrap, reason}}}
    end
  end

  # bd-1zp3ji: the shadow's `.git/objects/info/alternates` names the node store's
  # `objects/` by its host path (`Checkout.seed/1`). Git in the container resolves it
  # as written, so the store's objects are bound read-only at that same path; without
  # it every git command fails (`unable to normalize alternate object path`). A bind
  # rather than a `:O` overlay: concurrent seeds keep adding packs to the store, and
  # changing an overlay's lower layer while it is mounted is undefined. Read-only, so
  # a run cannot write into objects the node's other runs borrow.
  defp store_objects(%RunSpec{checkout: nil}, _config), do: []
  defp store_objects(%RunSpec{}, config), do: [Checkout.store_objects(config)]

  defp mount_map(dirs, prompts, bridge_paths) do
    Map.new(
      for(%{host: host, container: container} <- Map.values(dirs), do: {host, container}) ++
        for({host, dest} <- prompts, do: {host, dest}) ++
        for({%{path: path}, host} <- bridge_paths, do: {host, path})
    )
  end

  defp labels(spec, opts) do
    node = Keyword.get(opts, :node_id) || "unknown"

    [{"arbiter.run", spec.run}, {"arbiter.node", node}] ++
      if(spec.task, do: [{"arbiter.task", spec.task}], else: []) ++
      if(spec.install, do: [{"arbiter.install", spec.install}], else: [])
  end

  # ---- running ---------------------------------------------------------------------

  # sobelow_skip ["CI.System"]
  defp open(state, [podman | args]) do
    env = ReleaseEnv.port_env([]) |> Enum.map(&env_charlist/1)

    port =
      Port.open(
        {:spawn_executable, podman},
        [{:args, args}, :binary, :exit_status, :stderr_to_stdout] ++
          if(env == [], do: [], else: [{:env, env}])
      )

    _ = state
    {:ok, port}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp env_charlist({name, false}), do: {to_charlist(name), false}
  defp env_charlist({name, value}), do: {to_charlist(name), to_charlist(value)}

  # Frames go out only while attached and inside the window of unacked bytes.
  defp pump(%{connected?: false} = state), do: state

  defp pump(state) do
    target =
      min(StdoutBuffer.size(state.buffer), StdoutBuffer.acked(state.buffer) + @window_bytes)

    if state.sent < target do
      {:ok, chunks} = StdoutBuffer.from(state.buffer, state.sent)
      body = chunks |> Enum.map(&elem(&1, 1)) |> IO.iodata_to_binary()
      send_frames(state, state.sent, binary_part(body, 0, target - state.sent))
      %{state | sent: target}
    else
      state
    end
  end

  defp send_frames(_state, offset, ""), do: offset

  defp send_frames(state, offset, body) do
    size = min(@frame_bytes, byte_size(body))
    <<head::binary-size(^size), rest::binary>> = body
    push(state, "stdout", {:binary, StdoutFrame.encode(state.spec.run, offset, head)})
    send_frames(state, offset + size, rest)
  end

  # ---- exit --------------------------------------------------------------------------

  # RW12: the container is gone because the primary no longer knows the run. Its work
  # is kept on this node, not uploaded: nothing on the primary would accept it.
  defp finish(%{quiesce?: true} = state, _status) do
    stop_container(state)
    cleanup(state)
    retain(state)
  end

  defp finish(state, status) do
    oom? = oom?(state)
    stop_container(state)
    cleanup(state)
    state = final_checkout(state)

    exit = exit_report(state, status, oom?)
    state = %{state | exit: exit, phase: :exited}
    state = state |> push("exit", exit) |> arm_retention()
    state
  end

  defp retain(state) do
    if state.cp_task, do: Task.shutdown(state.cp_task, :brutal_kill)
    if state.cp_timer, do: Process.cancel_timer(state.cp_timer)
    cleanup(state)

    checkout = state.spec.checkout

    info = %{
      run: state.spec.run,
      task: state.spec.task,
      name: state.spec.name,
      install: state.spec.install,
      branch: checkout && checkout.branch,
      base: checkout && checkout.base,
      shadow: shadow(state),
      config_dir: Path.join([run_config(state).node_home, "runs", state.spec.run, "config"])
    }

    manifest = Retained.retain(run_config(state), info, state.known || [])

    state =
      push(
        %{state | phase: :retained, cp_task: nil, cp_timer: nil},
        "retained",
        Retained.report(manifest)
      )

    Logger.info("node agent: run #{state.spec.run} quiesced and retained")
    state
  end

  defp exit_report(state, status, oom?) do
    %{
      "run" => state.spec.run,
      "status" => status,
      "oom" => oom?,
      "size" => StdoutBuffer.size(state.buffer),
      "container" => state.spec.name,
      "cancelled" => not is_nil(state.cancelled),
      "reason" => state.cancelled
    }
    |> put_checkout(state.checkout_result)
  end

  defp put_checkout(report, nil), do: report
  defp put_checkout(report, result), do: Map.put(report, "checkout", result)

  defp resend_exit(%{exit: %{} = exit} = state), do: push(state, "exit", exit)
  defp resend_exit(state), do: state

  defp arm_retention(state) do
    ms = Keyword.get(state.opts, :exit_retention_ms, @default_retention_ms)
    %{state | exit_timer: Process.send_after(self(), :retention_expired, ms)}
  end

  defp oom?(state) do
    args = ["inspect", "--format", "{{.State.OOMKilled}}", state.spec.name]

    case podman(state, args) do
      {out, 0} -> String.trim(out) == "true"
      _ -> false
    end
  end

  defp stop_container(state) do
    _ =
      Container.stop(
        state.spec.name,
        runner_opts(state.opts) ++ [podman: podman_path(state.opts)]
      )

    :ok
  end

  defp cleanup(state) do
    if state.pod,
      do:
        TestServices.stop(state.pod, runner_opts(state.opts) ++ [podman: podman_path(state.opts)])

    Secrets.remove(runtime_dir(state.opts), state.spec.run)
    release_bridges(state)
    :ok
  end

  defp release_bridges(%{spec: %{bridges: [_ | _], run: run}, opts: opts}) do
    case Keyword.get(opts, :bridges_release_fun) do
      fun when is_function(fun, 1) -> fun.(run)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp release_bridges(_state), do: :ok

  defp adopt_refusal(%{quiesce?: true}), do: "quiescing"
  defp adopt_refusal(%{phase: :running}), do: "cancelling"
  defp adopt_refusal(%{phase: phase}), do: Atom.to_string(phase)

  defp report(state) do
    %{
      "id" => state.spec.run,
      "state" => Atom.to_string(state.phase),
      "container" => state.spec.name,
      "stdout_offset" => StdoutBuffer.size(state.buffer),
      "acked" => StdoutBuffer.acked(state.buffer),
      "exited" => not is_nil(state.exit)
    }
  end

  # ---- plumbing ----------------------------------------------------------------------

  defp push(%{connected?: false} = state, "run.refused" = event, payload),
    do: deliver(state, event, payload)

  defp push(%{connected?: false} = state, _event, _payload), do: state
  defp push(state, event, payload), do: deliver(state, event, payload)

  defp deliver(state, event, payload) do
    send(state.sink, {:run_push, state.spec.run, event, payload})
    state
  end

  defp podman(state, args),
    do: Container.cmd(runner_opts(state.opts), podman_path(state.opts), args, timeout: 30_000)

  defp podman_path(opts),
    do: Keyword.get(opts, :podman) || System.find_executable("podman") || "podman"

  defp runner_opts(opts), do: Keyword.take(opts, [:runner])

  defp runtime_dir(opts) do
    case Secrets.runtime_dir(opts) do
      {:ok, dir} -> dir
      _ -> nil
    end
  end
end
