defmodule Arbiter.Nodes.Registry do
  @moduledoc """
  Which nodes are connected: node id → its `Arbiter.Nodes.Session`
  (`docs/design/remote-workers.md` §3). A thin facade over a unique-key
  `Registry` of the same name, and the one place that starts a session.

  `attach/4` is what `ArbiterWeb.NodeChannel` calls on `join`: it finds or starts
  the node's session and hands it the channel pid and the `hello`.
  """

  alias Arbiter.Nodes
  alias Arbiter.Nodes.Node
  alias Arbiter.Nodes.Session

  @supervisor Arbiter.Nodes.SessionSupervisor

  @doc false
  def child_spec(_opts), do: Registry.child_spec(keys: :unique, name: __MODULE__)

  @doc """
  The session pid for `node_id`, or `nil`. A session that has exited is `nil`
  even in the instant before the registry drops its entry.
  """
  @spec lookup(String.t()) :: pid() | nil
  def lookup(node_id) do
    case Registry.lookup(__MODULE__, node_id) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  @doc "Every live session as `{pid, node_id}`."
  @spec list() :: [{pid(), String.t()}]
  def list, do: Registry.select(__MODULE__, [{{:"$1", :"$2", :_}, [], [{{:"$2", :"$1"}}]}])

  @doc """
  Connect `channel` as `node`'s channel with its `hello` params. Starts the
  session if the node has none, otherwise the existing session takes the new
  channel over (a reconnect inside the fence is a blip, §10.2).

  Returns `{:ok, %{pid:, hello_ok:}}`, or `{:error, :revoked}`. Options
  (`:clock`, `:tick_ms`) apply when the session is started.
  """
  @spec attach(Node.t(), pid(), map(), keyword()) ::
          {:ok, %{pid: pid(), hello_ok: map()}} | {:error, :revoked | term()}
  def attach(%Node{id: id}, channel, params, opts \\ []) do
    case Nodes.get_node(id) do
      %Node{status: status} = node when status != :revoked ->
        with {:ok, pid} <- ensure_session(node, opts) do
          Session.attach(pid, channel, params)
        end

      _ ->
        {:error, :revoked}
    end
  end

  defp ensure_session(%Node{id: id} = node, opts) do
    case lookup(id) do
      nil -> start_session(node, opts)
      pid -> {:ok, pid}
    end
  end

  defp start_session(%Node{} = node, opts) do
    case DynamicSupervisor.start_child(@supervisor, {Session, {node, opts}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc """
  Whether new work may be placed on `node_id` now: connected, not suspect, not
  draining, and healthy under the skew rules (§6, §13). `false` for a node with
  no session.
  """
  @spec assignable?(String.t()) :: boolean()
  def assignable?(node_id) do
    case lookup(node_id) do
      nil -> false
      pid -> Session.assignable?(pid)
    end
  end

  @doc "Tell `node_id`'s session (if any) about an out-of-band change. See `Session.notify/2`."
  @spec notify(String.t(), term()) :: :ok
  def notify(node_id, message) do
    case lookup(node_id) do
      nil -> :ok
      pid -> Session.notify(pid, message)
    end
  end
end
