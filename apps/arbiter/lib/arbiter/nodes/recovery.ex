defmodule Arbiter.Nodes.Recovery do
  @moduledoc """
  Restart recovery for runs on nodes (`docs/design/remote-workers.md` §10.4–10.5).

  A remote run does **not** survive a primary restart (v1). When the primary
  comes back, every node reconnects with a new `boot_epoch`; the agent quiesces
  the runs the new primary does not know (`Arbiter.NodeAgent.Run.quiesce/1`),
  keeping their snapshot, bundle and transcripts locally, and reports them
  `retained`. `await/1` is what makes the primary take that work **before**
  anything acts on the stale rows. It is the first step of the boot sweep
  (`Arbiter.Boot.ReconcileSweep`), ahead of `Workers.Reconciler`'s orphan sweep
  and of `Boot.ResumeGate` opening; otherwise a resume provisions from a home
  clone that lacks the work and can race a container that is still running
  (bd-aowisc §6.3).

  A node's hello can arrive before this has run. The session answers it from the
  persisted row (`hold`, see `Arbiter.Nodes.Session`): the agent keeps the container
  running until `recover` below quiesces it, so it is never told "unknown run" for a run
  with a live row on it. Re-attaching such a run to a new Worker instead of collecting
  it needs Worker adoption, which `docs/design/remote-workers.md` §10.4 decides against for v1 (bd-4p1vui).

  For every run in a live state with a `node_id` (and no live Worker) it waits, in
  parallel across nodes, for the node's session to be connected, then asks the
  session to `recover` the run (`Arbiter.Nodes.Session.recover/4`): the agent uploads
  the transcripts, then the checkout bundle, through the ordinary upload endpoints,
  which accept them for the run because the recovery context says so. The
  checkout lands in the run's home clone through the §9 quarantine, so the run
  then resumes like a local interrupted run.

  ## Budget (U17)

  Per node `:node_timeout_ms` (default 60 s), all nodes `:total_timeout_ms`
  (default 90 s). `Boot.ResumeGate` holds the scheduler closed for 10 minutes, far
  above that, and the sweep Task is a supervised child that runs while the web
  endpoint starts, so nodes can connect while it waits. Nothing here blocks past
  the budget: a run that was not recovered is `{:unreachable, reason}` and the
  sweep goes on.

  ## What an unreachable run becomes

    * the node never reconnected (`:timeout`, `:not_connected`, no session): the
      run is stamped `interrupted` / `stop_category: "node_lost"`, "node lost:
      <name>" (§10.3): not `failed`, no resume attempt consumed. It degrades to
      the last checkpoint in the home clone, and the node's own reaper removes
      leftovers later.
    * the node is reachable but has nothing for the run (`:not_on_node`), an upload
      was refused, or the home clone is gone: the row is left to
      `Workers.Reconciler` ("server restarted"), which also resumes it.

  ## Options

  `:primary?` (default `SingleInstance.primary?/0`; `false` skips), `:node_timeout_ms`,
  `:total_timeout_ms`, and `:context_fun` (`run -> {:ok, ctx} | {:error, reason}`,
  default `context/1`).
  """

  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Node, Registry, Session}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.{BranchNamer, PrivateClone, Worktree}
  alias Arbiter.Workers.{Run, RunState}

  require Ash.Query
  require Logger

  @default_node_timeout_ms 60_000
  @default_total_timeout_ms 90_000

  @type outcome :: :collected | {:unreachable, term()}

  @doc "Recover the runs nodes hold. See the moduledoc. Returns `{:ok, %{run_id => outcome}}`."
  @spec await(keyword()) :: {:ok, %{String.t() => outcome()} | :skipped}
  def await(opts \\ []) do
    if Keyword.get_lazy(opts, :primary?, &Arbiter.SingleInstance.primary?/0) do
      {:ok, recover_all(opts)}
    else
      {:ok, :skipped}
    end
  rescue
    e ->
      # The sweep must go on: whatever is not recovered degrades to the last checkpoint.
      Logger.warning("Nodes.Recovery: await failed: #{Exception.message(e)}")
      {:ok, %{}}
  end

  # ---- the runs and their nodes -----------------------------------------------------

  defp recover_all(opts) do
    case remote_runs() do
      [] ->
        %{}

      runs ->
        deadline = now() + Keyword.get(opts, :total_timeout_ms, @default_total_timeout_ms)
        node_ms = Keyword.get(opts, :node_timeout_ms, @default_node_timeout_ms)

        runs
        |> Enum.group_by(& &1.node_id)
        |> Enum.map(fn {node_id, node_runs} ->
          node_deadline = min(deadline, now() + node_ms)

          task =
            Task.Supervisor.async_nolink(Arbiter.TaskSupervisor, fn ->
              recover_node(node_id, node_runs, node_deadline, opts)
            end)

          {task, node_id, node_runs}
        end)
        |> collect(deadline)
        |> Enum.reduce(%{}, &Map.merge/2)
    end
  end

  defp remote_runs do
    live = Enum.filter(RunState.states(), &RunState.live?/1)

    Run
    |> Ash.Query.filter(state in ^live and not is_nil(node_id))
    |> Ash.read!()
    |> Enum.reject(&(not is_nil(Arbiter.Worker.whereis(&1.task_id))))
  end

  @doc """
  The runs on a node that `report` (what `await/1` returned) did not account for:
  still live, still without a Worker, and with no outcome here. They belong to
  Recovery, so the Reconciler leaves them (and their tickets) alone and the next
  boot's `await/1` takes them again. A run with any outcome is settled: collected,
  stamped `node_lost`, or (`:not_on_node` and the like) left to the Reconciler, as
  the moduledoc says.
  """
  @spec unsettled(%{String.t() => outcome()}) :: [Run.t()]
  def unsettled(report) when is_map(report),
    do: Enum.reject(remote_runs(), &Map.has_key?(report, &1.id))

  # A node task that overruns the total budget (its own deadline is the earlier of the
  # two, so this is the backstop) is killed and its runs treated as a node that did not
  # come back: stamped `node_lost`, rather than left unaccounted for.
  defp collect(entries, deadline) do
    wait = max(deadline - now(), 0) + 500
    by_task = Map.new(entries, fn {task, node_id, runs} -> {task.ref, {node_id, runs}} end)

    entries
    |> Enum.map(&elem(&1, 0))
    |> Task.yield_many(wait)
    |> Enum.map(fn
      {_task, {:ok, result}} ->
        result

      {task, _} ->
        Task.shutdown(task, :brutal_kill)
        {node_id, runs} = Map.fetch!(by_task, task.ref)
        results = Map.new(runs, &{&1.id, {:unreachable, :timeout}})
        mark_lost(node_id, runs, results)
        results
    end)
  end

  # ---- one node ---------------------------------------------------------------------

  defp recover_node(node_id, runs, deadline, opts) do
    case wait_for_session(node_id, deadline) do
      {:ok, pid} ->
        results = Map.new(runs, &{&1.id, recover_run(pid, &1, deadline, opts)})
        mark_lost(node_id, runs, results)
        results

      {:error, reason} ->
        results = Map.new(runs, &{&1.id, {:unreachable, reason}})
        mark_lost(node_id, runs, results)
        results
    end
  end

  # The session exists once the node has connected; a quiet node is waited for on the
  # `nodes` topic rather than polled.
  defp wait_for_session(node_id, deadline) do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, Nodes.topic())

    try do
      await_connected(node_id, deadline)
    after
      Phoenix.PubSub.unsubscribe(Arbiter.PubSub, Nodes.topic())
    end
  end

  defp await_connected(node_id, deadline) do
    case connected_session(node_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        remaining = deadline - now()

        if remaining <= 0 do
          {:error, :timeout}
        else
          receive do
            {:node_connection, ^node_id, :up} -> await_connected(node_id, deadline)
          after
            remaining -> {:error, :timeout}
          end
        end
    end
  end

  defp connected_session(node_id) do
    with pid when is_pid(pid) <- Registry.lookup(node_id),
         %{connected?: true} <- Session.snapshot(pid) do
      {:ok, pid}
    else
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp recover_run(pid, run, deadline, opts) do
    context_fun = Keyword.get(opts, :context_fun, &context/1)

    case context_fun.(run) do
      {:ok, ctx} ->
        case Session.recover(pid, run.id, ctx, max(deadline - now(), 1)) do
          {:ok, _result} -> :collected
          {:error, reason} -> {:unreachable, reason}
        end

      {:error, reason} ->
        {:unreachable, {:no_context, reason}}
    end
  end

  # ---- the run's checkout context -----------------------------------------------------

  @doc """
  The checkout context a run's recovery is authorized against: the home clone the run
  was placed from (the ticket's preserved worktree), its branch and base, the paths
  seeded into it and the run's config dir. `{:error, reason}` when there is no home
  clone to take the work into.
  """
  @spec context(Run.t()) :: {:ok, map()} | {:error, term()}
  def context(%Run{} = run) do
    with {:ok, %Issue{} = issue} <- Ash.get(Issue, run.task_id),
         home = Worktree.worktree_path(BranchNamer.derive(issue)),
         true <- PrivateClone.clone?(home) or {:error, :no_home_clone},
         branch when is_binary(branch) <- PrivateClone.branch(home) || {:error, :no_branch} do
      {:ok,
       %{
         home: home,
         branch: branch,
         base: base_branch(run) || "main",
         seeded_paths: Worktree.seeded_paths(home),
         config_dir: run.config_dir
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :no_home_clone}
    end
  rescue
    e -> {:error, {:context_failed, Exception.message(e)}}
  end

  defp base_branch(%Run{workspace_id: ws_id, repo: repo}) do
    case ws_id && Ash.get(Workspace, ws_id) do
      {:ok, workspace} -> Arbiter.Mergers.base_branch(workspace, repo)
      _ -> nil
    end
  end

  # ---- a node that did not come back ------------------------------------------------

  @lost_reasons [:timeout, :not_connected, :no_session, :node_lost]

  defp mark_lost(node_id, runs, results) do
    name = node_name(node_id)

    for run <- runs, {:unreachable, reason} <- [results[run.id]], reason in @lost_reasons do
      stamp_node_lost(run, name)
    end

    :ok
  end

  @doc """
  Stamp `run` `finished` / `interrupted`, classification `node_lost`: the §10.3 policy
  (interrupted, **not** failed; no resume attempt is consumed, because the attempt
  counter lives in the Worker and is only ever advanced by an in-place resume).
  """
  @spec stamp_node_lost(Run.t(), String.t()) :: :ok | {:error, term()}
  def stamp_node_lost(%Run{} = run, node_name) do
    attrs = %{
      state: :finished,
      outcome: :interrupted,
      completed_at: DateTime.utc_now(),
      failure_reason: "node lost: #{node_name}",
      stop_category: "node_lost"
    }

    case Ash.update(run, attrs, action: :update) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Nodes.Recovery: could not stamp run #{run.id} node_lost: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp node_name(node_id) do
    case Nodes.get_node(node_id) do
      %Node{name: name} -> name
      _ -> node_id
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
