defmodule ArbiterWeb.Api.IssueController do
  @moduledoc """
  REST endpoints for `Arbiter.Tasks.Issue`.

  Routes:

    * `POST   /api/issues`             — :create
    * `POST   /api/issues/batch`       — :batch_create (many tickets + edges, atomic)
    * `GET    /api/issues`             — :index (filters: state, priority,
                                        difficulty, issue_type, workspace_id)
    * `GET    /api/issues/ready`       — :ready (Issue.ready/1)
    * `GET    /api/issues/:id`         — :show
    * `PATCH  /api/issues/:id`         — :update
    * `POST   /api/issues/:id/close`   — :close (body: optional `reason`)
    * `POST   /api/issues/:id/reopen`  — :reopen
    * `POST   /api/issues/:id/promote` — :promote
    * `POST   /api/issues/:id/demote`  — :demote (return to backlog)
    * `POST   /api/issues/:id/resume_review` — :resume_review (clear a tripped
      ReviewPatrol circuit breaker; the typed replacement for PATCHing
      `circuit_breaker_*`, P-14)
    * `PATCH  /api/issues/:id/rank`    — :rank (body: one of `top: true`,
      `bottom: true`, `before_id: <id>`, `after_id: <id>`) — reorders the
      ticket inside its workspace's rank order (bd-djapyj)
    * `PATCH  /api/issues/:id/floor`   — :floor (body: `floor_priority` —
      1..3, `"P1"`..`"P3"`, or `null` / `"none"` to clear) — sets an epic's
      priority floor via `:set_floor` (ES2, bd-3e7inj). Coordinator tier;
      a worker token is refused (403) by `ArbiterWeb.ApiPolicy`
    * `POST   /api/issues/:id/verify`  — :verify (body: `outcome` +
      `evidence`) — records the post-merge restart-and-observe result
      (bd-9so315)
    * `POST   /api/issues/:id/permission` — :permission (body: `permission`,
      optional `deny` + `reason`) — grants or denies a requested permission
      (G15b, bd-lozakf; `arb ticket permit`)

  P-14: `POST` / `PATCH` take only the fields in `Arbiter.Tasks.IssueFields`
  (a coordinator's user-facing set). ReviewPatrol / circuit-breaker /
  `pr_opened_*` / `skills` state and the `change_origin` audit label are
  refused with 422; a key the action does not know at all is still Ash's
  `NoSuchInput` 422. `POST` goes through `Arbiter.Tasks.Create`, which also
  attaches the `parent_of` edge (`parent_id`) and `blocks` edges (`deps`).

  bd-1ozks5: the local `Issue.assignee` field was removed. `POST /api/issues`
  and `PATCH /api/issues/:id` still accept an `assignee` param — for one
  release it's silently dropped and reported back as a `warnings` entry,
  rather than rejected outright and breaking an existing coordinator script.
  """

  use ArbiterWeb, :controller

  require Ash.Query

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Params
  alias Arbiter.Tasks.AcceptanceLint
  alias Arbiter.Tasks.AssigneeCompat
  alias Arbiter.Tasks.BatchCreate
  alias Arbiter.Tasks.BulkRead
  alias Arbiter.Tasks.BulkResult
  alias Arbiter.Tasks.Create
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.EffectivePriority
  alias Arbiter.Tasks.History
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueFields
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Tasks.PermissionDecision
  alias Arbiter.Tasks.Permissions
  alias Arbiter.Tasks.ReadyHolds
  alias Arbiter.Tasks.Verification
  alias Arbiter.Usage.Estimate
  alias Arbiter.Workers.Current
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  @atom_fields ~w(issue_type tracker_type)a
  @filter_fields ~w(state priority difficulty issue_type)a

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, filters} <- build_filters(params),
         {:ok, include} <- parse_include(params) do
      filters = if ws_id, do: [{:workspace_id, ws_id} | filters], else: filters
      query = Ash.Query.do_filter(Ash.Query.new(Issue), filters)

      # bd-7sxpln: `ids=a,b` is the bulk show — the named tickets (still
      # filtered by the rest), unknown ones reported in `not_found`.
      {query, wanted} = restrict_ids(query, params)

      case Ash.read(query) do
        {:ok, issues} ->
          issues = order_by_ids(issues, wanted)
          not_found = if wanted, do: wanted -- Enum.map(issues, & &1.id)
          # Epics carry `child_closed`/`child_total`; `include=` adds the
          # parent/dependency edges — each one batch read, never per ticket.
          issues = BulkRead.load(issues)
          edges = if include == [], do: %{}, else: BulkRead.edges(issues)
          extras = Map.new(issues, &{&1.id, BulkRead.row_extras(&1, include, edges)})
          # P-13 (D-T-17): every row carries its lifecycle projection (`column`,
          # `step`, `blocked_by`, ...), as the MCP `ticket_list` rows do.
          views = Projection.views(issues)

          render(conn, :index,
            issues: issues,
            views: views,
            extras: extras,
            not_found: not_found,
            holds: holds_for(views, ws_id),
            workspace_id: ws_id
          )

        {:error, _} = err ->
          err
      end
    end
  end

  defp parse_include(params) do
    case BulkRead.parse_include(params["include"]) do
      {:ok, include} -> {:ok, include}
      {:error, msg} -> {:error, {:invalid_request, msg}}
    end
  end

  defp restrict_ids(query, %{"ids" => raw}) when is_binary(raw) do
    ids = raw |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.uniq()
    {Ash.Query.filter(query, id in ^ids), ids}
  end

  defp restrict_ids(query, _params), do: {query, nil}

  defp order_by_ids(issues, nil), do: issues

  defp order_by_ids(issues, ids) do
    by_id = Map.new(issues, &{&1.id, &1})
    for id <- ids, is_map_key(by_id, id), do: by_id[id]
  end

  def ready(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      # P-13 (D-T-16): `Projection.ready/2` is the one Ready definition — the
      # same rows MCP `ticket_ready` returns, in dispatch order (the §4 key,
      # an epic's floor included) — and each carries its projection and, when
      # the scheduler is holding it, its `hold_reason`.
      rows = Projection.ready(ws_id)
      views = Map.new(rows, fn {issue, view} -> {issue.id, view} end)

      render(conn, :index,
        issues: Enum.map(rows, &elem(&1, 0)),
        views: views,
        holds: if(rows == [], do: %{}, else: ReadyHolds.for_workspace(ws_id)),
        workspace_id: ws_id
      )
    end
  end

  # bd-6fkgvo: every open ticket in a workspace with its lifecycle projection
  # (state, column, step, blocked_by, attention), epics excluded as on the
  # board, in dispatch order — what `arb prime` groups into its sections.
  def lifecycle(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      tickets = Projection.open(ws_id)

      render(conn, :lifecycle,
        tickets: tickets,
        holds: ReadyHolds.for_workspace(ws_id),
        workspace_id: ws_id
      )
    end
  end

  # The board's read is only worth paying for when a Ready card is in the page.
  defp holds_for(views, ws_id) do
    if Enum.any?(views, fn {_id, view} -> view.column == :ready end),
      do: ReadyHolds.for_workspace(ws_id),
      else: %{}
  end

  def show(conn, %{"id" => id}) do
    case Ash.get(Issue, id, load: [:child_total, :child_closed]) do
      # bd-3j4ch4: the cost estimate rides along on the single-issue read so
      # `arb ticket show` renders it without a second round trip. Only here —
      # the index would pay a ledger scan per row for a number nobody reads
      # in a list.
      # bd-18vl9q: same for the epic cost rollup — nil for a non-epic issue.
      # bd-1defgu: same reasoning for dependency edges — `arb ticket show` was
      # write-only for them; the read already existed
      # (`Arbiter.Tasks.Dependencies.list/1`), it just wasn't reachable here.
      # bd-6fkgvo: and where the ticket is in the lifecycle (its projection)
      # and what its current run is doing, which `arb ticket show` prints.
      {:ok, issue} ->
        {:ok, dependencies} = Dependencies.list(issue_id: id)
        live = live_workers()

        render(conn, :show,
          issue: issue,
          estimate: Estimate.payload(issue),
          spend: spend_payload(issue),
          epic_rollup: Estimate.epic_cost_rollup(issue),
          dependencies: dependencies,
          lifecycle: Projection.view(issue, workers: live),
          priority_fields: EffectivePriority.fields(issue),
          current_run: current_run(id, live),
          # bd-6i7yzq: the recent audit history, each write with its actor.
          history: History.recent(id),
          # bd-54m4vv: carried but not yet granted (an operator-grant permission
          # a coordinator declared), so `arb ticket show` can say so.
          pending_permissions: Permissions.pending(issue)
        )

      {:error, _} = err ->
        err
    end
  end

  # The ticket's actual spend, per pass kind. Best-effort: a ledger read that
  # fails costs `arb ticket show` its Spend block, not the whole read.
  defp spend_payload(%{id: id}) do
    Arbiter.Usage.SpendBreakdown.for_task(id)
  rescue
    _ -> nil
  end

  defp live_workers do
    Arbiter.Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp current_run(id, live) do
    case Current.show(id, live: live, limit: 1) do
      %{current: current} -> current
      nil -> nil
    end
  end

  def create(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :write),
         {:ok, force?} <- params |> Params.fetch_bool("force", false) |> Params.to_rest() do
      create_issue(conn, params, force?, ws_id)
    end
  end

  # `POST /api/issues/batch` — `{tickets: [...], promote?, force?, acceptance_waived?}`.
  # Every entry is a `POST /api/issues` body plus an optional `ref`; `parent_id` /
  # `depends_on` / `blocks` may name an existing id or another entry's `ref`. The
  # whole batch is one transaction (`Arbiter.Tasks.BatchCreate`): any failure
  # writes nothing and the error names the entry (`error.details.index`). 201 with
  # the `refs` map on success.
  def batch_create(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :write),
         {:ok, force?} <- params |> Params.fetch_bool("force", false) |> Params.to_rest(),
         {:ok, promote?} <- params |> Params.fetch_bool("promote", false) |> Params.to_rest(),
         {:ok, entries} <- BatchCreate.parse(Map.get(params, "tickets"), &batch_entry_attrs/1),
         {:ok, result} <-
           BatchCreate.run(entries,
             workspace_id: ws_id,
             force: force?,
             promote: promote?,
             promote_args: batch_promote_args(params),
             created_by: Params.actor_label(conn.assigns[:mcp_scope]),
             context: permission_context(conn)
           ) do
      conn |> put_status(:created) |> json(BatchCreate.present(result))
    end
  end

  # One entry's own fields, gated and coerced exactly like a single create's.
  defp batch_entry_attrs(entry) do
    entry = Map.drop(entry, ["id", "assignee", "workspace", "workspace_id"])

    with :ok <- IssueFields.check(entry, :create),
         {:ok, _skip?} <-
           entry |> Params.fetch_bool("skip_upstream_create", false) |> Params.to_rest() do
      {:ok, entry |> Params.strip_attribution() |> coerce_atoms(@atom_fields)}
    end
  end

  defp batch_promote_args(params) do
    case params["acceptance_waived"] do
      reason when is_binary(reason) -> %{acceptance_waived: reason}
      _ -> %{}
    end
  end

  defp create_issue(conn, params, force?, ws_id) do
    assignee_warnings = AssigneeCompat.warnings(params)

    with :ok <- IssueFields.check(params, :create),
         {:ok, deps} <- fetch_id_lists(params, ["depends_on", "deps"]),
         {:ok, blocks} <- fetch_id_lists(params, ["blocks"]),
         {:ok, fixes} <- fetch_id_lists(params, ["fixes"]) do
      attrs =
        params
        |> Params.strip_attribution()
        |> Map.drop([
          "id",
          "force",
          "assignee",
          "workspace",
          "deps",
          "depends_on",
          "blocks",
          "no_lint",
          "fixes"
        ])
        |> Map.put("workspace_id", ws_id)
        |> coerce_atoms(@atom_fields)

      with {:ok, _skip_upstream?} <-
             attrs |> Params.fetch_bool("skip_upstream_create", false) |> Params.to_rest() do
        opts = [
          lint: Params.boolean(params["no_lint"]) != {:ok, true},
          force: force?,
          deps: deps,
          blocks: blocks,
          fixes: fixes,
          created_by: Params.actor_label(conn.assigns[:mcp_scope]),
          context: permission_context(conn)
        ]

        respond_to_create(conn, Create.run(attrs, opts), assignee_warnings)
      end
    end
  end

  # `depends_on` (alias `deps`) — ids of tickets that block the new one; `blocks` —
  # ids of tickets the new one blocks. Optional lists of strings, written in the
  # same transaction as the ticket.
  defp fetch_id_lists(params, keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Map.get(params, key) do
        nil ->
          {:cont, {:ok, acc}}

        ids when is_list(ids) ->
          if Enum.all?(ids, &is_binary/1),
            do: {:cont, {:ok, Enum.uniq(acc ++ ids)}},
            else: {:halt, {:error, {:invalid_request, "#{key} must be a list of ticket ids"}}}

        _ ->
          {:halt, {:error, {:invalid_request, "#{key} must be a list of ticket ids"}}}
      end
    end)
  end

  defp respond_to_create(conn, {:ok, issue, warnings}, assignee_warnings) do
    conn
    |> put_status(:created)
    |> render(:show, issue: issue, warnings: assignee_warnings ++ warnings)
  end

  defp respond_to_create(conn, {:duplicate, dup}, _assignee_warnings),
    do: duplicate_response(conn, dup)

  defp respond_to_create(conn, {:partial, issue, failures}, _assignee_warnings),
    do: partial_failure_response(conn, issue, failures)

  defp respond_to_create(_conn, {:error, _} = err, _assignee_warnings), do: err

  defp duplicate_response(conn, {:local_dup, matches}) do
    ids = Enum.map_join(matches, ", ", & &1.id)

    conn
    |> put_status(409)
    |> json(%{
      "error" => %{
        "type" => "duplicate_task",
        "message" =>
          "an open task with this title already exists (#{ids}); use --force to proceed anyway",
        "details" => %{
          "matches" =>
            Enum.map(matches, fn i ->
              %{"id" => i.id, "title" => i.title, "state" => to_string(i.state)}
            end)
        }
      }
    })
  end

  defp duplicate_response(conn, {:tracker_dup, matches}) do
    urls = Enum.map_join(matches, ", ", &Map.get(&1, :url, ""))

    conn
    |> put_status(409)
    |> json(%{
      "error" => %{
        "type" => "duplicate_tracker_issue",
        "message" =>
          "an open tracker issue with this title already exists (#{urls}); use --force to proceed anyway",
        "details" => %{
          "matches" =>
            Enum.map(matches, fn m ->
              %{"ref" => m[:ref], "title" => m[:title], "url" => m[:url]}
            end)
        }
      }
    })
  end

  # The task was created locally but the upstream create (or write-back of
  # the returned ref) and/or an edge failed. An upstream failure is a 502 Bad
  # Gateway so the CLI exits non-zero; an edge-only failure is a 422 (the ticket
  # exists, the relationship the caller asked for does not). Either way the
  # body carries the task, so the caller sees what got persisted and can
  # re-link — and `--json` callers still get the id.
  defp partial_failure_response(conn, %Issue{} = issue, failures) do
    primary = Enum.find(failures, &(&1.kind == :upstream_create_failed)) || hd(failures)

    status =
      if primary.kind == :upstream_create_failed, do: :bad_gateway, else: :unprocessable_entity

    conn
    |> put_status(status)
    |> json(%{
      "issue" => ArbiterWeb.Api.IssueJSON.data(issue),
      "error" => %{
        "type" => to_string(primary.kind),
        "message" => Create.failure_message(failures),
        "details" => %{
          "task_id" => issue.id,
          "tracker_type" => primary |> Map.get(:tracker_type) |> tracker_type_str(),
          "tracker_ref" => Map.get(primary, :tracker_ref),
          "failures" => Enum.map(failures, &failure_json/1)
        }
      }
    })
  end

  defp failure_json(failure) do
    %{
      "kind" => to_string(failure.kind),
      "message" => failure.message,
      "edge" => failure |> Map.get(:edge) |> edge_json()
    }
  end

  defp edge_json(nil), do: nil

  defp edge_json(%{from: from, to: to, type: type}),
    do: %{"from_issue_id" => from, "to_issue_id" => to, "type" => to_string(type)}

  defp tracker_type_str(nil), do: nil
  defp tracker_type_str(t) when is_atom(t), do: to_string(t)
  defp tracker_type_str(t), do: t

  # bd-54m4vv (G12): who is declaring permissions, for the `Issue` changes. The
  # authority is derived from the bearer token, never asserted by the caller
  # (`Arbiter.Guardrails.Authority`): operator proof is `:operator`, another
  # coordinator token `:coordinator`, anything else `:restricted`.
  defp permission_context(conn) do
    scope = conn.assigns[:mcp_scope]

    %{
      guardrail_authority: Authority.from_scope(scope),
      permission_actor: Params.actor_label(scope)
    }
  end

  # `add_permissions` / `remove_permissions` (what `arb ticket update
  # --permission` sends) fold into one `permissions` list server-side.
  defp resolve_permission_edits(issue, params) do
    case Permissions.resolve_edits(issue, params) do
      {:ok, _} = ok -> ok
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  def update(conn, %{"id" => id} = params) do
    assignee_warnings = AssigneeCompat.warnings(params)

    with {:ok, updated} <- apply_update(conn, id, params) do
      render(conn, :show,
        issue: updated,
        warnings: assignee_warnings ++ update_lint(updated, params)
      )
    end
  end

  # #1146: acceptance lint on update, only when `acceptance` was written.
  defp update_lint(updated, params) do
    if Map.has_key?(params, "acceptance") and Params.boolean(params["no_lint"]) != {:ok, true},
      do: AcceptanceLint.lint(updated.acceptance),
      else: []
  end

  defp apply_update(conn, id, params) do
    with :ok <- IssueFields.check(params, :update),
         {:ok, issue} <- Ash.get(Issue, id),
         {:ok, params} <- resolve_permission_edits(issue, params) do
      attrs =
        params
        |> Params.strip_attribution()
        |> Map.drop(["id", "workspace_id", "assignee", "no_lint"])
        |> coerce_atoms(@atom_fields)

      Ash.update(issue, attrs, context: permission_context(conn))
    end
  end

  @doc """
  Clear a tripped ReviewPatrol circuit breaker (P-14) — the typed replacement
  for PATCHing `circuit_breaker_tripped` / `circuit_breaker_reason`. Idempotent.
  """
  def resume_review(conn, %{"id" => id}) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, resumed} <- Ash.update(issue, %{}, action: :resume_review) do
      render(conn, :show, issue: resumed)
    end
  end

  def close(conn, %{"id" => id} = params) do
    with {:ok, closed} <- apply_close(id, params) do
      render(conn, :show, issue: closed)
    end
  end

  defp apply_close(id, params) do
    reason = params["reason"]

    # bd-2wilou: propagate the close upstream by default (matches the `:close`
    # action's own default). Only an explicit false (`false`/`"false"`/`"0"`)
    # suppresses it; junk is a 400.
    with {:ok, close_upstream} <-
           params |> Params.fetch_bool("close_upstream", true) |> Params.to_rest(),
         {:ok, issue} <- Ash.get(Issue, id) do
      args =
        %{}
        |> then(fn a -> if reason, do: Map.put(a, :reason, reason), else: a end)
        |> Map.put(:close_upstream, close_upstream)

      Ash.update(issue, args, action: :close)
    end
  end

  def reopen(conn, %{"id" => id}) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, reopened} <- Ash.update(issue, %{}, action: :reopen) do
      render(conn, :show, issue: reopened)
    end
  end

  def promote(conn, %{"id" => id} = params) do
    promote_args =
      case params["acceptance_waived"] do
        reason when is_binary(reason) -> %{acceptance_waived: reason}
        _ -> %{}
      end

    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, promoted} <- Ash.update(issue, promote_args, action: :promote_to_ready) do
      render(conn, :show, issue: promoted)
    end
  end

  def demote(conn, %{"id" => id}) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, demoted} <- Ash.update(issue, %{}, action: :return_to_backlog) do
      render(conn, :show, issue: demoted)
    end
  end

  # ---- bulk forms (bd-3cyf8j) -------------------------------------------------
  #
  # `POST /api/issues/{promote,demote,rank}` with `{"ids": [...]}`. Each id runs the
  # same action as its single-id route, independently; the reply is the shared
  # `Arbiter.Tasks.BulkResult` shape: `{results: [{id, status: ok | refused |
  # not_found, reason?, ticket?}], counts: {total, ok, refused, not_found}}`. A
  # batch that is itself malformed (no ids, over `BulkResult.max_batch/0`) is a 400.
  # Bulk rank takes one shared move plus an ORDERED `ids`, and leaves them in that
  # order (see `BulkResult.run_rank/3`).

  @doc "Promote every id in `ids`; an optional shared `acceptance_waived` applies to each."
  def bulk_promote(conn, params) do
    promote_args =
      case params["acceptance_waived"] do
        reason when is_binary(reason) -> %{acceptance_waived: reason}
        _ -> %{}
      end

    bulk(conn, params, fn id ->
      with {:ok, issue} <- Ash.get(Issue, id),
           {:ok, promoted} <- Ash.update(issue, promote_args, action: :promote_to_ready) do
        {:ok, ArbiterWeb.Api.IssueJSON.data(promoted)}
      end
    end)
  end

  @doc "Demote every id in `ids` back to Backlog."
  def bulk_demote(conn, params) do
    bulk(conn, params, fn id ->
      with {:ok, issue} <- Ash.get(Issue, id),
           {:ok, demoted} <- Ash.update(issue, %{}, action: :return_to_backlog) do
        {:ok, ArbiterWeb.Api.IssueJSON.data(demoted)}
      end
    end)
  end

  @doc "Rank the ordered `ids` with one shared move (`top`, `bottom`, `before_id`, `after_id`, `pinned`)."
  def bulk_rank(conn, params) do
    with {:ok, ids} <- bulk_ids(params) do
      move = Map.delete(params, "ids")

      result =
        BulkResult.run_rank(ids, move, fn id, step ->
          with {:ok, rank_args} <- rank_args(step),
               {:ok, issue} <- Ash.get(Issue, id),
               {:ok, ranked} <- Arbiter.Tasks.Rank.move(issue, rank_args) do
            {:ok,
             Map.merge(
               ArbiterWeb.Api.IssueJSON.data(ranked),
               Arbiter.Tasks.Rank.band_fields(ranked)
             )}
          else
            {:error, {:invalid_request, message}} -> {:error, {:invalid, message}}
            other -> other
          end
        end)

      json(conn, result)
    end
  end

  @doc """
  `PATCH /api/issues` with `{"ids": [...], "patch": {...}}` — apply one patch to
  every id (bd-cvyx6j). Each id goes through the same path as `PATCH
  /api/issues/:id` (field validation, permission rules). `patch.notes` REPLACES the
  field, so it is refused unless the body also carries `confirm_replace_notes:
  true`; `append_notes` needs no confirmation.
  """
  def bulk_update(conn, params) do
    patch = params["patch"]

    if is_map(patch) and map_size(patch) > 0 do
      with :ok <- notes_confirmed(patch, params) do
        bulk(conn, params, &patch_one(conn, &1, patch))
      end
    else
      {:error, {:invalid_request, "`patch` must be a non-empty object of fields to set"}}
    end
  end

  defp patch_one(conn, id, patch) do
    with {:ok, updated} <- apply_update(conn, id, Map.put(patch, "id", id)) do
      {:ok, ArbiterWeb.Api.IssueJSON.data(updated)}
    end
  end

  defp notes_confirmed(patch, params) do
    case BulkResult.check_notes_replace(
           Map.put(patch, "confirm_replace_notes", params["confirm_replace_notes"])
         ) do
      :ok -> :ok
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  @doc "`POST /api/issues/close` with `{ids, reason?, close_upstream?}` (bd-cvyx6j)."
  def bulk_close(conn, params) do
    shared = Map.take(params, ["reason", "close_upstream"])

    bulk(conn, params, fn id ->
      with {:ok, closed} <- apply_close(id, shared) do
        {:ok, ArbiterWeb.Api.IssueJSON.data(closed)}
      end
    end)
  end

  @doc """
  `POST /api/issues/verify` with `{ids, outcome, evidence}` (bd-cvyx6j). Each id
  records the outcome exactly as `POST /api/issues/:id/verify` does, so a `failed`
  outcome reopens every id parked in `:verifying`.
  """
  def bulk_verify(conn, params) do
    shared = Map.take(params, ["outcome", "evidence"])

    bulk(conn, params, fn id ->
      with {:ok, updated} <- apply_verify(id, shared) do
        {:ok, ArbiterWeb.Api.IssueJSON.data(updated)}
      end
    end)
  end

  defp bulk(conn, params, fun) do
    with {:ok, ids} <- bulk_ids(params) do
      json(conn, BulkResult.run(ids, fun))
    end
  end

  defp bulk_ids(params) do
    case BulkResult.fetch_ids(params) do
      {:ok, ids} -> {:ok, ids}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  @doc """
  Push a close to the linked tracker issue for a ticket already `:closed`
  locally (P-15) — the remedy `arb sync` reports for `drift`. Backs onto the
  `:sync_upstream_close` action; no local state change.
  """
  def sync_upstream_close(conn, %{"id" => id}) do
    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, synced} <- Ash.update(issue, %{}, action: :sync_upstream_close) do
      render(conn, :show, issue: synced)
    end
  end

  @doc """
  Reorder a ticket inside its workspace's rank order (bd-djapyj). Body is one
  of `top: true`, `bottom: true`, `before_id: <id>`, `after_id: <id>` — the
  same four forms the CLI (`arb ticket rank`) and MCP (`ticket_rank`) accept,
  all backed by the `:set_rank` action. Never changes `priority`.
  """
  @rank_usage "give exactly one of: top, bottom, before_id, after_id (optionally with pinned), or pinned alone"

  def rank(conn, %{"id" => id} = params) do
    with {:ok, rank_args} <- rank_args(params),
         {:ok, issue} <- Ash.get(Issue, id),
         {:ok, ranked} <- Arbiter.Tasks.Rank.move(issue, rank_args) do
      render(conn, :rank, issue: ranked, band: Arbiter.Tasks.Rank.band_fields(ranked))
    end
  end

  defp rank_args(params) do
    with {:ok, top?} <- params |> Params.fetch_bool("top", false) |> Params.to_rest(),
         {:ok, bottom?} <- params |> Params.fetch_bool("bottom", false) |> Params.to_rest(),
         {:ok, pinned} <- params |> fetch_pinned() |> Params.to_rest() do
      forms =
        [
          top? && %{position: :top},
          bottom? && %{position: :bottom},
          is_binary(params["before_id"]) && %{before_id: params["before_id"]},
          is_binary(params["after_id"]) && %{after_id: params["after_id"]}
        ]
        |> Enum.reject(&(&1 == false))

      case {forms, pinned} do
        {[form], nil} -> {:ok, form}
        {[form], pinned} -> {:ok, Map.put(form, :pinned, pinned)}
        {[], pinned} when is_boolean(pinned) -> {:ok, %{pinned: pinned}}
        _ -> {:error, {:invalid_request, @rank_usage}}
      end
    end
  end

  defp fetch_pinned(params) do
    if Map.has_key?(params, "pinned"),
      do: Params.fetch_bool(params, "pinned", false),
      else: {:ok, nil}
  end

  @doc """
  Set or clear an epic's priority floor (ES2, bd-3e7inj) through `:set_floor`.
  The `floor_priority` key is required (`null` clears), so an empty body is a
  400 rather than a silent clear. A non-epic is a 422. The caller's scope is
  passed as the actor, so the action refuses a worker/refine token even if the
  route policy is ever loosened.
  """
  def floor(conn, %{"id" => id} = params) do
    with {:ok, raw} <- fetch_floor_param(params),
         {:ok, floor} <- parse_floor(raw),
         {:ok, issue} <- Ash.get(Issue, id),
         {:ok, floored} <-
           Ash.update(issue, %{floor_priority: floor},
             action: :set_floor,
             actor: conn.assigns[:mcp_scope]
           ) do
      render(conn, :show, issue: floored)
    end
  end

  defp fetch_floor_param(%{"floor_priority" => raw}), do: {:ok, raw}

  defp fetch_floor_param(_params),
    do: {:error, {:invalid_request, "floor_priority is required (P1, P2, P3 or null to clear)"}}

  defp parse_floor(raw) do
    case Arbiter.Tasks.Floor.parse(raw) do
      {:ok, floor} -> {:ok, floor}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  @doc """
  Record the restart-and-observe result for a ticket in the `:verifying`
  state (bd-9so315).

  Body: `outcome` (`"observed"` | `"failed"`) and `evidence` (free text, what
  was actually seen on the running server). `observed` closes the task,
  `failed` reopens it; either way the evidence is persisted.

  The verification refusals are domain answers ("this task isn't parked" is a
  409, "evidence is required" a 422) carrying their own sentence, not a
  changeset's generic `validation failed`; they reach the fallback controller as
  `{:conflict, msg}` / `{:invalid, msg}`.
  """
  def verify(conn, %{"id" => id} = params) do
    with {:ok, updated} <- apply_verify(id, params) do
      render(conn, :show, issue: updated)
    end
  end

  defp apply_verify(id, params) do
    with {:ok, issue} <- Ash.get(Issue, id) do
      case Verification.record_outcome(issue, params["outcome"], params["evidence"]) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> verify_error(reason)
      end
    end
  end

  # The task is not in the state that accepts a verdict: the request is fine,
  # the ticket's state refuses it — a 409, like every other state refusal.
  defp verify_error(:not_awaiting_verification) do
    {:error,
     {:conflict,
      "task is not awaiting verification — only a ticket in state " <>
        ":verifying can record a verify result"}}
  end

  defp verify_error(:evidence_required) do
    {:error, {:invalid, "evidence is required: say what you observed on the running server"}}
  end

  defp verify_error({:invalid, message}) when is_binary(message),
    do: {:error, {:invalid, message}}

  defp verify_error({:invalid, err}), do: {:error, {:invalid, Exception.message(err)}}

  @doc """
  Record the coordinator's answer to a gate escalation (bd-4qjl0q) — what
  `arb review resolve` wraps. Body: `decision` (`accept_as_is` / `amend` /
  `send_back` / `reject`) and `reasoning` (both required); optional `gate`,
  `actor`, `round`, `fix_round_attempt`, `head_sha`. Returns the recorded
  resolution (201). Only `accept_as_is` / `amend` permit a merge without a fresh
  reviewer APPROVE; `send_back` means another review round follows.
  See `Arbiter.ReviewGate.Resolutions.record/1`.
  """
  def resolve(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.take(~w(decision reasoning gate round fix_round_attempt head_sha))
      |> Map.put("actor", Params.actor_label(conn.assigns[:mcp_scope]) || "coordinator")
      |> Map.put("task_id", id)

    case Arbiter.ReviewGate.Resolutions.record(attrs) do
      {:ok, resolution} ->
        conn
        |> put_status(:created)
        |> json(Arbiter.ReviewGate.Resolutions.serialize(resolution))

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Hand a ticket's attention to the operator (bd-8nlez1) — the coordinator's
  hand-off. Body: `note` (required), what the operator has to do.
  """
  def handoff(conn, %{"id" => id} = params), do: move_attention(conn, id, :operator, params)

  @doc """
  Grant or deny a requested permission (G15b, bd-lozakf) — what `arb ticket
  permit` wraps. Body: `permission` (required), `deny` (default false) and
  `reason` (required with `deny`). The authority is the token's, never the
  body's: an operator-only binding needs an operator-proof token.
  """
  def permission(conn, %{"id" => id} = params) do
    scope = conn.assigns[:mcp_scope]

    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, deny?} <- params |> Params.fetch_bool("deny", false) |> Params.to_rest(),
         {:ok, decided} <-
           PermissionDecision.answer(issue, params["permission"], deny?,
             authority: Authority.from_scope(scope),
             actor: Params.actor_label(scope),
             reason: params["reason"]
           ) do
      json(conn, decided)
    end
  end

  @doc """
  Hand a ticket's attention back to the coordinator (bd-8nlez1) — the
  operator's hand-back, which `arb ticket handback` wraps. Body: `note`
  (optional).
  """
  def handback(conn, %{"id" => id} = params), do: move_attention(conn, id, :coordinator, params)

  defp move_attention(conn, id, to, params) do
    note = if is_binary(params["note"]), do: params["note"]

    with {:ok, _issue} <- Ash.get(Issue, id) do
      case Arbiter.Tasks.Attention.hand_off(id, to, note) do
        {:ok, _attention} ->
          # P-13 (D-T-13): the ticket with its projection (`attention` included),
          # the shape the MCP `ticket_handoff` / `ticket_handback` return too.
          issue = Ash.get!(Issue, id)
          render(conn, :handoff, issue: issue, view: Projection.view(issue))

        {:error, reason} ->
          attention_error(reason)
      end
    end
  end

  # `Attention.hand_off/4` refusals: no such ticket → 404; the ticket's state
  # refuses a hand-off (nothing to hand off, already owned) → 409; a hand-off to
  # the operator with no note is a bad argument → 422.
  defp attention_error(:not_found), do: {:error, :not_found}

  defp attention_error(reason) when reason == :no_attention or elem(reason, 0) == :already_owned,
    do: {:error, {:conflict, Arbiter.Tasks.Attention.describe_error(reason)}}

  defp attention_error(reason),
    do: {:error, {:invalid, Arbiter.Tasks.Attention.describe_error(reason)}}

  # ---- helpers ----

  defp build_filters(params) do
    Enum.reduce_while(@filter_fields, {:ok, []}, fn field, {:ok, acc} ->
      case Map.fetch(params, Atom.to_string(field)) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, raw} ->
          case coerce_filter_value(field, raw) do
            {:ok, value} -> {:cont, {:ok, [{field, value} | acc]}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp coerce_filter_value(field, raw)
       when field in [:priority, :difficulty] and is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:invalid_request, "#{field} must be an integer"}}
    end
  end

  defp coerce_filter_value(field, raw)
       when field in [:priority, :difficulty] and is_integer(raw),
       do: {:ok, raw}

  # Matched against the lifecycle's own list rather than `to_existing_atom`:
  # plenty of atoms exist that are not states.
  defp coerce_filter_value(:state, raw) when is_binary(raw) do
    case Enum.find(Lifecycle.states(), &(Atom.to_string(&1) == raw)) do
      nil -> {:error, {:invalid_request, "invalid state: #{inspect(raw)}"}}
      state -> {:ok, state}
    end
  end

  defp coerce_filter_value(:issue_type, raw) when is_binary(raw) do
    {:ok, String.to_existing_atom(raw)}
  rescue
    ArgumentError ->
      {:error, {:invalid_request, "invalid issue_type: #{inspect(raw)}"}}
  end

  defp coerce_filter_value(_, raw) when is_binary(raw), do: {:ok, raw}
  defp coerce_filter_value(_, raw), do: {:ok, raw}

  defp coerce_atoms(params, fields) do
    Enum.reduce(fields, params, fn field, acc ->
      key = Atom.to_string(field)

      case Map.get(acc, key) do
        nil ->
          acc

        value when is_binary(value) ->
          try do
            Map.put(acc, key, String.to_existing_atom(value))
          rescue
            ArgumentError -> acc
          end

        _ ->
          acc
      end
    end)
  end
end
