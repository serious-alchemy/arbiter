defmodule ArbiterWeb.Api.MemoryController do
  @moduledoc """
  REST surface for the shared-memory operator tools (P-25), the transport
  behind `arb memory`. One thin adapter over the same handlers the
  `memory_*` MCP tools call (`Arbiter.MCP.Tools.MemoryPending`), so the two
  surfaces cannot drift.

    * `GET  /api/memory/pending` — queued candidates (`state` =
      `pending` | `rejected`, default `pending`).
    * `GET  /api/memory/pending/diff?id=` — one candidate in full, its diff
      and verification.
    * `POST /api/memory/pending/apply` — promote (`id`, optional `overwrite`).
    * `POST /api/memory/pending/reject` — reject (`id`, `reason`).
    * `GET  /api/memory/quarantine` — quarantined memories.
    * `POST /api/memory/quarantine/restore` — re-verify and serve again
      (`name`, optional `reanchor`).
    * `POST /api/memory/distill` — one transcript distillation pass
      (`session_id`, optional `max_bytes` / `from_turn` / `max_candidates` /
      `max_cost_usd`; the bounds can only lower the configured caps).

  Every route is `:operator` in `ArbiterWeb.ApiPolicy`: the shared layer is
  read by every future session, so a coordinator *session* token is refused
  here, reads included. Candidate ids are `<session-id>/<file>.md`, so they
  travel as params, not path segments.
  """

  use ArbiterWeb, :controller

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools.MemoryPending

  action_fallback(ArbiterWeb.Api.FallbackController)

  # Handler refusals the shared `Arbiter.Errors` table has no kind for, folded
  # onto the nearest one so the REST status is meaningful rather than a 500.
  @kind_aliases %{
    stale: :conflict,
    unavailable: :busy,
    budget_exhausted: :busy,
    model_error: :bad_gateway,
    system_error: :server_error
  }

  def pending_index(conn, params), do: run(conn, :memory_pending_list, params)
  def pending_diff(conn, params), do: run(conn, :memory_pending_diff, params)
  def pending_apply(conn, params), do: run(conn, :memory_pending_apply, params)
  def pending_reject(conn, params), do: run(conn, :memory_pending_reject, params)
  def quarantine_index(conn, params), do: run(conn, :memory_quarantine_list, params)
  def quarantine_restore(conn, params), do: run(conn, :memory_quarantine_restore, params)
  def distill(conn, params), do: run(conn, :memory_distill, params)

  defp run(conn, handler, params) do
    scope = conn.assigns[:mcp_scope] || %Scope{tier: :coordinator}

    case apply(MemoryPending, handler, [scope, params]) do
      {:ok, body} -> json(conn, body)
      {:error, {kind, message}} -> {:error, {Map.get(@kind_aliases, kind, kind), message}}
      {:error, other} -> {:error, other}
    end
  end
end
