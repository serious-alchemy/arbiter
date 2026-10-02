defmodule Arbiter.Agents.Gemini do
  @moduledoc """
  Gemini agent adapter implementing `Arbiter.Agents.Agent`.

  Favors `agy` CLI binary, falling back to `gemini` CLI binary if `agy` is not on PATH.

  The two CLIs are not interchangeable — see `resolve_executable/0`. On the agy
  branch the spawn's security posture is split across
  `Arbiter.Agents.Gemini.Security` (argv + the generated settings document) and
  `Arbiter.Agents.Gemini.ConfigDir` (the isolated `$HOME` that document lands
  in, injected by `spawn_env/1`); the upstream `gemini` branch has no analogue
  of either (bd-7s29yq).
  """

  @behaviour Arbiter.Agents.Agent

  alias Arbiter.Agents.Gemini.Config
  alias Arbiter.Agents.Gemini.ConfigDir
  alias Arbiter.Agents.Gemini.Security
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.Worker.Egress.JailRun
  alias Arbiter.Worker.Jail

  require Logger

  @done_regex ~r/(?:\A|\n)[^\p{L}\p{N}\n]*arb done[^\p{L}\p{N}]*\z/u

  # The gemini-cli's own default model (`DEFAULT_GEMINI_MODEL`) — what the CLI
  # runs when we pass no `--model`. Used only to stamp the usage ledger /
  # dashboards via `resolved_model/1`; dispatch behaviour is unchanged.
  @default_model "gemini-2.5-pro"

  # bd-svczq4: the auth probe's prompt, and the two numbers that bound it. The
  # fraction keeps agy's own `--print-timeout` strictly inside the harness
  # watchdog so agy is always the one to yield; the fallback only applies to a
  # bare adapter call that names no watchdog, since `Arbiter.Agents.Preflight`
  # always threads one through.
  @probe_prompt "ping"

  # `Jail.wrap/2` network-side refusals: these must fail the spawn.
  @egress_errors [:egress_socket_missing, :duplicate_bridge_port]

  # The hosts agy itself needs from inside the jail (bd-cfktou). Recorded from
  # a learn-mode run; see `egress_infra/0`.
  @egress_infra []
  @probe_timeout_fraction_pct 80
  @probe_fallback_watchdog_ms 120_000

  @impl true
  def provider, do: "gemini"

  @doc """
  Whether this host's Gemini-family spawn actually enforces the resolved
  `Arbiter.Agents.SecurityPolicy` (bd-7s29yq / T6b).

  True only when **both** halves of the seam are present:

    * the CLI on `PATH` is `agy` — the upstream `gemini` CLI has no analogue of
      `permissions.allow/deny` and still runs with whatever posture it
      inherits, so it answers `false`; and
    * worker config isolation is on (`Arbiter.Agents.Gemini.ConfigDir.enabled?/0`)
      — agy reads its posture only from `$HOME/.gemini/antigravity-cli/settings.json`,
      so without an Arbiter-owned `$HOME` there is nowhere to put the generated
      document and the spawn silently inherits the operator's
      `always-proceed`-with-no-deny-list file. That is precisely the state
      bd-7s29yq found, and the REST posture surface must keep showing it as
      *not* enforced.

  When both hold, `permissions.deny` is a hard block in every mode — confirmed
  live, including under `--dangerously-skip-permissions`; see
  `Arbiter.Agents.Gemini.Security`'s moduledoc for the probe results and for
  the two things agy does *not* enforce.
  """
  @impl true
  def security_enforced? do
    match?({:ok, {:agy, _}}, resolve_executable()) and ConfigDir.enabled?()
  end

  @doc """
  `:os_jail` when this spawn runs inside the bubblewrap write jail
  (`Arbiter.Worker.Jail`, bd-5gvqgc), `:none` otherwise
  (`docs/design/agy-strict-write-isolation.md`).

  No agy setting confines every write. agy's `write_file(...)` rules gate its
  native `write_to_file` only as literal path prefixes, with its own `/tmp`
  exception (bd-f8f9ln), a shell write through an allowed command is never
  checked against them, and the upstream `gemini` CLI has no allow/deny
  mechanism at all. `security_enforced?/0` above is about the *deny-list* contract, a
  separate claim. So the only confinement is the kernel's, and it applies
  exactly when `default_argv/2` jails the spawn: `sandbox.enabled` is on,
  `sandbox.filesystem` is `:worktree` (the base default — bd-3s82pf makes the
  jail default-on for agy in **every** mode, not just `:strict`), the CLI is
  agy, the isolated agy `$HOME` is on (it is the one writable place agy keeps
  its own state) and the host passes the jail's probe (`Jail.available?/0`).
  Outside `:strict`, a host that fails the probe or has isolation disabled
  just runs unjailed (`:none`) rather than refusing — only `:strict` fails
  closed (see `jail_blocker/1`).
  """
  @impl true
  def write_confinement(%SecurityPolicy{} = policy) do
    with {:ok, {:agy, _}} <- resolve_executable(),
         :ok <- jail_blocker(policy) do
      :os_jail
    else
      _ -> :none
    end
  end

  @doc """
  Why this host can't jail an agy spawn under `policy`, for `arb server
  doctor` / the workspace posture API (bd-3s82pf). `nil` when the resolved
  CLI isn't agy (nothing to jail), the policy opted the sandbox off on
  purpose (`sandbox.enabled: false` / `filesystem: :none` — a deliberate
  choice, not a degraded state), or the jail actually applies. Non-nil
  precisely when `default_argv/2` would run this spawn unjailed outside
  `:strict` (see `jail_blocker/1`) — the gap `write_confinement/1` alone
  can't distinguish from "not applicable".
  """
  @impl true
  def write_jail_warning(%SecurityPolicy{} = policy) do
    with {:ok, {:agy, _}} <- resolve_executable(),
         true <- jail_eligible?(policy),
         {:error, reason} <- jail_blocker(policy) do
      "agy write jail unavailable (#{jail_blocker_message(reason)}) — " <>
        jail_unavailable_effect(policy)
    else
      _ -> nil
    end
  end

  # `:strict` fails dispatch closed rather than falling back to unconfined
  # (`jail_blocker/1` refuses it, see `default_argv/2`'s `maybe_jail/4`), so
  # the warning text must not claim writes just run unconfined there — that's
  # only true outside `:strict` (bd-8xy1mf).
  defp jail_unavailable_effect(%SecurityPolicy{permissions: %{mode: :strict}}),
    do: ":strict dispatches of agy are refused"

  defp jail_unavailable_effect(_policy),
    do: "writes are not confined to the worktree outside :strict"

  # `jail_blocker/1`'s own reasons (sandbox off, isolated HOME off) are already
  # human strings; `{:jail_probe_failed, reason}` wraps a raw `Jail.status/0`
  # reason, which `Jail.explain/1` turns into the same cause + fix `arb server
  # doctor` shows (bd-8xy1mf) instead of an opaque `inspect/1`.
  defp jail_blocker_message({:jail_probe_failed, reason}) do
    case Jail.explain(reason) do
      %{message: message, fix: nil} -> message
      %{message: message, fix: fix} -> "#{message} — #{fix}"
    end
  end

  defp jail_blocker_message({:jail_network, reason}) do
    %{message: message, fix: fix} = Jail.explain_network(reason)
    if fix, do: "#{message} — #{fix}", else: message
  end

  defp jail_blocker_message(reason) when is_binary(reason), do: reason
  defp jail_blocker_message(reason), do: inspect(reason)

  @impl true
  def done_sentinel, do: @done_regex

  @impl true
  def default_argv(prompt, opts \\ []) when is_binary(prompt) do
    case resolve_executable() do
      {:ok, {type, exec}} ->
        policy = security_policy(opts)
        inner = build_argv(type, exec, prompt, opts, policy)

        # The jail sits between `sh` and the CLI, so the element before `-p`
        # is still the CLI and `splice_prompt/2` (resume, nudge) is unchanged.
        with {:ok, command} <- maybe_jail(type, inner, opts, policy) do
          {:ok, ["sh", "-c", ~s(exec "$@" < /dev/null), "sh" | command]}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def auth_probe_argv(opts \\ []) do
    # Cheap token-validity probe for whichever CLI is on PATH. A bad/expired key
    # makes Gemini print "API key not valid" / "RESOURCE_EXHAUSTED" (or 401) and
    # exit non-zero — classified by Arbiter.Worker.StopReason.
    #
    # bd-481sz7 AC3: without `--output-format stream-json` the probe's stdout
    # is plain text `Arbiter.Agents.Gemini.Stream` can't parse for usage, so
    # every preflight row landed with zero tokens even on a healthy probe —
    # the same root cause bd-2fzwlc found on the main spawn path.
    #
    # bd-svczq4: the word "ping" is not a ping to an agentic CLI. This probe
    # runs with tools enabled and an Arbiter-worker `GEMINI.md` in its isolated
    # HOME, and a measured run answered it with 21 model calls over 102s — well
    # past the harness watchdog, which then reported a hang that had not
    # happened. Without a `--print-timeout` agy runs on its own 5-minute
    # print-mode default, so nothing makes agy yield before the harness gives
    # up and no exit status is ever observed. Deriving one from the harness
    # watchdog makes agy the first to yield and report a real status.
    case resolve_executable() do
      {:ok, {:agy, exec}} ->
        {:ok,
         ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", exec, "-p", @probe_prompt] ++
           output_format_flag() ++ probe_print_timeout_flag(opts)}

      {:ok, {:gemini, exec}} ->
        # Upstream `gemini` has no `--print-timeout` (see `print_timeout_flag/1`);
        # the harness watchdog stays its only bound.
        {:ok,
         ["sh", "-c", ~s(exec "$@" < /dev/null), "sh", exec, "-p", @probe_prompt] ++
           output_format_flag()}

      {:error, _} = err ->
        err
    end
  end

  # agy's own turn budget for a probe, kept strictly *inside* the harness
  # watchdog (`Arbiter.Agents.Preflight.timeout_ms/2`, threaded in as
  # `:timeout_ms`) so agy always yields first and the harness sees a real exit
  # status instead of having to guess from silence. A bare adapter call that
  # names no watchdog still gets a bound — never agy's 5-minute default.
  defp probe_print_timeout_flag(opts) do
    watchdog =
      case Keyword.get(opts, :timeout_ms) do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> @probe_fallback_watchdog_ms
      end

    seconds = max(div(watchdog * @probe_timeout_fraction_pct, 100 * 1000), 1)
    ["--print-timeout", "#{seconds}s"]
  end

  @doc """
  Env pairs for an agy/gemini spawn.

  Besides the API key and thinking level, this injects the isolated `HOME`
  (`Arbiter.Agents.Gemini.ConfigDir`) that carries the generated agy permission
  posture and the Arbiter-owned `GEMINI.md` — without it agy reads the
  operator's own `~/.gemini` (bd-7s29yq). Pass the spawn's `:worktree` (or
  `:worktree_path`) and `:security` policy so the right directory and posture
  are prepared; a caller with neither still gets an isolated (default-policy)
  HOME rather than the operator's.
  """
  @impl true
  def spawn_env(opts \\ []) do
    api_key_env(opts) ++ thinking_env(opts) ++ home_env(opts)
  end

  # Only the agy fork reads its config from $HOME; the upstream gemini CLI
  # keeps its own state there too, and redirecting HOME for it would buy
  # nothing while risking its auth. Gate on the resolved executable.
  defp home_env(opts) do
    case resolve_executable() do
      {:ok, {:agy, _}} -> ConfigDir.env(opts)
      _ -> []
    end
  end

  defp api_key_env(opts) do
    case Keyword.get(opts, :api_key) || Config.resolve_api_key() do
      key when is_binary(key) and key != "" ->
        [
          {"GEMINI_API_KEY", key},
          {"GOOGLE_GENAI_API_KEY", key}
        ]

      _ ->
        []
    end
  end

  defp thinking_env(opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_env(level)
      _ -> []
    end
  end

  # bd-bxwsvo: the bd-apq1g6 re-run on agy 1.2.12 settled how a long command
  # can be waited on. `Blocking` is not a `run_command` parameter at all (agy
  # drops it silently) and `WaitMsBeforeAsync` caps at 10000 ms, so there is no
  # synchronous form for anything longer. But headless agy now keeps the session
  # alive after the turn ends — for up to 30m — while a background task runs,
  # and wakes the agent with a completion system message ("... finished with
  # result ..."); two probes waited that way with zero polls. The previous text
  # here said the opposite ("keep calling `manage_task status` … never end the
  # turn"), and that is what made bd-90kjvk's worker poll ~440 times and burn
  # 84% of a Gemini 5h window on one D1. So: launch, end the turn, resume on
  # the message. The version is named in the text so the next agy upgrade that
  # changes this is visibly out of date rather than silently wrong.
  # bd-buefg4: bd-2zjtca (agy D1, 6648 s / 3.19M tokens) read one 355-line file
  # in full 50 times, ~15 back to back with no edit between — every full
  # `view_file` re-adds the whole file to context. `Gemini.RereadDetector`
  # watches for it; this is the prompt-side half.
  @doc "The agy-only file-reading rule rendered in the work prompt."
  @spec file_reading_instruction() :: String.t()
  def file_reading_instruction do
    """
    *** READING FILES: every full `view_file` re-adds the whole file to your
    context and costs tokens and time on every later turn.
      * Do NOT re-read a file you have already read unless you have edited it
        since, or you need a different line range. Trust what you saw.
      * Once you know where you are working, `view_file` a line range
        (`StartLine`/`EndLine`), not the whole file.
      * Search first: `grep`/`grep_search` for the symbol or text, then read
        only the lines around the hit.
    """
  end

  @impl true
  def async_tool_instruction do
    async_tool_instruction(
      "your VERDICT",
      "a VERDICT issued while a background task is still running is invalid,\n" <>
        "you would be judging on incomplete evidence",
      commit_first: false
    )
  end

  @impl true
  def async_tool_instruction(completion_signal, coda \\ nil, opts \\ []) do
    tail =
      case coda do
        nil -> "before you print #{completion_signal}."
        extra -> "before you print #{completion_signal} —\n#{extra}."
      end

    commit_bullet =
      if Keyword.get(opts, :commit_first, true) do
        """
          * COMMIT correct work BEFORE running any long verification. Verification
            confirms work; it must never be the thing that loses it.
        """
      else
        ""
      end

    """
    *** ASYNC TOOLS (agy 1.2.12): `run_command` waits at most
    `WaitMsBeforeAsync` (capped at 10000 ms) for a command, then moves it to the
    background. Long commands — `mix test`, `mix precommit`, `mix dialyzer`,
    `git push` — will always go to the background. That is expected, and this is
    how to wait for them:

    #{commit_bullet}\
      * Launch the command with `run_command`, then end your turn. This
        headless session stays alive while a background task runs (for up to
        30 minutes) and agy wakes you with a system message saying the task
        finished with result: read that result, then carry on. This is the
        one exception to "a turn with no tool call ends the session": it holds
        only while a task you launched is still running. With nothing running,
        ending your turn still ends the session.
      * Do NOT poll. No `manage_task` status calls, no re-reading the task's
        log, no `sleep` loops while it runs — each one costs a full model turn
        and changes nothing.
      * A command that needs longer than 30 minutes is killed when agy gives up
        waiting. Narrow it instead: run the test files you changed rather than
        the whole suite.

    You MUST read every command's full output #{tail}\
    """
  end

  # bd-1zz5mn: agy's OWN markers for "a tool call went async and the turn
  # ended before it drained". None of these match the Claude CLI's wording,
  # so the shared Claude-shaped signature never fired for agy and every one of
  # these early-quits was misclassified as a plain `:exited_without_done`.
  #
  # bd-bxwsvo: on agy 1.2.12 ending a turn with a background task running is
  # legitimate — the CLI waits (up to 30m, "root agent idle; waiting up to …")
  # and wakes the agent, so that idle line is deliberately NOT a marker. What
  # still means an abandoned wait is the CLI giving up and killing the task on
  # exit ("terminating N background task(s) on exit", from its stderr). The
  # launch step's own "Step is still running." / "Status: RUNNING" were markers
  # before 1.2.12 but are dropped: every long command now backgrounds, so they
  # open every correct wait too, and would misread an unrelated early quit
  # after an honoured wait as an abandoned one.
  @async_arm_signature ~r/
      was[ _]canceled[ _]with[ _]result:[ _]tool[ _]execution[ _]was[ _]canceled
    | terminating[ _]\d+[ _]background[ _]task\(s\)[ _]on[ _]exit
  /ix

  @impl true
  def async_arm_signature, do: @async_arm_signature

  @impl true
  def init_session(_opts \\ []) do
    %{
      line_buf: "",
      output_lines: [],
      usage: %{},
      activity: nil,
      activity_at: nil
    }
  end

  @impl true
  def parse_line(session, line) when is_binary(line) do
    # Gemini and agy print output line-by-line. Since they may output plain text
    # or json, we support basic text streaming fallback: treat each line as a
    # raw output line.
    next = Map.update!(session, :output_lines, &[line | &1])
    {[{line, !tool_result_line?(line)}], next}
  end

  @impl true
  def usage_attrs(session) do
    Map.get(session, :usage, %{})
    |> Map.put(:provider, provider())
  end

  # The gemini / agy CLI emits no stream-json `init` event the worker can read
  # the model from (unlike Claude), so we resolve it up front for the ledger /
  # dashboards. Mirrors `resolve_model/1` (explicit `:model` → tier → workspace
  # `active_model`) but adds a concrete terminal fallback: when nothing is
  # configured the CLI defaults to `gemini-2.5-pro` (`DEFAULT_GEMINI_MODEL` in
  # the gemini-cli), so recording that is accurate even though we pass no
  # `--model` flag in that case.
  #
  # bd-d2yut8: agy does accept `--model` (bd-2fzwlc's "agy has no overlapping
  # model catalogue" read only applied to the *upstream-gemini* ids this
  # module tried first; agy has its own catalogue, now covered by
  # `Config.default_tier_models(:agy)`). So agy runs the same explicit →
  # tier → workspace `active_model` chain as the gemini branch, just against
  # its own tier map — no more forced-`nil` short-circuit. There is still no
  # known agy-CLI default to fall back to when nothing resolves (unlike
  # gemini-cli's documented `DEFAULT_GEMINI_MODEL`), so that terminal
  # fallback stays gemini-only.
  @impl true
  def resolved_model(opts \\ []) do
    case resolve_executable() do
      {:ok, {:agy, _}} ->
        resolve_model(:agy, opts)

      _ ->
        resolve_model(:gemini, opts) || @default_model
    end
  end

  # ---- Internals ---------------------------------------------------------

  defp tool_result_line?(line) when is_binary(line),
    do: String.starts_with?(line, "⏴ ")

  defp tool_result_line?(_), do: false

  # Splice `insert` (a nudge/resume prompt, see the two shapes below) into a
  # stashed `default_argv/2` invocation. Both the `:agy` and `:gemini`
  # branches build argv as `[…, exec, "-p", prompt, flags…]` (no `--`
  # separator, no `--print` name — see `build_argv/5` above), so the prompt
  # slot is always the element right after `"-p"`; only the resume
  # (`--conversation`) translation differs between the two CLIs.
  #
  # `["--resume", session_id, prompt]` → the worker's resume insert. Only
  # `agy` accepts a `--conversation <id>` flag (bd-b7e33c); the upstream
  # `gemini` CLI has no session-resume mechanism at all, so that branch
  # returns an explicit error instead of emitting an invocation `gemini`
  # would reject or silently misinterpret. `--print-timeout`/`--model`/
  # `--effort` (and every other flag) are left exactly where they were —
  # only the prompt is swapped and `--conversation <id>` is inserted right
  # after it.
  #
  # `[nudge]` → a gate-nudge swap-in: only the prompt changes, on either
  # branch.
  #
  # Returns `{:error, :no_print_slot}` when `argv` has no `"-p"` flag at all
  # (test fixtures / custom commands).
  @doc false
  def splice_prompt(argv, insert) when is_list(argv) and is_list(insert) do
    case Enum.find_index(argv, &(&1 == "-p")) do
      nil ->
        {:error, :no_print_slot}

      idx ->
        {head, [_old_prompt | tail]} = Enum.split(argv, idx + 1)
        exec = Enum.at(head, -2)

        case insert do
          ["--resume", session_id, prompt] ->
            if agy_executable?(exec) do
              {:ok, head ++ [prompt, "--conversation", session_id] ++ tail}
            else
              {:error, :resume_unsupported}
            end

          [nudge] ->
            {:ok, head ++ [nudge] ++ tail}
        end
    end
  end

  defp agy_executable?(exec) when is_binary(exec), do: Path.basename(exec) == "agy"
  defp agy_executable?(_), do: false

  @doc """
  Which Gemini-family CLI this host will actually run, and where.

  Returns `{:ok, {:agy, path}}` when the Antigravity fork is on `PATH` (it wins),
  `{:ok, {:gemini, path}}` for the upstream CLI, or
  `{:error, {:executable_not_found, "agy or gemini"}}` when neither is installed.

  Public because the two CLIs do not share a config format: which one is on
  `PATH` decides whether a worktree-local MCP config is even readable
  (`Arbiter.MCP.AgentConfig.Gemini`, bd-m8geh4). Also public so
  `Arbiter.Quota.provider_code/1` (bd-7qj58o) can key the quota-gate lookup
  off the same PATH probe instead of duplicating it and risking drift.
  """
  @spec resolve_executable() ::
          {:ok, {:agy | :gemini, String.t()}} | {:error, {:executable_not_found, String.t()}}
  def resolve_executable do
    case System.find_executable("agy") do
      path when is_binary(path) ->
        {:ok, {:agy, path}}

      nil ->
        case System.find_executable("gemini") do
          path when is_binary(path) ->
            {:ok, {:gemini, path}}

          nil ->
            {:error, {:executable_not_found, "agy or gemini"}}
        end
    end
  end

  # bd-3s82pf: the jail is default-on for agy in every mode, keyed on the same
  # `sandbox.enabled` / `sandbox.filesystem: :worktree` base default the rest
  # of the policy already uses — not just `:strict`. The escape agy's own
  # `write_to_file` leaves open is identical in `:bypass`/`:auto` (bd-ca7xko).
  # `:strict` still fails closed when the jail can't run (never falls back to
  # agy's own unenforced write confinement, and this is the same condition
  # `write_confinement/1` reports to the dispatch gate, bd-1abj7u — refusing
  # here too covers a caller that reaches the adapter without the gate).
  # `:auto`/`:bypass` fall back to running unjailed instead of refusing,
  # since jailing there is a hardening on top of an already-accepted posture,
  # not something dispatch has ever gated on.
  defp maybe_jail(:gemini, _command, _opts, %SecurityPolicy{permissions: %{mode: :strict}}),
    do:
      {:error,
       {:write_jail_unavailable,
        "the upstream gemini CLI keeps its state in the operator's $HOME and cannot be jailed"}}

  defp maybe_jail(:gemini, command, _opts, _policy), do: {:ok, command}

  defp maybe_jail(:agy, command, opts, %SecurityPolicy{permissions: %{mode: mode}} = policy) do
    case jail_blocker(policy) do
      :ok ->
        with {:ok, network} <- egress_network(opts, policy) do
          wrap_in_jail(command, opts, policy, mode, network)
        end

      {:error, reason} ->
        jail_unavailable(mode, command, reason)
    end
  end

  defp wrap_in_jail(command, opts, policy, mode, network) do
    jail_opts =
      [
        worktree: Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path),
        home: ConfigDir.path(opts),
        writable_paths: Map.get(policy.sandbox, :writable_paths, []),
        worktree_readonly: review_dispatch?(policy),
        keyring: ConfigDir.keyring_available?()
      ] ++ if(network, do: [network: network], else: [])

    case Jail.wrap(command, jail_opts) do
      {:ok, argv} ->
        {:ok, argv}

      # The network side of the jail is not optional once it was asked for.
      {:error, reason} when is_tuple(reason) and elem(reason, 0) in @egress_errors ->
        {:error, {:egress_unavailable, reason}}

      {:error, :socat_not_found} ->
        {:error, {:egress_unavailable, :socat_not_found}}

      {:error, reason} ->
        jail_unavailable(mode, command, reason)
    end
  end

  # bd-cfktou (G6): the jail runs in a network namespace whose only way out is
  # this run's proxy and bridges. `{:ok, nil}` means "no network mode": the
  # operator switched it off (`:worker_jail_network`), or this host cannot
  # (no `socat`, no netns), in which case the filesystem jail still applies, as
  # it did before, and `arb server doctor` fails the host's network check.
  # Once network mode applies, a proxy that cannot start is an error and never
  # a fallback: running anyway would mean running on the shared network.
  defp egress_network(opts, policy) do
    with true <- Application.get_env(:arbiter, :worker_jail_network, true),
         :ok <- network_host_status() do
      start_egress(opts, policy)
    else
      _ -> {:ok, nil}
    end
  end

  defp network_host_status do
    case Jail.network_status() do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning(
          "agy jail: network mode unavailable (#{jail_blocker_message({:jail_network, reason})}); " <>
            "running with the filesystem jail on the shared network"
        )

        error
    end
  end

  defp start_egress(opts, _policy) do
    worktree = Keyword.get(opts, :worktree) || Keyword.get(opts, :worktree_path)

    case JailRun.start(
           owner: Keyword.get(opts, :owner),
           worktree: worktree,
           infra: @egress_infra,
           tunnels: Keyword.get(opts, :egress_tunnels, [])
         ) do
      {:ok, network, _run_id} -> {:ok, network}
      {:error, reason} -> {:error, {:egress_unavailable, reason}}
    end
  end

  defp jail_unavailable(:strict, _command, reason),
    do: {:error, {:write_jail_unavailable, reason}}

  defp jail_unavailable(_mode, command, _reason), do: {:ok, command}

  # Why agy can't be jailed under `policy` on this host, or `:ok`. Independent
  # of `permissions.mode` — the eligibility test is the sandbox base default
  # (`enabled` + `filesystem: :worktree`), the same one every other mode
  # already resolves through.
  defp jail_blocker(%SecurityPolicy{} = policy) do
    cond do
      not jail_eligible?(policy) ->
        {:error, "sandbox.enabled is false or sandbox.filesystem is not :worktree"}

      not ConfigDir.enabled?() ->
        {:error, "the isolated agy HOME (worker_isolate_config) is off"}

      true ->
        with {:error, reason} <- Jail.status(), do: {:error, {:jail_probe_failed, reason}}
    end
  end

  defp jail_eligible?(%SecurityPolicy{sandbox: sandbox}) do
    Map.get(sandbox, :enabled, true) and Map.get(sandbox, :filesystem, :worktree) == :worktree
  end

  # A worktree-backed review dispatch (`Dispatch.review_security_policy/2`)
  # unions `deny: ["Edit", "Write", "NotebookEdit"]` onto the policy. agy
  # enforces that as `write_file(/)` for its native writes (bd-f8f9ln), but not
  # for a shell write, so the jail binds the worktree `--ro-bind` instead
  # whenever it's present.
  defp review_dispatch?(%SecurityPolicy{permissions: %{deny: deny}}), do: "Write" in deny

  # The resolved `Arbiter.Agents.SecurityPolicy` for this spawn. Falls back to
  # the install-wide default so a bare adapter call is still safe.
  defp security_policy(opts) do
    case Keyword.get(opts, :security) do
      %SecurityPolicy{} = policy -> policy
      _ -> SecurityPolicy.default()
    end
  end

  # The agy branch's permission posture lives in TWO places and they must agree:
  # the argv fragment here (`Arbiter.Agents.Gemini.Security.permission_argv/1`)
  # and the generated `settings.json` that `Arbiter.Agents.Gemini.ConfigDir`
  # drops into the spawn's isolated `$HOME` (injected by `spawn_env/1`). The
  # settings document is the load-bearing half — it carries `toolPermission`
  # and the allow/deny rules; the flag is the part agy only accepts on the
  # command line. See `Arbiter.Agents.Gemini.Security` for the mode table.
  defp build_argv(:agy, exec, prompt, opts, %SecurityPolicy{} = policy) do
    [exec, "-p", prompt] ++
      Security.permission_argv(policy) ++
      agy_model_and_effort_argv(opts) ++ output_format_flag() ++ print_timeout_flag(opts)
  end

  # The upstream `gemini` CLI has no allow/deny mechanism and no settings file
  # we can generate, so its branches stay coarse: `:bypass` skips its own trust
  # and confirmation gates, `:auto`/`:strict` leave them on. Nothing here
  # enforces the policy's deny rules, which is why `security_enforced?/0`
  # answers `false` on a host where `gemini` (not `agy`) is the resolved CLI.
  defp build_argv(:gemini, exec, prompt, opts, %SecurityPolicy{permissions: %{mode: :bypass}}) do
    [exec, "-p", prompt, "--skip-trust", "-y"] ++
      model_flag(:gemini, opts) ++ thinking_flag(:gemini, opts) ++ output_format_flag()
  end

  defp build_argv(:gemini, exec, prompt, opts, _policy) do
    [exec, "-p", prompt] ++
      model_flag(:gemini, opts) ++ thinking_flag(:gemini, opts) ++ output_format_flag()
  end

  # Both the upstream `gemini` CLI and the `agy` fork support
  # `--output-format stream-json` (confirmed live against installed agy
  # v1.1.11 — bd-2fzwlc). Prior to bd-2fzwlc this flag was omitted on the
  # `:agy` branches on the mistaken belief that agy had no stream-json
  # support; in fact agy was being invoked in plain-text mode the whole time,
  # so every agy session emitted nothing `Arbiter.Agents.Gemini.Stream` could
  # parse — the root cause of every Gemini `usage_events` row carrying zero
  # tokens/cost, since `resolve_executable/0` prefers `agy` over `gemini`.
  defp output_format_flag, do: ["--output-format", "stream-json"]

  # bd-1xss5z: `agy` hard-codes a 5-minute `--print-timeout` on print-mode
  # turns — a review that reads ~300k tokens of diff/context routinely blows
  # past that, and agy responds by cutting the turn short and returning
  # partial output under a `SUCCESS` status (see
  # `Arbiter.Worker.StopReason`'s `:agent_print_timeout` category and
  # `Arbiter.Agents.Gemini.Stream`'s docs on agy's wire schema). Threading the
  # caller's own `:timeout_ms` (ReviewGate resolves it from
  # `review_gate.timeout_ms`, live, per pass) through as `--print-timeout`
  # gives agy a budget that actually matches the harness's own — the
  # alternative is agy timing out silently well inside a longer harness-level
  # deadline that never gets a chance to fire.
  #
  # Upstream `gemini` has no equivalent flag, so this is agy-only; the
  # `:gemini` branches never call it.
  defp print_timeout_flag(opts) do
    case Keyword.get(opts, :timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ["--print-timeout", "#{max(div(ms, 1000), 1)}s"]
      _ -> []
    end
  end

  # bd-d2yut8 Finding 2: model ids in the agy tier map carry their own effort
  # suffix (`-low`/`-medium`/`-high`, e.g. `gemini-3.1-pro-high`). Passing
  # `--effort` alongside such an id sends two conflicting effort signals with
  # undefined precedence in agy — the operator decision is "never both", so
  # `--effort` is only emitted for a suffix-free resolved model (or when no
  # model resolves at all).
  defp agy_model_and_effort_argv(opts) do
    model = resolve_model(:agy, opts)

    model_part =
      case model do
        nil -> []
        m -> ["--model", m]
      end

    effort_part = if effort_suffixed?(model), do: [], else: thinking_flag(:agy, opts)

    model_part ++ effort_part
  end

  defp effort_suffixed?(model) when is_binary(model),
    do: Regex.match?(~r/-(low|medium|high)$/, model)

  defp effort_suffixed?(_), do: false

  defp model_flag(executable, opts) do
    case resolve_model(executable, opts) do
      nil -> []
      model when is_binary(model) -> ["--model", model]
    end
  end

  defp resolve_model(executable, opts) do
    case Keyword.get(opts, :model) do
      m when is_binary(m) and m != "" ->
        m

      _ ->
        case Keyword.get(opts, :model_tier) do
          tier when is_binary(tier) and tier != "" ->
            Config.model_for_tier(tier, executable) || Config.active_model()

          _ ->
            Config.active_model()
        end
    end
  end

  defp thinking_flag(executable, opts) do
    case Keyword.get(opts, :thinking) do
      level when is_binary(level) and level != "" -> Config.thinking_argv(level, executable)
      _ -> []
    end
  end
end
