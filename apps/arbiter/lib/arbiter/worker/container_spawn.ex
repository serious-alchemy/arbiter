defmodule Arbiter.Worker.ContainerSpawn do
  @moduledoc """
  Claude and Codex under the podman sandbox backend (bd-d2o3xb, P7, and
  bd-50d5j6, P8 of `docs/design/podman-worker-containers.md`): the wrap point
  between a dispatch's `ClaudeSession` spawn and `Arbiter.Worker.Container`.

  `sandbox.backend: podman` (`Arbiter.Agents.SecurityPolicy`) makes a worker's
  `claude --print` or `codex exec` run inside a rootless container (`:provider`,
  default `"claude"`; see "Codex" below). The bwrap jail is
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

  ## Codex (P8, bd-50d5j6)

  `provider: "codex"` differs from Claude in four places, the rest is shared:

    * **`CODEX_HOME`** is per run, under the run's temp dir
      (`ConfigDir.seed_run_home/2`: generated `config.toml`, `AGENTS.md`, the
      execpolicy deny rules, and a *copy* of the operator's `auth.json`). The
      operator's home, and the real `auth.json`, are never mounted: the host
      side copies the file in before the container exists.
    * **Refresh-token rotation.** The CLI refreshing its ChatGPT token rotates
      the refresh token in the copy only, which would leave the real login
      holding a retired one. `Arbiter.Agents.Codex.AuthSync` carries it back
      (newest `last_refresh` wins, atomic, never an older token over a newer one)
      at every port re-open, at `teardown/1`, and when the owning worker dies by
      any means (`AuthSync.Reaper`, flushed by `RunTmp.Reaper` before it removes
      the directory). A re-opened run also takes a newer login a sibling rotated.
    * **The CLI** is the vendored static binary, not the `codex` node launcher
      the host has on `PATH` (a container has no node): found beside the launcher
      in the npm package, mounted with its `rg` and `bwrap` so the CLI's own
      helpers resolve on the image's `PATH`.
    * **Egress infra** is the OpenAI hosts (`chatgpt.com`, `api.openai.com`,
      `auth.openai.com`) rather than Anthropic's.

  MCP needs nothing new: the adapter passes it as `-c mcp_servers.…` overrides
  (bd-avq0wb) naming `Arbiter.MCP.server_url/0` and the bearer in
  `ARBITER_MCP_TOKEN`, which reach the container as `-e NAME` and the Arbiter
  bridge on the same loopback port.

  ## Environment

  Nothing is inherited. The container's environment is the spawn's explicit
  pairs (`ClaudeSession`'s `env_pairs/4` minus its unsets: the worker token,
  `ARB_TOKEN`, `ARB_WORKER_BEAD_ID`, the workspace's `worker_env`, `TMPDIR`) plus
  the proxy variables, `ARB_HOST` and `GIT_SSH_COMMAND`. Every value reaches
  the container as `-e NAME` with the value in the `podman` client's own
  environment, so `ps` never shows a token; the few names that would change how
  the client itself runs (`PATH`, `HOME`, `XDG_*`, …) are passed as literals.

  ## Test services (P10, bd-dmcbos)

  A repo with a service definition (`Arbiter.Worker.TestServices`: vstim gets
  Postgres 16, tonic Postgres 15 plus an S3 store) gets a **pod** instead of a
  bare container. `prepare/1` starts it last, with the services ready, and the
  request carries `:pod` and the worker's `DATABASE_URL` and friends. The worker
  container joins the pod (`--pod`, no `--network`/`--userns` of its own: the pod
  is `--network none --userns keep-id`), so the services are on its `127.0.0.1`
  and nothing of the host's loopback is. Services are optional and per repo; a
  repo with none runs exactly as before.

  ## Teardown

  The container is named per worker (`arb-<task>-<hash>`), run with `--rm` and
  `--init`. `teardown/1` removes it by that name when the worker kills its
  sessions, because killing the `podman` client is not a reliable stop
  (`Container`, "Teardown by name"), and removes the pod with it. `--rm` does
  not remove a pod, so `TestServices.Reaper` also removes it when the owning
  worker process dies by any means.

  ## Which spawns are covered (bd-7ays3v)

  The task worker, a ReviewGate **reviewer** (Claude, in its round's read-only
  private clone, `PrivateClone.create_review/3`) and the merge queue's CI
  **fix pass** and **conflict pass** (Claude, in the pass's private clone). Each
  passes `sandbox_wrap: true` to `Claude.default_argv/2` and hands
  `session_opts/3` to `ClaudeSession`, which is what wraps it.

  ## Not covered

  A ReviewGate fix round's implementer and a `review: true` dispatch still call
  `Claude.default_argv/2` without `sandbox_wrap: true` and are refused under
  `podman`, as they were before this existed. So is a spawn whose cwd is not a
  private clone (a reviewer with no round checkout, which falls back to
  `sandbox.review_backend`, or a task-type dispatch with no worktree), and any
  provider but Claude and Codex: a reviewer or pass routed to one of those runs
  under `sandbox.review_backend` or is refused. The container's memory is not
  bounded by `MemoryScope`: it is not in the server's cgroup, but nothing caps
  it either.
  """

  alias Arbiter.Agents.Claude.ConfigDir
  alias Arbiter.Agents.Codex.AuthSync
  alias Arbiter.Agents.Codex.ConfigDir, as: CodexConfigDir
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails.Projection
  alias Arbiter.Mergers
  alias Arbiter.Nodes.Checkout, as: NodeCheckout
  alias Arbiter.Nodes.Files
  alias Arbiter.Worker.Container
  alias Arbiter.Worker.DepsCache
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.GitCredential
  alias Arbiter.Worker.Image
  alias Arbiter.Worker.Image.Publisher
  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.Sandbox
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.SessionHistory
  alias Arbiter.Worker.TestServices
  alias Arbiter.Worker.Withholding
  alias Arbiter.Worker.Worktree

  require Logger

  @cli_dir "/opt/arbiter/cli"

  # The model API and the hosts the CLI is known to talk to on its own. The
  # proxy runs in learn mode: these are the baseline an enforcing proxy would
  # start from, and anything else the run reaches is logged to `egress_events`.
  @egress_infra %{
    "claude" => ["api.anthropic.com:443"],
    "codex" => ["chatgpt.com:443", "api.openai.com:443", "auth.openai.com:443"]
  }

  # Names whose value changes how the `podman` client itself runs. They are
  # passed as `-e NAME=value`, never through the client's environment.
  @client_names ~w(PATH HOME USER LOGNAME SHELL LD_LIBRARY_PATH LD_PRELOAD
                   HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
                   http_proxy https_proxy all_proxy no_proxy)
  @client_prefixes ["XDG_", "CONTAINERS_", "DOCKER_", "PODMAN_", "DBUS_"]

  @type request :: %{
          required(:name) => String.t(),
          required(:provider) => String.t(),
          required(:image) => String.t(),
          required(:podman) => String.t() | nil,
          required(:mounts) => keyword(),
          required(:home) => String.t(),
          required(:config_dir) => String.t(),
          required(:writable_paths) => [String.t()],
          required(:cli_mounts) => [{String.t(), String.t()}],
          required(:prompt_paths) => [String.t()],
          required(:network) => keyword(),
          required(:env) => [{String.t(), String.t()}],
          optional(:codex_auth) => {Path.t(), Path.t()} | nil,
          optional(:pod) => String.t() | nil,
          optional(:deps_cache) => map() | nil,
          optional(:git_secrets) => [map()]
        }

  @doc "The path of the `claude` binary inside the container."
  @spec claude_path() :: String.t()
  def claude_path, do: @cli_dir <> "/claude"

  @doc "The path of `provider`'s CLI inside the container."
  @spec provider_path(String.t() | atom()) :: String.t()
  def provider_path(provider), do: @cli_dir <> "/" <> provider_name(provider)

  defp provider_name(provider) when provider in [:codex, "codex"], do: "codex"
  defp provider_name(_provider), do: "claude"

  @doc "Whether `policy` asks for the podman backend."
  @spec podman?(term()) :: boolean()
  def podman?(%SecurityPolicy{} = policy), do: SecurityPolicy.sandbox_backend(policy) == :podman
  def podman?(_), do: false

  @doc """
  The inputs `ClaudeSession.start/1` needs to wrap a spawn under `policy`
  (`:security`, `:workspace`, plus `extra`, e.g. `:repo`): none for any policy
  that is not podman, so a bwrap or unsandboxed spawn is unchanged. Every spawn
  site that can run in a container builds its session opts through here
  (the task worker, ReviewGate's reviewer, the merge queue's fix and conflict
  passes).
  """
  @spec session_opts(term(), term(), keyword()) :: keyword()
  def session_opts(policy, workspace, extra \\ []) do
    if podman?(policy),
      do: [security: policy, workspace: workspace] ++ extra,
      else: []
  end

  @doc """
  The policy a merge-queue pass (CI fix pass, conflict pass) runs in a container
  under, or `nil` when it does not (bd-7ays3v). The pass resolves the workspace's
  posture scoped to `repo` exactly as the task worker does
  (`SecurityPolicy.resolve/3`), so the egress decisions and `egress_events` match
  the implementer's; it runs in the container when that is podman and the
  provider is Claude. For anything else the pass spawns as it always did.
  """
  @spec pass_policy(term(), String.t() | nil, atom() | String.t()) ::
          SecurityPolicy.t() | nil
  def pass_policy(workspace, repo, provider) do
    policy = SecurityPolicy.resolve(workspace, %{}, repo)
    if podman?(policy) and provider in [:claude, "claude"], do: policy
  end

  @doc """
  The adapter opts a pass adds when `policy` (from `pass_policy/3`) is set:
  the policy, and the promise to hand the spawn to `ClaudeSession` with it.
  """
  @spec pass_agent_opts(SecurityPolicy.t() | nil) :: keyword()
  def pass_agent_opts(nil), do: []
  def pass_agent_opts(%SecurityPolicy{} = policy), do: [security: policy, sandbox_wrap: true]

  # -- prepare ------------------------------------------------------------------

  @doc """
  The host-side half. Options:

    * `:policy` (required), `:worktree_path` (required, a private clone),
      `:owner` (the worker pid the egress run lives and dies with), `:task_id`,
      `:arb_token`, `:tmp_dir` (the run's temp dir; required), `:workspace`,
      `:repo`, `:argv` (the inner argv, for an oversized prompt's temp file),
      `:provider` (`"claude"` default, or `"codex"`);
    * `:image` (a ready tag; else `config :arbiter, :worker_container_image`,
      else the repo's default-branch image from `Image.ensure/3`);
    * `:podman`, `:claude_path`, `:codex_path` and `:arb_path` (host binaries;
      default found with `:find_executable`, `System.find_executable/1`),
      `:codex_source_home` (the operator's codex home the login is copied from;
      default `Codex.ConfigDir.source_home/0`), `:egress`
      (`(opts -> {:ok, network, run_id} | {:error, reason})`, default
      `JailRun.start/1`).
  """
  @spec prepare(keyword()) :: {:ok, request()} | {:error, term()}
  def prepare(opts) when is_list(opts) do
    policy = Keyword.fetch!(opts, :policy)
    provider = provider_name(Keyword.get(opts, :provider))

    with :ok <- container_backend(policy, provider),
         :ok <- host_ready(),
         :ok <- no_ssh_agent(Keyword.get(opts, :projection)),
         {:ok, worktree} <- fetch_worktree(opts),
         {:ok, mounts} <- clone_mounts(worktree),
         {:ok, tmp_dir} <- fetch_tmp_dir(opts),
         {:ok, image} <- fetch_image(opts, worktree),
         {:ok, cli_mounts} <- cli_mounts(provider, opts),
         {:ok, home, config_dir, codex_auth} <- run_dirs(provider, tmp_dir, policy, opts),
         # Before the egress run starts: a cold seed takes minutes.
         deps_cache = seed_deps(opts, worktree, image, home),
         {:ok, network, spec} <- start_egress(provider, opts, policy, worktree),
         name = container_name(opts),
         {:ok, services} <- start_services(opts, name),
         {:ok, git_secrets} <- create_git_secrets(opts, name, tmp_dir, services) do
      track_codex_auth(opts, codex_auth)

      {:ok,
       %{
         name: name,
         provider: provider,
         image: image,
         podman: Keyword.get(opts, :podman),
         mounts: mounts,
         home: home,
         config_dir: config_dir,
         writable_paths: Enum.uniq([tmp_dir | Map.get(policy.sandbox, :writable_paths, [])]),
         cli_mounts: cli_mounts,
         prompt_paths: prompt_paths(Keyword.get(opts, :argv)),
         network: network,
         env:
           container_env(spec, Keyword.get(opts, :git_material)) ++
             GitCredential.container_env(Keyword.get(opts, :git_material)) ++
             if(services, do: services.env, else: []),
         git_secrets: git_secrets,
         pod: services && services.pod,
         deps_cache: deps_cache,
         codex_auth: codex_auth
       }}
    end
  end

  # bd-9cygoo (G16): the scoped git credential travels as `podman run --secret`s,
  # created here on the host (value through a 0600 file, never argv) and removed
  # at `teardown/1`, when the owning worker exits, and by `Container.reap_git_secrets/1`
  # at boot. The request keeps the names and targets only, never a value.
  defp create_git_secrets(opts, name, tmp_dir, services) do
    secrets = GitCredential.podman_secrets(Keyword.get(opts, :git_material), name)

    if secrets == [] do
      {:ok, []}
    else
      container_opts = Keyword.take(opts, [:podman, :runner])
      uid = host_uid()

      result =
        Enum.reduce_while(secrets, :ok, fn secret, :ok ->
          case Container.create_secret(secret, [dir: tmp_dir] ++ container_opts) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:git_credential_secret_failed, reason}}}
          end
        end)

      names = Enum.map(secrets, & &1.name)

      case result do
        :ok ->
          track_git_secrets(Keyword.get(opts, :owner), names, container_opts)

          {:ok,
           Enum.map(secrets, fn secret ->
             secret |> Map.delete(:value) |> Map.put(:uid, uid)
           end)}

        {:error, _} = error ->
          Enum.each(names, &Container.remove_secret(&1, container_opts))
          if services, do: TestServices.teardown(services.pod)
          error
      end
    end
  end

  # The uid the container maps to itself (`--userns=keep-id`): this process's.
  defp host_uid do
    case File.stat("/proc/self") do
      {:ok, %File.Stat{uid: uid}} -> uid
      _ -> 0
    end
  end

  # A worker killed without its `teardown/1` must not leave a deploy key in
  # podman's secret store.
  defp track_git_secrets(owner, names, container_opts) when is_pid(owner) do
    {:ok, _pid} =
      Task.start(fn ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, _, _} ->
            Enum.each(names, &Container.remove_secret(&1, container_opts))
        end
      end)

    :ok
  end

  defp track_git_secrets(_owner, _names, _container_opts), do: :ok

  defp container_backend(policy, provider) do
    case Sandbox.module(policy, provider) do
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

  # The clone's `deps/` and `_build/` come from the cache seeded inside this
  # image (`DepsCache`, bd-1wm14e), not from the host's own `_build`, which is
  # ABI-bound to the host's libc and OTP. Best-effort: a cache that cannot be
  # seeded (offline, no lockfile, a non-Mix repo) leaves the worker to fetch and
  # compile for itself, as it would without the cache. `nil` means no cache.
  defp seed_deps(opts, worktree, image, home) do
    seed =
      case Keyword.get(opts, :deps_cache, Application.get_env(:arbiter, :worker_deps_cache, true)) do
        enabled when enabled in [false, nil] ->
          nil

        true ->
          fn worktree, image ->
            DepsCache.seed_worktree(
              worktree,
              image,
              [home: home] ++ Keyword.take(opts, [:workspace, :repo, :podman])
            )
          end

        fun when is_function(fun, 2) ->
          fun
      end

    with seed when is_function(seed) <- seed,
         {:ok, summary} <- seed.(worktree, image) do
      summary
    else
      nil ->
        nil

      {:error, :no_lockfile} ->
        nil

      {:error, reason} ->
        Logger.warning("ContainerSpawn: no deps cache for #{worktree}: #{inspect(reason)}")
        nil
    end
  end

  # The test services (`Arbiter.Worker.TestServices`, P10) start last: nothing
  # after them can fail, so a refused prepare never leaves a pod behind. A repo
  # with no definition gets none and the container is exactly what it was.
  defp start_services(opts, name) do
    service_opts = Keyword.get(opts, :services_opts, [])

    with {:ok, services} <- services_for(opts),
         {:ok, started} <-
           TestServices.start(
             Keyword.merge(service_opts, name: name, services: services, podman: opts[:podman])
           ) do
      if started, do: track_pod(opts, started.pod, service_opts)
      {:ok, started}
    else
      {:error, reason} -> {:error, {:test_services_unavailable, reason}}
    end
  end

  defp services_for(opts) do
    case Keyword.fetch(opts, :services) do
      {:ok, specs} -> TestServices.resolve(specs)
      :error -> TestServices.for_repo(Keyword.get(opts, :repo))
    end
  end

  # The pod outlives the worker container (`--rm` removes only that), so the
  # owner's death, however it comes, removes it.
  defp track_pod(opts, pod, service_opts) do
    case Keyword.get(opts, :owner) do
      owner when is_pid(owner) -> TestServices.Reaper.track(owner, pod, service_opts)
      _ -> :ok
    end
  end

  # The provider CLI and `arb` are mounted from the host, so the image carries
  # no CLI that can drift from the one Arbiter probed. The provider CLI is
  # mandatory; a host with no `arb` on PATH still gets a worker, minus the CLI.
  @doc false
  def cli_mounts(provider, opts) do
    find = Keyword.get(opts, :find_executable, &System.find_executable/1)

    with {:ok, provider_mounts} <- provider_mounts(provider, opts, find) do
      arb = Keyword.get_lazy(opts, :arb_path, fn -> find.("arb") || installed_arb(opts) end)

      arb_mount =
        case arb do
          path when is_binary(path) ->
            [{resolve_links(path), @cli_dir <> "/arb"}]

          _ ->
            Logger.warning("ContainerSpawn: no `arb` on PATH; the container has no arb CLI")
            []
        end

      {:ok, provider_mounts ++ arb_mount}
    end
  end

  # The coordinator's own PATH need not carry `arb` (a systemd service); fall
  # back to where self-deploy installs it (`:installed_arb_path` overrides, for
  # tests; tests injecting `:find_executable` otherwise get no fallback so the
  # host's home never leaks into a spec).
  defp installed_arb(opts) do
    path =
      case Keyword.fetch(opts, :installed_arb_path) do
        {:ok, p} ->
          p

        :error ->
          if Keyword.has_key?(opts, :find_executable), do: nil, else: default_installed_arb()
      end

    if is_binary(path) and File.regular?(path), do: path
  end

  defp default_installed_arb do
    case System.get_env("ARB_INSTALL_BIN") do
      p when is_binary(p) and p != "" -> Path.expand(p)
      _ -> Path.join(System.user_home!(), ".local/bin/arb")
    end
  end

  defp provider_mounts("claude", opts, find) do
    case Keyword.get_lazy(opts, :claude_path, fn -> find.("claude") end) do
      path when is_binary(path) -> {:ok, [{resolve_links(path), claude_path()}]}
      _ -> {:error, {:executable_not_found, "claude"}}
    end
  end

  defp provider_mounts("codex", opts, find) do
    case Keyword.get_lazy(opts, :codex_path, fn -> codex_on_host(find) end) do
      path when is_binary(path) -> codex_mounts(resolve_links(path))
      _ -> {:error, {:executable_not_found, "codex"}}
    end
  end

  defp codex_on_host(find) do
    case Application.get_env(:arbiter, :worker_container_codex_path) do
      path when is_binary(path) and path != "" -> path
      _ -> find.("codex")
    end
  end

  # The npm `codex` on PATH is a node script: a container has no node. The
  # package vendors a static binary (with `rg`, and `bwrap` for the CLI's own
  # sandbox) beside it; mount that, and the helpers where the image's PATH has
  # them. A binary that already is an executable (a cargo or brew install) is
  # mounted as it is, with whatever vendor siblings it has.
  defp codex_mounts(resolved) do
    case native_codex(resolved) do
      {:ok, native} ->
        vendor = native |> Path.dirname() |> Path.dirname()

        helpers =
          for {rel, name} <- [{"codex-path/rg", "rg"}, {"codex-resources/bwrap", "bwrap"}],
              path = Path.join(vendor, rel),
              File.regular?(path),
              do: {path, @cli_dir <> "/" <> name}

        # The CLI spawns its sibling executables (the code-mode host) by path
        # beside itself; the container finds them on its PATH dir.
        siblings =
          for path <- Path.wildcard(Path.join(Path.dirname(native), "*")),
              path != native,
              File.regular?(path),
              executable?(path),
              do: {path, @cli_dir <> "/" <> Path.basename(path)}

        {:ok, [{native, provider_path("codex")} | helpers ++ siblings]}

      :error ->
        {:error, {:codex_native_binary_not_found, resolved}}
    end
  end

  defp native_codex(path) do
    if elf?(path) do
      {:ok, path}
    else
      package = path |> Path.dirname() |> Path.dirname()
      arch = :erlang.system_info(:system_architecture) |> to_string() |> String.split("-") |> hd()

      candidates =
        (Path.wildcard(
           Path.join(package, "node_modules/@openai/codex-linux-*/vendor/*/bin/codex")
         ) ++
           Path.wildcard(Path.join(package, "vendor/*/bin/codex")))
        |> Enum.filter(&elf?/1)

      case Enum.find(candidates, &String.contains?(&1, "/" <> arch <> "-")) ||
             List.first(candidates) do
        nil -> :error
        native -> {:ok, native}
      end
    end
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  defp elf?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, <<0x7F, "ELF">>} -> true
      _ -> false
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
  defp start_egress(provider, opts, policy, worktree) do
    start = Keyword.get(opts, :egress, &JailRun.start/1)
    projection = projection(opts)

    start_opts = [
      owner: Keyword.get(opts, :owner),
      task_id: Keyword.get(opts, :task_id),
      arb_token: Keyword.get(opts, :arb_token),
      safe_defaults_exclude: policy.permissions.safe_defaults_exclude,
      worktree: worktree,
      infra: Map.fetch!(@egress_infra, provider),
      tunnels: SecurityPolicy.egress_tunnels(policy) ++ projection.tunnels,
      grants: Withholding.grants(Keyword.get(opts, :task_id), projection)
    ]

    with {:ok, network, _run_id} <- start.(start_opts),
         {:ok, spec} <- Jail.network_spec(Keyword.put(network, :socat, "socat")) do
      {:ok, network, spec}
    else
      {:error, reason} -> {:error, {:egress_unavailable, reason}}
    end
  end

  # bd-ld8qde (G14): what the ticket's declared permissions project into this
  # run's proxy (grants) and fixed bridges (tunnels). No projection (a caller
  # that predates it) is an unguarded one.
  defp projection(opts) do
    case Keyword.get(opts, :projection) do
      %Projection{} = projection -> projection
      _ -> Projection.unguarded()
    end
  end

  # `prod_ssh` hands the worker a key through a per-worker ssh-agent socket bound
  # into a jail. A confined container cannot connect() to a host socket (only the
  # egress bridges are made reachable), so under podman the spawn is refused
  # rather than run without the agent it was promised.
  defp no_ssh_agent(%Projection{ssh: ssh}) when not is_nil(ssh),
    do: {:error, {:prod_ssh_unsupported, :podman}}

  defp no_ssh_agent(_), do: :ok

  # A deploy key is named by `GIT_SSH_COMMAND` too, so the proxy `ProxyCommand` is
  # composed onto it (`Jail.ssh_command/2`) and `GitCredential.container_env/1` leaves
  # that variable alone.
  defp container_env(spec, material),
    do: Jail.network_env(spec) ++ Jail.ssh_command(ssh_base(material), spec) ++ arb_host()

  defp ssh_base(%GitCredential.Material{kind: :deploy_key}),
    do: GitCredential.ssh_command(GitCredential.podman_key_path())

  defp ssh_base(_), do: nil

  # `arb` reads `ARB_HOST` (a base URL); the bridge listens on the same loopback
  # port the server does, so the default `http://127.0.0.1:4848` is only right
  # when the server is on 4848.
  defp arb_host do
    case URI.parse(Arbiter.MCP.server_url()) do
      %URI{port: port} when is_integer(port) -> [{"ARB_HOST", "http://127.0.0.1:#{port}"}]
      _ -> []
    end
  end

  # A per-run HOME and config dir (`CLAUDE_CONFIG_DIR`, or `CODEX_HOME` for
  # Codex). Claude's is seeded with the install's generated settings and worker
  # memory, and nothing else: no `.credentials.json`, none of the install-wide
  # dir's session history. Codex's holds a copy of the login
  # (`ConfigDir.seed_run_home/2`).
  defp run_dirs("claude", tmp_dir, _policy, opts) do
    home = Path.join(tmp_dir, "home")
    config_dir = Path.join(tmp_dir, "claude-config")

    with :ok <- File.mkdir_p(home),
         :ok <- File.mkdir_p(config_dir) do
      seed_config(config_dir, Keyword.get(opts, :workspace))
      seed_session(config_dir, opts)
      {:ok, home, config_dir, nil}
    else
      {:error, reason} -> {:error, {:run_dirs_failed, reason}}
    end
  end

  defp run_dirs("codex", tmp_dir, policy, opts) do
    home = Path.join(tmp_dir, "home")
    codex_home = Path.join(tmp_dir, "codex-home")
    seed_opts = [security: policy] ++ source_home_opt(opts)

    with :ok <- File.mkdir_p(home),
         {:ok, %{auth: auth}} <- CodexConfigDir.seed_run_home(codex_home, seed_opts) do
      {:ok, home, codex_home, auth}
    else
      {:error, reason} -> {:error, {:run_dirs_failed, reason}}
    end
  end

  defp source_home_opt(opts) do
    case Keyword.get(opts, :codex_source_home) do
      dir when is_binary(dir) and dir != "" -> [source_home: dir]
      _ -> []
    end
  end

  # The sync outlives the call stack: `AuthSync.Reaper` persists a rotation when
  # the owning worker dies, however it does.
  defp track_codex_auth(opts, {source, run}) do
    case Keyword.get(opts, :owner) do
      owner when is_pid(owner) -> AuthSync.Reaper.track(owner, source, run)
      _ -> :ok
    end
  end

  defp track_codex_auth(_opts, nil), do: :ok

  # bd-atsde3: a `--resume <sid>` argv needs that session's JSONL in THIS run's
  # config dir, which starts empty. Copy in that one session's history; when it
  # is gone the CLI says so and the stop is classified `:session_not_found`.
  defp seed_session(config_dir, opts),
    do: seed_resume(config_dir, Keyword.get(opts, :argv), Keyword.get(opts, :worktree_path))

  # `Worker` splices `--resume <sid>` into the argv when the port opens, after
  # `prepare/1` ran with the pristine argv (bd-9qazat), so `wrap_port/1` seeds
  # again with the final one. Seeding is idempotent.
  defp seed_resume(config_dir, argv, cwd) do
    with sid when is_binary(sid) <- SessionHistory.resume_session_id(argv),
         cwd when is_binary(cwd) <- cwd,
         {:error, reason} <- SessionHistory.seed(config_dir, cwd, sid) do
      Logger.warning("ContainerSpawn: cannot carry session #{sid} over: #{inspect(reason)}")
    end

    :ok
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
  `env` (a spawn's `port_args.env`) with the provider's config dir variable
  (`CLAUDE_CONFIG_DIR`, or `CODEX_HOME` for Codex) pointed at the run's own dir,
  so the host side (session archive, usage reconcile) and the container agree on
  where the transcript lives.
  """
  @spec apply_env([{String.t(), String.t() | false}], request()) :: [
          {String.t(), String.t() | false}
        ]
  def apply_env(env, %{config_dir: config_dir} = request) do
    name = config_env_name(request)
    Enum.reject(env, &(elem(&1, 0) == name)) ++ [{name, config_dir}]
  end

  defp config_env_name(%{provider: "codex"}), do: "CODEX_HOME"
  defp config_env_name(_request), do: "CLAUDE_CONFIG_DIR"

  # -- a run placed on a node (RW9) ----------------------------------------------------

  @doc """
  The primary half of a **remote** spawn (`docs/design/remote-workers.md` §7.1):
  what `prepare/1` does that has to happen on the primary, and nothing that has
  to happen on the node. Options are `prepare/1`'s plus `:node` (the placed
  node's row: `:id`, and `:capacity` for the memory cap).

  It starts the run's egress proxy and bridges (the policy never leaves the
  primary), resolves the image **plan** instead of building it, publishes the
  provider CLI and `arb` on the primary's file shelf (`Arbiter.Nodes.Files`) and
  reads the config files and prompt a node cannot reach. The node builds the
  image, fetches the files, makes the run's directories and starts the
  container itself. The returned request rides in `port_args.remote`; each open
  turns it into a spec with `remote_spec/3`.
  """
  @spec prepare_remote(keyword()) :: {:ok, map()} | {:error, term()}
  def prepare_remote(opts) when is_list(opts) do
    policy = Keyword.fetch!(opts, :policy)
    provider = provider_name(Keyword.get(opts, :provider))
    node = Keyword.fetch!(opts, :node)

    with :ok <- remote_provider(provider),
         :ok <- container_backend(policy, provider),
         {:ok, worktree} <- fetch_worktree(opts),
         {:ok, tmp_dir} <- fetch_tmp_dir(opts),
         {:ok, image} <- remote_image(opts, worktree, node),
         {:ok, cli} <- remote_cli(provider, opts),
         {:ok, services} <- remote_services(opts),
         {:ok, home, config_dir} <- remote_dirs(tmp_dir),
         {:ok, checkout} <- remote_checkout(opts, worktree, config_dir),
         {:ok, worktree_files, worktree_secrets} <- worktree_files(worktree),
         {:ok, network, spec} <- start_egress(provider, opts, policy, worktree) do
      name = container_name(opts)

      {:ok,
       %{
         node_id: node.id,
         name: name,
         provider: provider,
         image: image,
         worktree: worktree,
         checkout: checkout,
         worktree_files: worktree_files,
         worktree_secrets: worktree_secrets,
         home: home,
         config_dir: config_dir,
         config_files: config_files(Keyword.get(opts, :workspace)),
         tmp_dir: tmp_dir,
         cli: cli,
         prompt_paths: prompt_paths(Keyword.get(opts, :argv)),
         network: network,
         env: container_env(spec, nil) ++ services.env,
         services: services.presets,
         limits: remote_limits(node),
         task_id: Keyword.get(opts, :task_id)
       }}
    end
  end

  # RW11 (`docs/design/remote-workers.md` §9): a worktree that is a private clone
  # (the home clone of a remote run) is synced to the node as a shadow clone and
  # back as bundles. The placement veto runs here, so a repo with submodules or LFS
  # is refused as a placement error rather than by the agent mid-seed. A worktree
  # that is not a private clone has nothing to sync and is placed as before.
  defp remote_checkout(opts, worktree, config_dir) do
    case PrivateClone.branch(worktree) do
      branch when is_binary(branch) ->
        base =
          Mergers.base_branch(Keyword.get(opts, :workspace), Keyword.get(opts, :repo)) || "main"

        case NodeCheckout.veto(worktree, branch) do
          :ok ->
            {:ok,
             %{
               home: worktree,
               branch: branch,
               base: base,
               seeded_paths: Worktree.seeded_paths(worktree),
               config_dir: config_dir,
               read_only?: PrivateClone.read_only?(worktree)
             }}

          {:error, reason} ->
            {:error, {:checkout_vetoed, reason}}
        end

      _ ->
        {:ok, nil}
    end
  end

  # Only Claude has a podman path that is placed remotely (bd-aowisc §5).
  defp remote_provider("claude"), do: :ok
  defp remote_provider(provider), do: {:error, {:provider_not_remote, provider}}

  defp remote_image(opts, worktree, node) do
    case explicit_image(opts) do
      tag when is_binary(tag) ->
        registry_image(%{tag: tag, plan: nil}, node, %{}, opts)

      nil ->
        case PrivateClone.main_repo(worktree) do
          repo_path when is_binary(repo_path) -> plan_image(opts, repo_path, node)
          _ -> {:error, {:image_unavailable, {:not_a_private_clone, worktree}}}
        end
    end
  end

  defp explicit_image(opts) do
    case Keyword.get(opts, :image) || Application.get_env(:arbiter, :worker_container_image) do
      tag when is_binary(tag) and tag != "" -> tag
      _ -> nil
    end
  end

  defp plan_image(opts, repo_path, node) do
    base = Mergers.base_branch(Keyword.get(opts, :workspace), Keyword.get(opts, :repo)) || "main"

    case Image.plan(repo_path, base) do
      {:ok, plan} ->
        ctx = %{
          repo_path: repo_path,
          base: base,
          seed_paths: SeedPaths.resolve(Keyword.get(opts, :workspace), Keyword.get(opts, :repo))
        }

        registry_image(%{tag: plan.tag, plan: plan}, node, ctx, opts)

      {:error, reason} ->
        {:error, {:image_unavailable, reason}}
    end
  end

  @doc """
  Publish the run image for a node **before** the run is committed to it
  (`Worker.Dispatch`). `:ok` for a node that builds its own image (nothing to
  publish); for a registry node the same `registry_image/4` the spawn will
  call, so its single-flight cache makes the spawn's own call instant.
  `{:error, {:image_unavailable, reason}}` is what `Publisher.fallback/2` maps
  to local or a hold. Options are `prepare_remote/1`'s `:image`, `:workspace`,
  `:repo` and `:publish`.
  """
  @spec preflight_image(String.t() | nil, map(), keyword()) :: :ok | {:error, term()}
  def preflight_image(repo_path, node, opts) do
    cond do
      not registry_node?(node) ->
        :ok

      is_binary(explicit_image(opts)) ->
        with {:ok, _} <- registry_image(%{tag: explicit_image(opts), plan: nil}, node, %{}, opts),
             do: :ok

      is_binary(repo_path) ->
        with {:ok, _} <- plan_image(opts, repo_path, node), do: :ok

      true ->
        {:error, {:image_unavailable, :no_repo}}
    end
  end

  @doc false
  # A2 (`docs/design/remote-workers.md` §11): a node that advertises
  # `caps.image = "registry"` never receives a build plan. The primary publishes
  # the image (`Image.Publisher.ensure_ready/2`: bounded wait, single flight) and
  # the spec carries its digest-pinned `ref`. A publish that times out or fails
  # is `image_unavailable`, the same refusal a node would give; `Publisher.fallback/2`
  # is the placement policy for it. Any other node, and an install with no
  # `nodes.registry`, keep the plan exactly as before.
  def registry_image(image, node, ctx, opts) do
    if registry_node?(node) do
      case publish_image(image, ctx, Keyword.get(opts, :publish, [])) do
        {:ok, %{ref: ref}} -> {:ok, image |> Map.put(:plan, nil) |> Map.put(:ref, ref)}
        :disabled -> {:error, {:image_unavailable, :no_registry}}
        {:error, reason} -> {:error, {:image_unavailable, reason}}
      end
    else
      {:ok, image}
    end
  end

  defp registry_node?(node), do: get_in(Map.get(node, :caps) || %{}, ["image"]) == "registry"

  # `:stub` replaces the publisher in tests.
  defp publish_image(_image, ctx, stub: stub), do: stub.(ctx)
  defp publish_image(%{plan: nil}, _ctx, _opts), do: {:error, :no_plan_to_publish}

  defp publish_image(%{plan: plan}, ctx, opts),
    do: Publisher.ensure_ready(Map.put(ctx, :plan, plan), opts)

  # `[{sha256, name, container path}]`: the node fetches by hash.
  defp remote_cli(provider, opts) do
    with {:ok, mounts} <- cli_mounts(provider, opts) do
      Enum.reduce_while(mounts, {:ok, []}, fn {host, dest}, {:ok, acc} ->
        case Files.publish(host) do
          {:ok, sha} -> {:cont, {:ok, acc ++ [{sha, Path.basename(dest), dest}]}}
          {:error, reason} -> {:halt, {:error, {:cli_unavailable, reason}}}
        end
      end)
    end
  end

  # Presets only cross the wire (`Arbiter.NodeAgent.RunSpec`); a custom service
  # definition cannot be placed remotely.
  defp remote_services(opts) do
    configured = Application.get_env(:arbiter, :worker_test_services, %{})

    terms =
      case Keyword.fetch(opts, :services) do
        {:ok, specs} ->
          specs

        :error ->
          Map.get(Map.merge(TestServices.defaults(), configured), Keyword.get(opts, :repo), [])
      end

    with {:ok, presets} <- presets(terms),
         {:ok, resolved} <- TestServices.resolve(terms) do
      {:ok, %{presets: presets, env: TestServices.worker_env(resolved)}}
    else
      {:error, reason} -> {:error, {:test_services_unavailable, reason}}
    end
  end

  defp presets(terms) do
    Enum.reduce_while(terms, {:ok, []}, fn
      :postgres, {:ok, acc} -> {:cont, {:ok, acc ++ [%{"preset" => "postgres"}]}}
      :s3, {:ok, acc} -> {:cont, {:ok, acc ++ [%{"preset" => "s3"}]}}
      {:postgres, o}, {:ok, acc} when is_list(o) -> {:cont, {:ok, acc ++ [postgres_preset(o)]}}
      {:s3, o}, {:ok, acc} when is_list(o) -> {:cont, {:ok, acc ++ [s3_preset(o)]}}
      other, _ -> {:halt, {:error, {:custom_service_not_remote, inspect(other, limit: 3)}}}
    end)
  end

  defp postgres_preset(opts),
    do:
      Map.merge(
        %{"preset" => "postgres"},
        Map.new(Keyword.take(opts, [:version, :database]), fn {k, v} -> {Atom.to_string(k), v} end)
      )

  defp s3_preset(opts),
    do:
      Map.merge(
        %{"preset" => "s3"},
        Map.new(Keyword.take(opts, [:image]), fn {k, v} -> {Atom.to_string(k), v} end)
      )

  # The container-side paths equal the primary's (path transparency): the clone
  # slug `claude --resume` keys its session store on is the same on both sides.
  # The directories exist here too, so the transcript the node uploads has a
  # place to land.
  defp remote_dirs(tmp_dir) do
    home = Path.join(tmp_dir, "home")
    config_dir = Path.join(tmp_dir, "claude-config")

    with :ok <- File.mkdir_p(home),
         :ok <- File.mkdir_p(config_dir) do
      {:ok, home, config_dir}
    else
      {:error, reason} -> {:error, {:run_dirs_failed, reason}}
    end
  end

  # bd-8y8ztm: the agent config `Worker.Dispatch` injects into the worktree is
  # untracked (git-excluded), so the checkout's git bundle cannot carry it, yet
  # the claude argv names it by its primary path (`--mcp-config <worktree>/.mcp.json`)
  # and the container sees the shadow clone at that same path. These are the
  # files the node writes into the shadow after seeding it: `.mcp.json` and the
  # materialized skills tree.
  #
  # The `.mcp.json` carries the run's scope token in a bearer header. A secret
  # never rests on the node's disk (§11), so the file ships with the token
  # replaced by a `${ARBITER_MCP_TOKEN}` reference, which Claude expands from its
  # environment (even in a `--mcp-config` file), and the token itself rides in
  # the spec's `secrets`. Returns `{:ok, %{relative_path => bytes}, %{name => token}}`.
  @mcp_token_env "ARBITER_MCP_TOKEN"
  @skills_dir ".claude/skills"
  @max_skill_files 200

  @doc false
  @spec worktree_files(String.t()) ::
          {:ok, %{String.t() => binary()}, %{String.t() => String.t()}} | {:error, term()}
  def worktree_files(worktree) when is_binary(worktree) do
    with {:ok, mcp, secrets} <- mcp_file(worktree),
         {:ok, skills} <- skill_files(worktree) do
      {:ok, Map.merge(mcp, skills), secrets}
    end
  end

  defp mcp_file(worktree) do
    name = Arbiter.MCP.AgentConfig.Claude.filename()
    path = Path.join(worktree, name)

    with true <- regular_file?(path),
         {:ok, body} <- File.read(path),
         {:ok, %{} = config} <- Jason.decode(body) do
      {config, secrets} = redact_bearer_tokens(config)
      {:ok, %{name => Jason.encode!(config, pretty: true)}, secrets}
    else
      false -> {:ok, %{}, %{}}
      {:error, reason} -> {:error, {:mcp_config_unreadable, path, reason}}
      _ -> {:error, {:mcp_config_unreadable, path, :not_an_object}}
    end
  end

  defp redact_bearer_tokens(%{"mcpServers" => %{} = servers} = config) do
    {servers, secrets} =
      servers
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index()
      |> Enum.map_reduce(%{}, fn {{server, entry}, index}, secrets ->
        var = if index == 0, do: @mcp_token_env, else: "#{@mcp_token_env}_#{index}"

        case entry do
          %{"headers" => %{"Authorization" => "Bearer " <> token} = headers}
          when token != "" ->
            if String.starts_with?(token, "$") do
              {{server, entry}, secrets}
            else
              headers = Map.put(headers, "Authorization", "Bearer ${#{var}}")
              {{server, %{entry | "headers" => headers}}, Map.put(secrets, var, token)}
            end

          _ ->
            {{server, entry}, secrets}
        end
      end)

    {%{config | "mcpServers" => Map.new(servers)}, secrets}
  end

  defp redact_bearer_tokens(config), do: {config, %{}}

  defp skill_files(worktree) do
    root = Path.join(worktree, @skills_dir)

    case File.lstat(root) do
      {:ok, %File.Stat{type: :directory}} -> read_skill_files(worktree, walk_files(root))
      _ -> {:ok, %{}}
    end
  end

  defp read_skill_files(_worktree, paths) when length(paths) > @max_skill_files,
    do: {:error, {:too_many_skill_files, length(paths)}}

  defp read_skill_files(worktree, paths) do
    Enum.reduce_while(Enum.sort(paths), {:ok, %{}}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, body} -> {:cont, {:ok, Map.put(acc, Path.relative_to(path, worktree), body)}}
        {:error, reason} -> {:halt, {:error, {:skill_unreadable, path, reason}}}
      end
    end)
  end

  # Regular files only: a symlink is never followed out of the tree.
  defp walk_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      path = Path.join(dir, entry)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> walk_files(path)
        {:ok, %File.Stat{type: :regular}} -> [path]
        _ -> []
      end
    end)
  end

  defp regular_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  defp config_files(workspace) do
    case ConfigDir.ensure(workspace) do
      {:ok, source} ->
        for file <- ["settings.json", "CLAUDE.md"],
            path = Path.join(source, file),
            File.regular?(path),
            {:ok, body} <- [File.read(path)],
            into: %{},
            do: {file, body}

      _ ->
        %{}
    end
  end

  # A share of the node's memory for one worker (`docs/design/remote-workers.md`
  # §7.4: a percentage of the node's `MemTotal`, 40 % by default). Nothing known,
  # nothing asked: the agent then applies no memory cap of its own choosing.
  @memory_share 0.4

  defp remote_limits(node) do
    share = Application.get_env(:arbiter, :remote_worker_memory_share, @memory_share)

    case node |> Map.get(:capacity, %{}) |> then(&(&1 || %{})) |> Map.get("mem_total") do
      total when is_integer(total) and total > 0 ->
        %{"memory" => "#{max(div(round(total * share), 1_048_576), 256)}m"}

      _ ->
        %{}
    end
  end

  @doc """
  The declarative spec (string keys, JSON-safe) for one open of a remote spawn:
  `request` from `prepare_remote/1`, the spawn's `port_args` (its argv and env)
  and the `run_id` the node knows the run by. The secret half of the env
  (everything the local path would pass as `-e NAME`) goes in `"secrets"`, never
  in `"env"`.
  """
  @spec remote_spec(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def remote_spec(request, %{argv: [_ | _] = argv} = port_args, run_id) when is_binary(run_id) do
    with {:ok, jail} <- Jail.network_spec(Keyword.put(request.network, :socat, "socat")),
         {:ok, prompts} <- prompt_mounts(request.prompt_paths) do
      {secret, literal} = split_env(env_pairs(port_args, request))
      worktree_files = Map.get(request, :worktree_files, %{})
      worktree_secrets = Map.get(request, :worktree_secrets, %{})

      {:ok,
       %{
         "version" => 1,
         "run" => run_id,
         "task" => request.task_id && to_string(request.task_id),
         "name" => request.name,
         "install" => Arbiter.Nodes.InstallId.get(),
         "image" => image_json(request.image),
         "cwd" => request.worktree,
         "mounts" =>
           [
             put_worktree_files(
               %{"kind" => "worktree", "path" => request.worktree},
               worktree_files
             ),
             %{"kind" => "home", "path" => request.home},
             %{
               "kind" => "config_dir",
               "path" => request.config_dir,
               "files" => Map.new(request.config_files, fn {k, v} -> {k, Base.encode64(v)} end)
             },
             %{"kind" => "tmp", "path" => request.tmp_dir}
           ] ++
             Enum.map(request.cli, fn {sha, name, dest} ->
               %{"kind" => "cli", "name" => name, "sha256" => sha, "path" => dest}
             end) ++ prompts,
         "bridges" => bridges(request.network),
         "env" => Map.new(literal),
         "secrets" => Map.merge(Map.new(secret), worktree_secrets),
         "limits" => request.limits,
         "network" => "none",
         "services" => request.services,
         "command" => Jail.network_command(jail, argv)
       }
       |> put_checkout(request.checkout)}
    end
  end

  defp put_worktree_files(mount, files) when map_size(files) == 0, do: mount

  defp put_worktree_files(mount, files),
    do: Map.put(mount, "files", Map.new(files, fn {k, v} -> {k, Base.encode64(v)} end))

  defp put_checkout(spec, nil), do: spec

  # A reviewer's read-only clone (bd-cgdhlu) is seeded like any checkout but never
  # collected: it writes nothing back, so the agent mirrors only the transcripts.
  defp put_checkout(spec, %{branch: branch, base: base} = checkout) do
    body = %{"branch" => branch, "base" => base}

    body =
      if Map.get(checkout, :read_only?, false), do: Map.put(body, "read_only", true), else: body

    Map.put(spec, "checkout", body)
  end

  defp prompt_mounts(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, body} ->
          {:cont,
           {:ok, acc ++ [%{"kind" => "prompt", "path" => path, "content" => Base.encode64(body)}]}}

        {:error, reason} ->
          {:halt, {:error, {:prompt_unreadable, path, reason}}}
      end
    end)
  end

  defp bridges(network) do
    [%{"name" => "proxy", "path" => network[:proxy_socket]}] ++
      for {name, path} <- network[:bridges] || [],
          do: %{"name" => to_string(name), "path" => path}
  end

  # A2: a registry node gets the digest-pinned `ref` the primary pushed.
  defp image_json(image) do
    base = %{"tag" => image.tag, "plan" => plan_json(image.plan)}
    if is_binary(Map.get(image, :ref)), do: Map.put(base, "ref", image.ref), else: base
  end

  defp plan_json(nil), do: nil

  defp plan_json(plan) do
    %{
      "tag" => plan.tag,
      "name" => plan.name,
      "hash" => plan.hash,
      "containerfile" => plan.containerfile,
      "build_args" => Enum.map(plan.build_args, fn {k, v} -> [k, v] end),
      "base" =>
        Map.new(
          ~w(tag name hash containerfile)a,
          &{Atom.to_string(&1), Map.fetch!(plan.base, &1)}
        )
    }
  end

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
    sync_codex_auth(request, :reopen)

    if request.provider == "claude",
      do: seed_resume(request.config_dir, argv, request.mounts[:worktree])

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
      podman_secrets: Map.get(request, :git_secrets, []),
      inherit_env: Enum.map(inherit, &elem(&1, 0))
    ]

    base = if request[:pod], do: [{:pod, request.pod} | base], else: base
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

  # Carry a rotated login back to the operator's. On a re-open the previous
  # container has exited (the port is only opened again after it did), so the
  # copy is quiescent; the run then takes a newer login a sibling rotated.
  defp sync_codex_auth(%{codex_auth: {source, run}}, when_) do
    AuthSync.sync(source, run)
    if when_ == :reopen, do: AuthSync.pull(source, run)
    :ok
  end

  defp sync_codex_auth(_request, _when), do: :ok

  # -- teardown --------------------------------------------------------------------

  @doc """
  Remove the container of `port_args` (a spawn's args, or `nil`) by name, and
  the test-services pod it ran in, if any (`TestServices.stop/2`).
  """
  @spec teardown(map() | nil) :: :ok
  def teardown(%{sandbox: %{name: name} = request}) when is_binary(name) do
    Container.teardown(name)
    remove_git_secrets(request)
    reclaim_clone(request)
    sync_codex_auth(request, :final)
    TestServices.teardown(request[:pod])
  end

  def teardown(_), do: :ok

  defp remove_git_secrets(request) do
    for %{name: secret} <- Map.get(request, :git_secrets, []),
        do: Container.remove_secret(secret, podman: request.podman)

    :ok
  end

  @doc """
  Remove just the container of `port_args` (a spawn's args, or `nil`), so
  nothing of the worker's is left running in its clone. `teardown/1` is this
  plus the pod, the auth sync and the clone check.

  `opts` takes `:grace_ms`: how long a container that is still finishing may
  take to exit on its own before it is force-removed (see `Container.stop/2`).
  """
  @spec stop(map() | nil, keyword()) :: :ok
  def stop(port_args, opts \\ [])

  def stop(%{sandbox: %{name: name}}, opts) when is_binary(name) do
    case Container.stop(name, opts) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("container stop of #{name} failed: #{inspect(reason)}")
    end

    :ok
  end

  def stop(_, _opts), do: :ok

  # With the container gone, whatever it left at the clone's `.git` is checked
  # before any host-side git runs there again (bd-6t7u81): the `.git` mount
  # stops a rename while it ran, this covers a layout without one.
  defp reclaim_clone(%{mounts: %{worktree: worktree}}) when is_binary(worktree),
    do: _ = PrivateClone.reclaim(worktree)

  defp reclaim_clone(_request), do: :ok
end
