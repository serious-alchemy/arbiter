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

  Everything else in the git common dir (objects, refs, the own gitdir's
  index/HEAD) stays writable, because committing needs it.

  ## Known, accepted gaps

    * The network is shared: `arb`, MCP and `git push` need it.
    * Reads are not restricted.
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
  """

  alias Arbiter.Worker.ReleaseEnv

  @toolchain_dir ".arbiter-jail"
  @probe_timeout_ms 15_000

  @type git :: %{
          common_dir: String.t(),
          git_dir: String.t() | nil,
          worktrees_dir?: boolean(),
          dot_git_file?: boolean()
        }

  @type spec :: %{
          required(:bwrap) => String.t(),
          required(:worktree) => String.t(),
          optional(:home) => String.t() | nil,
          optional(:git) => git() | nil,
          optional(:writable_paths) => [String.t()],
          optional(:env) => [{String.t(), String.t()}],
          optional(:worktree_readonly) => boolean()
        }

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
    * `:worktree_readonly` — bind the worktree `--ro-bind` instead of
      `--bind` (bd-3s82pf). For a worktree-backed review dispatch, this makes
      the reviewer's read-only posture an OS guarantee rather than a deny
      rule agy's native `write_to_file` ignores.

  Resolves the worktree's git layout (`git/1`) and prepares the toolchain dirs
  under `:home` on the host, so call it just before spawning. Does not check
  `available?/0`; the caller decides whether a jail is required.
  """
  @spec wrap([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def wrap(command, opts) when is_list(command) and is_list(opts) do
    with {:ok, worktree} <- fetch_worktree(opts),
         {:ok, git} <- git(worktree),
         {:ok, toolchain_env} <- prepare_toolchain(Keyword.get(opts, :home)) do
      spec = %{
        bwrap: bwrap_path(),
        worktree: worktree,
        home: Keyword.get(opts, :home),
        git: git,
        writable_paths: writable_paths(Keyword.get(opts, :writable_paths, [])),
        env: toolchain_env ++ Keyword.get(opts, :env, []),
        worktree_readonly: Keyword.get(opts, :worktree_readonly, false)
      }

      {:ok, argv(spec, command)}
    end
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
      Enum.flat_map(Map.get(spec, :writable_paths, []), &["--bind-try", &1, &1]),
      if(Map.get(spec, :worktree_readonly, false), do: ro_bind(worktree), else: bind(worktree)),
      if(home, do: bind(home) ++ ["--setenv", "HOME", home], else: []),
      git_args(Map.get(spec, :git), worktree),
      Enum.flat_map(Map.get(spec, :env, []), fn {k, v} -> ["--setenv", k, v] end),
      ["--unshare-pid", "--die-with-parent", "--new-session", "--chdir", worktree, "--"],
      command
    ])
  end

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
      if(git.dot_git_file?, do: ro_bind(Path.join(worktree, ".git")), else: [])
    ])
  end

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
  main checkout), and whether `worktrees/` and a `.git` *file* exist. Creates a
  missing `<common>/hooks` so it can be bound read-only (otherwise a jailed
  process could create it). `{:ok, nil}` when `worktree` has no `.git`.
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
             dot_git_file?: match?({:ok, %File.Stat{type: :regular}}, File.lstat(dot_git))
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

  defp fetch_worktree(opts) do
    case Keyword.get(opts, :worktree) do
      wt when is_binary(wt) and wt != "" -> {:ok, Path.expand(wt)}
      _ -> {:error, :no_worktree}
    end
  end

  # ---- availability ------------------------------------------------------

  @doc "Whether this host can jail a worker (`status/0` is `:ok`)."
  @spec available?() :: boolean()
  def available?, do: status() == :ok

  @doc """
  `:ok` when the jail works on this host, `{:error, reason}` otherwise. The
  `:worker_jail_available` override wins; otherwise the first call runs
  `probe/0` and the answer is cached until `reset/0`.
  """
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

  @doc "Forget the cached probe result."
  @spec reset() :: :ok
  def reset do
    _ = :persistent_term.erase({__MODULE__, :status})
    :ok
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

  defp run_bounded([exec | args]) do
    task =
      Task.async(fn ->
        try do
          ReleaseEnv.cmd(exec, args, stderr_to_stdout: true, env: [{"LC_ALL", "C"}])
        rescue
          e -> {:raised, Exception.message(e)}
        end
      end)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
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
