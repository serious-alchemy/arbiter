defmodule ArbiterWeb.Api.IssueController do
  @moduledoc """
  REST endpoints for `Arbiter.Tasks.Issue`.

  Routes:

    * `POST   /api/issues`             — :create
    * `GET    /api/issues`             — :index (filters: state, priority,
                                        difficulty, issue_type, workspace_id)
    * `GET    /api/issues/ready`       — :ready (Issue.ready/1)
    * `GET    /api/issues/:id`         — :show
    * `PATCH  /api/issues/:id`         — :update
    * `POST   /api/issues/:id/close`   — :close (body: optional `reason`)
    * `POST   /api/issues/:id/reopen`  — :reopen
    * `POST   /api/issues/:id/promote` — :promote
    * `POST   /api/issues/:id/demote`  — :demote (return to backlog)
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

  bd-1ozks5: the local `Issue.assignee` field was removed. `POST /api/issues`
  and `PATCH /api/issues/:id` still accept an `assignee` param — for one
  release it's silently dropped and reported back as a `warnings` entry,
  rather than rejected outright and breaking an existing coordinator script.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Board.Snapshot
  alias Arbiter.Params
  alias Arbiter.Tasks.AssigneeCompat
  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.EffectivePriority
  alias Arbiter.Tasks.History
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Issue.Changes.CreateUpstream
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Tasks.Verification
  alias Arbiter.Usage.Estimate
  alias Arbiter.Workers.Current
  alias ArbiterWeb.InstallationSettings
  require Ash.Query

  action_fallback(ArbiterWeb.Api.FallbackController)

  @atom_fields ~w(issue_type tracker_type)a
  @filter_fields ~w(state priority difficulty issue_type workspace_id)a

  def index(conn, params) do
    with {:ok, filters} <- build_filters(params) do
      query = Ash.Query.do_filter(Ash.Query.new(Issue), filters)

      case Ash.read(query) do
        {:ok, issues} ->
          render(conn, :index, issues: issues)

        {:error, _} = err ->
          err
      end
    end
  end

  def ready(conn, params) do
    opts =
      case params["workspace_id"] do
        ws when is_binary(ws) and ws != "" -> [workspace_id: ws]
        _ -> []
      end

    # ES4: `Issue.ready/1` is the set; the §4 key (`EffectivePriority.order/1`,
    # an epic's floor included) is the order `arb ready` prints it in.
    issues = opts |> Issue.ready() |> EffectivePriority.order()
    render(conn, :index, issues: issues)
  end

  # bd-6fkgvo: every open ticket in a workspace with its lifecycle projection
  # (state, column, step, blocked_by, attention), epics excluded as on the
  # board, in dispatch order — what `arb prime` groups into its sections.
  def lifecycle(conn, %{"workspace_id" => ws_id}) when is_binary(ws_id) and ws_id != "" do
    render(conn, :lifecycle, tickets: Projection.open(ws_id), holds: ready_holds(ws_id))
  end

  def lifecycle(_conn, _params), do: {:error, {:invalid, "workspace_id is required"}}

  # bd-dtdeff: why the scheduler is not dispatching each Ready card, from the
  # board's own plan (the reason its card shows), so a card Autopilot is
  # skipping reads the same on `arb prime`. Only cards the board holds appear;
  # a failed board read yields none rather than failing the listing.
  defp ready_holds(ws_id) do
    paused? =
      not InstallationSettings.scheduler_running?() or InstallationSettings.scheduler_paused?()

    [workspace_id: ws_id, paused: paused?, exclude_engagements?: true]
    |> Snapshot.load()
    |> Map.get(:ready, [])
    |> Enum.filter(&(&1.state == :blocked))
    |> Map.new(&{&1.id, &1.reason})
  rescue
    _ -> %{}
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
          epic_rollup: Estimate.epic_cost_rollup(issue),
          dependencies: dependencies,
          lifecycle: Projection.view(issue, workers: live),
          priority_fields: EffectivePriority.fields(issue),
          current_run: current_run(id, live),
          # bd-6i7yzq: the recent audit history, each write with its actor.
          history: History.recent(id)
        )

      {:error, _} = err ->
        err
    end
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
    with {:ok, force?} <- params |> Params.fetch_bool("force", false) |> Params.to_rest() do
      create_issue(conn, params, force?)
    end
  end

  defp create_issue(conn, params, force?) do
    assignee_warnings = AssigneeCompat.warnings(params)

    attrs =
      params
      |> Params.strip_attribution()
      |> Map.drop(["id", "force", "assignee"])
      |> coerce_atoms(@atom_fields)

    case dedup_check(attrs, force?) do
      :ok ->
        case Ash.create(Issue, attrs) do
          {:ok, issue} ->
            case CreateUpstream.last_error() do
              nil ->
                conn
                |> put_status(:created)
                |> render(:show, issue: issue, warnings: assignee_warnings ++ ac_warnings(issue))

              err ->
                upstream_failure_response(conn, issue.id, err)
            end

          {:error, _} = err ->
            err
        end

      {:local_dup, matches} ->
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

      {:tracker_dup, matches} ->
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
  end

  # Delegates to `Arbiter.Tasks.Dedup` so the dashboard's create form applies
  # the same rule (bd-2cv4ws).
  defp dedup_check(attrs, force?) do
    Dedup.check(attrs["title"], attrs["workspace_id"],
      force: force?,
      skip_upstream_create: attrs["skip_upstream_create"] == true,
      tracker_ref: attrs["tracker_ref"]
    )
  end

  # The task was created locally but the upstream create (or write-back of
  # the returned ref) failed. We return 502 Bad Gateway so the CLI exits
  # non-zero, but we include the task body in the response so the user can
  # see what got persisted and re-link manually if needed.
  defp upstream_failure_response(conn, task_id, err) do
    issue_body =
      case Ash.get(Issue, task_id) do
        {:ok, issue} -> ArbiterWeb.Api.IssueJSON.data(issue)
        _ -> %{id: task_id}
      end

    conn
    |> put_status(:bad_gateway)
    |> json(%{
      "issue" => issue_body,
      "error" => %{
        "type" => to_string(err.kind),
        "message" => err.message,
        "details" => %{
          "task_id" => task_id,
          "tracker_type" => err |> Map.get(:tracker_type) |> tracker_type_str(),
          "tracker_ref" => Map.get(err, :tracker_ref)
        }
      }
    })
  end

  defp tracker_type_str(nil), do: nil
  defp tracker_type_str(t) when is_atom(t), do: to_string(t)
  defp tracker_type_str(t), do: t

  # bd-7mbrlg: non-blocking heads-up at filing time — mirrors
  # `Arbiter.MCP.Tools.Task.with_ac_warning/2`.
  defp ac_warnings(%Issue{} = issue) do
    if Issue.gated_type?(issue.issue_type) and blank?(issue.acceptance) do
      [
        "No acceptance criteria set. #{issue.issue_type} tasks need `acceptance` (or an " <>
          "explicit `acceptance_waived` reason) before they can be promoted to Ready."
      ]
    else
      []
    end
  end

  defp blank?(nil), do: true
  defp blank?(str), do: String.trim(str) == ""

  def update(conn, %{"id" => id} = params) do
    assignee_warnings = AssigneeCompat.warnings(params)

    attrs =
      params
      |> Params.strip_attribution()
      |> Map.drop(["id", "workspace_id", "assignee"])
      |> coerce_atoms(@atom_fields)

    with {:ok, issue} <- Ash.get(Issue, id),
         {:ok, updated} <- Ash.update(issue, attrs) do
      render(conn, :show, issue: updated, warnings: assignee_warnings)
    end
  end

  def close(conn, %{"id" => id} = params) do
    reason = params["reason"]

    # bd-2wilou: propagate the close upstream by default (matches the `:close`
    # action's own default). Only an explicit false (`false`/`"false"`/`"0"`)
    # suppresses it; junk is a 400.
    with {:ok, close_upstream} <-
           params |> Params.fetch_bool("close_upstream", true) |> Params.to_rest(),
         {:ok, issue} <- Ash.get(Issue, id),
         args =
           %{}
           |> then(fn a -> if reason, do: Map.put(a, :reason, reason), else: a end)
           |> Map.put(:close_upstream, close_upstream),
         {:ok, closed} <- Ash.update(issue, args, action: :close) do
      render(conn, :show, issue: closed)
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

  @doc """
  Reorder a ticket inside its workspace's rank order (bd-djapyj). Body is one
  of `top: true`, `bottom: true`, `before_id: <id>`, `after_id: <id>` — the
  same four forms the CLI (`arb ticket rank`) and MCP (`ticket_rank`) accept,
  all backed by the `:set_rank` action. Never changes `priority`.
  """
  def rank(conn, %{"id" => id} = params) do
    with {:ok, rank_args} <- rank_args(params),
         {:ok, issue} <- Ash.get(Issue, id),
         {:ok, ranked} <- Arbiter.Tasks.Rank.move(issue, rank_args) do
      render(conn, :show, issue: ranked)
    end
  end

  defp rank_args(params) do
    forms =
      [
        params["top"] == true && %{position: :top},
        params["bottom"] == true && %{position: :bottom},
        is_binary(params["before_id"]) && %{before_id: params["before_id"]},
        is_binary(params["after_id"]) && %{after_id: params["after_id"]}
      ]
      |> Enum.reject(&(&1 == false))

    case forms do
      [form] -> {:ok, form}
      _ -> {:error, {:invalid_request, "give exactly one of: top, bottom, before_id, after_id"}}
    end
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
    outcome = params["outcome"]
    evidence = params["evidence"]

    with {:ok, issue} <- Ash.get(Issue, id) do
      case Verification.record_outcome(issue, outcome, evidence) do
        {:ok, updated} -> render(conn, :show, issue: updated)
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
  `actor`, `round`, `fix_round_attempt`. Returns the recorded resolution (201).
  See `Arbiter.ReviewGate.Resolutions.record/1`.
  """
  def resolve(conn, %{"id" => id} = params) do
    attrs =
      params
      |> Map.take(~w(decision reasoning gate round fix_round_attempt))
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
  Hand a ticket's attention back to the coordinator (bd-8nlez1) — the
  operator's hand-back, which `arb ticket handback` wraps. Body: `note`
  (optional).
  """
  def handback(conn, %{"id" => id} = params), do: move_attention(conn, id, :coordinator, params)

  defp move_attention(conn, id, to, params) do
    note = if is_binary(params["note"]), do: params["note"]

    with {:ok, _issue} <- Ash.get(Issue, id) do
      case Arbiter.Tasks.Attention.hand_off(id, to, note) do
        {:ok, _attention} -> render(conn, :show, issue: Ash.get!(Issue, id))
        {:error, reason} -> attention_error(reason)
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
