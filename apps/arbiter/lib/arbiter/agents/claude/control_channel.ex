defmodule Arbiter.Agents.Claude.ControlChannel do
  @moduledoc """
  Reads Claude auth status and usage over the CLI's **stream-json control
  channel** (bd-a2zrh0) instead of a billed `claude --print ping` round-trip or
  an HTTP poll that rides the operator's interactive `~/.claude` login.

  The CLI is started once in SDK mode

      claude -p --input-format stream-json --output-format stream-json --verbose

  and driven over stdin with one JSON object per line. Two control requests are
  used (neither is a model turn, so neither spends quota):

      {"type":"control_request","request_id":"arb-1","request":{"subtype":"initialize"}}
      {"type":"control_request","request_id":"arb-2","request":{"subtype":"get_usage"}}

  each answered by

      {"type":"control_response","response":{"subtype":"success","request_id":"arb-1","response":{…}}}
      {"type":"control_response","response":{"subtype":"error","request_id":"arb-2","error":"…"}}

    * `initialize`'s response carries `account` (`tokenSource`,
      `subscriptionType`, …) — read by `auth_state/1`.
    * `get_usage`'s response is the same body `/api/oauth/usage` returns
      (`five_hour`, `seven_day`, `limits`, …) so it goes through
      `Arbiter.Quota.OAuthUsage.parse_usage/1` unchanged.

  ## Stability — this is a best-effort, fallback-first surface

  `get_usage` is an experimental control request and the field shapes above are
  not a published, versioned contract. So **every** way the channel can fail to
  answer is reported as `{:unsupported, reason}` and callers must fall back to
  the path they used before this existed (the `ping` pre-flight, the HTTP quota
  poll): an error `control_response`, a CLI that exits, a CLI that stays silent
  past `:timeout_ms`, a missing executable, a CLI older than
  `min_cli_version/0`. Nothing here is ever the *only* way to learn something.

  ## Options

    * `:usage` — also send `get_usage` (default `false`).
    * `:env` — `[{name, value}]` for the spawn; scrubbed through
      `Arbiter.Worker.SpawnEnv.port_env/2` like every other Claude spawn.
    * `:timeout_ms` — max wait for *each* response (default 15s).
    * `:cli_version` — CLI version to gate on, instead of asking
      `claude --version`.
    * `:control_command` — argv override (tests); bypasses executable lookup and
      the `--version` probe.

  ## Configuration

      config :arbiter, Arbiter.Agents.Claude.ControlChannel,
        enabled: true,            # false → every caller uses its legacy path
        min_cli_version: "2.1.0"  # nil/false disables the version gate

  ## Where it runs

  In `Arbiter.Agents.Preflight.probe_cwd/0` — never the BEAM's cwd — and the
  process tree is always killed afterwards (`Port.close/1` does not reap a
  `:spawn_executable` child).
  """

  require Logger

  alias Arbiter.Agents.Preflight
  alias Arbiter.Worker.OsProcess
  alias Arbiter.Worker.SpawnEnv

  # Conservative floor, not a measured one: the oldest CLI that has been seen to
  # answer `initialize` with an `account` block. The runtime fallback — not this
  # number — is what actually protects callers from an older CLI; the floor only
  # saves the spawn when the answer is already known. See the PR design note.
  @min_cli_version "2.1.0"
  @default_timeout_ms 15_000
  @max_line_bytes 1_048_576
  @version_timeout_ms 5_000
  @cli_args ~w(-p --input-format stream-json --output-format stream-json --verbose)
  @unsupported_re ~r/unsupported|unknown|not supported|unrecognized|invalid.*subtype|no handler/i

  @type usage_result ::
          :not_requested | {:ok, map()} | {:error, String.t()} | {:unsupported, term()}

  @type result ::
          {:ok, %{account: map(), usage: usage_result()}}
          | {:unsupported, term()}

  @doc "Lowest CLI version this adapter drives over the control channel."
  @spec min_cli_version() :: String.t() | nil
  def min_cli_version do
    case Keyword.fetch(config(), :min_cli_version) do
      {:ok, v} when is_binary(v) -> v
      {:ok, _} -> nil
      :error -> @min_cli_version
    end
  end

  @doc "False when the operator turned the control channel off."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true) != false

  @doc """
  Interpret an `initialize` `account` block.

  `:unauthenticated` only when the CLI says outright it has no token
  (`tokenSource: "none"`); `:authenticated` when it names a source; `:unknown`
  for anything else — including a missing `account` — so a payload we do not
  recognise can never read as "logged out".
  """
  @spec auth_state(map()) :: :authenticated | :unauthenticated | :unknown
  def auth_state(%{"tokenSource" => "none"}), do: :unauthenticated
  def auth_state(%{"tokenSource" => src}) when is_binary(src) and src != "", do: :authenticated
  def auth_state(_), do: :unknown

  @doc "Run the exchange. See the moduledoc for `opts` and the result shape."
  @spec run(keyword()) :: result()
  def run(opts \\ []) when is_list(opts) do
    with {:ok, argv} <- resolve_argv(opts),
         :ok <- check_version(opts),
         {:ok, exec} <- resolve_executable(hd(argv)) do
      exchange(exec, tl(argv), opts)
    end
  end

  @doc """
  `get_usage` on its own: `{:ok, body}` or `{:error, reason}` — every
  non-success is an error the caller answers by using its legacy path.
  """
  @spec fetch_usage(keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_usage(opts \\ []) do
    case run(Keyword.put(opts, :usage, true)) do
      {:ok, %{usage: {:ok, body}}} -> {:ok, body}
      {:ok, %{usage: other}} -> {:error, {:usage, other}}
      {:unsupported, reason} -> {:error, {:unsupported, reason}}
    end
  end

  # ---- version gate --------------------------------------------------------

  @doc false
  @spec parse_version(String.t()) :: String.t() | nil
  def parse_version(output) when is_binary(output) do
    case Regex.run(~r/(\d+\.\d+\.\d+)/, output) do
      [_, v] -> v
      _ -> nil
    end
  end

  @doc false
  @spec version_at_least?(String.t(), String.t()) :: boolean()
  def version_at_least?(version, floor), do: to_tuple(version) >= to_tuple(floor)

  defp to_tuple(v) do
    v |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end

  defp check_version(opts) do
    floor = min_cli_version()

    case floor && detected_version(opts) do
      v when is_binary(v) ->
        if version_at_least?(v, floor), do: :ok, else: {:unsupported, {:cli_too_old, v, floor}}

      # No floor, or a version we could not read: let the runtime answer decide.
      _ ->
        :ok
    end
  end

  defp detected_version(opts) do
    cond do
      is_binary(opts[:cli_version]) -> opts[:cli_version]
      is_list(opts[:control_command]) -> nil
      true -> cli_version_from_binary()
    end
  end

  # `exec` is the PATH-resolved `claude` binary and the argument list is the
  # literal `["--version"]`; nothing from a request or a ticket reaches either.
  # sobelow_skip ["CI.System"]
  defp cli_version_from_binary do
    with exec when is_binary(exec) <- System.find_executable("claude"),
         task = Task.async(fn -> System.cmd(exec, ["--version"], stderr_to_stdout: true) end),
         {:ok, {out, 0}} <- Task.yield(task, @version_timeout_ms) || Task.shutdown(task) do
      parse_version(out)
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # ---- spawn + exchange ----------------------------------------------------

  defp resolve_argv(opts) do
    case Keyword.get(opts, :control_command) do
      [exec | _] = argv when is_binary(exec) ->
        {:ok, argv}

      _ ->
        {:ok, ["claude" | @cli_args]}
    end
  end

  defp resolve_executable(exec) do
    cond do
      String.contains?(exec, "/") and File.exists?(exec) -> {:ok, exec}
      String.contains?(exec, "/") -> {:unsupported, {:executable_not_found, exec}}
      path = System.find_executable(exec) -> {:ok, path}
      true -> {:unsupported, {:executable_not_found, exec}}
    end
  end

  # The exchange runs in its own short-lived process that traps exits. A CLI
  # that dies before it reads stdin makes the linked port exit with `:epipe`,
  # and that exit signal would otherwise kill the *caller* — the quota poller or
  # the credential watchdog — over a probe that was only ever advisory.
  defp exchange(exec, args, opts) do
    parent = self()
    ref = make_ref()

    {_pid, mref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(parent, {ref, converse_with_cli(exec, args, opts)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, _, reason} ->
        {:unsupported, {:crashed, reason}}
    end
  end

  defp converse_with_cli(exec, args, opts) do
    timeout =
      positive(opts[:timeout_ms]) || @default_timeout_ms

    port =
      Port.open(
        {:spawn_executable, exec},
        [
          {:args, args},
          {:line, @max_line_bytes},
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:cd, Preflight.probe_cwd()}
        ] ++ env_opt(Keyword.get(opts, :env, []))
      )

    os_pid = os_pid(port)

    try do
      converse(port, timeout, Keyword.get(opts, :usage, false))
    rescue
      # Port.command/2 on a port whose CLI already died.
      ArgumentError -> {:unsupported, :closed}
    after
      reap(port, os_pid)
    end
  end

  defp converse(port, timeout, want_usage?) do
    case request(port, "arb-init", "initialize", timeout) do
      {:ok, payload} ->
        account = payload |> Map.get("account") |> account_map()
        {:ok, %{account: account, usage: usage(port, timeout, want_usage?)}}

      {:error, msg} ->
        {:unsupported, {:control_error, msg}}

      other ->
        {:unsupported, transport_reason(other)}
    end
  end

  defp usage(_port, _timeout, false), do: :not_requested

  defp usage(port, timeout, true) do
    case request(port, "arb-usage", "get_usage", timeout) do
      {:ok, body} ->
        {:ok, body}

      {:error, msg} ->
        if Regex.match?(@unsupported_re, msg),
          do: {:unsupported, {:control_error, msg}},
          else: {:error, msg}

      other ->
        {:unsupported, transport_reason(other)}
    end
  end

  defp account_map(%{} = m), do: m
  defp account_map(_), do: %{}

  defp transport_reason(:timeout), do: :timeout
  defp transport_reason({:exit, status}), do: {:exited, status}

  defp request(port, id, subtype, timeout) do
    line =
      Jason.encode!(%{type: "control_request", request_id: id, request: %{subtype: subtype}})

    Port.command(port, line <> "\n")
    await(port, id, System.monotonic_time(:millisecond) + timeout, "")
  end

  # Collect lines until the matching control_response, the CLI exits, or the
  # deadline passes. Anything that is not our response (init banners, hook
  # events, stderr) is skipped. `{:noeol, _}` chunks are reassembled — an
  # `initialize` payload (the command list) can exceed the line buffer.
  defp await(port, id, deadline, buf) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, {:noeol, chunk}}} ->
        await(port, id, deadline, buf <> chunk)

      {^port, {:data, {:eol, chunk}}} ->
        case match_response(buf <> chunk, id) do
          :nomatch -> await(port, id, deadline, "")
          result -> result
        end

      {^port, {:exit_status, status}} ->
        {:exit, status}

      {:EXIT, ^port, reason} ->
        {:exit, reason}
    after
      remaining -> :timeout
    end
  end

  defp match_response(line, id) do
    case Jason.decode(line) do
      {:ok,
       %{
         "type" => "control_response",
         "response" => %{"request_id" => ^id, "subtype" => "success"} = resp
       }} ->
        {:ok, resp |> Map.get("response") |> account_map()}

      {:ok,
       %{
         "type" => "control_response",
         "response" => %{"request_id" => ^id, "subtype" => "error"} = resp
       }} ->
        {:error, to_string(Map.get(resp, "error", "control request failed"))}

      _ ->
        :nomatch
    end
  end

  defp env_opt(pairs) do
    case SpawnEnv.port_env(pairs, "claude") do
      [] -> []
      merged -> [{:env, Enum.map(merged, &env_pair/1)}]
    end
  end

  defp env_pair({name, false}), do: {to_charlist(name), false}
  defp env_pair({name, value}), do: {to_charlist(name), to_charlist(value)}

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp reap(port, os_pid) do
    if is_integer(os_pid) do
      case OsProcess.kill_tree(os_pid) do
        [] ->
          :ok

        survivors ->
          Logger.warning("ControlChannel: pid(s) #{Enum.join(survivors, ",")} survived SIGKILL")
      end
    end

    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp config, do: Application.get_env(:arbiter, __MODULE__, [])
end
