defmodule ArbiterWeb.ReviewIndexLive do
  @moduledoc """
  LiveView at `/reviews` — the one place review engagements and the
  external-review audit ledger appear (bd-4jllkg, bd-amtjxk, bd-crk6tb).

  Two sections share the workspace filter:

    * **Engagements** — the ReviewPatrol babysitting rows
      (`Issue.only_engagements/1`), hidden from every ticket list. Open ones
      are the table; closed ones are the historical record, collapsed. Each
      row shows the PR, `review_automation` mode, `review_count`,
      `last_reviewed_at`, its run count / latest run (the ledger joined via
      `Record.engagement_id`) and links to `/tasks/:id`.
    * **Run history** — the ledger below. Read-only visibility for `worker_review(pr:)` /
  `arb review --pr` runs, which are not task-linked and previously had no
  UI beyond the transient `/events?subscribe=external_review` stream.

  List + inline row expansion, same shape as `AuditLogLive`/`UsageLive`:
  filters and page round-trip through the URL (`?workspace_id=&status=&page=`),
  `ArbiterWeb.Paging` backs pagination.

  Live updates: subscribes to the global `Arbiter.Events` PubSub topic (which
  receives a copy of every workspace-scoped broadcast, `Events.broadcast/3`)
  and, on an `external_review` event, re-fetches the single record by id and
  replaces it in the currently-loaded page in place — no polling, no full
  reload. See `Arbiter.Reviews.ExternalReview`'s `broadcast_review_event/3`
  for the (deliberately partial) event payload shape.

  Expanding a row also loads that review's durable corpus (bd-7efini): the
  composed prompt it was given, the tool calls its reviewer made and what they
  returned, and the transcript itself — the same class of data a regular
  worker run's `worker_log` exposes. Loaded lazily on expand (one row at a
  time, dropped on collapse) rather than per row on render, since each read
  hits disk. See `Arbiter.Reviews.Transcript`.

  Greenlight-from-UI is out of scope for v1 per the design doc — this is a
  read-only view.

  ## Async load

  The workspace list, the paginated record page, and a row's transcript all
  arrive via `start_async/3` on the connected mount / event only (bd-blnnu3):
  the dead render reads nothing and draws a loading state, and a failed read
  renders an inline, retryable error instead of crashing the view. A filter
  or page change while a record read is in flight marks it stale and gets
  exactly one more read once the current one lands (same coalescing as
  `RunIndexLive`/`TaskIndexLive`). Expanding a different row cancels any
  transcript read still in flight for the previous one.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Events
  alias Arbiter.Reviews.Record
  alias Arbiter.Reviews.Transcript
  alias Arbiter.Tasks.{Issue, Workspace}
  alias ArbiterWeb.CoreComponents.{Core, Data, Feedback, Forms, Navigation}
  alias ArbiterWeb.Paging
  require Ash.Query
  require Logger

  @statuses Record.statuses()
  @status_strings Enum.map(@statuses, &Atom.to_string/1)
  @status_options Enum.map(@statuses, &{Atom.to_string(&1), Atom.to_string(&1)})
  @open_engagement_limit 200
  @closed_engagement_limit 50

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)
    if live?, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Events.pubsub_topic(nil))

    socket =
      socket
      |> assign(:workspaces, [])
      |> assign(:workspace_names, %{})
      |> assign(:workspaces_loaded?, false)
      |> assign(:workspaces_error, nil)
      |> assign(:status_options, @status_options)
      |> assign(:expanded, nil)
      |> assign(:transcript, nil)
      |> assign(:transcript_loading?, false)
      |> assign(:transcript_error, nil)
      |> assign(:records, [])
      |> assign(:page_info, Paging.paginate_list([], 1))
      |> assign(:records_loaded?, false)
      |> assign(:records_loading?, false)
      |> assign(:records_stale?, false)
      |> assign(:records_error, nil)
      |> assign(:engagements, %{open: [], closed: [], runs: %{}})
      |> assign(:engagements_loaded?, false)
      |> assign(:engagements_error, nil)

    socket = if live?, do: fetch_workspaces(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    workspace_id = present(params["workspace_id"])
    status = if params["status"] in @status_strings, do: params["status"]
    page = Paging.parse_page(params)

    # Engagements depend on the workspace filter only, so status/page
    # patches don't re-read them.
    engagements_stale? =
      not socket.assigns.engagements_loaded? or
        Map.get(socket.assigns, :workspace_id) != workspace_id

    socket =
      socket
      |> assign(:workspace_id, workspace_id)
      |> assign(:status, status)
      |> assign(:page, page)

    # The dead render reads nothing and draws a loading state; the query
    # only runs once the socket is connected (bd-blnnu3).
    socket =
      if connected?(socket) do
        socket = fetch_records(socket)
        if engagements_stale?, do: fetch_engagements(socket), else: socket
      else
        socket
      end

    {:noreply, socket}
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(v), do: v

  @impl true
  def handle_event("filter", params, socket) do
    {:noreply,
     push_patch(socket,
       to: reviews_path(present(params["workspace_id"]), present(params["status"]), 1)
     )}
  end

  def handle_event("page", %{"page" => page}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         reviews_path(
           socket.assigns.workspace_id,
           socket.assigns.status,
           Paging.parse_page(%{"page" => page})
         )
     )}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    if socket.assigns.expanded == id do
      {:noreply,
       socket
       |> cancel_async(:transcript, :cancel)
       |> assign(:expanded, nil)
       |> assign(:transcript, nil)
       |> assign(:transcript_loading?, false)
       |> assign(:transcript_error, nil)}
    else
      {:noreply, start_transcript_load(socket, id)}
    end
  end

  def handle_event("retry_workspaces", _params, socket) do
    {:noreply, fetch_workspaces(socket)}
  end

  def handle_event("retry_records", _params, socket) do
    {:noreply, socket |> assign(:records_error, nil) |> fetch_records()}
  end

  def handle_event("retry_transcript", _params, socket) do
    {:noreply, start_transcript_load(socket, socket.assigns.expanded)}
  end

  @impl true
  def handle_info({:event, %{topic: "external_review", review_record_id: id}}, socket)
      when is_binary(id) do
    {:noreply, patch_record(socket, id)}
  end

  def handle_info({:event, _payload}, socket), do: {:noreply, socket}

  # Catch-all: `LiveHooks.on_mount(:coordinator_inbox)` subscribes every view
  # in this live_session to the per-workspace coordinator-mailbox topic and
  # `:cont`s messages like `{:new_message, _}` on to us, regardless of
  # whether this view cares about them.
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:workspaces, {:ok, workspaces}, socket) do
    {:noreply,
     socket
     |> assign(:workspaces, workspaces)
     |> assign(:workspace_names, Map.new(workspaces, &{&1.id, &1.name}))
     |> assign(:workspaces_loaded?, true)
     |> assign(:workspaces_error, nil)}
  end

  def handle_async(:workspaces, {:exit, reason}, socket) do
    Logger.error("ReviewIndexLive: loading workspaces failed: #{inspect(reason)}")
    {:noreply, assign(socket, :workspaces_error, describe_exit(reason))}
  end

  # A stale result belongs to a filter/page that's no longer current — a
  # newer request was already queued behind this one while it was in flight
  # (see `fetch_records/1`'s coalescing clause). Drop it and let
  # `records_read_done/1` fire the queued refetch against the current
  # assigns.
  def handle_async(:records, {:ok, _result}, %{assigns: %{records_stale?: true}} = socket) do
    records_read_done(socket)
  end

  def handle_async(:records, {:ok, result}, socket) do
    socket
    |> assign(:records, result.entries)
    |> assign(:page_info, result)
    |> assign(:records_loaded?, true)
    |> assign(:records_error, nil)
    |> records_read_done()
  end

  def handle_async(:records, {:exit, reason}, %{assigns: %{records_stale?: true}} = socket) do
    Logger.error(
      "ReviewIndexLive: loading records failed (superseded, retrying): #{inspect(reason)}"
    )

    records_read_done(socket)
  end

  # A read that fails must not take the page down. Whatever list is on
  # screen stays there — the skeleton on a first load, the last good read on
  # a refresh — under an error that says so.
  def handle_async(:records, {:exit, reason}, socket) do
    Logger.error("ReviewIndexLive: loading records failed: #{inspect(reason)}")

    socket
    |> assign(:records_error, describe_exit(reason))
    |> records_read_done()
  end

  def handle_async(:engagements, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:engagements, result)
     |> assign(:engagements_loaded?, true)
     |> assign(:engagements_error, nil)}
  end

  def handle_async(:engagements, {:exit, reason}, socket) do
    Logger.error("ReviewIndexLive: loading engagements failed: #{inspect(reason)}")
    {:noreply, assign(socket, :engagements_error, describe_exit(reason))}
  end

  def handle_async(:transcript, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:transcript, result)
     |> assign(:transcript_loading?, false)
     |> assign(:transcript_error, nil)}
  end

  def handle_async(:transcript, {:exit, reason}, socket) do
    Logger.error("ReviewIndexLive: loading transcript failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:transcript_loading?, false)
     |> assign(:transcript_error, describe_exit(reason))}
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  defp reviews_path(workspace_id, status, page),
    do: ~p"/reviews?#{[workspace_id: workspace_id, status: status, page: page]}"

  # ---- data ----

  defp fetch_workspaces(socket) do
    start_async(socket, :workspaces, &run_workspaces_load/0)
  end

  # The task is linked to this view, so a tab closed mid-read would kill it
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection. Trapping turns the view's exit into a message: the
  # query in flight finishes, and the task goes before it starts another.
  defp run_workspaces_load do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_workspaces()

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  @doc false
  def load_workspaces do
    Workspace
    |> Ash.Query.sort(name: :asc)
    |> Ash.read!()
  end

  # `start_async/3` under a name that is already running supersedes it, so a
  # burst of workspace-filter changes settles on the last one.
  defp fetch_engagements(socket) do
    workspace_id = socket.assigns.workspace_id
    start_async(socket, :engagements, fn -> run_engagements_load(workspace_id) end)
  end

  defp run_engagements_load(workspace_id) do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_engagements(workspace_id)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  @doc false
  def load_engagements(workspace_id) do
    base =
      Issue
      |> Issue.only_engagements()
      |> filter_workspace(workspace_id)
      |> Ash.Query.sort(last_reviewed_at: :desc_nils_last)

    open =
      base
      |> Ash.Query.filter(state != :closed)
      |> Ash.Query.limit(@open_engagement_limit)
      |> Ash.read!()

    closed =
      base
      |> Ash.Query.filter(state == :closed)
      |> Ash.Query.limit(@closed_engagement_limit)
      |> Ash.read!()

    %{open: open, closed: closed, runs: engagement_runs(Enum.map(open ++ closed, & &1.id))}
  end

  # The ledger joined to engagements via `Record.engagement_id`: run count and
  # latest start per engagement. Only the two columns needed are selected —
  # the row's `raw` payload would dominate the read.
  defp engagement_runs([]), do: %{}

  defp engagement_runs(ids) do
    Record
    |> Ash.Query.filter(engagement_id in ^ids)
    |> Ash.Query.select([:engagement_id, :started_at])
    |> Ash.read!()
    |> Enum.group_by(& &1.engagement_id)
    |> Map.new(fn {id, runs} ->
      {id,
       %{count: length(runs), latest: runs |> Enum.map(& &1.started_at) |> Enum.max(DateTime)}}
    end)
  end

  # A refresh requested while one is already in flight marks the page stale
  # and gets exactly one more read once the current one lands, so a burst of
  # filter/page patches costs two reads, not one each.
  defp fetch_records(%{assigns: %{records_loading?: true}} = socket),
    do: assign(socket, :records_stale?, true)

  defp fetch_records(socket) do
    workspace_id = socket.assigns.workspace_id
    status = socket.assigns.status
    page = socket.assigns.page

    socket
    |> assign(:records_loading?, true)
    |> assign(:records_stale?, false)
    |> start_async(:records, fn -> run_records_load(workspace_id, status, page) end)
  end

  defp records_read_done(socket) do
    socket = assign(socket, :records_loading?, false)
    {:noreply, if(socket.assigns.records_stale?, do: fetch_records(socket), else: socket)}
  end

  defp run_records_load(workspace_id, status, page) do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_records_page(workspace_id, status, page)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  @doc false
  def load_records_page(workspace_id, status, page) do
    query =
      Record
      |> filter_workspace(workspace_id)
      |> filter_status(status)
      |> Ash.Query.sort(started_at: :desc)

    Paging.paginate(query, page)
  end

  # Cap on rendered transcript events: an agentic review over a large PR runs
  # to thousands of JSONL lines, and the whole point of the durable file is
  # that the UI never has to be the complete record. The tail is what an
  # operator reads first (verdict, last tool calls); the full corpus stays on
  # disk and is reachable via `external_review_transcript` / the REST endpoint.
  @event_limit 300

  defp start_transcript_load(socket, id) do
    socket
    |> cancel_async(:transcript, :cancel)
    |> assign(:expanded, id)
    |> assign(:transcript, nil)
    |> assign(:transcript_loading?, true)
    |> assign(:transcript_error, nil)
    |> start_async(:transcript, fn -> run_transcript_load(id) end)
  end

  defp run_transcript_load(record_id) do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_transcript(record_id)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  # Read one review's corpus off disk. Never raises: a review that predates
  # capture, or whose file was reaped, renders as "no transcript captured"
  # rather than taking the page down.
  @doc false
  def load_transcript(record_id) do
    # One read + one decode pass for summary, events and tool uses alike: this
    # runs in a Task on every row expand, and the corpus it is decoding is
    # thousands of JSONL lines.
    corpus = Transcript.corpus(record_id)
    all_events = corpus.events
    shown = Enum.take(all_events, -@event_limit)

    %{
      record_id: record_id,
      summary: corpus.summary,
      prompt: transcript_prompt(record_id),
      tool_uses: corpus.tool_uses,
      events: shown,
      event_count: length(all_events),
      truncated: length(all_events) > length(shown)
    }
  rescue
    _ -> nil
  end

  defp transcript_prompt(record_id) do
    case Transcript.prompt(record_id) do
      {:ok, prompt} -> prompt
      {:error, _} -> nil
    end
  end

  defp filter_workspace(query, nil), do: query
  defp filter_workspace(query, ws), do: Ash.Query.filter(query, workspace_id == ^ws)

  defp filter_status(query, nil), do: query
  defp filter_status(query, status), do: Ash.Query.filter(query, status == ^status)

  # Replace a single record in the currently-loaded page in place, matching
  # the design doc's re-fetch-by-id approach (the broadcast payload only
  # carries a handful of fields — not enough to render every column). If the
  # record isn't part of the loaded page (e.g. a brand new running review on
  # page 1), a full `fetch_records/1` re-derives the correct page/total. A
  # record already on the page is patched in place even if its new status no
  # longer matches an active `?status=` filter — the operator is watching
  # this row transition, so leaving it visible is preferable to it vanishing
  # out from under them; it reappears filtered on the next navigation.
  # Swap the reloaded row in by id. A clause head rather than an inline
  # `if` inside the anonymous function: the `if` put this four blocks deep
  # for no gain in clarity.
  defp replace_record(records, id, record) do
    Enum.map(records, fn
      %{id: ^id} -> record
      other -> other
    end)
  end

  defp patch_record(socket, id) do
    case Ash.get(Record, id) do
      {:ok, record} ->
        if Enum.any?(socket.assigns.records, &(&1.id == id)) do
          assign(socket, :records, replace_record(socket.assigns.records, id, record))
        else
          fetch_records(socket)
        end

      _ ->
        socket
    end
  rescue
    _ -> socket
  end

  # ---- formatting ----

  defp workspace_name(_names, nil), do: "—"
  defp workspace_name(names, id), do: Map.get(names, id, id)

  defp format_started(nil), do: "—"
  defp format_started(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp format_maybe(nil), do: "—"
  defp format_maybe(v), do: to_string(v)

  defp pr_label(%{pr_ref: pr_ref, pr: pr}), do: pr || pr_ref

  defp show_proposed_comments?(%{status: :completed_unposted}), do: true
  defp show_proposed_comments?(%{mode: :report_only, greenlight_status: :pending}), do: true
  defp show_proposed_comments?(_record), do: false

  defp comment_field(comment, key) when is_map(comment),
    do: Map.get(comment, key) || Map.get(comment, to_string(key))

  # ---- transcript formatting ----

  # The transcript assign belongs to whichever row is expanded; guard against
  # rendering a stale one after a live patch swapped the record out.
  defp transcript_for(%{record_id: id} = transcript, id), do: transcript
  defp transcript_for(_transcript, _id), do: nil

  defp event_label(%{kind: :system}), do: "init"
  defp event_label(%{kind: :assistant_text}), do: "assistant"
  defp event_label(%{kind: :tool_use}), do: "tool"
  defp event_label(%{kind: :tool_result}), do: "result"
  defp event_label(%{kind: :result}), do: "final"
  defp event_label(_event), do: "raw"

  defp event_text(%{kind: :system} = e),
    do: Enum.join(Enum.reject([e[:model], e[:session_id]], &is_nil/1), " · ")

  defp event_text(%{kind: :tool_use} = e), do: "#{e.name} #{compact_json(e.input)}"
  defp event_text(%{text: text}) when is_binary(text), do: truncate(text, 2_000)
  defp event_text(_event), do: ""

  defp compact_json(map) when map_size(map) == 0, do: ""

  defp compact_json(map) do
    case Jason.encode(map) do
      {:ok, json} -> truncate(json, 300)
      _ -> inspect(map)
    end
  end

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  defp truncate(text, _limit), do: text

  # ---- render ----

  # The durable corpus of one review (bd-7efini): what the reviewer was told,
  # which tools it reached for and what came back, and the transcript itself.
  attr :transcript, :map, default: nil

  defp review_transcript(assigns) do
    ~H"""
    <div :if={@transcript} class="flex flex-col gap-3 border-t border-[var(--border-default)] pt-3">
      <div :if={!@transcript.summary.exists && !@transcript.summary.prompt_exists}>
        <p class="text-[11.5px] text-base-content/60">
          No transcript captured for this review — it ran before durable review
          capture existed, or its reviewer produced no output.
        </p>
      </div>

      <details :if={@transcript.prompt} class="text-[11.5px]">
        <summary class="cursor-pointer font-medium text-[var(--text-label)]">
          Prompt ({byte_size(@transcript.prompt)} bytes)
        </summary>
        <pre class="mt-1 max-h-72 overflow-auto whitespace-pre-wrap break-words font-[family-name:var(--font-mono)] text-[11px] leading-relaxed bg-base-200/40 rounded-[var(--radius-field)] p-2">{@transcript.prompt}</pre>
      </details>

      <div :if={@transcript.tool_uses != []} class="flex flex-col gap-1">
        <p class="text-[11.5px] font-medium text-[var(--text-label)]">
          Tools used ({@transcript.summary.tool_use_count})
        </p>
        <div class="flex flex-wrap gap-1">
          <span
            :for={tool <- @transcript.summary.tools_used}
            class="badge badge-ghost text-[10px] font-[family-name:var(--font-mono)]"
          >
            {tool.name} ×{tool.count}
          </span>
        </div>
        <details class="text-[11.5px]">
          <summary class="cursor-pointer text-[var(--text-label)]">Calls and results</summary>
          <div class="mt-1 flex flex-col gap-1 max-h-72 overflow-auto">
            <div
              :for={tool <- @transcript.tool_uses}
              class="border-l-2 border-[var(--border-default)] pl-2"
            >
              <span class="font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                {tool.name}
              </span>
              <span class="font-[family-name:var(--font-mono)] text-[11px] break-all">
                {compact_json(tool.input)}
              </span>
              <p
                :if={tool.result}
                class="mt-0.5 text-base-content/70 whitespace-pre-wrap break-words font-[family-name:var(--font-mono)] text-[11px]"
              >
                {truncate(tool.result, 600)}
              </p>
            </div>
          </div>
        </details>
      </div>

      <details :if={@transcript.summary.exists} class="text-[11.5px]">
        <summary class="cursor-pointer font-medium text-[var(--text-label)]">
          Transcript ({@transcript.summary.line_count} lines{if @transcript.truncated,
            do: ", showing the last #{length(@transcript.events)} events",
            else: ""})
        </summary>
        <div class="mt-1 max-h-96 overflow-auto flex flex-col gap-0.5 bg-base-200/40 rounded-[var(--radius-field)] p-2">
          <div :for={event <- @transcript.events} class="flex gap-2 items-start">
            <span class="shrink-0 w-14 text-[10px] uppercase tracking-wide text-base-content/50 font-[family-name:var(--font-mono)]">
              {event_label(event)}
            </span>
            <span class="whitespace-pre-wrap break-words font-[family-name:var(--font-mono)] text-[11px] leading-relaxed">
              {event_text(event)}
            </span>
          </div>
        </div>
        <p class="mt-1 text-[10px] text-base-content/50 break-all">
          {@transcript.summary.path}
        </p>
      </details>
    </div>
    """
  end

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
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6" id="reviews">
        <div>
          <h1 class="text-2xl font-bold tracking-tight flex items-center gap-2">
            <Core.icon name="hero-magnifying-glass" size={24} class="text-base-content/70" /> Reviews
          </h1>
          <p class="text-sm text-base-content/60 mt-1">
            External reviews (<code class="text-xs">worker_review(pr:)</code> / <code class="text-xs">arb review --pr</code>), sourced from the
            <code class="text-xs">Arbiter.Reviews.Record</code>
            audit ledger.
          </p>
        </div>

        <form phx-change="filter" class="flex flex-wrap items-center gap-3">
          <Forms.select
            name="workspace_id"
            id="reviews-workspace-filter"
            value={@workspace_id}
            prompt="All workspaces"
            options={Enum.map(@workspaces, &{&1.name, &1.id})}
            size="sm"
          />
          <Forms.select
            name="status"
            id="reviews-status-filter"
            value={@status}
            prompt="All statuses"
            options={@status_options}
            size="sm"
          />
        </form>

        <div
          :if={@workspaces_error}
          id="reviews-workspaces-error"
          role="alert"
          class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
        >
          <Core.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
          <span class="grow min-w-0 break-words">
            Could not load workspaces: {@workspaces_error}
          </span>
          <button
            type="button"
            id="reviews-workspaces-retry"
            phx-click="retry_workspaces"
            class={[
              "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
              "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
              "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
            ]}
          >
            Retry
          </button>
        </div>

        <section id="engagements" class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-[0.06em] text-base-content/70">
            Engagements
          </h2>

          <div
            :if={@engagements_error}
            id="engagements-error"
            role="alert"
            class="px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
          >
            Could not load engagements: {@engagements_error}
          </div>

          <div
            :if={not @engagements_loaded? and is_nil(@engagements_error)}
            id="engagements-loading"
            aria-label="Loading engagements"
            class="h-[34px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
          >
          </div>

          <div :if={@engagements_loaded? and @engagements.open == []} id="engagements-empty">
            <Feedback.empty_state icon="hero-inbox" detail="No open review engagements.">
              Nothing here
            </Feedback.empty_state>
          </div>

          <div
            :if={@engagements.open != []}
            id="engagements-table"
            class="w-full overflow-x-auto"
            role="table"
          >
            <.engagement_header />
            <.engagement_row
              :for={eng <- @engagements.open}
              engagement={eng}
              run={@engagements.runs[eng.id]}
            />
          </div>

          <details :if={@engagements.closed != []} id="closed-engagements" class="w-full">
            <summary class="cursor-pointer text-[12px] text-base-content/60">
              Closed engagements ({length(@engagements.closed)})
            </summary>
            <div class="w-full overflow-x-auto mt-2" role="table">
              <.engagement_header />
              <.engagement_row
                :for={eng <- @engagements.closed}
                engagement={eng}
                run={@engagements.runs[eng.id]}
              />
            </div>
          </details>
        </section>

        <h2 class="text-sm font-semibold uppercase tracking-[0.06em] text-base-content/70">
          Run history
        </h2>

        <div
          id="reviews-panel"
          data-state={records_state(@records_loaded?, @records_error)}
          aria-busy={to_string(not @records_loaded? and is_nil(@records_error))}
        >
          <div
            :if={@records_error}
            id="reviews-error"
            role="alert"
            class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
          >
            <Core.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
            <span class="grow min-w-0 break-words">
              Could not load reviews: {@records_error}<span :if={@records_loaded?}> — showing the last page that loaded.</span>
            </span>
            <button
              type="button"
              id="reviews-retry"
              phx-click="retry_records"
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
            :if={not @records_loaded? and is_nil(@records_error)}
            id="reviews-loading"
            aria-label="Loading reviews"
            class="flex flex-col gap-2"
          >
            <div
              :for={n <- 1..5}
              id={"reviews-loading-#{n}"}
              aria-hidden="true"
              class="h-[34px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
            >
            </div>
          </div>

          <Feedback.empty_state
            :if={@records_loaded? and @records == []}
            icon="hero-inbox"
            detail="No external reviews match these filters."
          >
            Nothing here
          </Feedback.empty_state>

          <div
            :if={@records_loaded? and @records != []}
            id="reviews-table"
            class="w-full overflow-x-auto"
            role="table"
          >
            <div
              class="grid items-center gap-3 h-[30px] px-[14px] bg-[var(--arb-chrome)]"
              style="grid-template-columns: 150px minmax(120px,1fr) 140px 90px 130px 90px 120px 80px 90px;"
              role="row"
            >
              <span
                :for={label <- ~w(Started PR Workspace Strategy Status Mode Verdict Findings Cost)}
                class="text-[10.5px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
                role="columnheader"
              >
                {label}
              </span>
            </div>

            <div :for={record <- @records} class="flex flex-col">
              <div
                class="grid items-center gap-3 min-h-[34px] px-[14px] border-b border-[var(--arb-line-soft)] hover:bg-[var(--arb-raised-hover)] cursor-pointer"
                style="grid-template-columns: 150px minmax(120px,1fr) 140px 90px 130px 90px 120px 80px 90px;"
                role="row"
                id={"review-row-#{record.id}"}
                phx-click="toggle"
                phx-value-id={record.id}
              >
                <span
                  role="cell"
                  class="text-[11.5px] font-[family-name:var(--font-mono)] tabular-nums text-[var(--text-body)]"
                >
                  {format_started(record.started_at)}
                </span>
                <span role="cell" class="text-[11.5px] truncate">
                  <a
                    :if={record.link}
                    href={record.link}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="hover:underline"
                    onclick="event.stopPropagation()"
                  >
                    {pr_label(record)}
                  </a>
                  <span :if={!record.link}>{pr_label(record)}</span>
                </span>
                <span role="cell" class="text-[11.5px] truncate">
                  {workspace_name(@workspace_names, record.workspace_id)}
                </span>
                <span role="cell" class="badge badge-ghost text-[10.5px]">
                  {format_maybe(record.strategy)}
                </span>
                <span role="cell"><Data.status_chip status={record.status} /></span>
                <span role="cell" class="text-[11.5px]">{format_maybe(record.mode)}</span>
                <span role="cell" class="text-[11.5px]">{format_maybe(record.verdict)}</span>
                <span
                  role="cell"
                  class="text-[11.5px] font-[family-name:var(--font-mono)] tabular-nums"
                >
                  {format_maybe(record.finding_count)}
                </span>
                <span
                  role="cell"
                  class="text-[11.5px] font-[family-name:var(--font-mono)] tabular-nums"
                >
                  {Data.format_usd(record.cost_usd)}
                </span>
              </div>

              <div
                :if={@expanded == record.id}
                class="mt-1 mb-2 border border-[var(--border-default)] rounded-[var(--radius-field)] p-3 flex flex-col gap-3"
                id={"review-detail-#{record.id}"}
              >
                <Data.data_list>
                  <:item label="Findings summary">
                    <.markdown
                      :if={record.findings_summary not in [nil, ""]}
                      id={"review-findings-md-#{record.id}"}
                      text={record.findings_summary}
                      class="markdown-body--compact"
                    />
                    <span :if={record.findings_summary in [nil, ""]}>—</span>
                  </:item>
                  <:item label="Model">{format_maybe(record.model)}</:item>
                  <:item label="Tokens in / out">
                    {format_maybe(record.tokens_in)} / {format_maybe(record.tokens_out)}
                  </:item>
                  <:item label="Dispatched by">{format_maybe(record.dispatched_by)}</:item>
                  <:item label="PR">{format_maybe(record.pr)} ({format_maybe(record.pr_ref)})</:item>
                </Data.data_list>

                <div :if={record.engagement_id} class="flex items-center gap-1">
                  <.link
                    navigate={~p"/tasks/#{record.engagement_id}"}
                    class="text-[11.5px] hover:underline text-[var(--text-label)]"
                  >
                    linked engagement: {record.engagement_id} →
                  </.link>
                  <Core.copy_id
                    id={record.engagement_id}
                    dom_id={"copy-id-review-#{record.id}"}
                  />
                </div>

                <div :if={record.status == :failed} class="text-[11.5px]">
                  <p class="font-medium text-[var(--arb-fail-text)]">
                    Failed at {format_maybe(record.failure_stage)}
                  </p>
                  <p class="text-base-content/70">{record.failure_reason || "no reason recorded"}</p>
                </div>

                <div
                  :if={@transcript_loading?}
                  id={"review-transcript-loading-#{record.id}"}
                  aria-hidden="true"
                  aria-label="Loading transcript"
                  class="h-16 rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
                >
                </div>

                <div
                  :if={@transcript_error}
                  id={"review-transcript-error-#{record.id}"}
                  role="alert"
                  class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
                >
                  <Core.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
                  <span class="grow min-w-0 break-words">
                    Could not load transcript: {@transcript_error}
                  </span>
                  <button
                    type="button"
                    id={"review-transcript-retry-#{record.id}"}
                    phx-click="retry_transcript"
                    class={[
                      "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
                      "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
                      "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
                    ]}
                  >
                    Retry
                  </button>
                </div>

                <.review_transcript transcript={transcript_for(@transcript, record.id)} />

                <div :if={show_proposed_comments?(record)} class="flex flex-col gap-2">
                  <p class="text-[11.5px] font-medium text-[var(--text-label)]">
                    Proposed comments ({length(record.proposed_comments)})
                  </p>
                  <div
                    :for={comment <- record.proposed_comments}
                    class="text-[11.5px] border-l-2 border-[var(--border-default)] pl-2"
                  >
                    <span class="font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                      {comment_field(comment, :file)}:{comment_field(comment, :line)}
                    </span>
                    <span class="badge badge-ghost text-[10px] ml-1">
                      {comment_field(comment, :severity)}
                    </span>
                    <p class="mt-0.5">{comment_field(comment, :message)}</p>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <Navigation.pager
            :if={@records_loaded? and @page_info.total_pages > 1}
            page={@page_info.page}
            total_pages={@page_info.total_pages}
            total_count={@page_info.total_count}
            page_path={&reviews_path(@workspace_id, @status, &1)}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp engagement_header(assigns) do
    ~H"""
    <div
      class="grid items-center gap-3 h-[30px] px-[14px] bg-[var(--arb-chrome)]"
      style="grid-template-columns: minmax(80px,1fr) 110px 70px 150px 70px 110px 90px;"
      role="row"
    >
      <span
        :for={label <- ~w(PR Automation Reviews Last\ reviewed Runs Latest\ run Task)}
        class="text-[10.5px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
        role="columnheader"
      >
        {label}
      </span>
    </div>
    """
  end

  attr :engagement, :map, required: true
  attr :run, :map, default: nil

  defp engagement_row(assigns) do
    ~H"""
    <div
      id={"engagement-row-#{@engagement.id}"}
      class="grid items-center gap-3 min-h-[34px] px-[14px] border-b border-[var(--arb-line-soft)] hover:bg-[var(--arb-raised-hover)]"
      style="grid-template-columns: minmax(80px,1fr) 110px 70px 150px 70px 110px 90px;"
      role="row"
    >
      <span data-role="source-pr" class="text-[12px] font-[family-name:var(--font-mono)] truncate">
        {@engagement.source_pr}
      </span>
      <span data-role="automation" class="text-[12px]">
        {format_maybe(@engagement.review_automation)}
      </span>
      <span data-role="review-count" class="text-[12px]">{@engagement.review_count || 0}</span>
      <span data-role="last-reviewed" class="text-[12px]">
        {format_minute(@engagement.last_reviewed_at)}
      </span>
      <span data-role="run-count" class="text-[12px]">{if @run, do: @run.count, else: 0}</span>
      <span data-role="latest-run" class="text-[12px]">
        {format_day(@run && @run.latest)}
      </span>
      <.link
        navigate={~p"/tasks/#{@engagement.id}"}
        class="text-[12px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
      >
        Task &rarr;
      </.link>
    </div>
    """
  end

  defp format_minute(nil), do: "—"
  defp format_minute(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_day(nil), do: "—"
  defp format_day(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp records_state(_loaded?, error) when not is_nil(error), do: "error"
  defp records_state(true, nil), do: "loaded"
  defp records_state(false, nil), do: "loading"
end
