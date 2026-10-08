defmodule Arbiter.MCP.Tools.Messaging do
  @moduledoc """
  `Arbiter.MCP.Tools` handlers for task/coordinator mailboxes and
  notifications: `inbox_check` / `coordinator_inbox` / `message_send` /
  `notify_list`. Split out of `Arbiter.MCP.Tools` (see its moduledoc) —
  called back into for the generic arg/serialization helpers it still owns.
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Messages.Mailbox
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Attention

  @message_kinds_mcp ~w(notification completion failure escalation info)a

  # ---- inbox_check --------------------------------------------------------

  @doc """
  The mailbox for a task — the structured replacement for `arb inbox <task>`.
  Worker: its own task. Coordinator: the `task_id` argument, within its workspace.

  Two states:
  - `state: "unread"` (default): unread messages, oldest first. `mark_read`
    (default `true`) stamps them read on return; pass `false` to peek.
  - `state: "outstanding"`: read-but-uncleared messages; pure read, no mutations.

  Both are `Arbiter.Messages.Mailbox.list/1`.
  """
  @spec inbox_check(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def inbox_check(%Scope{} = scope, args) do
    state = Tools.fetch_string(args, "state") || "unread"

    with :ok <- validate_state(state),
         {:ok, mark_read} <- Tools.fetch_bool(args, "mark_read", true),
         {:ok, to_ref} <- Tools.resolve_task_id(scope, args, "task_id"),
         {:ok, task} <- Tools.fetch_task(scope, args, to_ref) do
      messages =
        Mailbox.list(
          to_ref: to_ref,
          state: String.to_existing_atom(state),
          workspace_id: task.workspace_id,
          mark_read: mark_read
        )

      {:ok,
       %{
         task_id: to_ref,
         messages: Enum.map(messages, &serialize_message/1),
         count: length(messages)
       }}
    end
  end

  # ---- coordinator_inbox --------------------------------------------------

  @doc """
  The coordinator escalation mailbox for the bound workspace — the structured
  replacement for `arb message inbox` / `arb inbox`. Coordinator only; the
  worker tier is denied at the catalog level.

  Lists messages where `to_ref == "coordinator"`. Two states:
  - `state: "unread"` (default): unread messages, marks them read on return,
    and optionally soft-clears the outstanding tail (mirrors `arb inbox clear`).
  - `state: "outstanding"`: read-but-uncleared messages; pure read, no mutations.

  `state: "outstanding"` and `clear: true` are mutually exclusive and will
  return an error.

  ## The computed queue (bd-8nlez1)

  Both states also return `attention`: every open ticket whose attention the
  coordinator owns (`Arbiter.Tasks.Attention.items(owner: :coordinator)`),
  oldest first, with `attention_count`. The queue has no read or clear state:
  an item is listed exactly while its ticket's attention is, and goes when the
  ticket moves on — `coordinator_inbox_clear` is for the messages beside it.
  An item the coordinator cannot resolve goes to the operator with
  `ticket_handoff`.

  ## Reader identity (bd-8akewg)

  The mailbox itself is shared — every producer writes one row, and every
  session sees it. What is *not* shared is read/cleared state: this handler
  derives a reader from the calling scope (`"session:<id>"` for a
  browser-hosted session's token, the shared `"coordinator"` reader for a plain
  minted token) and marks read / clears only that reader's view. Session A
  polling no longer empties session B's inbox.

  A session's unread view is bounded, because with no receipts a reader is
  unread on *everything* and handing a session created today the whole archive
  is not a mailbox. The bound is a union: mail raised since the session
  started, plus anything still globally uncleared — an escalation raised before
  the session was launched is usually the reason it was launched, and a session
  clear never stamps the row, so the `last_escalation/2` dedupe would
  otherwise suppress the repeat forever. Only the resolved archive is withheld.

  ## Workspace scope

  A workspace-bound token is confined to its workspace, as before. A
  cross-workspace token that names no `workspace` now reads **every** workspace
  rather than silently falling back to the lone/"default" one — escalations
  raised elsewhere used to be invisible to it. Passing `workspace` still
  filters to that one.
  """
  @spec coordinator_inbox(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def coordinator_inbox(%Scope{} = scope, args) do
    state = Tools.fetch_string(args, "state") || "unread"

    with :ok <- validate_state(state),
         {:ok, clear} <- Tools.fetch_bool(args, "clear", false),
         {:ok, mark_read} <- Tools.fetch_bool(args, "mark_read", true),
         :ok <- validate_state_and_clear_combo(state, clear),
         {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      ref = Message.coordinator_ref()
      reader = Mailbox.reader(scope, nil)

      messages =
        Mailbox.list(
          to_ref: ref,
          state: String.to_existing_atom(state),
          workspace_id: ws_id,
          reader: reader,
          mark_read: mark_read
        )

      base = %{
        messages: Enum.map(messages, &serialize_message/1),
        count: length(messages),
        workspace_id: ws_id
      }

      cleared = if state == "unread", do: bulk_clear(clear, ref, ws_id, reader), else: %{}
      {:ok, base |> Map.merge(cleared) |> Map.merge(attention_queue(ws_id))}
    end
  end

  # `clear: true` soft-clears the reader's outstanding tail (mirrors `arb inbox
  # clear`); the counts ride on the unread response, as they always have.
  defp bulk_clear(true, ref, ws_id, reader) do
    {:ok, result} = Mailbox.clear({:mailbox, ref, false}, reader: reader, workspace_id: ws_id)
    Map.take(result, [:deleted_read, :deleted_unread, :remaining_unread])
  end

  defp bulk_clear(false, _ref, _ws_id, _reader) do
    %{deleted_read: 0, deleted_unread: 0, remaining_unread: 0}
  end

  defp attention_queue(ws_id) do
    items =
      [owner: :coordinator, workspace_id: ws_id]
      |> Attention.items()
      |> Enum.map(&Tools.serialize_attention_item/1)

    %{attention: items, attention_count: length(items)}
  end

  defp validate_state(state) when state in ["unread", "outstanding"] do
    :ok
  end

  defp validate_state(state) do
    {:error, {:invalid_args, "state must be \"unread\" or \"outstanding\", got \"#{state}\""}}
  end

  defp validate_state_and_clear_combo("outstanding", true) do
    {:error, {:invalid_args, "clear: true cannot be combined with state: \"outstanding\""}}
  end

  defp validate_state_and_clear_combo(_state, _clear) do
    :ok
  end

  # ---- coordinator_inbox_clear ---------------------------------------------

  @doc """
  Soft-clear specific coordinator-mailbox messages — the structured
  replacement for `arb inbox clear <id> ...` / `arb inbox clear --task
  <task-id>`. Coordinator only. Accepts `ids` (a list of message ids) and/or
  `task_id`; at least one is required.

  `ids` resolve directly by id, **regardless of workspace** (bd-95pse9: an id
  is already unambiguous, and a workspace-scoped lookup here is exactly the
  trap that made `coordinator_inbox` silently return `count: 0` when the
  caller omitted `workspace`). `task_id` clears every coordinator message
  concerning that task, in every workspace the token may see (a task id is
  unambiguous); an explicit `workspace` arg, or a workspace-bound token,
  narrows it — the same rule as REST `DELETE /api/messages?task_id=`.

  Both forms clear **only the calling reader's view** (bd-8akewg): a session
  token writes its own receipts and leaves the shared row — and therefore every
  other session, the sessionless coordinator, and the `last_escalation/2`
  escalation dedupe — untouched. A plain minted token is the shared sessionless
  coordinator reader, which still stamps the row exactly as before.

  Returns the `t:Arbiter.Messages.Mailbox.clear_result/0` map — the same keys
  (`cleared` ids, `cleared_count`, `not_found`, …) REST `DELETE /api/messages`
  answers with for every form; both forms in one call are merged.
  """
  @spec coordinator_inbox_clear(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def coordinator_inbox_clear(%Scope{} = scope, args) do
    ids = fetch_string_list(args, "ids")
    task_id = Tools.fetch_string(args, "task_id")

    if ids == [] and is_nil(task_id) do
      {:error, {:invalid_args, "coordinator_inbox_clear requires ids and/or task_id"}}
    else
      reader = Mailbox.reader(scope, nil)

      with {:ok, by_ids} <- clear_ids_if_present(ids, reader),
           {:ok, by_task} <- clear_by_task_if_present(scope, args, task_id, reader) do
        {:ok, merge_cleared(by_ids, by_task)}
      end
    end
  end

  defp clear_ids_if_present([], _reader), do: {:ok, nil}
  defp clear_ids_if_present(ids, reader), do: Mailbox.clear({:ids, ids}, reader: reader)

  defp clear_by_task_if_present(_scope, _args, nil, _reader), do: {:ok, nil}

  # Class B (like `coordinator_inbox`): a task id is already unambiguous, so no
  # `workspace` means every workspace the token may see — never a silent fall
  # back to the workspace named `default`.
  defp clear_by_task_if_present(scope, args, task_id, reader) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args) do
      Mailbox.clear({:task, task_id}, reader: reader, workspace_id: ws_id)
    end
  end

  defp merge_cleared(a, nil), do: a
  defp merge_cleared(nil, b), do: b

  defp merge_cleared(a, b) do
    %{
      a
      | cleared: a.cleared ++ b.cleared,
        cleared_count: a.cleared_count + b.cleared_count,
        deleted_read: a.deleted_read + b.deleted_read,
        deleted_unread: a.deleted_unread + b.deleted_unread,
        remaining_unread: min(a.remaining_unread, b.remaining_unread)
    }
  end

  defp fetch_string_list(args, key) when is_map(args) do
    case Map.get(args, key) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp fetch_string_list(_args, _key), do: []

  # ---- message_send -------------------------------------------------------

  @doc """
  Send a message to a task's mailbox — the structured replacement for
  `arb message <task> <text>`. Available to **both** tiers, with the envelope
  set from the scope so the sender identity cannot be spoofed:

    * a **coordinator** sends a `:direction` from `"coordinator"` down to any
      task in its workspace;
    * a **worker** raises a `:flag` from its own bound task to a sibling.

  The recipient must exist and be reachable by the scope, and the message is
  filed in the recipient task's own workspace, so it can only ever be created
  alongside its recipient. Backs onto `Messages.Mailbox.send_message/2` — the
  same function REST `POST /api/messages` (and so `arb message`) uses.
  """
  @spec message_send(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def message_send(%Scope{} = scope, args) do
    with {:ok, to_ref} <- Tools.require_string(args, "task_id"),
         {:ok, body} <- Tools.require_string(args, "body"),
         {:ok, kind} <- validate_message_kind(Tools.fetch_string(args, "kind")) do
      params = %{
        to_ref: to_ref,
        body: body,
        kind: kind,
        subject: Tools.fetch_string(args, "subject"),
        task_ref:
          Tools.fetch_string(args, "task_ref") || Tools.fetch_string(args, "directive_ref"),
        workspace: Tools.fetch_string(args, "workspace")
      }

      case Mailbox.send_message(scope, params) do
        {:ok, message} -> {:ok, serialize_message(message)}
        {:error, {_kind, _msg} = err} -> {:error, err}
        {:error, err} -> {:error, {:invalid, Tools.ash_error_message(err)}}
      end
    end
  end

  # Validate and convert message kind from string to atom. Returns {:ok, nil}
  # if not specified (use auto-derived kind), or {:ok, atom} if valid, or
  # {:error, {_, msg}} if invalid.
  defp validate_message_kind(nil), do: {:ok, nil}

  defp validate_message_kind(kind_str) when is_binary(kind_str) do
    case Tools.to_allowed_atom(kind_str, @message_kinds_mcp) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "invalid kind #{inspect(kind_str)}"}}
    end
  end

  # ---- notify_list --------------------------------------------------------

  @doc """
  The most recent notifications (broadcast events: completions, milestones,
  system events). Available to both tiers; a bound token is confined to its
  workspace, an unbound coordinator naming no `workspace` reads ALL workspaces
  (each row and the response echo `workspace_id`). Read-only — notifications
  are never consumed.
  Optional `limit` (default 20, max 500). Backs onto `Messages.Mailbox.notifications/1`.
  """
  @spec notify_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def notify_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Tools.authorized_workspace(scope, args),
         {:ok, limit} <- Tools.parse_bounded_limit(args, "limit", 20, Mailbox.max_limit()) do
      notifications =
        [workspace_id: ws_id, limit: limit]
        |> Mailbox.notifications()
        |> Enum.map(&serialize_message/1)

      {:ok, %{notifications: notifications, count: length(notifications), workspace_id: ws_id}}
    end
  end

  defp serialize_message(%Message{} = m) do
    %{
      id: m.id,
      workspace_id: m.workspace_id,
      kind: Tools.to_str(m.kind),
      from_ref: m.from_ref,
      to_ref: m.to_ref,
      subject: m.subject,
      body: m.body,
      task_ref: m.task_ref,
      directive_ref: m.directive_ref,
      read_at: Tools.iso(m.read_at),
      cleared_at: Tools.iso(m.cleared_at),
      inserted_at: Tools.iso(m.inserted_at)
    }
  end
end
