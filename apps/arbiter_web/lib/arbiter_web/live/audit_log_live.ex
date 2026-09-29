defmodule ArbiterWeb.AuditLogLive do
  @moduledoc """
  LiveView at `/audit` — a filtered/paged table of task state transitions
  sourced from `AshPaperTrail` versions on `Arbiter.Tasks.Issue`.

  ## Columns

  time / actor / subject / action / detail — `detail` renders a lifecycle
  `state` transition **verbatim**, e.g. `queued → active`, never humanized. Any
  other changed fields are shown as `key=value`, also verbatim — see
  `ArbiterWeb.CoreComponents.Data.status_chip/1`'s doc for the same rule
  applied elsewhere in this component library.

  ## Actor

  `Issue` has no `belongs_to_actor` (see `Arbiter.PaperTrail`'s moduledoc) —
  the only actor signal on an Issue version is the optional `change_origin`
  argument threaded through the `:update` action (`create`/`close`/`reopen`
  never set it), landing in `version_action_inputs["change_origin"]` via
  `store_action_inputs?(true)`. A version with no `change_origin` is shown
  as `"system"`.

  The **Human / Machine** tabs approximate a real actor-kind distinction
  from that one string: `"worker:<task_id>"`, `"loop:..."`, `"coordinator"`,
  and unattributed (`"system"`) writes are machine actors (every one of
  those is itself an AI agent session); `"cli"`, `"dashboard"`, or any other
  bare label is treated as human. This is a heuristic, not a first-class
  actor model — the moduledoc this replaces already punted actor filtering
  to "Phase 5" for the same reason (no actor resource to belong to).

  ## Query syntax

  The mono search box accepts space-separated `key:value` clauses —
  `subject:`, `actor:`, `action:` — ANDed together; a bare word without a
  `key:` prefix matches subject, actor, or action (substring, case
  insensitive).

  `subject:` is pushed into the `Ash.Query.filter/2` *before* the 500-row
  cap (see `read_events/1`), so a task's full history is reachable by id
  regardless of how much has been written since — the same guarantee the
  replaced implementation's `filter_by_entity_id/2` gave. `action:` pushes
  down too, but only when the value is one of the known action names
  (`create`/`update`/`close`/`reopen` — `version_action_name` is
  atom-typed, so only an exact match is safe to push as SQL); any other
  `action:` value, `actor:`, and bare-word clauses, plus the Human/Machine
  tab, only narrow within the already-bounded window (no `belongs_to_actor`,
  so there's no column to filter actor on server-side — see "Actor" above).
  Tab, query, and page are round-tripped through the URL (`?tab=&q=&page=`)
  via `handle_params/3` so the view is shareable and back-button safe, and
  so a deep link can seed a filter (see `subject_from_params/1`).

  Reads are bounded to the 500 most recent versions *matching the pushed
  filter* (same cap the prior implementation used). The raw read is cached
  in `:raw_events` and only re-run when the pushed-down filter changes —
  tab switches, in-memory query edits, and paging re-filter/re-slice the
  cached window instead of re-querying.

  ## Async load

  The bounded-but-unbounded-table read (`read_events/1`) runs via
  `start_async/3` on the connected mount and on every `handle_params/3` that
  changes the pushed-down filter — never inline in `mount/3` or the
  disconnected `handle_params/3` (bd-7or1v7). The dead render shows the
  loading skeleton and never touches the DB. Each such re-read (a search
  that changes `subject:`/`action:`) flips `events_loading?` back on and
  re-shows the skeleton in place of the stale rows, cancelling any read
  already in flight so a fast sequence of searches doesn't pile up
  concurrent queries. `raw_key` only advances to the filter being loaded
  once that read actually lands (`pending_key` holds it until then), so a
  tab/page patch racing an in-flight search re-slices the last *good*
  window instead of presenting it as a match for the new filter. A failed
  read shows an inline, retryable error instead of crashing the view; the
  last good page (if any) stays on screen underneath it.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Issue.Version
  alias ArbiterWeb.CoreComponents.{Core, Data, Feedback, Forms, Navigation}
  alias ArbiterWeb.Paging
  require Ash.Query
  require Logger

  @tabs [
    %{label: "All", value: "all"},
    %{label: "Human", value: "human"},
    %{label: "Machine", value: "machine"}
  ]

  # Identity colours only — deliberately excludes --arb-fail/--arb-attention
  # so an ordinary actor is never painted with a semantic error/warning tone.
  @actor_hues ~w(--arb-live --arb-info --arb-proposal)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:tabs, @tabs)
     |> assign(:raw_events, nil)
     |> assign(:raw_key, nil)
     |> assign(:pending_key, nil)
     |> assign(:events, [])
     |> assign(:page_info, Paging.paginate_list([], 1))
     |> assign(:events_loaded?, false)
     |> assign(:events_loading?, false)
     |> assign(:events_error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in ~w(all human machine), do: params["tab"], else: "all"
    query = params["q"] || subject_from_params(params) || ""
    page = Paging.parse_page(params)

    socket =
      socket
      |> assign(:tab, tab)
      |> assign(:query, query)
      |> assign(:page, page)

    socket = if connected?(socket), do: load_events(socket), else: socket

    {:noreply, socket}
  end

  # The task detail screen's Activity panel hands the subject over as
  # `?entity_id=`; translate it into the same `subject:` clause the search
  # box accepts so the deep link lands pre-filtered.
  defp subject_from_params(%{"entity_id" => eid}) when is_binary(eid) and eid != "",
    do: "subject:#{eid}"

  defp subject_from_params(_params), do: nil

  @impl true
  def handle_event("filter-tab", %{"tab" => tab}, socket) do
    {:noreply, push_patch(socket, to: audit_path(tab, socket.assigns.query, 1))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: audit_path(socket.assigns.tab, q, 1))}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         audit_path(
           socket.assigns.tab,
           socket.assigns.query,
           Paging.parse_page(%{"page" => page})
         )
     )}
  end

  def handle_event("retry", _params, socket) do
    {:noreply, socket |> assign(:events_error, nil) |> start_raw_read(socket.assigns.pending_key)}
  end

  @impl true
  def handle_async(:raw_events, {:ok, raw_events}, socket) do
    {:noreply,
     socket
     |> assign(:raw_key, socket.assigns.pending_key)
     |> assign(:raw_events, raw_events)
     |> assign(:pending_key, nil)
     |> assign(:events_loading?, false)
     |> assign(:events_error, nil)
     |> apply_filters()}
  end

  def handle_async(:raw_events, {:exit, reason}, socket) do
    Logger.error("AuditLogLive: loading events failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:events_loading?, false)
     |> assign(:events_error, describe_exit(reason))}
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  defp audit_path(tab, query, page),
    do: ~p"/audit?#{[tab: tab, q: query, page: page]}"

  # ---- data ----

  # Only re-reads the database when the pushed-down (subject/action) portion
  # of the query changed — tab switches and in-memory-only query edits reuse
  # the cached window and re-filter/re-slice it synchronously.
  defp load_events(socket) do
    clauses = socket.assigns.query |> String.split() |> Enum.map(&parse_clause/1)
    {sql_clauses, memory_clauses} = Enum.split_with(clauses, &pushable?/1)

    socket = assign(socket, :memory_clauses, memory_clauses)

    if socket.assigns.raw_key == sql_clauses and socket.assigns.raw_events do
      apply_filters(socket)
    else
      socket |> assign(:events_error, nil) |> start_raw_read(sql_clauses)
    end
  end

  # `raw_key` only moves to the filter being loaded once that read lands
  # (`handle_async/3`'s `{:ok, _}` clause) — until then it stays pointed at
  # whatever filter's rows are actually cached in `raw_events`, so a tab or
  # page patch that arrives before the read finishes keeps re-slicing the
  # last *good* window instead of presenting it as a match for the new one.
  defp start_raw_read(socket, sql_clauses) do
    socket
    |> cancel_async(:raw_events, :cancel)
    |> assign(:pending_key, sql_clauses)
    |> assign(:events_loading?, true)
    |> start_async(:raw_events, fn -> run_raw_read(sql_clauses) end)
  end

  # The task is linked to this view, so a tab closed mid-read would kill it
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection (under test, the one shared sandbox connection,
  # bd-5scl0c). Trapping turns the view's exit into a message: the query in
  # flight finishes, and the task goes before it starts another.
  defp run_raw_read(sql_clauses) do
    Process.flag(:trap_exit, true)
    result = __MODULE__.read_events(sql_clauses)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  defp apply_filters(socket) do
    rows =
      socket.assigns.raw_events
      |> filter_by_tab(socket.assigns.tab)
      |> filter_by_clauses(socket.assigns.memory_clauses)

    page = Paging.paginate_list(rows, socket.assigns.page)

    socket
    |> assign(:events, page.entries)
    |> assign(:page_info, page)
    |> assign(:events_loaded?, true)
  end

  @known_actions ~w(create update close reopen)

  # subject: always pushes down. action: only pushes down for an exact,
  # known action name — version_action_name is atom-typed, so anything else
  # (a partial word) has to stay an in-memory substring match.
  defp pushable?({:subject, _v}), do: true
  defp pushable?({:action, v}), do: v in @known_actions
  defp pushable?(_clause), do: false

  @doc false
  def read_events(sql_clauses) do
    Version
    |> Ash.Query.new()
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> push_sql_clauses(sql_clauses)
    |> Ash.Query.limit(500)
    |> Ash.read!()
    |> Enum.sort_by(& &1.version_inserted_at, {:asc, DateTime})
    |> annotate_transitions()
    |> Enum.reverse()
  end

  defp push_sql_clauses(query, clauses), do: Enum.reduce(clauses, query, &push_sql_clause/2)

  defp push_sql_clause({:subject, v}, query),
    do: Ash.Query.filter(query, like(version_source_id, ^"%#{v}%"))

  defp push_sql_clause({:action, v}, query),
    do: Ash.Query.filter(query, version_action_name == ^String.to_existing_atom(v))

  # Walk chronologically so a state change can show what it changed *from*,
  # not just what it changed to — `changes` (AshPaperTrail's changes_only
  # mode) only ever carries the new value.
  defp annotate_transitions(versions) do
    {rows, _last_state_by_subject} =
      Enum.map_reduce(versions, %{}, fn v, last_state ->
        subject = v.version_source_id
        changes = v.changes || %{}
        new_state = Map.get(changes, "state")

        transition = new_state && {Map.get(last_state, subject), new_state}

        last_state =
          if new_state, do: Map.put(last_state, subject, new_state), else: last_state

        row = %{
          id: v.id,
          at: v.version_inserted_at,
          actor: actor_of(v),
          subject: subject,
          action: v.version_action_name,
          transition: transition,
          changes: Map.delete(changes, "state")
        }

        {row, last_state}
      end)

    rows
  end

  defp actor_of(%{version_action_inputs: %{"change_origin" => origin}})
       when is_binary(origin) and origin != "",
       do: origin

  defp actor_of(_version), do: "system"

  defp actor_kind("system"), do: "machine"

  defp actor_kind(actor) do
    cond do
      String.starts_with?(actor, "worker:") -> "machine"
      String.starts_with?(actor, "loop:") -> "machine"
      actor == "coordinator" -> "machine"
      true -> "human"
    end
  end

  defp actor_hue(actor) do
    Enum.at(@actor_hues, :erlang.phash2(actor, length(@actor_hues)))
  end

  defp filter_by_tab(rows, "all"), do: rows
  defp filter_by_tab(rows, tab), do: Enum.filter(rows, &(actor_kind(&1.actor) == tab))

  defp filter_by_clauses(rows, []), do: rows

  defp filter_by_clauses(rows, clauses) do
    Enum.filter(rows, fn row -> Enum.all?(clauses, &matches_clause?(row, &1)) end)
  end

  defp parse_clause("subject:" <> v), do: {:subject, v}
  defp parse_clause("actor:" <> v), do: {:actor, v}
  defp parse_clause("action:" <> v), do: {:action, v}
  defp parse_clause(v), do: {:any, v}

  defp matches_clause?(row, {:subject, v}), do: contains?(row.subject, v)
  defp matches_clause?(row, {:actor, v}), do: contains?(row.actor, v)
  defp matches_clause?(row, {:action, v}), do: contains?(to_string(row.action), v)

  defp matches_clause?(row, {:any, v}) do
    contains?(row.subject, v) or contains?(row.actor, v) or contains?(to_string(row.action), v)
  end

  defp contains?(str, sub), do: String.contains?(String.downcase(str), String.downcase(sub))

  defp detail_text(%{transition: {old, new}}) when not is_nil(new) do
    if old, do: "#{old} → #{new}", else: new
  end

  defp detail_text(%{changes: changes}) do
    Enum.map_join(changes, ", ", fn {k, v} -> "#{k}=#{verbatim(v)}" end)
  end

  defp verbatim(v) when is_binary(v), do: v
  defp verbatim(v), do: inspect(v)

  # ---- render ----

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6" id="audit-log">
        <div>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
            <Core.icon name="hero-clock" size={24} class="text-base-content/70" /> Audit log
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            {@page_info.total_count} matching events (of the 500 most recent), sourced from
            <code class="text-xs">ash_paper_trail</code>
            versions on <code class="text-xs">Arbiter.Tasks.Issue</code>.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <Navigation.filter_tabs
            tabs={@tabs}
            active={@tab}
            tab_path={&audit_path(&1, @query, 1)}
          />
          <form phx-change="search" class="flex-1 min-w-0 sm:min-w-[240px]">
            <Forms.input
              type="text"
              name="q"
              id="audit-query"
              value={@query}
              placeholder="subject:bd-3o8mq1"
              phx-debounce="300"
              mono
            />
          </form>
        </div>

        <div
          :if={@events_error}
          id="audit-error"
          role="alert"
          class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
        >
          <Core.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
          <span class="grow min-w-0 break-words">
            Could not load audit events: {@events_error}<span :if={@events_loaded?}>
              — showing the last page that loaded.</span>
          </span>
          <button
            type="button"
            id="audit-retry"
            phx-click="retry"
            class={[
              "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
              "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
              "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
            ]}
          >
            Retry
          </button>
        </div>

        <div
          :if={(not @events_loaded? or @events_loading?) and is_nil(@events_error)}
          id="audit-loading"
          aria-label="Loading audit events"
          aria-busy="true"
          class="flex flex-col gap-1.5"
        >
          <div
            :for={n <- 1..5}
            id={"audit-loading-#{n}"}
            aria-hidden="true"
            class="h-[34px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
          >
          </div>
        </div>

        <Feedback.empty_state
          :if={@events_loaded? and not @events_loading? and @events == []}
          icon="hero-inbox"
          detail="No matching audit events."
        >
          Nothing here
        </Feedback.empty_state>

        <Data.data_table
          :if={@events_loaded? and not @events_loading? and @events != []}
          id="audit-table"
          rows={@events}
          min_width="760px"
        >
          <:col :let={row} label="Time" width="150px">
            <span class="text-xs text-base-content/60 font-mono tabular-nums whitespace-nowrap">
              {Calendar.strftime(row.at, "%Y-%m-%d %H:%M:%S")}
            </span>
          </:col>
          <:col :let={row} label="Actor" width="110px">
            <span class="font-mono text-xs" style={"color: var(#{actor_hue(row.actor)});"}>
              {row.actor}
            </span>
          </:col>
          <:col :let={row} label="Subject" width="minmax(100px, 1fr)">
            <code class="text-xs">{row.subject}</code>
          </:col>
          <:col :let={row} label="Action" width="140px">
            <span class="font-mono text-xs">{row.action}</span>
          </:col>
          <:col :let={row} label="Detail" width="minmax(220px, 1fr)" wrap>
            <span class="font-mono text-xs break-words">{detail_text(row)}</span>
          </:col>
        </Data.data_table>

        <Navigation.pager
          :if={@events_loaded? and not @events_loading? and @page_info.total_pages > 1}
          page={@page_info.page}
          total_pages={@page_info.total_pages}
          total_count={@page_info.total_count}
          page_path={&audit_path(@tab, @query, &1)}
        />
      </div>
    </Layouts.app>
    """
  end
end
