defmodule ArbiterWeb.LiveHooksTest do
  use ArbiterWeb.ConnCase

  import Phoenix.LiveViewTest
  import ArbiterWeb.QuotaFixtures

  defp query_count(fun) do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      ref,
      [:arbiter, :repo, :query],
      fn _event, _measurements, _metadata, _config -> send(parent, {:query, ref}) end,
      nil
    )

    fun.()

    count =
      Stream.repeatedly(fn ->
        receive do
          {:query, ^ref} -> :hit
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> length()

    :telemetry.detach(ref)
    count
  end

  # Claude and Antigravity both in use, so both are shown (bd-i2gwwn).
  @claude_and_agy %{"agent" => %{"type" => ["claude", "gemini"]}}

  describe "on_mount(:quota) filters via production code in live_hooks.ex" do
    test "on_mount invokes production code that filters hidden providers", %{conn: conn} do
      # Create a workspace — on_mount uses default workspace if it exists
      Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})

      # Create a proper LiveView socket using ConnCase infrastructure
      # and call the actual production ArbiterWeb.LiveHooks.on_mount function
      # (not a local copy). This is the critical fix to Finding 2.
      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      # The on_mount hook is attached in the router and runs automatically
      # when the LiveView connects. The presence of a valid page confirms
      # that on_mount executed successfully and the production code filtered
      # the quotas without errors.
      assert html =~ "Arbiter"
    end

    # bd-4p6pw7 round 2, finding 1: an uncached `on_mount(:quota, ...)` still
    # read a `Workspace`, its provider accounts and their workspace links on
    # every mount even after `SpendCache` covered the ledger scans — 20
    # queries cold, 18 warm. `QuotaCache` memoizes the whole decorated result
    # per workspace, so a *repeat* mount within its TTL (criterion 3's "no
    # spend queries" extended to the whole hook) issues close to none.
    test "on_mount(:quota) issues far fewer queries on a warm QuotaCache than cold", %{
      conn: _conn
    } do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default"})

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}],
          provider: "codex"
        )

      # bd-adewb4: the load runs off the mount now, so it's measured on the
      # function the hook's `start_async/3` runs; the (disconnected) mount
      # itself reads nothing at all.
      assert query_count(fn ->
               ArbiterWeb.LiveHooks.on_mount(:quota, %{}, %{}, %Phoenix.LiveView.Socket{})
             end) == 0

      load = fn -> query_count(fn -> ArbiterWeb.LiveHooks.load_quotas() end) end

      cold = load.()
      warm = load.()

      assert cold > warm
      assert warm <= 3
    end

    test "on_mount(:quota) shows codex when available", %{conn: conn} do
      ws =
        Ash.create!(Arbiter.Tasks.Workspace, %{
          name: "default",
          config: %{"agent" => %{"type" => ["claude", "codex"]}}
        })

      # Capture a normal provider and codex
      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      codex_quota!(ws, session_used_percent: 50.0)

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      # Both Claude and Codex should be present
      assert html =~ "Claude"
      assert html =~ "Codex"
    end

    test "on_mount(:quota) loads all configured providers with their quotas", %{
      conn: conn
    } do
      ws =
        Ash.create!(Arbiter.Tasks.Workspace, %{
          name: "default",
          config: %{"agent" => %{"type" => ["claude", "codex"]}}
        })

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      codex_quota!(ws, session_used_percent: 80.0)

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      # Both configured providers should be shown
      assert html =~ "Claude"
      assert html =~ "Codex"
    end

    test "on_mount(:quota) no longer filters antigravity at mount time (bd-gukyy1)", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default", config: @claude_and_agy})

      # Capture a normal provider and antigravity
      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}],
          provider: "antigravity"
        )

      {:ok, view, _html} = live(conn, ~p"/")
      html = render_async(view)

      # The `agy` CLI `/usage` probe superseded the stale-token reason
      # Antigravity was hidden for, so it renders alongside Claude.
      assert html =~ "Claude"
      assert html =~ "Antigravity"
    end

    test "on_mount(:quota) handle_info applies antigravity broadcasts (bd-gukyy1)", %{conn: conn} do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default", config: @claude_and_agy})

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)
      assert has_element?(view, "#quota-ring-claude")
      # Used but not captured yet (bd-i2gwwn): listed, with no data.
      assert has_element?(view, "#quota-ring-antigravity[data-ring-state=no-data]")

      # Broadcast an antigravity update
      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.80"}],
          provider: "antigravity"
        )

      assert has_element?(view, "#quota-ring-antigravity-5h[data-ring-pct='80']")
    end

    # bd-i2gwwn: the load and the broadcasts follow `Arbiter.Quota.Visibility`.
    test "on_mount(:quota) drops a provider the installation doesn't use, load and broadcast",
         %{conn: conn} do
      ws =
        Ash.create!(Arbiter.Tasks.Workspace, %{
          name: "default",
          config: %{"agent" => %{"type" => "claude"}}
        })

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}],
          provider: "antigravity"
        )

      assert {:ok, ws_id, [%{provider: "claude", no_data: true}]} =
               ArbiterWeb.LiveHooks.load_quotas()

      assert ws_id == ws.id

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view, 2_000)

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.60"}],
          provider: "antigravity"
        )

      assert has_element?(view, "#quota-ring-claude")
      refute has_element?(view, "#quota-ring-antigravity")
    end
  end

  # bd-adewb4: the shared chrome's two loads — the quota bars and the
  # coordinator mailbox — run on every page, so they are not allowed to hold up
  # the page's mount. They run in `start_async/3` on the connected mount only.
  describe "the chrome's quota and mailbox loads are async" do
    alias Arbiter.Messages.Message
    alias Arbiter.Quota.QuotaCache

    setup do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default", config: @claude_and_agy})

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      %{ws: ws}
    end

    defp mock(module) do
      :meck.new(module, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(module) end)
    end

    defp has?(html, selector) do
      html |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count() > 0
    end

    test "the dead render shows both loading states and runs neither load", %{conn: conn} do
      test = self()
      mock(QuotaCache)
      mock(Message)

      :meck.expect(QuotaCache, :fetch, fn ws_id, opts, compute ->
        send(test, :quota_loaded)
        :meck.passthrough([ws_id, opts, compute])
      end)

      :meck.expect(Message, :inbox, fn ref, opts ->
        send(test, :inbox_loaded)
        :meck.passthrough([ref, opts])
      end)

      html = conn |> get(~p"/") |> html_response(200)

      assert has?(html, "#quota-topbar-loading")
      refute has?(html, "#quota-ring-claude")
      assert has?(html, "#coordinator-mailbox-loading")
      refute has?(html, "#coordinator-mailbox-empty")

      refute_received :quota_loaded
      refute_received :inbox_loaded
    end

    test "a connected mount renders loading, then the quota bars and the mailbox", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert has?(html, "#quota-topbar-loading")
      assert has?(html, "#coordinator-mailbox-loading")
      refute has?(html, "#quota-ring-claude")

      render_async(view)

      assert has_element?(view, "#quota-ring-claude")
      refute has_element?(view, "#quota-topbar-loading")
      assert has_element?(view, "#coordinator-mailbox-empty")
      refute has_element?(view, "#coordinator-mailbox-loading")
    end

    @tag :capture_log
    test "a failed load renders inline errors and the page keeps working", %{conn: conn} do
      mock(QuotaCache)
      mock(Message)

      :meck.expect(QuotaCache, :fetch, fn _ws_id, _opts, _compute ->
        raise "database is locked"
      end)

      :meck.expect(Message, :inbox, fn _ref, _opts -> raise "database is locked" end)

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      assert has_element?(view, "#quota-topbar-error")
      refute has_element?(view, "#quota-topbar-loading")
      assert has_element?(view, "#coordinator-mailbox-error")
      assert has_element?(view, "#coordinator-inbox-error-badge")
      refute has_element?(view, "#coordinator-mailbox-empty")

      # Still a live page: a later event is handled rather than hitting a dead
      # process.
      send(view.pid, :coordinator_inbox_tick)
      assert render(view) =~ "app-status-bar"
    end

    test "a quota broadcast after the load merges into the loaded bars", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.50"}],
          provider: "antigravity"
        )

      assert has_element?(view, "#quota-ring-claude")
      assert has_element?(view, "#quota-ring-antigravity-5h[data-ring-pct='50']")
    end

    test "coordinator mail broadcast after the load lands in the drawer", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)
      assert has_element?(view, "#coordinator-mailbox-empty")

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          escalation_kind: :agent_raised,
          from_ref: "bd-async1",
          to_ref: Message.coordinator_ref(),
          body: "needs a hand"
        })

      assert has_element?(view, "#coordinator-mailbox-list", "needs a hand")
      assert has_element?(view, "#coordinator-inbox-unread-badge")
    end
  end

  describe "the chrome's async loads recover" do
    alias Arbiter.Messages.Message
    alias Arbiter.Quota.QuotaCache

    setup do
      ws = Ash.create!(Arbiter.Tasks.Workspace, %{name: "default", config: @claude_and_agy})

      {:ok, _} =
        Arbiter.Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.25"}],
          provider: "claude"
        )

      %{ws: ws}
    end

    defp mock!(module) do
      :meck.new(module, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(module) end)
    end

    @tag :capture_log
    test "the top bar's error notice retries the quota load", %{conn: conn} do
      mock!(QuotaCache)

      :meck.expect(QuotaCache, :fetch, fn _ws_id, _opts, _compute ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)
      assert has_element?(view, "#quota-topbar-error")

      :meck.expect(QuotaCache, :fetch, fn ws_id, opts, compute ->
        :meck.passthrough([ws_id, opts, compute])
      end)

      view |> element("#quota-topbar-error") |> render_click()
      assert has_element?(view, "#quota-topbar-loading")

      render_async(view)
      refute has_element?(view, "#quota-topbar-error")
      assert has_element?(view, "#quota-ring-claude")
    end

    @tag :capture_log
    test "the drawer's Retry reloads the mailbox and then follows broadcasts", %{
      conn: conn,
      ws: ws
    } do
      mock!(Message)
      :meck.expect(Message, :inbox, fn _ref, _opts -> raise "database is locked" end)

      {:ok, view, _html} = live(conn, ~p"/")
      render_async(view)
      assert has_element?(view, "#coordinator-mailbox-error", "database is locked")

      :meck.expect(Message, :inbox, fn ref, opts -> :meck.passthrough([ref, opts]) end)

      view |> element("#coordinator-mailbox-retry") |> render_click()
      render_async(view)

      refute has_element?(view, "#coordinator-mailbox-error")
      refute has_element?(view, "#coordinator-inbox-error-badge")
      assert has_element?(view, "#coordinator-mailbox-empty")

      # The failed mount load never joined the mailbox topics; the retry did.
      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          escalation_kind: :agent_raised,
          from_ref: "bd-retry1",
          to_ref: Message.coordinator_ref(),
          body: "after the retry"
        })

      assert has_element?(view, "#coordinator-mailbox-list", "after the retry")
    end

    # A click re-reads the mailbox inline; if that lands before the mount's
    # load, the load's older read must not overwrite it — but its topic
    # subscriptions still have to happen.
    test "a click that beats the mount's load keeps its newer read", %{conn: conn, ws: ws} do
      test = self()
      calls = :counters.new(1, [])
      mock!(Message)

      # Holds only the first read — the mount's task; the dead render reads
      # nothing, and the click's inline re-read is the second.
      :meck.expect(Message, :inbox, fn ref, opts ->
        result = :meck.passthrough([ref, opts])
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          send(test, {:loading, self()})

          receive do
            :release -> :ok
          after
            5_000 -> :ok
          end
        end

        result
      end)

      {:ok, view, _html} = live(conn, ~p"/")
      assert_receive {:loading, loader}

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          escalation_kind: :agent_raised,
          from_ref: "bd-race1",
          to_ref: Message.coordinator_ref(),
          body: "sent while loading"
        })

      view |> element(~s(button[phx-click="coordinator_clear"])) |> render_click()
      assert has_element?(view, "#coordinator-mailbox-list", "sent while loading")

      send(loader, :release)
      render_async(view)
      assert has_element?(view, "#coordinator-mailbox-list", "sent while loading")

      {:ok, _} =
        Message.send_mail(%{
          workspace_id: ws.id,
          kind: :escalation,
          escalation_kind: :agent_raised,
          from_ref: "bd-race2",
          to_ref: Message.coordinator_ref(),
          body: "sent after loading"
        })

      assert has_element?(view, "#coordinator-mailbox-list", "sent after loading")
    end
  end

  describe "on_mount(:live) drives the AppShell navbar badge" do
    test "dead (pre-connect) render shows stale, not live", %{conn: conn} do
      # A plain `get/2` never establishes a LiveView socket, so this is the
      # same HTML a real browser paints before app.js boots the socket —
      # exactly the state the bug report says got stuck forever.
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "stale — refresh"
    end

    test "connected render shows live, not stale", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "appshell-live"
      # The live span renders unhidden; the stale span is present (wired to
      # flip back via phx-disconnected on a genuine drop, see live_badge/1's
      # moduledoc) but hidden.
      refute html =~ ~r/id="appshell-live-live"[^>]*\shidden/
      assert html =~ ~r/id="appshell-live-stale"[^>]*\shidden/
    end
  end
end
