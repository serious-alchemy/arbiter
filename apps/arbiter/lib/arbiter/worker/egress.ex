defmodule Arbiter.Worker.Egress do
  @moduledoc """
  The host-side filtering CONNECT proxy for jailed workers (bd-aspkyr, G5;
  `docs/design/guardrail-profiles.md` §4.4).

  `Arbiter.Agents.Gemini` starts one per jailed agy run (G6, bd-cfktou); the
  jail bridges each socket into its network namespace with `socat`
  (`Arbiter.Worker.Jail`, `:network`).

  One proxy per run, listening on its own Unix socket (`<run>.proxy.sock`).
  The socket a request arrives on identifies the run and, through the run
  context, the task and its grants; nothing in the request can change that.

      {:ok, path} =
        Egress.start_run(run_id,
          task_id: task_id,
          enforce: true,
          baseline: ["repo.hex.pm:443", "*.githubusercontent.com:443"],
          grants: fn task_id -> ["network:api.example.com:443"] end
        )

  ## Policy

  See `Arbiter.Worker.Egress.Policy`: exact `host:port`; a leading `*.` only
  in the operator-written `:baseline`; ticket grants never wildcard; the
  `:no_public_upload` hosts denied even when granted unless the workspace
  `:safe_defaults_exclude` lifts them.

  ## Bridges and the owner

  `:bridges` adds a fixed-target socket per entry, `<run>.<name>.sock`, that
  splices to one `host:port` with no policy (`Arbiter.Worker.Egress.Forward`):
  the run's Arbiter endpoint and its fixed-destination tunnels. `:owner` is
  the process the run lives and dies with (the worker): when it exits the
  proxy and every bridge stop and their socket files go.

  ## Live grants

  Grants are read on every `CONNECT` through `Arbiter.Worker.Egress.GrantCache`.
  Whatever stores a grant calls `invalidate_grants/1` for the task; the next
  `CONNECT` sees it, with no restart. The cache has a short TTL as a backstop
  only.

  ## Modes

  `enforce: true` (the default) answers a denied `CONNECT` with `403`.
  `enforce: false` is learn mode: every decision is still recorded, a deny is
  allowed through (`Arbiter.Worker.Egress.Connection` states the one
  exception, public upload hosts).

  ## Audit

  Every decision is an `Arbiter.Worker.Egress.Event` row (`egress_events`).

  ## DNS and failure

  The proxy resolves and dials on the host; the client never resolves. A
  client whose proxy socket is gone or refusing has no other route, so egress
  fails closed. `stop_run/1` closes the socket and removes the file.
  """

  alias Arbiter.Config.Paths
  alias Arbiter.Worker.Egress.{BridgeIdentity, GrantCache, Policy, RunSupervisor}

  @registry Arbiter.Worker.Egress.Registry
  @supervisor Arbiter.Worker.Egress.RunSupervisors

  # sun_path is 108 bytes on Linux, 104 on macOS/BSD; stay under both.
  @max_socket_path 100

  @type start_opt ::
          {:task_id, String.t() | nil}
          | {:enforce, boolean()}
          | {:baseline, [String.t()]}
          | {:safe_defaults_exclude, [atom()]}
          | {:grants, (String.t() | nil -> [String.t()])}
          | {:dir, Path.t()}
          | {:allow_local_dial, boolean()}
          | {:dial_timeout, timeout()}
          | {:bridges, [{atom() | String.t(), {String.t(), :inet.port_number()}}]}
          | {:owner, pid()}
          | {:audit, boolean()}

  @doc """
  Starts the proxy for `run_id` and returns its socket path.

  Options:

    * `:task_id`: the ticket; the grants key.
    * `:enforce`: `true` (default) denies, `false` is learn mode.
    * `:baseline`: operator-written `host:port` entries, `*.` allowed. An
      invalid entry fails the start rather than being dropped.
    * `:safe_defaults_exclude`: the workspace's excluded categories.
    * `:grants`: `fun(task_id) -> [grant strings]`, called per cache miss.
      Default: none.
    * `:dir`: where the socket lives. Default `socket_dir/0`.
    * `:allow_local_dial`: let the proxy dial loopback/link-local addresses.
      Default `false`.
    * `:dial_timeout`: per-address connect timeout, ms. Default 10_000.
    * `:bridges`: `[{name, {host, port}}]`, each a fixed-target socket at
      `bridge_path/3`. `name` is 1-16 lowercase letters or digits.
    * `:owner`: a pid; the run stops when it exits. Default: not monitored,
      the caller stops the run.
    * `:audit`: `false` skips the `egress_events` rows. For the doctor's
      self-test (`Arbiter.Worker.Egress.SelfTest`), whose decisions are not a
      worker's. Default `true`.
  """
  @spec start_run(String.t(), [start_opt()]) :: {:ok, Path.t()} | {:error, term()}
  def start_run(run_id, opts \\ []) when is_binary(run_id) do
    dir = Keyword.get(opts, :dir) || socket_dir()
    path = socket_path(run_id, dir)

    with :ok <- validate_run_id(run_id),
         :ok <- validate_path(path),
         {:ok, baseline} <- Policy.normalize_baseline(Keyword.get(opts, :baseline, [])),
         {:ok, bridges} <- normalize_bridges(run_id, dir, Keyword.get(opts, :bridges, [])),
         :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      context = %{
        run_id: run_id,
        task_id: Keyword.get(opts, :task_id),
        enforce: Keyword.get(opts, :enforce, true),
        baseline: baseline,
        safe_defaults_exclude: Keyword.get(opts, :safe_defaults_exclude, []),
        grants_loader: Keyword.get(opts, :grants, fn _ -> [] end),
        allow_local_dial: Keyword.get(opts, :allow_local_dial, false),
        audit: Keyword.get(opts, :audit, true),
        dial_timeout: Keyword.get(opts, :dial_timeout, 10_000)
      }

      spec = %{
        id: {RunSupervisor, run_id},
        start:
          {RunSupervisor, :start_link,
           [
             [
               run_id: run_id,
               socket_path: path,
               context: context,
               bridges: bridges,
               owner: Keyword.get(opts, :owner)
             ]
           ]},
        type: :supervisor,
        restart: :temporary
      }

      case DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, _pid} -> {:ok, path}
        {:error, {:already_started, _}} -> {:error, :already_running}
        {:error, {:shutdown, {:failed_to_start_child, _, reason}}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Stops `run_id`'s proxy: closes live tunnels and the socket, removes the file."
  @spec stop_run(String.t()) :: :ok
  def stop_run(run_id) do
    BridgeIdentity.delete_run(run_id)

    case Registry.lookup(@registry, {run_id, :sup}) do
      [{pid, _}] -> _ = DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end

    :ok
  end

  @doc "True while `run_id` has a proxy running (its supervisor is alive)."
  @spec running?(String.t()) :: boolean()
  def running?(run_id) do
    # The Registry drops a dead process's entry asynchronously, so a lookup
    # right after the run's supervisor exits can still return its pid.
    Enum.any?(Registry.lookup(@registry, {run_id, :sup}), fn {pid, _} -> Process.alive?(pid) end)
  end

  @doc "A run's proxy socket path under `dir`: `<dir>/<run_id>.proxy.sock`."
  @spec socket_path(String.t(), Path.t()) :: Path.t()
  def socket_path(run_id, dir \\ socket_dir()), do: Path.join(dir, run_id <> ".proxy.sock")

  @doc "A run's bridge socket path under `dir`: `<dir>/<run_id>.<name>.sock`."
  @spec bridge_path(String.t(), atom() | String.t(), Path.t()) :: Path.t()
  def bridge_path(run_id, name, dir \\ socket_dir()),
    do: Path.join(dir, "#{run_id}.#{name}.sock")

  @doc "The default directory for proxy sockets."
  @spec socket_dir() :: Path.t()
  def socket_dir, do: Path.join(Paths.socket_root(), "egress")

  @doc """
  Drops the cached grants for `task_id` so the next `CONNECT` re-reads them.
  Call it from whatever grants or revokes a `network:` permission.
  """
  @spec invalidate_grants(String.t() | nil) :: :ok
  defdelegate invalidate_grants(task_id), to: GrantCache, as: :invalidate

  defp validate_run_id(run_id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, run_id), do: :ok, else: {:error, :invalid_run_id}
  end

  defp normalize_bridges(run_id, dir, bridges) do
    Enum.reduce_while(bridges, {:ok, []}, fn
      {name, {host, port}}, {:ok, acc} when is_binary(host) and port in 1..65_535 ->
        path = bridge_path(run_id, name, dir)

        cond do
          not Regex.match?(~r/\A[a-z0-9]{1,16}\z/, to_string(name)) ->
            {:halt, {:error, {:invalid_bridge, to_string(name)}}}

          to_string(name) == "proxy" ->
            {:halt, {:error, {:invalid_bridge, "proxy"}}}

          byte_size(path) > @max_socket_path ->
            {:halt, {:error, :socket_path_too_long}}

          true ->
            {:cont, {:ok, [%{name: to_string(name), path: path, host: host, port: port} | acc]}}
        end

      other, _ ->
        {:halt, {:error, {:invalid_bridge, inspect(other)}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp validate_path(path) do
    if byte_size(path) <= @max_socket_path, do: :ok, else: {:error, :socket_path_too_long}
  end
end
