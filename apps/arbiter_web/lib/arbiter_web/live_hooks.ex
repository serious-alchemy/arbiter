defmodule ArbiterWeb.LiveHooks do
  @moduledoc """
  Shared `on_mount` callbacks attached via `live_session` in the router.

  ## `:current_path`

  Stores the request path of the current LiveView on the socket as
  `:current_path`, kept in sync across `live_navigate`/`live_patch` via a
  `handle_params` hook. The `Layouts.app` nav reads it to highlight the
  active link.

  ## `:live`

  Assigns `:live` on the socket as `connected?(socket)` — `false` on the
  initial dead render, `true` once the LiveView process is connected over
  the socket. `Layouts.app`'s navbar badge (and every page-level
  `live_badge`) reads this assign; `live_badge/1`'s `live` attr is
  `required: true` precisely so no call site can fall back to a client-only
  mechanism instead. The DOM-only join-direction mechanism `live_badge/1`
  used to default to (`phx-connected` flipping "stale" to "Live" with no
  server assign) was the root cause of bd-akygjy — see the "Root cause"
  note on `ArbiterWeb.CoreComponents.Feedback.live_badge/1` for what was
  and wasn't established about why. This hook is the single source of
  truth every call site must be fed from.

  ## `:quota`

  Loads the latest quota snapshot for every tracked provider on the default
  workspace and assigns the list as `:quotas` on the socket (`[]` when
  nothing has been captured yet).

  `:quotas` is a `Phoenix.LiveView.AsyncResult` (bd-adewb4): the hook runs on
  every page, so the load (a workspaces read plus up to 18-20 queries on a
  cold `QuotaCache`) runs in `start_async/3` on the connected mount only. The
  dead render reads nothing and the top bar says "loading"; a failed load
  renders inline as an error. `{:quota_updated, ...}` broadcasts merge into the
  loaded result, joined once the load has named the workspace.

  **Temporary:** Codex is filtered from the quota list pending a fix: its
  dispatch is broken (bd-1nyedk, bd-dcvo3n, bd-bi5t54), and showing quota
  bars for a broken provider implies it's dispatchable when it isn't. Once
  dispatch is fixed, remove it from @hidden_providers and this comment.

  The upstream Gemini CLI (`gemini_cli`) used to be hidden here too
  (bd-5r6cdy); the provider itself is gone now (bd-ac53wz).

  Antigravity was hidden here too (bd-5r6cdy: quota was only checkable while the
  app was open, and its token staled ~1h after it closed). The `agy` CLI
  `/usage` probe (`Arbiter.Quota.CloudCode`) superseded that stored-token path,
  so it is shown again (bd-gukyy1); a reading `agy` couldn't refresh carries a
  `message` and renders muted as stale rather than as a current figure.

  ## `:loopback`

  Assigns `:loopback?` — whether the browser on the other end is on this box.
  It is the input to §10.4's one auth rule, and one surface needs it: the
  session dock, whose terminal rides a `/session` socket that trusts a loopback
  peer and nothing else (bd-2zskbb). Off loopback its window says so, and says
  how to get in (an SSH port-forward), rather than mounting a pane that
  silently never attaches.

  It has to be a *root* view's hook. `get_connect_info/2` is root-and-mount
  only, and `ArbiterWeb.SessionDockLive` is a nested, sticky child — so the
  dock is handed the answer through `live_render(..., session: ...)` in
  `layouts/live.html.heex` rather than reading it itself.

  ## `:coordinator_inbox`

  Lifted off `BoardLive` (bd-3kgb0e) so the coordinator's mailbox — the
  upward channel of `arb inbox` / `arb msg` — surfaces from the AppShell
  drawer on every screen instead of only the board. Subscribes to every
  workspace's message topic and assigns `:coordinator_inbox` (unread) and
  `:coordinator_outstanding_count` (seen but not cleared) same as the old
  `BoardLive.refresh_coordinator_inbox/1`. Also owns the drawer's two
  actions (`coordinator_mark_read`, `coordinator_clear`) via a
  `:handle_event` hook, so no LiveView needs its own clauses for them —
  distinct event names from `WorkerDetailLive`'s own `"mark_read"` (a
  different, per-worker mailbox) avoid a collision.

  `:coordinator_inbox` is a `Phoenix.LiveView.AsyncResult` (bd-adewb4), loaded
  the same way as `:quotas` — the workspaces read and both mailbox reads run in
  `start_async/3` on the connected mount, the drawer says "loading" until they
  land and shows an inline error if they fail. The message topics are joined
  when the load returns; the re-reads a click or a broadcast trigger stay
  inline and write into the same `AsyncResult`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, start_async: 3]

  alias Arbiter.Messages.Message
  alias Phoenix.LiveView.AsyncResult

  require Logger

  # Providers hidden from the UI pending fix; see module docstring for
  # context. Derived from `Arbiter.Quota.hidden_providers/0` (bd-4p6pw7
  # round 2, finding 2) rather than duplicated by hand, so the two can't
  # drift apart.
  @hidden_providers Arbiter.Quota.hidden_providers()

  @coordinator_ref Message.coordinator_ref()

  # `start_async/3` keys. Namespaced: they share the host LiveView's async key
  # space, and the hooks below pass any other key on to it.
  @quotas_async :arbiter_live_hooks_quotas
  @coordinator_inbox_async :arbiter_live_hooks_coordinator_inbox

  # bd-8akewg: the drawer is the operator's own view, so it reads and clears as
  # the shared sessionless coordinator reader — the same identity `arb inbox`
  # and a plain minted token use. That reader's state is mirrored onto the
  # message row, so the drawer behaves exactly as it did before per-reader
  # state existed; what changed is that a browser *session's* polling no longer
  # empties it.
  @reader_opts [reader: Message.coordinator_reader()]

  def on_mount(:current_path, _params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, nil)
      |> attach_hook(:gt_current_path, :handle_params, fn _params, uri, socket ->
        {:cont, assign(socket, :current_path, URI.parse(uri).path)}
      end)

    {:cont, socket}
  end

  def on_mount(:live, _params, _session, socket) do
    {:cont, assign(socket, :live, connected?(socket))}
  end

  def on_mount(:loopback, _params, _session, socket) do
    loopback? =
      case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
        %{address: address} -> ArbiterWeb.Loopback.loopback?(address)
        # No `:peer_data` means no transport to ask — a dead render under
        # `Phoenix.ConnTest` with none put on the conn. Treating that as
        # loopback keeps the default the same one the dashboard runs under.
        _ -> true
      end

    {:cont, assign(socket, :loopback?, loopback?)}
  end

  def on_mount(:quota, _params, _session, socket) do
    socket = assign(socket, :quotas, AsyncResult.loading())

    socket =
      if connected?(socket) do
        socket
        |> attach_hook(:quota_async, :handle_async, &handle_quota_async/3)
        |> attach_hook(:quota_events, :handle_event, &handle_quota_event/3)
        |> start_async(@quotas_async, &load_quotas_in_task/0)
      else
        socket
      end

    {:cont, socket}
  end

  def on_mount(:coordinator_inbox, _params, _session, socket) do
    socket =
      socket
      |> assign(:coordinator_inbox_now, DateTime.utc_now())
      |> assign(:coordinator_inbox, AsyncResult.loading())
      |> assign(:coordinator_outstanding_count, 0)
      |> maybe_load_coordinator_inbox()
      |> maybe_tick_coordinator_inbox_now()
      |> attach_hook(:coordinator_inbox_events, :handle_event, fn
        "coordinator_mark_read", %{"id" => id}, socket ->
          with {:ok, msg} <- Ash.get(Message, id),
               {:ok, _} <- Message.mark_read(msg, @reader_opts) do
            {:halt, refresh_coordinator_inbox(socket)}
          else
            _ -> {:halt, refresh_coordinator_inbox(socket)}
          end

        "coordinator_clear", _params, socket ->
          _ = Message.clear_read(@coordinator_ref, @reader_opts)
          {:halt, refresh_coordinator_inbox(socket)}

        "coordinator_retry", _params, socket ->
          {:halt, retry_coordinator_inbox(socket)}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end

  @doc """
  The top bar's quota load: the default workspace's id and its decorated,
  hidden-provider-filtered quota list, via `QuotaCache`. `{:ok, nil, []}` when
  there is no default workspace to read.

  `:exclude_providers` drops a hidden provider's view before it's decorated
  with spend (bd-4p6pw7), rather than filtering the fully decorated list after
  the fact.

  The whole decorated result is memoized by `QuotaCache` (bd-4p6pw7 round 2,
  finding 1): `list_latest_for_workspace/2` still reads a `Workspace`, its
  provider accounts and their workspace links even with `SpendCache` covering
  the ledger scans, so an uncached load is still 18-20 queries. `QuotaCache` is
  only used here — the direct callers (`GET /api/quota`, `arb quota`) read
  immediately after a write in their own tests and stay uncached so that holds.
  """
  @spec load_quotas() :: {:ok, String.t() | nil, [map()]}
  def load_quotas do
    case Arbiter.Quota.default_workspace_id() do
      {:ok, ws_id} ->
        opts = [exclude_providers: @hidden_providers]

        quotas =
          Arbiter.Quota.QuotaCache.fetch(ws_id, opts, fn ->
            Arbiter.Quota.list_latest_for_workspace(ws_id, opts)
          end)

        {:ok, ws_id, quotas}

      _ ->
        {:ok, nil, []}
    end
  end

  # bd-adewb4: the quota load runs on every page, so it may not hold up the
  # mount. The quota topic is joined once the load names the workspace — a
  # capture between the task's read and the subscribe is picked up by the next
  # one, the same window the synchronous read-then-subscribe always had.
  defp handle_quota_async(@quotas_async, {:ok, {:ok, ws_id, quotas}}, socket) do
    socket =
      if ws_id && is_nil(socket.assigns[:_quota_workspace_id]),
        do: subscribe_quota(socket, ws_id),
        else: socket

    {:halt,
     socket
     |> assign(:quotas, AsyncResult.ok(socket.assigns.quotas, quotas))
     |> assign(:_quota_workspace_id, ws_id)}
  end

  # Said inline in the top bar rather than as a crash: the chrome is on every
  # page, and a page whose quota can't be read is still a page.
  defp handle_quota_async(@quotas_async, {:exit, reason}, socket) do
    Logger.error("LiveHooks: loading the quota bars failed: #{inspect(reason)}")
    {:halt, assign(socket, :quotas, AsyncResult.failed(socket.assigns.quotas, {:exit, reason}))}
  end

  defp handle_quota_async(_key, _result, socket), do: {:cont, socket}

  # The top bar's error notice is the retry button.
  defp handle_quota_event("quota_retry", _params, socket) do
    if socket.assigns.quotas.failed do
      {:halt,
       socket
       |> assign(:quotas, AsyncResult.loading(socket.assigns.quotas))
       |> start_async(@quotas_async, &load_quotas_in_task/0)}
    else
      {:halt, socket}
    end
  end

  defp handle_quota_event(_event, _params, socket), do: {:cont, socket}

  defp maybe_load_coordinator_inbox(socket) do
    if connected?(socket) do
      socket
      |> attach_hook(:coordinator_inbox_async, :handle_async, &handle_coordinator_inbox_async/3)
      |> start_async(@coordinator_inbox_async, &load_coordinator_inbox_in_task/0)
    else
      socket
    end
  end

  # The drawer's Retry. Before the topics are joined (the mount's load failed)
  # it is that load again; after, the inline re-read a broadcast would do.
  defp retry_coordinator_inbox(socket) do
    cond do
      socket.assigns.coordinator_inbox.loading ->
        socket

      socket.assigns[:_coordinator_inbox_subscribed?] ->
        refresh_coordinator_inbox(socket)

      true ->
        socket
        |> assign(:coordinator_inbox, AsyncResult.loading(socket.assigns.coordinator_inbox))
        |> start_async(@coordinator_inbox_async, &load_coordinator_inbox_in_task/0)
    end
  end

  # The mailbox topics are joined once the load has named the workspaces. A
  # click (mark read / clear) may already have re-read the mailbox inline while
  # this was out: that read is the newer one, so it stands.
  defp handle_coordinator_inbox_async(
         @coordinator_inbox_async,
         {:ok, {workspace_ids, inbox, outstanding}},
         socket
       ) do
    socket = subscribe_coordinator_inbox(socket, workspace_ids)

    if socket.assigns.coordinator_inbox.ok?,
      do: {:halt, socket},
      else: {:halt, put_coordinator_inbox(socket, inbox, outstanding)}
  end

  defp handle_coordinator_inbox_async(@coordinator_inbox_async, {:exit, reason}, socket) do
    Logger.error("LiveHooks: loading the coordinator mailbox failed: #{inspect(reason)}")

    if socket.assigns.coordinator_inbox.ok?,
      do: {:halt, socket},
      else: {:halt, fail_coordinator_inbox(socket, {:exit, reason})}
  end

  defp handle_coordinator_inbox_async(_key, _result, socket), do: {:cont, socket}

  # The tasks are linked to the view, so a tab closed mid-read would kill one
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection (under test, the one shared sandbox connection,
  # bd-5scl0c). Trapping turns the view's exit into a message: the query in
  # flight finishes, and the task goes before it starts another (bd-6mfl0s).
  defp load_quotas_in_task do
    Process.flag(:trap_exit, true)
    result = load_quotas()
    exit_if_view_gone()
    result
  end

  defp load_coordinator_inbox_in_task do
    Process.flag(:trap_exit, true)

    workspace_ids =
      try do
        Arbiter.Tasks.Workspace |> Ash.read!() |> Enum.map(& &1.id)
      rescue
        _ -> []
      end

    exit_if_view_gone()
    {inbox, outstanding} = read_coordinator_inbox()
    exit_if_view_gone()
    {workspace_ids, inbox, outstanding}
  end

  defp exit_if_view_gone do
    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> :ok
    end
  end

  # Independent of any host LiveView's own :tick — the drawer is global chrome,
  # so its "N ago" timestamps need to advance even on pages with no clock of
  # their own. A per-minute cadence is plenty for coarse relative labels.
  defp maybe_tick_coordinator_inbox_now(socket) do
    if connected?(socket) do
      :timer.send_interval(60_000, self(), :coordinator_inbox_tick)

      attach_hook(socket, :coordinator_inbox_tick, :handle_info, fn
        :coordinator_inbox_tick, socket ->
          {:halt, assign(socket, :coordinator_inbox_now, DateTime.utc_now())}

        _msg, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp subscribe_coordinator_inbox(
         %{assigns: %{_coordinator_inbox_subscribed?: true}} = socket,
         _
       ),
       do: socket

  defp subscribe_coordinator_inbox(socket, workspace_ids) do
    for ws_id <- workspace_ids,
        do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Message.topic(ws_id))

    socket
    |> assign(:_coordinator_inbox_subscribed?, true)
    |> attach_hook(:coordinator_inbox_updates, :handle_info, fn
      {:new_message, _message}, socket -> {:cont, refresh_coordinator_inbox(socket)}
      {:message_read, _message}, socket -> {:cont, refresh_coordinator_inbox(socket)}
      {:mailbox_cleared, _workspace_id}, socket -> {:cont, refresh_coordinator_inbox(socket)}
      _msg, socket -> {:cont, socket}
    end)
  end

  # Two figures, not one: pending (unread — never seen) and outstanding (seen
  # but not cleared — still owes an action). Reading no longer empties the
  # queue, so "still open" needs its own number.
  #
  # The inline re-read after a click or a mailbox broadcast. It only runs once
  # the mount's async load has subscribed (or on a click), so it lands on an
  # `AsyncResult` either way; a read that raises says so in the drawer rather
  # than showing an empty inbox that isn't.
  defp refresh_coordinator_inbox(socket) do
    {inbox, outstanding} = read_coordinator_inbox()
    put_coordinator_inbox(socket, inbox, outstanding)
  rescue
    error -> fail_coordinator_inbox(socket, {:error, error})
  end

  defp read_coordinator_inbox do
    {Message.inbox(@coordinator_ref, @reader_opts),
     Message.outstanding(@coordinator_ref, @reader_opts)}
  end

  defp put_coordinator_inbox(socket, inbox, outstanding) do
    socket
    |> assign(:coordinator_inbox, AsyncResult.ok(socket.assigns.coordinator_inbox, inbox))
    |> assign(:coordinator_outstanding_count, length(outstanding))
  end

  defp fail_coordinator_inbox(socket, reason) do
    assign(
      socket,
      :coordinator_inbox,
      AsyncResult.failed(socket.assigns.coordinator_inbox, reason)
    )
  end

  defp subscribe_quota(socket, workspace_id) do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:#{workspace_id}")

    attach_hook(socket, :quota_updates, :handle_info, fn msg, socket ->
      case msg do
        {:quota_updated, ^workspace_id, quota} ->
          {:halt, merge_quota_update(socket, quota)}

        _ ->
          {:cont, socket}
      end
    end)
  end

  # A broadcast merges into the loaded list, kept as the `AsyncResult` it
  # arrived in. Skip updates for hidden providers to prevent re-introduction
  # via PubSub. The topic is only joined once the load succeeded, so the
  # result is always a list here.
  defp merge_quota_update(socket, quota) do
    %AsyncResult{result: quotas} = async = socket.assigns.quotas

    if quota.provider in @hidden_providers or not is_list(quotas) do
      socket
    else
      assign(socket, :quotas, AsyncResult.ok(async, upsert_quota(quotas, quota)))
    end
  end

  # Replace the list entry matching `quota.provider`, or append it when this
  # is the first snapshot seen for that provider.
  defp upsert_quota(quotas, quota) do
    if Enum.any?(quotas, &(&1.provider == quota.provider)) do
      Enum.map(quotas, fn
        %{provider: provider} = existing when provider == quota.provider ->
          preserve_cost(existing, quota)

        existing ->
          existing
      end)
    else
      quotas ++ [quota]
    end
  end

  # Live broadcast views don't carry `cost_usd` (it's a read-path add-on from the
  # usage ledger, not part of the per-provider fetch), so a naive replace would
  # blank the figure on every tick. Keep the last known cost when the incoming
  # update omits it (bd-ajh7bd). Same for `gate_policy` (bd-clzkvp), which
  # `list_latest_for_workspace/2` adds: without it the bars would fall back to
  # the install-default thresholds on the first tick.
  defp preserve_cost(existing, incoming) do
    incoming
    |> keep_existing(existing, :cost_usd)
    |> keep_existing(existing, :gate_policy)
  end

  defp keep_existing(incoming, existing, key) do
    case Map.get(incoming, key) do
      nil -> Map.put(incoming, key, Map.get(existing, key))
      _ -> incoming
    end
  end
end
