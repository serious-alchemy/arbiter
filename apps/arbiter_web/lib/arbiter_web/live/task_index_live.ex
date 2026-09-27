defmodule ArbiterWeb.TaskIndexLive do
  @moduledoc """
  Index of every directive (task) at `/tasks` — the "See all" target for the
  dashboard's current-only recent-directives section.

  Lists all directives with a status filter (all / open / in progress /
  awaiting verification / closed), a text search, and a combinable set of
  filters (workspace, type, priority, difficulty, backlog/ready stage, repo,
  parent epic), paginated with offset/limit and sortable by updated / created
  / priority / difficulty. Every bit of that state — search, filters, sort,
  page — round-trips through the URL query string via `push_patch`, so a
  filtered view is shareable and survives reload. Re-renders live on
  `:task_lifecycle` events so a transition shows up without a refresh.

  The "New issue" action navigates to the standalone `/tasks/new` create
  screen (`ArbiterWeb.TaskNewLive`) rather than opening an inline form here.

  ## Filtering strategy

  Every filter is pushed into the `Ash.Query` (see `refresh/1`) rather than
  applied in-memory, so `Paging.paginate/2`'s LIMIT/OFFSET stays correct
  under any combination. Text search matches id, title, and description
  substrings via SQLite's `LIKE` (case-insensitive for ASCII by default —
  same precedent as `AuditLogLive`'s `subject:` clause). The parent-epic
  filter is the one exception worth calling out: it resolves the epic's
  `:parent_of` children (or every parented issue, for "no parent") into an
  id list first, then filters `id in ^ids` / `id not in ^ids` — still a real
  SQL `IN` clause, just built from a precomputed list rather than a joined
  subquery, since AshSqlite has no cross-resource `exists` filter here.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias ArbiterWeb.Paging
  require Ash.Query
  require Logger

  @tasks_topic "tasks"

  # Literal status values — FilterTabs shows these verbatim, not humanized,
  # so the value here is what lands in the URL and the query filter.
  @filter_tabs [
    %{label: "All", value: "all"},
    %{label: "Open", value: "open"},
    %{label: "In progress", value: "in_progress"},
    %{label: "Awaiting verification", value: "awaiting_verification"},
    %{label: "Closed", value: "closed"}
  ]

  @sorts ~w(updated created priority difficulty)a
  @sort_labels %{
    updated: "Last updated",
    created: "Newest first",
    priority: "Priority",
    difficulty: "Difficulty"
  }

  @issue_types Issue.issue_types()
  @priorities 0..4
  @difficulties 0..5

  @default_filters %{
    status: :all,
    q: "",
    workspace: nil,
    type: nil,
    priority: nil,
    difficulty: nil,
    stage: nil,
    repo: nil,
    epic: nil,
    sort: :updated
  }

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)
    if live?, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @tasks_topic)

    # Both the filter-option lists (workspaces/epics/repos) and the result
    # page arrive by `start_async/3` on the connected mount only: the dead
    # render reads nothing and draws a loading state (bd-y9civj).
    socket =
      socket
      |> assign(:issue_label, "issue")
      |> assign(:filter_tabs, @filter_tabs)
      |> assign(:sort_options, Enum.map(@sorts, &{@sort_labels[&1], Atom.to_string(&1)}))
      |> assign(:issue_types, @issue_types)
      |> assign(:priorities, @priorities)
      |> assign(:difficulties, @difficulties)
      |> assign(:workspaces, [])
      |> assign(:epics, [])
      |> assign(:repos, [])
      |> assign(:filter_options_loaded?, false)
      |> assign(:filter_options_error, nil)
      |> assign(:tasks, [])
      |> assign(:page, 1)
      |> assign(:total_pages, 1)
      |> assign(:total_count, 0)
      |> assign(:tasks_loaded?, false)
      |> assign(:tasks_loading?, false)
      |> assign(:tasks_stale?, false)
      |> assign(:tasks_error, nil)

    socket = if live?, do: fetch_filter_options(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)
    page = Paging.parse_page(params)

    socket =
      socket
      |> assign(:f, filters)
      |> assign(:page, page)

    socket = if connected?(socket), do: fetch_tasks(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    params = Map.put(params, "status", Atom.to_string(socket.assigns.f.status))
    {:noreply, push_patch(socket, to: task_path(parse_filters(params), 1))}
  end

  def handle_event("retry_filter_options", _params, socket) do
    {:noreply, fetch_filter_options(socket)}
  end

  def handle_event("retry_tasks", _params, socket) do
    {:noreply, socket |> assign(:tasks_error, nil) |> fetch_tasks()}
  end

  # Any task transition can change which rows belong on the current page;
  # re-read the page in place (same filters + page).
  @impl true
  def handle_info({:task_lifecycle, _event, _issue}, socket) do
    {:noreply, fetch_tasks(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:filter_options, {:ok, options}, socket) do
    {:noreply,
     socket
     |> assign(:workspaces, options.workspaces)
     |> assign(:epics, options.epics)
     |> assign(:repos, options.repos)
     |> assign(:filter_options_loaded?, true)
     |> assign(:filter_options_error, nil)}
  end

  def handle_async(:filter_options, {:exit, reason}, socket) do
    Logger.error("TaskIndexLive: loading filter options failed: #{inspect(reason)}")
    {:noreply, assign(socket, :filter_options_error, describe_exit(reason))}
  end

  # A stale result belongs to filters/page that are no longer current — a
  # newer request was already queued behind this one while it was in
  # flight (see `fetch_tasks/1`'s coalescing clause). Applying it would
  # snap `@page`/`@f` back to what they were when this read started,
  # fighting the URL the user already navigated to (bd-y9civj). Drop it and
  # let `tasks_read_done/1` fire the queued refetch against the current
  # assigns instead.
  def handle_async(:tasks, {:ok, _result}, %{assigns: %{tasks_stale?: true}} = socket) do
    tasks_read_done(socket)
  end

  def handle_async(:tasks, {:ok, result}, socket) do
    socket
    |> assign(:tasks, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
    |> assign(:tasks_loaded?, true)
    |> assign(:tasks_error, nil)
    |> tasks_read_done()
  end

  # Same coalescing: an error for a superseded request isn't worth
  # flashing to the user when a fresher read is about to fire anyway.
  def handle_async(:tasks, {:exit, reason}, %{assigns: %{tasks_stale?: true}} = socket) do
    Logger.error("TaskIndexLive: loading tasks failed (superseded, retrying): #{inspect(reason)}")
    tasks_read_done(socket)
  end

  # A read that fails must not take the page down. Whatever list is on
  # screen stays there — the skeleton on a first load, the last good read on
  # a refresh — under an error that says so.
  def handle_async(:tasks, {:exit, reason}, socket) do
    Logger.error("TaskIndexLive: loading tasks failed: #{inspect(reason)}")

    socket
    |> assign(:tasks_error, describe_exit(reason))
    |> tasks_read_done()
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  # ---- data ----

  defp fetch_filter_options(socket) do
    start_async(socket, :filter_options, &run_filter_options_load/0)
  end

  # The task is linked to this view, so a tab closed mid-read would kill it
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection (under test, the one shared sandbox connection,
  # bd-5scl0c). Trapping turns the view's exit into a message: the query in
  # flight finishes, and the task goes before it starts another.
  defp run_filter_options_load do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_filter_options()

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  @doc false
  def load_filter_options do
    %{workspaces: load_workspaces(), epics: load_epics(), repos: load_repos()}
  end

  # A refresh requested while one is already in flight marks the page stale
  # and gets exactly one more read once the current one lands, so a burst of
  # lifecycle broadcasts costs two reads, not one each (same discipline as
  # BoardLive's `refresh_board/1`, bd-15bn6s).
  defp fetch_tasks(%{assigns: %{tasks_loading?: true}} = socket),
    do: assign(socket, :tasks_stale?, true)

  defp fetch_tasks(socket) do
    f = socket.assigns.f
    page = socket.assigns.page

    socket
    |> assign(:tasks_loading?, true)
    |> assign(:tasks_stale?, false)
    |> start_async(:tasks, fn -> run_tasks_load(f, page) end)
  end

  defp tasks_read_done(socket) do
    socket = assign(socket, :tasks_loading?, false)

    {:noreply, if(socket.assigns.tasks_stale?, do: fetch_tasks(socket), else: socket)}
  end

  defp run_tasks_load(f, page) do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_tasks(f, page)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  @doc false
  def load_tasks(f, page) do
    query =
      Issue
      |> filter_by_status(f.status)
      |> filter_by_query(f.q)
      |> filter_by_workspace(f.workspace)
      |> filter_by_type(f.type)
      |> filter_by_priority(f.priority)
      |> filter_by_difficulty(f.difficulty)
      |> filter_by_stage(f.stage)
      |> filter_by_repo(f.repo)
      |> filter_by_epic(f.epic)
      |> sort_by(f.sort)

    Paging.paginate(query, page)
  end

  defp load_workspaces, do: Workspace |> Ash.read!() |> Enum.sort_by(& &1.name)

  defp load_epics do
    Issue
    |> Ash.Query.filter(issue_type == :epic)
    |> Ash.read!()
    |> Enum.sort_by(& &1.title)
  end

  # AshSqlite has no `distinct` support (bd-y9civj), so this still uniques in
  # Elixir; the `select` at least keeps every other Issue column off the wire.
  defp load_repos do
    Issue
    |> Ash.Query.select([:repo])
    |> Ash.read!()
    |> Enum.map(& &1.repo)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # ---- query filters ----

  defp filter_by_status(query, :all), do: query
  defp filter_by_status(query, status), do: Ash.Query.filter(query, status == ^status)

  defp filter_by_query(query, ""), do: query

  defp filter_by_query(query, q) do
    pattern = "%#{escape_like(q)}%"

    # SQLite's LIKE is case-insensitive for ASCII by default; the ESCAPE
    # clause keeps a literal `%` or `_` typed by the user from acting as a
    # wildcard.
    Ash.Query.filter(
      query,
      fragment("? LIKE ? ESCAPE '\\'", id, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", title, ^pattern) or
        fragment("? LIKE ? ESCAPE '\\'", description, ^pattern)
    )
  end

  defp escape_like(q) do
    q
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp filter_by_workspace(query, nil), do: query
  defp filter_by_workspace(query, id), do: Ash.Query.filter(query, workspace_id == ^id)

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: Ash.Query.filter(query, issue_type == ^type)

  defp filter_by_priority(query, nil), do: query
  defp filter_by_priority(query, p), do: Ash.Query.filter(query, priority == ^p)

  defp filter_by_difficulty(query, nil), do: query
  defp filter_by_difficulty(query, :none), do: Ash.Query.filter(query, is_nil(difficulty))
  defp filter_by_difficulty(query, d), do: Ash.Query.filter(query, difficulty == ^d)

  defp filter_by_stage(query, nil), do: query
  defp filter_by_stage(query, :backlog), do: Ash.Query.filter(query, refined == false)
  defp filter_by_stage(query, :ready), do: Ash.Query.filter(query, refined == true)

  defp filter_by_repo(query, nil), do: query
  defp filter_by_repo(query, repo), do: Ash.Query.filter(query, repo == ^repo)

  defp filter_by_epic(query, nil), do: query

  defp filter_by_epic(query, :none) do
    case parented_issue_ids() do
      [] -> query
      parented_ids -> Ash.Query.filter(query, id not in ^parented_ids)
    end
  end

  defp filter_by_epic(query, epic_id) do
    child_ids = children_of(epic_id)
    Ash.Query.filter(query, id in ^child_ids)
  end

  defp parented_issue_ids do
    parent_of = :parent_of

    Dependency
    |> Ash.Query.filter(type == ^parent_of)
    |> Ash.read!()
    |> Enum.map(& &1.to_issue_id)
    |> Enum.uniq()
  end

  defp children_of(epic_id) do
    parent_of = :parent_of

    Dependency
    |> Ash.Query.filter(type == ^parent_of and from_issue_id == ^epic_id)
    |> Ash.read!()
    |> Enum.map(& &1.to_issue_id)
  end

  defp sort_by(query, :updated), do: Ash.Query.sort(query, updated_at: :desc)
  defp sort_by(query, :created), do: Ash.Query.sort(query, created_at: :desc)
  defp sort_by(query, :priority), do: Ash.Query.sort(query, priority: :asc)
  defp sort_by(query, :difficulty), do: Ash.Query.sort(query, difficulty: :asc_nils_last)

  # ---- URL <-> filter-state ----

  defp parse_filters(params) do
    %{
      status: parse_status(params),
      q: parse_q(params),
      workspace: parse_present_string(params, "workspace"),
      type: parse_type(params),
      priority: parse_priority(params),
      difficulty: parse_difficulty(params),
      stage: parse_stage(params),
      repo: parse_present_string(params, "repo"),
      epic: parse_epic(params),
      sort: parse_sort(params)
    }
  end

  defp parse_status(%{"status" => s}) when s in ~w(open in_progress awaiting_verification closed),
    do: String.to_existing_atom(s)

  defp parse_status(_), do: :all

  defp parse_q(%{"q" => q}) when is_binary(q), do: String.trim(q)
  defp parse_q(_), do: ""

  defp parse_present_string(params, key) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp parse_type(params) do
    with v when is_binary(v) and v != "" <- Map.get(params, "type"),
         true <- v in Enum.map(@issue_types, &Atom.to_string/1) do
      String.to_existing_atom(v)
    else
      _ -> nil
    end
  end

  defp parse_priority(params) do
    with v when is_binary(v) and v != "" <- Map.get(params, "priority"),
         {n, ""} <- Integer.parse(v),
         true <- n in @priorities do
      n
    else
      _ -> nil
    end
  end

  defp parse_difficulty(%{"difficulty" => "none"}), do: :none

  defp parse_difficulty(params) do
    with v when is_binary(v) and v != "" <- Map.get(params, "difficulty"),
         {n, ""} <- Integer.parse(v),
         true <- n in @difficulties do
      n
    else
      _ -> nil
    end
  end

  defp parse_stage(%{"stage" => s}) when s in ~w(backlog ready), do: String.to_existing_atom(s)
  defp parse_stage(_), do: nil

  defp parse_epic(%{"epic" => "none"}), do: :none
  defp parse_epic(params), do: parse_present_string(params, "epic")

  defp parse_sort(%{"sort" => s}) when s in ~w(updated created priority difficulty),
    do: String.to_existing_atom(s)

  defp parse_sort(_), do: :updated

  # ---- routes ----

  defp task_path(f, page) do
    %{}
    |> put_param(:status, f.status, @default_filters.status)
    |> put_param(:q, f.q, @default_filters.q)
    |> put_param(:workspace, f.workspace, @default_filters.workspace)
    |> put_param(:type, f.type, @default_filters.type)
    |> put_param(:priority, f.priority, @default_filters.priority)
    |> put_param(:difficulty, f.difficulty, @default_filters.difficulty)
    |> put_param(:stage, f.stage, @default_filters.stage)
    |> put_param(:repo, f.repo, @default_filters.repo)
    |> put_param(:epic, f.epic, @default_filters.epic)
    |> put_param(:sort, f.sort, @default_filters.sort)
    |> Map.put(:page, page)
    |> then(&~p"/tasks?#{&1}")
  end

  defp put_param(params, _key, default, default), do: params
  defp put_param(params, key, value, _default), do: Map.put(params, key, value)

  # ---- active-filter summary ----

  defp active_filter_summary(f, workspaces) do
    [
      f.status != :all && "status: #{f.status}",
      f.q != "" && "search: #{f.q}",
      f.workspace && "workspace: #{workspace_name(workspaces, f.workspace)}",
      f.type && "type: #{f.type}",
      f.priority && "priority: P#{f.priority}",
      difficulty_filter_label(f.difficulty),
      f.stage && "stage: #{f.stage}",
      f.repo && "repo: #{f.repo}",
      epic_filter_label(f.epic)
    ]
    |> Enum.filter(& &1)
  end

  defp difficulty_filter_label(:none), do: "difficulty: unrated"
  defp difficulty_filter_label(d) when is_integer(d), do: "difficulty: D#{d}"
  defp difficulty_filter_label(_), do: nil

  defp epic_filter_label(:none), do: "parent: none"
  defp epic_filter_label(e) when is_binary(e), do: "parent: #{e}"
  defp epic_filter_label(_), do: nil

  defp workspace_name(workspaces, id) do
    case Enum.find(workspaces, &(&1.id == id)) do
      %{name: name} -> name
      _ -> id
    end
  end

  # ---- render ----

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :active_filters, active_filter_summary(assigns.f, assigns.workspaces))

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
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-clipboard-document-list"
          title={cap_plural(@issue_label)}
          count={@total_count}
          subtitle={"Every #{@issue_label}, filterable and paged. The dashboard shows only the current ones."}
        >
          <:actions>
            <ArbiterWeb.CoreComponents.Feedback.live_badge live={@live} />
            <ArbiterWeb.CoreComponents.Core.button
              type="button"
              variant="primary"
              size="sm"
              phx-click={JS.navigate(~p"/tasks/new")}
            >
              <:icon><ArbiterWeb.CoreComponents.Core.icon name="hero-plus" size={13} /></:icon>
              New {@issue_label}
            </ArbiterWeb.CoreComponents.Core.button>
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <ArbiterWeb.CoreComponents.Navigation.filter_tabs
          tabs={@filter_tabs}
          active={Atom.to_string(@f.status)}
          tab_path={fn value -> task_path(%{@f | status: String.to_existing_atom(value)}, 1) end}
        />

        <form
          id="tasks-filter-form"
          phx-change="filter"
          class="flex flex-wrap items-end gap-2.5 p-3 rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--arb-canvas-sunken)]"
        >
          <div class="flex-1 min-w-[200px]">
            <ArbiterWeb.CoreComponents.Forms.input
              type="text"
              name="q"
              id="tasks-search"
              value={@f.q}
              placeholder="Search id or title…"
              phx-debounce="300"
              mono={false}
            />
          </div>

          <ArbiterWeb.CoreComponents.Forms.select
            name="workspace"
            id="tasks-filter-workspace"
            size="sm"
            prompt="Any workspace"
            value={@f.workspace || ""}
            options={ensure_selected_option(Enum.map(@workspaces, &{&1.name, &1.id}), @f.workspace)}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="type"
            id="tasks-filter-type"
            size="sm"
            prompt="Any type"
            value={if @f.type, do: Atom.to_string(@f.type), else: ""}
            options={Enum.map(@issue_types, &{Phoenix.Naming.humanize(&1), Atom.to_string(&1)})}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="priority"
            id="tasks-filter-priority"
            size="sm"
            prompt="Any priority"
            value={if @f.priority, do: Integer.to_string(@f.priority), else: ""}
            options={Enum.map(@priorities, &{"P#{&1}", Integer.to_string(&1)})}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="difficulty"
            id="tasks-filter-difficulty"
            size="sm"
            prompt="Any difficulty"
            value={difficulty_select_value(@f.difficulty)}
            options={[
              {"Unrated", "none"} | Enum.map(@difficulties, &{"D#{&1}", Integer.to_string(&1)})
            ]}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="stage"
            id="tasks-filter-stage"
            size="sm"
            prompt="Backlog + Ready"
            value={if @f.stage, do: Atom.to_string(@f.stage), else: ""}
            options={[{"Backlog", "backlog"}, {"Ready", "ready"}]}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="repo"
            id="tasks-filter-repo"
            size="sm"
            prompt="Any repo"
            value={@f.repo || ""}
            options={ensure_selected_option(@repos, @f.repo)}
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="epic"
            id="tasks-filter-epic"
            size="sm"
            prompt="Any parent"
            value={epic_select_value(@f.epic)}
            options={
              ensure_selected_option(
                [{"No parent", "none"} | Enum.map(@epics, &{"#{&1.id} — #{&1.title}", &1.id})],
                epic_extra_selected(@f.epic)
              )
            }
          />

          <ArbiterWeb.CoreComponents.Forms.select
            name="sort"
            id="tasks-filter-sort"
            size="sm"
            value={Atom.to_string(@f.sort)}
            options={@sort_options}
          />

          <.link
            :if={@active_filters != []}
            id="tasks-clear-filters"
            patch={~p"/tasks"}
            class="text-[11.5px] text-[var(--text-link)] hover:underline whitespace-nowrap pb-1.5"
          >
            Clear filters
          </.link>
        </form>

        <div
          :if={@filter_options_error}
          id="tasks-filter-options-error"
          role="alert"
          class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
        >
          <ArbiterWeb.CoreComponents.Core.icon
            name="hero-exclamation-triangle-micro"
            class="size-4 shrink-0 mt-px"
          />
          <span class="grow min-w-0 break-words">
            Could not load filter options: {@filter_options_error}
          </span>
          <button
            type="button"
            id="tasks-filter-options-retry"
            phx-click="retry_filter_options"
            class={[
              "shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer",
              "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
              "text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
            ]}
          >
            Retry
          </button>
        </div>

        <div :if={@active_filters != []} id="tasks-active-filters" class="flex flex-wrap gap-1.5">
          <span
            :for={label <- @active_filters}
            class="badge badge-ghost text-[10.5px] font-[family-name:var(--font-mono)]"
          >
            {label}
          </span>
        </div>

        <div
          id="tasks-panel"
          data-state={tasks_state(@tasks_loaded?, @tasks_error)}
          aria-busy={to_string(not @tasks_loaded? and is_nil(@tasks_error))}
        >
          <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
            <div
              :if={@tasks_error}
              id="tasks-error"
              role="alert"
              class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
            >
              <ArbiterWeb.CoreComponents.Core.icon
                name="hero-exclamation-triangle-micro"
                class="size-4 shrink-0 mt-px"
              />
              <span class="grow min-w-0 break-words">
                Could not load {plural(@issue_label)}: {@tasks_error}<span :if={@tasks_loaded?}> — showing the last page that loaded.</span>
              </span>
              <button
                type="button"
                id="tasks-retry"
                phx-click="retry_tasks"
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
              :if={not @tasks_loaded? and is_nil(@tasks_error)}
              id="tasks-loading"
              aria-label={"Loading #{plural(@issue_label)}"}
              class="flex flex-col gap-1.5"
            >
              <div
                :for={n <- 1..5}
                id={"tasks-loading-#{n}"}
                aria-hidden="true"
                class="h-[34px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
              >
              </div>
            </div>

            <div :if={@tasks_loaded? and @tasks == []} id="tasks-empty">
              <ArbiterWeb.CoreComponents.Feedback.empty_state icon="hero-clipboard-document-list">
                No {plural(@issue_label)} match
                <%= if @active_filters != [] do %>
                  the active filters ({Enum.join(@active_filters, ", ")}).
                <% else %>
                  this filter.
                <% end %>
              </ArbiterWeb.CoreComponents.Feedback.empty_state>
            </div>

            <ul :if={@tasks_loaded? and @tasks != []} id="tasks" class="flex flex-col gap-1.5">
              <li :for={b <- @tasks} class={issue_row_class(b)}>
                <.priority_tag priority={b.priority} />
                <.difficulty_meter difficulty={b.difficulty} />
                <.link
                  navigate={~p"/tasks/#{b.id}"}
                  class="min-w-0 flex-1 flex items-center gap-2 group"
                >
                  <span class="font-[family-name:var(--font-mono)] text-[10.5px] text-[var(--text-secondary)] shrink-0 group-hover:text-[var(--text-link)] transition-colors">
                    {b.id}
                  </span>
                  <span
                    class="truncate text-[12.5px] font-medium text-[var(--text-title)] group-hover:text-[var(--text-link)] transition-colors"
                    title={b.title}
                  >
                    {b.title}
                  </span>
                </.link>
                <ArbiterWeb.CoreComponents.Core.copy_id id={b.id} />
                <.status_chip status={b.status} />
              </li>
            </ul>

            <ArbiterWeb.CoreComponents.Navigation.pager
              :if={@tasks_loaded?}
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> task_path(@f, page) end}
              class={@tasks != [] && "pt-2"}
            />
          </ArbiterWeb.CoreComponents.Core.panel>
        </div>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp tasks_state(_loaded?, error) when not is_nil(error), do: "error"
  defp tasks_state(true, nil), do: "loaded"
  defp tasks_state(false, nil), do: "loading"

  defp difficulty_select_value(:none), do: "none"
  defp difficulty_select_value(d) when is_integer(d), do: Integer.to_string(d)
  defp difficulty_select_value(nil), do: ""

  defp epic_select_value(:none), do: "none"
  defp epic_select_value(id) when is_binary(id), do: id
  defp epic_select_value(nil), do: ""

  defp epic_extra_selected(id) when is_binary(id), do: id
  defp epic_extra_selected(_), do: nil

  # The workspace/repo/epic filter lists load async and can be `[]` while
  # loading, or stay `[]` after a failed load. If the URL already names a
  # value not yet in the list, the select's browser-rendered value would
  # silently fall back to the prompt option — and the next unrelated
  # `phx-change` would then push_patch that filter away (bd-y9civj).
  # Keeping the current value as an option (even without its real label)
  # until the real list lands avoids losing it.
  defp ensure_selected_option(options, nil), do: options

  defp ensure_selected_option(options, selected) do
    if Enum.any?(options, &(option_value(&1) == selected)) do
      options
    else
      options ++ [{selected, selected}]
    end
  end

  defp option_value({_label, value}), do: value
  defp option_value(value), do: value

  # P1 is the only priority that owns the row: a red left rule plus a faint
  # wash, matching the accent-rule treatment `Domain.task_card/1` uses for
  # its `fail` accent. Closed issues recede instead — opacity 0.62, no rule.
  defp issue_row_class(issue) do
    [
      "flex items-center gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-solid",
      "border-[var(--border-strong)] hover:bg-[var(--arb-raised-hover)]",
      "transition-colors duration-[var(--dur-hover)]",
      if(issue.priority == 1,
        do: [
          "bg-[var(--arb-fail-wash)]",
          "border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-fail)]"
        ],
        else: "bg-[var(--surface-card)]"
      ),
      issue.status == :closed && "opacity-[0.62]"
    ]
  end
end
