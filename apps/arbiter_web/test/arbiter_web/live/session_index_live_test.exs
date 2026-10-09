defmodule ArbiterWeb.SessionIndexLiveTest do
  @moduledoc """
  `/sessions` — the sessions index (bd-c76fu9 phase 5, bd-9mrzti's cost/tokens
  column, bd-a292yj's move of every per-session control into the dock).

  Since phase 3 of the session dock this is the *only* sessions page: there is
  no `/sessions/:id`, and what used to be tested there — keep_alive, kill from
  the session's own surface, the exit banner, the metadata, the non-loopback
  notice — is in `ArbiterWeb.SessionDockLiveTest`, against the dock window that
  owns it now. What is left here is what the index itself owns: launching,
  naming at launch, listing, handing a session to the dock, and Kill (a fleet
  act, shared with the dock through `SessionIndexLive.kill_modal/1`).

  The cost/tokens column reads `ArbiterWeb.SessionUsage` —
  `Arbiter.Usage.summarize(by: :session)`, the same canonical rollup `arb usage
  --by session` uses — rather than tailing a session's JSONL itself, so those
  tests drive it by writing `Arbiter.Usage.Event` rows, not by faking terminal
  bytes.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Accounts
  alias Arbiter.Agents.Claude
  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Sessions
  alias Arbiter.Test.NoopRunner
  alias Arbiter.Worker.StopReason
  alias Arbiter.Usage.Event
  alias ArbiterWeb.SessionIndexLive, as: ArbiterWebSessionIndex

  setup do
    Arbiter.Test.SessionEnv.sandbox("session-index-usage")
    Arbiter.Test.SessionEnv.launch_accounts!()
    put_env(:sessions_runner, NoopRunner)
    :ok
  end

  defp launch!(opts \\ []) do
    {:ok, session} = Sessions.launch(Keyword.put_new(opts, :runner, NoopRunner))
    session
  end

  # bd-b88x6g: the session list and the usage ledger rollup both load via
  # `start_async` on the connected mount now, in two stages. Every test that
  # wants to see sessions or usage on screen — not the loading state itself —
  # goes through this helper so it isn't racing either stage.
  defp live_sessions!(conn) do
    {:ok, view, _html} = live(conn, ~p"/sessions")
    html = render_async(view)
    {:ok, view, html}
  end

  defp put_env(key, value) do
    previous = Application.fetch_env(:arbiter, key)
    Application.put_env(:arbiter, key, value)

    on_exit(fn ->
      case previous do
        {:ok, old} -> Application.put_env(:arbiter, key, old)
        :error -> Application.delete_env(:arbiter, key)
      end
    end)
  end

  defp create_event!(attrs) do
    base = %{
      task_id: nil,
      source: :coordinator_session,
      step: :other,
      provider: "claude",
      model: "claude-opus-4-7",
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  describe "login sessions are hidden (bd-98oj3s)" do
    test "a :login session never appears in the sessions list", %{conn: conn} do
      coord = launch!()
      login = launch!(kind: :login, login_account: "acct")

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{coord.id}")
      refute has_element?(view, "#session-#{login.id}")
    end
  end

  describe "an ended row's transcript action (bd-3tf4oo)" do
    test "an ended session's action says View transcript", %{conn: conn} do
      session = launch!()
      {:ok, _ended} = Sessions.kill(session.id)

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#view-transcript-#{session.id}", "View transcript")
      refute has_element?(view, "#open-in-dock-button-#{session.id}")
    end

    test "it hands the session to the dock, the same way Open does", %{conn: conn} do
      session = launch!()
      {:ok, _ended} = Sessions.kill(session.id)

      {:ok, view, _html} = live_sessions!(conn)
      render_click(element(view, "#view-transcript-#{session.id}"))

      assert_push_event(view, "session-dock:open", %{id: id})
      assert id == session.id
    end

    test "a running session still says Open in dock", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#open-in-dock-button-#{session.id}", "Open in dock")
      refute has_element?(view, "#view-transcript-#{session.id}")
    end
  end

  describe "the cost/tokens column" do
    test "shows an ended session's final totals, from the same source as `arb usage --by session`",
         %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.record_provider_session(session, "prov-ended-1")

      create_event!(%{
        session_id: "prov-ended-1",
        cost_usd: 1.5,
        tokens_in: 1000,
        tokens_out: 500,
        raw: %{"arb_usage_source" => %{"cost_source" => "cost_state"}}
      })

      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "done")

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}-usage", "$1.50")
      assert has_element?(view, "#session-#{session.id}-usage", "1.0k in")
      refute has_element?(view, "#session-#{session.id}-usage", "estimated")
    end

    test "marks an estimated cost the same way the detail page does", %{conn: conn} do
      session = launch!()
      {:ok, _} = Sessions.record_provider_session(session, "prov-est-1")

      create_event!(%{
        session_id: "prov-est-1",
        cost_usd: 2.0,
        tokens_in: 200,
        tokens_out: 100,
        raw: %{"arb_usage_source" => %{"cost_source" => "estimated"}}
      })

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}-usage", "estimated")
    end

    test "shows an explicit empty state rather than $0.00 when a session has no metering data",
         %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}-usage-empty")
      refute has_element?(view, "#session-#{session.id}-usage", "$0.00")
    end

    test "a running session's figures refresh on the periodic tick without a page reload", %{
      conn: conn
    } do
      session = launch!()
      {:ok, _} = Sessions.record_provider_session(session, "prov-running-1")

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}-usage-empty")

      create_event!(%{
        session_id: "prov-running-1",
        cost_usd: 0.75,
        tokens_in: 300,
        tokens_out: 150,
        raw: %{"arb_usage_source" => %{"cost_source" => "cost_state"}}
      })

      # The tick handler starts the async read; make sure the LiveView has
      # processed the message (so the task exists) before awaiting it.
      send(view.pid, :refresh_session_usage)
      _ = :sys.get_state(view.pid)
      render_async(view)

      assert has_element?(view, "#session-#{session.id}-usage", "$0.75")
      refute has_element?(view, "#session-#{session.id}-usage-empty")
    end
  end

  describe "the sessions list" do
    test "is reachable from the app navigation", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ ~s(href="/sessions")
    end

    test "shows an empty state when nothing has ever been launched", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#sessions-empty")
      refute has_element?(view, "#sessions-list")
    end

    test "lists sessions newest first, each openable in the dock", %{conn: conn} do
      older = launch!()
      newer = launch!()

      {:ok, view, html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{older.id}")
      assert has_element?(view, "#session-#{newer.id}")

      # No link to a session page: there isn't one any more (bd-a292yj). The
      # row opens the session in the dock, on this page.
      refute html =~ ~s(href="/sessions/#{newer.id}")
      assert has_element?(view, "#open-in-dock-#{newer.id}")
      assert has_element?(view, "#open-in-dock-button-#{newer.id}")

      assert [first, second] =
               Regex.scan(~r/id="session-([-0-9a-f]+)"/, html, capture: :all_but_first)

      assert first == [newer.id]
      assert second == [older.id]
    end

    test "the cwd label never forces horizontal scroll on a phone-width viewport", %{conn: conn} do
      launch!()

      {:ok, _view, html} = live_sessions!(conn)

      # A bare `max-w-[26rem]` (416px) is wider than a 375px viewport minus
      # padding, and a flex item with no shrink basis holds that width even
      # while wrapping onto its own line — capping it to the full row width
      # on mobile and only widening to 26rem from sm: up keeps every row
      # inside the viewport.
      assert html =~ "max-w-full sm:max-w-[26rem]"
    end

    test "shows the resolved display name, and the id stays reachable (bd-o2vtsz)", %{conn: conn} do
      named = launch!(name: "refinement session")
      unnamed = launch!()

      {:ok, view, html} = live_sessions!(conn)

      assert html =~ "refinement session"

      assert has_element?(
               view,
               "#session-#{named.id}-short-id",
               Arbiter.Sessions.DisplayName.short_id(named.id)
             )

      assert has_element?(
               view,
               "#session-#{unnamed.id}-short-id",
               Arbiter.Sessions.DisplayName.short_id(unnamed.id)
             )
    end

    test "an ended session is shown as ended, with the reason it ended", %{conn: conn} do
      session = launch!()
      {:ok, _ended} = Sessions.kill(session.id, runner: NoopRunner, reason: "killed by hand")

      {:ok, view, html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}")
      assert html =~ "killed by hand"
    end

    test "a session ending on its own (no Kill click) updates the list live, via PubSub (bd-bsdeb2)",
         %{conn: conn} do
      session = launch!()
      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}", "running")

      # Simulate the Stream noticing a dead pane, or the periodic reaper
      # noticing a vanished scope — either way `mark_ended/2` is the one
      # place that runs, no Kill click involved.
      {:ok, _ended} = Sessions.mark_ended(session, "exited")

      assert render_async(view) =~ "exited"
      assert has_element?(view, "#session-#{session.id}", "ended")
    end

    test "a session with a persisted bridge_status: :unavailable is labeled in the list (bd-cdretj)",
         %{conn: conn} do
      session = launch!(remote_control: true)
      {:ok, session} = Sessions.mark_bridge_unavailable(session)

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}", "remote control bridge unavailable")
    end

    test "a session with remote_control requested but no bridge failure is labeled as requested",
         %{conn: conn} do
      session = launch!(remote_control: true)

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#session-#{session.id}", "remote control requested")
      refute has_element?(view, "#session-#{session.id}", "remote control bridge unavailable")
    end
  end

  # bd-b88x6g: the session list is a `start_async/3` read on the connected
  # mount, not a synchronous one in `mount/3` — the dead render draws nothing
  # but the loading state, and a slow or failed read can never hold the
  # LiveView process itself.
  describe "the async session load (bd-b88x6g)" do
    setup do
      :meck.new(Sessions, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Sessions) end)
      :ok
    end

    # Holds the read in its loader until the test says go, so the loading
    # state is something to assert on rather than a race. A read the test
    # never releases gives up well inside the render_async default timeout
    # and reports itself, so the test fails on `refute_held_load/0`, not on a
    # `render_async` timeout.
    defp hold_sessions_load do
      test = self()

      :meck.expect(Sessions, :list, fn ->
        sessions = :meck.passthrough([])
        send(test, {:loading_sessions, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_sessions_load, self()})
        end

        sessions
      end)
    end

    defp refute_held_load, do: refute_received({:unreleased_sessions_load, _})

    test "the dead render shows the loading state and reads nothing", %{conn: conn} do
      test = self()
      :meck.expect(Sessions, :list, fn -> send(test, :sessions_read) && :meck.passthrough([]) end)

      html = conn |> get(~p"/sessions") |> html_response(200)

      assert html =~ ~s(id="sessions-loading")
      refute html =~ ~s(id="sessions-list")
      refute_received :sessions_read
    end

    test "renders a loading state, then the session list", %{conn: conn} do
      session = launch!()
      hold_sessions_load()

      {:ok, view, _html} = live(conn, ~p"/sessions")
      assert_receive {:loading_sessions, loader}

      assert has_element?(view, "#sessions-loading")
      refute has_element?(view, "#session-#{session.id}")

      send(loader, :release)
      render_async(view)

      refute has_element?(view, "#sessions-loading")
      assert has_element?(view, "#session-#{session.id}")
      refute_held_load()
    end

    @tag :capture_log
    test "a failed load renders an inline error, and Retry recovers", %{conn: conn} do
      session = launch!()
      :meck.expect(Sessions, :list, fn -> raise "database is locked" end)

      {:ok, view, _html} = live(conn, ~p"/sessions")
      render_async(view)

      assert has_element?(view, "#sessions-error", "database is locked")
      refute has_element?(view, "#sessions-loading")
      refute has_element?(view, "#session-#{session.id}")

      :meck.expect(Sessions, :list, fn -> :meck.passthrough([]) end)
      view |> element("#sessions-retry") |> render_click()
      render_async(view)

      refute has_element?(view, "#sessions-error")
      assert has_element?(view, "#session-#{session.id}")
    end

    # bd-b88x6g round 2: a stage-2 (usage) failure must say so per row, not
    # fall through to the "no usage data" empty state — that phrasing is for
    # a session the ledger genuinely has no rows for yet (bd-9mrzti), and
    # reusing it here would tell the operator there is no cost data when the
    # read actually failed.
    @tag :capture_log
    test "a failed usage load renders an inline per-row error, not the empty state", %{
      conn: conn
    } do
      session = launch!()
      :meck.new(ArbiterWeb.SessionUsage, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.SessionUsage) end)

      :meck.expect(ArbiterWeb.SessionUsage, :for_sessions, fn _sessions -> raise "ledger down" end)

      {:ok, view, _html} = live(conn, ~p"/sessions")
      render_async(view)

      assert has_element?(view, "#session-#{session.id}-usage-error")
      refute has_element?(view, "#session-#{session.id}-usage-empty")
    end
  end

  describe "launching" do
    # bd-a292yj: launching no longer navigates. There is nowhere to navigate
    # *to* — the session's window opens in the dock, which is already on this
    # page, so a redirect would only have thrown away what was on screen.
    test "the launch button provisions a session with the phase-5 defaults and opens it in the dock",
         %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#launch-session")

      # Launching is slow and no longer redirects, so the button stays under
      # the cursor for the whole call. Without this a second click starts a
      # second real session (review finding 1).
      assert has_element?(view, ~s(#launch-session[phx-disable-with]))

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert_push_event(view, "session-dock:open", %{id: opened})
      assert opened == session.id

      # §10.1 / the phase-5 scope: mode B, cross-workspace, dispatch off. The
      # full pre-launch options UI is phase 11.
      assert session.auth_mode == :seeded_credentials
      assert session.workspace_id == nil
      assert session.can_dispatch == false
      assert session.status == :running
      assert session.name == nil
    end

    test "an operator-supplied name reaches the session row (bd-o2vtsz)", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"name" => "refinement session"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == "refinement session"
    end

    test "a blank name launches with no name, same as leaving it empty", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view |> form("#launch-session-form", %{"name" => "   "}) |> render_submit()

      assert [session] = Sessions.list()
      assert session.name == nil
    end

    test "a failed launch reports why and leaves the operator on the list", %{conn: conn} do
      put_env(:sessions_runner, Arbiter.Test.FailingSessionRunner)

      {:ok, view, _html} = live_sessions!(conn)

      html = view |> form("#launch-session-form") |> render_submit()

      assert html =~ "Could not launch"
      assert has_element?(view, "#launch-session")
    end
  end

  describe "workspace binding in the launch form (§9.5)" do
    test "defaults to cross-workspace and lists workspaces to opt into", %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-web", prefix: "aw"})

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#launch-session-workspace-id")
      assert render(view) =~ workspace.name

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == nil
    end

    test "selecting a workspace binds the launched session to it", %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-web2", prefix: "aw2"})

      :ok = Arbiter.Test.SessionEnv.launch_accounts!([workspace])

      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"workspace_id" => workspace.id})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == workspace.id
    end

    test "switching auth mode does not silently discard a workspace pick or can_dispatch",
         %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-web3", prefix: "aw3"})

      :ok = Arbiter.Test.SessionEnv.launch_accounts!([workspace])

      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"workspace_id" => workspace.id, "can_dispatch" => "true"})
      |> render_change()

      assert has_element?(view, "#launch-session-can-dispatch[checked]")

      # auth_mode is the only field explicitly changed here — the workspace
      # pick and can_dispatch check must survive this round trip rather than
      # reverting to their server-rendered defaults (review finding, phase 11
      # round 1: a form that re-renders `value=""` / no `checked` regardless
      # of what the operator picked loses those choices the moment any other
      # field triggers a diff).
      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      assert has_element?(view, "#launch-session-can-dispatch[checked]")

      assert has_element?(
               view,
               ~s(#launch-session-workspace-id option[value="#{workspace.id}"][selected])
             )

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.workspace_id == workspace.id
      assert session.can_dispatch == true
    end

    test "a workspace id that does not exist falls back to cross-workspace rather than binding",
         %{conn: conn} do
      # The `<select>` only ever offers real ids, but nothing stops a crafted
      # submit from sending one that doesn't — `launch_workspace_id/2` must
      # refuse it rather than binding the session to a workspace that isn't
      # there (review finding, phase 11 round 4).
      {:ok, view, _html} = live_sessions!(conn)

      # `form/3` refuses to build a submit with a `<select>` value outside
      # its own `<option>` list, so this goes straight at the event — the
      # same way a hand-crafted request would reach `handle_event/3`.
      render_submit(view, "launch", %{"workspace_id" => "not-a-real-workspace-id"})

      assert [session] = Sessions.list()
      assert session.workspace_id == nil
    end
  end

  describe "can_dispatch in the launch form (§10.1)" do
    test "defaults off", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      refute has_element?(view, "#launch-session-can-dispatch[checked]")

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert session.can_dispatch == false
    end

    test "checking the box turns it on explicitly", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"can_dispatch" => "true"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.can_dispatch == true
    end

    test "a second launch from the same view does not inherit the prior can_dispatch choice",
         %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      # `render_change` first, so `can_dispatch: true` is actually latched
      # onto the server assign before the launch that must clear it —
      # `render_submit` alone never fires `phx-change`, so a test that skips
      # this step passes whether or not the reset fix exists (review
      # finding, phase 11 round 3).
      view
      |> form("#launch-session-form", %{"name" => "first", "can_dispatch" => "true"})
      |> render_change()

      assert has_element?(view, "#launch-session-can-dispatch[checked]")

      view
      |> form("#launch-session-form", %{"name" => "first", "can_dispatch" => "true"})
      |> render_submit()

      # The form re-renders after a successful launch; a fresh submit with
      # only a name must not silently carry the prior can_dispatch: true
      # forward (review finding, phase 11 round 2).
      refute has_element?(view, "#launch-session-can-dispatch[checked]")

      view
      |> form("#launch-session-form", %{"name" => "second"})
      |> render_submit()

      assert [%{name: "second", can_dispatch: false}, %{name: "first", can_dispatch: true}] =
               Sessions.list()
    end

    test "a second launch does not inherit the prior session name either", %{conn: conn} do
      # Unlike the dock's launch panel, this page's form is never removed
      # from the DOM after a launch — so if the name input isn't reset
      # server-side, the browser's uncontrolled value survives and a second
      # submit with no `name` param would silently reuse the first session's
      # name (review finding, phase 11 round 4).
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"name" => "first"})
      |> render_change()

      view
      |> form("#launch-session-form", %{"name" => "first"})
      |> render_submit()

      view
      |> form("#launch-session-form", %{})
      |> render_submit()

      assert [%{name: nil}, %{name: "first"}] = Sessions.list()
    end

    test "switching to mode A un-checks a previously-checked Remote Control box",
         %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"remote_control" => "true"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[checked]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[checked]")
    end
  end

  describe "Remote Control gating in the launch form (§8.3)" do
    test "mode B (the default) leaves the Remote Control checkbox enabled and checked, no reason shown",
         %{conn: conn} do
      # §9.5's table: "on when mode B" — a fresh launch panel must arrive
      # checked, not merely enabled (review finding, phase 11 round 4: this
      # shipped off by default through round 3).
      {:ok, view, _html} = live_sessions!(conn)

      refute has_element?(view, "#launch-session-remote-control[disabled]")
      refute has_element?(view, "#launch-session-remote-control-reason")
      assert has_element?(view, "#launch-session-remote-control[checked]")

      view |> form("#launch-session-form") |> render_submit()

      assert [session] = Sessions.list()
      assert session.remote_control == true
    end

    test "selecting mode A disables the checkbox and shows the reason", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      html =
        view
        |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
        |> render_change()

      assert html =~ ~s(id="launch-session-remote-control-reason")

      assert has_element?(view, "#launch-session-remote-control[disabled]")
    end

    test "switching back to mode B re-enables the checkbox", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[disabled]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[disabled]")
    end

    test "switching back to mode B re-checks the box, even after it was un-latched by mode A",
         %{conn: conn} do
      # The checkbox is disabled (and so sends nothing) under mode A, so
      # nothing in the mode-A params can tell "explicitly unchecked" apart
      # from "never touched here". Coming back to mode B must re-arrive
      # checked per §9.5, not carry the disabled box's blank state forward
      # (review finding, phase 11 round 4).
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"auth_mode" => "oauth_token"})
      |> render_change()

      refute has_element?(view, "#launch-session-remote-control[checked]")

      view
      |> form("#launch-session-form", %{"auth_mode" => "seeded_credentials"})
      |> render_change()

      assert has_element?(view, "#launch-session-remote-control[checked]")
    end

    test "launching under mode B with the box checked records remote_control: true",
         %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{
        "auth_mode" => "seeded_credentials",
        "remote_control" => "true"
      })
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.auth_mode == :seeded_credentials
      assert session.remote_control == true
    end

    test "a submission that spoofs remote_control under mode A is still refused server-side",
         %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      # The disabled attribute stops a normal click, but `render_submit/1`
      # posts whatever params it is given — proving `launch_defaults/1`'s own
      # clamp (not just the disabled checkbox) is what keeps this from ever
      # reaching a row. Mode A has no configured token in this test env, so
      # the launch itself fails (a pre-existing gap of this phase-5 form, not
      # this test's concern) — what matters is that `remote_control` was
      # never `true` on the row it left behind.
      view
      |> form("#launch-session-form", %{
        "auth_mode" => "oauth_token",
        "remote_control" => "true"
      })
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.auth_mode == :oauth_token
      assert session.remote_control == false
    end
  end

  describe "provider in the launch form (bd-7xuvfl)" do
    test "defaults to Claude Code and offers agy", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(
               view,
               ~s(#launch-session-provider option[value="claude_code"][selected])
             )

      assert has_element?(view, ~s(#launch-session-provider option[value="agy"]))

      view |> form("#launch-session-form") |> render_submit()

      assert [%{provider: :claude_code}] = Sessions.list()
    end

    test "choosing agy launches an agy session, mode B with no Remote Control", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view
      |> form("#launch-session-form", %{"provider" => "agy", "remote_control" => "true"})
      |> render_submit()

      assert [session] = Sessions.list()
      assert session.provider == :agy
      assert session.status == :running
      assert session.auth_mode == :seeded_credentials
      assert session.remote_control == false
      assert session.config_dir == nil
    end

    test "agy disables the Claude-only options and says why", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view |> form("#launch-session-form", %{"provider" => "agy"}) |> render_change()

      assert has_element?(view, "#launch-session-auth-mode[disabled]")
      assert has_element?(view, "#launch-session-remote-control[disabled]")
      refute has_element?(view, "#launch-session-remote-control[checked]")
      assert has_element?(view, "#launch-session-provider-reason")

      # …and switching back restores Claude Code's defaults.
      view |> form("#launch-session-form", %{"provider" => "claude_code"}) |> render_change()

      refute has_element?(view, "#launch-session-auth-mode[disabled]")
      assert has_element?(view, "#launch-session-remote-control[checked]")
      refute has_element?(view, "#launch-session-provider-reason")
    end

    test "a crafted submit cannot put agy in mode A or pick an unknown provider",
         %{conn: conn} do
      assert {:ok, opts} =
               ArbiterWebSessionIndex.launch_defaults(%{
                 "provider" => "agy",
                 "auth_mode" => "oauth_token",
                 "remote_control" => "true"
               })

      assert opts[:auth_mode] == :seeded_credentials
      assert opts[:remote_control] == false

      assert {:error, {:provider_unavailable, "not_a_provider"}} =
               ArbiterWebSessionIndex.launch_defaults(%{"provider" => "not_a_provider"})

      {:ok, _view, _html} = live_sessions!(conn)
    end

    test "a second launch does not inherit the prior provider choice", %{conn: conn} do
      {:ok, view, _html} = live_sessions!(conn)

      view |> form("#launch-session-form", %{"provider" => "agy"}) |> render_submit()

      assert has_element?(
               view,
               ~s(#launch-session-provider option[value="claude_code"][selected])
             )
    end
  end

  describe "which providers the launch form offers (bd-8qoxst)" do
    # A provider whose accounts are all soft-deleted is not offered.
    defp delete_account!(ref), do: {:ok, _} = Accounts.delete_account(ref)

    defp expire_claude! do
      reason = %StopReason{
        category: :auth_expired,
        summary: "API Error: 401",
        remediation: "Re-authenticate",
        exit_status: 1,
        signal: nil
      }

      CredentialWatchdog.mark_expired(Claude, reason, CredentialWatchdog, :periodic_probe)
      on_exit(fn -> CredentialWatchdog.clear(Claude) end)
    end

    test "a provider with no live account is not listed", %{conn: conn} do
      delete_account!("antigravity:default")

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, ~s(#launch-session-provider option[value="claude_code"]))
      refute has_element?(view, ~s(#launch-session-provider option[value="agy"]))
    end

    test "a provider whose CLI is not on the host is not listed", %{conn: conn} do
      previous = Application.fetch_env!(:arbiter, :sessions_find_executable)

      Application.put_env(:arbiter, :sessions_find_executable, fn
        "agy" -> nil
        name -> name
      end)

      on_exit(fn -> Application.put_env(:arbiter, :sessions_find_executable, previous) end)

      {:ok, view, _html} = live_sessions!(conn)

      refute has_element?(view, ~s(#launch-session-provider option[value="agy"]))
    end

    test "an unhealthy provider is listed disabled, with the reason", %{conn: conn} do
      expire_claude!()

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(
               view,
               ~s(#launch-session-provider option[value="claude_code"][disabled])
             )

      assert has_element?(view, "#launch-session-provider-claude_code-unavailable", "expired")
      refute has_element?(view, ~s(#launch-session-provider option[value="agy"][disabled]))
    end

    test "with the default unavailable, the first healthy provider is pre-selected",
         %{conn: conn} do
      expire_claude!()

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, ~s(#launch-session-provider option[value="agy"][selected]))
      refute has_element?(view, "#launch-session[disabled]")

      view |> form("#launch-session-form") |> render_submit()
      assert [%{provider: :agy}] = Sessions.list()
    end

    test "with nothing launchable, Launch is disabled and points at /providers",
         %{conn: conn} do
      delete_account!("claude:default")
      delete_account!("antigravity:default")

      {:ok, view, _html} = live_sessions!(conn)

      assert has_element?(view, "#launch-session[disabled]")
      assert has_element?(view, ~s(#launch-session-providers-link[href="/providers"]))

      render_submit(view, "launch", %{"provider" => "claude_code"})
      assert Sessions.list() == []
    end

    test "picking a workspace re-derives the list from that workspace's joined accounts",
         %{conn: conn} do
      {:ok, workspace} =
        Ash.create(Arbiter.Tasks.Workspace, %{name: "acme-claude-only", prefix: "acl"})

      {:ok, claude} = Accounts.get_account("claude:default")
      {:ok, _} = Accounts.attach_workspace(workspace.id, :claude, claude.id)

      {:ok, view, _html} = live_sessions!(conn)
      assert has_element?(view, ~s(#launch-session-provider option[value="agy"]))

      view |> form("#launch-session-form", %{"workspace_id" => workspace.id}) |> render_change()

      assert has_element?(view, ~s(#launch-session-provider option[value="claude_code"]))
      refute has_element?(view, ~s(#launch-session-provider option[value="agy"]))
    end

    test "a hidden provider is rejected server-side", %{conn: conn} do
      delete_account!("antigravity:default")

      {:ok, view, _html} = live_sessions!(conn)
      render_submit(view, "launch", %{"provider" => "agy"})

      assert Sessions.list() == []
      assert render(view) =~ "not available"
    end

    test "a disabled provider is rejected server-side, not swapped for another",
         %{conn: conn} do
      expire_claude!()

      {:ok, view, _html} = live_sessions!(conn)
      render_submit(view, "launch", %{"provider" => "claude_code"})

      assert Sessions.list() == []
    end

    test "launch_defaults/1 refuses an unavailable or unknown provider" do
      delete_account!("antigravity:default")

      assert {:ok, opts} = ArbiterWebSessionIndex.launch_defaults(%{"provider" => "claude_code"})
      assert opts[:provider] == :claude_code

      assert {:error, {:provider_unavailable, "agy"}} =
               ArbiterWebSessionIndex.launch_defaults(%{"provider" => "agy"})

      assert {:error, {:provider_unavailable, "not_a_provider"}} =
               ArbiterWebSessionIndex.launch_defaults(%{"provider" => "not_a_provider"})
    end
  end

  describe "killing" do
    test "kill asks for confirmation first and does nothing until it gets one", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live_sessions!(conn)

      refute has_element?(view, "#kill-session-modal")

      view |> element("#kill-session-#{session.id}") |> render_click()
      assert has_element?(view, "#kill-session-modal")

      # Still running: opening the confirmation is not the action.
      assert {:ok, %{status: :running}} = Sessions.get(session.id)

      view |> element("#cancel-kill") |> render_click()
      refute has_element?(view, "#kill-session-modal")
      assert {:ok, %{status: :running}} = Sessions.get(session.id)
    end

    test "confirming the kill ends the session and says so in the list", %{conn: conn} do
      session = launch!()

      {:ok, view, _html} = live_sessions!(conn)

      view |> element("#kill-session-#{session.id}") |> render_click()
      view |> element("#confirm-kill") |> render_click()
      html = render_async(view)

      assert {:ok, %{status: :ended}} = Sessions.get(session.id)
      refute has_element?(view, "#kill-session-modal")
      assert html =~ "ended"
    end
  end
end
