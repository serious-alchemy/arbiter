defmodule ArbiterWeb.Api.LoopController do
  @moduledoc """
  REST surface for the loop-analysis pass (Stage 1, bd-dyfaq3) and its
  reviewable-proposal queue (Stage 2, bd-9j2g3x).

    * `POST /api/loop/analyze` — run the operator-invoked loop-analysis pass over
      a window and return its markdown report. (`GET /api/loop/analyze` is a
      **deprecated alias** with the same behaviour, marked by `Deprecation`,
      `Link` and `Warning` response headers.) Optional params: `since`
      (`7d` / `24h` / `30m` shortcuts or ISO8601; default: last 7 days), `until`
      (ISO8601; default now), `limit` (cap on runs scanned, newest first),
      `workspace` (id or name; `workspace_id` is its alias), `label`.
    * `POST /api/loop/propose` — the same pass, plus persistence of the
      proposals it implies. Same params.
    * `discover=true` on either route (bd-4f6opo) — additionally run the
      opt-in discovery model pass (`Arbiter.Loop.Discovery`): one bounded call
      over the finding residue, reported as candidate detectors under
      `summary.discovery` and a markdown section. It queues nothing.
    * `POST /api/loop/propose/repo_doc_patch` — hand-author a `:repo_doc_patch`
      proposal directly: `repo` + `lesson` (required), optional `category` /
      `workspace`. The Stage 1 pass cannot attribute a finding category to
      one repo yet, so this is the entry point onto that write path today.
    * `GET  /api/loop/pending` — list queued proposals. Optional `state` (one
      name or a comma-separated list; default the two live states), `kind`,
      `workspace`, `limit`.
    * `GET  /api/loop/pending/:id` — one proposal, including its unified `diff`.
    * `POST /api/loop/pending/:id/apply` — apply it through the same public
      domain API a human would use.
    * `POST /api/loop/pending/:id/reject` — soft-reject it (optional `reason`).

  `/api/loop/analyze` is **report-only**: it writes nothing but its own
  `usage_events` cost row (`Arbiter.Loop.Analysis`). Persisting proposals is a
  separate verb on a separate route, so the read-only guarantee is structural
  rather than a flag on a GET. Backs the `arb loop` CLI.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Guardrails.Authority
  alias Arbiter.Loop
  alias Arbiter.Loop.Analysis
  alias Arbiter.Loop.Analysis.{Request, Summary}
  alias Arbiter.Params
  alias ArbiterWeb.Api.WorkspaceParam

  # Documented `limit` cap for the loop list/analysis routes.
  @max_limit 500

  action_fallback(ArbiterWeb.Api.FallbackController)

  # Attribution label for decisions arriving over the REST/CLI surface.
  @actor "cli"

  # bd-6i7yzq: the token's actor (`Arbiter.Actor`, installed by `ApiAuth`) when
  # there is one, else the surface's historical `"cli"` label.
  defp actor_label, do: Arbiter.Actor.resolve_label(nil) || @actor

  # `POST` is the route: the pass writes its own `usage_events` cost row and
  # `discover=true` makes a model call, neither of which a GET may do (D-C-30).
  # `GET` still answers identically, but is a deprecated alias — every response
  # carries `Deprecation` / `Link` / `Warning` so a caller sees it.
  def analyze(%Plug.Conn{method: "GET"} = conn, params) do
    conn
    |> put_resp_header("deprecation", "true")
    |> put_resp_header("link", ~s(</api/loop/analyze>; rel="successor-version"; method="POST"))
    |> put_resp_header(
      "warning",
      ~s(299 - "GET /api/loop/analyze is deprecated: it records a usage_events row and may ) <>
        ~s(run a model call; use POST /api/loop/analyze")
    )
    |> run_analysis(params, propose?: false)
  end

  def analyze(conn, params), do: run_analysis(conn, params, propose?: false)

  def propose(conn, params), do: run_analysis(conn, params, propose?: true)

  # bd-1cusio: the Stage 1 pass cannot yet attribute a finding category to one
  # repo (Arbiter.Loop.Proposals leaves `repo: nil` on every `:claude_md`
  # destination), so this is the production entry point onto the
  # `:repo_doc_patch` write path today — an operator names the repo and the
  # lesson text directly. See `Arbiter.Loop.propose_repo_doc_patch/1`.
  def propose_repo_doc_patch(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :write) do
      attrs = %{
        repo: params["repo"],
        lesson: params["lesson"],
        category: blank_to_nil(params["category"]),
        workspace_id: ws_id,
        actor: actor_label()
      }

      case Loop.propose_repo_doc_patch(attrs) do
        {:ok, row} -> json(conn, %{pending: render_pending(row, :full)})
        {:error, reason} -> {:error, apply_error(reason)}
      end
    end
  end

  # Operator-started routing canary: see `Arbiter.Loop.propose_routing/1`.
  def propose_routing(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :write) do
      attrs = %{
        workspace: ws_id,
        difficulty: params["difficulty"],
        model_tier: blank_to_nil(params["model_tier"]),
        thinking: blank_to_nil(params["thinking"]),
        actor: actor_label()
      }

      case Loop.propose_routing(attrs) do
        {:ok, row} -> json(conn, %{pending: render_pending(row, :full)})
        {:error, reason} -> {:error, apply_error(reason)}
      end
    end
  end

  # `arb loop canary status`: both arms' metrics + verdict progress.
  def canary_status(conn, params) do
    # One workspace's canary: the named / bound one, else the sole workspace —
    # a 422 listing them when several exist, never the one called `default`.
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :write),
         {:ok, ws} <- Loop.fetch_workspace(ws_id) |> map_ws_error() do
      case Arbiter.Loop.Canary.status(ws) do
        {:ok, status} -> json(conn, %{running: true, status: status})
        {:none, message} -> json(conn, %{running: false, message: message})
      end
    end
  end

  defp map_ws_error({:error, reason}), do: {:error, apply_error(reason)}
  defp map_ws_error(ok), do: ok

  defp run_analysis(conn, params, propose?: propose?) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, opts} <- analysis_opts(params) do
      opts =
        opts
        |> Keyword.put(:propose?, propose?)
        |> put(:workspace_id, ws_id)

      case Analysis.analyze(opts) do
        {:ok, result} ->
          json(conn, Summary.envelope(result, &render_pending/1))

        {:error, reason} ->
          {:error, {:server_error, "loop analysis failed", %{reason: inspect(reason)}}}
      end
    end
  end

  defp analysis_opts(params) do
    case Request.build(params) do
      {:ok, opts} -> {:ok, opts}
      {:error, message} -> {:error, {:invalid_request, message}}
    end
  end

  # ---- the proposal queue -------------------------------------------------

  def pending_index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, states} <- parse_states(params["state"]),
         {:ok, kind} <- parse_kind(params["kind"]),
         {:ok, limit} <- parse_limit(params["limit"]) do
      rows =
        []
        |> put(:state, states || Loop.live_states())
        |> put(:kind, kind)
        |> put(:workspace_id, ws_id)
        |> put(:limit, limit)
        |> Loop.list_pending()

      json(conn, %{
        pending: Enum.map(rows, &render_pending/1),
        workspace_id: ws_id,
        evidence_bar: Loop.evidence_bar(ws_id)
      })
    end
  end

  def pending_show(conn, %{"id" => id}) do
    with {:ok, row} <- visible_pending(conn, id) do
      json(conn, %{pending: render_pending(row, :full)})
    end
  end

  def pending_apply(conn, %{"id" => id}) do
    with {:ok, _row} <- visible_pending(conn, id) do
      case Loop.apply_pending(id,
             actor: actor_label(),
             authority: Authority.from_scope(conn.assigns[:mcp_scope])
           ) do
        {:ok, row} -> json(conn, %{pending: render_pending(row, :full), applied: true})
        {:error, reason} -> {:error, apply_error(reason)}
      end
    end
  end

  def pending_reject(conn, %{"id" => id} = params) do
    opts = [actor: actor_label()] |> put(:reason, blank_to_nil(params["reason"]))

    with {:ok, _row} <- visible_pending(conn, id) do
      case Loop.reject_pending(id, opts) do
        {:ok, row} -> json(conn, %{pending: render_pending(row, :full), rejected: true})
        {:error, reason} -> {:error, apply_error(reason)}
      end
    end
  end

  # A proposal in another workspace is not found to a token bound to one —
  # the same rule as MCP `loop_pending_*`, so existence does not leak.
  defp visible_pending(conn, id) do
    with {:ok, row} <- Loop.get_pending(id) do
      bound = conn.assigns[:mcp_scope] && conn.assigns[:mcp_scope].workspace_id

      if is_nil(bound) or row.workspace_id == bound,
        do: {:ok, row},
        else: {:error, :not_found}
    end
  end

  defp apply_error(:not_found), do: :not_found

  # The proposal's own state refuses (already decided, nothing to apply) → 409;
  # the domain refused the write's arguments → 422. `code` stays in `details`.
  defp apply_error({code, message})
       when code in [:not_applicable, :unmapped] and is_binary(message),
       do: {:conflict, message, %{code: to_string(code)}}

  defp apply_error({code, message}) when is_atom(code) and is_binary(message),
    do: {:invalid, message, %{code: to_string(code)}}

  defp apply_error(other),
    do: {:server_error, "loop proposal failed", %{reason: inspect(other)}}

  defp render_pending(row, detail \\ :summary)

  defp render_pending(row, :summary) do
    %{
      id: row.id,
      kind: row.kind,
      state: row.state,
      scope: row.scope,
      workspace_id: row.workspace_id,
      gist: row.gist,
      evidence_count: row.evidence_count,
      distinct_tasks: row.distinct_tasks,
      context_cost_tokens: row.context_cost_tokens,
      target: row.target,
      category: row.category,
      applicable: Loop.applicable?(row),
      needs_authoring: !!Loop.authoring_gap(row),
      created_at: row.created_at,
      updated_at: row.updated_at
    }
  end

  defp render_pending(row, :full) do
    row
    |> render_pending(:summary)
    |> Map.merge(%{
      diff: row.diff,
      payload: row.payload,
      target_metric: row.target_metric,
      baseline: row.baseline,
      incident_refs: row.incident_refs,
      task_refs: row.task_refs,
      fingerprint: row.fingerprint,
      origin: row.origin,
      applied_at: row.applied_at,
      escalated_at: row.escalated_at,
      rejection_reason: row.rejection_reason,
      inapplicable_reason: Loop.inapplicable_reason(row),
      authoring_gap: Loop.authoring_gap(row)
    })
  end

  # ---- param parsing ------------------------------------------------------

  # `state=` accepts one name or a comma-separated list; absent means the two
  # live states (an operator wants the queue, not the archive). Unknown names are
  # rejected rather than silently dropped, so a typo can't look like an empty
  # queue.
  @states Enum.map(Arbiter.Loop.PendingWrite.states(), &Atom.to_string/1)
  @kinds Enum.map(Arbiter.Loop.PendingWrite.kinds(), &Atom.to_string/1)

  defp parse_states(nil), do: {:ok, nil}
  defp parse_states(""), do: {:ok, nil}

  defp parse_states(raw) when is_binary(raw) do
    names =
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    case Enum.reject(names, &(&1 in @states)) do
      [] when names == [] ->
        {:ok, nil}

      [] ->
        {:ok, Enum.map(names, &String.to_existing_atom/1)}

      bad ->
        {:error,
         {:invalid_request,
          "unknown state(s) #{inspect(bad)}; expected one of #{Enum.join(@states, ", ")}"}}
    end
  end

  defp parse_states(other) do
    {:error, {:invalid_request, "state must be a string, got #{inspect(other)}"}}
  end

  defp parse_kind(nil), do: {:ok, nil}
  defp parse_kind(""), do: {:ok, nil}

  defp parse_kind(raw) when is_binary(raw) do
    if raw in @kinds do
      {:ok, String.to_existing_atom(raw)}
    else
      {:error,
       {:invalid_request,
        "unknown kind #{inspect(raw)}; expected one of #{Enum.join(@kinds, ", ")}"}}
    end
  end

  defp parse_kind(other) do
    {:error, {:invalid_request, "kind must be a string, got #{inspect(other)}"}}
  end

  # Absent means "no cap requested"; a supplied value is clamped to `@max_limit`.
  defp parse_limit(raw) when raw in [nil, ""], do: {:ok, nil}
  defp parse_limit(raw), do: raw |> Params.limit(@max_limit, @max_limit) |> Params.to_rest()

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s
end
