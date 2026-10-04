defmodule Arbiter.Worker.Jail do
  @moduledoc """
  An OS-level write jail for worker agents: the agent runs under bubblewrap
  (`bwrap`) with the whole filesystem read-only except the handful of paths a
  worker legitimately writes (bd-5gvqgc, decided in bd-ca7xko —
  `docs/design/agy-strict-write-isolation.md`).

  Provider-agnostic on purpose: `SecurityPolicy.sandbox.enabled` is the
  documented seam, and the only thing an adapter supplies is its command and
  where its own state lives. `Arbiter.Agents.Gemini` is the first caller (agy's
  native `write_to_file` ignores every setting that should confine it, so the
  kernel is the only place left to enforce it).

  The `:worktree_readonly` option (bd-3s82pf) `--ro-bind`s the worktree
  instead of `--bind`ing it, for worktree-backed review dispatches: the
  reviewer read-only posture (`Dispatch.review_security_policy/2` denies
  `Edit`/`Write`/`NotebookEdit`) becomes an OS guarantee instead of a deny
  rule agy's native writes ignore.

  ## What is writable

      bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --tmpfs /dev/shm \\
        [--bind-try <each sandbox.writable_paths entry>] \\
        --bind <worktree> --bind <agy HOME> --setenv HOME <agy HOME> \\
        --bind <git-common-dir> \\
        --ro-bind <git-common-dir>/hooks --ro-bind <git-common-dir>/config \\
        --ro-bind <git-common-dir>/worktrees \\
        --bind <own gitdir> --ro-bind-try <own gitdir>/commondir \\
        --ro-bind <worktree>/.git \\
        --setenv HEX_HOME|MIX_HOME|XDG_CACHE_HOME <per-worker dirs in the agy HOME> \\
        --unshare-pid --die-with-parent --new-session --chdir <worktree> -- <command>

  The read-only re-binds come **after** every writable bind, so no
  `writable_paths` entry can re-open them. Each one closes a way for a jailed
  process to get code run *unjailed* on the host later:

    * `hooks/` and `config` — a hook, or `core.hooksPath` / `core.fsmonitor`,
      runs on the next host-side git command in any worktree of the repo.
    * `worktrees/` (with the worker's own gitdir re-opened on top) — a
      sibling worktree's `commondir` pointer, repointed at a fake common dir
      with its own `config`, does the same for that sibling. Worktrees the
      host adds later show up read-only too, because the bind is of the
      directory itself.
    * the own gitdir's `commondir` and the worktree's `.git` file — the same
      trick for this worktree, which the host keeps running git in (review,
      merge, cleanup).
    * for a private clone (git layout B, `Arbiter.Worker.PrivateClone`), which
      is its own common dir: its `"."` `commondir` guard and its
      `objects/info/alternates`. Its main repo stays visible under
      `:hide_reads`, since the clone borrows that repo's objects.

  Everything else in the git common dir (objects, refs, the own gitdir's
  index/HEAD) stays writable, because committing needs it.

  ## Known, accepted gaps

    * The network is shared unless the caller asks for network mode with
      `:network` (below); agy does (bd-cfktou). Codex's reviewer jail does not.
    * Reads are not restricted, except for `secret_files/0` (the server's
      env file and Erlang distribution cookie), which are shadowed by
      `/dev/null`, and, when the caller passes `hide_reads: true` (agy does),
      the denylist of `Arbiter.Worker.Jail.Hide`. Anything not on that list
      is still readable.
    * Refs in the common dir are shared, so sibling worktrees' branches can
      still be written (the same as without the jail).
    * `git config --local` fails with `EBUSY` (git renames a lockfile over the
      read-only bind).
    * Submodule git dirs (`<common>/modules/*`) are not protected.
    * Tools that hard-code `$HOME/.cache` (rather than honouring
      `XDG_CACHE_HOME`) reach the operator's existing cache entries through
      the agy HOME's passthrough symlinks, which are read-only here;
      `sandbox.writable_paths` is the escape hatch.
    * `/tmp` is a private tmpfs per worker, gone with the jail. That is a
      feature (agy's `/tmp` escape, cross-worker `/tmp` collisions), but it
      means nothing can be handed to or from the host through `/tmp`.

  ## ssh over git inside the jail (bd-5d5mrs)

  `--ro-bind / /` puts the whole filesystem in the jail's unprivileged user
  namespace, which maps only the calling uid; every other uid (root's
  `/etc/ssh/ssh_config.d/*.conf`, `/etc/ssh/ssh_config` itself) reads back as
  `nobody` inside it. OpenSSH's `Include` handling refuses to load a config
  file it doesn't consider owned by root or the current user (`Bad owner or
  permissions on ...`), so a bare `ssh`/`git push` over ssh fails inside the
  jail on every host that has a system ssh config — which is effectively all
  of them.

  The fix is `ssh_shadow_config/0`: copy the *content* of
  `/etc/ssh/ssh_config` and everything it `Include`s to a location the
  calling user does own (rewriting the `Include` lines to point at the
  copies), and set `GIT_SSH_COMMAND` to `ssh -F <copy>`. This is not the same
  as agy's own `ssh -F /dev/null` workaround (bd-90kjvk) — that skips the
  system config; this reproduces it, just from a path that passes the
  ownership check. `-F` replaces *both* the system and the per-user config,
  so the mirror's first line is `Include <operator's ~/.ssh/config>` (already
  self-owned, mirrored unchanged) whenever that file exists, ahead of the
  mirrored system config — the same precedence `ssh` gives the per-user
  config by default. No bind is added: the copy lives under the same cache
  dir `probe/0` already uses, already visible read-only through the blanket
  `--ro-bind / /` above. A caller-supplied `:env` entry for `GIT_SSH_COMMAND`
  still wins (set after this default in `wrap/2`'s `env` list).

  Known gap: only `Include` targets that are absolute paths are mirrored (the
  only form the shipped `/etc/ssh/ssh_config` uses). A config that `Include`s
  a relative path is passed through unmirrored and would still fail the
  ownership check if it resolves to a non-self-owned file.

  `ssh_probe/0` / `ssh_status/0` are the availability side: whether `ssh -G`
  can parse the mirrored config inside a real jail right now, surfaced to
  `arb server doctor` via `/api/server/agy_write_jail`'s `ssh` key,
  independent of `status/0` (a caller that never uses ssh transport
  shouldn't be blocked by a regression here).

  Claude workers do not go through this module at all — `Arbiter.Agents.
  Claude` never calls `Jail.wrap/2`, so they are not affected by, or fixed
  by, any of the above.

  ## Network mode (bd-cfktou, G6)

  `wrap/2`'s `:network` option (`[proxy_socket: path, bridges: [{port,
  socket}]]`, as `Arbiter.Worker.Egress.JailRun.start/1` returns it) adds
  `--unshare-net`: the namespace has only `lo`, UDP and ICMP have no route,
  and nothing resolves (the resolver sockets are masked). The socket dir is
  blanked with a `--tmpfs` and only this run's sockets are `--ro-bind`ed back.
  Before the command runs, a small `sh` wrapper starts one `socat` per
  listener (`127.0.0.1:3128` to the proxy socket, `127.0.0.1:<port>` to each
  bridge) and waits for them to bind, exiting 125 if one doesn't, so a spawn
  never runs without the bridge it was promised. The env gets
  `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` (and lowercase), `NO_PROXY` for
  loopback, and `GIT_SSH_COMMAND` gains a `ProxyCommand` through the proxy.
  `wrap/2` refuses (`{:egress_socket_missing, path}`, `:socat_not_found`,
  `{:duplicate_bridge_port, ports}`) rather than build a jail with a bridge
  missing. `network_status/0` / `network_probe/0` / `diagnose_network/0` are
  the host-capability side, surfaced to `arb server doctor` as `network`.

  ## Teardown

  `--unshare-pid` makes bwrap's inner process pid 1 of a fresh pid namespace,
  and `--die-with-parent` ties it to the outer bwrap the port spawned. Killing
  that outer process (what `Arbiter.Worker.OsProcess.kill_tree/1` does with the
  port's `os_pid`) kills the namespace's pid 1, and the kernel then kills every
  process in the namespace, however deep or detached, which the depth-bounded
  descendant walk alone cannot promise.

  ## Availability

  `available?/0` is a real, cached probe (`probe/0`): it runs this module's own
  argv on a scratch dir and checks that a write inside succeeds and a write
  outside fails with EROFS. The binary alone proves nothing: the userns
  sysctls, AppArmor's unprivileged-userns restriction and a setuid bwrap all
  change the answer. The result is cached for the life of the VM (`reset/0`
  clears it), so a host fixed after boot needs a restart to become eligible.

  ## Config

    * `:worker_jail_available` — `true`/`false` forces the answer without
      probing (the test suite sets `false`).
    * `:worker_jail_bwrap` — the bwrap executable (default: `bwrap` on `PATH`).
    * `:worker_jail_probe_root` — where the probe makes its scratch dir
      (default `$XDG_CACHE_HOME/arbiter/jail-probe`). Must not be under `/tmp`,
      which is a tmpfs inside the jail.
    * `:worker_jail_max_userns_path` / `:worker_jail_apparmor_restrict_path` —
      the sysctl files `explain/1` reads to tell `user.max_user_namespaces = 0`
      apart from Ubuntu's `kernel.apparmor_restrict_unprivileged_userns = 1`
      (defaults: the real `/proc/sys/...` paths; the test suite points these
      at fixtures to simulate each cause without root).
    * `:worker_jail_ssh_config_path` — the system ssh config `ssh_shadow_config/0`
      mirrors (default `/etc/ssh/ssh_config`; the test suite points this at a
      fixture instead of the real file).
    * `:worker_jail_user_ssh_config_path` — the operator's own ssh config
      `ssh_shadow_config/0` `Include`s ahead of the mirrored system config
      (default `~/.ssh/config`; the test suite points this at a fixture
      instead of the real file).
    * `:worker_jail_ssh_shadow_root` — where the mirrored copy is written
      (default `$XDG_CACHE_HOME/arbiter/jail-ssh-shadow`).
    * `:worker_jail_ssh_available` — `true`/`false` forces `ssh_status/0`'s
      answer without probing (the test suite sets `false`).
  """

  require Logger

  @behaviour Arbiter.Worker.Sandbox

  alias Arbiter.Worker.Jail.Hide
  alias Arbiter.Worker.PrivateClone
  alias Arbiter.Worker.ReleaseEnv
  alias Arbiter.Worker.RunTmp

  @toolchain_dir ".arbiter-jail"
  @probe_timeout_ms 15_000

  @type git :: %{
          required(:common_dir) => String.t(),
          required(:git_dir) => String.t() | nil,
          required(:worktrees_dir?) => boolean(),
          required(:dot_git_file?) => boolean(),
          optional(:main_repo) => String.t() | nil
        }

  @type spec :: %{
          required(:bwrap) => String.t(),
          required(:worktree) => String.t(),
          optional(:home) => String.t() | nil,
          optional(:git) => git() | nil,
          optional(:writable_paths) => [String.t()],
          optional(:env) => [{String.t(), String.t()}],
          optional(:worktree_readonly) => boolean(),
          optional(:mask_paths) => [String.t()],
          optional(:secret_files) => [String.t()],
          optional(:hide) => Hide.t() | nil,
          optional(:network) => network() | nil
        }

  # bd-cfktou (G6): network mode. `proxy_socket` is the run's G5 proxy socket
  # (bridged to `127.0.0.1:proxy_port` in the namespace); each `bridges` entry
  # is `{loopback_port, host_unix_socket}`.
  @type network :: %{
          proxy_socket: String.t(),
          proxy_port: :inet.port_number(),
          bridges: [{:inet.port_number(), String.t()}],
          socat: String.t()
        }

  @proxy_port 3128
  @no_proxy "127.0.0.1,localhost,::1"

  @doc """
  Wrap `command` (an argv list, executable first) in the jail.

  Options:

    * `:worktree` (required) — the worker's worktree; writable, and the cwd
      (unless `:worktree_readonly` is set).
    * `:home` — the agent's own `$HOME` (agy's `ConfigDir` key dir); writable,
      exported as `HOME`, and where the per-worker toolchain dirs are made.
    * `:writable_paths` — extra writable paths (`sandbox.writable_paths`);
      normalized by `writable_paths/1`.
    * `:env` — extra `{name, value}` pairs set inside the jail.
    * `:hide_reads` — also hide the sensitive read paths of `Arbiter.Worker.Jail.Hide`
      (credential dirs, the install DB and `~/.arbiter`, the output-log root,
      every other worktree, other workspaces' repos) behind `--tmpfs` and
      `/dev/null` (bd-3q2djr). Off by default: the agy caller turns it on;
      Codex's reviewer jail needs `~/.codex`.
    * `:hide_repos` — the workspace repo paths to hide (default: every
      `repo_paths` entry of every workspace; the worktree's own repo is
      always left visible).
    * `:worktree_readonly` — bind the worktree `--ro-bind` instead of
      `--bind` (bd-3s82pf). For a worktree-backed review dispatch, this makes
      the reviewer's read-only posture an OS guarantee rather than a deny
      rule agy's native `write_to_file` ignores.

  Resolves the worktree's git layout (`git/1`) and prepares the toolchain dirs
  under `:home` on the host, so call it just before spawning. Does not check
  `available?/0`; the caller decides whether a jail is required.
  """
  @keyring_sentinel "@KEYRING_SOCK@"

  @impl Arbiter.Worker.Sandbox
  @spec wrap([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def wrap(command, opts) when is_list(command) and is_list(opts) do
    with {:ok, worktree} <- fetch_worktree(opts),
         {:ok, git} <- git(worktree),
         {:ok, toolchain_env} <- prepare_toolchain(Keyword.get(opts, :home)),
         {:ok, network} <- network_spec(Keyword.get(opts, :network)) do
      spec = %{
        bwrap: bwrap_path(),
        worktree: worktree,
        home: Keyword.get(opts, :home),
        git: git,
        writable_paths: run_tmp_paths() ++ writable_paths(Keyword.get(opts, :writable_paths, [])),
        env:
          network_env(network) ++
            ssh_env(network) ++ toolchain_env ++ Keyword.get(opts, :env, []),
        worktree_readonly: Keyword.get(opts, :worktree_readonly, false),
        network: network,
        hide: if(Keyword.get(opts, :hide_reads, false), do: hide_spec(git, opts))
      }

      proxy = keyring_proxy(opts)

      spec =
        if proxy,
          do:
            Map.merge(spec, %{keyring_socket: @keyring_sentinel, keyring_bus_path: keyring_bus()}),
          else: spec

      {:ok, argv(spec, command) |> maybe_keyring_proxy(proxy)}
    end
  end

  # The own repo is the one the worktree's git common dir lives in: it stays
  # visible, every other workspace repo is hidden. A private clone (git layout
  # B, bd-4wy1w1) is its own common dir, but borrows its main repo's objects
  # through alternates, so the repo that stays visible is that one.
  defp hide_spec(git, opts) do
    own_repo =
      case git do
        %{main_repo: main} when is_binary(main) ->
          main

        %{common_dir: common} ->
          if Path.basename(common) == ".git", do: Path.dirname(common), else: common

        _ ->
          nil
      end

    repos = for {:hide_repos, repos} <- opts, do: {:repos, repos}
    Hide.paths([own_repo: own_repo] ++ repos)
  end

  # bd-5ad4ch: every spawn's TMPDIR lives under the worker temp root, which sits
  # outside the worktree and the jail home, so under `--ro-bind / /` it would be
  # read-only. The run's dir doesn't exist yet when the argv is built, so the
  # root is bound writable (created here so `--bind-try` has something to bind).
  @doc false
  @spec run_tmp_paths() :: [String.t()]
  def run_tmp_paths do
    root = Arbiter.Config.Paths.worker_tmp_root()

    case File.mkdir_p(root) do
      :ok -> [root]
      {:error, _} -> []
    end
  end

  # `network:` is `[proxy_socket: path, bridges: [{port, socket}], proxy_port:,
  # socat:]` (the last two optional), as `Arbiter.Agents.Gemini` builds it from
  # a started `Arbiter.Worker.Egress` run. Every socket must exist and `socat`
  # must be installed, or the spawn is refused: a jail asked for network mode
  # never degrades to a shared network.
  @doc false
  @spec network_spec(keyword() | map() | nil) :: {:ok, network() | nil} | {:error, term()}
  def network_spec(nil), do: {:ok, nil}

  def network_spec(network) when is_list(network) or is_map(network) do
    network = Map.new(network)
    proxy = Map.get(network, :proxy_socket)
    bridges = Map.get(network, :bridges, [])

    missing =
      Enum.find(
        [proxy | Enum.map(bridges, &elem(&1, 1))],
        &(not is_binary(&1) or not exists?(&1))
      )

    socat = Map.get(network, :socat) || System.find_executable("socat")

    ports = [Map.get(network, :proxy_port, @proxy_port) | Enum.map(bridges, &elem(&1, 0))]

    cond do
      is_nil(proxy) ->
        {:error, {:egress_socket_missing, nil}}

      ports != Enum.uniq(ports) ->
        {:error, {:duplicate_bridge_port, Enum.uniq(ports -- Enum.uniq(ports))}}

      missing != nil ->
        {:error, {:egress_socket_missing, missing}}

      is_nil(socat) ->
        {:error, :socat_not_found}

      true ->
        {:ok,
         %{
           proxy_socket: proxy,
           proxy_port: Map.get(network, :proxy_port, @proxy_port),
           bridges: bridges,
           socat: socat
         }}
    end
  end

  defp exists?(path), do: match?({:ok, _}, File.lstat(path))

  @doc false
  @spec network_env(network() | nil) :: [{String.t(), String.t()}]
  def network_env(nil), do: []

  def network_env(%{proxy_port: port}) do
    url = "http://127.0.0.1:#{port}"

    for name <- ~w(HTTPS_PROXY HTTP_PROXY ALL_PROXY), var <- [name, String.downcase(name)] do
      {var, url}
    end ++ [{"NO_PROXY", @no_proxy}, {"no_proxy", @no_proxy}]
  end

  # ---- filtered keyring bus (bd-7o08mj) ----------------------------------

  # `keyring: true` asks for Secret Service (agy's credential store) inside
  # the jail. The raw session bus stays masked either way; the only bus the
  # worker can see is an `xdg-dbus-proxy` socket that `--talk`s to
  # `org.freedesktop.secrets` and nothing else (so `systemd-run` fails with
  # ServiceUnknown). No proxy binary / no upstream bus ⇒ `nil` ⇒ fail
  # closed: the jail runs with no bus at all.
  defp keyring_proxy(opts) do
    with true <- Keyword.get(opts, :keyring, false),
         proxy when is_binary(proxy) <- dbus_proxy(),
         upstream when is_binary(upstream) <- session_bus_socket() do
      %{proxy: proxy, upstream: upstream}
    else
      _ -> nil
    end
  end

  @doc """
  Path of `xdg-dbus-proxy` on this host, or `nil` (optional dependency).
  The `:arbiter, :xdg_dbus_proxy` app env overrides the lookup (tests).
  """
  @spec dbus_proxy() :: String.t() | nil
  def dbus_proxy do
    case Application.fetch_env(:arbiter, :xdg_dbus_proxy) do
      {:ok, path} -> path
      :error -> System.find_executable("xdg-dbus-proxy")
    end
  end

  @doc """
  True when a filtered keyring bus can actually be offered inside the jail:
  a proxy binary *and* an upstream session bus socket. Callers that decide
  whether to rely on the keyring (vs. copying credential files) must use this,
  not merely "a session bus exists" — otherwise a missing proxy masks the bus
  with no credentials copied and the worker cannot authenticate.
  """
  @spec keyring_usable?() :: boolean()
  def keyring_usable?, do: dbus_proxy() != nil and session_bus_socket() != nil

  defp session_bus_socket do
    case System.get_env("DBUS_SESSION_BUS_ADDRESS") do
      "unix:path=" <> rest ->
        sock = rest |> String.split(",") |> hd()
        if File.exists?(sock), do: sock

      _ ->
        nil
    end
  end

  defp maybe_keyring_proxy(argv, nil), do: argv

  defp maybe_keyring_proxy([bwrap | rest], %{proxy: proxy, upstream: upstream}) do
    # `argv/2` already emitted the `--ro-bind @KEYRING_SOCK@ <bus>` after the
    # masks; the wrapper script swaps the sentinel for the real socket.
    script = ~S"""
    proxy=$1; up=$2; shift 2
    # SIGKILL teardown skips the EXIT trap, so also sweep stale dirs here.
    # bd-c9fqsk: a short base that does not depend on TMPDIR (per-run TMPDIRs
    # are long enough to push the socket past the 107-byte sun_path limit).
    r=${XDG_RUNTIME_DIR:-/tmp}/arb-kp
    mkdir -p "$r" && chmod 700 "$r" || exit 125
    find "$r" -mindepth 1 -maxdepth 1 -type d -mmin +60 -exec rm -rf {} + 2>/dev/null
    d=$(mktemp -d "$r/run.XXXXXX") || exit 125
    n=$(printf %s "$d/bus" | wc -c)
    if [ "$n" -gt 107 ]; then
      echo "keyring proxy socket path too long ($n bytes): $d/bus" >&2
      rm -rf "$d"; exit 125
    fi
    "$proxy" "unix:path=$up" "$d/bus" --filter --talk=org.freedesktop.secrets &
    p=$!
    trap 'kill $p 2>/dev/null; rm -rf "$d"' EXIT
    trap 'exit 143' TERM INT HUP
    i=0
    while [ ! -S "$d/bus" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ -S "$d/bus" ] || { echo "xdg-dbus-proxy did not come up" >&2; exit 125; }
    n=$#; seen=0
    while [ "$n" -gt 0 ]; do
      a=$1; shift; n=$((n-1))
      [ "$a" = "--" ] && seen=1
      [ "$seen" = 0 ] && [ "$a" = "@KEYRING_SOCK@" ] && a="$d/bus"
      set -- "$@" "$a"
    done
    "$@"
    """

    ["sh", "-c", script, "sh", proxy, upstream, bwrap | rest]
  end

  @doc """
  The full bwrap argv for `spec`, ending in `["--" | command]`. Pure: every
  existence check has already been folded into `spec` (see `git/1`).
  """
  @spec argv(spec(), [String.t()]) :: [String.t()]
  def argv(%{bwrap: bwrap, worktree: worktree} = spec, command) when is_list(command) do
    home = Map.get(spec, :home)

    Enum.concat([
      [bwrap, "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"],
      ["--tmpfs", "/tmp", "--tmpfs", "/dev/shm"],
      mask_args(spec),
      hide_args(Map.get(spec, :hide)),
      network_args(Map.get(spec, :network)),
      Enum.flat_map(Map.get(spec, :writable_paths, []), &["--bind-try", &1, &1]),
      if(Map.get(spec, :worktree_readonly, false), do: ro_bind(worktree), else: bind(worktree)),
      if(home, do: bind(home) ++ ["--setenv", "HOME", home], else: []),
      git_args(Map.get(spec, :git), worktree),
      secret_args(spec),
      Enum.flat_map(Map.get(spec, :env, []), fn {k, v} -> ["--setenv", k, v] end),
      ["--unshare-pid", "--die-with-parent", "--new-session", "--chdir", worktree, "--"],
      network_command(Map.get(spec, :network), command)
    ])
  end

  # bd-3q2djr (G3): blank each hidden directory, bind the few paths a worker
  # needs back out of a blanked one (`~/.ssh/known_hosts`), then shadow each
  # hidden file with /dev/null. Emitted before every bind the worker is meant
  # to see (worktree, HOME, git dirs, the egress sockets), so those return on
  # top of a masked parent such as the worktree root.
  defp hide_args(nil), do: []

  defp hide_args(%{dirs: dirs, files: files, keep: keep}) do
    Enum.flat_map(dirs, &["--tmpfs", &1]) ++
      Enum.flat_map(keep, &["--ro-bind-try", &1, &1]) ++
      Enum.flat_map(files, &["--ro-bind", "/dev/null", &1])
  end

  # ---- network mode (bd-cfktou, G6) --------------------------------------

  # `--unshare-net` leaves the namespace with `lo` only (bwrap brings it up);
  # UDP and ICMP have no route. The egress socket dir is blanked and only this
  # run's own sockets are bound back, so a jailed process can't connect to a
  # sibling run's proxy (whose policy and grants are not its own).
  defp network_args(nil), do: []

  defp network_args(%{proxy_socket: proxy, bridges: bridges}) do
    sockets = [proxy | Enum.map(bridges, &elem(&1, 1))]

    ["--unshare-net", "--tmpfs", Path.dirname(proxy)] ++ Enum.flat_map(sockets, &ro_bind/1)
  end

  # One `socat` per listener, started before the agent: 127.0.0.1:<port> to the
  # run's Unix socket. Each exits with the namespace (the agent is pid 1 after
  # the `exec`, and pid 1 leaving kills everything in a pid namespace). A
  # listener that dies or never binds aborts the spawn with 125: running
  # without a bridge would mean running without Arbiter or without the proxy.
  @network_script ~S"""
  socat=$1; shift
  pids=; ports=
  while [ "$1" != "--" ]; do
    "$socat" "TCP-LISTEN:$1,bind=127.0.0.1,fork,reuseaddr" "UNIX-CONNECT:$2" &
    pids="$pids $!"; ports="$ports $1"; shift 2
  done
  shift
  for port in $ports; do
    hex=$(printf '%04X' "$port"); i=0
    until grep -qi "^ *[0-9]*: 0100007F:$hex 00000000:0000 0A" /proc/net/tcp; do
      i=$((i+1))
      for pid in $pids; do kill -0 "$pid" 2>/dev/null || i=100; done
      if [ "$i" -ge 50 ]; then
        echo "arbiter jail: bridge on 127.0.0.1:$port did not come up" >&2
        exit 125
      fi
      sleep 0.1
    done
  done
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null || { echo "arbiter jail: a bridge exited at start-up" >&2; exit 125; }
  done
  exec "$@"
  """

  @doc false
  @spec network_command(network() | nil, [String.t()]) :: [String.t()]
  def network_command(nil, command), do: command

  def network_command(
        %{proxy_port: proxy_port, proxy_socket: proxy, bridges: bridges, socat: socat},
        command
      ) do
    listeners =
      Enum.flat_map([{proxy_port, proxy} | bridges], fn {port, sock} ->
        [to_string(port), sock]
      end)

    ["sh", "-c", @network_script, "sh", socat] ++ listeners ++ ["--" | command]
  end

  @doc """
  The host paths the jail blanks with a `--tmpfs` (bd-7o08mj): the user's
  runtime dir (`/run/user/<uid>`: session bus, `systemd/private`, ssh-agent,
  keyring sockets), `/run/dbus` (system bus) and `/run/systemd/resolve`
  (systemd-resolved's 0666 varlink socket). `--ro-bind / /` otherwise hands
  all of them to the jailed process, and `systemd-run --user` over the bus
  runs an unjailed command on the host (writes and network).

  Also masked: the operator socket's directory
  (`Arbiter.MCP.OperatorProof.socket_dir/0`, bd-8381tk). Its default home is
  under `/run/user/<uid>`, which is already covered. Its fallback
  (`~/.arbiter/run`) or an `ARB_OPERATOR_SOCKET` override is not, and a Unix
  socket on a read-only bind is still connectable. A path under another mask
  is dropped, because the parent's tmpfs already hides it.

  Only paths that exist on the host are listed: bwrap cannot create a mount
  point under the read-only root, and a path that is absent is no vector.
  `spec.mask_paths` overrides the detection (tests).
  """
  @spec mask_paths() :: [String.t()]
  def mask_paths do
    [
      runtime_dir(),
      System.get_env("XDG_RUNTIME_DIR"),
      bus_dir(),
      "/run/dbus",
      "/run/systemd/resolve",
      Arbiter.MCP.OperatorProof.socket_dir()
    ]
    |> Enum.filter(&(is_binary(&1) and Path.type(&1) == :absolute and File.dir?(&1)))
    |> Enum.map(&Path.expand/1)
    |> Enum.reject(&(&1 in ["/", "/tmp", "/run", "/dev/shm"]))
    |> Enum.uniq()
    |> drop_nested()
  end

  defp drop_nested(paths) do
    Enum.reject(paths, fn p ->
      Enum.any?(paths, &(&1 != p and String.starts_with?(p, &1 <> "/")))
    end)
  end

  @doc """
  Files holding the server's own secrets, which the jail replaces with
  `/dev/null` (bd-8381tk, bd-51m9ba). The jail doesn't restrict reads
  otherwise, and each of these lets a worker skip the operator proof
  entirely:

    * `<data_dir>/arbiter.env`, the release's `EnvironmentFile`. It carries
      `SECRET_KEY_BASE`, the MCP token signing key, so a worker that reads it
      can sign its own coordinator token.
    * `<data-home>/release.cookie`, the per-install Erlang distribution
      cookie the release's `env.sh` creates (the data home is the `:data_dir`
      app env when set, else `ARB_DATA_HOME`, default `~/.arbiter`). The jail
      shares the host's network, so with the cookie a worker could reach
      epmd on loopback and `bin/arbiter rpc` straight into the server.
    * `$RELEASE_ROOT/releases/COOKIE`, the build-time cookie, for a release
      that predates the per-install one.

  Only existing regular files are listed: bwrap cannot create a mount point
  under the read-only root, and an absent file is no vector.
  `spec.secret_files` overrides the detection (tests).
  """
  @spec secret_files() :: [String.t()]
  def secret_files do
    data_dir = Application.get_env(:arbiter, :data_dir, Path.expand("~/.arbiter"))

    release_cookie =
      case System.get_env("RELEASE_ROOT") do
        root when is_binary(root) and root != "" -> Path.join([root, "releases", "COOKIE"])
        _ -> nil
      end

    [Path.join(data_dir, "arbiter.env"), release_cookie]
    |> Enum.filter(&(is_binary(&1) and File.regular?(&1)))
    |> Enum.concat(secret_files(release_data_home()))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @doc """
  The per-install distribution cookie under `data_home`, when it exists
  (bd-51m9ba). See `secret_files/0`.
  """
  @spec secret_files(String.t() | nil) :: [String.t()]
  def secret_files(nil), do: []

  def secret_files(data_home) do
    Enum.filter([Path.join(data_home, "release.cookie")], &File.regular?/1)
  end

  # Where env.sh keeps the per-install cookie. An explicit `:data_dir` wins
  # so tests that repoint it stay hermetic.
  defp release_data_home do
    case {Application.fetch_env(:arbiter, :data_dir), System.get_env("ARB_DATA_HOME"),
          System.user_home()} do
      {{:ok, dir}, _, _} when is_binary(dir) -> Path.expand(dir)
      {_, dir, _} when is_binary(dir) and dir != "" -> Path.expand(dir)
      {_, _, home} when is_binary(home) -> Path.join(home, ".arbiter")
      _ -> nil
    end
  end

  # Last of the binds, so no writable path, HOME or git bind can re-open one.
  defp secret_args(spec) do
    (Map.get(spec, :secret_files) || secret_files())
    |> Enum.flat_map(&["--ro-bind", "/dev/null", &1])
  end

  # Directory holding the session bus socket named by the environment, when
  # it lives somewhere other than the conventional runtime dir.
  defp bus_dir do
    case session_bus_socket() do
      nil -> nil
      sock -> Path.dirname(sock)
    end
  end

  # Resolved at runtime, never hard-coded to 1000. `XDG_RUNTIME_DIR` is what
  # the bus address points into, but the conventional `/run/user/<uid>` is
  # masked as well so an unset/forged variable cannot leave it exposed
  # (`mask_paths/0` adds `XDG_RUNTIME_DIR` and the bus socket's directory).
  defp runtime_dir do
    case File.stat("/proc/self") do
      {:ok, %{uid: uid}} -> "/run/user/#{uid}"
      _ -> nil
    end
  end

  defp mask_args(spec) do
    masks = Map.get(spec, :mask_paths) || mask_paths()
    mask = Enum.flat_map(masks, &["--tmpfs", &1]) ++ resolv_conf_args(masks)

    # The one sanctioned way back to a bus: a proxy socket filtered to
    # org.freedesktop.secrets, bound over the masked bus path.
    case Map.get(spec, :keyring_socket) do
      nil ->
        mask

      sock ->
        bus = keyring_bus_path(spec)

        mask ++
          [
            "--ro-bind",
            sock,
            bus,
            "--setenv",
            "DBUS_SESSION_BUS_ADDRESS",
            "unix:path=" <> bus
          ]
    end
  end

  # /etc/resolv.conf is a symlink into /run/systemd/resolve on resolved hosts;
  # blanking the dir would break DNS for the (networked) worker. Put the two
  # plain-text files back read-only: the varlink sockets stay hidden, and the
  # stub address they name is ordinary UDP/TCP.
  @resolv_files ["/run/systemd/resolve/stub-resolv.conf", "/run/systemd/resolve/resolv.conf"]
  defp resolv_conf_args(masks) do
    if "/run/systemd/resolve" in masks do
      @resolv_files
      |> Enum.filter(&File.regular?/1)
      |> Enum.flat_map(&["--ro-bind", &1, &1])
    else
      []
    end
  end

  defp keyring_bus_path(spec), do: Map.get(spec, :keyring_bus_path) || keyring_bus()

  defp keyring_bus, do: Path.join(runtime_dir() || "/run/user/0", "bus")

  defp git_args(nil, _worktree), do: []

  defp git_args(%{common_dir: common} = git, worktree) do
    Enum.concat([
      bind(common),
      ro_bind(Path.join(common, "hooks")),
      ro_bind(Path.join(common, "config")),
      if(git.worktrees_dir?, do: ro_bind(Path.join(common, "worktrees")), else: []),
      case git.git_dir do
        nil ->
          []

        dir ->
          bind(dir) ++ ["--ro-bind-try", Path.join(dir, "commondir"), Path.join(dir, "commondir")]
      end,
      if(git.dot_git_file?, do: ro_bind(Path.join(worktree, ".git")), else: []),
      clone_guard_args(git, common)
    ])
  end

  # bd-4wy1w1: a private clone has no own gitdir whose `commondir` could be
  # bound read-only above, so it carries a `"."` guard file instead
  # (`Arbiter.Worker.PrivateClone`); that and its alternates get the same
  # treatment.
  defp clone_guard_args(%{main_repo: main}, common) when is_binary(main) do
    ro_bind(Path.join(common, "commondir")) ++
      ro_bind(Path.join(common, "objects/info/alternates"))
  end

  defp clone_guard_args(_git, _common), do: []

  defp bind(path), do: ["--bind", path, path]
  defp ro_bind(path), do: ["--ro-bind", path, path]

  @doc """
  Normalize `sandbox.writable_paths` entries: `~` / `~/…` expand against the
  operator's home, anything else must be absolute. Relative, blank and
  non-string entries are dropped (lenient, like the rest of the policy
  parser), and so are `/` and the operator's home itself, which would re-open
  everything the jail exists to close.
  """
  @spec writable_paths(term()) :: [String.t()]
  def writable_paths(entries) when is_list(entries) do
    home = System.user_home()

    entries
    |> Enum.flat_map(fn
      "~" -> [home]
      "~/" <> _ = p when is_binary(home) -> [Path.expand(p, home)]
      "/" <> _ = p -> [Path.expand(p)]
      _ -> []
    end)
    |> Enum.reject(&(&1 in ["/", home]))
    |> Enum.uniq()
  end

  def writable_paths(_), do: []

  @doc """
  The git layout of `worktree`: its common dir, its own gitdir (`nil` for a
  main checkout), whether `worktrees/` and a `.git` *file* exist, and for a
  private clone (`Arbiter.Worker.PrivateClone`, git layout B) the main repo it
  borrows from (`main_repo`, else `nil`). Creates a missing `<common>/hooks` so
  it can be bound read-only (otherwise a jailed process could create it).
  `{:ok, nil}` when `worktree` has no `.git`.
  """
  @spec git(String.t()) :: {:ok, git() | nil} | {:error, term()}
  def git(worktree) when is_binary(worktree) do
    dot_git = Path.join(worktree, ".git")

    if File.exists?(dot_git) do
      case System.cmd("git", ["rev-parse", "--git-common-dir", "--git-dir"],
             cd: worktree,
             stderr_to_stdout: true
           ) do
        {out, 0} ->
          [common, git_dir] =
            out |> String.split("\n", trim: true) |> Enum.map(&Path.expand(&1, worktree))

          :ok = File.mkdir_p(Path.join(common, "hooks"))

          {:ok,
           %{
             common_dir: common,
             git_dir: if(git_dir == common, do: nil, else: git_dir),
             worktrees_dir?: File.dir?(Path.join(common, "worktrees")),
             dot_git_file?: match?({:ok, %File.Stat{type: :regular}}, File.lstat(dot_git)),
             main_repo: PrivateClone.main_repo(worktree)
           }}

        {out, status} ->
          {:error, {:git_layout_unresolved, status, String.trim(out)}}
      end
    else
      {:ok, nil}
    end
  rescue
    e -> {:error, {:git_layout_unresolved, Exception.message(e)}}
  end

  @doc """
  The per-worker toolchain env for an agent HOME: `HEX_HOME`, `MIX_HOME` and
  `XDG_CACHE_HOME` under `<home>/#{@toolchain_dir}/`. A writable *shared*
  cache is a persistence path out of the jail (`~/.mix/archives` runs code in
  the operator's later mix runs), so each worker gets its own.
  """
  @spec toolchain_env(String.t()) :: [{String.t(), String.t()}]
  def toolchain_env(home) when is_binary(home) do
    base = Path.join(home, @toolchain_dir)

    [
      {"HEX_HOME", Path.join(base, "hex")},
      {"MIX_HOME", Path.join(base, "mix")},
      {"XDG_CACHE_HOME", Path.join(base, "cache")}
    ]
  end

  # Runs on the host, unjailed, inside a directory a jailed process can write.
  # Any path component it planted as a symlink is removed rather than
  # followed, or it could steer these host-side writes anywhere.
  defp prepare_toolchain(nil), do: {:ok, []}

  defp prepare_toolchain(home) do
    env = toolchain_env(home)

    with :ok <- File.mkdir_p(home),
         :ok <- real_dir(Path.join(home, @toolchain_dir)),
         :ok <- Enum.reduce_while(env, :ok, &real_dir_step/2) do
      {_, mix_home} = List.keyfind(env, "MIX_HOME", 0)
      passthrough_mix(mix_home, home)
      {:ok, env}
    else
      {:error, reason} -> {:error, {:toolchain_dirs, reason}}
    end
  end

  defp real_dir_step({_var, dir}, :ok) do
    case real_dir(dir) do
      :ok -> {:cont, :ok}
      err -> {:halt, err}
    end
  end

  defp real_dir(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, _link_or_file} ->
        with :ok <- File.rm(path), do: File.mkdir(path)

      {:error, :enoent} ->
        File.mkdir(path)

      err ->
        err
    end
  end

  # The operator's Hex archive and rebar3 live in their MIX_HOME. Linking each
  # entry through (read-only inside the jail) keeps `mix deps.get` / rebar
  # builds working without letting the worker write to them.
  defp passthrough_mix(mix_home, home) do
    with source when is_binary(source) <- operator_mix_home(),
         false <- String.starts_with?(source, home <> "/"),
         {:ok, entries} <- File.ls(source) do
      Enum.each(entries, fn entry ->
        link = Path.join(mix_home, entry)
        if File.lstat(link) == {:error, :enoent}, do: File.ln_s(Path.join(source, entry), link)
      end)
    end

    :ok
  end

  defp operator_mix_home do
    case System.get_env("MIX_HOME") do
      dir when is_binary(dir) and dir != "" ->
        Path.expand(dir)

      _ ->
        case System.user_home() do
          home when is_binary(home) -> Path.join(home, ".mix")
          _ -> nil
        end
    end
  end

  # bd-5d5mrs: the default `GIT_SSH_COMMAND` for `wrap/2` — logged so a
  # jailed worker's transport is visible, not a surprise like agy's own
  # `ssh -F /dev/null` workaround.
  defp ssh_env(network) do
    case ssh_shadow_config() do
      {:ok, nil} ->
        ssh_command(nil, network)

      {:ok, path} ->
        Logger.info(
          "Arbiter.Worker.Jail: git over ssh inside the jail uses " <>
            "GIT_SSH_COMMAND=\"ssh -F #{path}\" (a self-owned mirror of " <>
            "#{ssh_config_path()}, bd-5d5mrs)"
        )

        ssh_command("ssh -F #{path}", network)

      {:error, reason} ->
        Logger.warning(
          "Arbiter.Worker.Jail: could not mirror #{ssh_config_path()} for the jail " <>
            "(#{inspect(reason)}); git over ssh inside the jail may fail on an " <>
            "ownership check (bd-5d5mrs)"
        )

        ssh_command(nil, network)
    end
  end

  # In network mode there is no route to a git remote, so ssh goes through the
  # run's proxy (bd-cfktou): `ProxyCommand` hands `%h:%p` to the loopback
  # bridge as a `CONNECT`, and the proxy's policy decides. The `-o` wins over
  # a per-host `ProxyCommand` in the mirrored config, so a host entry can't
  # route around it.
  @doc false
  @spec ssh_command(String.t() | nil, network() | nil) :: [{String.t(), String.t()}]
  def ssh_command(base, nil), do: if(base, do: [{"GIT_SSH_COMMAND", base}], else: [])

  def ssh_command(base, %{proxy_port: port}) do
    proxy = "-o 'ProxyCommand socat - PROXY:127.0.0.1:%h:%p,proxyport=#{port}'"
    [{"GIT_SSH_COMMAND", command_with(base, proxy)}]
  end

  defp command_with(nil, proxy), do: "ssh #{proxy}"
  defp command_with(base, proxy), do: "#{base} #{proxy}"

  @doc """
  Materialize a self-owned mirror of the system ssh config (the
  `:worker_jail_ssh_config_path` override, default `/etc/ssh/ssh_config`) and
  everything it `Include`s, rewriting each `Include` line to point at the
  mirrored copies, with the operator's own ssh config (the
  `:worker_jail_user_ssh_config_path` override, default `~/.ssh/config`)
  `Include`d ahead of it when that file exists — `ssh -F` replaces both the
  system and per-user config, so this reproduces the per-user config's
  normal precedence over the system one. Returns the mirrored top-level
  config's path, suitable for `ssh -F`/`GIT_SSH_COMMAND`.

  `{:ok, nil}` when neither config exists (nothing to mirror, nothing to
  fix). `{:error, reason}` on an I/O failure reading a source or writing the
  mirror — never raises.
  """
  @spec ssh_shadow_config() :: {:ok, String.t() | nil} | {:error, term()}
  def ssh_shadow_config do
    with {:ok, system_shadow} <- mirror_ssh_config(ssh_config_path(), 0) do
      wrap_with_user_ssh_config(system_shadow)
    end
  end

  defp wrap_with_user_ssh_config(system_shadow) do
    user_path = user_ssh_config_path()
    real = user_path && Path.expand(user_path)

    case real && File.exists?(real) do
      true ->
        shadow = ssh_shadow_path("worker-jail-top-level-ssh-config")

        include_lines =
          [real, system_shadow]
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("", &"Include #{&1}\n")

        case write_ssh_shadow(shadow, include_lines) do
          :ok -> {:ok, shadow}
          {:error, reason} -> {:error, {:ssh_shadow_write_failed, shadow, reason}}
        end

      _ ->
        {:ok, system_shadow}
    end
  end

  @max_ssh_include_depth 8

  defp mirror_ssh_config(_path, depth) when depth > @max_ssh_include_depth do
    {:error, :ssh_include_too_deep}
  end

  defp mirror_ssh_config(path, depth) do
    real = Path.expand(path)

    case File.read(real) do
      {:ok, content} ->
        case rewrite_ssh_includes(content, depth) do
          {:ok, rewritten} ->
            shadow = ssh_shadow_path(real)

            case write_ssh_shadow(shadow, rewritten) do
              :ok -> {:ok, shadow}
              {:error, reason} -> {:error, {:ssh_shadow_write_failed, shadow, reason}}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, {:ssh_config_unreadable, real, reason}}
    end
  rescue
    e -> {:error, {:ssh_config_mirror_raised, Exception.message(e)}}
  end

  defp rewrite_ssh_includes(content, depth) do
    content
    |> String.split("\n")
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case rewrite_ssh_include_line(line, depth) do
        {:ok, rewritten} -> {:cont, {:ok, [rewritten | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, acc |> Enum.reverse() |> Enum.join("\n")}
      {:error, reason} -> {:error, reason}
    end
  end

  @ssh_include_re ~r/^(\s*)[Ii][Nn][Cc][Ll][Uu][Dd][Ee]\s+(.+?)\s*$/

  defp rewrite_ssh_include_line(line, depth) do
    case Regex.run(@ssh_include_re, line) do
      nil ->
        {:ok, line}

      [_, indent, value] ->
        value
        |> split_ssh_include_tokens()
        |> Enum.reduce_while({:ok, []}, fn token, {:ok, acc} ->
          case ssh_include_token_shadow_paths(token, depth) do
            {:ok, paths} -> {:cont, {:ok, acc ++ paths}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, []} -> {:ok, ""}
          {:ok, paths} -> {:ok, indent <> "Include " <> Enum.join(paths, " ")}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A quoted token can contain spaces; ssh_config quoting is otherwise plain.
  defp split_ssh_include_tokens(value) do
    ~r/"([^"]*)"|(\S+)/
    |> Regex.scan(value)
    |> Enum.map(fn
      [_, quoted, ""] -> quoted
      [_, "", bare] -> bare
    end)
  end

  # Only absolute-path Include targets are mirrored (the only form
  # `/etc/ssh/ssh_config` ships with) — see the "Known gap" in the moduledoc.
  defp ssh_include_token_shadow_paths("/" <> _ = token, depth) do
    case Path.wildcard(token) do
      [] ->
        {:ok, []}

      matches ->
        Enum.reduce_while(matches, {:ok, []}, fn match, {:ok, acc} ->
          case mirror_ssh_config(match, depth + 1) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, shadow} -> {:cont, {:ok, acc ++ [shadow]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  defp ssh_include_token_shadow_paths(token, _depth), do: {:ok, [token]}

  # bd-5d5mrs finding 4: several workers can call `wrap/2` concurrently and
  # share these mirror paths (`ssh_shadow_root/0` isn't per-worker). Writing
  # to a temp file in the same directory and renaming into place means a
  # concurrent reader never observes a truncated or partial mirror — and
  # skipping the write when the content hasn't changed avoids racing a
  # reader against a rewrite for no reason.
  defp write_ssh_shadow(shadow, content) do
    with :ok <- File.mkdir_p(Path.dirname(shadow)) do
      case File.read(shadow) do
        {:ok, ^content} ->
          File.chmod(shadow, 0o644)

        _ ->
          tmp = shadow <> ".tmp.#{System.unique_integer([:positive])}"

          with :ok <- File.write(tmp, content),
               # bd-5d5mrs finding 3: OpenSSH's Include ownership check
               # rejects group/other-writable files; the process umask can
               # leave File.write's default mode group-writable.
               :ok <- File.chmod(tmp, 0o644),
               :ok <- File.rename(tmp, shadow) do
            :ok
          else
            {:error, reason} ->
              File.rm(tmp)
              {:error, reason}
          end
      end
    end
  end

  defp ssh_shadow_path(real), do: Path.join(ssh_shadow_root(), real)

  defp ssh_shadow_root do
    Application.get_env(:arbiter, :worker_jail_ssh_shadow_root) ||
      Path.join([cache_base(), "arbiter", "jail-ssh-shadow"])
  end

  defp ssh_config_path do
    Application.get_env(:arbiter, :worker_jail_ssh_config_path, "/etc/ssh/ssh_config")
  end

  defp user_ssh_config_path do
    case Application.get_env(:arbiter, :worker_jail_user_ssh_config_path) do
      path when is_binary(path) ->
        path

      nil ->
        case System.user_home() do
          home when is_binary(home) -> Path.join(home, ".ssh/config")
          _ -> nil
        end
    end
  end

  defp fetch_worktree(opts) do
    case Keyword.get(opts, :worktree) do
      wt when is_binary(wt) and wt != "" -> {:ok, Path.expand(wt)}
      _ -> {:error, :no_worktree}
    end
  end

  # ---- availability ------------------------------------------------------

  @doc """
  Nothing to release: `--die-with-parent` and `--unshare-pid` take the jail
  down with the process the port spawned (see "Teardown" in the moduledoc).
  """
  @impl Arbiter.Worker.Sandbox
  @spec teardown(term()) :: :ok
  def teardown(_run), do: :ok

  @doc "Whether this host can jail a worker (`status/0` is `:ok`)."
  @spec available?() :: boolean()
  def available?, do: status() == :ok

  @doc """
  `:ok` when the jail works on this host, `{:error, reason}` otherwise. The
  `:worker_jail_available` override wins; otherwise the first call runs
  `probe/0` and the answer is cached until `reset/0`.
  """
  @impl Arbiter.Worker.Sandbox
  @spec status() :: :ok | {:error, term()}
  def status do
    case Application.get_env(:arbiter, :worker_jail_available) do
      true ->
        :ok

      false ->
        {:error, :disabled_by_config}

      _ ->
        case :persistent_term.get({__MODULE__, :status}, :unprobed) do
          :unprobed ->
            result = probe()
            :persistent_term.put({__MODULE__, :status}, result)
            result

          cached ->
            cached
        end
    end
  end

  @doc "Forget the cached probe results (write jail and ssh)."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase({__MODULE__, :status})
    _ = :persistent_term.erase({__MODULE__, :ssh_status})
    _ = :persistent_term.erase({__MODULE__, :network_status})
    :ok
  end

  @doc """
  `:ok` when network mode (`wrap/2`'s `:network`) works on this host right
  now, `{:error, reason}` otherwise (bd-cfktou). The
  `:worker_jail_network_available` override wins; otherwise the first call
  runs `network_probe/0` and the answer is cached until `reset/0`.

  Independent of `status/0`: a host can jail writes while a network namespace
  or `socat` is missing.
  """
  @impl Arbiter.Worker.Sandbox
  @spec network_status() :: :ok | {:error, term()}
  def network_status do
    case Application.get_env(:arbiter, :worker_jail_network_available) do
      true ->
        :ok

      false ->
        {:error, :disabled_by_config}

      _ ->
        case :persistent_term.get({__MODULE__, :network_status}, :unprobed) do
          :unprobed ->
            result = network_probe()
            :persistent_term.put({__MODULE__, :network_status}, result)
            result

          cached ->
            cached
        end
    end
  end

  @doc """
  Run the network-mode check for real (uncached): `socat` is installed, and a
  jail built with `:network` (a dummy proxy socket, no bridges besides the
  proxy's own) starts its `socat`, then shows `lo` as the only interface with
  no route. `:ok` or `{:error, reason}`; never raises.
  """
  @spec network_probe() :: :ok | {:error, term()}
  def network_probe do
    with {:ok, bwrap} <- find_bwrap(),
         socat when is_binary(socat) <-
           System.find_executable("socat") || {:error, :socat_not_found} do
      scratch =
        Path.join(probe_root(), "net-#{System.pid()}-#{System.unique_integer([:positive])}")

      try do
        :ok = File.mkdir_p(Path.join(scratch, "run"))
        proxy = Path.join([scratch, "run", "proxy.sock"])
        :ok = File.write(proxy, "")

        {:ok, network} = network_spec(proxy_socket: proxy, bridges: [], socat: socat)

        script = ~S"""
        awk -F'[: ]+' 'NR>2 {print "if:" $2}' /proc/net/dev
        echo "routes:$(awk 'NR>1' /proc/net/route | wc -l)"
        """

        %{bwrap: bwrap, worktree: scratch, network: network}
        |> argv(["sh", "-c", script])
        |> run_bounded()
        |> judge_network_probe()
      rescue
        e -> {:error, {:probe_raised, Exception.message(e)}}
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp judge_network_probe(:timeout), do: {:error, :probe_timeout}
  defp judge_network_probe({:raised, msg}), do: {:error, {:bwrap_failed, msg}}

  defp judge_network_probe({out, 0}) do
    lines = out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

    case Enum.filter(lines, &String.starts_with?(&1, "if:")) -- ["if:lo"] do
      [] -> if("routes:0" in lines, do: :ok, else: {:error, {:netns_leaks, out}})
      extra -> {:error, {:netns_leaks, Enum.join(extra, ", ")}}
    end
  end

  defp judge_network_probe({out, status}), do: {:error, {:netns_failed, status, String.trim(out)}}

  @doc "`nil` when `network_status/0` is `:ok`, else a cause + fix for `arb server doctor`."
  @spec diagnose_network() :: diagnosis() | nil
  def diagnose_network do
    case network_status() do
      :ok -> nil
      {:error, reason} -> explain_network(reason)
    end
  end

  @doc "Categorize a `network_status/0` error `reason` into a cause + fix."
  @spec explain_network(term()) :: diagnosis()
  def explain_network(:socat_not_found) do
    %{
      cause: :socat_missing,
      message: "no `socat` on PATH: the jail's network mode bridges its loopback with it",
      fix: "Install socat (`dnf install socat` / `apt install socat`)."
    }
  end

  def explain_network({:netns_failed, status, out}) do
    %{
      cause: :netns_unavailable,
      message: "bwrap could not start a network namespace (exit #{status}): #{out}",
      fix:
        "Check that unprivileged user namespaces and network namespaces are allowed " <>
          "(user.max_user_namespaces, kernel.unprivileged_userns_clone, AppArmor)."
    }
  end

  def explain_network({:netns_leaks, what}) do
    %{
      cause: :netns_unavailable,
      message: "the jail's network namespace is not isolated: #{what}",
      fix: "Run bwrap with --unshare-net; this host's bwrap did not isolate the namespace."
    }
  end

  def explain_network(:disabled_by_config) do
    %{
      cause: :other,
      message:
        "network mode probing is disabled by the `:arbiter, :worker_jail_network_available` override",
      fix: "Unset that override to let the real probe run."
    }
  end

  def explain_network(reason), do: explain(reason)

  @doc """
  `:ok` when `ssh -G` can parse the mirror `ssh_shadow_config/0` builds,
  inside a real jail, right now (bd-5d5mrs) — `{:error, reason}` otherwise.
  The `:worker_jail_ssh_available` override wins; otherwise the first call
  runs `ssh_probe/0` and the answer is cached until `reset/0`.

  Independent of `status/0`: a host can jail writes fine while this
  regresses (`/etc/ssh/ssh_config` changed, no `ssh` on `PATH`), and a caller
  that never uses ssh transport shouldn't be blocked by it.
  """
  @spec ssh_status() :: :ok | {:error, term()}
  def ssh_status do
    case Application.get_env(:arbiter, :worker_jail_ssh_available) do
      true ->
        :ok

      false ->
        {:error, :disabled_by_config}

      _ ->
        case :persistent_term.get({__MODULE__, :ssh_status}, :unprobed) do
          :unprobed ->
            result = ssh_probe()
            :persistent_term.put({__MODULE__, :ssh_status}, result)
            result

          cached ->
            cached
        end
    end
  end

  @doc "Why `ssh_status/0` is `{:error, _}` (`nil` when it's `:ok`)."
  @spec diagnose_ssh() :: diagnosis() | nil
  def diagnose_ssh do
    case ssh_status() do
      :ok -> nil
      {:error, reason} -> explain_ssh(reason)
    end
  end

  @doc "Categorize an `ssh_status/0`/`ssh_probe/0` error `reason` into a cause + fix."
  @spec explain_ssh(term()) :: diagnosis()
  def explain_ssh(:ssh_not_found) do
    %{
      cause: :other,
      message: "no `ssh` executable on PATH",
      fix: "Install an ssh client (`dnf install openssh-clients` / `apt install openssh-client`)."
    }
  end

  def explain_ssh({:ssh_config_unreadable, path, reason}) do
    %{cause: :other, message: "could not read #{path}: #{inspect(reason)}", fix: nil}
  end

  def explain_ssh({:ssh_shadow_write_failed, path, reason}) do
    %{
      cause: :other,
      message: "could not write the ssh config mirror at #{path}: #{inspect(reason)}",
      fix: "Check that #{Path.dirname(path)} is writable by the user running Arbiter."
    }
  end

  def explain_ssh({:ssh_config_rejected, out}) do
    %{
      cause: :other,
      message: "ssh still rejected the mirrored config inside the jail: #{String.trim(out)}",
      fix:
        "Check the ownership of Jail.ssh_shadow_config/0's output — it must be owned by the " <>
          "user running the jail, not root."
    }
  end

  def explain_ssh(:disabled_by_config) do
    %{
      cause: :other,
      message: "ssh probing is disabled by the `:arbiter, :worker_jail_ssh_available` override",
      fix: "Unset that override to let the real probe run."
    }
  end

  def explain_ssh(reason), do: %{cause: :other, message: reason_message(reason), fix: nil}

  @type cause :: :bwrap_missing | :user_namespaces_disabled | :apparmor_restricted | :other

  @type diagnosis :: %{cause: cause(), message: String.t(), fix: String.t() | nil}

  @doc """
  Why `status/0` is `{:error, _}` (`nil` when it's `:ok`) — bd-8xy1mf, for
  `arb server doctor` and the workspace posture API. Distinguishes the causes
  that have a known fix (bwrap missing, `user.max_user_namespaces = 0`,
  Ubuntu's `kernel.apparmor_restrict_unprivileged_userns = 1`) from anything
  else, which falls back to bwrap's own stderr.
  """
  @spec diagnose() :: diagnosis() | nil
  def diagnose do
    case status() do
      :ok -> nil
      {:error, reason} -> explain(reason)
    end
  end

  @doc """
  Categorize a `status/0`/`probe/0` error `reason` into a cause + fix. Public
  so a caller that already holds the reason (`Gemini.write_jail_warning/1`
  gets it from `jail_blocker/1`, which calls `status/0` itself) can explain it
  without re-probing.

  The two sysctl-backed causes are read directly from `/proc/sys` rather than
  pattern-matched out of bwrap's stderr, which varies by bwrap version and
  locale — the sysctls are the ground truth bwrap itself consults.
  """
  @spec explain(term()) :: diagnosis()
  def explain({:bwrap_not_found, path}) do
    %{
      cause: :bwrap_missing,
      message: "bwrap (#{path}) not found on PATH",
      fix:
        "Install bubblewrap: `dnf install bubblewrap` (Fedora/RHEL 8+/AL2023) or " <>
          "`apt install bubblewrap` (Debian/Ubuntu)."
    }
  end

  def explain(:disabled_by_config) do
    %{
      cause: :other,
      message: "the jail is disabled by the `:arbiter, :worker_jail_available` override",
      fix: "Unset that override to let the real probe run."
    }
  end

  def explain({:bwrap_failed, _status, _out} = reason) do
    cond do
      max_user_namespaces() == 0 ->
        %{
          cause: :user_namespaces_disabled,
          message: "unprivileged user namespaces are disabled (`user.max_user_namespaces = 0`)",
          fix:
            "Enable them: `sysctl -w user.max_user_namespaces=<N>` and persist it under " <>
              "`/etc/sysctl.d/`, or accept that agy stays :strict-ineligible on this host."
        }

      apparmor_restricts_userns?() ->
        %{
          cause: :apparmor_restricted,
          message:
            "AppArmor restricts unprivileged user namespaces " <>
              "(`kernel.apparmor_restrict_unprivileged_userns = 1`)",
          fix:
            "Allow bwrap via an AppArmor profile, or " <>
              "`sysctl -w kernel.apparmor_restrict_unprivileged_userns=0` to permit it " <>
              "(weakens a hardening default — only do this if you understand the tradeoff)."
        }

      true ->
        %{cause: :other, message: reason_message(reason), fix: nil}
    end
  end

  def explain(reason), do: %{cause: :other, message: reason_message(reason), fix: nil}

  defp reason_message({:bwrap_failed, status, out}) when is_binary(out) do
    trimmed = String.trim(out)
    if trimmed == "", do: "bwrap exited #{status}", else: "bwrap exited #{status}: #{trimmed}"
  end

  defp reason_message(reason) when is_binary(reason), do: reason
  defp reason_message(reason), do: inspect(reason)

  defp max_user_namespaces do
    case read_sysctl(max_user_namespaces_path()) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> nil
        end
    end
  end

  defp apparmor_restricts_userns?, do: read_sysctl(apparmor_restrict_path()) == "1"

  defp read_sysctl(path) do
    case File.read(path) do
      {:ok, content} -> String.trim(content)
      _ -> nil
    end
  end

  defp max_user_namespaces_path do
    Application.get_env(
      :arbiter,
      :worker_jail_max_userns_path,
      "/proc/sys/user/max_user_namespaces"
    )
  end

  defp apparmor_restrict_path do
    Application.get_env(
      :arbiter,
      :worker_jail_apparmor_restrict_path,
      "/proc/sys/kernel/apparmor_restrict_unprivileged_userns"
    )
  end

  @doc """
  Run the jail for real (uncached): this module's own argv around a trivial
  `sh` on a scratch dir, then check on the host that the write inside landed,
  the write outside did not, and the shell saw EROFS for it.
  """
  @spec probe() :: :ok | {:error, term()}
  def probe do
    with {:ok, bwrap} <- find_bwrap() do
      scratch =
        Path.join(probe_root(), "probe-#{System.pid()}-#{System.unique_integer([:positive])}")

      inside = Path.join(scratch, "inside")
      outside = Path.join(scratch, "outside")

      try do
        :ok = File.mkdir_p(inside)
        :ok = File.mkdir_p(outside)
        script = ~s(echo ok > "$1/in" || exit 3; { echo x > "$2/out"; } 2>&1; exit 0)

        argv =
          argv(%{bwrap: bwrap, worktree: inside}, ["sh", "-c", script, "sh", inside, outside])

        argv
        |> run_bounded()
        |> judge_probe(inside, outside)
      rescue
        e -> {:error, {:probe_raised, Exception.message(e)}}
      after
        File.rm_rf(scratch)
      end
    end
  end

  @doc """
  Run the escape-vector check for real (uncached), inside this module's own
  jail argv (bd-7o08mj): none of the host's control sockets may be reachable —
  the user's session bus and `systemd/private`, the system bus,
  systemd-resolved's varlink socket, the ssh-agent / keyring sockets — and
  `systemd-run --user` (when installed) must fail, and the release's
  distribution cookie (`secret_files/0`) must read back empty. `:ok` when
  everything is hidden; `{:error, {:escape_reachable, [vector]}}` otherwise.
  """
  @spec escape_probe() :: :ok | {:error, term()}
  def escape_probe do
    with {:ok, bwrap} <- find_bwrap() do
      scratch =
        Path.join(probe_root(), "escape-#{System.pid()}-#{System.unique_integer([:positive])}")

      try do
        :ok = File.mkdir_p(scratch)

        script = """
        rd=/run/user/$(id -u)
        for p in "$rd/bus" "$rd/systemd/private" "$rd/gcr/ssh" "$rd/keyring" \
                 /run/dbus/system_bus_socket /run/systemd/resolve/io.systemd.Resolve; do
          [ -e "$p" ] && echo "reachable:$p"
        done
        for c in "$@"; do
          [ -s "$c" ] && echo "reachable:$c"
        done
        if command -v systemd-run >/dev/null 2>&1 &&
           systemd-run --user --wait --collect true >/dev/null 2>&1; then
          echo "reachable:systemd-run --user"
        fi
        exit 0
        """

        %{bwrap: bwrap, worktree: scratch}
        |> argv(["sh", "-c", script, "sh" | secret_files()])
        |> run_bounded()
        |> judge_escape_probe()
      rescue
        e -> {:error, {:probe_raised, Exception.message(e)}}
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp judge_escape_probe(:timeout), do: {:error, :probe_timeout}
  defp judge_escape_probe({:raised, msg}), do: {:error, {:bwrap_failed, msg}}

  defp judge_escape_probe({out, 0}) do
    case for "reachable:" <> v <- String.split(out, "\n", trim: true), do: v do
      [] -> :ok
      vectors -> {:error, {:escape_reachable, vectors}}
    end
  end

  defp judge_escape_probe({out, status}), do: {:error, {:bwrap_failed, status, String.trim(out)}}

  @doc "`escape_probe/0` as a diagnosis (`nil` when no vector is reachable)."
  @spec diagnose_escape() :: diagnosis() | nil
  def diagnose_escape do
    # `:worker_jail_escape_available` overrides the real probe (tests, as
    # `:worker_jail_ssh_available` does for ssh).
    result =
      case Application.get_env(:arbiter, :worker_jail_escape_available) do
        nil -> escape_probe()
        true -> :ok
        false -> {:error, {:escape_reachable, ["(forced by :worker_jail_escape_available)"]}}
      end

    case result do
      :ok ->
        nil

      {:error, {:escape_reachable, vectors}} ->
        %{
          cause: :other,
          message: "jail escape vector(s) reachable: " <> Enum.join(vectors, ", "),
          fix:
            "The jail argv must mask /run/user/<uid>, /run/dbus and /run/systemd/resolve " <>
              "(Arbiter.Worker.Jail.mask_paths/0) and shadow the release cookie " <>
              "(Arbiter.Worker.Jail.secret_files/0); this build's jail does not."
        }

      {:error, reason} ->
        explain(reason)
    end
  end

  @doc """
  Run the hidden-reads check for real (uncached), inside this module's own
  jail argv with the live hide set (bd-3q2djr, G3): every credential dir, the
  install DB and `~/.arbiter`, the output-log root, another worker's
  worktree and another workspace's repo that exists on this host must be
  absent or empty inside the jail. `:ok` when none is readable;
  `{:error, {:reads_reachable, [path]}}` otherwise. A path class that does
  not exist on this host has nothing to leak, so it is not a failure.
  """
  @spec reads_probe() :: :ok | {:error, term()}
  def reads_probe do
    with {:ok, bwrap} <- find_bwrap() do
      scratch =
        Path.join(probe_root(), "reads-#{System.pid()}-#{System.unique_integer([:positive])}")

      try do
        :ok = File.mkdir_p(scratch)
        hide = Hide.paths()
        targets = Hide.probe_targets(hide)

        script = ~S"""
        for t in "$@"; do
          kind=${t%%:*}; p=${t#*:}
          case $kind in
            file) [ -s "$p" ] && echo "reachable:$p" ;;
            dir)  [ -e "$p" ] && echo "reachable:$p" ;;
          esac
        done
        exit 0
        """

        %{bwrap: bwrap, worktree: scratch, hide: hide}
        |> argv(["sh", "-c", script, "sh" | Enum.map(targets, fn {k, p} -> "#{k}:#{p}" end)])
        |> run_bounded()
        |> judge_reads_probe()
      rescue
        e -> {:error, {:probe_raised, Exception.message(e)}}
      after
        File.rm_rf(scratch)
      end
    end
  end

  defp judge_reads_probe(:timeout), do: {:error, :probe_timeout}
  defp judge_reads_probe({:raised, msg}), do: {:error, {:bwrap_failed, msg}}

  defp judge_reads_probe({out, 0}) do
    case for "reachable:" <> v <- String.split(out, "\n", trim: true), do: v do
      [] -> :ok
      paths -> {:error, {:reads_reachable, paths}}
    end
  end

  defp judge_reads_probe({out, status}), do: {:error, {:bwrap_failed, status, String.trim(out)}}

  @doc "`reads_probe/0` as a diagnosis (`nil` when nothing sensitive is readable)."
  @spec diagnose_reads() :: diagnosis() | nil
  def diagnose_reads do
    # `:worker_jail_reads_available` overrides the real probe (tests).
    result =
      case Application.get_env(:arbiter, :worker_jail_reads_available) do
        nil -> reads_probe()
        true -> :ok
        false -> {:error, {:reads_reachable, ["(forced by :worker_jail_reads_available)"]}}
      end

    case result do
      :ok ->
        nil

      {:error, {:reads_reachable, paths}} ->
        %{
          cause: :other,
          message: "sensitive path(s) readable inside the jail: " <> Enum.join(paths, ", "),
          fix:
            "The agy jail must hide these (Arbiter.Worker.Jail.Hide.paths/1, bd-3q2djr); " <>
              "this build's jail does not, or `:worker_jail_unmask` re-exposes them."
        }

      {:error, reason} ->
        explain(reason)
    end
  end

  defp run_bounded([exec | args], extra_env \\ []) do
    task =
      Task.async(fn ->
        try do
          ReleaseEnv.cmd(exec, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"} | extra_env])
        rescue
          e -> {:raised, Exception.message(e)}
        end
      end)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
    end
  end

  @doc """
  Run the keyring-proxy check for real (uncached) the way a live agy spawn runs
  it (bd-c9fqsk): `keyring: true`, with `TMPDIR` a per-run directory built by
  `Arbiter.Worker.RunTmp` for the longest realistic task slug, so a proxy
  socket path that depends on `TMPDIR`'s length (the 107-byte `sun_path`
  limit) fails here instead of on the first review run. `:ok` when the proxy
  bus appears inside the jail, or when this host can't offer a keyring bus at
  all (`keyring_usable?/0` false — agy then falls back to credential files).
  """
  @spec keyring_probe() :: :ok | {:error, term()}
  def keyring_probe do
    with true <- keyring_usable?(),
         {:ok, _bwrap} <- find_bwrap(),
         {:ok, run_tmp} <- RunTmp.create(String.duplicate("x", 40)) do
      try do
        script =
          ~S(test -S "${DBUS_SESSION_BUS_ADDRESS#unix:path=}" && echo KEYRING_OK; exit 0)

        scratch = Path.join(run_tmp, "wt")
        :ok = File.mkdir_p(scratch)

        {:ok, [exec | args]} = wrap(["sh", "-c", script], worktree: scratch, keyring: true)

        case run_bounded([exec | args], RunTmp.env_pairs(run_tmp)) do
          :timeout ->
            {:error, :probe_timeout}

          {:raised, msg} ->
            {:error, {:bwrap_failed, msg}}

          {out, 0} ->
            if out =~ "KEYRING_OK", do: :ok, else: {:error, {:keyring_down, String.trim(out)}}

          {out, status} ->
            {:error, {:keyring_down, "exit #{status}: #{String.trim(out)}"}}
        end
      rescue
        e -> {:error, {:probe_raised, Exception.message(e)}}
      after
        RunTmp.remove(run_tmp)
      end
    else
      false -> :ok
      {:error, _} = err -> err
    end
  end

  @doc "`keyring_probe/0` as a diagnosis (`nil` when the keyring bus comes up)."
  @spec diagnose_keyring() :: diagnosis() | nil
  def diagnose_keyring do
    # `:worker_jail_keyring_available` overrides the real probe (tests).
    result =
      case Application.get_env(:arbiter, :worker_jail_keyring_available) do
        nil -> keyring_probe()
        true -> :ok
        false -> {:error, {:keyring_down, "(forced by :worker_jail_keyring_available)"}}
      end

    case result do
      :ok ->
        nil

      {:error, {:keyring_down, out}} ->
        %{
          cause: :other,
          message: "the filtered keyring proxy did not come up with a per-run TMPDIR: " <> out,
          fix:
            "The proxy socket must live under a short base independent of TMPDIR " <>
              "(Arbiter.Worker.Jail keyring wrapper, bd-c9fqsk); sun_path is limited to 107 bytes."
        }

      {:error, reason} ->
        explain(reason)
    end
  end

  defp judge_probe(:timeout, _inside, _outside), do: {:error, :probe_timeout}
  defp judge_probe({:raised, msg}, _inside, _outside), do: {:error, {:bwrap_failed, msg}}

  defp judge_probe({out, status}, inside, outside) do
    out = String.trim(out)

    cond do
      status != 0 -> {:error, {:bwrap_failed, status, out}}
      not File.exists?(Path.join(inside, "in")) -> {:error, {:inside_write_failed, out}}
      File.exists?(Path.join(outside, "out")) -> {:error, {:outside_write_not_blocked, out}}
      not (out =~ ~r/read-only file system/i) -> {:error, {:outside_write_not_erofs, out}}
      true -> :ok
    end
  end

  @doc """
  Run the ssh-config-parse check for real (uncached), inside a real jail:
  `ssh_shadow_config/0`'s mirror, then `ssh -F <mirror> -G localhost` inside
  bwrap (bd-5d5mrs). `:ok` when there's nothing to mirror (no system ssh
  config) or `ssh -G` parses the mirror cleanly; `{:error, reason}` when
  there's no `ssh` on `PATH`, the mirror couldn't be built, or `ssh` still
  rejects it (a regression in the mirror itself, or on this host's ownership
  rules).
  """
  @spec ssh_probe() :: :ok | {:error, term()}
  def ssh_probe do
    with {:ok, ssh} <- find_ssh(),
         {:ok, bwrap} <- find_bwrap(),
         {:ok, shadow} <- ssh_shadow_config() do
      case shadow do
        nil ->
          :ok

        path ->
          root = probe_root()
          :ok = File.mkdir_p(root)

          argv(%{bwrap: bwrap, worktree: root}, [ssh, "-F", path, "-G", "localhost"])
          |> run_bounded()
          |> judge_ssh_probe()
      end
    end
  end

  defp judge_ssh_probe(:timeout), do: {:error, :ssh_probe_timeout}
  defp judge_ssh_probe({:raised, msg}), do: {:error, {:ssh_probe_raised, msg}}

  defp judge_ssh_probe({out, status}) do
    cond do
      out =~ ~r/bad owner or permissions/i -> {:error, {:ssh_config_rejected, out}}
      status != 0 -> {:error, {:ssh_config_parse_failed, status, String.trim(out)}}
      true -> :ok
    end
  end

  defp find_ssh do
    case System.find_executable("ssh") do
      nil -> {:error, :ssh_not_found}
      path -> {:ok, path}
    end
  end

  defp find_bwrap do
    case Application.get_env(:arbiter, :worker_jail_bwrap) do
      path when is_binary(path) and path != "" ->
        if File.exists?(path), do: {:ok, path}, else: {:error, {:bwrap_not_found, path}}

      _ ->
        case System.find_executable("bwrap") do
          nil -> {:error, {:bwrap_not_found, "bwrap"}}
          path -> {:ok, path}
        end
    end
  end

  defp bwrap_path do
    case find_bwrap() do
      {:ok, path} -> path
      {:error, {:bwrap_not_found, path}} -> path
    end
  end

  defp probe_root do
    Application.get_env(:arbiter, :worker_jail_probe_root) ||
      Path.join([cache_base(), "arbiter", "jail-probe"])
  end

  defp cache_base do
    case System.get_env("XDG_CACHE_HOME") do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        case System.user_home() do
          home when is_binary(home) -> Path.join(home, ".cache")
          _ -> System.tmp_dir!()
        end
    end
  end
end
