defmodule Arbiter.MCP.Tools.Task do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for reading and mutating tasks: `ticket_show` /
  `ticket_ready` / `ticket_update_progress` / `ticket_create` / `ticket_update` /
  `ticket_close` / `ticket_reopen` / `ticket_verify` / `ticket_sync_upstream_close` / `dep_add` /
  `dep_remove`. Split out of `Arbiter.MCP.Tools` (see its moduledoc) — called
  back into for the generic arg/serialization helpers it still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Params
  alias Arbiter.Tasks.AssigneeCompat
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Create
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.EffectivePriority
  alias Arbiter.Tasks.History
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueSerializer
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Tasks.Rank
  alias Arbiter.Tasks.Verification
  alias Arbiter.Tasks.WorkerFiling
  alias Arbiter.Usage.Estimate
  alias Arbiter.MCP.Tools.Worker

  require Ash.Query

  @progress_fields ~w(notes qa_notes deployment_notes pr_body)

  # bd-9so315: the one non-text field a worker may set on its own task. It is a
  # self-declaration about its own diff ("this only runs inside the long-lived
  # server"), which the worker is the best-placed party to make and which
  # nothing else in the pipeline can infer — and unlike state/priority it
  # cannot reroute or reprioritize work: its only effect is that the task waits
  # for a human observation before closing.
  @progress_flags ~w(verify_after_deploy)

  # bd-3uy2hn: the fields a `:refine` token may write on a task in its subtree.
  # Deliberately excludes the lifecycle (it belongs to the board and moves only
  # through the transition tools), everything tracker- or assignment-shaped, and `pr_ref` /
  # `target_branch` / `pr_body` — a refine session shapes *what the work is*, not
  # who does it, where it lands, or whether it is done.
  @refine_writable_fields ~w(title description acceptance notes qa_notes deployment_notes
                             issue_type difficulty priority repo verify_after_deploy)

  # bd-13pqcp: `provider_constraint` (where a ticket may run) is deliberately in
  # neither list above — not a worker's progress field, not a refine session's:
  # like `repo` and `target_branch` it is coordinator authority. `ticket_create` /
  # `ticket_update` are coordinator-tier tools, and `refine_field_gate/2`
  # refuses it for a refine token.

  # bd-3uy2hn / coordinator doctrine: Autopilot can claim a task within seconds
  # of it becoming Ready, so any child or edge that must exist before work starts
  # has to exist *before* the promote, not after. Returned on every refine-tier
  # promotion so the rule travels with the action, not just the docs.
  @edges_before_promote "Edges before promote: Autopilot can claim this task within seconds " <>
                          "of it going Ready, so every parent_of child and depends_on edge it " <>
                          "needs must already exist. Promote last. If this is your bound ticket " <>
                          "in a refine session, promote it last of all — promoting it ends the " <>
                          "session and revokes your token immediately, stranding any child not " <>
                          "yet promoted."

  # ---- task_show ----------------------------------------------------------

  @doc "Read a single task. Worker: its own task only. Coordinator: any in its workspace."
  @spec task_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_show(%Scope{} = scope, args) do
    with {:ok, full} <- Params.fetch_bool(args, "full", false),
         {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id) do
      loaded = load_progress(issue)
      result = if(full, do: Tools.serialize_task(loaded), else: serialize_task_slim(loaded))

      # bd-6fkgvo: where the ticket is, in the lifecycle vocabulary, on both
      # views — its stored state, its column, its computed step, what blocks
      # it, and its attention (bd-8nlez1: owner, what it waits on, why, and
      # any hand-off note).
      result =
        result
        |> Map.merge(Projection.payload(Projection.view(issue)))
        |> Map.put(:close_reason, Tools.to_str(issue.close_reason))
        # ES4: `priority` stays the own priority; these say how the ticket is
        # actually scheduled when an epic floor lifts it.
        |> Map.merge(EffectivePriority.fields(issue))

      # Strip pr_body from coordinator full-view (bandwidth; coordinators don't
      # need the body they didn't write). Worker full-view retains it so the
      # worker can verify its own authored body (bd-53xrmi).
      result =
        if full and scope.tier == :coordinator,
          do: Map.delete(result, :pr_body),
          else: result

      # bd-3j4ch4: what tasks like this one have actually cost, as a
      # percentile range. `nil` when the ledger is too thin — never a made-up
      # number, and never absent, so "no estimate yet" can't read as "$0".
      result = Map.put(result, :estimate, Estimate.payload(loaded))

      # bd-18vl9q: the epic cost rollup (design bd-9jj5lf §4). `nil` for a
      # non-epic issue — the field always rides along so callers don't have to
      # branch on `issue_type` to know whether to look for it.
      result = Map.put(result, :epic_rollup, Estimate.epic_cost_rollup(loaded))

      # bd-1defgu: the domain-layer edge read existed (`Dependencies.list/1`)
      # but wasn't reachable from here — full view only, same bandwidth
      # tradeoff as every other field this branch adds.
      #
      # P-13 (D-T-15): and the audit trail (each write with its actor) and what
      # the ticket's current run is doing, which `GET /api/issues/:id` always
      # carried and this view did not.
      result =
        if full do
          result
          |> Map.put(:dependencies, dependency_rows(id))
          |> Map.put(:history, id |> History.recent() |> IssueSerializer.history())
          |> Map.put(:current_run, current_run(id))
        else
          result
        end

      {:ok, result}
    end
  end

  defp current_run(id) do
    case Arbiter.Workers.Current.show(id, limit: 1) do
      %{current: current} -> Worker.current_run_payload(current)
      nil -> nil
    end
  end

  defp dependency_rows(issue_id) do
    case Dependencies.list(issue_id: issue_id) do
      {:ok, rows} -> Enum.map(rows, &Tools.serialize_dependency_edge/1)
      {:error, _} -> []
    end
  end

  # ---- task_ready ---------------------------------------------------------

  @doc """
  List ready tasks in a workspace — exactly the tickets whose column is
  `:ready` (bd-6fkgvo), epics excluded as on the board, in dispatch order
  (effective priority, then rank, age — the §4 key). Coordinator only. The workspace is resolved from the
  optional `workspace` arg, else the scope's bound workspace, else ALL
  workspaces (`Arbiter.Tasks.Workspaces`); the resolved `workspace_id` (`nil`
  for all) is echoed.
  """
  @spec task_ready(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_ready(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      # P-13 (D-T-16): `Projection.ready/2` is the one Ready definition — the
      # same rows `GET /api/issues/ready` returns.
      tasks = ws_id |> Projection.ready() |> Tools.ready_rows(ws_id)

      {:ok, %{tasks: tasks, count: length(tasks), workspace_id: ws_id}}
    end
  end

  # ---- task_update_progress ----------------------------------------------

  @doc """
  The worker's one write: record `notes` / `qa_notes` / `deployment_notes` /
  `pr_body` on its own task (the structured replacement for `arb ticket update
  <id> --qa-notes …`). It cannot move the ticket's state, reprioritize, or touch another
  task. Coordinator: the same narrow write against any task in its workspace.
  """
  @spec task_update_progress(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_update_progress(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, attrs} <- progress_attrs(args),
         {:ok, attrs} <- refine_field_gate(scope, attrs) do
      case Ash.update(issue, attrs, action: :update) do
        {:ok, updated} -> {:ok, Tools.serialize_ticket(updated, args)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ======================================================================
  # Phase 2 — coordinator-only mutating tools (docs/mcp-server-design.md §8)
  # ======================================================================

  # ---- task_create --------------------------------------------------------

  @doc """
  Create a task in a workspace. The target workspace is resolved from the optional
  `workspace` arg (name or id), else the scope's bound workspace, else the sole
  workspace — and fails (`multiple workspaces; pass workspace …`) rather than
  guess when several exist. `workspace_id` is then forced onto the task. Backs
  onto `Ash.create(Issue, …)` (the same path `arb create` / the REST
  `POST /api/issues` take), so a workspace with a tracker configured still mirrors
  the new task upstream.

  An optional `parent_id` attaches the new task as a `parent_of` child of an
  existing task in the same workspace, in one call. It is also handed to
  `Issue.create`, so a child of a tracker-linked parent defaults from the
  parent's ticket per `tracker.child_policy` instead of minting its own (#1973);
  a refine session's children are always context-only.

  For a `:refine` scope (bd-3uy2hn) the parent is not optional: it defaults to the
  bound issue and must be the bound issue or one of its descendants, so a refine
  token cannot file a task outside its subtree. The parent is authorized *before*
  the task is created — a refused create leaves nothing behind. The same
  `refine_field_gate/2` that narrows `ticket_update` also runs here, so a refine
  session cannot set on create (`tracker_ref`, `target_branch`, …)
  what it would be refused on update.
  """
  @spec task_create(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_create(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.resolve_workspace_id(scope, args),
         :ok <- authorize_worker_create(scope, args, ws_id),
         {:ok, title} <- Tools.require_string(args, "title"),
         {:ok, parent_id} <- create_parent(scope, args, ws_id),
         {:ok, force?} <- Params.fetch_bool(args, "force", false),
         {:ok, attrs} <- Tools.collect_attrs(args, task_create_spec()),
         # Gate *before* title/workspace_id are forced on: those two are set by
         # the tool, not by the caller, and a refine session is allowed both.
         {:ok, attrs} <- refine_field_gate(scope, attrs) do
      attrs =
        attrs
        |> Map.put("title", title)
        |> Map.put("workspace_id", ws_id)
        |> put_tracker_parent(scope, parent_id)

      opts = [
        force: force?,
        created_by: Arbiter.PaperTrail.actor_label(scope)
      ]

      case Create.run(attrs, opts) do
        {:ok, issue, warnings} ->
          {:ok,
           issue
           |> Tools.serialize_ticket(args)
           |> with_warnings(warnings)
           |> with_deprecation_warnings(args)
           |> with_parent_id(parent_id)}

        {:duplicate, dup} ->
          {:error, duplicate_error(dup)}

        {:partial, issue, failures} ->
          {:error, partial_error(scope, issue, failures, parent_id)}

        {:error, %{__exception__: true} = err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}

        {:error, _} = err ->
          err
      end
    end
  end

  defp with_warnings(result, []), do: result
  defp with_warnings(result, warnings), do: Map.put(result, :warnings, warnings)

  defp with_parent_id(result, nil), do: result
  defp with_parent_id(result, parent_id), do: Map.put(result, :parent_id, parent_id)

  # `force: true` skips dedup (the REST/CLI/dashboard escape hatch).
  defp duplicate_error({:local_dup, matches}) do
    ids = Enum.map_join(matches, ", ", & &1.id)

    {:conflict,
     "an open ticket with this title already exists (#{ids}); pass `force: true` to file it anyway",
     %{matches: Enum.map(matches, &%{id: &1.id, title: &1.title, state: to_string(&1.state)})}}
  end

  defp duplicate_error({:tracker_dup, matches}) do
    urls = Enum.map_join(matches, ", ", &(Map.get(&1, :url) || Map.get(&1, :ref) || "?"))

    {:conflict,
     "an open tracker issue with this title already exists (#{urls}); pass `force: true` to file it anyway",
     %{matches: Enum.map(matches, &%{ref: &1[:ref], title: &1[:title], url: &1[:url]})}}
  end

  @doc """
  The error for a `{:partial, issue, failures}` create (`Arbiter.Tasks.Create`):
  the ticket **exists**, but the tracker mirror and/or an edge failed. An error
  response, not a clean create — and the message names the id.

  The edge half of the contract is deliberate: an issue cannot be un-created
  (`Ash.destroy` on a task whose paper-trail version row exists fails the
  version table's foreign key), so there is no compensating delete. `Create`
  preflights every endpoint, which leaves only a race (a parent deleted between
  the preflight and the write) to land here. For a refine session the unparented
  task sits outside the bound subtree and a `parent_of` add needs both endpoints
  inside it, so the message says who can re-attach it.

  Public so that contract is directly testable.
  """
  @spec partial_error(Scope.t(), Issue.t(), [Create.failure()], String.t() | nil) ::
          {atom(), String.t(), map()}
  def partial_error(scope, issue, failures, parent_id) do
    upstream? = Enum.any?(failures, &(&1.kind == :upstream_create_failed))
    kind = if upstream?, do: :bad_gateway, else: :invalid

    {kind, partial_message(scope, issue, failures, parent_id),
     %{task_id: issue.id, failures: Enum.map(failures, &Map.take(&1, [:kind, :message]))}}
  end

  defp partial_message(scope, issue, failures, parent_id) do
    Enum.map_join(failures, "; ", fn
      %{kind: :upstream_create_failed, message: message} ->
        "ticket #{issue.id} was created locally, but the tracker mirror failed: #{message} — " <>
          "re-link it with ticket_update tracker_ref rather than filing it again"

      %{kind: :edge_failed, message: message} ->
        edge_hint(scope, message, issue, parent_id)
    end)
  end

  defp edge_hint(%Scope{tier: :refine}, message, issue, parent_id) do
    message <>
      " — it is filed in the workspace Backlog with no parent, which puts it outside this " <>
      "session's subtree: ask a coordinator to attach it with dep_add, or file it again once " <>
      "#{parent_id || "the parent"} is reachable (#{issue.id})"
  end

  defp edge_hint(%Scope{}, message, _issue, _parent_id), do: message

  # bd-dtfe9x (D-T-21): a worker files exactly what `POST /api/issues` lets it
  # (`ApiPolicy :issue_create`) — a child of its own task, in its own workspace,
  # with only the descriptive fields. One rule set: `Arbiter.Tasks.WorkerFiling`.
  # `workspace` is this tool's name for REST's `workspace_id`; it has been
  # resolved (and confined to the worker's own workspace) by now.
  defp authorize_worker_create(%Scope{tier: :worker} = scope, args, ws_id) do
    params = args |> Map.delete("workspace") |> Map.put("workspace_id", ws_id)

    case WorkerFiling.authorize_create(scope, params) do
      :ok -> :ok
      {:error, why} -> {:error, {:unauthorized, "a worker-tier token #{why}"}}
    end
  end

  defp authorize_worker_create(_scope, _args, _ws_id), do: :ok

  # #1973: tell `Issue.create` who the parent is, so a child of a tracker-linked
  # parent defaults from the parent's linkage (per `tracker.child_policy`) rather
  # than minting its own ticket. A refine session is by definition decomposing an
  # already-tracked issue, so its children are context-only whatever the policy.
  defp put_tracker_parent(attrs, _scope, nil), do: attrs

  defp put_tracker_parent(attrs, %Scope{tier: :refine}, parent_id) do
    attrs
    |> Map.put("parent_id", parent_id)
    |> Map.put("tracker_child_policy", :context_only)
  end

  defp put_tracker_parent(attrs, %Scope{}, parent_id), do: Map.put(attrs, "parent_id", parent_id)

  # Resolve and authorize the `parent_of` parent for a create. `{:ok, nil}` means
  # "file it unparented", which only a non-refine scope can ask for.
  defp create_parent(%Scope{} = scope, args, ws_id) do
    named = Tools.fetch_string(args, "parent_id")
    requested = if scope.tier == :refine, do: named || scope.issue_id, else: named

    if is_nil(requested) do
      {:ok, nil}
    else
      with {:ok, parent} <- Tools.fetch_task_in_workspace(ws_id, requested),
           :ok <- Tools.authorize_subtree(scope, parent.id) do
        {:ok, parent.id}
      end
    end
  end

  # bd-1ozks5: `assignee` is still accepted for one release — the local
  # assignee field is gone, so it's ignored and reported back as a
  # `warnings` entry rather than rejected outright.
  defp with_deprecation_warnings(result, args) when is_map(args) do
    with_deprecation_warnings(result, AssigneeCompat.warnings(args))
  end

  defp with_deprecation_warnings(result, []), do: result

  defp with_deprecation_warnings(result, warnings) when is_list(warnings),
    do: Map.update(result, :warnings, warnings, &(&1 ++ warnings))

  # Narrow a write to the fields a `:refine` token may set (bd-3uy2hn). Rejecting
  # a disallowed field is deliberate rather than silently dropping it: a refine
  # agent that asked to close a task must be told it cannot, not told "updated"
  # and left believing it did.
  #
  # Works on both attr shapes in this module — string keys from `collect_attrs/2`
  # and atom keys from `progress_attrs/1`.
  defp refine_field_gate(%Scope{tier: :refine}, attrs) do
    case Enum.reject(Map.keys(attrs), &(to_string(&1) in @refine_writable_fields)) do
      [] ->
        {:ok, attrs}

      refused ->
        {:error,
         {:unauthorized,
          "a refine session may not write " <>
            Enum.map_join(Enum.sort(refused), ", ", &to_string/1) <>
            " — it may set only: " <> Enum.join(@refine_writable_fields, ", ")}}
    end
  end

  defp refine_field_gate(%Scope{}, attrs), do: {:ok, attrs}

  # ---- task_update --------------------------------------------------------

  @doc """
  Update a task's fields in the scope's workspace (priority / title / …).
  Coordinator only. It never moves the lifecycle `state` — that goes through
  `ticket_promote` / `ticket_demote` / `ticket_close` / `ticket_reopen`, which
  run the transitions and their side effects. Backs onto the task's `:update`
  action.
  """
  @spec task_update(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_update(%Scope{} = scope, args) do
    assignee_warnings = AssigneeCompat.warnings(args)

    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, attrs} <- Tools.collect_attrs(args, task_update_spec()),
         {:ok, attrs} <- refine_field_gate(scope, attrs) do
      case {map_size(attrs), assignee_warnings} do
        {0, []} ->
          {:error, {:invalid, "provide at least one field to update"}}

        {0, warnings} ->
          # Only a deprecated `assignee` was passed — nothing to write, but
          # that isn't a failure: report the task back with the warning.
          {:ok, issue |> Tools.serialize_ticket(args) |> with_deprecation_warnings(warnings)}

        {_, warnings} ->
          case Ash.update(issue, attrs, action: :update) do
            {:ok, updated} ->
              {:ok,
               updated |> Tools.serialize_ticket(args) |> with_deprecation_warnings(warnings)}

            {:error, err} ->
              {:error, {:invalid, Tools.ash_error_message(err)}}
          end
      end
    end
  end

  # ---- task_close ---------------------------------------------------------

  @doc """
  Close a task in the scope's workspace via the `:close` action (moves it to
  `:closed`, runs the worker/worktree teardown, and syncs the close upstream by default
  when the task carries a `tracker_ref`). Pass `close_upstream: false` to leave
  the linked tracker issue open. Coordinator only.
  """
  @spec task_close(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_close(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, close_upstream} <- Tools.fetch_bool(args, "close_upstream", true) do
      attrs =
        %{close_upstream: close_upstream}
        |> Tools.maybe_put(:reason, Tools.fetch_string(args, "reason"))

      case Ash.update(issue, attrs, action: :close) do
        {:ok, closed} -> {:ok, Tools.serialize_ticket(closed, args)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_reopen --------------------------------------------------------

  @doc """
  Reopen a closed task in the scope's workspace via the `:reopen` action (clears
  `closed_at`, returns it to `:queued` and the ready queue, and best-effort
  reopens the linked tracker issue). Coordinator only. Reopening is the only
  supported path out of `:closed` — the `:update` FSM rejects that transition —
  so a non-closed task is reported as an operational error.
  """
  @spec task_reopen(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_reopen(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      case Ash.update(issue, %{}, action: :reopen) do
        {:ok, reopened} -> {:ok, Tools.serialize_ticket(reopened, args)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_promote --------------------------------------------------------

  @doc """
  Promote a task from Backlog to the queue (state `:backlog` → `:queued`) via
  the `:promote_to_ready` action. Coordinator only. Idempotent by design —
  promoting an already-queued task is a no-op success, not an error.
  """
  @spec task_promote(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_promote(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      promote_args =
        case Map.get(args, "acceptance_waived") do
          reason when is_binary(reason) -> %{acceptance_waived: reason}
          _ -> %{}
        end

      case Ash.update(issue, promote_args, action: :promote_to_ready) do
        {:ok, promoted} ->
          {:ok, with_promotion_note(Tools.serialize_ticket(promoted, args), scope)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # The edges-before-promote rule, on the response of every refine-tier
  # promotion. Coordinators already own the scheduling doctrine; a refine session
  # is a fresh agent in a narrow scope, and the one ordering mistake it can make
  # that Arbiter cannot undo is promoting before wiring.
  defp with_promotion_note(result, %Scope{tier: :refine}),
    do: Map.put(result, :promotion_note, @edges_before_promote)

  defp with_promotion_note(result, %Scope{}), do: result

  # ---- task_demote --------------------------------------------------------

  @doc """
  Move a task back to Backlog (state `:queued` | `:active` | `:merging` →
  `:backlog`) via the `demote` transition. Inverse of `ticket_promote`.
  Coordinator only, and idempotent.

  Refuses a task with a live worker, and one that is verifying or closed.
  """
  @spec task_demote(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def task_demote(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      case Ash.update(issue, %{}, action: :return_to_backlog) do
        {:ok, demoted} ->
          {:ok, Tools.serialize_ticket(demoted, args)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- ticket_resume_review -------------------------------------------------

  @doc """
  Clear a tripped ReviewPatrol circuit breaker on a ticket (P-14) via the typed
  `:resume_review` action — the same one REST
  (`POST /api/issues/:id/resume_review`) and `arb ticket update --resume-review`
  use, instead of raw `circuit_breaker_*` writes through `ticket_update`.
  Coordinator only, idempotent. The head the breaker tripped at is watermarked,
  so the next ReviewPatrol tick does not re-trip on the same commit.
  """
  @spec ticket_resume_review(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def ticket_resume_review(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      case Ash.update(issue, %{}, action: :resume_review) do
        {:ok, resumed} ->
          {:ok, Map.put(Tools.serialize_ticket(resumed, args), :circuit_breaker_tripped, false)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_rank ------------------------------------------------------------

  @doc """
  Reorder a task inside its workspace's rank order (bd-djapyj): the space
  `board/scheduler.ex` and Autopilot dispatch read (priority, then rank,
  then age). Coordinator only. Backs onto the `:set_rank` action, the same
  one the CLI (`arb ticket rank`) and REST (`PATCH /api/issues/:id/rank`)
  use. Exactly one of `top`, `bottom`, `before_id`, `after_id` is required.
  Never changes priority — ranking before/after a task in a different
  priority band only orders within rank, it does not move the task into
  that band.
  """
  @spec task_rank(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_rank(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, rank_args} <- rank_args(args) do
      case Rank.move(issue, rank_args) do
        {:ok, ranked} ->
          {:ok, ranked |> Tools.serialize_ticket(args) |> Map.merge(Rank.band_fields(ranked))}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  defp rank_args(args) do
    with {:ok, top?} <- Params.fetch_bool(args, "top", false),
         {:ok, bottom?} <- Params.fetch_bool(args, "bottom", false) do
      forms =
        [
          top? && %{position: :top},
          bottom? && %{position: :bottom},
          is_binary(args["before_id"]) && %{before_id: args["before_id"]},
          is_binary(args["after_id"]) && %{after_id: args["after_id"]}
        ]
        |> Enum.reject(&(&1 == false))

      case forms do
        [form] -> {:ok, form}
        _ -> {:error, {:invalid, "give exactly one of: top, bottom, before_id, after_id"}}
      end
    end
  end

  # ---- epic_floor -------------------------------------------------------------

  @doc """
  Set or clear an epic's priority floor (ES2, bd-3e7inj;
  `docs/design/epic-aware-scheduling.md` §6.2). Coordinator tier, which is
  what both the operator's and the coordinator's tokens mint; a worker never
  sees the tool. Backs onto `:set_floor` — the same action REST
  (`PATCH /api/issues/:id/floor`), `arb epic floor` and the epic page use.
  `floor_priority` is required: 1..3, `"P1"`..`"P3"`, or `null` / `"none"` to
  clear. The epic's own `priority` is never touched.
  """
  @spec epic_floor(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def epic_floor(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, raw} <- floor_arg(args),
         {:ok, floor} <- parse_floor(raw) do
      case Ash.update(issue, %{floor_priority: floor}, action: :set_floor, actor: scope) do
        {:ok, floored} ->
          {:ok, floored |> Tools.serialize_ticket(args) |> Map.put(:floor_priority, floor)}

        {:error, err} ->
          {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  defp floor_arg(%{"floor_priority" => raw}), do: {:ok, raw}

  defp floor_arg(_args),
    do: {:error, {:invalid, "floor_priority is required (P1, P2, P3 or null to clear)"}}

  defp parse_floor(raw) do
    case Arbiter.Tasks.Floor.parse(raw) do
      {:ok, floor} -> {:ok, floor}
      {:error, message} -> {:error, {:invalid, message}}
    end
  end

  # ---- ticket_handoff / ticket_handback -------------------------------------

  @doc """
  The coordinator hands a ticket's attention to the operator, with a `note`
  saying what the operator has to do (bd-8nlez1,
  `Arbiter.Tasks.Attention.hand_off/3`). Coordinator only.
  """
  @spec ticket_handoff(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def ticket_handoff(%Scope{} = scope, args), do: move_attention(scope, args, :operator)

  @doc """
  The operator hands a ticket's attention back to the coordinator, with an
  optional `note` (bd-8nlez1). The coordinator gets a fresh clock and attempt
  budget. Coordinator tier (the operator's MCP and CLI both use it).
  """
  @spec ticket_handback(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def ticket_handback(%Scope{} = scope, args), do: move_attention(scope, args, :coordinator)

  defp move_attention(scope, args, to) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      case Attention.hand_off(issue.id, to, Tools.fetch_string(args, "note")) do
        {:ok, _attention} ->
          # P-13 (D-T-13): the updated ticket — `attention` is part of its
          # projection — as `POST /api/issues/:id/handoff` and the CLI return it.
          {:ok, moved_ticket(issue.id, args)}

        {:error, reason} ->
          {:error, {:invalid, Attention.describe_error(reason)}}
      end
    end
  end

  # The ticket as the move left it, with its projection (`attention` included) —
  # the shape `POST /api/issues/:id/handoff` renders (`IssueJSON.handoff/1`).
  defp moved_ticket(id, args) do
    issue = Ash.get!(Issue, id)
    IssueSerializer.row(Tools.serialize_ticket(issue, args), Projection.view(issue))
  end

  # ---- task_sync_upstream_close --------------------------------------------

  @doc """
  Push a close to the linked tracker for a task that's already `:closed`
  locally but never synced upstream. Coordinator only. Backs onto the
  `:sync_upstream_close` action, which requires the task to already be
  `:closed` — a non-closed task is reported as an operational error — and
  makes no local state/closed_at change or close-time side effect (no
  StopWorker/CleanupWorktree/parent rollup).
  """
  @spec task_sync_upstream_close(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def task_sync_upstream_close(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id) do
      case Ash.update(issue, %{}, action: :sync_upstream_close) do
        {:ok, synced} -> {:ok, Tools.serialize_ticket(synced, args)}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # ---- task_verify ---------------------------------------------------------

  @doc """
  Record the restart-and-observe result for a task in state `:verifying`
  (bd-9so315). Coordinator only.

  Exactly one of `observed` / `failed` must be given, and its value is the
  evidence — what was actually seen on the running server. `observed` closes
  the task; `failed` reopens it for another attempt. Either way the evidence is
  persisted on the task, so the claim is auditable rather than remembered.
  """
  @spec task_verify(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_verify(%Scope{} = scope, args) do
    with {:ok, id} <- Tools.resolve_task_id(scope, args),
         {:ok, issue} <- Tools.fetch_task(scope, args, id),
         :ok <- Tools.authorize_subtree(scope, issue.id),
         {:ok, outcome, evidence} <- verify_verdict(args) do
      case Verification.record_outcome(issue, outcome, evidence) do
        {:ok, updated} -> {:ok, Tools.serialize_ticket(updated, args)}
        {:error, reason} -> {:error, {:invalid, verify_error_message(reason)}}
      end
    end
  end

  defp verify_verdict(args) do
    observed = Tools.fetch_string(args, "observed")
    failed = Tools.fetch_string(args, "failed")

    case {observed, failed} do
      {nil, nil} ->
        {:error, {:invalid, "provide exactly one of: observed (evidence) or failed (evidence)"}}

      {obs, fail} when is_binary(obs) and is_binary(fail) ->
        {:error, {:invalid, "provide only one of: observed or failed, not both"}}

      {obs, nil} ->
        {:ok, :observed, obs}

      {nil, fail} ->
        {:ok, :failed, fail}
    end
  end

  defp verify_error_message(:not_awaiting_verification),
    do:
      "task is not awaiting verification — only a task in state " <>
        "verifying can record a verify result"

  defp verify_error_message(:evidence_required),
    do: "evidence text is required: say what you observed on the running server"

  defp verify_error_message({:invalid, %{} = err}), do: Tools.ash_error_message(err)
  defp verify_error_message({:invalid, msg}) when is_binary(msg), do: msg
  defp verify_error_message(other), do: inspect(other)

  # ---- dep_add ------------------------------------------------------------

  @doc """
  Add a dependency edge between two tasks in the scope's workspace. Coordinator,
  or a worker adding a `parent_of` edge from its own task to an unparented
  ticket (`Arbiter.Tasks.WorkerFiling`, the `POST /api/dependencies` rule). Both endpoints must resolve inside the workspace (a cross-workspace id is
  reported not-found, which is why the scope checks stay here and are not left
  to the facade's `:cross_workspace` error).

  The write itself goes through `Arbiter.Tasks.Dependencies.add/4` (bd-apj0gq),
  so it also gets the cycle guard and the `parent_of` auto-close re-evaluation.
  """
  @spec dep_add(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_add(%Scope{} = scope, args) do
    with {:ok, from} <- Tools.require_string(args, "from_issue_id"),
         {:ok, to} <- Tools.require_string(args, "to_issue_id"),
         {:ok, type} <- Tools.require_enum(args, "type", Dependency.types()),
         :ok <- authorize_worker_edge(scope, args),
         {:ok, from_task} <- Tools.fetch_task(scope, args, from),
         {:ok, _to_task} <- Tools.fetch_task_in_workspace(from_task.workspace_id, to),
         :ok <- Tools.authorize_subtree_edge(scope, from, to, type) do
      opts =
        []
        |> Tools.maybe_put_kw(:notes, Tools.fetch_string(args, "notes"))
        |> Tools.maybe_put_kw(:created_by, Arbiter.Params.actor_label(scope))

      case Dependencies.add(from, to, type, opts) do
        {:ok, dep} -> {:ok, Tools.serialize_dependency(dep)}
        {:error, reason} -> Tools.dependency_error(reason)
      end
    end
  end

  # bd-dtfe9x (D-T-21): a worker adds what `POST /api/dependencies` lets it
  # (`ApiPolicy :dependency_add`) — a `parent_of` edge from its own task to an
  # unparented ticket in its workspace, and no caller-set `created_by`/`notes`.
  defp authorize_worker_edge(%Scope{tier: :worker} = scope, args) do
    case WorkerFiling.authorize_dependency(scope, args) do
      :ok -> :ok
      {:error, why} -> {:error, {:unauthorized, "a worker-tier token #{why}"}}
    end
  end

  defp authorize_worker_edge(_scope, _args), do: :ok

  # ---- dep_remove ---------------------------------------------------------

  @doc """
  Remove dependency edges between two tasks in the scope's workspace. Coordinator
  only. With no `type` every edge between the pair is removed; with a `type`
  only that edge. Idempotent — removing an absent edge reports `removed: 0`.

  Routed through `Arbiter.Tasks.Dependencies.remove/3` (bd-apj0gq), so detaching
  an epic's last open child now re-evaluates the parent's `auto_close`.
  """
  @spec dep_remove(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_remove(%Scope{} = scope, args) do
    with {:ok, from} <- Tools.require_string(args, "from_issue_id"),
         {:ok, to} <- Tools.require_string(args, "to_issue_id"),
         {:ok, type} <- Tools.optional_enum(args, "type", Dependency.types()),
         {:ok, from_task} <- Tools.fetch_task(scope, args, from),
         {:ok, _to_task} <- Tools.fetch_task_in_workspace(from_task.workspace_id, to),
         :ok <- Tools.authorize_subtree_edge(scope, from, to, type) do
      case Dependencies.remove(from, to, type) do
        {:ok, removed} -> {:ok, %{from_issue_id: from, to_issue_id: to, removed: removed}}
        {:error, reason} -> Tools.dependency_error(reason)
      end
    end
  end

  # ---- dep_list -----------------------------------------------------------

  @doc """
  List dependency edges in the scope's workspace. Coordinator or worker
  (bd-1defgu) — a worker with no `workspace` arg sees its own workspace's
  edges, exactly like `dep_add` / `dep_remove` already scope a worker's
  writes; naming a *different* workspace is `:unauthorized`, the same rule
  `Tools.authorized_workspace/2` already enforces everywhere else.

  With no `issue_id`, lists every edge in the resolved workspace. With
  `issue_id`, lists that issue's edges in both directions instead (the issue
  must resolve inside the same workspace-authorization the scope already
  has — a cross-workspace `issue_id` is not-found, not leaked).

  Routed through `Arbiter.Tasks.Dependencies.list/1` (bd-1defgu): a symmetric
  edge (`conflicts_with`) is never doubled — it appears once, from wherever
  you look at it.
  """
  @spec dep_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def dep_list(%Scope{} = scope, args) do
    with {:ok, type} <- Tools.optional_enum(args, "type", Dependency.types()) do
      case Tools.fetch_string(args, "issue_id") do
        nil -> dep_list_workspace(scope, args, type)
        issue_id -> dep_list_issue(scope, args, issue_id, type)
      end
    end
  end

  defp dep_list_workspace(scope, args, type) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args),
         {:ok, rows} <- list_edges(workspace_id: ws_id, type: type) do
      {:ok, Map.put(serialize_dep_list(rows), :workspace_id, ws_id)}
    end
  end

  defp dep_list_issue(scope, args, issue_id, type) do
    with {:ok, _issue} <- Tools.fetch_task(scope, args, issue_id),
         {:ok, rows} <- list_edges(issue_id: issue_id, type: type) do
      {:ok, serialize_dep_list(rows)}
    end
  end

  defp list_edges(opts) do
    case Dependencies.list(opts) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> Tools.dependency_error(reason)
    end
  end

  defp serialize_dep_list(rows) do
    deps = Enum.map(rows, &Tools.serialize_dependency_edge/1)
    %{dependencies: deps, count: length(deps)}
  end

  # Load the child-progress rollup calcs for a task so the serializer can emit
  # `child_total` / `child_closed`. Best-effort: on any load error the task is
  # returned unchanged (the serializer then omits the progress fields).
  defp load_progress(%Issue{} = issue) do
    Ash.load!(issue, [:child_total, :child_closed])
  rescue
    _ -> issue
  end

  # Keep only the allowed progress fields; require at least one.
  defp progress_attrs(args) do
    text =
      for field <- @progress_fields, (val = Tools.fetch_string(args, field)) != nil, into: %{} do
        {String.to_existing_atom(field), val}
      end

    flags =
      for field <- @progress_flags, is_boolean(val = Map.get(args, field)), into: %{} do
        {String.to_existing_atom(field), val}
      end

    attrs = Map.merge(text, flags)

    if map_size(attrs) == 0 do
      {:error,
       {:invalid,
        "provide at least one of: #{Enum.join(@progress_fields ++ @progress_flags, ", ")}"}}
    else
      {:ok, attrs}
    end
  end

  defp task_create_spec do
    [
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"verify_after_deploy", :boolean},
      {"provider_constraint", :map},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"target_branch", :string},
      {"repo", :string}
    ]
  end

  defp task_update_spec do
    [
      {"title", :string},
      {"description", :string},
      {"acceptance", :string},
      {"notes", :string},
      {"qa_notes", :string},
      {"deployment_notes", :string},
      {"priority", :integer},
      {"difficulty", :integer},
      {"issue_type", {:enum, Issue.issue_types()}},
      {"auto_close", :boolean},
      {"verify_after_deploy", :boolean},
      {"provider_constraint", :map},
      {"tracker_type", {:enum, Issue.tracker_types()}},
      {"tracker_ref", :string},
      {"tracker_context_type", {:enum, Issue.tracker_types()}},
      {"tracker_context_ref", :string},
      {"pr_ref", :string},
      {"target_branch", :string},
      {"repo", :string}
    ]
  end

  # Slim serializer for worker task_show (full: false). Omits review/human
  # fields that bloat worker context without aiding task execution.
  defp serialize_task_slim(%Issue{} = i) do
    %{
      id: i.id,
      title: i.title,
      description: i.description,
      acceptance: i.acceptance,
      acceptance_waived: i.acceptance_waived,
      state: Tools.to_str(i.state),
      priority: i.priority,
      difficulty: i.difficulty,
      issue_type: Tools.to_str(i.issue_type)
    }
    |> Tools.put_progress(i)
  end
end
