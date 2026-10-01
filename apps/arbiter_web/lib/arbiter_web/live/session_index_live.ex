defmodule ArbiterWeb.SessionIndexLive do
  @moduledoc """
  The sessions list at `/sessions` (bd-c76fu9, phase 5 of
  `docs/browser-hosted-coordinator-sessions.md`).

  Every browser-hosted coordinator session Arbiter has ever launched, newest
  first, with the three fleet-level things an operator does to one: launch,
  open, and kill.

  ## What this page owns, and what the dock owns (phase 3, bd-a292yj)

  This page is the **index**: the whole history, launching, naming at launch,
  and reviewing sessions that are long over. It is deliberately the only other
  surface, because `/sessions/:id` is gone — phase 3 moved every per-session
  control into `ArbiterWeb.SessionDockLive`'s window (keep_alive, detach, kill,
  the metadata, live cost, the terminal) and deleted the page they used to live
  on rather than leaving a route whose controls had moved away.

  So "open" here does not navigate anywhere: it hands the session to the dock,
  which is on this page too and on every other one. Launching does the same,
  which is why it no longer redirects.

  Kill is the one control that is deliberately on both surfaces — ending a
  session is a fleet act as much as a window act — and both of them go through
  `kill_modal/1` below, so there is one confirmation, not two that can drift.

  ## The §9.5 pre-launch options (phase 11)

  `launch_form/1` carries the whole option set: session name, provider
  (Claude Code by default, or agy — bd-7xuvfl), auth mode, Remote Control
  (§8, gated to mode B), workspace binding, and `can_dispatch`. Choosing agy
  disables auth mode and Remote Control with the reason shown, for the same
  §8.3 "never a toggle that silently does nothing" rule: an agy session runs
  on the operator's own grant (mode B, always), and bridge verification reads
  Claude Code's JSONL. `launch_defaults/1` clamps both server-side, as the
  `Session` resource does again at the row. Every option keeps its §9.5 default, including Remote
  Control's — see below, this was wrong through round 3 (review finding,
  phase 11 round 4: the code shipped it off by default and this moduledoc
  claimed that was the spec):

    * Workspace binding defaults to **cross-workspace** (`workspace_id: nil`).
      Picking a workspace from `workspaces/0`'s list opts a session into a
      single one. The `<select>` offers no way to *pick* an id outside that
      list, but a crafted submit still can — `launch_workspace_id/2` re-checks
      it against `workspaces/0` server-side (mirroring the `remote_control`
      clamp below), so a bogus id falls back to cross-workspace rather than
      binding the session to a workspace that doesn't exist (review finding,
      phase 11 round 4).
    * `can_dispatch` defaults **off** — §10.1's rule that a session cannot
      start workers until an operator says so. A button that quietly
      launched something with dispatch rights would be the wrong default to
      ship, so the checkbox has to be checked, explicitly, every time.

  Remote Control defaults **on** under mode B and is force-disabled under
  mode A — §9.5's table row reads "on when mode B; disabled with reason when
  mode A" (§8.3). §8.3's design consequence 1 adds the hard UI rule on top:
  "`--remote-control` must be disabled in the UI when mode A is selected,
  with the reason shown. Offering a toggle that silently does nothing is the
  worst outcome." Mode B (seeded credentials, Amendment 2) is still the
  default auth mode, so a fresh launch panel arrives with the box checked.

  ## Kill is confirmed, and says what it takes with it

  `Arbiter.Sessions.kill/2` stops a real tmux server inside a real systemd
  scope; whatever the agent was mid-turn on is gone. So it is a two-step, and
  the confirmation names the session rather than asking "are you sure?".

  ## Cost/tokens column (bd-9mrzti)

  Each row's cost and token totals come from `ArbiterWeb.SessionUsage`, which
  is `Arbiter.Usage.summarize(by: :session)` — the same rollup `arb usage --by
  session` and the dock window's info view read — rather than a second
  computation. A
  running session's row is not backed by its own JSONL tailer: the page
  polls that one aggregate query on `@usage_refresh_ms`, so N running
  sessions cost one query per tick, not N. The ledger itself
  (`Arbiter.Sessions.UsageIngest`) only sweeps every 5 minutes by default, so
  this is "the next sweep shows up without a reload", not sub-second — see
  the "estimated" marker on figures still riding on `ClaudePricing`'s
  token-priced fallback rather than a real `cost-state` record.

  The row keys on `session.provider_session_id`, which a `--resume` or
  compaction rollover **replaces** rather than appends to
  (`Session.record_provider_session/2`). A rolled-over session's row only
  ever reflects spend under its *current* provider id — pre-rollover spend
  under the old id is real, ledgered, and reachable via `arb usage --by
  session`, but this column under-reports it. `Sessions.usage_events/1` has
  the same limitation already.
  """

  use ArbiterWeb, :live_view

  alias Arbiter.Sessions
  alias Arbiter.Sessions.DisplayName
  alias Arbiter.Tasks.Workspace
  alias ArbiterWeb.CoreComponents.Core
  alias ArbiterWeb.CoreComponents.Data
  alias ArbiterWeb.CoreComponents.Domain
  alias ArbiterWeb.CoreComponents.Feedback
  alias ArbiterWeb.CoreComponents.Forms
  alias ArbiterWeb.CoreComponents.Navigation
  alias ArbiterWeb.SessionUsage

  require Logger

  # How often a running session's row re-pulls the usage ledger (bd-9mrzti).
  # `Arbiter.Sessions.UsageIngest` only sweeps every 5 minutes by default, so
  # polling faster than that buys nothing; this just needs to be "a page left
  # open eventually catches the next sweep" rather than instant. A single
  # `Usage.summarize(by: :session)` call for the whole list, not one tailer
  # per row — see the module doc.
  @usage_refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Arbiter.PubSub, Sessions.lifecycle_topic())
    end

    # bd-b88x6g: the session list, the usage ledger rollup, and the launch
    # form's workspace list are all reads this page used to run synchronously
    # on every mount, dead render included. The dead render now draws nothing
    # but the loading state; the connected mount starts the reads and lands
    # them via `handle_async/3` below.
    socket =
      socket
      |> assign(:kill_candidate, nil)
      |> assign(:usage_refresh_ref, nil)
      |> assign(:launch_provider, "claude_code")
      |> assign(:launch_auth_mode, "seeded_credentials")
      |> assign(:launch_name, nil)
      |> assign(:launch_workspace_id, nil)
      |> assign(:launch_can_dispatch?, false)
      # §9.5: on when mode B, which is the default auth mode — see moduledoc.
      |> assign(:launch_remote_control?, true)
      |> assign(:workspaces, [])
      |> assign(:sessions, [])
      |> assign(:running_count, 0)
      |> assign(:usage_by_session, %{})
      |> assign(:sessions_loaded?, false)
      |> assign(:sessions_loading?, false)
      |> assign(:sessions_stale?, false)
      |> assign(:sessions_error, nil)
      |> assign(:usage_loading?, false)
      |> assign(:usage_error, nil)

    socket =
      if connected?(socket) do
        socket
        |> start_async(:workspaces, &load_workspaces_task/0)
        |> refresh()
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_launch", params, socket) do
    {:noreply, assign_launch_params(socket, params)}
  end

  def handle_event("launch", params, socket) do
    case Sessions.launch(launch_defaults(params)) do
      {:ok, session} ->
        # Straight into the dock rather than off to a page of its own: the
        # terminal is in the strip at the bottom of every page, and a redirect
        # would only have thrown away whatever the operator was reading.
        {:noreply, socket |> refresh() |> reset_launch_params() |> open_in_dock(session.id)}

      {:error, reason} ->
        Logger.error("SessionIndexLive: launch failed: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Could not launch a session: #{describe(reason)}")
         |> refresh()}
    end
  end

  # `push_event/3` reaches the client as a `window` `phx:` event, which is
  # exactly how a LiveView hook's `handleEvent` listens — so the `SessionDock`
  # hook picks this up even though the dock is a *sibling* sticky view with its
  # own process and its own assigns. It answers by pushing `open` to that
  # process, the same path the roster's own Open button takes.
  def handle_event("open_in_dock", %{"id" => id}, socket) do
    {:noreply, open_in_dock(socket, id)}
  end

  def handle_event("confirm_kill", %{"id" => id}, socket) do
    {:noreply,
     assign(socket, :kill_candidate, Enum.find(socket.assigns.sessions, &(&1.id == id)))}
  end

  def handle_event("retry_sessions", _params, socket) do
    {:noreply, socket |> assign(:sessions_error, nil) |> refresh()}
  end

  def handle_event("cancel_kill", _params, socket) do
    {:noreply, assign(socket, :kill_candidate, nil)}
  end

  def handle_event("kill", %{"id" => id}, socket) do
    socket =
      case Sessions.kill(id) do
        {:ok, _session} ->
          put_flash(socket, :info, "Session ended.")

        {:error, reason} ->
          Logger.error("SessionIndexLive: kill #{id} failed: #{inspect(reason)}")
          put_flash(socket, :error, "Could not end that session: #{describe(reason)}")
      end

    {:noreply, socket |> assign(:kill_candidate, nil) |> refresh()}
  end

  # bd-bsdeb2: a session ending on its own (exit, crash, a vanished scope the
  # sweep reaped) has no other reason for this page to hear about it — Kill
  # already refreshes locally after its own call returns.
  @impl true
  def handle_info({:session_ended, _session_id}, socket) do
    {:noreply, refresh(socket)}
  end

  # bd-9mrzti: the periodic re-pull of the usage ledger — see the module doc.
  # Rescheduled from `refresh/1` itself (not left as a fixed
  # `:timer.send_interval`) so it stops once nothing is running and — unlike
  # an earlier revision — reliably restarts from *any* lifecycle event that
  # calls `refresh/1`, not just this handler.
  def handle_info(:refresh_session_usage, socket) do
    {:noreply, refresh(socket)}
  end

  # `ArbiterWeb.LiveHooks` subscribes every view to the coordinator mailbox and
  # quota topics and lets their messages fall through (`:cont`), so any page
  # with a `handle_info/2` of its own has to tolerate them.
  def handle_info(_message, socket), do: {:noreply, socket}

  # bd-b88x6g: stage 1 of the two-stage load lands here. Every session row
  # can render off this alone — the usage ledger rollup is stage 2, started
  # right after, so an operator sees the roster before the cost/tokens
  # column fills in rather than waiting on both reads before anything shows.
  @impl true
  def handle_async(:sessions, {:ok, sessions}, socket) do
    running_count = Enum.count(sessions, &(&1.status == :running))

    socket
    |> assign(:sessions, sessions)
    |> assign(:running_count, running_count)
    |> assign(:sessions_loaded?, true)
    |> assign(:sessions_error, nil)
    |> assign(:usage_loading?, true)
    |> assign(:usage_error, nil)
    |> start_async(:usage, fn -> load_usage_task(sessions) end)
    |> sessions_read_done()
  end

  def handle_async(:sessions, {:exit, reason}, socket) do
    Logger.error("SessionIndexLive: loading sessions failed: #{inspect(reason)}")

    socket
    |> assign(:sessions_error, describe_exit(reason))
    |> schedule_usage_refresh(socket.assigns.running_count)
    |> sessions_read_done()
  end

  # Stage 2. Re-arms the polling timer only once this lands (ok or failed) —
  # never from stage 1 — so a tick can never fire while the usage read it
  # would duplicate is still in flight.
  def handle_async(:usage, {:ok, usage_by_session}, socket) do
    socket
    |> assign(:usage_by_session, usage_by_session)
    |> assign(:usage_loading?, false)
    |> assign(:usage_error, nil)
    |> schedule_usage_refresh(socket.assigns.running_count)
    |> sessions_read_done()
  end

  def handle_async(:usage, {:exit, reason}, socket) do
    Logger.error("SessionIndexLive: loading usage failed: #{inspect(reason)}")

    socket
    |> assign(:usage_loading?, false)
    |> assign(:usage_error, describe_exit(reason))
    |> schedule_usage_refresh(socket.assigns.running_count)
    |> sessions_read_done()
  end

  def handle_async(:workspaces, {:ok, workspaces}, socket) do
    {:noreply, assign(socket, :workspaces, workspaces)}
  end

  def handle_async(:workspaces, {:exit, reason}, socket) do
    Logger.error("SessionIndexLive: loading workspaces failed: #{inspect(reason)}")
    {:noreply, assign(socket, :workspaces, [])}
  end

  defp describe_exit({%{__exception__: true} = error, _stacktrace}), do: Exception.message(error)
  defp describe_exit(reason), do: Exception.format_exit(reason)

  # Both stages are one refresh cycle: `sessions_loading?` only drops back to
  # false once stage 2 lands, so a refresh requested mid-cycle (a lifecycle
  # broadcast, Kill, the tick) is marked stale instead of starting a second
  # overlapping stage-1 read — and gets exactly one more full cycle once this
  # one finishes.
  defp sessions_read_done(socket) do
    socket = assign(socket, :sessions_loading?, false)
    {:noreply, if(socket.assigns.sessions_stale?, do: refresh(socket), else: socket)}
  end

  defp refresh(%{assigns: %{sessions_loading?: true}} = socket),
    do: assign(socket, :sessions_stale?, true)

  defp refresh(socket) do
    socket
    |> assign(:sessions_loading?, true)
    |> assign(:sessions_stale?, false)
    |> start_async(:sessions, &load_sessions_task/0)
  end

  # The task is linked to this view, so a tab closed mid-read (or a test
  # tearing down) would kill it mid-query — and a DB client that dies holding
  # a checkout costs the pool that connection (under test, the shared sandbox
  # one, bd-5scl0c). Trapping turns the view's exit into a message: the query
  # in flight finishes, and the task goes before it starts another.
  defp load_sessions_task do
    Process.flag(:trap_exit, true)
    result = Sessions.list()
    exit_if_view_gone()
    result
  end

  defp load_usage_task(sessions) do
    Process.flag(:trap_exit, true)
    result = SessionUsage.for_sessions(sessions)
    exit_if_view_gone()
    result
  end

  defp load_workspaces_task do
    Process.flag(:trap_exit, true)
    result = workspaces()
    exit_if_view_gone()
    result
  end

  defp exit_if_view_gone do
    receive do
      {:EXIT, _view, _reason} -> exit(:shutdown)
    after
      0 -> :ok
    end
  end

  defp open_in_dock(socket, id), do: push_event(socket, "session-dock:open", %{id: id})

  # Re-armed on every `refresh/1` (mount, kill, a lifecycle broadcast, or its
  # own tick) rather than only from the tick handler, so a session that starts
  # running again after the timer had stopped (nothing was running) gets
  # polling back — see the moduledoc's cost/tokens section and bd-9mrzti
  # finding 3. Cancels any prior ref first so lifecycle events firing in a
  # burst can't stack duplicate timers.
  defp schedule_usage_refresh(socket, running_count) do
    if ref = socket.assigns[:usage_refresh_ref] do
      Process.cancel_timer(ref)
    end

    ref =
      if connected?(socket) and running_count > 0 do
        Process.send_after(self(), :refresh_session_usage, @usage_refresh_ms)
      end

    assign(socket, :usage_refresh_ref, ref)
  end

  # Phase 5's defaults, plus §8's auth mode / Remote Control pulled forward
  # from phase 11 (see moduledoc). `:name` is the other option this page's
  # operator can already set (bd-o2vtsz) — an empty or missing field launches
  # with no name, same as before this option existed.
  #
  # Public, and `launch_auth_mode_param/2` and `describe/1` below alongside
  # it, so `ArbiterWeb.SessionDockLive`'s own `launch`/`validate_launch`
  # handlers can call the exact same params-to-opts logic (see `launch_form/1`
  # above) rather than a second copy that could drift from this one — the
  # gating in particular (`remote_control` clamped to mode B here) is a rule,
  # not styling, and a fork of it is the one thing bd-cdut29 was asked not to
  # build.
  @doc false
  def launch_defaults(params) do
    provider = launch_provider_param(params)
    auth_mode = launch_auth_mode_param(params, provider)

    [
      provider: String.to_existing_atom(provider),
      auth_mode: launch_auth_mode(auth_mode),
      # Mode A can never carry Remote Control (§8.3), and neither can agy —
      # enforced again here (on top of the disabled checkbox and the `Session`
      # resource's own validation) so a submission that bypassed the disabled
      # attribute still cannot request it.
      remote_control:
        remote_control_available?(provider, auth_mode) and launch_remote_control?(params),
      workspace_id: launch_workspace_id(params, Enum.map(workspaces(), & &1.id)),
      # §10.1: off unless the operator explicitly checks the box. A session
      # that could dispatch workers by default is the wrong thing to ship
      # turned on.
      can_dispatch: launch_can_dispatch?(params),
      name: launch_name(params)
    ]
  end

  @doc """
  Workspaces the launch form offers for the §9.5 binding option, sorted by
  name. Public so `ArbiterWeb.SessionDockLive`'s mount can load the same
  list for its copy of `launch_form/1` — see `launch_defaults/1` above.
  """
  @spec workspaces() :: [Workspace.t()]
  def workspaces do
    Workspace
    |> Ash.Query.sort(name: :asc)
    |> Ash.read()
    |> case do
      {:ok, list} -> list
      _ -> []
    end
  end

  @doc """
  Mirrors every §9.5 option from a `validate_launch` (or `launch`) params map
  onto its own assign, so a `phx-change` diff that touches an unrelated field
  — switching `auth_mode`, say — cannot cause LiveView's DOM patch to
  re-morph the *other* inputs back to their server-rendered defaults and
  silently discard a workspace pick or a checked `can_dispatch` box (review
  finding, phase 11 round 1). Public so `ArbiterWeb.SessionDockLive`'s own
  `validate_launch` calls the same mapping rather than a second copy of it.
  """
  def assign_launch_params(socket, params) do
    previous_available? =
      remote_control_available?(socket.assigns.launch_provider, socket.assigns.launch_auth_mode)

    provider = launch_provider_param(params)
    auth_mode = launch_auth_mode_param(params, provider)
    available? = remote_control_available?(provider, auth_mode)

    # A disabled checkbox never contributes to form params (the browser omits
    # it entirely), so a plain "was `remote_control` => "true" in params?"
    # check can't tell "operator explicitly unchecked it under mode B" apart
    # from "it was disabled under mode A and never sent anything". Mode A ->
    # B is the one transition that must re-arrive checked (§9.5: on when mode
    # B) rather than inheriting whatever mode A's disabled box last rendered —
    # and so is agy -> Claude Code, which disables the box the same way.
    entering_mode_b? = available? and not previous_available?

    valid_workspace_ids = Enum.map(socket.assigns.workspaces, & &1.id)

    socket
    |> Phoenix.Component.assign(:launch_provider, provider)
    |> Phoenix.Component.assign(:launch_auth_mode, auth_mode)
    |> Phoenix.Component.assign(:launch_name, launch_name(params))
    |> Phoenix.Component.assign(
      :launch_workspace_id,
      launch_workspace_id(params, valid_workspace_ids)
    )
    |> Phoenix.Component.assign(:launch_can_dispatch?, launch_can_dispatch?(params))
    # Mode A never shows Remote Control as checked, even if the box was
    # ticked under mode B before the operator switched — otherwise the
    # checkbox renders `checked` and `disabled` at once right above the
    # reason saying it is unavailable (review finding, phase 11 round 2).
    # Mirrors the clamp `launch_defaults/1` applies server-side.
    |> Phoenix.Component.assign(
      :launch_remote_control?,
      available? and (entering_mode_b? or launch_remote_control?(params))
    )
  end

  @doc """
  Resets every §9.5 launch option assign back to its mount default. Called
  after a successful launch so the *next* launch from the same panel starts
  clean instead of echoing the last submission — `can_dispatch` and Remote
  Control both carry forward in the broadening direction otherwise, which
  §10.1 and the moduledoc above require to be a per-launch, explicit choice
  (review finding, phase 11 round 2). Public so `ArbiterWeb.SessionDockLive`'s
  `launch` handler uses the same reset rather than a second copy of it.
  """
  def reset_launch_params(socket) do
    socket
    |> Phoenix.Component.assign(:launch_provider, "claude_code")
    |> Phoenix.Component.assign(:launch_auth_mode, "seeded_credentials")
    |> Phoenix.Component.assign(:launch_name, nil)
    |> Phoenix.Component.assign(:launch_workspace_id, nil)
    |> Phoenix.Component.assign(:launch_can_dispatch?, false)
    # §9.5: on when mode B, which is the default this resets back to.
    |> Phoenix.Component.assign(:launch_remote_control?, true)
  end

  @doc false
  # agy is mode B, always — whatever a crafted submit says.
  def launch_auth_mode_param(params, provider \\ "claude_code")
  def launch_auth_mode_param(_params, "agy"), do: "seeded_credentials"
  def launch_auth_mode_param(%{"auth_mode" => "oauth_token"}, _provider), do: "oauth_token"
  def launch_auth_mode_param(_params, _provider), do: "seeded_credentials"

  # Only the providers the form offers; anything else is Claude Code, so a
  # crafted value never reaches `String.to_existing_atom/1` unvetted.
  @launch_providers ~w(claude_code agy)
  @doc false
  def launch_provider_param(%{"provider" => provider}) when provider in @launch_providers,
    do: provider

  def launch_provider_param(_params), do: "claude_code"

  defp remote_control_available?(provider, auth_mode),
    do: provider == "claude_code" and auth_mode == "seeded_credentials"

  defp launch_auth_mode("oauth_token"), do: :oauth_token
  defp launch_auth_mode(_mode), do: :seeded_credentials

  defp launch_remote_control?(%{"remote_control" => "true"}), do: true
  defp launch_remote_control?(_params), do: false

  # A crafted submit can send any string here — the `<select>` only ever
  # offers ids from `workspaces/0`'s own list, but nothing upstream re-checks
  # that server-side, so a bogus id must fall back to cross-workspace rather
  # than bind the session to a workspace that doesn't exist.
  defp launch_workspace_id(%{"workspace_id" => id}, valid_ids) when is_binary(id) do
    case String.trim(id) do
      "" -> nil
      trimmed -> if trimmed in valid_ids, do: trimmed, else: nil
    end
  end

  defp launch_workspace_id(_params, _valid_ids), do: nil

  defp launch_can_dispatch?(%{"can_dispatch" => "true"}), do: true
  defp launch_can_dispatch?(_params), do: false

  defp launch_name(%{"name" => name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp launch_name(_params), do: nil

  @doc false
  def describe({:provisioning_failed, reason}), do: "provisioning failed (#{inspect(reason)})"
  def describe({:launch_failed, status, _out}), do: "the launch command exited #{status}"
  def describe(reason), do: inspect(reason)

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
        <Domain.index_header
          icon="hero-command-line"
          title="Sessions"
          count={length(@sessions)}
          subtitle="Coordinator sessions Arbiter hosts. They live in their own systemd scope, so they survive an arbiter restart."
          stack_on_mobile
        >
          <:actions>
            <.launch_form
              prefix="launch-session"
              launch_provider={@launch_provider}
              launch_auth_mode={@launch_auth_mode}
              launch_name={@launch_name}
              launch_workspace_id={@launch_workspace_id}
              launch_can_dispatch?={@launch_can_dispatch?}
              launch_remote_control?={@launch_remote_control?}
              workspaces={@workspaces}
            />
          </:actions>
        </Domain.index_header>

        <Core.panel
          title="All sessions"
          meta={"#{@running_count} running"}
          body_class="flex flex-col gap-3"
        >
          <div
            :if={not @sessions_loaded? and is_nil(@sessions_error)}
            id="sessions-loading"
            class="flex items-center gap-2 p-4 text-[12.5px] text-[var(--text-secondary)]"
          >
            <.icon name="hero-arrow-path-micro" class="size-4 shrink-0 animate-spin" />
            Loading sessions…
          </div>

          <div
            :if={@sessions_error}
            id="sessions-error"
            role="alert"
            class="flex items-start gap-3 p-4 rounded-[var(--radius-field)] border border-solid border-[var(--arb-fail-edge)] bg-[var(--arb-fail-wash)] text-[12.5px] text-[var(--arb-fail-text)]"
          >
            <.icon
              name="hero-exclamation-triangle"
              class="size-5 shrink-0 mt-0.5 text-[var(--arb-fail-text)]"
            />
            <div class="grow min-w-0">
              <p class="font-medium">Could not load sessions</p>
              <p class="mt-1 text-[12px] opacity-90">{@sessions_error}</p>
            </div>
            <button
              type="button"
              id="sessions-retry"
              phx-click="retry_sessions"
              class={[
                "shrink-0 px-3 h-[28px] rounded-[var(--radius-field)] cursor-pointer",
                "border border-solid border-[var(--arb-fail-edge)] bg-[var(--surface-chrome)]",
                "text-[12px] text-[var(--text-secondary)] hover:text-[var(--text-primary)] transition-colors"
              ]}
            >
              Retry
            </button>
          </div>

          <div :if={@sessions_loaded? and @sessions == []} id="sessions-empty">
            <Feedback.empty_state
              icon="hero-command-line"
              detail="launching one scaffolds its own workspace, config dir and MCP token"
            >
              No coordinator sessions yet.
            </Feedback.empty_state>
          </div>

          <ul
            :if={@sessions_loaded? and @sessions != []}
            id="sessions-list"
            class="flex flex-col gap-2"
          >
            <li
              :for={session <- @sessions}
              id={"session-#{session.id}"}
              class="flex flex-wrap items-center gap-3 px-3 py-2.5 rounded-[var(--radius-field)] border border-[var(--border-default)] bg-[var(--surface-card)]"
            >
              <Data.status_chip status={session.status} />

              <button
                type="button"
                id={"open-in-dock-#{session.id}"}
                phx-click="open_in_dock"
                phx-value-id={session.id}
                class="text-[13px] font-medium text-[var(--text-primary)] text-left cursor-pointer bg-transparent border-0 hover:underline"
              >
                {DisplayName.resolve(session)}
              </button>

              <span
                id={"session-#{session.id}-short-id"}
                class="font-[family-name:var(--font-mono)] text-[11px] text-[var(--text-label)]"
              >
                {short_id(session.id)}
              </span>

              <span class="text-[12px] text-[var(--text-secondary)] truncate max-w-full sm:max-w-[26rem]">
                {session.cwd}
              </span>

              <span class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]">
                {session.provider} · {session.auth_mode} · {workspace_label(session)}{dispatch_label(
                  session
                )}{remote_control_label(session)}
              </span>

              <.usage_cell
                session_id={session.id}
                usage={@usage_by_session[session.provider_session_id]}
                loading={@usage_loading?}
                error={@usage_error}
              />

              <span :if={session.end_reason} class="text-[11px] text-[var(--text-label)] italic">
                {session.end_reason}
              </span>

              <span class="ml-auto flex items-center gap-2">
                <%!-- Not a navigation: the window opens in the dock, on this
                      page. An ended session opens too, and since bd-3tf4oo its
                      window replays the persisted transcript — so the action
                      says what it will show. Same event, same dock window:
                      this is an entry point, not a second viewer. --%>
                <Core.button
                  id={
                    if session.status == :running,
                      do: "open-in-dock-button-#{session.id}",
                      else: "view-transcript-#{session.id}"
                  }
                  size="sm"
                  variant="secondary"
                  phx-click="open_in_dock"
                  phx-value-id={session.id}
                >
                  {if session.status == :running, do: "Open in dock", else: "View transcript"}
                </Core.button>

                <Core.button
                  :if={session.status == :running}
                  id={"kill-session-#{session.id}"}
                  size="sm"
                  variant="danger"
                  phx-click="confirm_kill"
                  phx-value-id={session.id}
                >
                  Kill
                </Core.button>
              </span>
            </li>
          </ul>
        </Core.panel>

        <Navigation.back_link />
      </div>

      <.kill_modal session={@kill_candidate} />
    </Layouts.app>
    """
  end

  @doc """
  The launch options form, shared with `ArbiterWeb.SessionDockLive`'s roster
  (bd-cdut29: launching without leaving whatever page the operator is on).

  Its markup does not change between surfaces, but each embeds it in its own
  way — this page inline in the index header, the dock as a small panel over
  its roster — so this stays a function component rather than a
  `Phoenix.LiveComponent`: no shared process, and `phx-submit="launch"` /
  `phx-change="validate_launch"` reach whichever LiveView happens to have
  rendered it. Both views implement `validate_launch` (calling
  `assign_launch_params/2` to mirror every option onto its own assign — not
  just `launch_auth_mode` for the disabled-checkbox gating, §8.3, but the
  workspace pick and the `can_dispatch`/`remote_control` checkboxes too, so a
  `phx-change` on one field can't cause LiveView's DOM patch to reset the
  others to their server-rendered defaults) and `launch`
  (calling `Sessions.launch(launch_defaults(params))`, and `describe/1` for
  the failure message) themselves — see `launch_defaults/1` and `describe/1`
  below, both public for the dock to call.

  `prefix` keys every element's DOM id so two instances (this page's and the
  dock's, which renders on `/sessions` too) can never collide. `error` is
  `nil` here: this page reports a failed launch via flash. The dock cannot —
  a nested LiveView's flash never reaches the host page (see
  `SessionDockLive`'s `:error_message` assign) — so it renders its own
  failure message inline through this attr instead.
  """
  attr :prefix, :string, required: true
  attr :launch_provider, :string, default: "claude_code"
  attr :launch_auth_mode, :string, required: true
  attr :launch_name, :string, default: nil
  attr :launch_workspace_id, :string, default: nil
  attr :launch_can_dispatch?, :boolean, default: false
  attr :launch_remote_control?, :boolean, default: false
  attr :workspaces, :list, default: []
  attr :error, :string, default: nil, doc: "an inline launch failure to show, or nil"

  def launch_form(assigns) do
    ~H"""
    <form
      id={"#{@prefix}-form"}
      phx-submit="launch"
      phx-change="validate_launch"
      class="flex flex-wrap items-center gap-2"
    >
      <Forms.input
        type="text"
        name="name"
        id={"#{@prefix}-name"}
        value={@launch_name}
        placeholder="Session name (optional)"
        mono={false}
        size="sm"
      />
      <Forms.select
        name="provider"
        id={"#{@prefix}-provider"}
        size="sm"
        value={@launch_provider}
        options={[{"Claude Code", "claude_code"}, {"agy (Antigravity)", "agy"}]}
      />
      <Forms.select
        name="auth_mode"
        id={"#{@prefix}-auth-mode"}
        size="sm"
        value={@launch_auth_mode}
        disabled={@launch_provider == "agy"}
        options={[
          {"Mode B — seeded credentials", "seeded_credentials"},
          {"Mode A — workspace token", "oauth_token"}
        ]}
      />
      <span
        :if={@launch_provider == "agy"}
        id={"#{@prefix}-provider-reason"}
        class="text-[11px] text-[var(--text-label)]"
      >
        agy runs on your own Google login, with no Remote Control
      </span>
      <%!-- §9.5: cross-workspace unless the operator opts a session into a
            single workspace. --%>
      <Forms.select
        name="workspace_id"
        id={"#{@prefix}-workspace-id"}
        size="sm"
        value={@launch_workspace_id || ""}
        options={[{"Cross-workspace", ""}] ++ Enum.map(@workspaces, &{&1.name, &1.id})}
      />
      <span class="flex items-center gap-1.5">
        <Forms.checkbox
          name="remote_control"
          id={"#{@prefix}-remote-control"}
          value="true"
          checked={@launch_remote_control?}
          disabled={@launch_provider == "agy" or @launch_auth_mode != "seeded_credentials"}
          label="Remote Control"
        />
        <span
          :if={@launch_provider != "agy" and @launch_auth_mode != "seeded_credentials"}
          id={"#{@prefix}-remote-control-reason"}
          class="text-[11px] text-[var(--text-label)]"
        >
          needs mode B — a workspace token (mode A) never bridges (§8.3)
        </span>
      </span>
      <%!-- §10.1: off by default; turning it on is a deliberate pre-launch
            choice, never a silent inherited default. --%>
      <Forms.checkbox
        name="can_dispatch"
        id={"#{@prefix}-can-dispatch"}
        value="true"
        checked={@launch_can_dispatch?}
        label="Can dispatch workers"
      />
      <%!-- Launching is slow (a systemd scope, a `claude` process) and does
            not redirect, so the button stays on screen and under the cursor
            throughout — without this a second click during the launch
            starts a second real session, whose window steals the expanded
            slot from the first (bd-a292yj review, finding 1). --%>
      <Core.button
        id={@prefix}
        type="submit"
        variant="primary"
        phx-disable-with="Launching…"
      >
        <:icon><.icon name="hero-plus" class="size-4" /></:icon>
        Launch session
      </Core.button>
      <p
        :if={@error}
        id={"#{@prefix}-error"}
        role="alert"
        class="w-full text-[11px] text-[var(--arb-fail-text)]"
      >
        {@error}
      </p>
    </form>
    """
  end

  @doc """
  The kill confirmation, shared with `ArbiterWeb.SessionDockLive`.

  Both surfaces can end a session and both must ask first, and a second copy of
  this markup is a second chance for one of them to stop asking. The dock's
  need for it is if anything sharper: its Kill sits in a title bar that is on
  screen on every page, which a page you navigated to deliberately is not.

  Both views implement `cancel_kill` and a `kill` carrying `phx-value-id`.
  """
  attr :session, :any, required: true, doc: "the session to kill, or nil when closed"

  def kill_modal(assigns) do
    ~H"""
    <div :if={@session} id="kill-session-modal" class="modal modal-open">
      <div class="modal-box">
        <h3 class="font-semibold text-lg mb-3">End this session?</h3>
        <p class="text-sm text-base-content/70 mb-3">
          <code class="text-xs">{short_id(@session.id)}</code>
          stops immediately: the tmux server is killed and its systemd scope is stopped, so
          whatever the agent is part-way through is lost. The session's transcript and
          workspace stay on disk.
        </p>
        <div class="modal-action">
          <Core.button id="cancel-kill" variant="ghost" size="sm" phx-click="cancel_kill">
            Cancel
          </Core.button>
          <Core.button
            id="confirm-kill"
            variant="danger"
            size="sm"
            phx-click="kill"
            phx-value-id={@session.id}
          >
            End it
          </Core.button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="cancel_kill"></div>
    </div>
    """
  end

  @doc "The first segment of a session UUID — enough to tell two apart on screen."
  def short_id(id) when is_binary(id), do: id |> String.split("-") |> hd()

  defp workspace_label(%{workspace_id: nil}), do: "cross-workspace"
  defp workspace_label(%{workspace_id: id}), do: id

  # A session row's cost/tokens, or an explicit empty state — never a silent
  # `$0.00` for a session the ledger has no rows for yet (bd-9mrzti).
  attr :session_id, :string, required: true
  attr :usage, :any, required: true, doc: "an `Arbiter.Usage.summarize/1` rollup, or nil"
  attr :loading, :boolean, default: false, doc: "stage 2 of the two-stage load is still out"
  attr :error, :any, default: nil, doc: "stage 2 failed with this message"

  defp usage_cell(assigns) do
    ~H"""
    <span
      :if={@usage}
      id={"session-#{@session_id}-usage"}
      class="text-[11px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
    >
      {Data.format_tokens(@usage.tokens_in)} in / {Data.format_tokens(@usage.tokens_out)} out · {Data.format_usd(
        @usage.total_cost_usd
      )}<span :if={@usage.estimated}> (estimated)</span>
    </span>
    <span
      :if={!@usage and @loading}
      id={"session-#{@session_id}-usage-loading"}
      class="text-[11px] text-[var(--text-label)] italic"
    >
      loading usage…
    </span>
    <span
      :if={!@usage and !@loading and @error}
      id={"session-#{@session_id}-usage-error"}
      class="text-[11px] text-[var(--arb-fail-text)] italic"
    >
      usage unavailable
    </span>
    <span
      :if={!@usage and !@loading and !@error}
      id={"session-#{@session_id}-usage-empty"}
      class="text-[11px] text-[var(--text-label)] italic"
    >
      no usage data
    </span>
    """
  end

  defp dispatch_label(%{can_dispatch: true}), do: " · can dispatch"
  defp dispatch_label(_session), do: ""

  defp remote_control_label(%{remote_control: true, bridge_status: :unavailable}),
    do: " · remote control bridge unavailable"

  defp remote_control_label(%{remote_control: true}), do: " · remote control requested"
  defp remote_control_label(_session), do: ""
end
