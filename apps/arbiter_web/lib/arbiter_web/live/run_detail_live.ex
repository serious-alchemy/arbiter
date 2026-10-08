defmodule ArbiterWeb.RunDetailLive do
  @moduledoc """
  Detail view for a persisted `Arbiter.Workers.Run` at
  `/workers/history/:id` — the post-mortem of a worker after its GenServer
  is gone. Renders the same output-lines pane as the live worker detail
  view, but sourced from the persisted Run row rather than a live snapshot.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Nodes.Overview
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Workers.Run
  alias ArbiterWeb.CoreComponents.Domain
  require Logger

  # bd-ap05jy: `Run` rows carry `output_lines`, a column bd-6jcebm found can
  # run to 141MB for a single row — loading it (plus the workspace lookup and
  # the `Worker.whereis/1` GenServer hop) synchronously in `mount/3` held the
  # dead render *and* the connected one. The dead render now reads nothing
  # and draws the loading state; the connected mount fetches everything via
  # `start_async/3` instead, so a slow read never blocks the socket coming
  # up. A failed read shows an inline error rather than crashing the view;
  # "not found" is a distinct, already-loaded state (`run: nil` with no
  # error), never conflated with "still loading".
  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      socket
      |> assign(:run_id, id)
      |> assign(:worker_label, "worker")
      |> assign(:issue_label, "ticket")
      |> assign(:repo_label, "repo")
      |> assign(:workspace_label, "workspace")
      |> assign(:run, nil)
      |> assign(:workspace, nil)
      |> assign(:live_worker?, false)
      |> assign(:node, nil)
      |> assign(:run_loaded?, false)
      |> assign(:run_error, nil)

    socket =
      if connected?(socket) do
        start_async(socket, :run_data, fn -> __MODULE__.load_run_data(id) end)
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_async(:run_data, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:run, result.run)
     |> assign(:workspace, result.workspace)
     |> assign(:live_worker?, result.live_worker?)
     |> assign(:node, result.node)
     |> assign(:run_loaded?, true)
     |> assign(:run_error, nil)}
  end

  def handle_async(:run_data, {:exit, reason}, socket) do
    Logger.error("RunDetailLive: loading run failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:run_loaded?, true)
     |> assign(:run_error, describe_exit(reason))}
  end

  @doc false
  def load_run_data(id) do
    case Ash.get(Run, id) do
      {:ok, run} ->
        %{
          run: run,
          workspace: lookup_workspace(run.workspace_id),
          live_worker?: !is_nil(Worker.whereis(run.task_id)),
          node: Overview.node_for_run(run.id)
        }

      _ ->
        %{run: nil, workspace: nil, live_worker?: false, node: nil}
    end
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  defp lookup_workspace(nil), do: nil

  defp lookup_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  end

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
        <div
          :if={@run_error}
          id="run-detail-error"
          role="alert"
          class="flex items-start gap-2 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
        >
          <ArbiterWeb.CoreComponents.Core.icon
            name="hero-exclamation-triangle-micro"
            class="size-4 shrink-0 mt-px"
          />
          <span class="grow min-w-0 break-words">
            Could not load this run: {@run_error}
          </span>
        </div>

        <div
          :if={not @run_loaded? and is_nil(@run_error)}
          id="run-detail-loading"
          aria-label="Loading run"
          aria-busy="true"
          class="flex flex-col gap-1.5"
        >
          <div
            :for={n <- 1..4}
            id={"run-detail-loading-#{n}"}
            aria-hidden="true"
            class="h-[34px] rounded-[var(--radius-field)] border border-solid border-[var(--border-strong)] bg-[var(--surface-card)] animate-pulse"
          >
          </div>
        </div>

        <%= if @run_loaded? and is_nil(@run_error) and @run do %>
          <%!-- ── Header ─────────────────────────────────────────────── --%>
          <div class="flex flex-col gap-6">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="min-w-0">
                <div class="flex items-center gap-2 text-[10.5px] text-[var(--text-label)]">
                  <.link
                    navigate={~p"/"}
                    class="text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors"
                  >
                    Dashboard
                  </.link>
                  <ArbiterWeb.CoreComponents.Core.icon name="hero-chevron-right" size={12} />
                  <span>{cap_plural(@worker_label)} history</span>
                </div>
                <h1 class="text-[24px] font-semibold leading-[1.2] tracking-[var(--tracking-section)] text-[var(--text-title)] flex items-center gap-2 mt-1.5">
                  {cap_plural(@worker_label)} run
                  <code class="font-[family-name:var(--font-mono)] text-[16px] font-normal text-[var(--text-secondary)]">
                    {@run.task_id}
                  </code>
                  <ArbiterWeb.CoreComponents.Core.copy_id id={@run.task_id} />
                </h1>
              </div>

              <div class="flex items-center gap-2 flex-none">
                <span
                  class="text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)] bg-[var(--arb-panel)] text-[var(--text-secondary)] font-medium"
                  title="This is a persisted post-mortem, not a live view"
                >
                  <ArbiterWeb.CoreComponents.Core.icon
                    name="hero-archive-box"
                    size={12}
                    class="inline mr-1"
                  /> Historical
                </span>
                <span class={[
                  "text-[10.5px] px-1.5 py-px rounded-[var(--radius-field)] font-medium",
                  run_status_badge_class(ArbiterWeb.StatusHelpers.run_status(@run))
                ]}>
                  {ArbiterWeb.StatusHelpers.run_label(@run)}
                </span>
              </div>
            </div>

            <%!-- ── Run metadata ────────────────────────────────────── --%>
            <div class="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-4">
              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  DURATION
                </span>
                <span class="text-[14px] font-semibold text-[var(--text-title)] font-[family-name:var(--font-mono)]">
                  {humanize_duration(@run.started_at, @run.completed_at)}
                </span>
                <span class="text-[10px] text-[var(--text-secondary)]">wall-clock runtime</span>
              </div>

              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  STARTED
                </span>
                <span class="text-[12px] font-medium text-[var(--text-title)] font-[family-name:var(--font-mono)]">
                  {format_dt(@run.started_at)}
                </span>
                <span class="text-[10px] text-[var(--text-secondary)]">
                  <%= if @run.completed_at do %>
                    ended {format_dt(@run.completed_at)}
                  <% else %>
                    not yet completed
                  <% end %>
                </span>
              </div>

              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  KIND
                </span>
                <span class="text-[12px] font-medium text-[var(--text-title)] font-[family-name:var(--font-mono)] truncate">
                  {ArbiterWeb.StatusHelpers.run_role(@run)}
                </span>
                <span class="text-[10px] text-[var(--text-secondary)]">
                  <%= if @run.model do %>
                    {@run.model}
                  <% else %>
                    no model recorded
                  <% end %>
                </span>
              </div>

              <div class="flex flex-col gap-2 px-3 py-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)]">
                <span class="text-[10.5px] text-[var(--text-label)] font-medium font-[family-name:var(--font-mono)]">
                  PROVIDER
                </span>
                <div class="flex items-center gap-1.5">
                  <.provider_icon :if={@run.provider} provider={@run.provider} class="size-4" />
                  <span class="text-[12px] font-medium text-[var(--text-title)]">
                    <%= if @run.provider do %>
                      {ArbiterWeb.CoreComponents.ProviderIcon.display_name(@run.provider)}
                    <% else %>
                      unknown
                    <% end %>
                  </span>
                </div>
              </div>
            </div>

            <%!-- ── Node (remote runs) ──────────────────────────────── --%>
            <div
              :if={@node}
              id="run-node"
              class="flex items-center gap-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)] px-3 py-2 text-[12px] text-[var(--text-secondary)]"
            >
              <ArbiterWeb.CoreComponents.Core.icon name="hero-server-stack" size={14} />
              Running on node
              <.link
                navigate={~p"/nodes/#{@node.id}"}
                class="font-medium text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors"
              >
                {@node.name}
              </.link>
            </div>

            <div
              :if={is_nil(@node)}
              id="run-node-local"
              class="flex items-center gap-2 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--arb-panel-alt)] px-3 py-2 text-[12px] text-[var(--text-secondary)]"
            >
              <ArbiterWeb.CoreComponents.Core.icon name="hero-server-stack" size={14} />
              Running on <.run_where class="font-medium text-[var(--text-title)]" />
            </div>

            <%!-- ── Live worker link ────────────────────────────────── --%>
            <div
              :if={@live_worker?}
              class="rounded-[var(--radius-field)] bg-[color-mix(in_oklch,var(--arb-live)_10%,transparent)] border border-[color-mix(in_oklch,var(--arb-live)_30%,transparent)] p-3"
            >
              <.link
                navigate={~p"/workers/#{@run.task_id}"}
                class="text-[12px] font-medium text-[var(--arb-live)] hover:text-[var(--text-title)] transition-colors flex items-center gap-1.5 w-fit"
              >
                <ArbiterWeb.CoreComponents.Core.icon name="hero-arrow-top-right-on-square" size={12} />
                Live {@worker_label} for this {@issue_label} is still active
              </.link>
            </div>
          </div>

          <%!-- ── Captured output log stream ──────────────────────────── --%>
          <Domain.log_stream
            id="run-transcript"
            live={false}
            lines={build_log_lines(Arbiter.Workers.OutputOffload.output_lines(@run))}
            max_height="28rem"
          />
        <% end %>

        <%= if @run_loaded? and is_nil(@run_error) and is_nil(@run) do %>
          <ArbiterWeb.CoreComponents.Core.panel>
            <div class="flex flex-col items-center justify-center gap-3 py-12">
              <ArbiterWeb.CoreComponents.Core.icon
                name="hero-archive-box-x-mark"
                size={32}
                color="var(--text-label)"
              />
              <p class="text-[12px] text-[var(--text-secondary)]" id="run-detail-not-found">
                No run found for id <code class="font-mono">{@run_id}</code>.
              </p>
            </div>
          </ArbiterWeb.CoreComponents.Core.panel>
        <% end %>

        <div>
          <.link
            navigate={~p"/"}
            class="text-[12px] font-medium text-[var(--text-link)] hover:text-[var(--text-title)] transition-colors flex items-center gap-1.5 w-fit"
          >
            <ArbiterWeb.CoreComponents.Core.icon name="hero-arrow-left" size={14} /> Back to dashboard
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # Keyed on `StatusHelpers.run_status/1`: a live run's state, a finished
  # run's outcome.
  defp run_status_badge_class(:succeeded),
    do: "bg-[color-mix(in_oklch,var(--arb-done)_20%,transparent)] text-[var(--arb-done)]"

  defp run_status_badge_class(:failed),
    do: "bg-[color-mix(in_oklch,var(--arb-fail)_20%,transparent)] text-[var(--arb-fail-text)]"

  defp run_status_badge_class(:working),
    do: "bg-[color-mix(in_oklch,var(--arb-live)_20%,transparent)] text-[var(--arb-live)]"

  defp run_status_badge_class(:waiting),
    do:
      "bg-[color-mix(in_oklch,var(--arb-attention)_20%,transparent)] text-[var(--arb-attention)]"

  defp run_status_badge_class(_), do: "bg-[var(--arb-panel)] text-[var(--text-secondary)]"

  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  defp format_dt(_), do: ""

  defp humanize_duration(%DateTime{} = started_at, %DateTime{} = ended_at) do
    started_at |> DateTime.diff(ended_at, :second) |> abs() |> humanize_seconds()
  end

  defp humanize_duration(_, _), do: "—"

  defp humanize_seconds(s) when s < 60, do: "#{s}s"
  defp humanize_seconds(s) when s < 3600, do: "#{div(s, 60)}m"
  defp humanize_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp build_log_lines(output_lines) do
    output_lines
    |> Enum.with_index(1)
    |> Enum.map(fn {line, idx} ->
      %{
        time: format_line_time(idx),
        role: "output",
        text: line
      }
    end)
  end

  defp format_line_time(idx) do
    idx
    |> Integer.to_string()
    |> String.pad_leading(5, "0")
  end
end
