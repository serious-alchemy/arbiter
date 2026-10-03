defmodule Arbiter.Worker.ContainerSpawn do
  @moduledoc """
  Claude under the podman sandbox backend (bd-d2o3xb, P7 of
  `docs/design/podman-worker-containers.md`): the wrap point between a
  dispatch's `ClaudeSession` spawn and `Arbiter.Worker.Container`.

  `sandbox.backend: podman` (`Arbiter.Agents.SecurityPolicy`) makes a Claude
  worker's `claude --print` run inside a rootless container. The bwrap jail is
  untouched: `ClaudeSession` only calls in here for a spawn that carries a
  podman policy.

  ## Two steps

    * `prepare/1` runs once per worker, on the host, from
      `ClaudeSession.start/1`: it checks the host can run the backend, finds the
      private clone's mount set (`Arbiter.Worker.PrivateClone.mounts/1`), the
      image (`Arbiter.Worker.Image.ensure/3`), starts the run's egress proxy and
      Arbiter bridge (`Arbiter.Worker.Egress.JailRun`, the same one agy's jail
      uses), creates the per-run home and config dir, and returns a **request**
      map that rides in the spawn's `port_args` under `:sandbox`. Any failure is
      an `{:error, reason}`: a podman spawn never degrades to an unsandboxed one.
    * `wrap_port/1` runs at every port open (the first spawn, a commit-gate
      nudge, an auto-resume: they all stash the same `port_args`), turns the
      inner `sh -c 'exec claude --print …'` argv into a `podman run` argv, and
      moves the secrets out of argv.

  ## What the container gets

  Only what is named here is visible; the host's `~/.ssh`, keyring, install DB
  and every sibling worktree are not mounted, so there is nothing to mask.

    * the private clone at its own path, its `.git` and the read-only guards
      (`PrivateClone.mounts/1`), the main repo's `objects/` as an overlay;
    * a **per-run** `HOME` and `CLAUDE_CONFIG_DIR` under the run's temp dir
      (removed with the worker), the config dir seeded with the install's
      generated `settings.json` and `CLAUDE.md` and **never** with a credential
      file, nor with another run's session history;
    * the host's `claude` and `arb` binaries, read-only, at `/opt/arbiter/cli`
      (on the image's `PATH`), and an oversized prompt's temp file, read-only;
    * the run's proxy socket and Arbiter bridge socket, read-only, with a
      `socat` per socket inside the container (`Arbiter.Worker.Jail`'s own
      script) listening on loopback: `HTTPS_PROXY` names the proxy, and
      `127.0.0.1:<arbiter port>` is Arbiter, so the `.mcp.json` URL and `arb`
      work unchanged. The container is `--network=none`; the sockets are its
      only exit, and the proxy runs in learn mode (`Egress`).

  ## Environment

  Nothing is inherited. The container's environment is the spawn's explicit
  pairs (`ClaudeSession`'s `env_pairs/4` minus its unsets: the worker token,
  `ARB_TOKEN`, `ARB_WORKER_BEAD_ID`, the workspace's `worker_env`, `TMPDIR`) plus
  the proxy variables, `ARB_HOST` and `GIT_SSH_COMMAND`. Every value reaches
  the container as `-e NAME` with the value in the `podman` client's own
  environment, so `ps` never shows a token; the few names that would change how
  the client itself runs (`PATH`, `HOME`, `XDG_*`, …) are passed as literals.

  ## Teardown

  The container is named per worker (`arb-<task>-<hash>`), run with `--rm` and
  `--init`. `teardown/1` removes it by that name when the worker kills its
  sessions, because killing the `podman` client is not a reliable stop
  (`Container`, "Teardown by name").

  ## Not covered

  Reviewer, conflict-resolution and fix-pass spawns call `Claude.default_argv/2`
  without `sandbox_wrap: true` and are therefore refused under `podman`, as they
  were before this existed. So is a spawn whose cwd is not a private clone (a
  review checkout, a task-type dispatch with no worktree). The container's
  memory is not bounded by `MemoryScope`: it is not in the server's cgroup, but
  nothing caps it either.
  """

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Mergers
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Sandbox

  require Logger

  @cli_dir "/opt/arbiter/cli"

  # The model API and the hosts the CLI is known to talk to on its own. The
  # proxy runs in learn mode: these are the baseline an enforcing proxy would
  # start from, and anything else the run reaches is logged to `egress_events`.
  @egress_infra ["api.anthropic.com:443"]

  # Names whose value changes how the `podman` client itself runs. They are
  # passed as `-e NAME=value`, never through the client's environment.
  @client_names ~w(PATH HOME USER LOGNAME SHELL LD_LIBRARY_PATH LD_PRELOAD
                   HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
                   http_proxy https_proxy all_proxy no_proxy)
  @client_prefixes ["XDG_", "CONTAINERS_", "DOCKER_", "PODMAN_", "DBUS_"]

  @type request :: %{
          required(:name) => String.t(),
          required(:image) => String.t(),
          required(:podman) => String.t() | nil,
          required(:mounts) => keyword(),
          required(:home) => String.t(),
          required(:config_dir) => String.t(),
          required(:writable_paths) => [String.t()],
          required(:cli_mounts) => [{String.t(), String.t()}],
          required(:prompt_paths) => [String.t()],
          required(:network) => keyword(),
          required(:env) => [{String.t(), String.t()}]
        }

  @doc "The path of the `claude` binary inside the container."
  @spec claude_path() :: String.t()
  def claude_path, do: @cli_dir <> "/claude"

  @doc "Whether `policy` asks for the podman backend."
  @spec podman?(term()) :: boolean()
  def podman?(%SecurityPolicy{} = policy), do: SecurityPolicy.sandbox_backend(policy) == :podman
  def podman?(_), do: false

  # -- prepare ------------------------------------------------------------------

  @doc """
  The host-side half. Options:

    * `:policy` (required), `:worktree_path` (required, a private clone),
      `:owner` (the worker pid the egress run lives and dies with), `:task_id`,
      `:arb_token`, `:tmp_dir` (the run's temp dir; required), `:workspace`,
      `:repo`, `:argv` (the inner argv, for an oversized prompt's temp file);
    * `:image` (a ready tag; else `config :arbiter, :worker_container_image`,
      else the repo's default-branch image from `Image.ensure/3`);
    * `:podman`, `:claude_path` and `:arb_path` (host binaries; default found with
      `:find_executable`, `System.find_executable/1`), `:egress` (`(opts -> {:ok, network, run_id} | {:error, reason})`,
      default `JailRun.start/1`).
  """
  @spec prepare(keyword()) :: {:ok, request()} | {:error, term()}
  def prepare(opts) when is_list(opts) do
    policy = Keyword.fetch!(opts, :policy)

    with :ok <- container_backend(policy),
         :ok <- host_ready(),
         {:ok, worktree} <- fetch_worktree(opts),
         {:ok, mounts} <- clone_mounts(worktree),
         {:ok, tmp_dir} <- fetch_tmp_dir(opts),
         {:ok, image} <- fetch_image(opts, worktree),
         {:ok, cli_mounts} <- cli_mounts(opts),
         {:ok, network, spec} <- start_egress(opts, policy, worktree),
         {:ok, home, config_dir} <- run_dirs(tmp_dir, Keyword.get(opts, :workspace)) do
      {:ok,
       %{
         name: container_name(opts),
         image: image,
         podman: Keyword.get(opts, :podman),
         mounts: mounts,
         home: home,
         config_dir: config_dir,
         writable_paths: Enum.uniq([tmp_dir | Map.get(policy.sandbox, :writable_paths, [])]),
         cli_mounts: cli_mounts,
         prompt_paths: prompt_paths(Keyword.get(opts, :argv)),
         network: network,
         env: container_env(spec)
       }}
    end
  end

  defp container_backend(policy) do
    case Sandbox.module(policy, :claude) do
      {:ok, Container} -> :ok
      {:ok, other} -> {:error, {:not_a_container_backend, other}}
      {:error, _} = refusal -> refusal
    end
  end

  defp host_ready do
    with :ok <- wrap_status(Container.status(), :podman_unavailable),
         do: wrap_status(Container.network_status(), :podman_network_unavailable)
  end

  defp wrap_status(:ok, _tag), do: :ok
  defp wrap_status({:error, reason}, tag), do: {:error, {tag, reason}}

  defp fetch_worktree(opts) do
    case Keyword.get(opts, :worktree_path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, :no_worktree}
    end
  end

  # A container is only ever handed the layout `PrivateClone.create/3` built; a
  # linked worktree (layout A) or a shared checkout is refused, never mounted.
  defp clone_mounts(worktree) do
    case PrivateClone.mounts(worktree) do
      {:ok, mounts} -> {:ok, mounts}
      {:error, reason} -> {:error, {:not_a_private_clone, worktree, reason}}
    end
  end

  defp fetch_tmp_dir(opts) do
    case Keyword.get(opts, :tmp_dir) do
      dir when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> {:error, :no_run_tmp_dir}
    end
  end

  defp fetch_image(opts, worktree) do
    case Keyword.get(opts, :image) || Application.get_env(:arbiter, :worker_container_image) do
      tag when is_binary(tag) and tag != "" -> {:ok, tag}
      _ -> ensure_image(opts, worktree)
    end
  end

  defp ensure_image(opts, worktree) do
    repo_path = PrivateClone.main_repo(worktree)
    base = Mergers.base_branch(Keyword.get(opts, :workspace), Keyword.get(opts, :repo)) || "main"

    with true <- is_binary(repo_path) or {:error, {:not_a_private_clone, worktree}},
         {:ok, %{tag: tag}} <- Image.ensure(repo_path, base) do
      {:ok, tag}
    else
      {:error, reason} -> {:error, {:image_unavailable, reason}}
    end
  end

  # The provider CLI and `arb` are mounted from the host, so the image carries
  # no CLI that can drift from the one Arbiter probed. `claude` is mandatory;
  # a host with no `arb` on PATH still gets a worker, minus the CLI.
  defp cli_mounts(opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)
    claude = Keyword.get_lazy(opts, :claude_path, fn -> find.("claude") end)
    arb = Keyword.get_lazy(opts, :arb_path, fn -> find.("arb") end)

    case claude do
      path when is_binary(path) ->
        arb_mount =
          case arb do
            path when is_binary(path) ->
              [{resolve_links(path), @cli_dir <> "/arb"}]

            _ ->
              Logger.warning("ContainerSpawn: no `arb` on PATH; the container has no arb CLI")
              []
          end

        {:ok, [{resolve_links(path), claude_path()} | arb_mount]}

      _ ->
        {:error, {:executable_not_found, "claude"}}
    end
  end

  # `~/.local/bin/claude` is a symlink into a versioned directory; binding the
  # link would bind a dangling target.
  defp resolve_links(path, depth \\ 0)
  defp resolve_links(path, depth) when depth > 8, do: path

  defp resolve_links(path, depth) do
    case File.read_link(path) do
      {:ok, target} -> target |> Path.expand(Path.dirname(path)) |> resolve_links(depth + 1)
      {:error, _} -> path
    end
  end

  defp prompt_paths(argv) when is_list(argv) do
    case Arbiter.Agents.Claude.prompt_tmpfile(argv) do
      path when is_binary(path) -> [path]
      _ -> []
    end
  end

  defp prompt_paths(_), do: []

  # The proxy and the Arbiter bridge come from the same `Egress` run agy's jail
  # uses (`JailRun`, learn mode): one per worker, reused by every later spawn.
  # The in-container `socat` is `Jail`'s own listener script.
  defp start_egress(opts, policy, worktree) do
    start = Keyword.get(opts, :egress, &JailRun.start/1)

    start_opts = [
      owner: Keyword.get(opts, :owner),
      task_id: Keyword.get(opts, :task_id),
      arb_token: Keyword.get(opts, :arb_token),
      safe_defaults_exclude: policy.permissions.safe_defaults_exclude,
      worktree: worktree,
      infra: @egress_infra,
      tunnels: SecurityPolicy.egress_tunnels(policy)
    ]

    with {:ok, network, _run_id} <- start.(start_opts),
         {:ok, spec} <- Jail.network_spec(Keyword.put(network, :socat, "socat")) do
      {:ok, network, spec}
    else
      {:error, reason} -> {:error, {:egress_unavailable, reason}}
    end
  end

  defp container_env(spec),
    do: Jail.network_env(spec) ++ Jail.ssh_command(nil, spec) ++ arb_host()

  # `arb` reads `ARB_HOST` (a base URL); the bridge listens on the same loopback
  # port the server does, so the default `http://127.0.0.1:4848` is only right
  # when the server is on 4848.
  defp arb_host do
    case URI.parse(Arbiter.MCP.server_url()) do
      %URI{port: port} when is_integer(port) -> [{"ARB_HOST", "http://127.0.0.1:#{port}"}]
      _ -> []
    end
  end

  # A per-run HOME and CLAUDE_CONFIG_DIR. The config dir is seeded with the
  # install's generated settings and worker memory, and nothing else: no
  # `.credentials.json`, none of the install-wide dir's session history.
  defp run_dirs(tmp_dir, workspace) do
    home = Path.join(tmp_dir, "home")
    config_dir = Path.join(tmp_dir, "claude-config")

    with :ok <- File.mkdir_p(home),
         :ok <- File.mkdir_p(config_dir) do
      seed_config(config_dir, workspace)
      {:ok, home, config_dir}
    else
      {:error, reason} -> {:error, {:run_dirs_failed, reason}}
    end
  end

  defp seed_config(config_dir, workspace) do
    with {:ok, source} <- ConfigDir.ensure(workspace) do
      for file <- ["settings.json", "CLAUDE.md"], File.regular?(Path.join(source, file)) do
        File.cp(Path.join(source, file), Path.join(config_dir, file))
      end
    end

    :ok
  end

  defp container_name(opts) do
    slug =
      opts
      |> Keyword.get(:task_id, "run")
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
      |> String.slice(0, 30)

    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({Keyword.get(opts, :owner), make_ref()}))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    Container.name_for("#{slug}-#{hash}")
  end

  # -- the spawn env --------------------------------------------------------------

  @doc """
  `env` (a spawn's `port_args.env`) with `CLAUDE_CONFIG_DIR` pointed at the
  run's own dir, so the host side (session archive, usage reconcile) and the
  container agree on where the transcript lives.
  """
  @spec apply_env([{String.t(), String.t() | false}], request()) :: [
          {String.t(), String.t() | false}
        ]
  def apply_env(env, %{config_dir: config_dir}),
    do:
      Enum.reject(env, &(elem(&1, 0) == "CLAUDE_CONFIG_DIR")) ++
        [{"CLAUDE_CONFIG_DIR", config_dir}]

  # -- wrap ----------------------------------------------------------------------

  @doc """
  The port-open half: `port_args` with `:sandbox` becomes the `podman run`
  invocation, else it is returned as it is.

  The result's `:env` is only the values `-e NAME` takes from the client's
  environment: the unsets the spawn env carries (`SpawnEnv`) are for a child
  that inherits, and the client must keep `XDG_RUNTIME_DIR` to find its rootless
  runtime.
  """
  @spec wrap_port(map()) :: {:ok, map()} | {:error, term()}
  def wrap_port(%{sandbox: %{} = request, argv: [_ | _] = argv} = port_args) do
    with {:ok, spec} <- Jail.network_spec(Keyword.put(request.network, :socat, "socat")),
         {:ok, [podman | args]} <-
           Container.wrap(Jail.network_command(spec, argv), opts(request, port_args)) do
      {:ok,
       %{port_args | exec: podman, argv: [podman | args], env: inherit_pairs(port_args, request)}}
    end
  end

  def wrap_port(%{sandbox: _}), do: {:error, :empty_command}
  def wrap_port(port_args), do: {:ok, port_args}

  defp opts(request, port_args) do
    {inherit, literal} = split_env(env_pairs(port_args, request))

    base = [
      worktree: request.mounts[:worktree],
      git_dir: request.mounts[:git_dir],
      objects: request.mounts[:objects],
      readonly_paths: request.mounts[:readonly_paths] ++ request.prompt_paths,
      image: request.image,
      name: request.name,
      home: request.home,
      writable_paths: request.writable_paths,
      bridges: [
        request.network[:proxy_socket] | Enum.map(request.network[:bridges], &elem(&1, 1))
      ],
      cli_mounts: request.cli_mounts,
      env: literal,
      inherit_env: Enum.map(inherit, &elem(&1, 0))
    ]

    if request.podman, do: [{:podman, request.podman} | base], else: base
  end

  # The explicit pairs of the spawn plus the container's own.
  defp env_pairs(port_args, request) do
    set = for {name, value} <- Map.get(port_args, :env, []), is_binary(value), do: {name, value}
    Map.to_list(Map.new(set ++ request.env))
  end

  defp inherit_pairs(port_args, request),
    do: port_args |> env_pairs(request) |> split_env() |> elem(0)

  defp split_env(pairs), do: Enum.split_with(pairs, fn {name, _} -> not client_name?(name) end)

  defp client_name?(name),
    do: name in @client_names or Enum.any?(@client_prefixes, &String.starts_with?(name, &1))

  # -- teardown --------------------------------------------------------------------

  @doc "Remove the container of `port_args` (a spawn's args, or `nil`) by name."
  @spec teardown(map() | nil) :: :ok
  def teardown(%{sandbox: %{name: name}}) when is_binary(name), do: Container.teardown(name)
  def teardown(_), do: :ok
end
