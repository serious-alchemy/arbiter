defmodule Arbiter.Worker.MemoryScope do
  @moduledoc """
  Per-spawn memory cap for a worker's whole process tree (bd-6zuoo6, GitHub #265).

  ## Why

  Incident 2026-10-03: one worker's child BEAM (a `mix test` in a worktree)
  grew to 17.5 GB, the kernel OOM-killer picked it, and because every worker
  lived in the *server's* cgroup (`arbiter.service`, `OOMPolicy=stop`,
  `MemoryMax=infinity`) systemd stopped the **whole service**: every in-flight
  run died and the coordinator's MCP connection dropped.

  ## What

  Each agent spawn is wrapped in its own transient systemd **scope**:

      systemd-run --user --scope --unit=arb-run-<task>-<hex> \\
        -p MemoryMax=<cap> -p MemorySwapMax=0 -p OOMPolicy=kill \\
        env -u XDG_RUNTIME_DIR <agent argv…>

  The scope is a *sibling* of the service's cgroup, so the cap bounds the agent
  and everything it spawns, and an OOM kills only that scope (`OOMPolicy=kill`
  takes down the whole tree, agent included). The server is never involved.
  `systemd-run --scope` exec()s the command in place, so the Port's OS pid is
  still the agent's own and `Arbiter.Worker.OsProcess` keeps working unchanged.

  `MemorySwapMax=0` matters: cgroup v2's `memory.max` counts RAM only, so
  without it a runaway tree would spill into swap and thrash the host instead
  of being killed.

  The scope unit name is recorded on the run (`worker_runs.cgroup_scopes`), so a
  kernel OOM line (`task_memcg=…/arb-run-bd-xxxx-1a2b3c4d.scope`) maps back to
  a task and a run.

  ## Detecting the kill

  `systemd-run --scope` returns the command's own exit status, which for an OOM
  kill is just 137 — indistinguishable from any other SIGKILL. systemd itself
  keeps the answer: the scope goes `failed` with `Result=oom-kill` and stays
  loaded until `reset-failed` (a *non-OOM* exit leaves nothing behind). So the
  Worker calls `outcome/1` when the port exits and, on `oom-kill`, classifies
  the run `:memory_cap_exceeded` (`Arbiter.Worker.StopReason`).

  ## Configuration

  `ARBITER_WORKER_MEMORY_MAX` (or `config :arbiter, :worker_memory_max`): a
  size systemd accepts for `MemoryMax=` — `12G`, `512M`, or a percentage of
  physical RAM (`40%`, the default). `off` / `0` / `none` / `infinity` disable
  the cap entirely.

  ## Degradation

  Linux with systemd, cgroup v2 and a user manager that has the memory
  controller delegated is required. A one-off `probe/2` checks all of that
  *with the real properties*, and when it fails the worker is spawned exactly
  as before (uncapped) with one warning logged — a host without systemd (dev on
  macOS, a container) must still be able to run workers. The doctor
  (`Arbiter.Worker.MemoryScope.Diagnosis`) reports that state.

  ## Environment

  `Arbiter.Worker.SpawnEnv` deliberately strips `XDG_RUNTIME_DIR` from the
  agent's environment (no session-bus handle for a worker), but `systemd-run
  --user` cannot find the user manager without it. So it is restored for
  `systemd-run` only, and removed again by `env -u` before the agent starts.
  An explicit `XDG_RUNTIME_DIR` in the spawn env (workspace `worker_env`) is
  left exactly as given.

  ## `$` in argv

  `systemd-run` expands `$VAR` / `$$` in the command it is given, and the agent
  argv carries arbitrary prompt text. `probe/2` measures whether this systemd
  does so, and `wrap/3` doubles every `$` when it does.
  """

  require Logger

  @default_max "40%"
  @disabled ~w(off none 0 infinity false disabled)
  @size_re ~r/\A\d+(\.\d+)?[KMGT]?\z/
  @percent_re ~r/\A\d{1,3}%\z/
  @probe_retry_ms 300_000
  @pt_key {__MODULE__, :probe}
  @outcome_timeout_ms 5_000

  @type scope :: %{unit: String.t(), max: String.t()}
  @type probe :: %{escape?: boolean(), runtime_dir: String.t() | nil}

  @doc "The cap applied when nothing is configured."
  @spec default_max() :: String.t()
  def default_max, do: @default_max

  @doc """
  The configured cap, `{:ok, "40%"}`, or `:disabled`. Environment beats
  application config beats the default; an unparseable value is logged and
  replaced by the default rather than silently disabling the protection.
  """
  @spec configured_max() :: {:ok, String.t()} | :disabled
  def configured_max do
    raw =
      presence(System.get_env("ARBITER_WORKER_MEMORY_MAX")) ||
        presence(Application.get_env(:arbiter, :worker_memory_max))

    case normalize(raw) do
      {:ok, _} = ok ->
        ok

      :disabled ->
        :disabled

      :error ->
        Logger.warning(
          "MemoryScope: ignoring invalid ARBITER_WORKER_MEMORY_MAX #{inspect(raw)} " <>
            "(want e.g. 12G, 512M, 40% or off) — using the default #{@default_max}"
        )

        {:ok, @default_max}
    end
  end

  @doc false
  @spec normalize(term()) :: {:ok, String.t()} | :disabled | :error
  def normalize(nil), do: {:ok, @default_max}

  def normalize(raw) do
    value = raw |> to_string() |> String.trim() |> String.upcase()

    cond do
      String.downcase(value) in @disabled -> :disabled
      # `MemoryMax=0` would kill the agent the instant it spawns.
      not Regex.match?(~r/[1-9]/, value) -> :error
      Regex.match?(@size_re, value) -> {:ok, value}
      Regex.match?(@percent_re, value) -> {:ok, value}
      true -> :error
    end
  end

  @doc """
  Wrap `port_args` (`%{exec:, argv:, cd:, env:}`) so the agent runs in its own
  memory-capped scope. Returns `{port_args, scope}`; `scope` is `nil` (and
  `port_args` untouched) when the cap is disabled or this host cannot provide
  one.
  """
  @spec wrap(map(), String.t() | nil, keyword()) :: {map(), scope() | nil}
  def wrap(%{exec: exec, argv: [_argv0 | rest]} = port_args, task_id, opts \\ []) do
    with {:ok, max} <- configured_max(),
         {:ok, probe} <- probe(max, opts),
         systemd_run when is_binary(systemd_run) <- systemd_run_path(opts) do
      unit = unit_name(task_id)
      {env, unset} = runtime_dir_env(Map.get(port_args, :env, []), probe.runtime_dir)
      inner = unset ++ [exec | rest]

      args = scope_args(unit, max, task_id) ++ Enum.map(inner, &escape(&1, probe.escape?))

      wrapped = %{
        port_args
        | exec: systemd_run,
          argv: [systemd_run | args]
      }

      wrapped = Map.put(wrapped, :env, env)

      {wrapped, %{unit: unit <> ".scope", max: max}}
    else
      _ -> {port_args, nil}
    end
  end

  @doc """
  What systemd concluded about a scope that just exited: `:ok`, or
  `{:memory_cap_exceeded, %{peak: bytes | nil, max: cap}}` when its processes
  were OOM-killed. The failed scope is `reset-failed` so it does not linger.
  Never raises; anything unexpected is `:ok` (the exit is then classified as the
  plain signal kill it looks like).
  """
  @spec outcome(scope(), keyword()) :: :ok | {:memory_cap_exceeded, map()}
  def outcome(%{unit: _, max: _} = scope, opts \\ []) do
    # Bounded: this runs inside the Worker's own process, and a wedged user bus
    # must not be able to hang it.
    task = Task.async(fn -> query_outcome(scope, opts) end)

    case Task.yield(task, @outcome_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :ok
    end
  end

  defp query_outcome(%{unit: unit, max: max}, opts) do
    with ctl when is_binary(ctl) <- systemctl_path(opts),
         {out, 0} <-
           run_cmd(
             opts,
             ctl,
             ["--user", "show", unit, "-p", "Result", "-p", "MemoryPeak"],
             stderr_to_stdout: true,
             env: runtime_dir_pairs(opts)
           ),
         %{"Result" => "oom-kill"} = props <- parse_show(out) do
      _ =
        run_cmd(opts, ctl, ["--user", "reset-failed", unit],
          stderr_to_stdout: true,
          env: runtime_dir_pairs(opts)
        )

      {:memory_cap_exceeded, %{peak: parse_int(Map.get(props, "MemoryPeak")), max: max}}
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Whether this host can run a capped scope for `max`, measured once with the
  real properties and cached (a failure is retried after #{div(@probe_retry_ms, 60_000)} minutes
  — the user manager may simply not be up yet at boot).

  Passing `:cmd` in `opts` runs the probe through that function and skips the
  cache (test seam).
  """
  @spec probe(String.t(), keyword()) :: {:ok, probe()} | {:error, String.t()}
  def probe(max, opts \\ []) do
    if Keyword.has_key?(opts, :cmd) do
      run_probe(max, opts)
    else
      cached_probe(max, opts)
    end
  end

  @doc "Forget the cached probe result (config change, tests)."
  @spec reset_probe() :: :ok
  def reset_probe do
    _ = :persistent_term.erase(@pt_key)
    :ok
  end

  @doc "The systemd user manager's runtime dir for this server, or `nil`."
  @spec runtime_dir(keyword()) :: String.t() | nil
  def runtime_dir(opts \\ []) do
    case Keyword.fetch(opts, :runtime_dir) do
      {:ok, dir} ->
        dir

      :error ->
        case presence(System.get_env("XDG_RUNTIME_DIR")) do
          nil -> fallback_runtime_dir()
          dir -> dir
        end
    end
  end

  @doc false
  @spec unit_name(String.t() | nil) :: String.t()
  def unit_name(task_id) do
    slug =
      (task_id || "run")
      |> to_string()
      |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
      |> String.slice(0, 40)

    "arb-run-#{slug}-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
  end

  # ---- internals -----------------------------------------------------------

  defp scope_args(unit, max, task_id) do
    [
      "--user",
      "--scope",
      "--quiet",
      "--unit=#{unit}",
      "--description=Arbiter worker #{task_id || "run"}",
      "-p",
      "MemoryMax=#{max}",
      "-p",
      "MemorySwapMax=0",
      "-p",
      "OOMPolicy=kill"
    ]
  end

  # `systemd-run` needs XDG_RUNTIME_DIR; the agent must not get it (see the
  # moduledoc). Returns the port env to use and the `env -u …` prefix.
  defp runtime_dir_env(env, dir) when is_binary(dir) do
    case List.keyfind(env, "XDG_RUNTIME_DIR", 0) do
      {_, value} when is_binary(value) ->
        {env, []}

      _ ->
        env = List.keystore(env, "XDG_RUNTIME_DIR", 0, {"XDG_RUNTIME_DIR", dir})
        {env, [env_path(), "-u", "XDG_RUNTIME_DIR"]}
    end
  end

  defp runtime_dir_env(env, nil), do: {env, []}

  defp env_path, do: System.find_executable("env") || "/usr/bin/env"

  defp escape(arg, true), do: String.replace(arg, "$", "$$")
  defp escape(arg, false), do: arg

  defp cached_probe(max, opts) do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@pt_key, nil) do
      {^max, {:ok, _} = ok, _at} ->
        ok

      {^max, {:error, _} = err, at} when now - at < @probe_retry_ms ->
        err

      _ ->
        result = run_probe(max, opts)
        :persistent_term.put(@pt_key, {max, result, now})

        case result do
          {:error, reason} ->
            Logger.warning(
              "MemoryScope: per-worker memory cap unavailable — workers run uncapped: #{reason}"
            )

          {:ok, _} ->
            Logger.info("MemoryScope: workers run in memory-capped scopes (MemoryMax=#{max})")
        end

        result
    end
  end

  defp run_probe(max, opts) do
    with :ok <- check_platform(opts),
         sd when is_binary(sd) <- systemd_run_path(opts) || {:error, "systemd-run not found"},
         runtime_dir <- runtime_dir(opts),
         true <-
           is_binary(runtime_dir) || {:error, "no systemd user runtime dir (XDG_RUNTIME_DIR)"},
         {:ok, escape?} <- probe_expansion(sd, max, runtime_dir, opts),
         :ok <- probe_enforced(sd, max, runtime_dir, escape?, opts) do
      {:ok, %{escape?: escape?, runtime_dir: runtime_dir}}
    else
      {:error, _} = err -> err
      other -> {:error, "unexpected probe result: #{inspect(other)}"}
    end
  end

  defp check_platform(opts) do
    cond do
      Keyword.has_key?(opts, :cmd) -> :ok
      match?({:unix, :linux}, :os.type()) -> check_cgroup_v2()
      true -> {:error, "not Linux"}
    end
  end

  defp check_cgroup_v2 do
    if File.exists?("/sys/fs/cgroup/cgroup.controllers"),
      do: :ok,
      else: {:error, "cgroup v2 (unified hierarchy) is not mounted"}
  end

  # Does this `systemd-run` expand `$`? (`printf %s '$$'` prints `$` if so.)
  defp probe_expansion(sd, max, runtime_dir, opts) do
    case run_in_scope(sd, max, runtime_dir, ["printf", "%s", "$$"], opts) do
      {:ok, "$"} -> {:ok, true}
      {:ok, "$$"} -> {:ok, false}
      {:ok, other} -> {:error, "unexpected systemd-run probe output #{inspect(other)}"}
      {:error, _} = err -> err
    end
  end

  # Is the limit actually applied? On a host whose user manager lacks the
  # memory controller the property is accepted and silently ignored, which would
  # leave workers "wrapped" and uncapped.
  defp probe_enforced(sd, max, runtime_dir, escape?, opts) do
    script = ~S[cat /sys/fs/cgroup$(cut -d: -f3- /proc/self/cgroup)/memory.max]
    argv = ["sh", "-c", escape(script, escape?)]

    case run_in_scope(sd, max, runtime_dir, argv, opts) do
      {:ok, "max"} ->
        {:error,
         "the user manager did not apply MemoryMax (memory.max is 'max'): the memory " <>
           "controller is not delegated to user units"}

      {:ok, value} ->
        if match?({_, ""}, Integer.parse(value)),
          do: :ok,
          else: {:error, "unreadable scope memory.max #{inspect(value)}"}

      {:error, _} = err ->
        err
    end
  end

  # `inner` goes to systemd-run verbatim — callers escape it themselves, because
  # the first probe exists to learn whether escaping is needed at all.
  defp run_in_scope(sd, max, runtime_dir, inner, opts) do
    unit = unit_name("probe")

    args =
      ["--collect" | scope_args(unit, max, "probe")] ++
        [env_path(), "-u", "XDG_RUNTIME_DIR"] ++ inner

    case run_cmd(opts, sd, args,
           stderr_to_stdout: true,
           env: [{"XDG_RUNTIME_DIR", runtime_dir}]
         ) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, status} -> {:error, "systemd-run probe exited #{status}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, "systemd-run probe failed: #{Exception.message(e)}"}
  end

  defp parse_show(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> [{k, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp runtime_dir_pairs(opts) do
    case runtime_dir(opts) do
      nil -> []
      dir -> [{"XDG_RUNTIME_DIR", dir}]
    end
  end

  # systemd's own default when the variable was stripped from the environment.
  defp fallback_runtime_dir do
    case File.stat("/proc/self") do
      {:ok, %File.Stat{uid: uid}} ->
        dir = "/run/user/#{uid}"
        if File.dir?(dir), do: dir

      _ ->
        nil
    end
  end

  # The one place this feature spawns a process: `systemd-run` / `systemctl`,
  # run through `ReleaseEnv.cmd/3` like every other non-literal command so a
  # release's ROOTDIR/BINDIR never leaks into them. `opts[:cmd]` is the test seam.
  @doc false
  def run_cmd(opts, bin, args, cmd_opts) do
    case Keyword.fetch(opts, :cmd) do
      {:ok, fun} -> fun.(bin, args, cmd_opts)
      :error -> Arbiter.Worker.ReleaseEnv.cmd(bin, args, cmd_opts)
    end
  end

  defp systemd_run_path(opts),
    do: Keyword.get(opts, :systemd_run) || binary(:systemd_run, "systemd-run")

  defp systemctl_path(opts),
    do: Keyword.get(opts, :systemctl) || binary(:systemctl, "systemctl")

  defp binary(key, name) do
    case Application.get_env(:arbiter, key) do
      path when is_binary(path) -> path
      _ -> System.find_executable(name)
    end
  end

  defp presence(nil), do: nil

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(value), do: value
end
