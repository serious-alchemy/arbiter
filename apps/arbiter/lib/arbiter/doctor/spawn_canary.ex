defmodule Arbiter.Doctor.SpawnCanary do
  @moduledoc """
  End-to-end canary spawn for `arb server doctor` (bd-8t4yui,
  `POST /api/server/spawn_canary`).

  The doctor's static checks never proved the one thing that matters after a
  deploy: that a worker can actually spawn and reach its agent. On 2026-10-04
  v0.2.14 deployed with the doctor all-ok while every spawn crashed
  (`Paths.worker_tmp_root/0` raising a `FunctionClauseError` inside
  `RunTmp.create/1`), and on the same day every agy reviewer exited 125 (the
  jail's `sun_path` limit, bd-c9fqsk). Both were found by hand, minutes later.

  For each provider an install uses and has not paused, the canary drives the
  real spawn pipeline without a ticket:

    1. a per-run `TMPDIR` (`Arbiter.Worker.RunTmp`) and a throwaway directory
       standing in for the worktree — a temp dir, never a real repo;
    2. the adapter's own `default_argv/2` and `spawn_env/1`, built from a
       workspace that uses the provider and that workspace's resolved security
       policy: the same jail wrapper, config isolation, MCP config and
       provider-account credential handoff a dispatch gets;
    3. the workspace's worker env, `Arbiter.Worker.SpawnEnv` and the per-run
       `TMPDIR`, exactly as `Arbiter.Worker.ClaudeSession` composes them;
    4. `Arbiter.Worker.MemoryScope` and the same `Port` open
       (`ClaudeSession.open_scoped_port/2`).

  The only difference is the last argument: `--version` is appended to the
  agent CLI's argv, which every supported CLI answers before it touches the
  network, so the canary reaches the agent (the jail, the scope and the env all
  had to work for it to run) and spends no model tokens. A wrapper that dies
  first (a jail's exit 125, a missing binary, a scope that cannot start) never
  reaches it and the check fails with the first line it printed.

  ## What it does not touch

  No ticket, run record, board card, `usage_events` row or scheduler slot is
  created — it never goes through `Arbiter.Worker`, `Dispatch` or the slot gate
  — and it is not counted against any quota. It cleans up after itself: the
  agent's process tree, its memory scope, the per-run temp dirs and the
  per-spawn isolated agent homes it seeded.

  ## Guards

  One canary at a time: a second caller gets `{:error, :busy}` (HTTP 409). The
  last report is kept for the life of the server (`cached/0`), so the doctor can
  run it once per boot.

  A provider whose workspace resolves `sandbox.backend: podman` is reported
  `skipped` rather than `ok`: its spawn needs a real worktree checkout mounted
  into a container, which a canary does not have. The podman readiness check
  covers that backend.
  """

  alias Arbiter.Agents
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Doctor.Scope
  alias Arbiter.MCP
  alias Arbiter.Providers.Pause
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.MemoryScope
  alias Arbiter.Worker.OsProcess
  alias Arbiter.Worker.RunTmp
  alias Arbiter.Worker.SpawnEnv
  alias Arbiter.Worker.WorkerEnv

  require Logger

  @providers [
    {"claude", :claude, "claude"},
    {"codex", :codex, "codex"},
    {"gemini", :gemini, "agy"},
    {"grok", :grok, "grok"}
  ]

  @prompt "arbiter doctor spawn canary"
  @default_timeout_ms 30_000
  @probe_args ["--version"]
  # A `--version` answer is a line or two. Anything past this is a runaway (or
  # not the CLI we think it is): the canary stops reading, kills it and fails.
  @max_output_bytes 64 * 1024
  @max_kept_lines 20
  @cache_key {__MODULE__, :last}

  @type provider_result :: %{
          required(:provider) => String.t(),
          required(:label) => String.t(),
          required(:status) => String.t(),
          required(:spawned) => boolean(),
          required(:reached_agent) => boolean(),
          required(:exit_code) => integer() | nil,
          required(:duration_ms) => non_neg_integer() | nil,
          required(:error) => String.t() | nil,
          required(:detail) => String.t() | nil
        }

  @type report :: %{
          required(:ok) => boolean(),
          required(:ran_at) => String.t(),
          required(:providers) => [provider_result()]
        }

  @doc """
  Run one canary per provider the install uses, serialised install-wide.

  Options (tests): `:scope` (an `Arbiter.Doctor.Scope.report/1` map),
  `:workspaces`, `:timeout_ms` (per provider), `:probe_args`.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, :busy}
  def run(opts \\ []) do
    lock = {__MODULE__, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        report = build_report(opts)
        :persistent_term.put(@cache_key, report)
        {:ok, report}
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, :busy}
    end
  end

  @doc "The report of the last canary this boot ran, or `nil` when none has."
  @spec cached() :: report() | nil
  def cached, do: :persistent_term.get(@cache_key, nil)

  @doc false
  @spec reset_cache() :: :ok
  def reset_cache do
    _ = :persistent_term.erase(@cache_key)
    :ok
  end

  # -- report ------------------------------------------------------------------

  defp build_report(opts) do
    workspaces = Keyword.get_lazy(opts, :workspaces, fn -> Ash.read!(Workspace) end)

    scope =
      Keyword.get_lazy(opts, :scope, fn -> Scope.report(workspaces: workspaces) end)

    providers =
      for {type, adapter_type, label} <- @providers do
        provider_result(type, adapter_type, label, scope.providers[type], workspaces, opts)
      end

    %{
      ok: Enum.all?(providers, &(&1.status != "fail")),
      ran_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      providers: providers
    }
  end

  defp provider_result(type, adapter_type, label, info, workspaces, opts) do
    cond do
      not in_use?(info) ->
        not_applicable(type, label, "#{label} is not configured for any workspace")

      paused?(info) ->
        not_applicable(type, label, paused_detail(label, info))

      true ->
        candidates = Enum.filter(workspaces, &(&1.name in info.workspaces))
        workspace = Enum.find(candidates, &(Pause.blocking(type, &1.id) == nil)) || hd(candidates)
        canary(type, adapter_type, label, workspace, opts)
    end
  end

  defp in_use?(%{in_use: true}), do: true
  defp in_use?(_), do: false

  defp paused?(%{paused: true}), do: true
  defp paused?(_), do: false

  defp paused_detail(label, info) do
    reason = if r = info[:pause_reason], do: ": #{r}", else: ""
    "#{label} is paused#{reason} (`arb provider resume`); not spawned"
  end

  defp not_applicable(type, label, detail), do: result(type, label, "n/a", %{detail: detail})

  defp result(type, label, status, fields) do
    Map.merge(
      %{
        provider: type,
        label: label,
        status: status,
        spawned: false,
        reached_agent: false,
        exit_code: nil,
        duration_ms: nil,
        error: nil,
        detail: nil
      },
      fields
    )
  end

  # -- one provider ------------------------------------------------------------

  # Run in its own process: it owns the agent's port, and a raise or a stuck
  # receive can never leave a message in the caller's mailbox.
  defp canary(type, adapter_type, label, workspace, opts) do
    started = System.monotonic_time(:millisecond)

    task =
      Task.async(fn ->
        # If the caller dies (an HTTP client hanging up) this task must still
        # run its cleanups; it is bounded by the probe deadline either way.
        Process.flag(:trap_exit, true)

        try do
          spawn_and_probe(type, adapter_type, workspace, opts)
        rescue
          e -> {:failed, %{error: first_line(Exception.format_banner(:error, e))}}
        catch
          kind, reason -> {:failed, %{error: first_line(Exception.format_banner(kind, reason))}}
        after
          run_cleanups()
        end
      end)

    outcome = Task.await(task, :infinity)
    duration = System.monotonic_time(:millisecond) - started
    finish(type, label, outcome, duration)
  end

  defp finish(type, label, {:ok, %{exit_code: code, detail: detail}}, duration) do
    result(type, label, "ok", %{
      spawned: true,
      reached_agent: true,
      exit_code: code,
      duration_ms: duration,
      detail: detail
    })
  end

  defp finish(type, label, {:skipped, detail}, duration),
    do: result(type, label, "skipped", %{detail: detail, duration_ms: duration})

  defp finish(type, label, {:failed, fields}, duration) do
    result(
      type,
      label,
      "fail",
      Map.merge(%{duration_ms: duration}, fields)
    )
  end

  defp spawn_and_probe(type, adapter_type, workspace, opts) do
    canary_id = "canary-#{type}-#{System.unique_integer([:positive])}"
    adapter = Agents.for_type(adapter_type)
    policy = if workspace, do: SecurityPolicy.resolve(workspace), else: SecurityPolicy.default()

    if ContainerSpawn.podman?(policy) do
      {:skipped,
       "agent.security.sandbox.backend is podman: a canary has no worktree to mount (see `podman_sandbox`)"}
    else
      with {:ok, tmp_dir} <- create_tmp(canary_id),
           {:ok, worktree} <- create_tmp(canary_id <> "-worktree") do
        :ok = if workspace, do: Agents.prepare(workspace, :agent), else: :ok
        track_agent_home(adapter_type, worktree)
        on_cleanup(fn -> JailRun.stop(self()) end)

        token = mint_token(workspace, canary_id)

        agent_opts =
          [
            security: policy,
            workspace: workspace,
            worktree_path: worktree,
            task_id: canary_id,
            sandbox_wrap: true,
            # The agy jail's egress run lives and dies with its owner: this
            # task, which outlives the probe and runs the cleanups below.
            owner: self()
          ] ++ mcp_opts(adapter_type, worktree, token) ++ arb_token_opts(token)

        with {:ok, argv} <- adapter.default_argv(@prompt, agent_opts),
             argv = probe_argv(argv, Keyword.get(opts, :probe_args, @probe_args)),
             {:ok, exec} <- resolve_executable(argv) do
          env = port_env(type, adapter, agent_opts, workspace, canary_id, tmp_dir, token)
          probe(%{exec: exec, argv: argv, cd: worktree, env: env}, canary_id, opts)
        else
          {:error, reason} -> {:failed, %{error: first_line(describe(reason))}}
        end
      else
        {:error, reason} -> {:failed, %{error: first_line(describe(reason))}}
      end
    end
  end

  # The adapter's argv with the probe flag at the end, which is the agent CLI's
  # own argument list. A `-- <prompt>` tail (codex puts the prompt after `--`)
  # is dropped: past `--` the flag would be read as the prompt.
  defp probe_argv(argv, probe_args) do
    case Enum.split(argv, -2) do
      {head, ["--", @prompt]} -> head ++ probe_args
      _ -> argv ++ probe_args
    end
  end

  # A worker token bound to the canary's made-up task id, the way a dispatch
  # mints one for its task (`ARB_TOKEN`, which the agent's own `arb` and grok's
  # token broker authenticate with). It is signed, not stored: no row exists,
  # and it can read nothing.
  defp mint_token(%Workspace{id: ws_id}, canary_id) do
    Arbiter.MCP.Scope.mint_worker(%{id: canary_id, workspace_id: ws_id})
  rescue
    e ->
      Logger.warning("SpawnCanary: minting the canary token failed: #{Exception.message(e)}")
      nil
  end

  defp mint_token(nil, _canary_id), do: nil

  defp arb_token_opts(nil), do: []
  defp arb_token_opts(token), do: [arb_token: token]

  # `ClaudeSession.start/1` resolves the head of argv before opening the port.
  defp resolve_executable([exec | _]) do
    cond do
      String.contains?(exec, "/") and File.exists?(exec) ->
        {:ok, exec}

      String.contains?(exec, "/") ->
        {:error, {:executable_not_found, exec}}

      true ->
        case System.find_executable(exec) do
          nil -> {:error, {:executable_not_found, exec}}
          path -> {:ok, path}
        end
    end
  end

  # The pairs `ClaudeSession.env_pairs/4` composes for a spawn that carries an
  # explicit `:env` (a dispatch always does): workspace vars and provider-account
  # credentials, the adapter's own env, the per-run TMPDIR, the self-recursion
  # guard, all through `SpawnEnv`.
  defp port_env(type, adapter, agent_opts, workspace, canary_id, tmp_dir, token) do
    {worker_env, _secrets} =
      case workspace do
        %Workspace{} = ws -> WorkerEnv.resolve_workspace(ws, canary_id, provider: type)
        nil -> {[], []}
      end

    adapter_env =
      if function_exported?(adapter, :spawn_env, 1), do: adapter.spawn_env(agent_opts), else: []

    SpawnEnv.port_env(
      worker_env ++
        adapter_env ++
        RunTmp.env_pairs(tmp_dir) ++
        arb_token_env(token) ++ [{"ARB_WORKER_BEAD_ID", canary_id}],
      type
    )
  end

  defp arb_token_env(nil), do: []
  defp arb_token_env(token), do: [{"ARB_TOKEN", token}]

  # Claude is handed an MCP config file by `--mcp-config`; write one the same
  # way a dispatch does so the flag and its path are exercised. `--version`
  # never connects, so the token in it is never used.
  defp mcp_opts(:claude, worktree, token) do
    if MCP.inject_config?() do
      write_opts = [
        mcp_url: MCP.server_url(),
        scope_token: token || "doctor-spawn-canary",
        server_name: MCP.server_name()
      ]

      case MCP.AgentConfig.write(:claude, worktree, write_opts) do
        :ok -> [mcp_config: Path.join(worktree, MCP.AgentConfig.Claude.filename())]
        _ -> []
      end
    else
      []
    end
  end

  defp mcp_opts(_adapter_type, _worktree, _token), do: []

  defp probe(port_args, canary_id, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    {port, scope} = ClaudeSession.open_scoped_port(port_args, canary_id)
    on_cleanup(fn -> stop_scope(scope) end)

    os_pid = os_pid(port)
    deadline = System.monotonic_time(:millisecond) + timeout
    {outcome, lines} = collect(port, deadline, [], 0)

    case outcome do
      {:exit, 0} ->
        {:ok, %{exit_code: 0, detail: version_line(lines)}}

      {:exit, code} ->
        {:failed, %{spawned: true, exit_code: code, error: failure_line(lines, code)}}

      :timeout ->
        kill_tree(os_pid)
        close(port)

        {:failed,
         %{
           spawned: true,
           error:
             "the agent did not finish `--version` within #{timeout} ms (launch wrapper included)"
         }}

      :overflow ->
        kill_tree(os_pid)
        close(port)

        {:failed,
         %{
           spawned: true,
           error: "the agent printed more than #{@max_output_bytes} bytes for `--version`"
         }}
    end
  end

  # One deadline for the whole probe (not per message, so a chatty child cannot
  # keep it alive), and a byte cap on what is read. Only the first lines are
  # kept; they are all a verdict ever quotes.
  defp collect(port, deadline, acc, bytes) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {_eol, line}}} ->
        bytes = bytes + byte_size(line)

        cond do
          bytes > @max_output_bytes -> {:overflow, Enum.reverse(acc)}
          length(acc) >= @max_kept_lines -> collect(port, deadline, acc, bytes)
          true -> collect(port, deadline, [line | acc], bytes)
        end

      {^port, {:exit_status, status}} ->
        {{:exit, status}, Enum.reverse(acc)}
    after
      remaining -> {:timeout, Enum.reverse(acc)}
    end
  end

  defp version_line(lines), do: lines |> Enum.find(&present?/1) |> then(&(&1 && String.trim(&1)))

  # The first thing the child printed is what a human needs: bwrap's complaint,
  # `sh`'s `not found`, the CLI's own error.
  defp failure_line(lines, code) do
    case Enum.find(lines, &present?/1) do
      nil -> "exited #{code} without output"
      line -> "exit #{code}: #{String.trim(line)}"
    end
  end

  defp present?(line), do: String.trim(line) != ""

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  defp kill_tree(nil), do: :ok
  defp kill_tree(os_pid), do: OsProcess.kill_tree(os_pid)

  defp close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp stop_scope(nil), do: :ok

  defp stop_scope(%{unit: unit} = scope) do
    case MemoryScope.stop(scope) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("SpawnCanary: could not stop scope #{unit}: #{reason}")
    end
  end

  # -- cleanup -----------------------------------------------------------------

  # Everything the canary creates is registered here the moment it exists and
  # torn down (newest first) when the provider's process ends, whether it
  # passed, failed or raised. Process dictionary, because the owner is a
  # short-lived task.
  defp on_cleanup(fun), do: Process.put(:spawn_canary_cleanups, [fun | cleanups()])

  defp cleanups, do: Process.get(:spawn_canary_cleanups, [])

  defp run_cleanups do
    funs = cleanups()
    Process.delete(:spawn_canary_cleanups)
    Enum.each(funs, &safely/1)
  end

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.warning("SpawnCanary: cleanup failed: #{Exception.message(e)}")
  catch
    kind, reason ->
      Logger.warning("SpawnCanary: cleanup failed: #{inspect({kind, reason})}")
  end

  defp create_tmp(label) do
    with {:ok, dir} <- RunTmp.create(label) do
      on_cleanup(fn -> RunTmp.remove(dir) end)
      {:ok, dir}
    end
  end

  # Gemini, Codex and Grok seed an isolated home per worktree key; the canary's
  # key is unique, so remove the home it caused. Claude's config dir is one
  # install-wide directory and is left alone.
  defp track_agent_home(adapter_type, worktree) do
    case agent_home(adapter_type, worktree) do
      nil -> :ok
      {root, home} -> on_cleanup(fn -> remove_home(root, home) end)
    end
  end

  defp agent_home(:gemini, worktree) do
    {Agents.Gemini.ConfigDir.home_root(), Agents.Gemini.ConfigDir.path(worktree_path: worktree)}
  end

  defp agent_home(:codex, worktree) do
    case Agents.Codex.ConfigDir.path(worktree_path: worktree) do
      nil -> nil
      home -> {Agents.Codex.ConfigDir.home_root(), home}
    end
  end

  defp agent_home(:grok, worktree) do
    {Agents.Grok.ConfigDir.home_root(), Agents.Grok.ConfigDir.path(worktree_path: worktree)}
  end

  defp agent_home(_adapter_type, _worktree), do: nil

  # Never delete outside the adapter's own home root, and never the root itself.
  defp remove_home(root, home) do
    if String.starts_with?(home, root <> "/"), do: RunTmp.force_rm_rf(home)
    :ok
  end

  # -- text --------------------------------------------------------------------

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp first_line(text) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
  end
end
