defmodule ArbiterWeb.RunIndexLive do
  @moduledoc """
  Index of every worker run at `/workers/history` — the "See all" target for
  the dashboard's completed-workers section.

  Lists all persisted `Arbiter.Workers.Run` records (the durable post-mortem
  of each worker execution) with a filter on the run's state or outcome
  (bd-1uu19b) and paging, newest first.
  Each row links to the run detail page. Re-renders live on
  `:worker_lifecycle` events so a freshly-finished run appears without a
  refresh.

  The result page arrives by `start_async/3` on the connected mount only
  (bd-1gshps): the dead render reads nothing and draws a loading skeleton,
  an async failure renders an inline error with a retry button instead of
  crashing, and `:worker_lifecycle` refreshes re-run the same async load.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Workers.Run
  alias Arbiter.Workers.RunNode
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.Paging
  require Ash.Query
  require Logger

  @workers_topic "workers"

  @filters [
    %{label: "All", value: "all"},
    # Any run not finished yet: starting, working, or waiting.
    %{label: "Live", value: "live"},
    %{label: "Succeeded", value: "succeeded"},
    # A review park or a review that never started (bd-8tjcms, bd-9zuvbh) is
    # a failed run, with its cause on the row's failure reason.
    %{label: "Failed", value: "failed"},
    # bd-aje6fj: the worker was shut down with the server — not a failure.
    %{label: "Interrupted", value: "interrupted"},
    %{label: "Handed off", value: "handed_off"}
  ]

  @outcome_filters ~w(succeeded failed interrupted handed_off)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Arbiter.PubSub, @workers_topic)

    {:ok,
     socket
     |> assign(:worker_label, "worker")
     |> assign(:filters, @filters)
     |> assign(:runs, [])
     |> assign(:page, 1)
     |> assign(:total_pages, 1)
     |> assign(:total_count, 0)
     |> assign(:runs_loaded?, false)
     |> assign(:runs_loading?, false)
     |> assign(:runs_stale?, false)
     |> assign(:runs_error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> assign(:status, parse_status(params))
      |> assign(:page, Paging.parse_page(params))

    # The dead render reads nothing and draws a loading state; the query
    # only runs once the socket is connected (bd-1gshps).
    socket = if connected?(socket), do: fetch_runs(socket), else: socket

    {:noreply, socket}
  end

  @impl true
  def handle_event("retry_runs", _params, socket) do
    {:noreply, socket |> assign(:runs_error, nil) |> fetch_runs()}
  end

  @impl true
  def handle_info({:worker_lifecycle, _event, _snap}, socket), do: {:noreply, fetch_runs(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  # A stale result belongs to a status/page that's no longer current — a
  # newer request was already queued behind this one while it was in flight
  # (see `fetch_runs/1`'s coalescing clause). Drop it and let
  # `runs_read_done/1` fire the queued refetch against the current assigns.
  def handle_async(:runs, {:ok, _result}, %{assigns: %{runs_stale?: true}} = socket) do
    runs_read_done(socket)
  end

  def handle_async(:runs, {:ok, result}, socket) do
    socket
    |> assign(:runs, result.entries)
    |> assign(:page, result.page)
    |> assign(:total_pages, result.total_pages)
    |> assign(:total_count, result.total_count)
    |> assign(:runs_loaded?, true)
    |> assign(:runs_error, nil)
    |> runs_read_done()
  end

  def handle_async(:runs, {:exit, reason}, %{assigns: %{runs_stale?: true}} = socket) do
    Logger.error("RunIndexLive: loading runs failed (superseded, retrying): #{inspect(reason)}")
    runs_read_done(socket)
  end

  # A read that fails must not take the page down. Whatever list is on
  # screen stays there — the skeleton on a first load, the last good read on
  # a refresh — under an error that says so.
  def handle_async(:runs, {:exit, reason}, socket) do
    Logger.error("RunIndexLive: loading runs failed: #{inspect(reason)}")

    socket
    |> assign(:runs_error, describe_exit(reason))
    |> runs_read_done()
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  # A refresh requested while one is already in flight marks the page stale
  # and gets exactly one more read once the current one lands, so a burst of
  # lifecycle broadcasts costs two reads, not one each.
  defp fetch_runs(%{assigns: %{runs_loading?: true}} = socket),
    do: assign(socket, :runs_stale?, true)

  defp fetch_runs(socket) do
    status = socket.assigns.status
    page = socket.assigns.page

    socket
    |> assign(:runs_loading?, true)
    |> assign(:runs_stale?, false)
    |> start_async(:runs, fn -> run_runs_load(status, page) end)
  end

  defp runs_read_done(socket) do
    socket = assign(socket, :runs_loading?, false)
    {:noreply, if(socket.assigns.runs_stale?, do: fetch_runs(socket), else: socket)}
  end

  # The task is linked to this view, so a tab closed mid-read would kill it
  # mid-query — and a DB client that dies holding a checkout costs the pool
  # that connection. Trapping turns the view's exit into a message: the
  # query in flight finishes, and the task goes before it starts another.
  defp run_runs_load(status, page) do
    Process.flag(:trap_exit, true)
    result = __MODULE__.load_runs(status, page)

    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> result
    end
  end

  @doc false
  def load_runs(status, page) do
    query =
      Run
      |> filter_by_status(status)
      |> Ash.Query.sort(started_at: :desc)
      |> exclude_output_lines()

    Paging.paginate(query, page)
  end

  defp filter_by_status(query, :all), do: Ash.Query.new(query)
  defp filter_by_status(query, :live), do: Ash.Query.filter(query, state != :finished)
  defp filter_by_status(query, outcome), do: Ash.Query.filter(query, outcome == ^outcome)

  defp exclude_output_lines(query) do
    Ash.Query.select(query, [
      :id,
      :task_id,
      :task_title,
      :repo,
      :workspace_id,
      :kind,
      :role,
      :state,
      :outcome,
      :model,
      :started_at,
      :completed_at,
      :exit_code,
      :failure_reason,
      :failure_summary,
      :resolved_skills,
      :standing_orders_digest,
      :routing_policy,
      :model_tier,
      :thinking,
      :difficulty_at_dispatch,
      :provider,
      :node_id,
      :session_id,
      :resumed_from_run_id
    ])
  end

  # The `status` param names a filter tab: `live`, or a finished run's
  # outcome. The pre-5/13 values still land on their tab, so an old link
  # keeps working (`RunState.from_legacy_status/1`'s mapping).
  defp parse_status(%{"status" => "live"}), do: :live

  defp parse_status(%{"status" => s}) when s in @outcome_filters,
    do: String.to_existing_atom(s)

  defp parse_status(%{"status" => "running"}), do: :live
  defp parse_status(%{"status" => "completed"}), do: :succeeded

  defp parse_status(%{"status" => s}) when s in ~w(review_not_started review_parked),
    do: :failed

  defp parse_status(_), do: :all

  defp run_path(:all, page), do: ~p"/workers/history?#{%{page: page}}"
  defp run_path(status, page), do: ~p"/workers/history?#{%{status: status, page: page}}"

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
            icon="hero-clock"
            title={"#{cap_plural(@worker_label)} history"}
            count={@total_count}
            subtitle={"Every recorded #{@worker_label} run. The dashboard shows only the most recent."}
          />
          <Feedback.live_badge live={@live} />
        </div>

        <Navigation.filter_tabs
          tabs={@filters}
          active={Atom.to_string(@status)}
          tab_path={fn value -> run_path(String.to_existing_atom(value), 1) end}
        />

        <div
          id="runs-panel"
          data-state={runs_state(@runs_loaded?, @runs_error)}
          aria-busy={to_string(not @runs_loaded? and is_nil(@runs_error))}
        >
          <ArbiterWeb.CoreComponents.Core.panel body_class="flex flex-col gap-4">
            <div
              :if={@runs_error}
              id="runs-error"
              role="alert"
              class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
            >
              <ArbiterWeb.CoreComponents.Core.icon
                name="hero-exclamation-triangle-micro"
                class="size-4 shrink-0 mt-px"
              />
              <span class="grow min-w-0 break-words">
                Could not load {@worker_label} runs: {@runs_error}<span :if={@runs_loaded?}> — showing the last page that loaded.</span>
              </span>
              <button
                type="button"
                id="runs-retry"
                phx-click="retry_runs"
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
              :if={not @runs_loaded? and is_nil(@runs_error)}
              id="runs-loading"
              aria-label={"Loading #{@worker_label} runs"}
              class="flex flex-col gap-3"
            >
              <div
                :for={n <- 1..5}
                id={"runs-loading-#{n}"}
                aria-hidden="true"
                class="h-[56px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
              >
              </div>
            </div>

            <div :if={@runs_loaded? and @runs == []} id="runs-empty">
              <Feedback.empty_state icon="hero-moon">
                No {@worker_label} runs match this filter.
              </Feedback.empty_state>
            </div>

            <ul :if={@runs_loaded? and @runs != []} id="runs-history" class="flex flex-col gap-3">
              <li :for={r <- @runs}>
                <.link navigate={~p"/workers/history/#{r.id}"} class="block no-underline">
                  <Domain.run_row
                    worker={r.task_id}
                    outcome={r.task_title || r.task_id}
                    status={ArbiterWeb.StatusHelpers.run_status(r)}
                    duration={humanize_duration(r.started_at, r.completed_at)}
                    role={ArbiterWeb.StatusHelpers.run_role(r)}
                    provider={r.provider}
                    node_name={RunNode.node_name(r)}
                    selected={false}
                    expanded={false}
                    class="cursor-pointer hover:bg-[var(--surface-raised)]"
                  />
                </.link>
              </li>
            </ul>

            <Navigation.pager
              :if={@runs_loaded?}
              page={@page}
              total_pages={@total_pages}
              total_count={@total_count}
              page_path={fn page -> run_path(@status, page) end}
            />
          </ArbiterWeb.CoreComponents.Core.panel>
        </div>

        <Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end

  # ---- view helpers ----

  defp runs_state(_loaded?, error) when not is_nil(error), do: "error"
  defp runs_state(true, nil), do: "loaded"
  defp runs_state(false, nil), do: "loading"

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: nil

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"
end
