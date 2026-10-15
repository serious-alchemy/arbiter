defmodule Arbiter.NodeAgent.K8s.Boot do
  @moduledoc """
  The node-agent boot of a cluster controller: the Arbiter release with
  `ARB_ROLE=agent` and `ARB_AGENT_BACKEND=k8s`, as the rendered Deployment runs it
  (`docs/design/remote-workers.md` K§2.2, K§2.4; ticket K14).

  `Arbiter.NodeAgent.Supervisor` starts `children/1` instead of the machine's tree:

      TaskSupervisor      as on a machine
      Status              <node_home>/status.json (`ARB_NODE_HOME`, default /tmp/arbiter-node:
                          the pod's root filesystem is read-only, /tmp is its emptyDir)
      Bridge              the bridge multiplexer; the pod channel's :9443 feeds it
      TreeSupervisor      holds the controller once it is started
      Boot                this process

  `:rest_for_one`: if the tree's supervisor gives up, the boot runs again.

  The boot cannot start the controller at once: it does not know who it is yet. On every
  start it

    1. builds the in-cluster API client (the service account, `Client.in_cluster/1`);
    2. reads the node credential from the Secret `arbiter-node-credential`, or redeems the
       operator's join token at `POST /nodes/enroll` and stores the answer there
       (`Arbiter.NodeAgent.K8s.Credential`);
    3. asks the primary for the install id, `nodes.registry` and the canary's image
       (`GET /nodes/cluster`), and resolves the controller's identity from the API and the
       pod's environment (`Arbiter.NodeAgent.K8s.Identity`);
    4. starts `Arbiter.NodeAgent.K8s.NodeTree` (the pod channel, the controller and the
       connection) under `TreeSupervisor`.

  A step that fails (no join Secret yet, the primary unreachable or refusing the
  credential, a missing placeholder object) does not crash-loop the pod: the status file
  says `booting` with the error, the log says what to do, and the boot tries again after
  `Arbiter.NodeAgent.Backoff` (1 s doubling to 30 s). A credential that was enrolled but
  could not be stored is kept in memory and only its store is retried: the join token is
  spent.

  The primary's URL is `ARB_NODE_URL`, else `ARB_PRIMARY_URL` (what the manifest sets);
  `ARB_NODE_PROXY` (the tailscale sidecar's `http://127.0.0.1:1055`) carries the WebSocket
  and every HTTP call to the primary, never the API server's.

  Options (tests): everything `Arbiter.NodeAgent.Config.load/1` takes, plus `:k8s_client`
  (instead of the in-cluster client), `:token_file`, `:tree` (`NodeTree`'s per-child
  options).
  """

  use GenServer

  alias Arbiter.NodeAgent.Backend
  alias Arbiter.NodeAgent.Backoff
  alias Arbiter.NodeAgent.Bridge
  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.Credential
  alias Arbiter.NodeAgent.K8s.Identity
  alias Arbiter.NodeAgent.K8s.NodeTree
  alias Arbiter.NodeAgent.K8s.SelfUpgrade
  alias Arbiter.NodeAgent.Status
  alias Arbiter.NodeAgent.WsClient

  require Logger

  @tree_supervisor Arbiter.NodeAgent.K8s.TreeSupervisor
  @default_home "/tmp/arbiter-node"

  @doc "The node supervisor's children for a cluster controller (see the moduledoc)."
  @spec children(keyword()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(opts) do
    home = node_home(opts)

    [
      {Task.Supervisor, name: Arbiter.NodeAgent.TaskSupervisor},
      {Status, path: Path.join(home, "status.json")},
      {Bridge, node_home: home},
      {DynamicSupervisor, name: @tree_supervisor, strategy: :one_for_one},
      {__MODULE__, opts}
    ]
  end

  @doc "A cluster controller's data dir: `ARB_NODE_HOME`, else `#{@default_home}`."
  @spec node_home(keyword()) :: Path.t()
  def node_home(opts) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    Keyword.get(opts, :node_home) || non_empty(env["ARB_NODE_HOME"]) || @default_home
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    state = %{opts: opts, attempt: 0, unstored: nil}
    put_status(%{state: "booting", backend: "k8s", agent_version: version(opts)})
    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state), do: {:noreply, boot(state)}

  @impl true
  def handle_info(:boot, state), do: {:noreply, boot(state)}
  def handle_info(_other, state), do: {:noreply, state}

  # A credential kept for a store retry is a secret: never in a crash report or
  # `:sys.get_status/1`.
  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &redact/1)

  defp redact(%{unstored: credential} = state) when is_binary(credential),
    do: %{state | unstored: "[redacted]"}

  defp redact(state), do: state

  # -- the boot ----------------------------------------------------------------------------

  defp boot(state) do
    if Process.whereis(NodeTree) do
      # This process restarted under a tree that is still up: nothing to start twice.
      state
    else
      case resolve(state) do
        {:ok, tree_opts, state} -> start_tree(state, tree_opts)
        {:error, step, reason, state} -> retry(state, step, reason)
      end
    end
  end

  defp resolve(state) do
    opts = state.opts
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    with {:ok, endpoint} <- step(:primary_url, primary_endpoint(opts, env)),
         {:ok, req_options} <- step(:proxy, req_options(opts, endpoint.proxy)),
         {:ok, client} <- step(:kubernetes_api, client(opts)),
         k8s_version = k8s_version(client),
         {:ok, credential, state} <-
           credential(state, client, endpoint.url, req_options, k8s_version, env),
         {:ok, config} <-
           step(
             :config,
             config(opts, env, endpoint.url, credential, client, k8s_version, req_options)
           ),
         {:ok, facts} <- step(:primary_facts, Identity.primary_facts(config)),
         {:ok, identity} <- step(:identity, Identity.resolve(client, config, facts, env: env)) do
      {:ok,
       [
         config: config,
         client: client,
         identity: identity,
         canary_image: canary_image(config, facts.canary_image),
         tree: Keyword.get(opts, :tree, [])
       ], state}
    else
      # A step after the credential's failed: the state from before it is kept. If that
      # still holds an unstored credential, the next try stores it again, which
      # `Credential.store/2` answers `:ok` for the credential already there.
      {:error, step, reason} -> {:error, step, reason, state}
      {:error, step, reason, state} -> {:error, step, reason, state}
    end
  end

  defp step(_name, {:ok, value}), do: {:ok, value}
  defp step(name, {:error, reason}), do: {:error, name, reason}

  defp primary_endpoint(opts, env) do
    url =
      Keyword.get(opts, :primary_url) || non_empty(env["ARB_NODE_URL"]) || env["ARB_PRIMARY_URL"]

    Config.primary_endpoint(Keyword.merge(opts, env: env, primary_url: url))
  end

  # Every HTTP call to the primary goes through the proxy the WebSocket uses.
  defp req_options(opts, proxy) do
    base = Keyword.get(opts, :req_options, [])

    case WsClient.parse_proxy(proxy) do
      {:ok, nil} ->
        {:ok, base}

      {:ok, proxy} ->
        {:ok,
         Keyword.update(base, :connect_options, [proxy: proxy], &Keyword.put(&1, :proxy, proxy))}

      {:error, _} = error ->
        error
    end
  end

  defp client(opts) do
    case Keyword.get(opts, :k8s_client) do
      %Client{} = client -> {:ok, client}
      nil -> Client.in_cluster(Keyword.take(opts, [:sa_dir, :env]))
    end
  end

  # Reported in `hello`; not knowing it is no reason to stay down.
  defp k8s_version(client) do
    case Client.server_version(client) do
      {:ok, version} -> version
      {:error, _} -> nil
    end
  end

  defp credential(%{unstored: credential} = state, client, _url, _req, _version, _env)
       when is_binary(credential) do
    case Credential.store(client, credential) do
      :ok -> {:ok, credential, %{state | unstored: nil}}
      {:error, reason} -> {:error, :store_credential, reason, state}
    end
  end

  defp credential(state, client, url, req_options, k8s_version, env) do
    opts = [
      primary_url: url,
      name: non_empty(env["ARB_NODE_NAME"]),
      k8s_version: k8s_version,
      agent_version: version(state.opts),
      req_options: req_options
    ]

    opts =
      case Keyword.get(state.opts, :token_file) do
        nil -> opts
        path -> Keyword.put(opts, :token_file, path)
      end

    case Credential.obtain(client, opts) do
      {:ok, credential} ->
        {:ok, credential, state}

      {:error, {:store_failed, reason, credential}} ->
        {:error, :store_credential, reason, %{state | unstored: credential}}

      {:error, reason} ->
        {:error, :credential, reason, state}
    end
  end

  defp config(opts, env, url, credential, client, k8s_version, req_options) do
    Config.load(
      Keyword.merge(opts,
        env: env,
        primary_url: url,
        node_home: node_home(opts),
        read_credential: fn _path -> {:ok, credential} end,
        backend: Backend.K8s,
        req_options: req_options,
        cluster: %{
          namespace: client.namespace,
          k8s_version: k8s_version,
          self_upgrade?: SelfUpgrade.available?(env)
        }
      )
    )
  end

  # Asked on every canary run: the primary may publish a worker image after this boot.
  # The image named at boot is the fallback while the primary cannot be asked.
  defp canary_image(config, at_boot) do
    fn ->
      case Identity.primary_facts(config) do
        {:ok, %{canary_image: image}} when is_binary(image) -> {:ok, image}
        _other when is_binary(at_boot) -> {:ok, at_boot}
        {:ok, _} -> {:error, :not_published}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp start_tree(state, tree_opts) do
    case DynamicSupervisor.start_child(@tree_supervisor, {NodeTree, tree_opts}) do
      {:ok, _pid} ->
        Logger.info("k8s controller booted: node #{tree_opts[:config].node_id}")
        put_status(%{state: "booted", last_error: nil, boot_step: nil})
        %{state | attempt: 0}

      {:error, {:already_started, _pid}} ->
        state

      {:error, reason} ->
        retry(state, :start, reason)
    end
  end

  defp retry(state, step, reason) do
    delay = Backoff.delay(state.attempt, Keyword.get(state.opts, :backoff, []))
    message = describe(step, reason)
    Logger.warning("k8s controller not booted (#{message}); retrying in #{delay} ms")

    put_status(%{
      state: "booting",
      boot_step: Atom.to_string(step),
      last_error: message,
      attempt: state.attempt + 1,
      next_retry_ms: delay
    })

    Process.send_after(self(), :boot, delay)
    %{state | attempt: state.attempt + 1}
  end

  # What the operator reads in the log and the status file. Never the credential: no
  # step's reason carries it (an unstored one is kept in the state, not the reason).
  defp describe(:credential, :no_join_token),
    do:
      "no node credential and no join token: create the join Secret " <>
        "(kubectl -n <namespace> create secret generic arbiter-join --from-file=token=/dev/stdin)"

  defp describe(:credential, {:enroll_refused, status, message}),
    do: "the primary refused the join token (#{status}: #{message}); mint a new one"

  defp describe(:primary_facts, {:primary, status, message}),
    do: "the primary answered #{status} to GET /nodes/cluster: #{message}"

  defp describe(step, reason), do: "#{step}: #{inspect(reason, limit: 8, printable_limit: 300)}"

  defp put_status(changes) do
    Status.put(changes)
  catch
    :exit, _ -> :ok
  end

  defp version(opts), do: Keyword.get_lazy(opts, :version, &Arbiter.Version.app_version/0)

  defp non_empty(value) when value in [nil, ""], do: nil
  defp non_empty(value), do: value
end
