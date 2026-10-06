defmodule Arbiter.Agents.Grok do
  @moduledoc """
  grok (xAI's `grok` CLI) adapter implementing `Arbiter.Agents.Agent`
  (bd-9ydvov, epic bd-6f3edy).

  grok is a real agent harness with a Claude-compatible headless stream, so this
  adapter is mostly argv and environment; the parsing rides on
  `Arbiter.Worker.ClaudeSession` with `Arbiter.Agents.Grok.Stream` absorbing the
  grok quirks. The shapes and gotchas come from the research (bd-73uvlo) and the
  live probe (bd-7nbwix, grok 1.0.25 / `grok-4.7`).

  ## Argv

      grok -p <prompt> --output-format streaming-messages-json --always-approve \\
        --no-auto-update --max-turns N [-m model] [--effort e]

  There is deliberately **no** grok `--sandbox`: `Arbiter.Worker.Jail` wraps the
  spawn, and grok's own Landlock/bwrap sandbox would nest inside it. The prompt
  goes inline, or, when it would overflow one argv element, in a `--prompt-file`
  under the worker's bound HOME (the jail's `--tmpfs /tmp` hides `/tmp` files).
  The whole thing runs under `sh -c '... exec "$@" < /dev/null'` so stdin is
  closed. That script first runs `grok login` when the broker's
  `GROK_AUTH_PROVIDER_COMMAND` is set and the worker's `GROK_HOME` has no
  `auth.json`: headless `-p` never calls the provider cold (bd-8rvkqd).

  ## Security policy (bd-761q6h)

  `Arbiter.Agents.Grok.Security` maps the `SecurityPolicy` onto `--deny` rules,
  `--disallowed-tools`, `--disable-web-search` and `--no-subagents`; a deny beats
  `--always-approve`. Those are permission-layer guards. The OS-level guarantees
  come from the jail: nothing outside the worktree and the bound HOME is
  writable, and a review dispatch (the policy denies `Write`) gets the worktree
  `--ro-bind`-ed, so a reviewer's grok cannot write it however it tries. Why the
  jail and not grok's own `--sandbox` is in `docs/worker-security.md`.

  ## Environment

  Each worker gets its own `HOME` with `GROK_HOME=$HOME/.grok`
  (`Arbiter.Agents.Grok.ConfigDir`). `HOME` isolation is required: `GROK_HOME`
  alone leaks the operator's `~/.claude` settings, hooks, MCP servers and skills
  through grok's compatibility layer. On top of that:
  `GROK_DISABLE_AUTOUPDATER=1`, `GROK_TELEMETRY_TRACE_UPLOAD=0`, `GROK_MEMORY=0`
  and `NO_COLOR=1`. An inherited `XAI_API_KEY` or `GROK_AUTH_PROVIDER_COMMAND`
  is removed from the spawn; the credential comes from
  `Arbiter.Agents.Grok.Credential`, which asks the credential broker's auth provider.

  ## Completion and failure

  Completion is the terminal `result` line plus the exit code; the `arb done`
  sentinel comes from assistant text, as for every provider. Exit 0 is success,
  1 an error (the `result` carries `errors[]`), 130/143 SIGINT/SIGTERM, which
  `Arbiter.Worker.StopReason` already classifies as killed.

  ## Quota

  The free tier is small (about 500K tokens per rolling 24 h, cached tokens
  counted), so a usage record keeps `tokens_in` (uncached) and
  `cache_read_tokens` apart and the quota total is their sum plus output.
  `total_cost_usd` is notional on the free tier. The 429 hold, the ledger
  headroom estimate and the `grok usage <sid>` archive are separate tasks.

  ## Not here yet

  The per-worker MCP config is `Arbiter.MCP.AgentConfig.Grok`; provider
  registration and routing are a later task. A `splice_prompt/2` (nudge / `-r`
  resume) is left out too, which the worker treats as "this provider cannot be
  resumed in place".
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Grok.ConfigDir
  alias Arbiter.Agents.Grok.Credential
  alias Arbiter.Agents.Grok.Security
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.Sandbox

  require Logger

  @done_regex ~r/(?:\A|\n)[^\p{L}\p{N}\n]*arb done[^\p{L}\p{N}]*\z/u

  # Linux's per-argument execve limit (see `Arbiter.Agents.Claude`).
  @max_prompt_argv_bytes 131_072

  @default_max_turns 60

  @static_env [
    {"GROK_DISABLE_AUTOUPDATER", "1"},
    {"GROK_TELEMETRY_TRACE_UPLOAD", "0"},
    {"GROK_MEMORY", "0"},
    {"NO_COLOR", "1"}
  ]

  # Credential channels an inherited server env must not hand a worker; the
  # credential seam re-adds whichever it means to.
  @credential_vars ~w(XAI_API_KEY GROK_AUTH_PROVIDER_COMMAND)

  @impl true
  def provider, do: "grok"

  @impl true
  def done_sentinel, do: @done_regex

  @doc """
  `true`: the deny categories ride on every spawn's argv as `--deny` /
  `--disallowed-tools` (`Arbiter.Agents.Grok.Security`), and the per-worker HOME
  that would let an operator hook or settings file undercut them has no off
  switch (`ensure_home/1`).
  """
  @impl true
  def security_enforced?, do: true

  @doc """
  `:os_jail` when this spawn runs inside `Arbiter.Worker.Jail`
  (`default_argv/2` jails it), `:none` otherwise.
  """
  @impl true
  def write_confinement(%SecurityPolicy{} = policy) do
    with {:ok, _grok} <- resolve_executable(),
         :ok <- jail_blocker(policy) do
      :os_jail
    else
      _ -> :none
    end
  end

  @doc """
  Why a grok spawn under `policy` would run unjailed outside `:strict`, or
  `nil` when it is jailed, the CLI is absent, or the policy opted the sandbox
  off on purpose.
  """
  @impl true
  def write_jail_warning(%SecurityPolicy{} = policy) do
    with {:ok, _grok} <- resolve_executable(),
         true <- jail_eligible?(policy),
         {:error, reason} <- jail_blocker(policy) do
      "grok write jail unavailable (#{blocker_message(reason)}) — " <>
        if(policy.permissions.mode == :strict,
          do: ":strict dispatches of grok are refused",
          else: "writes are not confined to the worktree outside :strict"
        )
    else
      _ -> nil
    end
  end

  # grok has no per-workspace config map of its own (model and effort ride in
  # the dispatch opts), so there is nothing to seed.
  @impl true
  def prepare(_workspace, _opts \\ []), do: :ok

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    policy = security_policy(opts)

    with {:ok, grok} <- resolve_executable(),
         {:ok, _sandbox} <- Sandbox.module(policy),
         {:ok, _home} <- ensure_home(opts),
         {:ok, prompt_args} <- prompt_args(prompt, opts),
         command = [grok | prompt_args] ++ flags(opts) ++ security_flags(policy, opts),
         {:ok, command} <- maybe_jail(command, opts, policy) do
      {:ok, ["sh", "-c", launch_script(grok), "sh" | command]}
    end
  end

  # grok's headless `-p` never runs `GROK_AUTH_PROVIDER_COMMAND` on a cold
  # `GROK_HOME`: it answers "Not signed in" without asking (grok 1.0.25,
  # bd-8rvkqd). The command is only consulted to *refresh* a credential grok
  # already holds, and `grok login` is what hydrates one (an `auth.json` with
  # `auth_mode: external` and no refresh token). So when the broker's provider
  # command is wired in and this home has no `auth.json` yet, run `grok login`
  # first: it asks the broker for a token through the provider command, which
  # is the first (logged) token request of the run. A failed login prints its
  # output and the spawn goes on to die "Not signed in", which is an auth death
  # like any other. Runs in the spawn's own env, before the jail wraps grok.
  defp launch_script(grok) do
    """
    if [ -n "$GROK_AUTH_PROVIDER_COMMAND" ] && [ -n "$GROK_HOME" ] && [ ! -s "$GROK_HOME/auth.json" ]; then
      #{quote_sh(grok)} login < /dev/null > "$GROK_HOME/arbiter-login.log" 2>&1 || cat "$GROK_HOME/arbiter-login.log" >&2
    fi
    exec "$@" < /dev/null
    """
  end

  defp quote_sh(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  @impl true
  def spawn_env(opts \\ []) do
    home_env =
      case ConfigDir.env(opts) do
        {:ok, env} -> env
        {:error, _} -> []
      end

    scrubbed = Enum.map(@credential_vars, &{&1, false})

    credential_opts =
      case List.keyfind(home_env, "GROK_HOME", 0) do
        {_, grok_home} -> Keyword.put(opts, :grok_home, grok_home)
        nil -> opts
      end

    merge_env(scrubbed ++ @static_env ++ home_env, Credential.env(credential_opts))
  end

  # Later pairs win, so the credential seam can replace a scrubbed var.
  defp merge_env(base, overrides) do
    overridden = MapSet.new(overrides, &elem(&1, 0))
    Enum.reject(base, fn {k, _} -> MapSet.member?(overridden, k) end) ++ overrides
  end

  @doc """
  `grok models` (0 tokens). grok can print "You are not authenticated." on the
  first call after the access token expired, while it refreshes, and answer
  normally on the second, so the probe retries once; `models` exits 0 either
  way, so the script turns a still-unauthenticated answer into exit 1 for
  `Arbiter.Worker.StopReason` to classify.
  """
  @impl true
  def auth_probe_argv(_opts \\ []) do
    with {:ok, grok} <- resolve_executable() do
      script = """
      out=$("$@" models 2>&1)
      case "$out" in *"not authenticated"*) sleep 2; out=$("$@" models 2>&1);; esac
      printf '%s\\n' "$out"
      case "$out" in *"not authenticated"*) exit 1;; esac
      """

      {:ok, ["sh", "-c", script, "sh", grok]}
    end
  end

  @impl true
  def resolved_model(opts \\ []) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  # `ClaudeSession` reads the session-config keys (task_id, topic, done_regex,
  # line_cap, ...) off the same map, so start from the shape the worker builds.
  @impl true
  def init_session(opts \\ []) do
    %{line_buf: "", output_lines: [], usage: %{}, activity: nil, activity_at: nil}
    |> Map.merge(
      ClaudeSession.build_session_config(
        Keyword.get(opts, :task_id),
        nil,
        provider: provider(),
        model: Keyword.get(opts, :model),
        redact_values: []
      )
    )
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    session = Map.put_new(session, :provider, provider())
    next = ClaudeSession.handle_data(session, line <> "\n", true)

    prev_len = length(Map.get(session, :output_lines, []))
    added = next.output_lines |> Enum.take(length(next.output_lines) - prev_len) |> Enum.reverse()

    {Enum.map(added, &{&1, arms_done?(&1)}), next}
  end

  # The session's own done detection (`ClaudeSession`) is exact; this flag is
  # the display-line approximation every adapter exposes: tool calls and
  # results, the session summary lines and error text never arm the sentinel.
  @non_arming_prefixes ["⏴ ", "⏵ ", "⚙ ", "grok error: "]

  defp arms_done?(line), do: not Enum.any?(@non_arming_prefixes, &String.starts_with?(line, &1))

  @impl true
  def usage_attrs(session),
    do: ClaudeSession.usage_summary(session) |> Map.put(:provider, provider())

  # ---- internals ---------------------------------------------------------

  defp resolve_executable do
    case System.find_executable("grok") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, {:executable_not_found, "grok"}}
    end
  end

  # No off switch: an un-isolated grok worker runs with the operator's hooks
  # and MCP servers.
  defp ensure_home(opts) do
    case ConfigDir.ensure(opts) do
      {:ok, home} -> {:ok, home}
      {:error, reason} -> {:error, {:grok_home_unavailable, reason}}
    end
  end

  defp prompt_args(prompt, opts) do
    if byte_size(prompt) > @max_prompt_argv_bytes do
      case ConfigDir.write_prompt_file(prompt, opts) do
        {:ok, file} -> {:ok, ["-p", "--prompt-file", file]}
        {:error, reason} -> {:error, {:prompt_file_failed, reason}}
      end
    else
      {:ok, ["-p", prompt]}
    end
  end

  # The deny baseline. An operator `deny` entry with no grok spelling is not
  # enforced, so say so: the other adapters drop theirs just as quietly.
  defp security_flags(policy, opts) do
    case Security.unmapped(policy) do
      [] ->
        :ok

      dropped ->
        Logger.warning(
          "grok has no equivalent for deny entries #{inspect(dropped)}; not enforced"
        )
    end

    Security.argv(policy, grok_home: ConfigDir.grok_home(opts))
  end

  # No `--sandbox`: the Worker.Jail is the confinement (see the moduledoc).
  defp flags(opts) do
    ["--output-format", "streaming-messages-json", "--always-approve", "--no-auto-update"] ++
      ["--max-turns", Integer.to_string(max_turns(opts))] ++
      model_flag(opts) ++ effort_flag(opts)
  end

  defp max_turns(opts) do
    case Keyword.get(opts, :max_turns) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_max_turns
    end
  end

  defp model_flag(opts) do
    case resolved_model(opts) do
      nil -> []
      model -> ["-m", model]
    end
  end

  defp effort_flag(opts) do
    case Keyword.get(opts, :effort) || Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> ["--effort", level]
      _ -> []
    end
  end

  # The jail is default-on in every mode, like agy's (bd-3s82pf). `:strict`
  # fails closed when it cannot run; the other modes fall back to running
  # unjailed (still HOME-isolated) rather than refusing.
  defp maybe_jail(command, opts, %SecurityPolicy{permissions: %{mode: mode}} = policy) do
    case jail_blocker(policy) do
      :ok -> wrap_in_jail(command, opts, policy, mode)
      {:error, reason} -> jail_unavailable(mode, command, reason)
    end
  end

  defp wrap_in_jail(command, opts, policy, mode) do
    home = ConfigDir.path(opts)

    jail_opts = [
      worktree: Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path),
      home: home,
      writable_paths: Map.get(policy.sandbox, :writable_paths, []),
      worktree_readonly: review_dispatch?(policy),
      hide_reads: true,
      env: [{"GROK_HOME", ConfigDir.grok_home(opts)} | @static_env]
    ]

    case Sandbox.wrap(policy, command, jail_opts) do
      {:ok, argv} -> {:ok, argv}
      {:error, reason} -> jail_unavailable(mode, command, reason)
    end
  end

  defp jail_unavailable(:strict, _command, reason),
    do: {:error, {:write_jail_unavailable, reason}}

  defp jail_unavailable(_mode, command, reason) do
    Logger.warning("grok write jail unavailable (#{inspect(reason)}); running unjailed")
    {:ok, command}
  end

  defp jail_blocker(%SecurityPolicy{} = policy) do
    cond do
      match?({:error, _}, Sandbox.module(policy)) ->
        {:error, "sandbox.backend #{SecurityPolicy.sandbox_backend(policy)} is not implemented"}

      not jail_eligible?(policy) ->
        {:error, "sandbox.enabled is false or sandbox.filesystem is not :worktree"}

      true ->
        with {:error, reason} <- Sandbox.status(policy),
             do: {:error, {:jail_probe_failed, reason}}
    end
  end

  defp jail_eligible?(%SecurityPolicy{sandbox: sandbox}),
    do: Map.get(sandbox, :enabled, true) and Map.get(sandbox, :filesystem, :worktree) == :worktree

  defp blocker_message({:jail_probe_failed, reason}) do
    case Jail.explain(reason) do
      %{message: message, fix: nil} -> message
      %{message: message, fix: fix} -> "#{message} — #{fix}"
    end
  end

  defp blocker_message(reason) when is_binary(reason), do: reason

  # A review dispatch carries the `Write` deny (`Dispatch.review_security_policy/2`):
  # the jail makes that an OS guarantee by binding the worktree read-only.
  defp review_dispatch?(%SecurityPolicy{permissions: %{deny: deny}}), do: "Write" in deny

  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end
end
