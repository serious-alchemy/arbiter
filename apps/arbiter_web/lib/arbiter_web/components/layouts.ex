defmodule ArbiterWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use ArbiterWeb, :html
  import ArbiterWeb.QuotaHelpers

  alias Arbiter.Messages.Message
  alias Phoenix.LiveView.AsyncResult

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_path, :string,
    default: nil,
    doc: "request path of the current page, used to highlight the active nav link"
  )

  attr(:quotas, :any,
    default: [],
    doc:
      "One AnthropicQuota struct per tracked provider — a list, or the `AsyncResult` of one ArbiterWeb.LiveHooks' :quota hook loads"
  )

  attr(:live, :boolean,
    default: false,
    doc:
      "socket-connected state from ArbiterWeb.LiveHooks' :live on_mount; false (never live) for dead controller renders that skip the hook"
  )

  attr(:quota_on_exhaustion, :any,
    default: nil,
    doc:
      "the installation default workspace's mode, from ArbiterWeb.LiveHooks' :quota assign; nil until it loads"
  )

  attr(:coordinator_inbox, :any,
    default: [],
    doc:
      "unread mailbox-family messages addressed to the coordinator — a list, or the `AsyncResult` of one ArbiterWeb.LiveHooks loads"
  )

  attr(:coordinator_outstanding_count, :integer,
    default: 0,
    doc: "seen-but-not-cleared coordinator messages — the triage queue"
  )

  attr(:coordinator_inbox_now, DateTime,
    default: nil,
    doc: "drives the drawer's relative timestamps (ArbiterWeb.LiveHooks)"
  )

  attr(:open_epic_count, :integer,
    default: nil,
    doc:
      "the Epics nav badge, from ArbiterWeb.LiveHooks' :open_epics assign; nil renders no badge"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    # Nothing here touches the DB: this renders on every page and on every
    # re-render, so the values arrive as assigns from `ArbiterWeb.LiveHooks`
    # (`:quota` loads `quota_on_exhaustion`, `:open_epics` keeps
    # `open_epic_count` fresh off PubSub) and are passed in by the page
    # (bd-cixhhs). A caller that omits them gets the global default / no badge.
    assigns =
      assigns
      |> assign(:quotas, as_async(assigns.quotas))
      |> assign(:coordinator_inbox, as_async(assigns.coordinator_inbox))

    assigns =
      assign(
        assigns,
        :groups,
        ArbiterWeb.Nav.groups(assigns.open_epic_count)
      )

    # One GenServer call to `UpdateCheck`, which answers from memory (the HTTP
    # fetch runs in its own task) and reports "disabled" when it isn't running.
    assigns = assign(assigns, :update, Arbiter.Release.UpdateCheck.state())

    # The last `arb server deploy`'s own record (a tiny file the CLI keeps, so it
    # survives the restart the deploy causes) — progress while it runs, the
    # outcome once the server is back.
    assigns = assign(assigns, :deploy, Arbiter.Release.DeployStatus.read())

    assigns =
      assign(assigns, :coordinator_inbox_now, assigns.coordinator_inbox_now || DateTime.utc_now())

    ~H"""
    <%!-- The status bar (bd-d63b1c): the wordmark and the right-hand cluster,
          and nothing else — the links moved to the rail. It sticks to the top
          of the viewport because everything `position: fixed` below it (the
          rail, the dock's Side and Max windows) is measured from
          `--nav-height`, so a bar that scrolled away would leave a gap above
          all three. --%>
    <header
      id="app-status-bar"
      class="sticky top-0 z-20 flex items-center gap-3 sm:gap-[18px] h-[var(--nav-height)] px-3 sm:px-4 bg-[var(--surface-chrome)] border-b border-solid border-[var(--border-default)]"
    >
      <button
        type="button"
        id="nav-rail-toggle"
        aria-label="Menu"
        aria-controls="nav-rail"
        aria-expanded="false"
        phx-mounted={JS.ignore_attributes(["aria-expanded"])}
        phx-click={JS.dispatch("nav-rail:toggle")}
        class="lg:hidden -ml-1 flex flex-none items-center justify-center size-[30px] rounded-[var(--radius-field)] cursor-pointer text-[var(--text-secondary)] transition-colors duration-150 hover:bg-[var(--arb-raised-hover)] hover:text-[var(--text-title)]"
      >
        <ArbiterWeb.CoreComponents.Core.icon name="hero-bars-3" size={20} />
      </button>

      <span
        class="flex-none max-sm:hidden"
        aria-label="Arbiter"
        title={ArbiterWeb.VersionHelper.get_tooltip()}
      >
        <.brandmark form="wordmark" size={120} tone="accent" />
      </span>
      <%!-- The wordmark's 120px minimum width doesn't fit the status bar
            below `sm` alongside the rail toggle and the right-hand cluster
            (it overflowed the viewport by a few px at 375/414 — bd-bcroux);
            the icon form is the mark's own fallback for that width, not a
            one-off pixel hack. --%>
      <span
        class="flex-none sm:hidden"
        aria-label="Arbiter"
        title={ArbiterWeb.VersionHelper.get_tooltip()}
      >
        <.brandmark form="icon" size={26} tone="accent" />
      </span>

      <div class="ml-auto flex flex-none items-center gap-2 sm:gap-4">
        <%!-- The quota chip (bd-i2gwwn): one object per provider the
              installation uses — its logo inside two concentric rings, the
              5h window inner and the 7d outer — in a single 36px control
              whose height doesn't change with the provider count (each
              provider costs 38px of width, not a row of height). It opens
              the popover with the full bars. Loaded off the mount
              (bd-adewb4): a chip-sized placeholder until it lands, an inline
              notice if it fails. --%>
        <div
          :if={@quotas.loading}
          id="quota-topbar-loading"
          role="status"
          aria-label="Loading quota"
          class="max-sm:hidden flex flex-none items-center gap-[6px] h-[36px] px-[6px] rounded-[var(--radius-field)] border border-solid border-[var(--border-default)]"
        >
          <span class="size-[32px] rounded-full border-[2.5px] border-solid border-[var(--border-default)] animate-pulse">
          </span>
        </div>
        <button
          :if={@quotas.failed}
          type="button"
          id="quota-topbar-error"
          phx-click="quota_retry"
          title={"Could not load quota: #{async_error(@quotas.failed)} — click to retry"}
          class="max-sm:hidden flex items-center gap-1.5 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--arb-fail-text)] transition-colors duration-150 hover:bg-[var(--surface-chrome)]"
        >
          <ArbiterWeb.CoreComponents.Core.icon
            name="hero-exclamation-triangle-micro"
            class="size-3.5 shrink-0"
          /> quota unavailable
        </button>
        <.quota_chip
          :if={quota_bars?(@quotas)}
          quotas={@quotas.result}
          on_exhaustion={@quota_on_exhaustion}
        />
        <ArbiterWeb.CoreComponents.Feedback.live_badge id="appshell-live" live={@live} />
        <.coordinator_inbox_trigger inbox={@coordinator_inbox} />
      </div>
    </header>

    <%!-- The nav rail (bd-d63b1c). One `sidebar_nav/1` tree, always rendered
          expanded, inside a `position: fixed` column whose *width* is the only
          thing that changes — `app.css` ("the nav rail") clips it to the icon
          column when collapsed and hides the labels and headers there. So:

          * hovering the collapsed rail widens this column over the page; it is
            `fixed`, out of `<main>`'s flow, and no inset rule mentions
            `:hover`, so nothing reflows;
          * pinning (the `NavRail` hook, `<html data-nav-rail="pinned">`)
            widens it *and* the page inset, so the page makes room instead;
          * below `lg` it is hidden and the page takes the full width, until
            the status bar's hamburger opens it as an overlay
            (`<html data-nav-rail-open>`).

          It is one tree rather than a collapsed rail plus an expanded float so
          the page has exactly one `aria-current` item, and so a label is always
          in the accessibility tree even when it is clipped out of sight.
          `z-20` keeps it under the dock (`z-30`) and the coordinator drawer
          (`z-40` backdrop, `z-50` drawer). --%>
    <div
      id="nav-rail-backdrop"
      class="nav-rail-backdrop fixed inset-0 top-[var(--nav-height)] z-10 bg-black/30"
      phx-click={JS.dispatch("nav-rail:close")}
      aria-hidden="true"
    >
    </div>

    <div
      id="nav-rail"
      phx-hook="NavRail"
      class="nav-rail fixed left-0 top-[var(--nav-height)] bottom-[var(--session-dock-strip-height)] z-20"
    >
      <.sidebar_nav groups={@groups} current_path={@current_path} expanded={true}>
        <:footer>
          <div class="flex min-w-0 flex-col gap-1">
            <.link
              id="about-link"
              navigate={~p"/about"}
              title="About: version and update status"
              class="flex items-center whitespace-nowrap rounded-[var(--radius-field)] py-1.5 text-xs text-[var(--text-label)] no-underline transition-colors duration-150 hover:text-[var(--text-title)]"
            >
              <%!-- A 40px icon cell puts the icon on the collapsed rail's centre line, and
                    the label's margin starts it past the 56px clip, as a nav item's does. --%>
              <span class="flex w-10 flex-none justify-center">
                <.icon name="hero-information-circle" size={14} />
              </span>
              <span class="ml-3">About</span>
              <span class="ml-3">v{Arbiter.Version.app_version()}</span>
            </.link>
            <.theme_toggle />
          </div>
        </:footer>
      </.sidebar_nav>
    </div>

    <%!-- The room the page's two fixed edges are taking, each zero unless
          something is actually occupying it (bd-2qqqbp): on the right a
          Side-panel session window (bd-covojz), zero at every other dock size;
          on the left the nav rail. Both are `position: fixed`, so without
          these the page would simply slide underneath them — and reading a
          page while talking to a session is the whole reason the Side preset
          exists. --%>
    <main class="pl-[var(--nav-rail-page-inset)] pr-[var(--session-dock-page-inset)]">
      <.update_notice
        update={@update}
        deploy={@deploy}
        dismissed={dismissed_update(@update, @current_path)}
      />
      {render_slot(@inner_block)}
    </main>

    <.coordinator_inbox_drawer
      inbox={@coordinator_inbox}
      outstanding_count={@coordinator_outstanding_count}
      now={@coordinator_inbox_now}
    />

    <.toast_group flash={@flash} />
    """
  end

  attr(:inbox, AsyncResult, required: true)

  defp coordinator_inbox_trigger(assigns) do
    assigns = assign(assigns, :unread, length(inbox_messages(assigns.inbox)))

    ~H"""
    <button
      type="button"
      id="coordinator-inbox-trigger"
      aria-label="Coordinator mailbox"
      phx-click={
        JS.toggle(to: "#coordinator-drawer-backdrop")
        |> JS.toggle(to: "#coordinator-drawer", display: "flex")
      }
      class="relative flex items-center justify-center size-[30px] rounded-[var(--radius-pill)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] cursor-pointer"
    >
      <ArbiterWeb.CoreComponents.Core.icon name="hero-inbox-micro" color="var(--text-secondary)" />
      <span
        :if={@inbox.failed}
        id="coordinator-inbox-error-badge"
        title="Could not load the coordinator mailbox"
        class="absolute -top-1 -right-1 min-w-[16px] h-[16px] px-1 rounded-[var(--radius-pill)] bg-[var(--arb-fail)] text-[9.5px] leading-[16px] text-center font-[family-name:var(--font-mono)] text-[var(--surface-chrome)]"
      >
        !
      </span>
      <span
        :if={!@inbox.failed && @unread > 0}
        id="coordinator-inbox-unread-badge"
        class="absolute -top-1 -right-1 min-w-[16px] h-[16px] px-1 rounded-[var(--radius-pill)] bg-[var(--arb-attention)] text-[9.5px] leading-[16px] text-center font-[family-name:var(--font-mono)] text-[var(--surface-chrome)]"
      >
        {@unread}
      </span>
    </button>
    """
  end

  attr(:inbox, AsyncResult, required: true)
  attr(:outstanding_count, :integer, required: true)
  attr(:now, DateTime, required: true)

  # The coordinator's mailbox — the upward channel of `arb inbox` / `arb msg`,
  # live — as an AppShell drawer rather than a board-only panel (bd-3kgb0e).
  # It is not scoped to any one screen because none of the mail in it is
  # scoped to any one screen either.
  defp coordinator_inbox_drawer(assigns) do
    assigns = assign(assigns, :messages, inbox_messages(assigns.inbox))

    ~H"""
    <div
      id="coordinator-drawer-backdrop"
      class="hidden fixed inset-0 bg-black/30 z-40"
      phx-click={JS.hide(to: "#coordinator-drawer-backdrop") |> JS.hide(to: "#coordinator-drawer")}
    >
    </div>

    <aside
      id="coordinator-drawer"
      class="hidden fixed right-0 top-0 h-full w-full max-w-sm z-50 flex flex-col border-l border-solid border-[var(--border-default)] bg-[var(--surface-card)] shadow-xl"
    >
      <div class="flex items-center justify-between gap-2 px-4 h-[var(--toolbar-height)] border-b border-solid border-[var(--border-default)] bg-[var(--arb-canvas-sunken)]">
        <h2 class="flex items-center gap-2 text-[12.5px] font-medium text-[var(--text-title)]">
          Coordinator Mailbox
          <span
            :if={@inbox.ok? && !@inbox.failed}
            class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--arb-attention)]"
          >
            {length(@messages)} unread
          </span>
          <span
            :if={@inbox.ok? && !@inbox.failed}
            id="coordinator-mailbox-outstanding"
            title="Seen but not yet cleared — the triage queue"
            class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-label)]"
          >
            {@outstanding_count} outstanding
          </span>
        </h2>
        <div class="flex items-center gap-3 shrink-0">
          <button
            type="button"
            phx-click="coordinator_clear"
            title="Soft-clear the outstanding tail — already-read mail is marked cleared (retained), unread is kept"
            class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)] cursor-pointer"
          >
            clear read
          </button>
          <button
            type="button"
            aria-label="Close mailbox"
            phx-click={
              JS.hide(to: "#coordinator-drawer-backdrop") |> JS.hide(to: "#coordinator-drawer")
            }
            class="cursor-pointer"
          >
            <ArbiterWeb.CoreComponents.Core.icon
              name="hero-x-mark-micro"
              color="var(--text-secondary)"
            />
          </button>
        </div>
      </div>

      <%!-- Loaded off the mount (bd-adewb4). --%>
      <p
        :if={@inbox.loading}
        id="coordinator-mailbox-loading"
        role="status"
        class="flex items-center gap-2 px-4 py-4 text-[12px] text-[var(--text-secondary)]"
      >
        <ArbiterWeb.CoreComponents.Core.icon
          name="hero-arrow-path-micro"
          class="size-4 shrink-0 animate-spin"
        /> Loading mailbox…
      </p>

      <div
        :if={@inbox.failed}
        id="coordinator-mailbox-error"
        role="alert"
        class="flex items-start gap-2 m-3 px-3 py-3 rounded-[var(--radius-field)] text-[12px] text-[var(--arb-fail-text)] bg-[var(--arb-fail-wash)]"
      >
        <ArbiterWeb.CoreComponents.Core.icon
          name="hero-exclamation-triangle-micro"
          class="size-4 shrink-0 mt-px"
        />
        <span class="grow min-w-0 break-words">
          Could not load the mailbox: {async_error(@inbox.failed)}
        </span>
        <button
          type="button"
          id="coordinator-mailbox-retry"
          phx-click="coordinator_retry"
          class="shrink-0 px-2 h-[22px] rounded-[var(--radius-field)] cursor-pointer border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)] text-[11px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
        >
          Retry
        </button>
      </div>

      <div
        :if={@inbox.ok? && !@inbox.failed && @messages == []}
        id="coordinator-mailbox-empty"
        class="p-4"
      >
        <ArbiterWeb.CoreComponents.Feedback.empty_state
          icon="hero-inbox"
          detail="worker completions, failures and escalations land here in real time"
        >
          Inbox clear.
        </ArbiterWeb.CoreComponents.Feedback.empty_state>
      </div>

      <ul
        :if={!@inbox.failed && @messages != []}
        id="coordinator-mailbox-list"
        class="flex flex-col gap-2 p-3 overflow-y-auto"
      >
        <li
          :for={m <- @messages}
          class={[
            "rounded-[var(--radius-field)] border border-solid border-[var(--arb-line-strong)]",
            "border-l-[length:var(--border-accent-width)] px-3 py-2 bg-[var(--arb-panel-alt)]",
            mailbox_border(m.kind)
          ]}
        >
          <div class="flex items-baseline justify-between gap-2">
            <div class="flex items-baseline gap-2 flex-wrap min-w-0">
              <span class="text-[10px] uppercase tracking-[0.08em] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                {m.kind}
              </span>
              <span class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-secondary)]">
                from {m.from_ref || "?"}
              </span>
              <.link
                :if={Message.task_ref(m)}
                navigate={~p"/tasks/#{Message.task_ref(m)}"}
                class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)]"
              >
                {Message.task_ref(m)}
              </.link>
              <span :if={m.subject} class="text-[12.5px] font-medium text-[var(--text-title)]">
                {m.subject}
              </span>
            </div>
            <div class="flex items-center gap-2 shrink-0">
              <span class="text-[10px] font-[family-name:var(--font-mono)] text-[var(--text-label)]">
                {relative(m.inserted_at, @now)}
              </span>
              <button
                type="button"
                phx-click="coordinator_mark_read"
                phx-value-id={m.id}
                class="text-[10.5px] font-[family-name:var(--font-mono)] text-[var(--text-link)] cursor-pointer"
              >
                mark read
              </button>
            </div>
          </div>
          <p
            :if={m.body not in [nil, ""]}
            class="mt-1.5 text-[12px] whitespace-pre-wrap text-[var(--text-secondary)]"
          >
            {m.body}
          </p>
        </li>
      </ul>
    </aside>
    """
  end

  # ---- the quota chip (bd-i2gwwn) -------------------------------------------
  #
  # Interaction: a disclosure, not a hover card. The chip is a real <button>
  # (focusable, Enter/Space) carrying `aria-expanded` + `aria-controls`; a
  # click or tap toggles the popover, and a click/tap anywhere outside the
  # chip-and-popover (`phx-click-away`) or Escape (`phx-window-keydown`)
  # closes it. Touch is the same as mouse — a tap is a click and there is no
  # hover-only content, so nothing needs a second gesture. The commands are
  # client-side `JS`, so opening costs no round trip, and LiveView keeps what
  # they set across server patches (a quota broadcast doesn't shut it).
  #
  # Anchoring: the popover hangs from the chip's right edge, below the bar —
  # the right-hand cluster (live badge, inbox, theme toggle) sits beside the
  # chip in the bar, so a popover under the bar can't cover them — and is
  # capped at the viewport width minus the bar's padding.

  @doc """
  The "update available" notice from `Arbiter.Release.UpdateCheck.state/0`:
  the release link, the deploy command and — for the operator's own dashboard
  session, which is the only thing that renders this layout — an
  "Update to vX.Y.Z" button; plus the last deploy's progress or outcome
  (`Arbiter.Release.DeployStatus`).

  The button is a plain form POST to `/release/deploy` (a dashboard login, CSRF
  protected) rather than a LiveView event, so it works on the dead `/about` page
  and on every LiveView alike. Its `data-confirm` names the version and whether
  migrations are pending before anything starts.
  """
  attr :update, :map, required: true
  attr :deploy, :map, default: nil
  attr :dismissed, :string, default: nil

  def update_notice(assigns) do
    assigns =
      assigns
      |> assign(:update_visible?, update_visible?(assigns.update, assigns.dismissed))
      |> assign(:deploy_state, deploy_state(assigns.deploy))
      |> assign(:deploy_visible?, deploy_visible?(assigns.deploy))
      |> assign(
        :deploy_dismissable?,
        Arbiter.Release.DeployStatus.dismiss_key(assigns.deploy) != nil
      )

    ~H"""
    <div
      :if={@update_visible?}
      id="update-available"
      role="status"
      class="alert alert-info mx-4 mt-4 text-sm"
    >
      <.icon name="hero-arrow-up-circle" class="size-5 shrink-0" />
      <div class="min-w-0 flex-1">
        <p class="font-semibold">Update available: {@update.latest}</p>
        <p>
          <a
            :if={@update.release_url}
            id="update-release-link"
            href={@update.release_url}
            target="_blank"
            rel="noopener noreferrer"
            class="link link-hover font-medium text-info-content underline"
          >
            Release notes
          </a>
          · deploy with <code id="update-deploy-command">arb server deploy</code>
        </p>
      </div>
      <.form
        for={%{}}
        as={:update_dismiss}
        id="update-dismiss-form"
        action={~p"/release/update/dismiss"}
        method="post"
        class="shrink-0 order-last"
      >
        <button
          type="submit"
          id="update-dismiss-button"
          aria-label={"Dismiss the update notice for " <> to_string(@update.latest)}
          title="Dismiss until a newer version is available"
          class="inline-flex items-center rounded-[var(--radius-field)] p-1 text-[var(--text-label)] cursor-pointer transition-colors duration-150 hover:text-[var(--text-title)]"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </.form>
      <.form
        :if={@deploy_state != "running"}
        for={%{}}
        as={:update}
        id="update-deploy-form"
        action={~p"/release/deploy"}
        method="post"
        class="shrink-0"
      >
        <button
          type="submit"
          id="update-deploy-button"
          data-confirm={update_confirm_text(@update)}
          class="inline-flex items-center gap-1.5 rounded-[var(--radius-field)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] px-3 py-1.5 text-sm font-medium text-[var(--text-title)] cursor-pointer transition-colors duration-150 hover:bg-[var(--arb-raised-hover)]"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" /> Update to {@update.latest}
        </button>
      </.form>
    </div>
    <div
      :if={@deploy_visible?}
      id="deploy-status"
      role="status"
      data-state={@deploy_state}
      class={[
        "alert mx-4 mt-4 text-sm",
        deploy_alert_class(@deploy_state)
      ]}
    >
      <.icon name={deploy_icon(@deploy_state)} class="size-5 shrink-0" />
      <div class="min-w-0">
        <p class="font-semibold">{deploy_headline(@deploy, @deploy_state)}</p>
        <p class="break-words">{deploy_detail(@deploy, @deploy_state)}</p>
      </div>
      <.form
        :if={@deploy_dismissable?}
        for={%{}}
        as={:deploy_dismiss}
        id="deploy-dismiss-form"
        action={~p"/release/deploy/dismiss"}
        method="post"
        class="shrink-0"
      >
        <button
          type="submit"
          id="deploy-dismiss-button"
          aria-label="Dismiss the deploy notice"
          title="Dismiss this notice"
          class="inline-flex items-center rounded-[var(--radius-field)] p-1 cursor-pointer transition-colors duration-150 hover:opacity-70"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </.form>
    </div>
    """
  end

  # Shown when an update is offered and the operator has not dismissed this
  # version or a newer one (a lower `latest` than the dismissed tag stays hidden).
  defp update_visible?(%{update_available?: true, latest: latest}, dismissed) do
    is_nil(dismissed) or Arbiter.Release.UpdateCheck.newer?(latest, dismissed)
  end

  defp update_visible?(_, _), do: false

  # The dismissal is cosmetic: `/about` always shows the notice, so the update
  # and its details stay reachable from the UI.
  # The setting is only read while an update is on offer, so the chrome of an
  # up-to-date install still issues no DB query per render.
  defp dismissed_update(%{update_available?: true}, current_path) when current_path != "/about",
    do: Arbiter.Settings.dismissed_update_version()

  defp dismissed_update(_update, _current_path), do: nil

  # "running" is only believed while the deploy's process is alive: a record
  # whose process died reads as an interrupted (failed) deploy.
  defp deploy_state(nil), do: nil

  defp deploy_state(%{"state" => "running"} = deploy) do
    if Arbiter.Release.DeployStatus.interrupted?(deploy), do: "failed", else: "running"
  end

  defp deploy_state(%{"state" => state}) when is_binary(state), do: state
  defp deploy_state(_), do: nil

  # A successful deploy is news for a day; anything that needs the operator
  # (failed, rolled back, refused) and anything in flight stays until the next
  # deploy replaces the record.
  @success_visible_s 24 * 3600

  # A dismissal hides exactly the record it was made at (tag + finish time), so a
  # later deploy, whatever its outcome, shows again.
  defp deploy_visible?(deploy) do
    case deploy_state(deploy) do
      nil -> false
      "running" -> true
      state -> not deploy_dismissed?(deploy) and outcome_fresh?(state, deploy)
    end
  end

  defp outcome_fresh?("succeeded", deploy), do: within?(deploy["finished_at"], @success_visible_s)
  defp outcome_fresh?(_, _), do: true

  # An interrupted "running" record reads as failed and has no key; it is never
  # dismissable, so it is not looked up.
  defp deploy_dismissed?(deploy) do
    case Arbiter.Release.DeployStatus.dismiss_key(deploy) do
      nil -> false
      key -> key == Arbiter.Settings.dismissed_deploy()
    end
  end

  defp within?(iso, seconds) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _} -> DateTime.diff(DateTime.utc_now(), at) <= seconds
      _ -> false
    end
  end

  defp within?(_, _), do: false

  defp deploy_alert_class("succeeded"), do: "alert-success"
  defp deploy_alert_class("running"), do: "alert-info"
  defp deploy_alert_class(_), do: "alert-warning"

  defp deploy_icon("succeeded"), do: "hero-check-circle"
  defp deploy_icon("running"), do: "hero-arrow-path"
  defp deploy_icon(_), do: "hero-exclamation-triangle"

  defp deploy_headline(deploy, "running"), do: "Updating to #{deploy["tag"]}…"
  defp deploy_headline(deploy, "succeeded"), do: "Updated to #{deploy["tag"]}"

  defp deploy_headline(deploy, "rolled_back"),
    do: "Update to #{deploy["tag"]} failed and was rolled back to #{deploy["rolled_back_to"]}"

  defp deploy_headline(deploy, "refused"),
    do: "Update to #{deploy["tag"]} failed; rollback was declined"

  defp deploy_headline(deploy, _), do: "Update to #{deploy["tag"]} failed"

  defp deploy_detail(deploy, "running") do
    "Phase: #{deploy["phase"] || "starting"}. The server restarts when the new release swaps in; " <>
      "this page shows the outcome once it is back."
  end

  defp deploy_detail(deploy, "succeeded") do
    "Finished #{deploy["finished_at"]}." <> backup_note(deploy)
  end

  defp deploy_detail(deploy, "rolled_back") do
    restored =
      if deploy["restored_database"] == true,
        do: " The pre-update database was restored from the backup.",
        else: " The database was not touched."

    "The new release did not come back healthy." <> restored <> backup_note(deploy)
  end

  defp deploy_detail(deploy, "refused") do
    "The release added migrations and could not be rolled back automatically; " <>
      "see `arb server deploy` output." <> backup_note(deploy)
  end

  defp deploy_detail(deploy, state) do
    base = deploy["message"] || "The deploy stopped before finishing (state: #{state})."
    base <> backup_note(deploy)
  end

  defp backup_note(%{"backup_path" => path}) when is_binary(path), do: " Backup: #{path}"
  defp backup_note(_), do: ""

  # What the browser asks before it posts: the version, whether migrations are
  # pending (the update check reads the release's migration manifest against this
  # database), and that the server restarts.
  defp update_confirm_text(update) do
    "Update Arbiter to #{update.latest}?\n\n" <>
      migrations_sentence(update[:migrations_pending]) <>
      "\n\nA database backup is taken first, then the server restarts; if the new release " <>
      "does not come back healthy it is rolled back. The update will not start while workers " <>
      "are actively working (a restart would kill their in-flight work) — it stops and says so here."
  end

  defp migrations_sentence([]), do: "This update has no pending migrations."

  defp migrations_sentence(names) when is_list(names) do
    "This update has #{length(names)} pending migration(s): #{Enum.join(names, ", ")}. " <>
      "If it fails after migrating, the database backup is restored."
  end

  defp migrations_sentence(_),
    do:
      "Whether it has pending migrations could not be determined " <>
        "(the release publishes no migration list, or this database could not be read)."

  attr :quotas, :list, required: true
  attr :on_exhaustion, :any, default: nil

  defp quota_chip(assigns) do
    ~H"""
    <div
      id="quota-topbar"
      class="relative flex-none max-sm:hidden"
      phx-click-away={close_quota_popover()}
      phx-window-keydown={close_quota_popover()}
      phx-key="Escape"
    >
      <button
        type="button"
        id="quota-chip"
        aria-expanded="false"
        aria-controls="quota-popover"
        phx-click={toggle_quota_popover()}
        class="flex items-center gap-[6px] h-[36px] px-[6px] rounded-[var(--radius-field)] cursor-pointer border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] transition-[background-color,border-color] duration-150 hover:bg-[var(--arb-raised-hover)] hover:border-[var(--border-strong)] aria-expanded:bg-[var(--arb-raised-hover)] aria-expanded:border-[var(--border-strong)] focus-visible:outline-none focus-visible:shadow-[var(--ring-focus)]"
      >
        <.quota_ring_object :for={quota <- @quotas} quota={quota} />
      </button>
      <div
        id="quota-popover"
        role="region"
        aria-label="Quota by provider"
        class="hidden absolute right-0 top-[calc(100%+6px)] z-30 w-[360px] max-w-[calc(100vw-24px)] max-h-[calc(100vh-var(--nav-height)-24px)] overflow-y-auto flex flex-col p-[12px] rounded-[var(--radius-panel)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)] shadow-[var(--shadow-float)]"
      >
        <.quota_popover_entry
          :for={quota <- @quotas}
          quota={quota}
          on_exhaustion={@on_exhaustion}
        />
        <p class="m-0 mt-[10px] pt-[8px] border-t border-solid border-[var(--border-default)] text-[10.5px] leading-[1.5] text-[var(--text-secondary)]">
          Rings: inner 5h, outer 7d. The hairline is elapsed time.
        </p>
      </div>
    </div>
    """
  end

  defp toggle_quota_popover do
    JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#quota-chip")
    |> JS.toggle(
      to: "#quota-popover",
      in:
        {"transition ease-out duration-150", "opacity-0 -translate-y-1",
         "opacity-100 translate-y-0"},
      out: {"transition ease-in duration-100", "opacity-100", "opacity-0"},
      time: 150
    )
  end

  defp close_quota_popover do
    JS.set_attribute({"aria-expanded", "false"}, to: "#quota-chip")
    |> JS.hide(
      to: "#quota-popover",
      transition: {"transition ease-in duration-100", "opacity-100", "opacity-0"},
      time: 100
    )
  end

  # One provider: the logo in the middle of an inner 5h and an outer 7d ring,
  # in a 32px box (2px inside the 36px chip). Strokes are 2.5px with a 1px
  # gap, leaving a 19.5px hole for the 13px logo. The `title`/`aria-label`
  # say both windows in words, so the colour is never the only signal.
  attr :quota, :map, required: true

  defp quota_ring_object(assigns) do
    rings = quota_rings(assigns.quota)
    state = quota_object_state(assigns.quota, rings)

    assigns =
      assign(assigns,
        rings: rings,
        state: state,
        summary: quota_ring_summary(assigns.quota, rings),
        title: quota_ring_title(assigns.quota, rings)
      )

    ~H"""
    <span
      id={"quota-ring-#{@quota.provider}"}
      data-ring-provider={@quota.provider}
      data-ring-state={ring_state_attr(@state)}
      role="img"
      aria-label={@summary}
      title={@title}
      class={["relative flex-none size-[32px]", @state == :stale && "opacity-60"]}
    >
      <svg data-ring-svg viewBox="0 0 32 32" class="absolute inset-0 size-full" aria-hidden="true">
        <%!-- Only skip outer ring for truly single-window providers (Codex with session-only).
             Antigravity without data has nil secondary_label but still needs the outer ring for UI consistency. --%>
        <%= if @quota.secondary_label || @quota.primary_label == "used" do %>
          <.quota_ring
            id={"quota-ring-#{@quota.provider}-7d"}
            position="outer"
            r={14.5}
            ring={@rings.outer}
          />
        <% end %>
        <.quota_ring
          id={"quota-ring-#{@quota.provider}-5h"}
          position="inner"
          r={11.0}
          ring={@rings.inner}
        />
      </svg>
      <span
        data-ring-logo
        class="absolute inset-0 flex items-center justify-center pointer-events-none"
      >
        <.provider_icon
          provider={quota_icon_provider(@quota.provider)}
          class="size-[13px]"
          aria-hidden="true"
        />
      </span>
    </span>
    """
  end

  attr :id, :string, required: true
  attr :position, :string, required: true
  attr :r, :float, required: true
  attr :ring, :map, required: true

  # The track, the utilisation arc from 12 o'clock clockwise (`pathLength`
  # 100, so the dash is the percentage), and the elapsed-time hairline across
  # the stroke. No data draws a dashed track and no arc.
  defp quota_ring(assigns) do
    ~H"""
    <g
      id={@id}
      data-ring-window={@position}
      data-ring-state={ring_state_attr(@ring.state)}
      data-ring-pct={@ring.pct}
    >
      <circle
        cx="16"
        cy="16"
        r={@r}
        fill="none"
        stroke-width="2.5"
        pathLength="100"
        stroke-dasharray={@ring.state == :no_data && "2 3"}
        style={
          if(@ring.state == :no_data,
            do: "stroke: var(--arb-done); stroke-opacity: 0.6;",
            else: "stroke: var(--border-default);"
          )
        }
      />
      <circle
        :if={@ring.state != :no_data}
        data-ring-arc
        cx="16"
        cy="16"
        r={@r}
        fill="none"
        stroke-width="2.5"
        pathLength="100"
        stroke-dasharray={"#{@ring.pct} 100"}
        transform="rotate(-90 16 16)"
        style={"stroke: #{quota_ring_stroke(@ring.state)};"}
        class="transition-[stroke-dasharray,stroke] duration-[var(--dur-bar)] ease-[var(--arb-ease-out)]"
      />
      <line
        :if={@ring.elapsed_pct}
        data-ring-hairline
        x1="16"
        x2="16"
        y1={16 - @r - 1.5}
        y2={16 - @r + 1.5}
        stroke-width="1"
        transform={"rotate(#{@ring.elapsed_pct * 3.6} 16 16)"}
        style="stroke: var(--text-title); stroke-opacity: 0.55;"
      />
    </g>
    """
  end

  defp ring_state_attr(state), do: state |> Atom.to_string() |> String.replace("_", "-")

  # The popover's entry for one provider: the logo and name, then both windows
  # as the full `quota_bar/1` (pace hairline, percentage, reset or burn-rate
  # note), Antigravity's two bucket groups each as their own pair, and a note
  # under any window near or over its ceiling.
  attr :quota, :map, required: true
  attr :on_exhaustion, :any, default: nil

  defp quota_popover_entry(assigns) do
    assigns = assign(assigns, :groups, popover_groups(assigns.quota))

    ~H"""
    <section
      id={"quota-popover-#{@quota.provider}"}
      class="flex flex-col gap-[7px] py-[10px] first:pt-0 border-t first:border-t-0 border-solid border-[var(--border-default)]"
    >
      <div class="flex items-center gap-[7px]">
        <.provider_icon provider={quota_icon_provider(@quota.provider)} class="size-4" />
        <span class="text-[12px] font-medium text-[var(--text-title)]">
          {quota_provider_label(@quota.provider)}
        </span>
      </div>
      <%= cond do %>
        <% quota_no_data?(@quota) -> %>
          <ArbiterWeb.CoreComponents.Feedback.quota_no_data />
        <% @groups != [] -> %>
          <div
            :for={group <- @groups}
            id={"quota-popover-#{@quota.provider}-#{group.group}"}
            class="flex flex-col gap-[5px]"
          >
            <span class="text-[10px] leading-none text-[var(--text-secondary)] font-[family-name:var(--font-mono)]">
              {group.label}
            </span>
            <.quota_popover_window
              :for={w <- group.windows}
              id={"quota-popover-#{@quota.provider}-#{group.group}-#{w.window}"}
              quota={@quota}
              w={w}
              on_exhaustion={@on_exhaustion}
            />
          </div>
        <% true -> %>
          <.quota_popover_window
            :for={w <- quota_windows(@quota)}
            id={"quota-popover-#{@quota.provider}-#{w.window}"}
            quota={@quota}
            w={w}
            on_exhaustion={@on_exhaustion}
          />
      <% end %>
    </section>
    """
  end

  defp popover_groups(%{provider: "antigravity"} = quota), do: quota_antigravity_groups(quota)
  defp popover_groups(_quota), do: []

  attr :id, :string, required: true
  attr :quota, :map, required: true
  attr :w, :map, required: true
  attr :on_exhaustion, :any, default: nil

  defp quota_popover_window(assigns) do
    bar =
      Map.merge(assigns.w, %{
        provider: assigns.quota.provider,
        overage_status: assigns.quota.overage_status
      })

    pace = quota_pace(bar, Map.get(assigns.quota, :gate_policy))

    assigns =
      assign(assigns,
        pace_note: assigns.quota.message == nil && quota_hold_text(pace, assigns.w.utilization)
      )

    ~H"""
    <div class="flex flex-col gap-[3px]">
      <.quota_bar
        id={@id}
        provider={@quota.provider}
        show_label={false}
        window={@w.window}
        label={@w.label}
        utilization={@w.utilization}
        reset_at={@w.reset_at}
        overage_status={@quota.overage_status}
        representative_claim={@quota.representative_claim}
        stale_message={@quota.message}
        gate_policy={Map.get(@quota, :gate_policy)}
        label_width={44}
        width={140}
        on_exhaustion={@on_exhaustion}
      />
      <p
        :if={@pace_note}
        data-quota-pace-note
        class="m-0 pl-[51px] text-[10px] leading-[1.4] text-[var(--text-secondary)] font-[family-name:var(--font-mono)]"
      >
        {@pace_note} · {quota_reset_text(@w.reset_at)}
      </p>
    </div>
    """
  end

  # `ArbiterWeb.LiveHooks` loads both off the mount (bd-adewb4), so a
  # LiveView hands over `AsyncResult`s; a plain list (a specimen, a test, a
  # dead controller render) is already loaded.
  defp as_async(%AsyncResult{} = async), do: async
  defp as_async(list) when is_list(list), do: AsyncResult.ok(list)

  defp quota_bars?(%AsyncResult{ok?: true, result: [_ | _]}), do: true
  defp quota_bars?(%AsyncResult{}), do: false

  # The loaded messages; none until the first load lands. A failed re-read
  # keeps the last list in the result, but the drawer and the trigger show
  # the failure instead of it.
  defp inbox_messages(%AsyncResult{ok?: true, result: messages}) when is_list(messages),
    do: messages

  defp inbox_messages(%AsyncResult{}), do: []

  # `{:exit, reason}` from a crashed load, `{:error, reason}` from an inline
  # re-read that raised.
  defp async_error({:exit, {%{__exception__: true} = error, _stacktrace}}),
    do: Exception.message(error)

  defp async_error({kind, %{__exception__: true} = error}) when kind in [:exit, :error],
    do: Exception.message(error)

  defp async_error({_kind, reason}), do: inspect(reason)
  defp async_error(reason), do: inspect(reason)

  defp mailbox_border(:escalation), do: "border-l-[color:var(--arb-fail)]"
  defp mailbox_border(:failure), do: "border-l-[color:var(--arb-fail)]"
  defp mailbox_border(:completion), do: "border-l-[color:var(--arb-live)]"
  defp mailbox_border(:direction), do: "border-l-[color:var(--arb-attention)]"
  defp mailbox_border(:flag), do: "border-l-[color:var(--arb-attention)]"
  defp mailbox_border(_), do: "border-l-[color:var(--arb-info)]"

  defp relative(%DateTime{} = ts, %DateTime{} = now), do: "#{elapsed(ts, now)} ago"
  defp relative(_, _), do: ""

  defp elapsed(%DateTime{} = since, %DateTime{} = now) do
    seconds = DateTime.diff(now, since)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <ArbiterWeb.CoreComponents.icon
          name="hero-arrow-path"
          class="ml-1 size-3 motion-safe:animate-spin"
        />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <ArbiterWeb.CoreComponents.icon
          name="hero-arrow-path"
          class="ml-1 size-3 motion-safe:animate-spin"
        />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  Lives in the nav rail footer. Two variants share the one `#theme-toggle`
  root and `app.css` picks between them: `theme-full` is the three-way pill
  (expanded, pinned and overlay rail); `theme-cycle` is a single 28px button
  for the collapsed 56px rail, where the pill would clip. The cycle variant is
  three buttons, one per mode, of which CSS shows the one for the current
  `html[data-theme]` (none = system). Each carries the *next* mode in
  `data-phx-theme`, so the existing `phx:set-theme` handler needs no change.

  See <head> in root.html.heex which applies the theme before page load.
  """
  attr :id, :string, default: "theme-toggle"

  def theme_toggle(assigns) do
    ~H"""
    <div id={@id} class="flex items-center">
      <div
        data-role="theme-full"
        class="relative flex items-center rounded-[var(--radius-pill)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)]"
      >
        <div class="absolute inset-y-[2px] left-[2px] w-[calc(33.333%-2px)] rounded-[var(--radius-pill)] bg-[var(--surface-card)] transition-[left] duration-200 [[data-theme=light]_&]:left-[calc(33.333%+1px)] [[data-theme=dark]_&]:left-[calc(66.666%-1px)]" />

        <button
          class="relative flex p-[7px] cursor-pointer w-1/3 justify-center"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="system"
          aria-label="Match system theme"
        >
          <ArbiterWeb.CoreComponents.Core.icon
            name="hero-computer-desktop-micro"
            color="var(--text-secondary)"
          />
        </button>

        <button
          class="relative flex p-[7px] cursor-pointer w-1/3 justify-center"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="light"
          aria-label="Light theme"
        >
          <ArbiterWeb.CoreComponents.Core.icon name="hero-sun-micro" color="var(--text-secondary)" />
        </button>

        <button
          class="relative flex p-[7px] cursor-pointer w-1/3 justify-center"
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="dark"
          aria-label="Dark theme"
        >
          <ArbiterWeb.CoreComponents.Core.icon name="hero-moon-micro" color="var(--text-secondary)" />
        </button>
      </div>

      <div data-role="theme-cycle" class="hidden items-center">
        <button
          class={[cycle_class(), "flex [[data-theme=light]_&]:hidden [[data-theme=dark]_&]:hidden"]}
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="light"
          aria-label="Theme: system. Switch to light."
        >
          <ArbiterWeb.CoreComponents.Core.icon
            name="hero-computer-desktop-micro"
            color="var(--text-secondary)"
          />
        </button>

        <button
          class={[cycle_class(), "hidden [[data-theme=light]_&]:flex"]}
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="dark"
          aria-label="Theme: light. Switch to dark."
        >
          <ArbiterWeb.CoreComponents.Core.icon name="hero-sun-micro" color="var(--text-secondary)" />
        </button>

        <button
          class={[cycle_class(), "hidden [[data-theme=dark]_&]:flex"]}
          phx-click={JS.dispatch("phx:set-theme")}
          data-phx-theme="system"
          aria-label="Theme: dark. Switch to system."
        >
          <ArbiterWeb.CoreComponents.Core.icon name="hero-moon-micro" color="var(--text-secondary)" />
        </button>
      </div>
    </div>
    """
  end

  defp cycle_class,
    do:
      "size-7 items-center justify-center cursor-pointer rounded-[var(--radius-pill)] border border-solid border-[var(--border-default)] bg-[var(--surface-chrome)]"
end
