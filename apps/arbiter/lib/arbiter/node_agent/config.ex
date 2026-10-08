defmodule Arbiter.NodeAgent.Config do
  @moduledoc """
  What the agent needs to reach its primary (`docs/design/remote-workers.md`
  §4.3, §5.2), resolved once at boot. Precedence: keyword options, then the
  environment, then `config :arbiter, Arbiter.NodeAgent, …` (the test suite's
  safety net, see `config/test.exs`):

    * `ARB_NODE_URL` — the primary's base URL. `https` for anything but
      loopback; plain `http` is accepted **only** for a loopback host (a
      same-host rig, or `ssh -L`). It is a URL, not a secret.
    * `ARB_NODE_HOME` — the data dir, default `~/.arbiter-node` (deliberately
      not `~/.arbiter`, the primary's default data home).
    * `ARB_NODE_CREDENTIAL_FILE` — default
      `~/.config/arbiter-node/credential`, 0600. The `arbn_<id>.<secret>`
      credential is the **only** secret an agent keeps at rest; it is read from
      that file, never from the environment or argv, and never printed
      (`inspect/1` hides it).
    * `ARB_NODE_MAX_WORKERS` — optional, a positive integer: the node owner's
      hard ceiling on concurrent workers, reported in `hello` as
      `capacity.ceiling` (§13). Anything else is ignored.

  `load/1` returns an error tuple instead of raising: an agent that cannot start
  reports why in its status file (`arbiter-node status`) rather than crash-looping
  under systemd.
  """

  @derive {Inspect, except: [:credential]}
  defstruct [
    :primary_url,
    :node_home,
    :credential_file,
    :credential,
    :node_id,
    :status_path,
    :version,
    :req_options,
    :halt_fun,
    :live_runs_fun,
    :readiness_fun,
    :max_workers,
    run_opts: [],
    hb_interval_ms: 10_000,
    fence_after_ms: 60_000,
    readiness_ttl_ms: 600_000,
    connect_timeout_ms: 10_000,
    hello_timeout_ms: 240_000,
    idle_poll_ms: 5_000,
    backoff: []
  ]

  @type t :: %__MODULE__{}

  @proto 1

  @doc "The wire protocol version this agent speaks (`hello.proto`)."
  @spec proto() :: pos_integer()
  def proto, do: @proto

  @doc """
  Resolve the config (precedence in the moduledoc). `:env` (a map), `:app_config`
  (a keyword list) and `:read_credential` (`path -> {:ok, binary} | {:error, term}`) exist so tests
  need no real files.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    node_home = node_home(opts)
    env = env(opts)

    credential_file =
      setting(opts, env, :credential_file, "ARB_NODE_CREDENTIAL_FILE") ||
        Path.join([home(env), ".config", "arbiter-node", "credential"])

    with {:ok, url} <- primary_url(opts, env),
         {:ok, credential} <- read_credential(credential_file, opts),
         {:ok, node_id} <- node_id(credential) do
      {:ok,
       struct!(
         __MODULE__,
         opts
         |> merged_opts()
         |> Keyword.take(
           ~w(hb_interval_ms fence_after_ms readiness_ttl_ms connect_timeout_ms hello_timeout_ms
            idle_poll_ms backoff req_options halt_fun live_runs_fun readiness_fun run_opts)a
         )
         |> Keyword.merge(
           primary_url: url,
           node_home: node_home,
           credential_file: credential_file,
           credential: credential,
           node_id: node_id,
           max_workers: max_workers(opts, env),
           status_path: Path.join(node_home, "status.json"),
           version: Keyword.get_lazy(opts, :version, &Arbiter.Version.app_version/0)
         )
       )}
    end
  end

  @doc "The data dir alone (`ARB_NODE_HOME`, default `~/.arbiter-node`); needs no valid config."
  @spec node_home(keyword()) :: Path.t()
  def node_home(opts \\ []) do
    env = env(opts)
    setting(opts, env, :node_home, "ARB_NODE_HOME") || Path.join(home(env), ".arbiter-node")
  end

  @doc """
  The WebSocket URL: the V2 serializer endpoint of `/node/socket`, with the
  credential as the `token` param `NodeSocket.connect/3` takes (§4.2), the
  `proto` and the `agent_version`. `https` becomes `wss`, `http` becomes `ws`.
  """
  @spec socket_url(t()) :: String.t()
  def socket_url(%__MODULE__{} = config) do
    uri = URI.parse(config.primary_url)
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    base = String.trim_trailing(uri.path || "", "/")

    query =
      URI.encode_query(%{
        "vsn" => "2.0.0",
        "token" => config.credential,
        "proto" => Integer.to_string(@proto),
        "agent_version" => config.version
      })

    URI.to_string(%{uri | scheme: scheme, path: base <> "/node/socket/websocket", query: query})
  end

  @doc "`GET`/`DELETE` URL for a node-tier HTTP route (`/nodes/…`) on the primary."
  @spec http_url(t(), String.t()) :: String.t()
  def http_url(%__MODULE__{primary_url: url}, path), do: String.trim_trailing(url, "/") <> path

  # -- private ----------------------------------------------------------------

  defp app_config(opts),
    do:
      Keyword.get_lazy(opts, :app_config, fn ->
        Application.get_env(:arbiter, Arbiter.NodeAgent, [])
      end)

  defp merged_opts(opts), do: Keyword.merge(app_config(opts), opts)

  # keyword option, then the environment, then application config
  defp setting(opts, env, key, env_name) do
    non_empty(Keyword.get(opts, key)) || non_empty(env[env_name]) ||
      non_empty(app_config(opts)[key])
  end

  defp max_workers(opts, env) do
    case Integer.parse(to_string(setting(opts, env, :max_workers, "ARB_NODE_MAX_WORKERS") || "")) do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end

  defp non_empty(value) when value in [nil, ""], do: nil
  defp non_empty(value), do: value

  defp env(opts), do: Keyword.get_lazy(opts, :env, &System.get_env/0)
  defp home(env), do: env["HOME"] || System.user_home() || "."

  defp primary_url(opts, env) do
    case setting(opts, env, :primary_url, "ARB_NODE_URL") do
      nil -> {:error, {:missing, "ARB_NODE_URL"}}
      url -> validate_url(url)
    end
  end

  defp validate_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> {:ok, url}
      %URI{scheme: "http", host: host} when is_binary(host) -> loopback_only(url, host)
      _ -> {:error, {:insecure_url, url}}
    end
  end

  defp loopback_only(url, host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]")

    loopback? =
      host == "localhost" or
        match?({:ok, {127, _, _, _}}, :inet.parse_address(String.to_charlist(host))) or
        match?({:ok, {0, 0, 0, 0, 0, 0, 0, 1}}, :inet.parse_address(String.to_charlist(host)))

    if loopback?, do: {:ok, url}, else: {:error, {:insecure_url, url}}
  end

  defp read_credential(path, opts) do
    reader = Keyword.get(opts, :read_credential)

    with :ok <- if(reader, do: :ok, else: check_mode(path)),
         {:ok, body} <- do_read(reader, path) do
      {:ok, String.trim(body)}
    end
  end

  defp do_read(nil, path) do
    case File.read(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:credential_unreadable, path, reason}}
    end
  end

  defp do_read(reader, path) do
    case reader.(path) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:credential_unreadable, path, reason}}
    end
  end

  # The credential is a standing secret: refuse a file other users can read.
  defp check_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        perm = Bitwise.band(mode, 0o777)

        if Bitwise.band(perm, 0o077) == 0,
          do: :ok,
          else: {:error, {:credential_permissions, path, perm}}

      {:error, reason} ->
        {:error, {:credential_unreadable, path, reason}}
    end
  end

  defp node_id("arbn_" <> rest) do
    case String.split(rest, ".", parts: 2) do
      [id, secret] when id != "" and secret != "" -> {:ok, id}
      _ -> {:error, :credential_malformed}
    end
  end

  defp node_id(_), do: {:error, :credential_malformed}
end
