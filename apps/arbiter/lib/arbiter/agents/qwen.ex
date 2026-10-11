defmodule Arbiter.Agents.Qwen do
  @moduledoc """
  Qwen Code (`qwen`) adapter implementing `Arbiter.Agents.Agent` (bd-1cm12v, Q2
  of the bd-3km00p epic), modelled on `Arbiter.Agents.Grok`.

  qwen is a Gemini-CLI fork with a Claude-shaped headless stream, so this adapter
  is mostly argv and environment; parsing rides on `Arbiter.Worker.ClaudeSession`
  with `Arbiter.Agents.Qwen.Stream` absorbing the qwen quirks (tool names, the
  missing `result` line on budget exits, unknown-vs-zero usage) and mapping exit
  codes to `Arbiter.Worker.StopReason`.

  ## Argv

      qwen -p <prompt> -o stream-json --yolo --bare --auth-type openai \\
        --max-session-turns N [-m model]

  `--yolo` is required headless: nobody can answer an approval prompt (the
  permission layer is not the boundary, see `docs/worker-security.md`). The flags
  are the ones `Arbiter.Test.QwenCli` runs against the fixture server; qwen's
  flags churn quickly, so re-verify them with the harness on every qwen upgrade
  (`docs/qwen-test-harness.md`). The whole thing runs under
  `sh -c 'exec "$@" < /dev/null'`, so stdin is closed.

  ## Prompt delivery

  A prompt that fits one argv element goes inline as `-p`. A larger one would
  overflow the kernel's per-argument limit (E2BIG), so it is written to a
  temp file and fed on **stdin** (`qwen` with no `-p` and a non-TTY stdin reads
  the prompt from stdin): `sh -c 'f="$1"; shift; exec "$@" < "$f"' sh <file> qwen ...`.
  `prompt_tmpfile/1` recovers the path so the worker unlinks it on exit.

  ## Environment

  `NO_COLOR` and `QWEN_CODE_SUPPRESS_YOLO_WARNING` are set, and inherited
  `OPENAI_*` variables are removed from the spawn so the server's own
  credentials never reach a worker. The endpoint (`opts[:endpoint]`, a map with
  `:base_url` / `:api_key`) and model are re-added as `OPENAI_BASE_URL`,
  `OPENAI_API_KEY` and `OPENAI_MODEL`. The per-worker HOME, settings and
  telemetry/update switches are `Qwen.ConfigDir` (Q3); provider registration and
  routing are Q6.

  ## Security and the jail (Q5)

  **The jail is the boundary.** A headless qwen needs `--yolo`, and a qwen deny
  rule does not see through `bash -c`, so `Qwen.Security` (deny rules and tool
  removal, written into the read-only system settings) only steers the model.
  `default_argv/2` wraps qwen in `Arbiter.Worker.Jail`: read-only root, writable
  worktree and per-worker `$HOME`, the system settings directory bound read-only
  over that home, credential paths hidden, a pid namespace. A review dispatch
  (the policy denies `Write`) gets the worktree `--ro-bind`-ed, so a reviewer
  cannot write it however it tries. `:strict` fails closed when the jail cannot
  run; other modes fall back to running unjailed (still HOME-isolated) and
  `write_jail_warning/1` says so.

  The jail also runs in its own network namespace (`Qwen.Egress`): a local
  endpoint (Ollama on `127.0.0.1:11434`) is reached through a fixed-destination
  `egress_tunnels` bridge, a hosted one through the filtering proxy whose
  baseline is the endpoint's host, and every other connection is refused with a
  `403` and recorded. A run that dies on such a refusal is classified
  `:egress_denied`.

  ## Completion and failure

  Completion is the terminal `result` line plus the exit code; the `arb done`
  sentinel comes from assistant text, as for every provider. Exit 0 is success;
  41/42/44/52/53/54/55 are mapped by `Arbiter.Agents.Qwen.Stream.stop_reason/1`.
  Budget exits 53/55 emit **no** `result` line, so usage is summed from the
  per-message usage and survives them.

  ## Usage (Q7)

  `usage_attrs/1` normalises the stream's usage (qwen's `input_tokens` includes
  cache reads), reconciles it with the session JSONL at `opts[:session_file]`
  (`Qwen.SessionFile`, which also survives a killed run), and prices it from the
  endpoint (`Qwen.Usage.price/2`; unmetered endpoints record `0.0`). A sustained
  429 retry loop is turned into a provider hold by `Qwen.RetryHold`.

  ## Not here yet

  `splice_prompt/2` (nudge / `--resume`) is Q8; without it the worker treats the
  provider as "cannot be resumed in place".
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Qwen.ConfigDir
  alias Arbiter.Agents.Qwen.Egress, as: QwenEgress
  alias Arbiter.Agents.Qwen.Security
  alias Arbiter.Agents.Qwen.SessionFile
  alias Arbiter.Agents.Qwen.Stream, as: QwenStream
  alias Arbiter.Agents.Qwen.Usage
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Guardrails.Projection
  alias Arbiter.MCP.AgentConfig.Qwen, as: QwenMcp
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.Jail
  alias Arbiter.Worker.Sandbox
  alias Arbiter.Worker.Withholding

  require Logger

  @done_regex ~r/(?:\A|\n)[^\p{L}\p{N}\n]*arb done[^\p{L}\p{N}]*\z/u

  # Linux's per-argument execve limit (see `Arbiter.Agents.Claude`).
  @max_prompt_argv_bytes 131_072

  @default_max_turns 60

  @prompt_tmp_prefix "arb_qwen_prompt_"

  @inline_prompt_script ~s(exec "$@" < /dev/null)
  @stdin_prompt_script ~s(f="$1"; shift; exec "$@" < "$f")

  @static_env [
    {"NO_COLOR", "1"},
    {"QWEN_CODE_SUPPRESS_YOLO_WARNING", "1"}
  ]

  # Credential / endpoint channels an inherited server env must not hand a
  # worker; `endpoint_env/1` re-adds whichever the dispatch means to.
  @endpoint_vars ~w(OPENAI_API_KEY OPENAI_BASE_URL OPENAI_MODEL)

  @impl true
  def provider, do: "qwen"

  @impl true
  def done_sentinel, do: @done_regex

  @doc """
  `true`: the deny categories ride on every spawn's read-only system settings
  (`Arbiter.Agents.Qwen.Security`) and the per-worker HOME that would let an
  operator or repo settings file undercut them has no off switch. These are a
  permission layer; `write_confinement/1` says whether the jail backs them.
  """
  @impl true
  def security_enforced?, do: true

  @doc """
  `:os_jail` when this spawn runs inside `Arbiter.Worker.Jail`
  (`default_argv/2` jails it), `:none` otherwise.
  """
  @impl true
  def write_confinement(%SecurityPolicy{} = policy) do
    with {:ok, _qwen} <- resolve_executable(),
         :ok <- jail_blocker(policy) do
      :os_jail
    else
      _ -> :none
    end
  end

  @doc """
  `:os_jail` when the spawn is jailed and the host can build the network
  namespace (`--unshare-net`, the only route out is the egress proxy and the
  tunnels), `:none` otherwise.
  """
  @impl true
  def egress_confinement(%SecurityPolicy{} = policy) do
    if write_confinement(policy) == :os_jail and Sandbox.network_status(policy) == :ok,
      do: :os_jail,
      else: :none
  end

  @doc """
  Why a qwen spawn under `policy` would run unjailed outside `:strict`, or
  `nil` when it is jailed, the CLI is absent, or the policy opted the sandbox
  off on purpose.
  """
  @impl true
  def write_jail_warning(%SecurityPolicy{} = policy) do
    with {:ok, _qwen} <- resolve_executable(),
         true <- jail_eligible?(policy),
         {:error, reason} <- jail_blocker(policy) do
      "qwen write jail unavailable (#{blocker_message(reason)}) — " <>
        if(policy.permissions.mode == :strict,
          do: ":strict dispatches of qwen are refused",
          else: "writes are not confined to the worktree outside :strict"
        )
    else
      _ -> nil
    end
  end

  @impl true
  def prepare(_workspace, _opts \\ []), do: :ok

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    policy = security_policy(opts)

    with {:ok, qwen} <- resolve_executable(),
         {:ok, _sandbox} <- Sandbox.module(policy),
         {:ok, _home} <- ensure_home(policy, opts) do
      if byte_size(prompt) > @max_prompt_argv_bytes do
        with {:ok, tmp} <- write_prompt_tmpfile(prompt),
             {:ok, command} <- maybe_jail([qwen | flags(opts)], opts, policy) do
          {:ok, ["sh", "-c", @stdin_prompt_script, "sh", tmp | command]}
        end
      else
        with {:ok, command} <- maybe_jail([qwen, "-p", prompt | flags(opts)], opts, policy) do
          {:ok, ["sh", "-c", @inline_prompt_script, "sh" | command]}
        end
      end
    end
  end

  @doc """
  The stdin-delivery temp file of an argv built by `default_argv/2`, or `nil`
  for an inline-prompt argv. Lets the worker unlink it once the port exits.
  """
  @spec prompt_tmpfile([String.t()]) :: String.t() | nil
  def prompt_tmpfile(argv) when is_list(argv) do
    with ["sh", "-c", @stdin_prompt_script, "sh", path | _] <- argv,
         true <- String.starts_with?(Path.basename(path), @prompt_tmp_prefix) do
      path
    else
      _ -> nil
    end
  end

  @impl true
  def spawn_env(opts \\ []) do
    scrubbed = Enum.map(@endpoint_vars, &{&1, false})
    overrides = endpoint_env(opts)
    overridden = MapSet.new(overrides, &elem(&1, 0))

    Enum.reject(scrubbed, fn {k, _} -> MapSet.member?(overridden, k) end) ++
      @static_env ++ isolation_env(opts) ++ overrides
  end

  # The worker's own HOME / QWEN_HOME, read-only system settings and the
  # phone-home switches. A home that cannot be prepared still points at the
  # isolated path, never the operator's.
  defp isolation_env(opts) do
    case ConfigDir.env(opts) do
      {:ok, env} -> env
      {:error, _} -> ConfigDir.isolation_env(ConfigDir.path(opts), opts)
    end
  end

  # The home and the system settings (with the policy's deny rules) must exist
  # before the jail binds them. No off switch: an un-isolated qwen worker runs
  # with the operator's skills and MCP servers.
  defp ensure_home(policy, opts) do
    case Security.unmapped(policy) do
      [] ->
        :ok

      dropped ->
        Logger.warning(
          "qwen has no equivalent for deny entries #{inspect(dropped)}; not enforced"
        )
    end

    case ConfigDir.ensure(Keyword.put(opts, :security, policy)) do
      {:ok, home} -> {:ok, home}
      {:error, reason} -> {:error, {:qwen_home_unavailable, reason}}
    end
  end

  defp endpoint_env(opts) do
    endpoint = Keyword.get(opts, :endpoint) || %{}

    [
      {"OPENAI_BASE_URL", Map.get(endpoint, :base_url)},
      {"OPENAI_API_KEY", Map.get(endpoint, :api_key)},
      {"OPENAI_MODEL", resolved_model(opts)}
    ]
    |> Enum.filter(fn {_, v} -> is_binary(v) and v != "" end)
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
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil,
      endpoint: Keyword.get(opts, :endpoint),
      session_file: Keyword.get(opts, :session_file)
    }
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

  # Tool calls and results, the session summary lines and error text never arm
  # the sentinel (the session's own detection is exact; this is the display
  # approximation every adapter exposes).
  @non_arming_prefixes ["⏴ ", "⏵ ", "⚙ ", "qwen error: "]

  defp arms_done?(line), do: not Enum.any?(@non_arming_prefixes, &String.starts_with?(line, &1))

  @impl true
  def usage_attrs(session) do
    session
    |> ClaudeSession.usage_summary()
    |> Usage.normalize_stream()
    |> Usage.reconcile(SessionFile.read(Map.get(session, :session_file)))
    |> Usage.price(Map.get(session, :endpoint))
    |> Map.put(:provider, provider())
  end

  @doc "True when `status` is one of qwen's budget exits (53 turns, 55 tokens): no `result` line."
  @spec budget_exit?(term()) :: boolean()
  defdelegate budget_exit?(status), to: QwenStream

  # ---- internals ---------------------------------------------------------

  defp resolve_executable do
    case System.find_executable("qwen") do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, {:executable_not_found, "qwen"}}
    end
  end

  defp flags(opts) do
    ["-o", "stream-json", "--yolo", "--bare"] ++
      ["--auth-type", auth_type(opts)] ++
      ["--max-session-turns", Integer.to_string(max_turns(opts))] ++
      model_flag(opts) ++ QwenMcp.flags()
  end

  defp auth_type(opts) do
    case Keyword.get(opts, :auth_type) do
      t when is_binary(t) and t != "" -> t
      _ -> "openai"
    end
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

  # ---- the jail ----------------------------------------------------------

  # The jail is default-on in every mode, like grok's and agy's. `:strict`
  # fails closed when it cannot run; the other modes fall back to running
  # unjailed (still HOME-isolated) rather than refusing.
  defp maybe_jail(command, opts, %SecurityPolicy{permissions: %{mode: mode}} = policy) do
    case jail_blocker(policy) do
      :ok -> jail(command, opts, policy, mode)
      {:error, reason} -> jail_unavailable(mode, command, reason)
    end
  end

  defp jail(command, opts, policy, mode) do
    with {:ok, network} <- egress_network(opts, policy) do
      case Sandbox.wrap(policy, command, jail_opts(opts, policy, network)) do
        {:ok, argv} ->
          {:ok, argv}

        # The network side of the jail is not optional once it was asked for.
        {:error, reason} when network != nil ->
          if egress_error?(reason),
            do: {:error, {:egress_unavailable, reason}},
            else: jail_unavailable(mode, command, reason)

        {:error, reason} ->
          jail_unavailable(mode, command, reason)
      end
    end
  end

  defp jail_opts(opts, policy, network) do
    [
      worktree: worktree(opts),
      home: ConfigDir.path(opts),
      writable_paths: Map.get(policy.sandbox, :writable_paths, []),
      worktree_readonly: review_dispatch?(policy),
      # The settings (and so the deny rules) are not the worker's to rewrite:
      # its home is writable, this directory inside it is not.
      readonly_paths: [ConfigDir.system_settings_dir(opts)],
      hide_reads: true,
      env: [
        {"QWEN_HOME", ConfigDir.qwen_home(opts)},
        {"QWEN_CODE_SYSTEM_SETTINGS_PATH", ConfigDir.system_settings_path(opts)}
      ]
    ] ++ if(network, do: [network: network], else: [])
  end

  defp egress_error?({tag, _}) when tag in [:egress_socket_missing, :duplicate_bridge_port],
    do: true

  defp egress_error?(:socat_not_found), do: true
  defp egress_error?(_), do: false

  # The jail runs in a network namespace whose only way out is this run's proxy
  # and bridges. `{:ok, nil}` means "no network mode": the operator switched it
  # off (`:worker_jail_network`) or this host cannot (no `socat`, no netns), in
  # which case the filesystem jail still applies and `arb server doctor` fails
  # the host's network check. Once network mode applies, a proxy that cannot
  # start is an error and never a fallback to the shared network.
  defp egress_network(opts, policy) do
    with true <- Application.get_env(:arbiter, :worker_jail_network, true),
         :ok <- network_host_status(policy) do
      start_egress(opts, policy)
    else
      _ -> {:ok, nil}
    end
  end

  defp network_host_status(policy) do
    case Sandbox.network_status(policy) do
      :ok ->
        :ok

      {:error, reason} = error ->
        %{message: message} = Jail.explain_network(reason)

        Logger.warning(
          "qwen jail: network mode unavailable (#{message}); " <>
            "running with the filesystem jail on the shared network"
        )

        error
    end
  end

  defp start_egress(opts, policy) do
    plan = QwenEgress.plan(Keyword.get(opts, :endpoint), policy)
    projection = projection(opts)

    case JailRun.start(
           owner: Keyword.get(opts, :owner),
           task_id: Keyword.get(opts, :task_id),
           arb_token: Keyword.get(opts, :arb_token),
           safe_defaults_exclude: policy.permissions.safe_defaults_exclude,
           worktree: worktree(opts),
           infra: QwenEgress.baseline(plan, policy),
           enforce: QwenEgress.enforce?(),
           allow_local_dial: plan.allow_local_dial,
           grants: Withholding.grants(Keyword.get(opts, :task_id), projection),
           tunnels: plan.tunnels ++ Keyword.get(opts, :egress_tunnels, []) ++ projection.tunnels
         ) do
      {:ok, network, _run_id} -> {:ok, network}
      {:error, reason} -> {:error, {:egress_unavailable, reason}}
    end
  end

  defp projection(opts) do
    case Keyword.get(opts, :projection) do
      %Projection{} = projection -> projection
      _ -> Projection.unguarded()
    end
  end

  defp jail_unavailable(:strict, _command, reason),
    do: {:error, {:write_jail_unavailable, reason}}

  defp jail_unavailable(_mode, command, reason) do
    Logger.warning("qwen write jail unavailable (#{inspect(reason)}); running unjailed")
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

  defp worktree(opts), do: Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path)

  defp write_prompt_tmpfile(prompt) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        @prompt_tmp_prefix <> Integer.to_string(System.unique_integer([:positive])) <> ".txt"
      )

    with :ok <- File.write(tmp, prompt, [:exclusive]),
         :ok <- File.chmod(tmp, 0o600) do
      {:ok, tmp}
    else
      {:error, reason} -> {:error, {:prompt_tmpfile_failed, reason}}
    end
  end
end
