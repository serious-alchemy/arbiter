defmodule Arbiter.Messages.Mailbox do
  @moduledoc """
  The one mailbox API every surface goes through (parity audit P-26).

  `GET/POST/DELETE /api/messages`, the MCP tools `inbox_check`,
  `coordinator_inbox`, `coordinator_inbox_clear`, `message_send` and
  `notify_list`, and — through REST — `arb inbox` / `arb message` / `arb notify`
  are thin adapters over the functions here, so a rule is stated once:

    * **Workspace.** A send is filed under the *recipient task's* workspace
      (`send_message/2`); a workspace the caller names that disagrees with the
      task is refused rather than honoured. Reads filter on `workspace_id` when
      given and read every workspace when not.
    * **Reader identity.** `reader/2`: the token's session (an MCP/REST session
      token) wins, then an explicit session id, else the shared sessionless
      coordinator reader. A task mailbox has one reader and is always read at
      row level (`effective_reader/2`).
    * **Listing.** `list/1` — unread and outstanding queues are oldest-first and
      uncapped unless a `limit` is given; the history view is newest-first with
      a default 50-row cap. The ceiling for any `limit` is `max_limit/0`.
    * **Read side effects.** Explicit: `mark_read: true` stamps what an unread
      listing returns; the default here is `false`. Surfaces state their own
      default (MCP `inbox_check` / `coordinator_inbox` and the CLI task drain
      pass `true`, the REST `GET` and the CLI coordinator view `false`).
    * **Clear.** `clear/2` takes one of three forms and always answers with the
      same map (`t:clear_result/0`).
  """

  alias Arbiter.MCP.Scope
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspaces

  require Ash.Query

  @default_limit 50
  @max_limit 500

  @type state :: :unread | :outstanding | :any
  @type clear_result :: %{
          cleared: [String.t()],
          cleared_count: non_neg_integer(),
          not_found: [String.t()],
          deleted_read: non_neg_integer(),
          deleted_unread: non_neg_integer(),
          remaining_unread: non_neg_integer(),
          workspace_id: String.t() | nil
        }

  @doc "Default row cap for the history (`state: :any`) view."
  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @doc "Ceiling for any caller-supplied `limit`."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  # ---- reader identity ------------------------------------------------------

  @doc """
  The reader a call acts as. A session token's own `session_id` wins over any
  `session` argument (a token cannot speak for another session); a token with
  no session falls back to the explicit one (`arb inbox --session`), else the
  shared sessionless coordinator reader.
  """
  @spec reader(Scope.t() | nil, String.t() | nil) :: String.t()
  def reader(%Scope{session_id: sid}, _session) when is_binary(sid) and sid != "",
    do: Message.session_reader(sid)

  def reader(_scope, session) when is_binary(session) and session != "",
    do: Message.session_reader(session)

  def reader(_scope, _session), do: Message.coordinator_reader()

  @doc """
  The reader that applies to a mailbox: per-reader receipts only exist on the
  coordinator mailbox. A task mailbox has exactly one reader, so it is read and
  marked at row level (`nil`) whoever asks.
  """
  @spec effective_reader(String.t() | nil, String.t() | nil) :: String.t() | nil
  def effective_reader(to_ref, reader) when is_binary(reader) do
    if to_ref in Message.coordinator_refs(), do: reader, else: nil
  end

  def effective_reader(_to_ref, _reader), do: nil

  # ---- listing --------------------------------------------------------------

  @doc """
  Messages matching the filters.

  Options: `:to_ref`, `:from_ref`, `:kind` (atom), `:workspace_id`,
  `:state` (`:unread` | `:outstanding` | `:any`, default `:any`), `:reader`,
  `:limit`, `:mark_read` (stamp the returned *unread* messages read; default
  `false`).

  `:unread` / `:outstanding` without a `:kind` are the mailbox-family queue
  (what `inbox_check` has always listed), oldest first. `:any` is newest first.
  """
  @spec list(keyword()) :: [Message.t()]
  def list(opts) do
    state = Keyword.get(opts, :state, :any)
    to_ref = Keyword.get(opts, :to_ref)
    reader = effective_reader(to_ref, Keyword.get(opts, :reader))

    messages =
      Message
      |> filter_to_ref(to_ref)
      |> filter_from_ref(Keyword.get(opts, :from_ref))
      |> filter_kind(Keyword.get(opts, :kind), state)
      |> filter_workspace(Keyword.get(opts, :workspace_id))
      |> for_state(state, reader)
      |> order_and_limit(state, Keyword.get(opts, :limit))
      |> Ash.read!()

    # Mail only: a notification is a broadcast and is never consumed.
    if state == :unread and Keyword.get(opts, :mark_read, false) do
      for %{kind: kind} = message <- messages, kind in Message.mailbox_kinds() do
        Message.mark_read(message, reader: reader)
      end
    end

    messages
  end

  @doc "The most recent notifications (`:limit`, `:workspace_id`), newest first."
  @spec notifications(keyword()) :: [Message.t()]
  def notifications(opts \\ []) do
    list(
      kind: :notification,
      workspace_id: Keyword.get(opts, :workspace_id),
      limit: Keyword.get(opts, :limit, 20)
    )
  end

  @doc "Mark one message (or id) read as `reader:` — row level for a task mailbox."
  @spec mark_read(Message.t() | String.t(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  def mark_read(id, opts) when is_binary(id) do
    with {:ok, message} <- Ash.get(Message, id), do: mark_read(message, opts)
  end

  def mark_read(%Message{} = message, opts) do
    Message.mark_read(message,
      reader: effective_reader(message.to_ref, Keyword.get(opts, :reader))
    )
  end

  defp filter_to_ref(query, ref) when ref in [nil, ""], do: query

  defp filter_to_ref(query, ref),
    do: Ash.Query.filter(query, to_ref in ^Message.ref_variants(ref))

  defp filter_from_ref(query, ref) when ref in [nil, ""], do: query

  defp filter_from_ref(query, ref),
    do: Ash.Query.filter(query, from_ref in ^Message.ref_variants(ref))

  defp filter_kind(query, nil, state) when state in [:unread, :outstanding],
    do: Ash.Query.filter(query, kind in ^Message.mailbox_kinds())

  defp filter_kind(query, nil, :any), do: query
  defp filter_kind(query, kind, _state), do: Ash.Query.filter(query, kind == ^kind)

  defp filter_workspace(query, ws) when is_binary(ws),
    do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_workspace(query, _ws), do: query

  defp for_state(query, :any, _reader), do: query
  defp for_state(query, state, reader), do: Message.for_reader(query, reader, state)

  defp order_and_limit(query, :any, limit) do
    query
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(clamp(limit || @default_limit))
  end

  defp order_and_limit(query, _queue, nil), do: Ash.Query.sort(query, inserted_at: :asc)

  defp order_and_limit(query, _queue, limit) do
    query |> Ash.Query.sort(inserted_at: :asc) |> Ash.Query.limit(clamp(limit))
  end

  defp clamp(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  # ---- send -----------------------------------------------------------------

  @doc """
  Compose and send a message.

  `params` (atom keys): `:to_ref`, `:body` (required), `:kind` (atom or string),
  `:subject`, `:task_ref` (or the deprecated `:directive_ref`), `:from_ref`
  (honoured only for an unauthenticated caller), `:workspace` (name or id).

  The envelope comes from the scope, never the caller: a coordinator sends from
  `"coordinator"` (default kind `:direction`), a worker from its own task
  (default `:flag`; a worker cannot direct, so a direction becomes a flag).
  The recipient must be the coordinator or an existing task (a worker reaches
  only its own workspace's tasks); the message is filed in the recipient task's
  workspace. A named `:workspace` that disagrees with it is `{:invalid, _}`.
  """
  @spec send_message(Scope.t() | nil, map()) ::
          {:ok, Message.t()} | {:error, Workspaces.error() | term()}
  def send_message(scope, params) when is_map(params) do
    to_ref = blank_to_nil(params[:to_ref])

    with {:ok, recipient} <- resolve_recipient(scope, to_ref),
         {:ok, ws_id} <- message_workspace(scope, recipient, params[:workspace]) do
      attrs =
        params
        |> Map.take([:to_ref, :body, :subject])
        |> Map.merge(%{workspace_id: ws_id, kind: kind_for(scope, params[:kind])})
        |> Map.put(:from_ref, from_ref(scope, params[:from_ref]))
        |> put_task_ref(scope, recipient, params)
        |> drop_nil()
        |> Message.hand_written()
        |> mark_unverified_origin()

      Message.send_mail(attrs)
    end
  end

  # `:coordinator` | `{:task, issue}` | `nil` (no recipient — a broadcast kind).
  defp resolve_recipient(_scope, nil), do: {:ok, nil}

  defp resolve_recipient(_scope, to_ref) when to_ref in ["coordinator", "admiral"],
    do: {:ok, :coordinator}

  defp resolve_recipient(scope, to_ref) do
    case Ash.get(Issue, to_ref) do
      {:ok, %Issue{} = issue} ->
        if bound_elsewhere?(scope, issue.workspace_id),
          do: {:error, {:not_found, "task #{to_ref} not found"}},
          else: {:ok, {:task, issue}}

      _ ->
        {:error, {:not_found, "task #{to_ref} not found"}}
    end
  end

  # A token bound to one workspace (every worker) cannot see — or name the
  # existence of — a task elsewhere.
  defp bound_elsewhere?(%Scope{workspace_id: bound}, ws_id) when is_binary(bound),
    do: bound != ws_id

  defp bound_elsewhere?(_scope, _ws_id), do: false

  defp message_workspace(scope, {:task, issue}, named) do
    with {:ok, resolved} <- Workspaces.resolve(scope, blank_to_nil(named), mode: :read) do
      if is_nil(resolved) or resolved == issue.workspace_id,
        do: {:ok, issue.workspace_id},
        else:
          {:error,
           {:invalid,
            "workspace #{inspect(named)} is not the recipient task's workspace " <>
              "(#{issue.workspace_id}); a message is filed in its recipient's workspace"}}
    end
  end

  defp message_workspace(%Scope{tier: :worker, workspace_id: ws}, _recipient, _named)
       when is_binary(ws),
       do: {:ok, ws}

  # An escalation raised by an `arb` in a sandbox or another install names a
  # workspace this installation has no row for. It is delivered and marked
  # (`mark_unverified_origin/1`), never dropped, so an unknown workspace is kept
  # as written for an UNBOUND caller; a bound token gets the resolver's answer.
  defp message_workspace(scope, _recipient, named) do
    case Workspaces.resolve(scope, blank_to_nil(named), mode: :write) do
      {:error, {:not_found, _}} = error ->
        if is_binary(named) and named != "" and unbound?(scope),
          do: {:ok, named},
          else: error

      other ->
        other
    end
  end

  defp unbound?(nil), do: true
  defp unbound?(%Scope{workspace_id: ws}), do: is_nil(ws)

  defp kind_for(%Scope{tier: :worker}, kind) when kind in [nil, "", :direction, "direction"],
    do: :flag

  defp kind_for(%Scope{tier: :coordinator}, kind) when kind in [nil, ""], do: :direction
  defp kind_for(_scope, kind) when kind in [nil, ""], do: nil
  defp kind_for(_scope, kind) when is_atom(kind), do: kind

  defp kind_for(_scope, kind) when is_binary(kind) do
    String.to_existing_atom(kind)
  rescue
    # Left as written; the resource answers with a clean validation error.
    ArgumentError -> kind
  end

  defp from_ref(%Scope{tier: :worker, task_id: task_id}, _given), do: task_id
  defp from_ref(%Scope{tier: :coordinator}, _given), do: "coordinator"
  defp from_ref(_scope, given), do: given

  # The ticket a message concerns: the caller's `task_ref`, else the recipient
  # task, else (a worker flagging the coordinator) the worker's own task.
  defp put_task_ref(attrs, scope, recipient, params) do
    ref =
      blank_to_nil(params[:task_ref]) || blank_to_nil(params[:directive_ref]) ||
        default_task_ref(scope, recipient)

    Map.put(attrs, :task_ref, ref)
  end

  defp default_task_ref(_scope, {:task, issue}), do: issue.id
  defp default_task_ref(%Scope{tier: :worker, task_id: task_id}, _recipient), do: task_id
  defp default_task_ref(_scope, _recipient), do: nil

  # bd-2nbu7a / #15: an agent CLI in a throwaway sandbox on this host posts to
  # the live coordinator. Its escalation names a task this installation has no
  # row for. Mark such an escalation — never drop it: an operator can still
  # read it, and only a task_ref this installation cannot resolve is flagged.
  defp mark_unverified_origin(%{kind: :escalation, task_ref: ref} = attrs)
       when is_binary(ref) and ref != "" do
    if task_known?(ref) do
      attrs
    else
      note =
        "[origin not verified: #{ref} is not a task in this installation — " <>
          "likely a sandbox, test fixture or another install posting to this host]"

      %{
        attrs
        | subject: "[UNVERIFIED ORIGIN: #{ref}] #{attrs[:subject]}",
          body: "#{note}\n\n#{attrs[:body]}"
      }
    end
  end

  defp mark_unverified_origin(attrs), do: attrs

  defp task_known?(id), do: match?({:ok, %Issue{}}, Ash.get(Issue, id))

  defp drop_nil(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  # ---- clear ----------------------------------------------------------------

  @doc """
  Soft-clear messages. One of:

    * `{:ids, ids}` — exactly those messages, resolved regardless of workspace;
    * `{:task, task_ref}` — every coordinator message concerning the task
      (`workspace_id:` narrows; omitted = every workspace);
    * `{:mailbox, to_ref, all?}` — the outstanding (read) tail of a mailbox, or
      everything read and unread when `all?`.

  Options: `:reader`, `:workspace_id`. Always `{:ok, t:clear_result/0}`.
  """
  @spec clear(
          {:ids, [String.t()]} | {:task, String.t()} | {:mailbox, String.t(), boolean()},
          keyword()
        ) ::
          {:ok, clear_result()}
  def clear(form, opts \\ [])

  def clear({:ids, ids}, opts) do
    read_ids = read_ids(Message.coordinator_ref(), opts)
    {:ok, cleared, not_found} = Message.clear_ids(ids, reader_opt(opts))
    {:ok, result(cleared, not_found, read_ids, Message.coordinator_ref(), opts)}
  end

  def clear({:task, task_ref}, opts) do
    read_ids = read_ids(Message.coordinator_ref(), opts)
    {:ok, cleared} = Message.clear_by_task(task_ref, reader_opt(opts) ++ ws_opt(opts))
    {:ok, result(cleared, [], read_ids, Message.coordinator_ref(), opts)}
  end

  def clear({:mailbox, to_ref, all?}, opts) do
    reader = effective_reader(to_ref, Keyword.get(opts, :reader))
    scope = [reader: reader] ++ ws_opt(opts)

    queue = Message.outstanding(to_ref, scope)
    pending = if all?, do: Message.inbox(to_ref, scope), else: []

    if all?, do: Message.clear_all(to_ref, scope), else: Message.clear_read(to_ref, scope)

    {:ok, result(queue ++ pending, [], Enum.map(queue, & &1.id), to_ref, opts)}
  end

  defp reader_opt(opts), do: [reader: Keyword.get(opts, :reader)]
  defp ws_opt(opts), do: [workspace_id: Keyword.get(opts, :workspace_id)]

  # The ids this reader had already read (its outstanding queue) before a clear.
  # A session reader's read state lives in receipts, not on the row, so the
  # row's `read_at` cannot say.
  defp read_ids(to_ref, opts) do
    reader = effective_reader(to_ref, Keyword.get(opts, :reader))
    to_ref |> Message.outstanding(reader: reader) |> Enum.map(& &1.id)
  end

  defp result(cleared, not_found, read_ids, to_ref, opts) do
    {read, unread} = Enum.split_with(cleared, &(&1.id in read_ids))

    remaining =
      length(
        list(
          to_ref: to_ref,
          state: :unread,
          reader: Keyword.get(opts, :reader),
          workspace_id: Keyword.get(opts, :workspace_id)
        )
      )

    %{
      cleared: Enum.map(cleared, & &1.id),
      cleared_count: length(cleared),
      not_found: not_found,
      deleted_read: length(read),
      deleted_unread: length(unread),
      remaining_unread: remaining,
      workspace_id: Keyword.get(opts, :workspace_id)
    }
  end
end
