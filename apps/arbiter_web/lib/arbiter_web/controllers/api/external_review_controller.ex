defmodule ArbiterWeb.Api.ExternalReviewController do
  @moduledoc """
  REST endpoint for the ExternalReview audit ledger (bd-31fh9e, bd-bs5b12).

  Route:

    * `GET /api/external_reviews` — list recent records, newest first, wrapped under the "data" key.
      Returns: `{"data": [...]}` (consistent with other /api collection endpoints).
      Note: the MCP `external_review_list` tool uses "external_reviews" instead (deliberate
      asymmetry — each transport follows its own convention per bd-bs5b12 Option 3).
      The records themselves are `Arbiter.Reviews.Serializer.record/2`, the same as MCP's,
      so `mode`, `greenlight_status` and the `proposed_*` counts are here too (P-12).
      Optional query params:
        * `workspace` — restrict to one workspace (id or name; `workspace_id` is
          its alias). Omitted = all workspaces; the body echoes `workspace_id`.
        * `status`       — filter by `running` | `completed` | `failed`.
        * `since`        — ISO8601 lower bound on `started_at`.
        * `limit`        — max rows (default 20, max 200 — `Arbiter.Reviews.Listing`).

    * `GET /api/external_reviews/:id` — one record with its full `proposed_comments`
      and its durable-corpus state: a report-only review's findings, readable before
      they are greenlit. Wrapped under "data".

    * `POST /api/external_reviews/:id/greenlight` — post the approved subset of a
      report-only review's `proposed_comments` to the PR, and nothing else (bd-36qzgx).
      `:dispatch` tier, like the review that produced the record, and refused at the
      dispatch-recursion limit. Optional body: `select` (`"all"` — the default —, a list
      of zero-based indices, or `[]` to approve nothing), `post_verdict`, `repo`.
      Returns `{"data": {mr_ref, posted, selected, proposed, skipped, verdict_posted,
      verdict, link}}`.

    * `GET /api/external_reviews/:id/transcript` — the durable corpus of one review
      (bd-7efini): the composed prompt, the raw stream-json transcript its reviewer
      emitted, and every tool call paired with the result it returned. The REST
      counterpart of `GET /api/workers/:task_id/log` for a review, which — not being
      task-linked — has no run row to look up. Wrapped under "data".
      Optional query params:
        * `tail`           — return only the last N transcript lines (`truncated`).
        * `include_prompt` — `false` to omit the (large) composed prompt.
      `exists: false` (200, empty `lines`) distinguishes "never captured" from
      "captured but empty"; only an unknown record id 404s.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Params
  alias Arbiter.Reviews.ExternalReview
  alias Arbiter.Reviews.Listing
  alias Arbiter.Reviews.Params, as: ReviewParams
  alias Arbiter.Reviews.Serializer
  alias Arbiter.Reviews.Transcript
  alias Arbiter.Worker.Dispatch.Params, as: DispatchParams
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, since} <- params["since"] |> Listing.parse_since() |> Params.to_rest(),
         {:ok, status} <- params["status"] |> Listing.parse_status() |> Params.to_rest(),
         {:ok, limit} <- params["limit"] |> Listing.parse_limit() |> Params.to_rest() do
      records =
        Listing.list(workspace_id: ws_id, status: status, since: since, limit: limit)

      json(conn, %{data: Enum.map(records, &Serializer.record/1), workspace_id: ws_id})
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, record} <- Listing.fetch(id) do
      json(conn, %{data: Serializer.record(record, proposed_comments: true, transcript: true)})
    end
  end

  # The depth/`can_dispatch` checks repeat `ApiPolicy`'s `:dispatch` rule on
  # purpose (defense in depth), exactly as `WorkerController` does for review:
  # greenlight posts to a forge under the fleet's identity, and a depth-limited
  # session must not be able to curl its way past what MCP refuses.
  def greenlight(conn, %{"id" => id} = params) do
    scope = conn.assigns[:mcp_scope]

    with :ok <- ensure_can_dispatch(scope),
         :ok <- DispatchParams.ensure_depth(scope),
         {:ok, opts} <- id |> ReviewParams.greenlight_opts(params) |> Params.to_rest() do
      case ExternalReview.greenlight(opts) do
        {:ok, result} -> json(conn, %{data: result})
        {:error, reason} -> greenlight_error(reason)
      end
    end
  end

  defp ensure_can_dispatch(%Arbiter.MCP.Scope{tier: :coordinator, can_dispatch: true}), do: :ok

  defp ensure_can_dispatch(_),
    do: {:error, {:unauthorized, "this token may not dispatch (can_dispatch is not set)"}}

  defp greenlight_error({:not_found, _}), do: {:error, :not_found}

  defp greenlight_error(reason),
    do: {:error, {:invalid_request, ExternalReview.describe_error(reason)}}

  def transcript(conn, %{"id" => id} = params) do
    with {:ok, tail} <- parse_tail(params["tail"]),
         {:ok, record} <- Listing.fetch(id) do
      # One read + one decode pass for every projection — a tool-heavy review
      # runs to thousands of JSONL lines and this endpoint wants all of them.
      corpus = Transcript.corpus(record.id, preview: Transcript.default_preview())
      summary = corpus.summary
      {lines, truncated} = Transcript.tail(corpus.lines, tail)

      json(conn, %{
        data: %{
          record_id: record.id,
          pr_ref: record.pr_ref,
          pr: record.pr,
          workspace_id: record.workspace_id,
          status: record.status,
          model: record.model,
          path: summary.path,
          prompt_path: summary.prompt_path,
          exists: summary.exists,
          prompt_exists: summary.prompt_exists,
          prompt: maybe_prompt(record.id, params["include_prompt"]),
          line_count: summary.line_count,
          lines: lines,
          truncated: truncated,
          tool_use_count: summary.tool_use_count,
          tools_used: summary.tools_used,
          tool_uses: corpus.tool_uses
        }
      })
    end
  end

  defp maybe_prompt(id, raw) do
    case Params.boolean(raw) do
      {:ok, false} -> nil
      _ -> fetch_prompt(id)
    end
  end

  defp fetch_prompt(id) do
    case Transcript.prompt(id) do
      {:ok, prompt} -> prompt
      {:error, _} -> nil
    end
  end

  # ---- param coercion ------------------------------------------------------

  defp parse_tail(nil), do: {:ok, nil}
  defp parse_tail(""), do: {:ok, nil}

  defp parse_tail(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_request, "tail must be a positive integer"}}
    end
  end

  defp parse_tail(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp parse_tail(_), do: {:error, {:invalid_request, "tail must be a positive integer"}}
end
