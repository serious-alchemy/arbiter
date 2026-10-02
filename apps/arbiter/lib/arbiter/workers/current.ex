defmodule Arbiter.Workers.Current do
  @moduledoc """
  One read for "what is this ticket's run doing" (ticket lifecycle 5/13,
  bd-1uu19b). `arb worker list` (`GET /api/workers`, MCP `worker_list`) and
  `arb worker show` (`GET /api/workers/:task_id`, MCP `worker_show`) both go
  through `current_run/3`, so for any ticket they report the same run's kind,
  state and outcome (`Arbiter.Workers.RunState`).

  A **view** is one run, as a map in the worker snapshot's shape (so the
  serializers that render a live snapshot render a view unchanged), plus:

    * `:ticket_id` — the ticket the run is an attempt at. A ReviewGate
      reviewer / implementer runs under a synthetic `<ticket>#…` id; its
      ticket is the base id.
    * `:source` — `:live` (read from the worker process) or `:history` (read
      from its `Arbiter.Workers.Run` row).
    * `:run_id`, `:completed_at`, `:failure_reason`.
    * `:workspace_id` — the ticket's workspace. A reviewer worker carries
      `workspace_id: nil` on its own state, which used to drop it from every
      workspace-scoped listing (`arb prime`'s active workers among them).
    * `:held` — the dispatch the quota gate is holding for the ticket
      (`Arbiter.Workflows.DispatchQueue.describe/1`), or nil. While one is
      held and no run is working, the phase reads `:held_for_quota`: a
      ReviewGate fix round refused for quota is waiting on the gate, not
      failed (bd-6omte4).

  ## The current run

  A ticket's current run is its live run, if it has one — the newest
  unfinished one when more than one is registered (an author waiting on the
  review gate while its reviewer works: the reviewer is current), else the
  newest registered one. With no live run it is the ticket's newest `Run`
  row. There is no separate history fallback with a vocabulary of its own:
  a row is read into the same view.
  """

  require Ash.Query

  alias Arbiter.Tasks.Issue
  alias Arbiter.Worker
  alias Arbiter.Worker.Phase
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.DispatchQueue

  @recent_limit 10

  @type view :: map()

  @doc """
  Every ticket with a live run, each as its current run (`current_run/3`).

  Options:

    * `:live` — the live worker snapshots (`Arbiter.Worker.list_children/0`
      when absent).
    * `:workspace_id` — keep only runs whose ticket is in this workspace.
  """
  @spec list(keyword()) :: [view()]
  def list(opts \\ []) do
    live = live(opts)

    live
    |> Enum.map(&ticket_id/1)
    |> Enum.uniq()
    |> Enum.map(&current_run(&1, live, []))
    |> Enum.reject(&is_nil/1)
    |> with_workspaces()
    |> filter_workspace(Keyword.get(opts, :workspace_id))
    |> with_holds()
  end

  @doc """
  The ticket's current run (`current_run/3`) and its recent runs, newest
  first, each labelled with its kind — `%{current: view, runs: [view]}` — or
  `nil` when the ticket has neither a live run nor a recorded one.

  Each entry in `runs` carries `current: true` when it is the current run.
  Options: `:live` (as `list/1`) and `:limit` (default #{@recent_limit}).
  """
  @spec show(String.t(), keyword()) :: %{current: view(), runs: [view()]} | nil
  def show(ticket_id, opts \\ []) when is_binary(ticket_id) do
    live = live(opts)
    rows = recent_rows(ticket_id, Keyword.get(opts, :limit, @recent_limit))

    case current_run(ticket_id, live, rows) do
      nil ->
        nil

      current ->
        [current] = current |> List.wrap() |> with_workspaces() |> with_holds()
        %{current: current, runs: recent_runs(current, live, rows)}
    end
  end

  @doc """
  The one function both surfaces read: ticket `ticket_id`'s current run, as
  a view, given the live worker snapshots (`live`, already phase-annotated
  by `list/1` / `show/2`) and its `Run` rows newest first (`rows`; read when
  needed and not given).
  """
  @spec current_run(String.t(), [map()], [Run.t()] | nil) :: view() | nil
  def current_run(ticket_id, live, rows \\ nil) when is_binary(ticket_id) do
    case current_live(ticket_id, live) do
      %{} = snap ->
        from_snapshot(snap)

      nil ->
        rows = if rows in [nil, []], do: recent_rows(ticket_id, 1), else: rows

        case rows do
          [%Run{} = run | _] -> from_row(run)
          _ -> nil
        end
    end
  end

  @doc "The ticket a run (a snapshot, a view or a `Run`) is an attempt at."
  @spec ticket_id(map()) :: String.t()
  def ticket_id(%{task_id: task_id}) when is_binary(task_id),
    do: ReviewGate.base_task_id(task_id)

  # ---- internals ------------------------------------------------------------

  defp live(opts) do
    opts
    |> Keyword.get_lazy(:live, &Worker.list_children/0)
    |> Phase.annotate()
  end

  defp current_live(ticket_id, live) do
    live
    |> Enum.filter(&(ticket_id(&1) == ticket_id))
    |> Enum.sort_by(&current_rank/1, :desc)
    |> List.first()
  end

  # An unfinished run outranks a finished one still registered; then newest.
  defp current_rank(snap) do
    {if(Map.get(snap, :state) == :finished, do: 0, else: 1), unix(Map.get(snap, :started_at))}
  end

  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp unix(_), do: 0

  defp from_snapshot(snap) do
    meta = Map.get(snap, :meta) || %{}

    snap
    |> Map.merge(%{
      ticket_id: ticket_id(snap),
      source: :live,
      run_id: Map.get(snap, :run_id),
      completed_at: nil,
      failure_reason: Map.get(meta, :failure_reason)
    })
  end

  defp from_row(%Run{} = run) do
    %{
      ticket_id: ticket_id(run),
      task_id: run.task_id,
      registry_key: nil,
      role: role_atom(run.role),
      source: :history,
      run_id: run.id,
      workspace_id: run.workspace_id,
      repo: run.repo,
      current_step: nil,
      kind: run.kind,
      state: run.state,
      outcome: run.outcome,
      waiting_on: nil,
      phase: nil,
      agent_live: false,
      started_at: run.started_at,
      step_started_at: nil,
      completed_at: run.completed_at,
      mr_ref: run.mr_ref,
      merger_url: run.merger_url,
      failure_reason: run.failure_reason,
      pid: nil,
      run: run,
      meta: %{
        model: run.model,
        output_lines: run.output_lines || [],
        exit_status: run.exit_code,
        failure_reason: run.failure_reason,
        failure_summary: run.failure_summary
      }
    }
  end

  # The run's role column back to the snapshot's role atom, through a fixed
  # allowlist rather than `String.to_existing_atom/1` on a DB value.
  @roles %{
    "review" => :reviewer,
    "impl" => :implementer,
    "fix_pass" => :fix_pass,
    "conflict" => :conflict_resolver
  }

  defp role_atom(role), do: Map.get(@roles, role)

  defp recent_runs(current, live, rows) do
    live_by_run = for snap <- live, id = Map.get(snap, :run_id), into: %{}, do: {id, snap}

    views =
      Enum.map(rows, fn run ->
        case Map.get(live_by_run, run.id) do
          nil -> from_row(run)
          snap -> from_snapshot(snap)
        end
      end)

    views =
      if Enum.any?(views, &same_run?(&1, current)), do: views, else: [current | views]

    Enum.map(views, &Map.put(&1, :current, same_run?(&1, current)))
  end

  defp same_run?(%{run_id: id}, %{run_id: id}) when is_binary(id), do: true
  defp same_run?(a, b), do: a == b

  defp recent_rows(ticket_id, limit) do
    Run
    |> Ash.Query.filter(task_id == ^ticket_id or base_task_id == ^ticket_id)
    |> Ash.Query.sort(started_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!()
  rescue
    _ -> []
  end

  # A reviewer / implementer view carries no workspace of its own; it is the
  # ticket's. One read for every ticket that needs it.
  defp with_workspaces(views) do
    missing = for v <- views, is_nil(v.workspace_id), uniq: true, do: v.ticket_id

    by_ticket = workspaces_of(missing)

    Enum.map(views, fn
      %{workspace_id: nil, ticket_id: id} = v -> %{v | workspace_id: Map.get(by_ticket, id)}
      v -> v
    end)
  end

  defp workspaces_of([]), do: %{}

  defp workspaces_of(ids) do
    Issue
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :workspace_id])
    |> Ash.read!()
    |> Map.new(&{&1.id, &1.workspace_id})
  rescue
    _ -> %{}
  end

  # A run still working owns the ticket's phase; only a finished one gives
  # way to a held dispatch. Reads the queue only for those.
  defp with_holds(views) do
    Enum.map(views, fn view ->
      held =
        if Map.get(view, :state) == :finished,
          do: DispatchQueue.held_item(view.workspace_id, view.ticket_id)

      case held do
        nil -> Map.put(view, :held, nil)
        item -> Map.merge(view, %{held: DispatchQueue.describe(item), phase: :held_for_quota})
      end
    end)
  end

  defp filter_workspace(views, nil), do: views
  defp filter_workspace(views, ws_id), do: Enum.filter(views, &(&1.workspace_id == ws_id))
end
