defmodule Arbiter.Accounts.LoginRunner do
  @moduledoc """
  Drives one provider CLI's **own** login inside a hidden `:login` tmux
  `Arbiter.Sessions.Session` (login relay 3/6, bd-c99hys, epic bd-dqvv90).

  Arbiter never speaks OAuth. A `LoginRunner` is a supervised process, one per
  in-flight login, that:

    1. creates the account's dedicated config dir
       (`<accounts_root>/<provider>-<slug>/`, mode 0700) and launches a
       `:login` Session on its own tmux socket running
       `<config_dir_env>=<dir> <recipe command + args>` in it
       (`Arbiter.Accounts.LoginRecipes`);
    2. polls the pane — `capture-pane -p -J` redirected **into a file** and read
       back (piping it straight to the BEAM sometimes returned nothing in the
       spike), then strips OSC-8/ANSI — and runs the recipe's extractors;
    3. walks the state machine

           :starting → :awaiting_user → :verifying → :succeeded
                                                   ↘ :failed | :timed_out | :cancelled

       where `:awaiting_user` carries the auth `url`, a `device_code` and/or
       `needs_paste?`, and every transition is broadcast as
       `{:login_state, login_id, snapshot}` to the **one private topic the
       requester supplied** (`:topic`) and nowhere else — no-leak rules are
       bd-2prmjm;
    4. relays an operator-pasted code to the pane (`relay_paste/2`);
    5. decides success **only** from the recipe's status command run in the
       same env (`claude auth status --json`, `codex login status`), never from
       screen text, and then hands off via the `:on_success` callback (child 4,
       bd-djh1yr) — after `Arbiter.Accounts.LoginCompletion` has recorded the
       credential reference, cleared the alerts and refreshed quota.

  ## Limits

    * **One active login per account** — the process is registered under
      `{:account, {provider, slug}}` in `Arbiter.Accounts.LoginRunner.Registry`,
      so a second `start_login/1` gets `{:error, :already_active}`. The runner
      stops after its terminal state, which releases the lock.
    * A **10 minute** timeout (`:timeout_ms`).
    * Cancelling, timing out, succeeding or failing kills the tmux session and
      ends the Session row. After a crash/restart,
      `Arbiter.Accounts.LoginRunner.Sweep` removes stale `arb-login-*` tmux
      sessions on boot.

  ## Pasted text never reaches an argv

  `ps` is world-readable, so a one-time code must not ride in the tmux command
  line. `tmux send-keys` has no stdin form, so the paste is written to a 0600
  file in the session's private dir, loaded with `load-buffer <file>`, delivered
  with `paste-buffer -d` (the same bytes a literal `send-keys -l` would type),
  and then `Enter` is sent. Only the file path is ever in an argv.

  ## Options (`start_login/1`)

    * `:provider`, `:account` — required. `account` is the slug
      (`[A-Za-z0-9][A-Za-z0-9_-]*`).
    * `:topic` — the requester's private PubSub topic. No topic, no broadcasts.
    * `:started_by` — who asked for the login, recorded in the Login history
      (`Arbiter.Accounts.LoginRecord`). `:completion_opts` — test seams for
      `Arbiter.Accounts.LoginCompletion.complete/2`.
    * `:on_success` — `fun/1` called with
      `%{login_id:, provider:, account:, config_dir:}` after the status command
      confirms the login. Exceptions are logged, never fatal.
    * `:timeout_ms` (default #{10 * 60_000}), `:poll_interval_ms` (500),
      `:status_interval_ms` (5000, how often a no-output flow such as codex
      device-auth re-asks the status command).
    * Test seams: `:recipe`, `:runner`, `:extra_env`, `:enter_delay_ms`.
  """

  use GenServer, restart: :temporary

  alias Arbiter.Accounts.LoginCompletion
  alias Arbiter.Accounts.LoginRecipe
  alias Arbiter.Accounts.LoginRecipes
  alias Arbiter.Accounts.LoginTranscript
  alias Arbiter.Config.Paths
  alias Arbiter.Sessions
  alias Arbiter.Sessions.Layout
  alias Arbiter.Sessions.Naming

  require Logger

  @registry Arbiter.Accounts.LoginRunner.Registry
  @supervisor Arbiter.Accounts.LoginRunner.Supervisor

  @default_timeout_ms 10 * 60_000
  @default_poll_interval_ms 500
  @default_status_interval_ms 5_000
  @max_input_bytes 4_096
  @redacted "[REDACTED]"

  # Credential env a login must not inherit from the server: a stray token in
  # the environment would make the CLI (and its status command) report the
  # server's identity instead of the account being logged in.
  @scrubbed_env ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN OPENAI_API_KEY)

  # Printed after the CLI exits so the pane (kept alive by the trailing sleep)
  # still carries its exit status, and the final screen can be read.
  @exit_marker "[arb-login-exit"
  @exit_regex ~r/\[arb-login-exit (\d+)\]/

  @terminal ~w(succeeded failed timed_out cancelled)a

  # Everything the operator or the CLI's auth flow put on screen is secret:
  # `inspect`/crash reports of the state (and any `:sys.get_state` dump) show
  # none of it.
  @derive {Inspect, except: [:url, :device_code, :extra_env, :pasted, :transcript]}
  defstruct [
    :id,
    :provider,
    :account,
    :recipe,
    :topic,
    :runner,
    :extra_env,
    :on_success,
    :started_by,
    :started_at,
    :completion_opts,
    :timeout_ms,
    :poll_interval_ms,
    :status_interval_ms,
    :enter_delay_ms,
    :config_dir,
    :session,
    :status,
    :url,
    :device_code,
    :needs_paste?,
    :reason,
    :last_status_check,
    :cleaned_up?,
    pasted: [],
    transcript: nil
  ]

  @type status ::
          :starting | :awaiting_user | :verifying | :succeeded | :failed | :timed_out | :cancelled

  @type snapshot :: %{
          id: String.t(),
          provider: atom(),
          account: String.t(),
          status: status(),
          url: String.t() | nil,
          device_code: String.t() | nil,
          needs_paste?: boolean(),
          reason: String.t() | nil,
          session_id: String.t() | nil
        }

  # -- API --------------------------------------------------------------------

  @doc """
  Start a login for `provider`/`account`. Returns the login id.

  `{:error, :already_active}` while one is running for the account;
  `:unsupported` / `:disabled` / `:unknown` per `LoginRecipes.fetch/1`;
  `:invalid_account` for a slug that is not a plain name.
  """
  @spec start_login(keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_login(opts) do
    provider = Keyword.fetch!(opts, :provider)
    account = Keyword.fetch!(opts, :account)

    with {:ok, base_recipe} <- LoginRecipes.fetch(provider),
         :ok <- validate_account(account) do
      id = Ash.UUID.generate()

      opts =
        opts
        |> Keyword.put(:id, id)
        |> Keyword.put_new(:recipe, base_recipe)

      case DynamicSupervisor.start_child(@supervisor, {__MODULE__, opts}) do
        {:ok, _pid} -> {:ok, id}
        {:error, {:already_started, _pid}} -> {:error, :already_active}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Type the operator's pasted code into the CLI's prompt and press Enter.
  Only valid in `:awaiting_user` with `needs_paste?`. `{:error, :invalid_input}`
  for anything but one printable line.
  """
  @spec relay_paste(String.t() | pid(), String.t()) ::
          :ok | {:error, :not_awaiting_code | :invalid_input | :relay_failed | :not_found}
  def relay_paste(login, text) when is_binary(text), do: call(login, {:relay_paste, text})

  @doc "Abort the login: kills the tmux session, ends in `:cancelled`."
  @spec cancel(String.t() | pid()) :: :ok | {:error, :not_found}
  def cancel(login), do: call(login, :cancel)

  @doc "The current snapshot of a live login."
  @spec state(String.t() | pid()) :: {:ok, snapshot()} | {:error, :not_found}
  def state(login), do: call(login, :state)

  @doc "Whether a login for `provider`/`account` is running."
  @spec active?(atom(), String.t()) :: boolean()
  def active?(provider, account),
    do: Registry.lookup(@registry, {:account, {provider, account}}) != []

  @doc """
  Whether `tmux` is installed — the doctor's input
  (`GET /api/server/tmux`, `arb server doctor`).
  """
  @spec tmux_diagnosis(keyword()) :: %{
          required(:available) => boolean(),
          optional(atom()) => term()
        }
  def tmux_diagnosis(opts \\ []) do
    case System.find_executable("tmux") do
      nil ->
        %{
          available: false,
          message: "tmux is not installed",
          fix:
            "Install tmux (e.g. `sudo dnf install tmux` or `sudo apt install tmux`); the " <>
              "dashboard login relay runs a provider CLI's login inside it."
        }

      path ->
        {out, _} = safe_run(Sessions.runner(opts), "tmux", ["-V"], [])
        %{available: true, path: path, version: String.trim(out)}
    end
  end

  @doc false
  def child_spec(opts), do: super(opts)

  def start_link(opts) do
    provider = Keyword.fetch!(opts, :provider)
    account = Keyword.fetch!(opts, :account)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {@registry, {:account, {provider, account}}}}
    )
  end

  defp call(login, message) do
    GenServer.call(via(login), message)
  catch
    :exit, {:noproc, _} ->
      {:error, :not_found}

    :exit, {:normal, _} ->
      {:error, :not_found}

    # A timeout/crash exit carries the call's message — for a relay, the paste.
    :exit, {reason, {GenServer, :call, [server, _message, timeout]}} ->
      exit({reason, {GenServer, :call, [server, @redacted, timeout]}})
  end

  defp via(pid) when is_pid(pid), do: pid
  defp via(id) when is_binary(id), do: {:via, Registry, {@registry, {:login, id}}}

  defp validate_account(account) when is_binary(account) do
    if account =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/,
      do: :ok,
      else: {:error, :invalid_account}
  end

  defp validate_account(_), do: {:error, :invalid_account}

  # -- GenServer --------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    {:ok, _} = Registry.register(@registry, {:login, id}, nil)

    provider = Keyword.fetch!(opts, :provider)
    account = Keyword.fetch!(opts, :account)

    state = %__MODULE__{
      id: id,
      provider: provider,
      account: account,
      recipe: Keyword.fetch!(opts, :recipe),
      topic: Keyword.get(opts, :topic),
      runner: Sessions.runner(opts),
      extra_env: Keyword.get(opts, :extra_env, []),
      on_success: Keyword.get(opts, :on_success),
      started_by: Keyword.get(opts, :started_by),
      started_at: DateTime.utc_now(),
      completion_opts: Keyword.get(opts, :completion_opts, []),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms),
      status_interval_ms: Keyword.get(opts, :status_interval_ms, @default_status_interval_ms),
      enter_delay_ms: Keyword.get(opts, :enter_delay_ms, 100),
      config_dir: Path.join(Paths.accounts_root(), "#{provider}-#{account}"),
      session: nil,
      status: :starting,
      url: nil,
      device_code: nil,
      needs_paste?: false,
      reason: nil,
      last_status_check: nil,
      cleaned_up?: false
    }

    {:ok, state, {:continue, :launch}}
  end

  @impl GenServer
  def handle_continue(:launch, state) do
    with :ok <- make_account_dir(state.config_dir),
         {:ok, session} <- launch(state) do
      state = %{state | session: session}
      Logger.info("login #{state.id} (#{state.provider}-#{state.account}): started")
      broadcast(state)
      Process.send_after(self(), :timeout, state.timeout_ms)
      send(self(), :poll)
      {:noreply, state}
    else
      {:error, reason} ->
        finish(state, :failed, "could not start the login: #{describe(reason)}")
    end
  end

  @impl GenServer
  def handle_call(:state, _from, state), do: {:reply, {:ok, snapshot(state)}, state}

  def handle_call(:cancel, _from, state) do
    {:stop, :normal, :ok, finish_state(state, :cancelled, "cancelled by the operator")}
  end

  def handle_call({:relay_paste, _text}, _from, %{status: status, needs_paste?: needs} = state)
      when status != :awaiting_user or not needs do
    {:reply, {:error, :not_awaiting_code}, state}
  end

  def handle_call({:relay_paste, text}, _from, state) do
    with :ok <- validate_input(text),
         state = %{state | pasted: [text | state.pasted]},
         :ok <- paste(state, text) do
      {:reply, :ok, transition(state, :verifying)}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = guarded_poll(state)

    if state.status in @terminal do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :poll, state.poll_interval_ms)
      {:noreply, state}
    end
  end

  def handle_info(:timeout, state) do
    minutes = div(state.timeout_ms, 60_000)
    reason = if minutes > 0, do: "timed out after #{minutes} minutes", else: "timed out"
    {:stop, :normal, finish_state(state, :timed_out, reason)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    cleanup(state)
    :ok
  end

  @impl GenServer
  def format_status(status) do
    status
    |> Map.update(:state, nil, &redact_state/1)
    |> Map.update(:message, nil, fn
      {:relay_paste, _} -> {:relay_paste, @redacted}
      other -> other
    end)
  end

  defp redact_state(%{} = state) do
    Map.merge(state, %{
      url: state.url && @redacted,
      device_code: state.device_code && @redacted,
      extra_env: @redacted,
      pasted: state.pasted != [] && @redacted,
      transcript: state.transcript && @redacted
    })
  end

  defp redact_state(other), do: other

  # -- launch -----------------------------------------------------------------

  defp make_account_dir(dir) do
    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, {:account_dir, reason}}
    end
  end

  defp launch(state) do
    Sessions.launch(
      kind: :login,
      login_account: "#{state.provider}-#{state.account}",
      config_dir: state.config_dir,
      cwd: state.config_dir,
      command: pane_command(state),
      # No provisioning (nothing seeded, no instructions, no MCP) and no
      # transcript capture: the pane carries the auth URL and one-time codes.
      provision: false,
      ensure_reader: false,
      cols: 200,
      rows: 50,
      runner: state.runner
    )
  end

  # `env -u <credential> … <CONFIG_DIR_ENV>=<dir> <command> <args>`, then the
  # exit status is printed and the pane parked so the final screen survives.
  defp pane_command(%{recipe: recipe} = state) do
    unset = Enum.flat_map(@scrubbed_env, &["-u", &1])

    assigns =
      Enum.map([{recipe.config_dir_env, state.config_dir} | state.extra_env], fn {k, v} ->
        "#{k}=#{shell_quote(v)}"
      end)

    argv = [shell_quote(recipe.command) | Enum.map(recipe.args, &shell_quote/1)]
    env = Enum.join(["env" | unset] ++ assigns ++ argv, " ")

    ~s(#{env}; arb_code=$?; printf '\\n#{@exit_marker} %s]\\n' "$arb_code"; sleep 900)
  end

  defp shell_quote(value), do: "'" <> String.replace(to_string(value), "'", "'\\''") <> "'"

  # -- polling ----------------------------------------------------------------

  # The raw pane text is an argument all the way down `poll/1`; a crash there
  # (a FunctionClauseError, say) would print it from the stacktrace. Re-raise
  # with the argument lists reduced to arities.
  defp guarded_poll(state) do
    poll(state)
  rescue
    e -> reraise scrub(e), scrub_stacktrace(__STACKTRACE__)
  end

  defp scrub(%FunctionClauseError{} = e), do: %{e | args: nil}
  defp scrub(e), do: e

  defp scrub_stacktrace(stacktrace) do
    Enum.map(stacktrace, fn
      {mod, fun, args, location} when is_list(args) -> {mod, fun, length(args), location}
      entry -> entry
    end)
  end

  defp poll(state) do
    case capture(state) do
      {:ok, text} -> state |> store_transcript(text) |> evaluate(text)
      :gone -> verify(state, true, nil)
    end
  end

  # Only the redacted screen is ever kept (and later stored): the raw pane text
  # lives in this call's stack frame alone.
  defp store_transcript(state, text) do
    secrets = [state.device_code | state.pasted]
    %{state | transcript: LoginTranscript.redact(text, state.recipe, secrets)}
  end

  defp evaluate(state, text) do
    recipe = state.recipe
    exit_code = exit_code(text)

    cond do
      LoginRecipe.failure?(recipe, text) ->
        finish_state(state, :failed, "the #{state.provider} CLI reported a failed login")

      exit_code != nil ->
        verify(state, true, exit_code)

      LoginRecipe.success?(recipe, text) ->
        verify(state, false, nil)

      true ->
        state |> observe(text) |> periodic_status()
    end
  end

  defp exit_code(text) do
    case Regex.run(@exit_regex, text) do
      [_, code] -> String.to_integer(code)
      _ -> nil
    end
  end

  # Fold what the screen shows into the state and promote :starting once there
  # is something for the operator to act on. Only before the paste: once the
  # code is relayed the screen is no longer a prompt.
  defp observe(%{status: status} = state, text) when status in [:starting, :awaiting_user] do
    scanned = scan(state, text)

    cond do
      state.status == :starting and ready?(scanned) -> transition(scanned, :awaiting_user)
      state.status == :awaiting_user and snapshot(scanned) != snapshot(state) -> announce(scanned)
      true -> scanned
    end
  end

  defp observe(state, _text), do: state

  defp scan(%{recipe: recipe} = state, text) do
    %{
      state
      | url: LoginRecipe.extract_url(recipe, text) || state.url,
        device_code: LoginRecipe.extract_device_code(recipe, text) || state.device_code,
        needs_paste?: LoginRecipe.awaiting_code?(recipe, text)
    }
  end

  defp ready?(state), do: state.url != nil and (state.needs_paste? or state.device_code != nil)

  # No-output flows (codex device-auth) print nothing when approval lands, so
  # ask the status command now and then while waiting.
  defp periodic_status(%{recipe: %{success_pattern: nil}, status: :awaiting_user} = state) do
    now = System.monotonic_time(:millisecond)

    if state.last_status_check == nil or now - state.last_status_check >= state.status_interval_ms do
      state = %{state | last_status_check: now}

      if status_ok?(state) do
        state |> transition(:verifying) |> finish_state(:succeeded, nil)
      else
        state
      end
    else
      state
    end
  end

  defp periodic_status(state), do: state

  # The CLI exited, or printed its success line: the status command decides —
  # screen text never does. A process that is gone and not logged in failed.
  defp verify(state, exited?, exit_code) do
    state = transition(state, :verifying)

    cond do
      status_ok?(state) -> finish_state(state, :succeeded, nil)
      exited? -> finish_state(state, :failed, failure_reason(exit_code))
      true -> state
    end
  end

  defp failure_reason(nil),
    do: "the login process ended and the status check does not show a logged-in account"

  defp failure_reason(code),
    do:
      "the login process exited with status #{code} and the status check does not show " <>
        "a logged-in account"

  # -- pane I/O ---------------------------------------------------------------

  defp private_dir(state) do
    dir = Layout.session_dir(state.session.id)
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    dir
  end

  # `capture-pane -p -J > file`, then read the file back. Piping the command's
  # stdout straight to the BEAM intermittently returned nothing in the spike.
  defp capture(state) do
    file = Path.join(private_dir(state), "pane.txt")
    File.rm(file)

    script = ~s(exec tmux -S "$1" capture-pane -p -J -t "$2" > "$3")

    case safe_run(
           state.runner,
           "sh",
           ["-c", script, "arb-capture", state.session.tmux_socket, tmux_name(state), file],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        case File.read(file) do
          {:ok, text} -> {:ok, text}
          {:error, _} -> :gone
        end

      _ ->
        :gone
    end
  end

  defp tmux_name(state), do: Naming.tmux_session(state.session)

  defp validate_input(text) do
    if text != "" and byte_size(text) <= @max_input_bytes and String.valid?(text) and
         not String.match?(text, ~r/[[:cntrl:]]/u) do
      :ok
    else
      {:error, :invalid_input}
    end
  end

  defp paste(state, text) do
    buffer = "arb-login-paste-#{state.id}"
    file = Path.join(private_dir(state), "paste-#{System.unique_integer([:positive])}")

    try do
      with :ok <- write_private(file, text),
           {_, 0} <- tmux(state, ["load-buffer", "-b", buffer, file]),
           {_, 0} <- tmux(state, ["paste-buffer", "-d", "-b", buffer, "-t", tmux_name(state)]),
           :ok <- enter(state) do
        :ok
      else
        _ ->
          _ = tmux(state, ["delete-buffer", "-b", buffer])
          {:error, :relay_failed}
      end
    after
      File.rm(file)
    end
  end

  defp enter(state) do
    if state.enter_delay_ms > 0, do: Process.sleep(state.enter_delay_ms)

    case tmux(state, ["send-keys", "-t", tmux_name(state), "Enter"]) do
      {_, 0} -> :ok
      _ -> :error
    end
  end

  defp tmux(state, args),
    do:
      safe_run(state.runner, "tmux", ["-S", state.session.tmux_socket | args],
        stderr_to_stdout: true
      )

  defp write_private(path, text) do
    with {:ok, io} <- File.open(path, [:write, :exclusive, :binary]),
         :ok <- File.chmod(path, 0o600),
         :ok <- IO.binwrite(io, text) do
      File.close(io)
    end
  end

  # -- status command ---------------------------------------------------------

  defp status_ok?(%{recipe: %{status_command: nil} = recipe} = state) do
    case recipe.status_fallback_file do
      nil -> false
      file -> File.exists?(Path.join(state.config_dir, file))
    end
  end

  defp status_ok?(%{recipe: %{status_command: [cmd | args]} = recipe} = state) do
    env =
      Enum.map(@scrubbed_env, &{&1, nil}) ++
        [{recipe.config_dir_env, state.config_dir} | state.extra_env]

    {out, code} = safe_run(state.runner, cmd, args, env: env)
    LoginRecipe.status_ok?(recipe, code, out)
  end

  defp safe_run(runner, command, args, opts) do
    runner.run(command, args, opts)
  rescue
    e -> {Exception.message(e), 127}
  end

  # -- state ------------------------------------------------------------------

  defp transition(%{status: status} = state, status), do: state

  defp transition(state, status) do
    state = %{
      state
      | status: status,
        needs_paste?: status == :awaiting_user and state.needs_paste?
    }

    Logger.info("login #{state.id} (#{state.provider}-#{state.account}): #{status}")
    broadcast(state)
    state
  end

  defp finish(state, status, reason), do: {:stop, :normal, finish_state(state, status, reason)}

  # Terminal: record, hand off on success, tear down the tmux session, broadcast.
  defp finish_state(state, status, reason) do
    state = %{state | status: status, reason: reason}
    state = cleanup(state)
    complete(state)
    if status == :succeeded, do: hand_off(state)
    Logger.info("login #{state.id} (#{state.provider}-#{state.account}): #{status}")
    broadcast(state)
    state
  end

  defp cleanup(%{cleaned_up?: true} = state), do: state

  defp cleanup(state) do
    if state.session do
      _ =
        Sessions.kill(state.session.id,
          runner: state.runner,
          reason: "login #{state.status}"
        )

      File.rm_rf(Layout.session_dir(state.session.id))
    end

    %{state | cleaned_up?: true}
  end

  # Child 4 (bd-djh1yr): record the credential by reference, clear the alerts,
  # poke the quota poller, and write the Login history row. Never fatal.
  defp complete(state) do
    LoginCompletion.complete(
      %{
        login_id: state.id,
        provider: state.provider,
        account: state.account,
        config_dir: state.config_dir,
        started_by: state.started_by,
        started_at: state.started_at
      },
      Keyword.merge(state.completion_opts,
        outcome: state.status,
        reason: state.reason,
        transcript: state.transcript
      )
    )
  rescue
    e -> Logger.error("login #{state.id}: completion raised: #{Exception.message(e)}")
  end

  defp hand_off(%{on_success: fun} = state) when is_function(fun, 1) do
    fun.(%{
      login_id: state.id,
      provider: state.provider,
      account: state.account,
      config_dir: state.config_dir
    })
  rescue
    e -> Logger.error("login #{state.id}: on_success handler raised: #{Exception.message(e)}")
  end

  defp hand_off(_state), do: :ok

  defp snapshot(state) do
    %{
      id: state.id,
      provider: state.provider,
      account: state.account,
      status: state.status,
      url: state.url,
      device_code: state.device_code,
      needs_paste?: state.needs_paste?,
      reason: state.reason,
      session_id: state.session && state.session.id
    }
  end

  defp announce(state) do
    broadcast(state)
    state
  end

  defp broadcast(%{topic: topic} = state) when is_binary(topic) do
    Phoenix.PubSub.broadcast(Arbiter.PubSub, topic, {:login_state, state.id, snapshot(state)})
  end

  defp broadcast(_state), do: :ok

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason), do: inspect(reason)
end
