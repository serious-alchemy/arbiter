defmodule Arbiter.NodeAgent.PodChannel do
  @moduledoc """
  The k8s controller's channel to its worker pods (`docs/design/remote-workers.md`
  §16 K§9.2, K§9.3, K§10, K§12; ticket K6): the one place pods and the controller
  meet, and the security boundary between them.

  ```
  pod  --mTLS :9443-->  BridgeListener --adopt--> NodeAgent.Bridge --bridge.open--> primary
  pod  --HTTPS :9444--> PodServer: /boot  /seed.bundle  /checkpoint  /transcripts  /commands
  ```

    * **Identity.** `Arbiter.NodeAgent.PodChannel.CA` creates the per-install CA on
      first boot and keeps it in a `Arbiter.NodeAgent.PodChannel.CAStore` (a Secret
      in the cluster). `Arbiter.NodeAgent.PodChannel.Runs.register/3` mints, in
      memory, **one leaf per bridge per run** (`CN` run id, `OU` bridge name) plus a
      `control` leaf for `:9444`, valid until the run's deadline.
    * **Bridges** (`:9443`): `Arbiter.NodeAgent.PodChannel.BridgeListener` needs a
      leaf this controller minted for a live registered run, with a bridge name from
      that run's spec, from the run's pod IP. It hands the connection to the **same**
      `Arbiter.NodeAgent.Bridge` the machine agent uses, so `bridge.open`, the
      primary's egress policy, `egress_events` and `BridgeIdentity` are untouched.
    * **Boot, seed, checkpoint, transcripts, commands** (`:9444`):
      `Arbiter.NodeAgent.PodChannel.PodServer`. `/boot` redeems the single-use,
      expiring, pod-IP-bound nonce (`Arbiter.NodeAgent.PodChannel.BootNonce`) for the
      run's certificates, secrets and seed files; the rest need the `control` leaf and
      move bytes between pod and primary without parsing them.
    * **Per-run secrets never become Kubernetes objects.** Only the CA goes to a
      store; the leaves, keys, provider tokens and seed files live in
      `Runs`' memory and reach the pod through `/boot` into a memory `emptyDir`. The
      pod spec carries one thing, the nonce.

  The server certificate (SANs: `:server_names`, `:server_ips`, i.e. the Service
  name and ClusterIP) is re-minted every `:rotate_after_ms` (default a quarter of
  its 30-day life) by restarting the two listeners; in-flight bridge streams end
  and the in-pod `socat` reconnects, as it does across a controller restart.

  Options: `:ca_store` (required), `:config` (`Arbiter.NodeAgent.Config`: the
  primary and its credential, for the seed/checkpoint legs), `:bridge`
  (`Arbiter.NodeAgent.Bridge` server, default its module name), `:ip`,
  `:bridge_port` (9443), `:boot_port` (9444), `:server_names`
  (`["arbiter-controller"]`), `:server_ips`, `:server_ttl_s`, `:rotate_after_ms`,
  `:notify`, `:max_upload_bytes`, `:name`.

  The controller's run lifecycle (K5) drives it: `register/2` at `assign`,
  `bind_pod_ip/2` when the informer reports the pod's address, `release/1` when the
  run is over, `push_command/2` for `checkpoint now`.
  """

  use Supervisor

  alias Arbiter.NodeAgent.PodChannel.{CA, Listeners, Runs}
  alias Arbiter.NodeAgent.RunSpec

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    # A CA that cannot be loaded or created fails the controller's boot: pods
    # could not be given an identity, so nothing may be started.
    case CA.load_or_create(Keyword.fetch!(opts, :ca_store)) do
      {:ok, ca} ->
        runs = [ca: ca] ++ Keyword.take(opts, [:boot_ttl_ms, :now])

        children = [
          {Runs, runs},
          {Listeners, Keyword.put(opts, :ca, ca)}
        ]

        Supervisor.init(children, strategy: :rest_for_one)

      {:error, reason} ->
        {:stop, {:pod_channel_ca, reason}}
    end
  end

  @doc "The controller assigned `spec`'s run: `{:ok, boot_nonce}` for the pod spec's `ARB_BOOT_NONCE`."
  @spec register(RunSpec.t(), DateTime.t()) :: {:ok, String.t()} | {:error, atom()}
  defdelegate register(spec, deadline), to: Runs

  @doc "The informer reported `run`'s `status.podIP`."
  @spec bind_pod_ip(String.t(), :inet.ip_address()) :: :ok
  defdelegate bind_pod_ip(run, ip), to: Runs

  @doc "The run is over: its leaves stop working at once and its nonce is gone."
  @spec release(String.t()) :: :ok
  defdelegate release(run), to: Runs

  @doc "Tell the run's snapshotter something over `GET /commands` (`%{\"op\" => \"checkpoint\"}`)."
  @spec push_command(String.t(), map()) :: :ok | {:error, :unknown_run}
  defdelegate push_command(run, command), to: Runs

  @doc "The bound ports: `%{bridge: 9443, boot: 9444}` (diagnostics, tests)."
  @spec ports() :: %{bridge: :inet.port_number(), boot: :inet.port_number()}
  defdelegate ports(), to: Listeners

  @doc "The `CAStore` the CA lives in."
  @spec ca_store() :: Arbiter.NodeAgent.PodChannel.CAStore.t()
  defdelegate ca_store(), to: Listeners

  @doc "Re-mint the server certificate now and restart the listeners on it."
  @spec rotate() :: :ok
  defdelegate rotate(), to: Listeners
end
