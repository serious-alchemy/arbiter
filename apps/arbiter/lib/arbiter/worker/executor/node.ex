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

  All eight callbacks are implemented. `collect/2` (`:checkout`, RW11) takes a
  checkpoint of a live run; `recover/2` and `reap/2` (RW12) are the restart path:
  `recover/2` takes a quiesced run's work from the node that retained it, and
  `reap/2` asks the node's reaper to remove what the primary's live set does not
  hold (`docs/design/remote-workers.md` §10.4–10.6).

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

  @doc """
  Take the work of `run` that `node` retained across a primary restart (RW12):
  `run_ref` is `%{run: run_id, context: ctx}` (and optionally `timeout:`), `ctx` the
  checkout context (`%{home, branch, base, seeded_paths, config_dir}`). The agent's
  transcripts and checkout bundle go through the ordinary upload endpoints into the
  home clone. See `Arbiter.Nodes.Session.recover/4` for the result.
  """
  @impl true
  def recover(node, %{run: run, context: ctx} = run_ref) when is_binary(run) and is_map(ctx) do
    with {:ok, node_id} <- node_id(node),
         {:ok, pid} <- session(node_id) do
      Session.recover(pid, run, ctx, Map.get(run_ref, :timeout, 60_000))
    end
  end

  def recover(_node, _run_ref), do: {:error, :bad_run_ref}

  @doc """
  Ask `node` to reap its leftovers outside `live_set` (run ids), scoped to this
  install. `{:error, :disabled}` unless this is the single primary instance.
  """
  @impl true
  def reap(node, live_set) when is_list(live_set) do
    with {:ok, node_id} <- node_id(node),
         {:ok, pid} <- session(node_id) do
      Session.reap(pid, live_set)
    end
  end

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
