defmodule Arbiter.Worker.Executor do
  @moduledoc """
  Where a worker's agent process actually runs (`docs/design/remote-workers.md`
  §12): the boundary between `Arbiter.Worker` and a node. Eight callbacks and one
  implementation, `Arbiter.Worker.Executor.Node`. A Kubernetes controller is just
  another *agent* speaking the same node protocol, so it needs no Executor of its
  own: the polymorphism is in the agent, not here.

  **The local path does not go through this behaviour.** A run with no node
  (`worker.placement: local_only`, the default, or an ineligible run) opens a
  `Port` exactly as before; only a run placed on a node (`opts[:node]`) takes
  the executor, so there is no regression surface for runs that stay local.

  | callback | meaning for `Executor.Node` |
  |----------|-----------------------------|
  | `prepare/3` | send `assign`; the agent does image / CLI / deps / run dir / listeners and replies `run.ready`, or refuses |
  | `open/1` | the **remote handle** (`{:remote, ref}`) the owner then receives Port-shaped messages for |
  | `signal/2` | `TERM` or `KILL` to the container's init |
  | `stop/1` | idempotent stop-and-remove by name, done by the agent |
  | `outcome/1` | `%{oom?, exit_code, cancelled?, node_lost?}` once the run ended |
  | `collect/2` | take a checkpoint now (RW11): the agent uploads, the primary ingests, the result comes back |
  | `recover/2` | the restart path (RW12) |
  | `reap/2` | node-side reaping against the primary's live set (RW12) |

  The message shapes an owner receives for a handle are the three a `Port` sends,
  plus one more:

      {handle, {:data, {:eol | :noeol, line}}}
      {handle, {:outcome, %{oom?: boolean, exit_code: integer, ...}}}   # just before the exit
      {handle, {:exit_status, code}}
  """

  @type node_ref :: String.t() | %{required(:id) => String.t(), optional(atom()) => term()}
  @type run_spec :: map()
  @type prepared :: term()
  @type handle :: {:remote, term()}
  @type run_ref :: handle() | term()

  @callback prepare(node_ref(), run_spec(), keyword()) :: {:ok, prepared()} | {:error, term()}
  @callback open(prepared()) :: {:ok, handle()} | {:error, term()}
  @callback signal(handle(), :term | :kill) :: :ok | {:error, term()}
  @callback stop(run_ref()) :: :ok
  @callback outcome(run_ref()) :: {:ok, map()} | :pending | {:error, term()}
  @callback collect(run_ref(), :checkout | :transcripts) :: :ok | {:ok, term()} | {:error, term()}
  @callback recover(node_ref(), run_ref()) :: {:ok, term()} | {:error, term()}
  @callback reap(node_ref(), live_set :: [String.t()]) :: :ok | {:error, term()}

  @doc "True for the handle an `Executor` returns (`{:remote, _}`), false for a `Port`."
  @spec remote?(term()) :: boolean()
  def remote?({:remote, _}), do: true
  def remote?(_), do: false
end
