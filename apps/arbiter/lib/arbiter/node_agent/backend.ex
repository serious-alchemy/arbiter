defmodule Arbiter.NodeAgent.Backend do
  @moduledoc """
  The seam between the node agent and whatever actually runs a worker
  (bd-1nfuq5 §1). The agent's connection, reaper and `hello` speak only to this
  behaviour. Two implementations: `Arbiter.NodeAgent.Backend.Podman` (the RW9 run
  supervisor, a machine) and `Arbiter.NodeAgent.Backend.K8s` (the in-cluster
  controller, K14).

  `ARB_AGENT_BACKEND` picks the backend (`Arbiter.NodeAgent.Config`): `podman`
  by default, `k8s` for a cluster controller, and an unknown name fails the
  agent's boot rather than silently falling back.

  Runs are addressed by run id. Mutating calls are idempotent: an unknown run is
  `{:error, :not_found}`.
  """

  @typedoc "Run id, the `arbiter.run` label."
  @type run :: String.t()

  @doc "Every owned run's report (what `hello` and `hb` carry)."
  @callback inventory() :: [map()]

  @doc "Start the run described by `%{spec: map, opts: keyword}` (the decoded `assign` spec)."
  @callback start_run(%{spec: map(), opts: keyword()}) :: {:ok, run} | {:error, term()}

  @doc "Send `signal` (TERM or KILL) to the run's init."
  @callback signal(run, String.t()) :: :ok | {:error, :not_found}

  @doc "Stop the run; `{run, reason}` carries the cancel reason reported in its exit."
  @callback stop(run | {run, String.t()}) :: :ok | {:error, :not_found}

  @doc "The run's exit report once it has exited, `nil` while it is still running."
  @callback outcome(run) :: map() | nil

  @doc "Take a checkpoint of the run now; `opts` may carry `:kind` (default `\"checkout\"`)."
  @callback collect(run, keyword()) :: :ok | {:error, term()}

  @doc """
  Run `command` (`sh -c`) to completion in a container of `run`'s shape — its image,
  mounts and limits, none of its secrets — and return `{output, exit_status}`
  (bd-9rrrgk, the pre-push recipe). The run need not be live. Optional: a backend
  without it answers `{:error, :unsupported}`.
  """
  @callback exec(run, String.t(), pos_integer(), keyword()) ::
              {String.t(), non_neg_integer()} | {:error, term()}

  @optional_callbacks exec: 4

  @doc "Ids of the runs this backend currently owns."

  @callback list_owned() :: [run]

  @doc "Remove leftovers of runs outside the live set: `%{config:, request:, opts:}`."
  @callback reap(%{config: struct(), request: map(), opts: keyword()}) :: map() | {:error, term()}

  @doc "Capacity facts for `hello` (cpus, memory, suggestion)."
  @callback capacity() :: map()

  @doc "The readiness report for `hello` (the backend can run workers, or why not)."
  @callback readiness() :: map()

  # -- the connection's hooks (K14) ---------------------------------------------------
  #
  # What `Arbiter.NodeAgent.Connection` does to the runs when the channel says something.
  # The machine agent's own `Run`/`Runs` calls moved behind these unchanged
  # (`Arbiter.NodeAgent.Backend.Podman`), so the connection names no backend.

  @doc "The `hello` payload, given the readiness report `readiness/0` produced."
  @callback hello(Arbiter.NodeAgent.Config.t(), readiness :: map()) :: map()

  @doc "The `hb` payload for heartbeat number `seq`."
  @callback heartbeat(Arbiter.NodeAgent.Config.t(), seq :: non_neg_integer()) :: map()

  @doc "Say again what the primary may have missed for `run` (it repeated the `assign`)."
  @callback attach(run) :: :ok | {:error, :not_found}

  @doc "The channel is up (`hello_ok`): every run but `skip` resends what is unacknowledged."
  @callback attach_all(skip :: [run]) :: :ok

  @doc "The channel went away."
  @callback detach_all() :: :ok

  @doc "The self-fence (§10.1): stop every run."
  @callback fence_all() :: :ok

  @doc "The primary acknowledged `run`'s output up to `cursor` (`ack{run, offset}`)."
  @callback ack(run, cursor :: term()) :: :ok | {:error, :not_found}

  @doc "The primary has `run`'s `exit` (`exit_ack{run}`): the run may go."
  @callback exit_ack(run) :: :ok | {:error, :not_found}

  @doc "The primary does not know `run`, or asked for it to be collected (`quiesce{run}`)."
  @callback quiesce(run) :: :ok | {:error, :not_found}

  @doc "A new Worker on the primary takes a held `run` over (`adopt{run}`)."
  @callback adopt(run) :: :ok | {:error, :not_found | :unsupported}

  @backends %{
    "podman" => Arbiter.NodeAgent.Backend.Podman,
    "k8s" => Arbiter.NodeAgent.Backend.K8s
  }

  @doc "The backend names `ARB_AGENT_BACKEND` accepts."
  @spec names() :: [String.t()]
  def names, do: @backends |> Map.keys() |> Enum.sort()

  @doc "Resolve a backend name (default `podman`) to its module."
  @spec resolve(String.t() | nil) :: {:ok, module()} | {:error, {:unknown_backend, term()}}
  def resolve(nil), do: {:ok, Arbiter.NodeAgent.Backend.Podman}

  def resolve(name) when is_binary(name) do
    case Map.fetch(@backends, name |> String.trim() |> String.downcase()) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, {:unknown_backend, name}}
    end
  end
end
