defmodule Arbiter.Loop.Replay.CliRunner do
  @moduledoc """
  The `Arbiter.Loop.Replay.Runner` that spawns the agent CLIs (R15,
  bd-c7lx65), through the live spawn path: the adapter's own argv
  (`default_argv/2`), `Arbiter.Worker.ClaudeSession.port_args/6` (which puts a
  `sandbox.backend: podman` spawn in a container) and `open_scoped_port/2`, as
  a dispatch and the doctor's spawn canary do. One run, headless, with a
  deadline; the process tree (and any container) is gone when it returns.

  ## Held to the workspace's policy

  The policy is the one a dispatch on this workspace and repo would run under:
  `Arbiter.Agents.SecurityPolicy.resolve/3`, for a reviewer its review backend
  (`for_review_spawn/1`), floored by the replayed model's guardrail profile
  (`Arbiter.Guardrails.apply_to_policy/5`). A container backend needs a private
  clone to mount, which `layout/2` tells the harness. A provider with no
  container wrap point runs on the bwrap path, as a dispatch of it does.

  ## The environment

  Built from nothing (`Arbiter.Worker.SpawnEnv`): the allowlisted names, and

    * the account's own credential (the workspace's credential for that
      provider), never the workspace's other `worker_env` vars, which can hold a
      forge token or production secrets;
    * the adapter's own env (`spawn_env/1`: its isolated config dir);
    * a private `TMPDIR`, removed with the run;
    * the replay's fences: `arb` points at a port nothing listens on and has no
      workspace or token (and the run gets no MCP config), so nothing reaches
      Arbiter; `gh`/`glab` read empty config dirs, so there is no forge login;
      git reads a config of the replay's own with no credential helper, never
      prompts, and has no ssh transport. With the sandbox's missing remote,
      nothing can be pushed.

  ## The output

  Every line is parsed by the adapter (`parse_line/2`, with a session of the
  replay's own: no transcript, no run, a topic nobody else uses), and only the
  model's own text is kept: a tool's output never reads as a verdict.
  """

  @behaviour Arbiter.Loop.Replay.Runner

  require Logger

  alias Arbiter.Accounts.Credentials
  alias Arbiter.Agents
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.ContainerSpawn
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.MemoryScope
  alias Arbiter.Worker.OsProcess
  alias Arbiter.Worker.RunTmp
  alias Arbiter.Worker.Sandbox

  # Where the replayed CLI's `arb` points: the discard port, which nothing serves.
  @nowhere "http://127.0.0.1:9"

  @impl true
  def layout(role, spec) do
    {_type, policy} = policy(role, spec)
    if ContainerSpawn.podman?(policy), do: :private_clone, else: :sandbox
  end

  @impl true
  def run(role, spec) do
    {type, policy} = policy(role, spec)
    adapter = Agents.for_type(type)
    label = "replay-#{spec.replay_id}-#{role}"
    :ok = Agents.prepare(spec.workspace, if(role == :review, do: :review_agent, else: :agent))

    agent_opts = [
      security: policy,
      workspace: spec.workspace,
      worktree_path: spec.dir,
      task_id: label,
      model: spec.model,
      owner: self(),
      timeout_ms: spec.timeout_ms,
      sandbox_wrap: true
    ]

    with {:ok, tmp} <- RunTmp.create(label) do
      try do
        spawn_run(adapter, type, policy, agent_opts, tmp, label, spec)
      rescue
        error -> {:error, {:spawn_failed, Exception.message(error)}}
      after
        RunTmp.force_rm_rf(tmp)
        stop_jail()
      end
    end
  end

  # ---- the policy ----------------------------------------------------------------

  defp policy(role, spec) do
    type = adapter_type(spec.provider)
    resolved = SecurityPolicy.resolve(spec.workspace, %{}, spec.repo)
    resolved = if role == :review, do: SecurityPolicy.for_review_spawn(resolved), else: resolved

    policy =
      resolved
      |> Guardrails.apply_to_policy(spec.workspace, type, spec.model, repo: spec.repo)
      |> host_fallback(type)

    {type, policy}
  end

  # A provider with no container wrap point (agy, grok) is never spawned under
  # podman by a dispatch: it runs on the bwrap path, as the spawn canary's does.
  defp host_fallback(%SecurityPolicy{} = policy, type) do
    if ContainerSpawn.podman?(policy) and not match?({:ok, _}, Sandbox.module(policy, type)),
      do: %{policy | sandbox: %{policy.sandbox | backend: :bwrap}},
      else: policy
  end

  defp adapter_type(:antigravity), do: :gemini
  defp adapter_type(provider), do: provider

  # ---- the spawn ---------------------------------------------------------------------

  defp spawn_run(adapter, type, policy, agent_opts, tmp, label, spec) do
    with {:ok, argv} <- adapter.default_argv(spec.prompt, agent_opts),
         {:ok, exec} <- executable(policy, argv),
         {:ok, port_args} <-
           ClaudeSession.port_args(
             session_opts(type, policy, spec),
             exec,
             argv,
             spec.dir,
             env(adapter, type, agent_opts, tmp, spec),
             owner: self(),
             task_id: label,
             tmp_dir: tmp
           ) do
      try do
        {:ok, collect_run(port_args, label, adapter, type, spec)}
      after
        ContainerSpawn.teardown(port_args)
        remove_prompt_file(adapter, argv)
      end
    end
  end

  defp session_opts(type, policy, spec) do
    [security: policy, workspace: spec.workspace, repo: spec.repo, provider: Atom.to_string(type)] ++
      Map.get(spec, :container_opts, [])
  end

  # A container's argv names its own executables; a host one is resolved here,
  # as `ClaudeSession.start/1` does.
  defp executable(policy, [exec | _]) do
    cond do
      ContainerSpawn.podman?(policy) -> {:ok, exec}
      String.contains?(exec, "/") and File.exists?(exec) -> {:ok, exec}
      path = System.find_executable(exec) -> {:ok, path}
      true -> {:error, {:executable_not_found, exec}}
    end
  end

  defp env(adapter, type, agent_opts, tmp, spec) do
    adapter_env =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :spawn_env, 1),
        do: adapter.spawn_env(agent_opts),
        else: []

    Arbiter.Worker.SpawnEnv.port_env(
      Credentials.workspace_pairs(spec.workspace.id, spec.provider) ++
        adapter_env ++ RunTmp.env_pairs(tmp) ++ fences(spec),
      Atom.to_string(type)
    )
  end

  defp fences(spec) do
    gh = Path.join(spec.scratch, "gh")
    glab = Path.join(spec.scratch, "glab")
    gitconfig = Path.join(spec.scratch, "gitconfig")
    Enum.each([gh, glab], &File.mkdir_p!/1)

    File.write!(gitconfig, """
    [user]
    \tname = arbiter replay
    \temail = replay@arbiter.invalid
    [commit]
    \tgpgsign = false
    """)

    [
      {"ARB_HOST", @nowhere},
      {"ARB_WORKSPACE", false},
      {"ARB_TOKEN", false},
      {"ARBITER_MCP_TOKEN", false},
      {"ARB_WORKER_BEAD_ID", false},
      {"GH_CONFIG_DIR", gh},
      {"GLAB_CONFIG_DIR", glab},
      {"GIT_CONFIG_GLOBAL", gitconfig},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_SSH_COMMAND", "false"}
    ]
  end

  defp collect_run(port_args, label, adapter, type, spec) do
    started = System.monotonic_time(:millisecond)
    {port, scope} = ClaudeSession.open_scoped_port(port_args, label)
    os_pid = os_pid(port)

    {outcome, parser} =
      collect(port, started + spec.timeout_ms, parser(adapter, type, label, spec), "")

    if outcome == :timeout do
      kill_tree(os_pid)
      close(port)
    end

    stop_scope(scope)
    flush_done()

    %{
      output: text(parser),
      exit_status: exit_status(outcome),
      timed_out: outcome == :timeout,
      duration_ms: System.monotonic_time(:millisecond) - started
    }
  end

  # One deadline for the whole run, not per message: a chatty child cannot keep
  # it alive. A line longer than the port's line buffer arrives in pieces.
  defp collect(port, deadline, parser, partial) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        collect(port, deadline, parser, partial <> chunk)

      {^port, {:data, {:eol, line}}} ->
        collect(port, deadline, feed(parser, partial <> line), "")

      {^port, {:exit_status, status}} ->
        {{:exit, status}, if(partial == "", do: parser, else: feed(parser, partial))}
    after
      remaining -> {:timeout, parser}
    end
  end

  defp exit_status({:exit, status}), do: status
  defp exit_status(:timeout), do: nil

  # ---- the output --------------------------------------------------------------------

  defp parser(adapter, type, label, spec) do
    config =
      ClaudeSession.build_session_config(label, "replay:" <> spec.replay_id,
        provider: Atom.to_string(type),
        model: spec.model,
        redact_values: []
      )

    %{
      adapter: adapter,
      session: Map.merge(adapter.init_session(task_id: label, model: spec.model), config),
      text: []
    }
  end

  # Only the model's own text (`arm_done?` true) is kept; the session's display
  # buffer is emptied after each line, so its cap never hides a later one.
  defp feed(%{adapter: adapter, session: session, text: text} = parser, line) do
    {display, session} = adapter.parse_line(session, line)
    kept = for {line_text, true} <- display, do: line_text
    %{parser | session: %{session | output_lines: []}, text: Enum.reverse(kept, text)}
  end

  defp text(%{text: text}),
    do: text |> Enum.reverse() |> Enum.flat_map(&String.split(&1, "\n"))

  # The session's done detection messages its caller; a replay reads the
  # verdict from the text instead, so they are dropped.
  defp flush_done do
    receive do
      {:__claude_session_done__, _line} -> flush_done()
    after
      0 -> :ok
    end
  end

  # ---- cleanup -------------------------------------------------------------------------

  defp os_pid(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  end

  defp os_pid(_handle), do: nil

  defp kill_tree(nil), do: :ok
  defp kill_tree(os_pid), do: OsProcess.kill_tree(os_pid)

  defp close(port) when is_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp close(_handle), do: :ok

  defp stop_scope(nil), do: :ok

  defp stop_scope(scope) do
    case MemoryScope.stop(scope) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Loop.Replay: could not stop scope #{scope.unit}: #{reason}")
    end
  end

  # agy's egress jail is bound to its owner, this process.
  defp stop_jail do
    JailRun.stop(self())
  catch
    :exit, _ -> :ok
  end

  defp remove_prompt_file(adapter, argv) do
    if function_exported?(adapter, :prompt_tmpfile, 1) do
      case adapter.prompt_tmpfile(argv) do
        path when is_binary(path) -> File.rm(path)
        _ -> :ok
      end
    end
  end
end
