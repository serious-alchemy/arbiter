defmodule ArbiterWeb.TrustLive do
  @moduledoc """
  Earned trust at `/trust` (G18, `docs/design/guardrail-profiles.md` §6.5):
  each subject's (`provider/model`) tier, its record over the promotion window,
  its recent guardrail events and any pending promotion proposal. It renders the
  same `Arbiter.Loop.Trust.View` maps as `arb trust show`, `GET /api/trust` and
  MCP `trust_show`, so the surfaces cannot disagree.

  **A view, never a control.** Suspensions and demotions are automatic; the
  coordinator confirms or dismisses a suspension (`arb trust confirm` /
  `arb trust dismiss`); a promotion is the operator's alone, applied from their
  own shell with operator proof (`arb trust promote`). The page names those
  commands and offers no button that runs any of them, so no browser session
  becomes a second promotion path.

  `?subject=provider/model` opens one subject in full. The list and the open
  subject load by `start_async/3` on the connected mount, and again on every
  `{:trust, :updated}` on `Arbiter.Loop.Trust.pubsub_topic/0` (a tick, a
  promotion, a confirmation or a dismissal). A later load supersedes one still
  in flight: `start_async/3` keeps only the newest task's result.
  """

  use ArbiterWeb, :live_view

  require Logger

  alias Arbiter.Loop.Trust
  alias Arbiter.Loop.Trust.View

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Arbiter.PubSub, Trust.pubsub_topic())

    {:ok,
     socket
     |> assign(:page_title, "Trust")
     |> assign(:subject, nil)
     |> assign(:subjects, [])
     |> assign(:detail, nil)
     |> assign(:loaded?, false)
     |> assign(:error, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    subject =
      case params["subject"] do
        s when is_binary(s) -> if String.trim(s) == "", do: nil, else: s
        _ -> nil
      end

    {:noreply, socket |> assign(:subject, subject) |> load()}
  end

  @impl true
  def handle_event("retry", _params, socket),
    do: {:noreply, socket |> assign(:error, nil) |> load()}

  @impl true
  def handle_info({:trust, :updated}, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:trust, {:ok, %{subjects: subjects, detail: detail}}, socket) do
    {:noreply,
     socket
     |> assign(:subjects, subjects)
     |> assign(:detail, detail)
     |> assign(:loaded?, true)
     |> assign(:error, nil)}
  end

  # A read that fails must not take the page down: what was on screen stays,
  # under an error that says so.
  def handle_async(:trust, {:exit, reason}, socket) do
    Logger.error("TrustLive: loading the trust records failed: #{inspect(reason)}")
    {:noreply, assign(socket, :error, describe_exit(reason))}
  end

  defp load(socket) do
    subject = socket.assigns.subject
    start_async(socket, :trust, fn -> load_trust(subject) end)
  end

  @doc false
  # The list, and the open subject as `{requested, detail | :not_found}` so a
  # result is only ever shown under the subject it was read for.
  def load_trust(subject) do
    detail =
      if subject do
        case View.detail(subject) do
          {:ok, detail} -> {subject, detail}
          {:error, :not_found} -> {subject, :not_found}
        end
      end

    %{subjects: View.list(), detail: detail}
  end

  @doc """
  The DOM id of a subject's row. A subject key holds `/` and `.`, so the id is a
  slug of it plus a short hash that keeps two keys with the same slug apart.
  """
  @spec dom_id(String.t()) :: String.t()
  def dom_id(subject) do
    slug = subject |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
    hash = :crypto.hash(:sha256, subject) |> Base.encode16(case: :lower) |> binary_part(0, 6)
    "trust-subject-#{slug}-#{hash}"
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  # ---- presentation ------------------------------------------------------------

  defp list_state(_loaded?, error) when not is_nil(error), do: "error"
  defp list_state(true, nil), do: "loaded"
  defp list_state(false, nil), do: "loading"

  # The open subject, once the read for *it* has landed.
  defp open_detail({subject, %{} = detail}, subject), do: detail
  defp open_detail(_detail, _subject), do: nil

  defp missing?({subject, :not_found}, subject), do: true
  defp missing?(_detail, _subject), do: false

  defp tier_class("quarantine"),
    do:
      "bg-[var(--arb-attention-wash)] text-[var(--arb-attention)] border-[var(--arb-attention-edge)]"

  defp tier_class("probation"),
    do: "bg-[var(--arb-info-wash)] text-[var(--arb-info)] border-[var(--arb-info-edge)]"

  defp tier_class("trusted"),
    do: "bg-[var(--arb-live-wash)] text-[var(--arb-live)] border-[var(--arb-live-edge)]"

  defp tier_class("privileged"),
    do:
      "bg-[var(--arb-proposal-wash)] text-[var(--arb-proposal)] border-[var(--arb-proposal-edge)]"

  defp tier_class("suspended"),
    do: "bg-[var(--arb-fail-wash)] text-[var(--arb-fail-text)] border-[var(--arb-fail-edge)]"

  defp tier_class(_none),
    do: "bg-[var(--arb-done-wash)] text-[var(--text-secondary)] border-[var(--arb-done-edge)]"

  defp severity_class("critical"), do: tier_class("suspended")
  defp severity_class("major"), do: tier_class("quarantine")
  defp severity_class(_minor), do: tier_class(nil)

  # The row's one-line verdict, in `arb trust show`'s order of precedence.
  defp status(%{suspended: %{} = s, effective_tier: eff}),
    do: {"suspended", "suspended (#{s.kind}) · treated as #{eff}"}

  defp status(%{pending: [%{to: to} | _]}), do: {"proposed", "promotion to #{to} proposed"}

  defp status(%{eligibility: %{eligible_for: to}}) when is_binary(to),
    do: {"eligible", "eligible for #{to}"}

  defp status(%{pinned: true}), do: {"pinned", "pinned"}
  defp status(_subject), do: {"none", "—"}

  defp status_kind(subject), do: subject |> status() |> elem(0)
  defp status_text(subject), do: subject |> status() |> elem(1)

  defp status_class("suspended"), do: "text-[var(--arb-fail-text)]"
  defp status_class("proposed"), do: "text-[var(--arb-proposal)]"
  defp status_class("eligible"), do: "text-[var(--arb-live)]"
  defp status_class(_other), do: "text-[var(--text-label)]"

  defp events_class(%{critical_events: c}) when c > 0, do: "text-[var(--arb-fail-text)]"
  defp events_class(%{major_events: m}) when m > 0, do: "text-[var(--arb-attention)]"
  defp events_class(_record), do: "text-[var(--text-secondary)]"

  defp pct(q) when is_number(q), do: "#{Float.round(q * 100 / 1, 1)}%"
  defp pct(_q), do: "—"

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n || 0} #{noun}s"

  defp when_text(nil), do: "—"

  defp when_text(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M UTC")

  defp when_text(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _offset} -> when_text(dt)
      _ -> text
    end
  end

  defp value(nil), do: "—"
  defp value(v) when is_float(v), do: v |> Float.round(3) |> to_string()
  defp value(v) when is_binary(v) or is_number(v) or is_atom(v), do: to_string(v)
  defp value(v), do: Jason.encode!(v)

  defp criterion_text(%{"detail" => detail}) when is_binary(detail), do: detail
  defp criterion_text(c), do: "#{value(c["have"])} of #{value(c["need"])}"

  # Newest first; each entry's own fields beyond when, what and who.
  defp history_entries(history) do
    history
    |> Enum.reverse()
    |> Enum.map(fn h ->
      extra =
        h
        |> Map.drop(~w(at action actor))
        |> Enum.sort()
        |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{value(v)}" end)

      %{at: h["at"], action: h["action"], actor: h["actor"], extra: extra}
    end)
  end

  defp promote_command(subject, to),
    do: ~s(arb trust promote #{subject} --to #{to} --reason "...")

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:open, open_detail(assigns.detail, assigns.subject))
      |> assign(:missing?, missing?(assigns.detail, assigns.subject))

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
      <div id="trust-page" class="p-4 sm:p-6 max-w-7xl mx-auto space-y-6">
        <ArbiterWeb.CoreComponents.Domain.index_header
          icon="hero-shield-check"
          title="Trust"
          count={if(@loaded?, do: length(@subjects))}
          subtitle="Earned trust per subject (provider/model): its tier, its record over the promotion window, recent guardrail events and any promotion the Loop proposes. Suspensions and demotions are automatic; a promotion is the operator's, from arb trust promote."
        >
          <:actions>
            <ArbiterWeb.CoreComponents.Feedback.live_badge live={@live} />
          </:actions>
        </ArbiterWeb.CoreComponents.Domain.index_header>

        <div
          id="trust-list-panel"
          data-state={list_state(@loaded?, @error)}
          aria-busy={to_string(not @loaded? and is_nil(@error))}
        >
          <.panel padded={false}>
            <div
              :if={@error}
              id="trust-error"
              role="alert"
              class="flex items-start gap-2 m-3 px-3 py-2.5 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12px] text-[var(--arb-fail-text)]"
            >
              <.icon name="hero-exclamation-triangle-micro" class="size-4 shrink-0 mt-px" />
              <span class="grow min-w-0 break-words">
                Could not load the trust records: {@error}<span :if={@loaded?}> — showing the last list that loaded.</span>
              </span>
              <button
                type="button"
                id="trust-retry"
                phx-click="retry"
                class="shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)] text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
              >
                Retry
              </button>
            </div>

            <div
              :if={not @loaded? and is_nil(@error)}
              id="trust-loading"
              aria-label="Loading the trust records"
              class="flex flex-col gap-1.5 p-3"
            >
              <div
                :for={n <- 1..3}
                id={"trust-loading-#{n}"}
                aria-hidden="true"
                class="h-[44px] rounded-[var(--radius-field)] bg-[var(--arb-panel-alt)] animate-pulse"
              >
              </div>
            </div>

            <div :if={@loaded? and @subjects == []} id="trust-empty" class="p-3">
              <ArbiterWeb.CoreComponents.Feedback.empty_state
                icon="hero-shield-check"
                detail="the Loop folds a record for every subject that runs, on the canary ticker"
              >
                No trust records yet.
              </ArbiterWeb.CoreComponents.Feedback.empty_state>
            </div>

            <div :if={@loaded? and @subjects != []} class="w-full overflow-x-auto">
              <table id="trust-subjects" class="w-full min-w-[760px] border-collapse text-left">
                <thead>
                  <tr class="h-[30px] bg-[var(--arb-chrome)] text-[10.5px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                    <th class="px-[14px] font-normal">Subject</th>
                    <th class="px-2 font-normal">Tier</th>
                    <th class="px-2 font-normal">Record</th>
                    <th class="px-2 font-normal" title="critical / major / minor guardrail events">
                      Events c/M/m
                    </th>
                    <th class="px-2 font-normal" title="round-1 approve rate">Round 1</th>
                    <th class="px-2 font-normal">Status</th>
                    <th class="px-[14px] font-normal"><span class="sr-only">Open</span></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={s <- @subjects}
                    id={dom_id(s.subject)}
                    data-subject={s.subject}
                    aria-current={if(s.subject == @subject, do: "true")}
                    class={[
                      "border-t border-[var(--arb-line-soft)] transition-colors",
                      "hover:bg-[var(--arb-raised-hover)]",
                      s.subject == @subject && "bg-[var(--arb-raised-hover)]"
                    ]}
                  >
                    <td class="px-[14px] py-2 min-w-0">
                      <div class="flex items-center gap-1.5 font-[family-name:var(--font-mono)] text-[12px] text-[var(--text-title)] break-all">
                        {s.subject}
                        <.icon
                          :if={s.pinned}
                          name="hero-lock-closed-micro"
                          size={12}
                          color="var(--text-label)"
                          class="shrink-0"
                        />
                      </div>
                      <div :if={s.family} class="text-[11px] text-[var(--text-label)]">
                        {s.family}
                      </div>
                    </td>
                    <td class="px-2 py-2" data-role="tier">
                      <span class={[
                        "inline-flex items-center h-[20px] px-[7px] rounded-[var(--radius-pill)] border border-solid text-[11px] font-medium",
                        tier_class(s.tier)
                      ]}>
                        {s.tier || "no rule"}
                      </span>
                    </td>
                    <td
                      class="px-2 py-2 font-[family-name:var(--font-mono)] tabular-nums text-[11.5px] text-[var(--text-secondary)]"
                      data-role="record"
                    >
                      <div>{s.record.clean_runs}/{s.record.runs} clean</div>
                      <div class="text-[10.5px] text-[var(--text-label)]">
                        {count(s.record.clean_tickets, "ticket")} · {count(
                          s.record.clean_repos,
                          "repo"
                        )}
                      </div>
                    </td>
                    <td
                      class={[
                        "px-2 py-2 font-[family-name:var(--font-mono)] tabular-nums text-[11.5px]",
                        events_class(s.record)
                      ]}
                      data-role="events"
                    >
                      {s.record.critical_events}/{s.record.major_events}/{s.record.minor_events}
                    </td>
                    <td
                      class="px-2 py-2 font-[family-name:var(--font-mono)] tabular-nums text-[11.5px] text-[var(--text-secondary)]"
                      data-role="round1"
                    >
                      <div>{pct(s.record.round1_approve_rate)}</div>
                      <div class="text-[10.5px] text-[var(--text-label)]">
                        {s.record.reviewed} reviewed
                      </div>
                    </td>
                    <td
                      class={["px-2 py-2 text-[11.5px]", status_class(status_kind(s))]}
                      data-role="status"
                      data-status={status_kind(s)}
                    >
                      {status_text(s)}
                    </td>
                    <td class="px-[14px] py-2 text-right">
                      <.link
                        patch={~p"/trust?#{[subject: s.subject]}"}
                        data-role="open"
                        class="inline-flex items-center gap-1 h-[var(--control-sm)] px-[10px] rounded-[var(--radius-field)] border border-solid border-transparent text-[11.5px] font-medium text-[var(--text-secondary)] hover:bg-[var(--surface-card)] hover:text-[var(--text-title)] transition-[background,color]"
                      >
                        Review <.icon name="hero-chevron-right-micro" size={12} />
                      </.link>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.panel>
        </div>

        <div
          :if={@missing?}
          id="trust-detail-missing"
          class="flex items-center justify-between gap-3 px-4 py-3 rounded-[var(--radius-panel)] border border-dashed border-[var(--border-strong)] text-[12.5px] text-[var(--text-secondary)]"
        >
          <span>
            No trust record for <span class="font-[family-name:var(--font-mono)]">{@subject}</span>.
            A subject is provider/model, and gets a record once it has run.
          </span>
          <.link
            patch={~p"/trust"}
            class="text-[11.5px] text-[var(--text-secondary)] hover:text-[var(--text-title)]"
          >
            Close
          </.link>
        </div>

        <.panel :if={@open} id="trust-detail" title={@open.subject} meta={@open.family}>
          <:actions>
            <.link
              id="trust-detail-close"
              patch={~p"/trust"}
              class="inline-flex items-center h-[var(--control-sm)] px-[10px] rounded-[var(--radius-field)] text-[11.5px] font-medium text-[var(--text-secondary)] hover:bg-[var(--surface-card)] hover:text-[var(--text-title)] transition-[background,color]"
            >
              Close
            </.link>
          </:actions>

          <div class="space-y-5">
            <dl class="grid grid-cols-2 sm:grid-cols-4 gap-x-4 gap-y-3 text-xs">
              <div>
                <dt class="text-[var(--text-label)]">Tier</dt>
                <dd class="mt-1 flex flex-wrap items-center gap-1.5">
                  <span class={[
                    "inline-flex items-center h-[20px] px-[7px] rounded-[var(--radius-pill)] border border-solid text-[11px] font-medium",
                    tier_class(@open.tier)
                  ]}>
                    {@open.tier || "no rule"}
                  </span>
                  <span
                    :if={@open.suspended}
                    class={[
                      "inline-flex items-center h-[20px] px-[7px] rounded-[var(--radius-pill)] border border-solid text-[11px] font-medium",
                      tier_class("suspended")
                    ]}
                  >
                    suspended → {@open.effective_tier}
                  </span>
                  <span :if={@open.pinned} class="text-[11px] text-[var(--text-label)]">pinned</span>
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">At this tier since</dt>
                <dd class="mt-1 font-mono text-[var(--text-secondary)]">
                  {when_text(@open.record.tier_since)}
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Promotion clock since</dt>
                <dd class="mt-1 font-mono text-[var(--text-secondary)]">
                  {when_text(@open.record.clock_started_at)}
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Last run</dt>
                <dd class="mt-1 font-mono text-[var(--text-secondary)]">
                  {when_text(@open.record.last_run_at)}
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Record ({@open.record.window_days}d)</dt>
                <dd class="mt-1 font-mono text-[var(--text-secondary)]">
                  {@open.record.clean_runs}/{@open.record.runs} clean runs on {count(
                    @open.record.clean_tickets,
                    "ticket"
                  )}, {count(@open.record.clean_repos, "repo")}
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Guardrail events</dt>
                <dd class={["mt-1 font-mono", events_class(@open.record)]}>
                  {@open.record.critical_events} critical · {@open.record.major_events} major · {@open.record.minor_events} minor
                </dd>
              </div>
              <div>
                <dt class="text-[var(--text-label)]">Round-1 approve rate</dt>
                <dd class="mt-1 font-mono text-[var(--text-secondary)]">
                  {pct(@open.record.round1_approve_rate)} over {@open.record.reviewed} reviewed
                </dd>
              </div>
              <div id="trust-versions">
                <dt class="text-[var(--text-label)]">Versions</dt>
                <dd class="mt-1 font-mono text-[var(--text-secondary)] break-all">
                  harness {@open.versions.harness || "—"} · model {@open.versions.model || "—"}
                </dd>
              </div>
            </dl>

            <section
              :if={@open.suspended}
              id="trust-suspension"
              class="rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-fail)] bg-[var(--arb-fail-wash)] px-[13px] py-[11px] space-y-2"
            >
              <p class="flex items-start gap-1.5 text-[12.5px] font-medium text-[var(--arb-fail-text)]">
                <.icon name="hero-no-symbol-micro" size={14} class="mt-px shrink-0" />
                Suspended since {when_text(@open.suspended.at)} after a critical guardrail event
              </p>
              <dl class="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[11.5px]">
                <dt class="text-[var(--text-label)]">Event</dt>
                <dd class="font-mono text-[var(--text-secondary)] break-all">
                  {@open.suspended.kind} ({@open.suspended.severity || "critical"}) on run {@open.suspended.run_id ||
                    "?"}, ticket {@open.suspended.task_id || "?"}
                </dd>
                <dt :if={@open.suspended.detail} class="text-[var(--text-label)]">Detail</dt>
                <dd
                  :if={@open.suspended.detail}
                  class="font-mono text-[var(--text-secondary)] break-all"
                >
                  {@open.suspended.detail}
                </dd>
                <dt class="text-[var(--text-label)]">Parked</dt>
                <dd class="font-mono text-[var(--text-secondary)] break-all">
                  {if(@open.suspended.parked == [],
                    do: "no run of it was in flight",
                    else: Enum.join(@open.suspended.parked, ", ")
                  )}
                </dd>
              </dl>
              <p class="text-[11.5px] text-[var(--text-secondary)]">
                It is treated as {@open.effective_tier} and takes no work in any role until the coordinator decides:
              </p>
              <pre class="text-[11.5px] bg-[var(--arb-canvas-sunken)] rounded-[var(--radius-field)] px-3 py-2 overflow-x-auto"><code>arb trust confirm {@open.subject}{"\n"}arb trust dismiss {@open.subject} --reason "..."</code></pre>
              <p class="text-[11px] text-[var(--text-label)]">
                Confirm lets the demotion to quarantine stand; dismiss records a false positive and the {@open.suspended.prior_tier ||
                  @open.tier} tier returns.
              </p>
            </section>

            <section id="trust-pending" class="space-y-2">
              <h3 class="text-[11px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                Pending promotion
              </h3>
              <p :if={@open.pending == []} class="text-[12px] text-[var(--text-secondary)]">
                None. The Loop proposes one when every §6.3 threshold holds; it never proposes trusted → privileged.
              </p>
              <div
                :for={p <- @open.pending}
                id={"trust-proposal-#{p.id}"}
                class="rounded-[var(--radius-field)] border border-solid border-[var(--arb-proposal-edge)] border-l-[length:var(--border-accent-width)] border-l-[color:var(--arb-proposal)] bg-[var(--arb-proposal-wash)] px-[13px] py-[11px] space-y-2"
              >
                <p class="text-[12.5px] font-medium text-[var(--text-title)]">
                  {p.from} → {p.to}: {count(p.evidence_count, "clean run")} across {count(
                    p.distinct_tasks,
                    "ticket"
                  )}
                </p>
                <p class="text-[11px] font-mono text-[var(--text-label)] break-all">
                  proposal {p.id} · {p.state} · {when_text(p.created_at)}
                </p>
                <p class="text-[11.5px] text-[var(--text-secondary)]">
                  Operator-only: a promotion loosens this subject's guardrails, so the coordinator cannot apply it, and nor can arb loop apply or this page. The operator applies it from their own shell:
                </p>
                <pre class="text-[11.5px] bg-[var(--arb-canvas-sunken)] rounded-[var(--radius-field)] px-3 py-2 overflow-x-auto"><code>{promote_command(@open.subject, p.to)}</code></pre>
              </div>
            </section>

            <section id="trust-eligibility" class="space-y-2">
              <h3 class="text-[11px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                Eligibility
              </h3>
              <p
                :if={is_binary(@open.eligibility["to"])}
                class="text-[12px] text-[var(--text-secondary)]"
              >
                {@open.eligibility["from"]} → {@open.eligibility["to"]}
                <span :if={@open.eligibility.eligible_for} class="text-[var(--arb-live)]">
                  · eligible
                </span>
                <span :if={@open.eligibility["blocked_by"]} class="text-[var(--arb-attention)]">
                  · blocked: {@open.eligibility["blocked_by"]}
                </span>
              </p>
              <p :if={@open.eligibility["note"]} class="text-[12px] text-[var(--text-secondary)]">
                {@open.eligibility["note"]}
              </p>
              <p
                :if={!is_binary(@open.eligibility["to"]) and !@open.eligibility["note"]}
                class="text-[12px] text-[var(--text-secondary)]"
              >
                Not judged yet: the Loop judges it on its next fold.
              </p>
              <ul :if={(@open.eligibility["criteria"] || []) != []} class="space-y-1">
                <li
                  :for={c <- @open.eligibility["criteria"] || []}
                  class="flex items-start gap-2 text-[11.5px]"
                >
                  <.icon
                    :if={c["met"]}
                    name="hero-check-circle-micro"
                    size={14}
                    color="var(--arb-live)"
                    class="mt-px shrink-0"
                  />
                  <.icon
                    :if={!c["met"]}
                    name="hero-x-circle-micro"
                    size={14}
                    color="var(--arb-fail-text)"
                    class="mt-px shrink-0"
                  />
                  <span class="font-mono text-[var(--text-title)]">{c["name"]}</span>
                  <span class="text-[var(--text-secondary)] break-words">{criterion_text(c)}</span>
                </li>
              </ul>
            </section>

            <section id="trust-recent-events" class="space-y-2">
              <h3 class="text-[11px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                Recent guardrail events
              </h3>
              <p :if={@open.recent_events == []} class="text-[12px] text-[var(--text-secondary)]">
                None in the window.
              </p>
              <ul :if={@open.recent_events != []} class="flex flex-col gap-1.5">
                <li
                  :for={e <- @open.recent_events}
                  class="rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-card)] px-3 py-2 space-y-1"
                >
                  <div class="flex flex-wrap items-center gap-1.5 text-[11.5px]">
                    <span class={[
                      "inline-flex items-center h-[18px] px-[6px] rounded-[var(--radius-pill)] border border-solid text-[10.5px] font-medium",
                      severity_class(e["severity"])
                    ]}>
                      {e["severity"]}
                    </span>
                    <span class="font-mono text-[var(--text-title)]">{e["kind"]}</span>
                    <span :if={e["source"]} class="text-[var(--text-label)]">{e["source"]}</span>
                    <span class="ml-auto font-mono text-[10.5px] text-[var(--text-label)]">
                      {when_text(e["at"])}
                    </span>
                  </div>
                  <p class="font-mono text-[10.5px] text-[var(--text-label)] break-all">
                    run {e["run_id"] || "?"} · ticket {e["task_id"] || "?"}
                  </p>
                  <p
                    :if={e["detail"]}
                    class="font-mono text-[11px] text-[var(--text-secondary)] break-all"
                  >
                    {e["detail"]}
                  </p>
                </li>
              </ul>
            </section>

            <section id="trust-history" class="space-y-2">
              <h3 class="text-[11px] uppercase tracking-[0.06em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                History
              </h3>
              <p :if={@open.history == []} class="text-[12px] text-[var(--text-secondary)]">
                Nothing has been done to this subject yet.
              </p>
              <ol :if={@open.history != []} class="flex flex-col gap-1">
                <li :for={h <- history_entries(@open.history)} class="text-[11.5px] break-words">
                  <span class="font-mono text-[10.5px] text-[var(--text-label)]">
                    {when_text(h.at)}
                  </span>
                  <span class="font-medium text-[var(--text-title)]">{h.action}</span>
                  <span class="text-[var(--text-label)]">by {h.actor || "—"}</span>
                  <span
                    :if={h.extra != ""}
                    class="font-mono text-[10.5px] text-[var(--text-secondary)]"
                  >
                    · {h.extra}
                  </span>
                </li>
              </ol>
            </section>
          </div>
        </.panel>

        <ArbiterWeb.CoreComponents.Navigation.back_link />
      </div>
    </Layouts.app>
    """
  end
end
