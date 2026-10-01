defmodule ArbiterWeb.WorkerIndexLive do
  @moduledoc """
  Index of every active worker (worker) at `/workers` — the "See all"
  target for the dashboard's active-workers section.

  Workers are live GenServer state, not rows, so the listing comes from
  `Worker.list_children/0` and is paged in memory. A state filter narrows to
  working vs waiting runs (waiting on a question or the review gate). Re-renders live on `:worker_lifecycle` events and
  on a 1s tick (for the elapsed counters). Each row links to the worker
  detail page; completed/failed runs live on the run history index instead.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.Paging
  require Ash.Query

  @workers_topic "workers"

  @filters [
    %{label: "All", value: "all"},
    %{label: "Working", value: "working"},
    %{label: "Waiting", value: "waiting"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    live? = connected?(socket)

    if live? do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)
      :timer.send_interval(1000, self(), :tick)
    end

    socket =
      socket
      |> assign(:now, DateTime.utc_now())
      |> assign(:worker_label, "worker")
      |> assign(:issue_label, "ticket")
      |> assign(:filters, @filters)
      |> assign(:workers_raw, [])
      |> assign(:workers, [])
      |> assign(:page, 1)
      |> assign(:requested_page, 1)
      |> assign(:total_pages, 1)
      |> assign(:total_count, 0)
      |> assign(:workers_loaded?, false)
      |> assign(:workers_loading?, false)
      |> assign(:workers_stale?, false)
      |> assign(:workers_error, nil)

    # The worker walk arrives by `start_async/3` on the connected mount only
    # (bd-4gtia5): the dead render reads nothing and draws a skeleton, and a
    # slow or wedged worker in `Worker.list_children/0`'s GenServer fan-out
    # can no longer block the page.
    {:ok, if(live?, do: fetch_workers(socket), else: socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:status, parse_status(params))
     |> assign(:requested_page, Paging.parse_page(params))
     |> paginate()}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket),
    do: {:noreply, fetch_workers(socket)}

  def handle_info(:tick, socket), do: {:noreply, assign(socket, :now, DateTime.utc_now())}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:workers, {:ok, raw}, socket) do
    socket
    |> assign(:workers_raw, raw)
    |> assign(:workers_loaded?, true)
    |> assign(:workers_error, nil)
    |> paginate()
    |> workers_read_done()
  end

  # A read that fails must not take the page down. Whatever list is on
  # screen stays there — the skeleton on a first load, the last good read on
  # a refresh — under an error that says so.
  def handle_async(:workers, {:exit, reason}, socket) do
    socket
    |> assign(:workers_error, load_error(reason))
    |> workers_read_done()
  end

  @impl true
  def handle_event("retry_workers", _params, socket),
    do: {:noreply, socket |> assign(:workers_error, nil) |> fetch_workers()}

  defp fetch_workers(%{assigns: %{workers_loading?: true}} = socket),
    do: assign(socket, :workers_stale?, true)

  defp fetch_workers(socket) do
    socket
    |> assign(:workers_loading?, true)
    |> assign(:workers_stale?, false)
    |> start_async(:workers, fn -> load_workers() end)
  end

  defp workers_read_done(socket) do
    socket = assign(socket, :workers_loading?, false)

    {:noreply, if(socket.assigns.workers_stale?, do: fetch_workers(socket), else: socket)}
  end

  defp load_error({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp load_error(reason), do: Exception.format_exit(reason)

  # Runs in the async task: the GenServer fan-out over every live worker
  # (bd-4gtia5) plus the workspaces read, kept off the render path.
  defp load_workers do
    workspaces_by_id = index_workspaces()

    list_children()
    # bd-aw2cyt: a row's phase depends on the task's other live rounds, so
    # stamp it over the whole list before filtering or paging.
    |> Arbiter.Worker.Phase.annotate()
    |> Enum.map(fn p ->
      Map.put(p, :workspace_name, workspace_name(workspaces_by_id, p.workspace_id))
    end)
    # bd-45tkhq: a degraded (stale-probe) entry can carry a nil
    # `started_at` when it has no matching Run row; DateTime.compare/2
    # has no nil clause, so sort nils last instead of crashing.
    |> Enum.sort_by(& &1.started_at, fn
      nil, nil -> true
      nil, _ -> false
      _, nil -> true
      a, b -> DateTime.compare(a, b) != :gt
    end)
  end

  defp paginate(socket) do
    all = Enum.filter(socket.assigns.workers_raw, &matches_status?(&1, socket.assigns.status))
    result = Paging.paginate_list(all, socket.assigns.requested_page)

    socket
    |> assign(:workers, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
  end

  defp list_children do
    Worker.list_children()
  rescue
    _ -> []
  end

  defp index_workspaces do
    Ash.read!(Workspace) |> Map.new(fn ws -> {ws.id, ws} end)
  rescue
    _ -> %{}
  end

  defp workspace_name(_by_id, nil), do: "(none)"

  defp workspace_name(by_id, ws_id) do
    case Map.fetch(by_id, ws_id) do
      {:ok, ws} -> ws.name
      :error -> "(unknown)"
    end
  end

  defp matches_status?(_p, :all), do: true
  defp matches_status?(%{state: state}, state), do: true
  defp matches_status?(_p, _), do: false

  # bd-1uu19b: the filter is the run state. The pre-5/13 `running` /
  # `awaiting` values still land on their states, so an old link keeps
  # working.
  defp parse_status(%{"status" => s}) when s in ~w(working waiting all),
    do: String.to_existing_atom(s)

  defp parse_status(%{"status" => "running"}), do: :working
  defp parse_status(%{"status" => "awaiting"}), do: :waiting
  defp parse_status(_), do: :all

  defp worker_path(:all, page), do: ~p"/workers?#{%{page: page}}"
  defp worker_path(status, page), do: ~p"/workers?#{%{status: status, page: page}}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_path={@current_path}
      quotas={@quotas}
      quota_on_exhaustion={@quota_on_exhaustion}
      open_epic_count={@open_epic_count}
      live={@live}
      coordinator_inbox={@coordinator_inbox}
      coordinator_outstanding_count={@coordinator_outstanding_count}
      coordinator_inbox_now={@coordinator_inbox_now}
    >
      <div class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <div class="flex items-start justify-between gap-4">
          <Domain.index_header
            icon="hero-cpu-chip"
            title={"Active #{cap_plural(@worker_label)}"}
            count={@total_count}
            subtitle={"Every #{@worker_label} running right now. Finished runs live on the history index."}
          />
          <Feedback.live_badge live={@live} />
        </div>

        <Navigation.filter_tabs
          tabs={@filters}
          active={Atom.to_string(@status)}
          tab_path={fn value -> worker_path(String.to_existing_atom(value), 1) end}
        />

        <div
          id="workers-panel"
          data-state={workers_state(@workers_loaded?, @workers_error)}
          aria-busy={to_string(not @workers_loaded? and is_nil(@workers_error))}
        >
          <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
            <div
              :if={@workers_error}
              id="workers-error"
              role="alert"
              class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
            >
              <ArbiterWeb.CoreComponents.Core.icon
                name="hero-exclamation-triangle-micro"
                class="size-4 shrink-0 mt-px"
              />
              <span class="grow min-w-0 break-words">
                Could not load {plural(@worker_label)}: {@workers_error}<span :if={@workers_loaded?}> — showing the last list that loaded.</span>
              </span>
              <button
                type="button"
                id="workers-retry"
                phx-click="retry_workers"
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
              :if={not @workers_loaded? and is_nil(@workers_error)}
              id="workers-loading"
              aria-label={"Loading #{plural(@worker_label)}"}
              class="flex flex-col gap-3"
            >
              <div
                :for={n <- 1..3}
                id={"workers-loading-#{n}"}
                aria-hidden="true"
                class="h-[52px] rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--arb-panel-alt)] animate-pulse"
              >
              </div>
            </div>

            <div :if={@workers_loaded? and @workers == []} id="workers-empty">
              <Feedback.empty_state icon="hero-moon">
                No active {plural(@worker_label)} match this filter.
              </Feedback.empty_state>
            </div>

            <ul :if={@workers_loaded? and @workers != []} id="workers" class="flex flex-col gap-3">
              <li :for={p <- @workers} class="flex flex-col">
                <div class="flex items-center gap-1">
                  <.link
                    navigate={~p"/workers/#{p.task_id}"}
                    class={[
                      "flex items-center justify-between gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-solid",
                      "border-[var(--border-default)] bg-[var(--arb-panel-alt)] hover:bg-[var(--arb-raised-hover)]",
                      "transition-colors duration-[var(--dur-hover)] no-underline flex-1 min-w-0"
                    ]}
                  >
                    <div class="flex items-center gap-2 min-w-0 flex-1">
                      <span class="relative flex h-2.5 w-2.5 shrink-0">
                        <span
                          :if={p.state == :working}
                          class="absolute inline-flex h-full w-full animate-ping rounded-full bg-[var(--arb-live)] opacity-75"
                        >
                        </span>
                        <span class={[
                          "relative inline-flex h-2.5 w-2.5 rounded-full",
                          status_dot_class(p.state)
                        ]}>
                        </span>
                      </span>
                      <code class="text-[11px] font-medium font-[family-name:var(--font-mono)] text-[var(--text-secondary)] group-hover:text-[var(--text-link)] transition-colors truncate">
                        {p.task_id}
                      </code>
                      <.provider_icon
                        provider={Worker.provider(p.meta)}
                        class="size-3.5 text-[var(--text-label)] shrink-0"
                      />
                    </div>
                    <div class="flex items-center gap-2 flex-none">
                      <span
                        class="text-[10.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)] whitespace-nowrap"
                        title="Elapsed"
                      >
                        {humanize_seconds(runtime_seconds(p.started_at, @now))}
                      </span>
                      <%!-- bd-aw2cyt: the status badge is the record's state; the
                    phase chip beside it is what is actually happening, and it
                    dims when no agent is live for this row. --%>
                      <span
                        :if={p[:phase]}
                        data-phase={p[:phase]}
                        data-agent-live={to_string(p[:agent_live])}
                        class={[
                          "text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)]",
                          "font-[family-name:var(--font-mono)] border border-solid",
                          "border-[var(--border-strong)] text-[var(--text-label)]",
                          p[:agent_live] != true && "opacity-60"
                        ]}
                      >
                        {Arbiter.Worker.Phase.label(p[:phase])}
                      </span>
                      <span class={[
                        "text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)] font-medium",
                        worker_status_class(ArbiterWeb.StatusHelpers.run_status(p))
                      ]}>
                        {ArbiterWeb.StatusHelpers.run_label(p)}
                      </span>
                    </div>
                  </.link>
                  <ArbiterWeb.CoreComponents.Core.copy_id id={p.task_id} class="flex-none" />
                </div>
                <span class="text-[10.5px] text-[var(--text-label)] px-3 py-1">
                  {p.workspace_name}
                </span>
              </li>
            </ul>

            <Navigation.pager
              :if={@workers_loaded?}
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> worker_path(@status, page) end}
            />
          </ArbiterWeb.CoreComponents.Core.panel>
        </div>

        <div class="flex items-center gap-4">
          <Navigation.back_link />
          <.link
            navigate={~p"/workers/history"}
            class="text-[12.5px] font-medium text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors flex items-center gap-1.5"
          >
            <ArbiterWeb.CoreComponents.Core.icon name="hero-clock" size={14} />
            History (completed {plural(@worker_label)})
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp workers_state(_loaded?, error) when not is_nil(error), do: "error"
  defp workers_state(true, nil), do: "loaded"
  defp workers_state(false, nil), do: "loading"

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now),
    do: DateTime.diff(now, started_at, :second)

  defp runtime_seconds(_, _), do: 0

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp status_dot_class(:working), do: "bg-[var(--arb-live)]"
  defp status_dot_class(:waiting), do: "bg-[var(--arb-attention)]"
  defp status_dot_class(:finished), do: "bg-[var(--arb-done)]"
  defp status_dot_class(_), do: "bg-[var(--text-label)]"

  # Keyed on `StatusHelpers.run_status/1`: a live run's state, a finished
  # run's outcome.
  defp worker_status_class(:starting),
    do: "bg-[color-mix(in_oklch,var(--arb-info)_20%,transparent)] text-[var(--arb-info)]"

  defp worker_status_class(:working),
    do: "bg-[color-mix(in_oklch,var(--arb-live)_20%,transparent)] text-[var(--arb-live)]"

  defp worker_status_class(:waiting),
    do:
      "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"

  defp worker_status_class(:succeeded),
    do: "bg-[color-mix(in_oklch,var(--arb-done)_20%,transparent)] text-[var(--arb-done)]"

  defp worker_status_class(:failed),
    do: "bg-[color-mix(in_oklch,var(--arb-fail)_20%,transparent)] text-[var(--arb-fail-text)]"

  defp worker_status_class(_), do: "bg-[var(--arb-panel)] text-[var(--text-secondary)]"
end
