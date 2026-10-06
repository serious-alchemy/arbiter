defmodule Arbiter.Worker.Container do
  @moduledoc """
  The rootless-podman worker sandbox (bd-bu4ye2, P3 of
  `docs/design/podman-worker-containers.md`): a pure argv builder like
  `Arbiter.Worker.Jail.argv/2`, plus teardown by container name.

  A container starts from an empty root and adds, where the bwrap jail starts
  from `--ro-bind / /` and subtracts. Nothing is visible unless this module
  mounts or passes it.

  ## The argv

      podman run --name <arb-…> --init --rm --pull=never \\
        --userns=keep-id --read-only --cap-drop=all \\
        --security-opt no-new-privileges [--security-opt label=disable] \\
        --network=none|pasta --tmpfs /tmp:… --tmpfs /dev/shm:… \\
        -v <worktree>:<worktree>:rw,Z [-v <git dir>:<git dir>:rw,Z] \\
        [-v <objects>:<objects>:O] [-v <home>…] \\
        [-v <writable path>:…:rw] [-v <bridge socket>:…:ro] [-v <read-only path>:…:ro] \\
        [-e NAME …] [-e NAME=value …] [-i] -w <worktree> \\
        -- <image> <command…>

    * **User namespace** — `--userns=keep-id`: the in-container uid is the host
      uid, so bind-mounted files need no chown. No other identity flag.
    * **Read-only root** — `--read-only`; the only writable places are the
      tmpfs mounts and the mounts listed in the spec.
    * **Capabilities** — `--cap-drop=all` and `no-new-privileges`; nothing
      adds one back.
    * **Env allowlist** — nothing is inherited. `:inherit_env` names become
      `-e NAME` (the value comes from the environment of the `podman` client, so
      a token is never on argv where `ps` would show it); `:env` pairs become
      `-e NAME=value` for non-secret literals.
    * **Mounts** — the worker's checkout at its own absolute path (private,
      relabelled `:Z`), the main repo's `objects/` as an overlay (`:O`: readable
      with no relabel of the host checkout, writes are discarded), the per-run
      HOME, `sandbox.writable_paths`, and one read-only bind per bridge socket.
      For a private clone (git layout B, bd-4wy1w1) also its `.git` as a mount
      point of its own (`:git_dir`, so it cannot be renamed away or replaced by
      a `gitdir:` file) and `:readonly_paths` bound read-only last, on top of
      everything writable: `Arbiter.Worker.PrivateClone.mounts/1` builds that
      set.
    * **Label policy (design §5.3, decided 2026-10-02)** —
      `--security-opt label=disable` is added **only** when the container has
      bridge sockets: a confined `container_t` cannot `connect()` to an
      unconfined host listener. Every other container keeps its SELinux
      confinement. With the label disabled nothing is relabelled (`:Z` is
      dropped); without it, private mounts get `:Z` and shared ones never do.
    * **Network** — `--network=none` unless `network: :pasta` is asked for. A
      container with bridges is always `none`; the sockets are its only exit.

  ## In a test-services pod

  With `:pod` (bd-dmcbos, `Arbiter.Worker.TestServices`) the argv carries
  `--pod <name>` instead of `--userns=keep-id` and `--network=…`: podman refuses
  either on a pod member, and the pod was created with `--network none
  --userns keep-id`, so the container is as isolated as before and also shares
  `lo` with its services. Everything else (read-only root, no capabilities, the
  label policy, mounts, env) is unchanged.

  ## The `--` boundary

  `--` comes **before the image**, not before the command: podman parses
  `image -- cmd` as a command named `--` (reproduced). Adapters that split a
  jailed argv at the first `--` therefore get `[image | command]` as the
  inner part; resolving the CLI inside the image is the wrap point's job (P7).

  ## Teardown by name (design §6.4)

  Killing the `podman run` client is not a reliable way to stop the container:
  the design's probe saw `kill -KILL` leave it running and `kill -TERM` leave
  one whose PID 1 ignores signals. Podman 5.8.7 with a Port-attached client
  removed it on its own, so the behaviour varies; do not rely on either.
  So every container is named (`name_for/1`, always `arb-…`), run with `--init`
  and `--rm`, and `stop/2` / `teardown/1` remove it by name
  (`podman rm --force --ignore --time 0`). `run/2` does that in an `after`, so
  success, a non-zero exit, a crash and a timeout all end with the container
  gone. `stop/2` refuses a name without the `arb-` prefix: teardown can never
  touch a container Arbiter did not start.

  Not covered: the BEAM itself being killed between `podman run` and the
  `after` (nothing can run then). A caller that spawns through a `Port`
  instead of `run/2` must call `teardown/1` from its own exit path, and the
  worktree sweeper should reap `arb-*` containers it does not own.

  ## Wiring

  `Arbiter.Worker.Sandbox.module/1` still refuses `:podman`: the adapters only
  check that gate before spawning, so resolving it for every provider would run
  the ones with no wrap point unsandboxed. `Sandbox.module/2` resolves it for
  Claude alone, whose wrap point is `Arbiter.Worker.ContainerSpawn` (P7,
  bd-d2o3xb): it builds the spec for this module out of a dispatch's policy,
  checkout, config dir, token env and egress bridges.
  """

  @behaviour Arbiter.Worker.Sandbox

  alias Arbiter.Worker.PodmanReadiness
  alias Arbiter.Worker.ReleaseEnv

  require Logger

  @name_prefix "arb-"
  @name_re ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}\z/
  @env_re ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @default_timeout_ms 600_000
  @stop_timeout_ms 30_000

  @type mount_mode :: :ro | :rw | :rw_private | :overlay
  @type network :: :none | :pasta

  @type spec :: %{
          required(:podman) => String.t(),
          required(:image) => String.t(),
          required(:name) => String.t(),
          required(:worktree) => String.t(),
          optional(:home) => String.t() | nil,
          optional(:objects) => String.t() | nil,
          optional(:git_dir) => String.t() | nil,
          optional(:readonly_paths) => [String.t()],
          optional(:cli_mounts) => [{String.t(), String.t()}],
          optional(:worktree_readonly) => boolean(),
          optional(:writable_paths) => [String.t()],
          optional(:bridges) => [String.t()],
          optional(:tmpfs) => [String.t()],
          optional(:env) => [{String.t(), String.t()}],
          optional(:inherit_env) => [String.t()],
          optional(:network) => network(),
          optional(:pod) => String.t() | nil,
          optional(:interactive) => boolean(),
          optional(:memory) => String.t() | nil,
          optional(:memory_swap) => String.t() | nil,
          optional(:cpus) => String.t() | nil,
          optional(:labels) => [{String.t(), String.t()}],
          optional(:keep) => boolean(),
          optional(:mount_map) => %{optional(String.t()) => String.t()}
        }

  # -- naming ----------------------------------------------------------------

  @doc "The container name for run `id` (`arb-<id>`)."
  @spec name_for(String.t()) :: String.t()
  def name_for(id) when is_binary(id), do: @name_prefix <> id

  # -- the pure builder --------------------------------------------------------

  @doc """
  The full `podman run` argv for `spec`, ending in `["--", image | command]`.
  Pure: validation and every existence check live in `wrap/2`.

  Opt-in spec keys (RW8a, none changes the argv when absent): `:memory`,
  `:memory_swap` and `:cpus` (`--memory`, `--memory-swap`, `--cpus` values),
  `:labels` (`[{key, value}]`, extra `--label`s), `keep: true` (omit `--rm`,
  so `.State.OOMKilled` is readable after exit; the caller then owns removal)
  and `:mount_map` (`%{host_path => container_path}`: the container side of a
  `-v` and the `-w` workdir, for a host path that lives elsewhere inside the
  container). The hardening flags are emitted whatever these are.
  """
  @spec argv(spec(), [String.t()]) :: [String.t()]
  def argv(%{podman: podman, image: image, name: name, worktree: worktree} = spec, command)
      when is_list(command) do
    bridges = Map.get(spec, :bridges, [])
    label_disabled? = bridges != []
    home = Map.get(spec, :home)

    Enum.concat([
      [podman, "run", "--name", name, "--init"],
      if(Map.get(spec, :keep, false), do: [], else: ["--rm"]),
      ["--pull=never"],
      placement(spec),
      ["--read-only", "--cap-drop=all"],
      ["--security-opt", "no-new-privileges"],
      if(label_disabled?, do: ["--security-opt", "label=disable"], else: []),
      Enum.flat_map(["/tmp", "/dev/shm"] ++ Map.get(spec, :tmpfs, []), &tmpfs_args/1),
      mounts(spec, label_disabled?),
      env_args(spec, home && mapped(spec, home)),
      limit_args(spec),
      Enum.flat_map(Map.get(spec, :labels, []), fn {k, v} -> ["--label", "#{k}=#{v}"] end),
      if(Map.get(spec, :interactive, false), do: ["-i"], else: []),
      ["-w", mapped(spec, worktree), "--", image],
      command
    ])
  end

  # A container in a test-services pod (`Arbiter.Worker.TestServices`) takes its
  # user namespace and its network from the pod, which was created with
  # `--userns keep-id --network none`: podman refuses either flag on a member.
  defp placement(%{pod: pod}) when is_binary(pod), do: ["--pod", pod]
  defp placement(spec), do: ["--userns=keep-id", "--network=#{network(spec)}"]

  defp network(spec),
    do: if(Map.get(spec, :bridges, []) == [], do: Map.get(spec, :network, :none), else: :none)

  defp limit_args(spec) do
    for {key, flag} <- [memory: "--memory", memory_swap: "--memory-swap", cpus: "--cpus"],
        value = Map.get(spec, key),
        value != nil,
        arg <- [flag, to_string(value)],
        do: arg
  end

  defp mapped(spec, path), do: Map.get(Map.get(spec, :mount_map, %{}), path, path)

  defp tmpfs_args("/dev/shm"), do: ["--tmpfs", "/dev/shm:rw,nosuid,nodev,noexec,size=64m"]
  defp tmpfs_args("/tmp"), do: ["--tmpfs", "/tmp:rw,nosuid,nodev"]
  defp tmpfs_args(path), do: ["--tmpfs", path <> ":rw,nosuid,nodev"]

  # Read-only re-binds come last, so nothing writable is mounted over them.
  defp mounts(%{worktree: worktree} = spec, label_disabled?) do
    worktree_mode = if Map.get(spec, :worktree_readonly, false), do: :ro, else: :rw_private
    home = Map.get(spec, :home)
    objects = Map.get(spec, :objects)
    git_dir = Map.get(spec, :git_dir)

    Enum.flat_map(
      [{worktree, worktree_mode}] ++
        if(git_dir, do: [{git_dir, worktree_mode}], else: []) ++
        if(home, do: [{home, :rw_private}], else: []) ++
        if(objects, do: [{objects, :overlay}], else: []) ++
        Enum.map(Map.get(spec, :writable_paths, []), &{&1, :rw}) ++
        Enum.map(Map.get(spec, :bridges, []), &{&1, :ro}) ++
        Enum.map(Map.get(spec, :readonly_paths, []), &{&1, :ro}),
      fn {path, mode} ->
        ["-v", "#{path}:#{mapped(spec, path)}:#{mount_opts(mode, label_disabled?)}"]
      end
    ) ++
      Enum.flat_map(Map.get(spec, :cli_mounts, []), fn {host, dest} ->
        ["-v", "#{host}:#{dest}:ro"]
      end)
  end

  # `:Z` relabels the host path with a private MCS pair: right for a directory
  # only this container touches, wrong for anything shared. With the label
  # disabled nothing needs relabelling.
  defp mount_opts(:ro, _), do: "ro"
  defp mount_opts(:rw, _), do: "rw"
  defp mount_opts(:overlay, _), do: "O"
  defp mount_opts(:rw_private, true), do: "rw"
  defp mount_opts(:rw_private, false), do: "rw,Z"

  defp env_args(spec, home) do
    literal = Map.get(spec, :env, []) ++ if(home, do: [{"HOME", home}], else: [])

    Enum.flat_map(Map.get(spec, :inherit_env, []), &["-e", &1]) ++
      Enum.flat_map(literal, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  # -- Sandbox.wrap/2 ----------------------------------------------------------

  @doc """
  Wrap `command` (executable first) in a container.

  Options: `:worktree`, `:image` and `:name` (required; the name must be
  `name_for/1`-shaped), `:home`, `:objects`, `:git_dir` and `:readonly_paths`
  (both must exist: podman would create a missing bind source on the host),
  `:worktree_readonly`, `:writable_paths`, `:bridges` (host unix sockets),
  `:cli_mounts` (`[{host path, container path}]`: a provider CLI or `arb` bound
  read-only under `/opt/arbiter/cli`, which the image has on its `PATH`),
  `:tmpfs`, `:env`,
  `:inherit_env`, `:network` (`:none` | `:pasta`), `:pod` (join a test-services
  pod, bd-dmcbos; the pod fixes the network, so `:pasta` is refused),
  `:interactive`, `:podman`
  (path; default the host's `podman`) and `:find_executable` (for tests).
  """
  @impl Arbiter.Worker.Sandbox
  @spec wrap([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def wrap(command, opts) when is_list(command) and is_list(opts) do
    with :ok <- check_command(command),
         {:ok, worktree} <- fetch_path(opts, :worktree, :no_worktree),
         {:ok, image} <- fetch_image(opts),
         {:ok, name} <- fetch_name(opts),
         {:ok, podman} <- find_podman(opts),
         {:ok, network} <- fetch_network(opts),
         {:ok, pod} <- fetch_pod(opts, network),
         :ok <- check_env(opts),
         {:ok, mounts} <- check_mounts(opts),
         {:ok, bridges} <- check_bridges(opts, network) do
      spec = %{
        podman: podman,
        image: image,
        name: name,
        worktree: worktree,
        home: mounts.home,
        objects: mounts.objects,
        git_dir: mounts.git_dir,
        readonly_paths: mounts.readonly_paths,
        cli_mounts: mounts.cli_mounts,
        worktree_readonly: Keyword.get(opts, :worktree_readonly, false),
        writable_paths: mounts.writable_paths,
        bridges: bridges,
        tmpfs: Keyword.get(opts, :tmpfs, []),
        env: Keyword.get(opts, :env, []),
        inherit_env: Keyword.get(opts, :inherit_env, []),
        network: network,
        pod: pod,
        interactive: Keyword.get(opts, :interactive, false)
      }

      with :ok <- check_paths([worktree | spec.tmpfs]) do
        {:ok, argv(spec, command)}
      end
    end
  end

  defp check_command([]), do: {:error, :empty_command}
  defp check_command(_), do: :ok

  defp fetch_path(opts, key, error) do
    case Keyword.get(opts, key) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, error}
    end
  end

  defp fetch_image(opts) do
    case Keyword.get(opts, :image) do
      image when is_binary(image) and image != "" ->
        if String.starts_with?(image, "-"), do: {:error, {:bad_image, image}}, else: {:ok, image}

      _ ->
        {:error, :no_image}
    end
  end

  defp fetch_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> {:error, :no_container_name}
      name -> with :ok <- check_name(name), do: {:ok, name}
    end
  end

  defp check_name(name) when is_binary(name) do
    if String.starts_with?(name, @name_prefix) and byte_size(name) > byte_size(@name_prefix) and
         Regex.match?(@name_re, name),
       do: :ok,
       else: {:error, {:bad_container_name, name}}
  end

  defp check_name(name), do: {:error, {:bad_container_name, name}}

  defp find_podman(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    case Keyword.get_lazy(opts, :podman, fn -> find.("podman") end) do
      path when is_binary(path) -> {:ok, path}
      _ -> {:error, :podman_not_found}
    end
  end

  defp fetch_network(opts) do
    case Keyword.get(opts, :network, :none) do
      net when net in [:none, :pasta] -> {:ok, net}
      other -> {:error, {:bad_network, other}}
    end
  end

  defp fetch_pod(opts, network) do
    case Keyword.get(opts, :pod) do
      nil -> {:ok, nil}
      _pod when network != :none -> {:error, :pod_requires_network_none}
      pod -> with :ok <- check_name(pod), do: {:ok, pod}
    end
  end

  defp check_env(opts) do
    names =
      Keyword.get(opts, :inherit_env, []) ++ Enum.map(Keyword.get(opts, :env, []), &elem(&1, 0))

    values = Keyword.get(opts, :env, [])

    with nil <- Enum.find(names, &(not (is_binary(&1) and Regex.match?(@env_re, &1)))),
         nil <- Enum.find(values, fn {_k, v} -> not is_binary(v) or String.contains?(v, "\0") end) do
      :ok
    else
      {k, _v} -> {:error, {:bad_env_value, k}}
      name -> {:error, {:bad_env_name, name}}
    end
  end

  defp check_mounts(opts) do
    writable = Keyword.get(opts, :writable_paths, [])
    home = Keyword.get(opts, :home)
    objects = Keyword.get(opts, :objects)
    git_dir = Keyword.get(opts, :git_dir)
    readonly = Keyword.get(opts, :readonly_paths, [])
    cli = Keyword.get(opts, :cli_mounts, [])
    cli_paths = Enum.flat_map(cli, &Tuple.to_list/1)
    paths = writable ++ readonly ++ cli_paths ++ Enum.reject([home, objects, git_dir], &is_nil/1)

    with :ok <- check_paths(paths),
         :ok <- check_exists(git_dir, :git_dir_missing),
         :ok <- check_all_exist(readonly ++ Enum.map(cli, &elem(&1, 0))) do
      {:ok,
       %{
         home: home,
         objects: objects,
         git_dir: git_dir,
         readonly_paths: readonly,
         cli_mounts: cli,
         writable_paths: writable
       }}
    end
  end

  defp check_exists(nil, _error), do: :ok

  defp check_exists(dir, error),
    do: if(File.dir?(dir), do: :ok, else: {:error, {error, dir}})

  defp check_all_exist(paths) do
    case Enum.find(paths, &(not File.exists?(&1))) do
      nil -> :ok
      missing -> {:error, {:readonly_path_missing, missing}}
    end
  end

  # `-v src:dst:opts` is split on `:`; a relative path is a *named volume*.
  defp check_paths(paths) do
    case Enum.find(paths, &(not valid_path?(&1))) do
      nil -> :ok
      bad -> {:error, {:bad_mount_path, bad}}
    end
  end

  defp valid_path?(path) when is_binary(path),
    do: String.starts_with?(path, "/") and not String.contains?(path, [":", "\0", ","])

  defp valid_path?(_), do: false

  defp check_bridges(opts, network) do
    bridges = Keyword.get(opts, :bridges, [])

    cond do
      bridges != [] and network != :none ->
        {:error, :bridges_require_network_none}

      missing = Enum.find(bridges, &(not valid_path?(&1) or not File.exists?(&1))) ->
        {:error, {:egress_socket_missing, missing}}

      true ->
        {:ok, bridges}
    end
  end

  # -- teardown -----------------------------------------------------------------

  @doc """
  Remove the container `name_or_run` names (a name, or a map with `:name`).
  Always `:ok`: the callback has nothing to return a failure to; `stop/2` is
  the form that reports one. An unrecognised ref is a no-op.
  """
  @impl Arbiter.Worker.Sandbox
  @spec teardown(term()) :: :ok
  def teardown(%{name: name}), do: teardown(name)

  def teardown(name) when is_binary(name) do
    case stop(name, []) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("container teardown of #{name} failed: #{inspect(reason)}")
    end

    :ok
  end

  def teardown(_), do: :ok

  @doc """
  `podman rm --force --ignore --time 0 <name>`: stops and removes the
  container whether it is running, stopped or already gone. Options:
  `:runner` (`(cmd, args, opts -> {output, status})`) and `:podman`.
  """
  @spec stop(String.t(), keyword()) :: :ok | {:error, term()}
  def stop(name, opts \\ []) do
    with :ok <- check_name(name) do
      # No `find_podman/1` refusal here: a teardown that cannot find podman
      # still tries the bare name, and reports the failure.
      podman = Keyword.get(opts, :podman) || System.find_executable("podman") || "podman"
      args = ["rm", "--force", "--ignore", "--time", "0", name]

      case exec(opts, podman, args, timeout: @stop_timeout_ms) do
        {_out, 0} -> :ok
        {out, status} -> {:error, {:podman_rm_failed, status, String.trim(out)}}
      end
    end
  end

  # -- a podman-backed spawn ------------------------------------------------------

  @doc """
  Run `command` in a container to completion and return `{:ok, {output,
  exit_status}}`, `{:error, :timeout}`, `{:error, {:crashed, message}}` or a
  `wrap/2` refusal. The container is removed by name afterwards in every case
  (see "Teardown by name"); a refused `wrap/2` started nothing, so removes
  nothing.

  Options are `wrap/2`'s plus `:timeout` (ms), `:runner`, and `:secret_env`
  (`[{name, value}]`): exported to the `podman` client only and passed in with
  `-e NAME`, so the value never reaches argv.
  """
  @spec run([String.t()], keyword()) ::
          {:ok, {String.t(), non_neg_integer()}} | {:error, term()}
  def run(command, opts) when is_list(command) and is_list(opts) do
    secret_env = Keyword.get(opts, :secret_env, [])

    opts =
      Keyword.update(
        opts,
        :inherit_env,
        secret_names(secret_env),
        &(&1 ++ secret_names(secret_env))
      )

    with {:ok, [podman | args]} <- wrap(command, opts) do
      name = Keyword.fetch!(opts, :name)
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

      try do
        exec_with_timeout(opts, podman, args, secret_env, timeout)
      after
        _ = stop(name, Keyword.take(opts, [:runner, :podman]))
      end
    end
  end

  defp secret_names(secret_env), do: Enum.map(secret_env, &elem(&1, 0))

  defp exec_with_timeout(opts, podman, args, secret_env, timeout) do
    task =
      Task.async(fn ->
        try do
          {:ok, exec(opts, podman, args, env: secret_env, stderr_to_stdout: true)}
        rescue
          e -> {:crashed, Exception.message(e)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:crashed, message}} -> {:error, {:crashed, message}}
      {:exit, reason} -> {:error, {:crashed, inspect(reason)}}
      nil -> {:error, :timeout}
    end
  end

  @doc false
  # The `podman` call every function here makes, with the stand-in runner hook
  # (`:runner`, else `config :arbiter, :worker_container_runner`). Shared with
  # `Arbiter.Worker.TestServices`.
  @spec cmd(keyword(), String.t(), [String.t()], keyword()) :: {String.t(), non_neg_integer()}
  def cmd(opts, cmd, args, run_opts), do: exec(opts, cmd, args, run_opts)

  # sobelow_skip ["CI.System"]
  defp exec(opts, cmd, args, run_opts) do
    case Keyword.get(opts, :runner) || Application.get_env(:arbiter, :worker_container_runner) do
      nil -> release_env_cmd(cmd, args, run_opts)
      runner -> runner.(cmd, args, run_opts)
    end
  end

  # The real `podman` call. `:timeout` bounds the wait (System.cmd has none).
  defp release_env_cmd(cmd, args, run_opts) do
    {timeout, run_opts} = Keyword.pop(run_opts, :timeout, :infinity)
    run_opts = Keyword.put_new(run_opts, :stderr_to_stdout, true)

    task =
      Task.async(fn ->
        try do
          ReleaseEnv.cmd(cmd, args, run_opts)
        rescue
          e in ErlangError -> {"#{cmd}: #{Exception.message(e)}", 127}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {"#{cmd} timed out after #{timeout} ms", 124}
    end
  end

  # -- availability -----------------------------------------------------------------

  @doc "Whether this host can run the container backend (`status/0` is `:ok`)."
  @spec available?() :: boolean()
  def available?, do: status() == :ok

  @doc """
  `:ok` when `PodmanReadiness` finds no failing prerequisite (podman 4+,
  rootless, subuid/subgid, user namespaces, storage, ...), else
  `{:error, {:podman_not_ready, failed_checks}}`. The `:worker_container_available`
  override wins; otherwise the first call probes and the answer is cached until
  `reset/0`. The socket-bridge self-test starts a container, so it is left to
  `network_status/0`.
  """
  @impl Arbiter.Worker.Sandbox
  @spec status() :: :ok | {:error, term()}
  def status do
    cached(:status, :worker_container_available, fn ->
      readiness_result(PodmanReadiness.diagnose(probes: []))
    end)
  end

  @doc """
  `:ok` when a `--network=none` container can reach a host unix socket with
  `label=disable` (the bridge self-test): the one capability bridge containers
  depend on. Same override/caching rules as `status/0`
  (`:worker_container_network_available`).
  """
  @impl Arbiter.Worker.Sandbox
  @spec network_status() :: :ok | {:error, term()}
  def network_status do
    cached(:network_status, :worker_container_network_available, fn ->
      bridge_result(PodmanReadiness.diagnose(probes: [:bridge]))
    end)
  end

  defp bridge_result(%{installed: false} = report), do: readiness_result(report)

  defp bridge_result(%{checks: checks}) do
    case Enum.find(checks, &(&1.id == "socket_bridge")) do
      %{status: "fail", detail: detail} -> {:error, {:socket_bridge_failed, detail}}
      _ -> :ok
    end
  end

  @doc "Forget the cached probe results."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase({__MODULE__, :status})
    _ = :persistent_term.erase({__MODULE__, :network_status})
    :ok
  end

  defp readiness_result(%{ready: true}), do: :ok

  defp readiness_result(%{checks: checks}) do
    {:error,
     {:podman_not_ready,
      for(%{status: "fail"} = c <- checks, do: %{id: c.id, detail: c.detail, hint: c.hint})}}
  end

  defp cached(key, env_key, probe) do
    case Application.get_env(:arbiter, env_key) do
      true ->
        :ok

      false ->
        {:error, :disabled_by_config}

      _ ->
        case :persistent_term.get({__MODULE__, key}, :unprobed) do
          :unprobed ->
            result = probe.()
            :persistent_term.put({__MODULE__, key}, result)
            result

          cached ->
            cached
        end
    end
  end
end
