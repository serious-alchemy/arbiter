defmodule ArbiterWeb.Api.MessageController do
  @moduledoc """
  REST endpoints for `Arbiter.Messages.Message` — the inter-agent queue.

  Routes (a thin adapter over `Arbiter.Messages.Mailbox`, as the MCP mailbox
  tools and `arb inbox` / `arb message` / `arb notify` are):

    * `GET  /api/messages`           — :index (filters: workspace (id or name;
                                       `workspace_id` alias), kind, to_ref, from_ref,
                                       unread=true [pending: read_at & cleared_at
                                       both nil], outstanding=true [read, not
                                       cleared], limit, mark_read=true [stamp the
                                       returned unread messages read; default
                                       false — a plain GET is a pure read]).
                                       Unread/outstanding are oldest-first and
                                       uncapped unless `limit` is given; the
                                       history view is newest-first, 50 by default.
                                       `limit` never exceeds 500. A worker token
                                       may read its own mailbox (`to_ref=<its
                                       task>`) and the notification feed
                                       (`kind=notification`, its own workspace).
    * `GET  /api/messages/:id`       — :show (one message in full; a worker
                                       token may read only its own task's mail)
    * `POST /api/messages`           — :create (body: kind, to_ref, subject,
                                       body, task_ref (or the deprecated
                                       directive_ref alias), workspace_id). The
                                       recipient must be the coordinator or an
                                       existing task and the message is filed in
                                       the RECIPIENT's workspace; a `workspace_id`
                                       that disagrees is a 422.
    * `POST /api/messages/:id/read`  — :read (stamp read_at = now)
    * `DELETE /api/messages`         — :clear (soft-clear by stamping cleared_at;
                                       rows are retained, not destroyed). Three
                                       forms: `ids=<comma-separated>` clears
                                       exactly those messages, resolved
                                       regardless of workspace; `task_id=<ref>`
                                       (+ optional `workspace`; omitted = every
                                       workspace the token may see) clears every
                                       coordinator message concerning that
                                       task; `to_ref=<ref>` (+ optional `all`)
                                       is the bulk mailbox clear — `all=true`
                                       clears read+unread, absent/false clears
                                       the outstanding (read) tail only. Every
                                       form answers with the same keys
                                       (`cleared`, `cleared_count`, `not_found`,
                                       `deleted_read`, `deleted_unread`,
                                       `remaining_unread`, `workspace_id`).

  ## Reader identity (bd-8akewg)

  The coordinator mailbox is shared, but read/cleared state is per reader. The
  reader is derived from the token exactly as the MCP tools derive it
  (`Mailbox.reader/2`): a session token acts as its own session; any other token
  is the **sessionless coordinator** reader — the identity the CLI, the
  dashboard drawer and a plain minted token share — unless it names a
  `session=<session_id>` on :index, :read or any :clear form. A session's reads
  and clears leave the shared row, and therefore every other reader, untouched.
  """

  use ArbiterWeb, :controller

  alias Arbiter.Messages.Mailbox
  alias Arbiter.Messages.Message
  alias Arbiter.Params
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, params) do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, limit} <- parse_limit(params["limit"]),
         {:ok, kind} <- parse_kind(params["kind"]),
         {:ok, unread?} <- params |> Params.fetch_bool("unread", false) |> Params.to_rest(),
         {:ok, outstanding?} <-
           params |> Params.fetch_bool("outstanding", false) |> Params.to_rest(),
         {:ok, mark_read?} <- params |> Params.fetch_bool("mark_read", false) |> Params.to_rest(),
         {:ok, state} <- parse_state(unread?, outstanding?) do
      messages =
        Mailbox.list(
          workspace_id: ws_id,
          kind: kind,
          to_ref: params["to_ref"],
          from_ref: params["from_ref"],
          state: state,
          reader: reader_ref(conn, params),
          limit: limit,
          mark_read: mark_read?
        )

      render(conn, :index, messages: messages, workspace_id: ws_id)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, message} <- Ash.get(Message, id) do
      render(conn, :show, message: message)
    end
  end

  def create(conn, params) do
    attrs = %{
      to_ref: params["to_ref"],
      body: params["body"],
      kind: params["kind"],
      subject: params["subject"],
      task_ref: params["task_ref"],
      directive_ref: params["directive_ref"],
      from_ref: params["from_ref"],
      workspace: Arbiter.Tasks.Workspaces.arg(params)
    }

    case Mailbox.send_message(conn.assigns[:mcp_scope], attrs) do
      {:ok, message} ->
        conn
        |> put_status(:created)
        |> render(:show, message: message)

      {:error, _} = err ->
        err
    end
  end

  def read(conn, %{"id" => id} = params) do
    with {:ok, updated} <- Mailbox.mark_read(id, reader: reader_ref(conn, params)) do
      render(conn, :show, message: updated)
    end
  end

  # Soft-clear specific messages by id (comma-separated). Resolved directly by
  # id — no workspace scoping, since an id is already unambiguous (bd-95pse9:
  # a workspace-scoped lookup here is exactly the trap that made
  # `coordinator_inbox` silently return `count: 0` when the caller omitted
  # `workspace`).
  def clear(conn, %{"ids" => ids_param} = params) when is_binary(ids_param) and ids_param != "" do
    ids =
      ids_param
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, result} = Mailbox.clear({:ids, ids}, reader: reader_ref(conn, params))
    json(conn, %{data: result})
  end

  # Soft-clear every coordinator message concerning `task_id` — in the named
  # `workspace`, else (a task id being unambiguous) every workspace the token
  # may see. The same rule as MCP `coordinator_inbox_clear`.
  def clear(conn, %{"task_id" => task_id} = params) when is_binary(task_id) and task_id != "" do
    with {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, result} <-
           Mailbox.clear({:task, task_id}, reader: reader_ref(conn, params), workspace_id: ws_id) do
      json(conn, %{data: result})
    end
  end

  # Soft-clear a mailbox: stamp `cleared_at` on the outstanding (read, uncleared)
  # tail addressed to `to_ref`. Pending mail is left untouched — you read it
  # first, then clear. Pass `all=true` to clear both read and unread. Rows are
  # retained (soft), never destroyed; the durable escalation record survives.
  # `to_ref` is required so a stray call can't sweep the table.
  def clear(conn, %{"to_ref" => to_ref} = params) when is_binary(to_ref) and to_ref != "" do
    with {:ok, all?} <- params |> Params.fetch_bool("all", false) |> Params.to_rest(),
         {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read),
         {:ok, result} <-
           Mailbox.clear({:mailbox, to_ref, all?},
             reader: reader_ref(conn, params),
             workspace_id: ws_id
           ) do
      json(conn, %{data: result})
    end
  end

  def clear(_conn, _params),
    do: {:error, {:invalid_request, "clear requires ids, task_id or to_ref"}}

  # ---- helpers ----

  # The reader these endpoints act as: the token's own session when it has one,
  # else `session=<session_id>`, else the shared sessionless coordinator reader
  # (whose state is mirrored onto the row — which is why callers that never
  # pass `session` see no change at all).
  defp reader_ref(conn, params), do: Mailbox.reader(conn.assigns[:mcp_scope], params["session"])

  defp parse_state(true, true),
    do: {:error, {:invalid_request, "unread and outstanding are mutually exclusive"}}

  defp parse_state(true, false), do: {:ok, :unread}
  defp parse_state(false, true), do: {:ok, :outstanding}
  defp parse_state(false, false), do: {:ok, :any}

  # ---- param coercion ----

  # No `limit` is `nil`: the unread/outstanding queues are uncapped and the
  # history view applies `Mailbox.default_limit/0` itself.
  defp parse_limit(raw) when raw in [nil, ""], do: {:ok, nil}

  defp parse_limit(raw),
    do: raw |> Params.limit(Mailbox.default_limit(), Mailbox.max_limit()) |> Params.to_rest()

  defp parse_kind(nil), do: {:ok, nil}
  defp parse_kind(""), do: {:ok, nil}

  defp parse_kind(raw) when is_binary(raw) do
    {:ok, String.to_existing_atom(raw)}
  rescue
    ArgumentError -> {:error, {:invalid_request, "invalid kind: #{inspect(raw)}"}}
  end
end
