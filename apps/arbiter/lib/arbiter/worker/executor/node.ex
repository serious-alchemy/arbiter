defmodule Arbiter.Worker.Executor.Node do
  @moduledoc """
  `Arbiter.Worker.Executor` for a run placed on an enrolled node
  (`docs/design/remote-workers.md` §7.2, §12), over the node's
  `Arbiter.Nodes.Session`.

  The handle is `{:remote, {node_id, run_id, ref}}`: it carries everything
  `signal/2`, `stop/1` and `outcome/1` need to find the session again, and the
  `ref` makes a re-open of the same run id a *different* handle (the Worker keeps
  one entry per handle, as it does per port).

  ## What is and is not here yet

  `prepare/3`, `open/1`, `signal/2`, `stop/1`, `outcome/1` and `collect/2`
  (`:checkout`, RW11) are complete. `recover/2` and `reap/2` (restart recovery
  and the node-side reaper, RW12) answer `{:error, :unsupported}`: the agent has
  no side of those yet, and pretending would be worse than saying so.

  `prepare/3` takes `checkout: %{home, branch, base, seeded_paths}` (RW11): the
  primary's context for the run, which authorizes the seed and checkout
  endpoints (`Arbiter.Nodes.Checkout`). The spec's own `checkout` block tells the
  agent to seed and upload.

  ## Stop is asynchronous

  `stop/1` asks the node to remove the container by name and returns. A node that
  cannot be reached keeps the request and repeats it on reconnect; failing that,
  the agent's own fence (60 s) stops the container.
  """

  @behaviour Arbiter.Worker.Executor

  alias Arbiter.Nodes
  alias Arbiter.Nodes.Session

  @impl true
  def prepare(node, run_spec, opts \\ []) when is_map(run_spec) do
    with {:ok, node_id} <- node_id(node),
         run when is_binary(run) <- run_spec["run"] || {:error, :no_run_id},
         {:ok, pid} <- session(node_id),
         owner = Keyword.get(opts, :owner, self()),
         {:ok, handle} <-
           Session.assign(
             pid,
             run,
             run_spec,
             owner,
             Keyword.take(opts, [:prepare_timeout_ms, :checkout])
           ) do
      {:ok, %{handle: handle, node_id: node_id, run: run, session: pid}}
    end
  end

  @impl true
  def open(%{handle: handle}), do: {:ok, handle}

  @impl true
  def signal({:remote, {node_id, run, _ref}}, kind) when kind in [:term, :kill] do
    with {:ok, pid} <- session(node_id) do
      Session.signal_run(pid, run, if(kind == :term, do: "TERM", else: "KILL"))
    end
  end

  @impl true
  def stop({:remote, {node_id, run, _ref}}) do
    case Nodes.Registry.lookup(node_id) do
      nil -> :ok
      pid -> Session.cancel_run(pid, run, "stop")
    end
  end

  def stop(_other), do: :ok

  @impl true
  def outcome({:remote, {node_id, run, _ref}}) do
    case Nodes.Registry.lookup(node_id) do
      nil -> {:error, :no_session}
      pid -> normalize(Session.run_outcome(pid, run))
    end
  catch
    :exit, _ -> {:error, :no_session}
  end

  @doc """
  `collect(handle, :checkout)` takes a checkpoint now (RW11): the agent snapshots its
  shadow and uploads it, the primary ingests it through the quarantine into the
  home clone, and this returns `{:ok, %{head, snapshot, status_hash, filtered, ...}}`
  or `{:error, reason}` (an ingest refusal, `:timeout`, `:run_gone`, ...).
  `:transcripts` is not served by the node yet.
  """
  @impl true
  def collect({:remote, {node_id, run, _ref}}, :checkout) do
    with {:ok, pid} <- session(node_id), do: Session.collect(pid, run, :checkout)
  end

  def collect(_run_ref, _kind), do: {:error, :unsupported}

  @impl true
  def recover(_node, _run_ref), do: {:error, :unsupported}

  @impl true
  def reap(_node, _live_set), do: {:error, :unsupported}

  @doc """
  Whether the node still has the run (assigned and not ended). The Worker's
  replacement for `Port.info(port) != nil`; `false` when the session is gone.
  """
  @spec live?(Arbiter.Worker.Executor.handle()) :: boolean()
  def live?({:remote, {node_id, run, _ref}}) do
    case Nodes.Registry.lookup(node_id) do
      nil -> false
      pid -> Session.run_live?(pid, run)
    end
  catch
    :exit, _ -> false
  end

  @doc "Tell the session an ended run can be forgotten."
  @spec release(Arbiter.Worker.Executor.handle()) :: :ok
  def release({:remote, {node_id, run, _ref}}) do
    case Nodes.Registry.lookup(node_id) do
      nil -> :ok
      pid -> Session.release_run(pid, run)
    end
  end

  # -- internals -------------------------------------------------------------------

  defp node_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp node_id(id) when is_binary(id), do: {:ok, id}
  defp node_id(_), do: {:error, :no_node}

  defp session(node_id) do
    case Nodes.Registry.lookup(node_id) do
      nil -> {:error, :no_session}
      pid -> {:ok, pid}
    end
  end

  defp normalize({:ok, outcome}), do: {:ok, outcome}
  defp normalize(:pending), do: :pending
  defp normalize(:error), do: {:error, :unknown_run}
end
