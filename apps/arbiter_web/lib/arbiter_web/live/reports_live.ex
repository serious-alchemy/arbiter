defmodule ArbiterWeb.ReportsLive do
  @moduledoc """
  LiveView at `/reports` — the reports shell (bd-an8t0e; design
  `docs/design/reports-design-v2.md` §7).

  Owns the page chrome every report reuses: the shared filter form (workspace,
  repo, type, difficulty, range — held in the query string so a view is
  linkable), the loading / empty / failed states, the "as of" stamp of the
  short-TTL `Arbiter.Reports.Cache`, and the `ArbiterWeb.Charts` components.
  Reports are computed in `start_async/3` on the connected mount and again on
  every filter change; nothing runs on a PubSub tick.

  The overview shown here (ticket counts and tickets created per week) is the
  shell's first consumer of the chart set; the real reports (throughput, cost,
  ReviewGate health, …) arrive as tabs in later tickets and reuse
  `filters/1`, `load_report/1` and the `<.report_state>` wrapper.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Reports.{Cache, Throughput}
  alias Arbiter.Tasks.{Issue, Workspace}
  alias ArbiterWeb.Charts
  alias ArbiterWeb.CoreComponents.Feedback
  alias Phoenix.LiveView.AsyncResult
  require Ash.Query

  @ranges ~w(7d 30d 90d all)
  @types ~w(task research bug feature epic chore decision)
  @difficulties ~w(0 1 2 3 4 5)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Reports")
     |> assign(:workspaces, load_workspaces())
     |> assign(:repos, load_repos())
     |> assign(:types_list, @types)
     |> assign(:difficulties_list, @difficulties)
     |> assign(:ranges_list, @ranges)
     |> assign(:filters, default_filters())
     |> assign(:form, to_form(default_filters(), as: :filters))
     |> assign(:as_of, nil)
     |> assign(:report, AsyncResult.loading())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = parse_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(filters, as: :filters))
     |> assign(:report, AsyncResult.loading(socket.assigns.report))
     |> start_report(filters)}
  end

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/reports?#{query(parse_filters(params))}")}
  end

  def handle_event("range", %{"option" => range}, socket) do
    filters = Map.put(socket.assigns.filters, "range", range)
    {:noreply, push_patch(socket, to: ~p"/reports?#{query(parse_filters(filters))}")}
  end

  @impl true
  def handle_async(:report, {:ok, {report, as_of}}, socket) do
    {:noreply,
     socket
     |> assign(:as_of, as_of)
     |> assign(:report, AsyncResult.ok(socket.assigns.report, report))}
  end

  def handle_async(:report, {:exit, reason}, socket) do
    {:noreply, assign(socket, :report, AsyncResult.failed(socket.assigns.report, reason))}
  end

  # ---- filters ----

  defp default_filters,
    do: %{"workspace" => "", "repo" => "", "type" => "", "difficulty" => "", "range" => "30d"}

  # Unknown values collapse to "any" so a stale or hand-edited URL never
  # reaches a query (and `type` is never turned into an atom unchecked).
  defp parse_filters(params) do
    %{
      "workspace" => Map.get(params, "workspace", ""),
      "repo" => Map.get(params, "repo", ""),
      "type" => one_of(params, "type", @types),
      "difficulty" => one_of(params, "difficulty", @difficulties),
      "range" => one_of(params, "range", @ranges, "30d")
    }
  end

  defp one_of(params, key, allowed, default \\ "") do
    value = Map.get(params, key)
    if value in allowed, do: value, else: default
  end

  defp query(filters), do: Map.reject(filters, fn {_k, v} -> v == "" end)

  defp range_cutoff("all"), do: nil

  defp range_cutoff(range) do
    days = range |> String.trim_trailing("d") |> String.to_integer()
    DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
  end

  # ---- data ----

  defp start_report(socket, filters) do
    if connected?(socket) do
      start_async(socket, :report, fn ->
        Cache.fetch({:overview, filters}, fn -> load_report(filters) end)
      end)
    else
      socket
    end
  end

  defp load_workspaces do
    Workspace |> Ash.Query.select([:id, :name]) |> Ash.Query.sort(:name) |> Ash.read!()
  end

  defp load_repos do
    Issue
    |> Ash.Query.select([:repo])
    |> Ash.Query.filter(not is_nil(repo))
    |> Ash.read!()
    |> Enum.map(& &1.repo)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  # One slim read (id, state, created_at only — never whole tickets' notes or
  # versions), grouped in Elixir; the chart contract is a list of points.
  def load_report(filters) do
    rows =
      Issue
      |> Ash.Query.select([:id, :state, :created_at])
      |> apply_filters(filters)
      |> Ash.read!()

    weekly =
      rows
      |> Enum.frequencies_by(&(&1.created_at |> DateTime.to_date() |> Date.beginning_of_week()))
      |> Enum.sort()
      |> Enum.map(fn {date, n} ->
        %{key: Date.to_iso8601(date), label: Calendar.strftime(date, "%b %d"), value: n}
      end)

    %{
      total: length(rows),
      closed: Enum.count(rows, &(&1.state == :closed)),
      open: Enum.count(rows, &(&1.state != :closed)),
      weekly: weekly,
      throughput: Throughput.load(filters)
    }
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {_, ""}, q ->
        q

      {"workspace", id}, q ->
        Ash.Query.filter(q, workspace_id == ^id)

      {"repo", repo}, q ->
        Ash.Query.filter(q, repo == ^repo)

      {"type", type}, q ->
        Ash.Query.filter(q, issue_type == ^String.to_existing_atom(type))

      {"difficulty", d}, q ->
        Ash.Query.filter(q, difficulty == ^String.to_integer(d))

      {"range", range}, q ->
        case range_cutoff(range) do
          nil -> q
          cutoff -> Ash.Query.filter(q, created_at >= ^cutoff)
        end
    end)
  end

  # ---- render ----

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
      <div id="reports-page" class="p-4 sm:p-6 max-w-7xl mx-auto flex flex-col gap-4">
        <div class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <h1 class="text-[20px] font-semibold">Reports</h1>
            <p class="text-[12.5px] text-[var(--text-secondary)]">
              Aggregates over the ticket lifecycle. Results are cached briefly and may lag.
            </p>
          </div>
          <span
            :if={@as_of}
            id="reports-as-of"
            class="text-[11.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
          >
            as of {Calendar.strftime(@as_of, "%H:%M:%S")} UTC
          </span>
        </div>

        <div class="flex flex-wrap items-end gap-3">
          <.form
            for={@form}
            id="reports-filters"
            phx-change="filter"
            class="flex flex-wrap items-end gap-3"
          >
            <.filter_select
              field={@form[:workspace]}
              label="Workspace"
              options={Enum.map(@workspaces, &{&1.name, &1.id})}
            />
            <.filter_select field={@form[:repo]} label="Repo" options={Enum.map(@repos, &{&1, &1})} />
            <.filter_select
              field={@form[:type]}
              label="Type"
              options={Enum.map(@types_list, &{&1, &1})}
            />
            <.filter_select
              field={@form[:difficulty]}
              label="Difficulty"
              options={Enum.map(@difficulties_list, &{"D#{&1}", &1})}
            />
          </.form>
          <.segmented_control
            id="reports-range"
            options={@ranges_list}
            value={@filters["range"]}
            event="range"
          />
        </div>

        <.async_result :let={report} assign={@report}>
          <:loading>
            <div id="reports-loading" class="grid grid-cols-2 sm:grid-cols-3 gap-3">
              <div
                :for={_ <- 1..3}
                class="h-[74px] rounded-[var(--radius-md)] bg-[var(--arb-done-wash)] animate-pulse"
              />
            </div>
          </:loading>
          <:failed :let={_reason}>
            <div id="reports-failed" class="text-[12.5px] text-[var(--arb-fail-text)]">
              The report could not be computed. Change a filter to retry.
            </div>
          </:failed>

          <div :if={report.total == 0} id="reports-empty">
            <Feedback.empty_state
              icon="hero-chart-bar-square"
              detail="Widen the range or clear a filter."
            >
              No tickets match these filters.
            </Feedback.empty_state>
          </div>

          <div :if={report.total > 0} class="flex flex-col gap-4">
            <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
              <Charts.stat_tile id="reports-tile-total" label="Tickets" value={report.total} />
              <Charts.stat_tile id="reports-tile-closed" label="Closed" value={report.closed} />
              <Charts.stat_tile id="reports-tile-open" label="Open" value={report.open} />
            </div>
            <section class="flex flex-col gap-2">
              <h2 class="text-[13px] font-medium">Tickets created per week</h2>
              <Charts.bar
                id="reports-created-chart"
                title="Tickets created per week"
                points={report.weekly}
              />
            </section>
            <.throughput_section throughput={report.throughput} />
          </div>
        </.async_result>
      </div>
    </Layouts.app>
    """
  end

  attr :throughput, :map, required: true

  defp throughput_section(assigns) do
    t = assigns.throughput
    ranks = Throughput.weights() |> Enum.sort() |> Enum.map(&elem(&1, 0))

    series =
      Enum.map(ranks, &%{key: &1, label: "D#{&1}"}) ++ [%{key: :unrated, label: "Unrated"}]

    assigns =
      assign(assigns,
        series: series,
        stacked:
          Enum.map(t.weekly, fn w ->
            %{key: Date.to_iso8601(w.week), label: week_label(w.week), values: counts(w.counts)}
          end),
        weighted: Enum.map(t.weekly, &week_point(&1, :weighted)),
        moving: Enum.map(t.weekly, &week_point(&1, :moving_avg)),
        weights: Enum.sort(Throughput.weights()),
        unrated_weight: Throughput.unrated_weight(),
        cutover: Throughput.era_cutover()
      )

    ~H"""
    <section id="reports-throughput" class="flex flex-col gap-4">
      <div class="flex flex-col gap-2">
        <h2 class="text-[13px] font-medium">Throughput: tickets closed per week, by difficulty</h2>
        <Charts.stacked_bar
          id="reports-throughput-chart"
          title="Completed tickets per week by difficulty"
          points={@stacked}
          series={@series}
        />
      </div>
      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="flex flex-col gap-2">
          <h2 class="text-[13px] font-medium">Weighted size per week</h2>
          <Charts.step_line
            id="reports-weighted-chart"
            title="Weighted size closed per week"
            points={@weighted}
          />
        </div>
        <div class="flex flex-col gap-2">
          <h2 class="text-[13px] font-medium">Weighted size, 4-week moving average</h2>
          <Charts.step_line
            id="reports-moving-chart"
            title="Weighted size, 4-week moving average"
            color="var(--arb-attention)"
            points={@moving}
          />
        </div>
      </div>
      <p id="reports-weighting-policy" class="text-[12px] text-[var(--text-secondary)]">
        Weighted size = Σ weight per ticket. Weights:
        <span :for={{d, w} <- @weights} class="font-[family-name:var(--font-mono)]">
          D{d} = {w}{if d < 4, do: ",", else: ""}
        </span>
        · unrated (no difficulty) = {@unrated_weight}, as the ticket estimate treats it.
        Weeks start Monday (UTC); reopened tickets count in the week they last closed.
      </p>

      <div class="flex flex-col gap-2">
        <h2 class="text-[13px] font-medium">Lead time (created → closed, in days)</h2>
        <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
          <Charts.stat_tile id="reports-lead-n" label="Tickets" value={@throughput.lead.n} />
          <Charts.stat_tile
            id="reports-lead-p50"
            label="P50"
            value={days(@throughput.lead.p50_hours)}
          />
          <Charts.stat_tile
            id="reports-lead-p90"
            label="P90"
            value={days(@throughput.lead.p90_hours)}
          />
        </div>
        <Charts.histogram
          id="reports-lead-chart"
          title="Lead time distribution"
          buckets={@throughput.lead.buckets}
          unit="d"
        />
        <p id="reports-lead-era" class="text-[12px] text-[var(--text-secondary)]">
          Lifecycle changed on {Date.to_iso8601(@cutover)} (before it, <code>queued</code>
          meant "open"). Closed before: n={@throughput.lead.eras.before.n},
          P50 {days(@throughput.lead.eras.before.p50_hours)}, P90 {days(
            @throughput.lead.eras.before.p90_hours
          )}.
          Closed since: n={@throughput.lead.eras.after.n},
          P50 {days(@throughput.lead.eras.after.p50_hours)}, P90 {days(
            @throughput.lead.eras.after.p90_hours
          )}.
          Percentiles are nearest-rank.
        </p>
      </div>
    </section>
    """
  end

  defp week_label(week), do: Calendar.strftime(week, "%b %d")

  defp week_point(w, field) do
    %{
      key: Date.to_iso8601(w.week),
      label: week_label(w.week),
      value: Float.round(w[field] * 1.0, 2)
    }
  end

  defp counts(counts) do
    Map.new(counts, fn
      {nil, n} -> {:unrated, n}
      {d, n} -> {d, n}
    end)
  end

  defp days(nil), do: "—"
  defp days(hours), do: "#{Float.round(hours / 24, 1)}d"

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true

  defp filter_select(assigns) do
    ~H"""
    <label class="flex flex-col gap-[6px]">
      <span class="font-medium text-[11.5px] text-[var(--arb-text-body)]">{@label}</span>
      <select
        id={@field.id}
        name={@field.name}
        class="h-[var(--control-md)] px-[10px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-field)] text-[12.5px] text-[var(--arb-text-body)]"
      >
        <option value="" selected={@field.value in [nil, ""]}>Any</option>
        <option :for={{text, value} <- @options} value={value} selected={@field.value == value}>
          {text}
        </option>
      </select>
    </label>
    """
  end
end
