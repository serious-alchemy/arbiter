defmodule ArbiterWeb.QuotaTopbarTest do
  @moduledoc """
  The status bar's quota chip (bd-i2gwwn): one concentric-ring object per
  provider the installation uses — the logo in the centre, the 5h window as
  the inner ring and the 7d window as the outer — and the popover it opens,
  which holds the full bars. Also the shared visibility rule, which `/usage`
  reads through the same `LiveHooks` load.

  `ArbiterWeb.QuotaTopbarBrowserTest` covers what needs a layout engine and a
  real click: the fit inside the 46px bar and the popover's interaction.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Quota
  alias Arbiter.Tasks.Workspace

  import ArbiterWeb.QuotaFixtures

  # `render_async/2` waits on every async task the page started (the board's,
  # the inbox's and the quota load), and its 100ms default flakes on a loaded
  # box; a test that times out mid-query also takes the sandbox connection
  # down with it for the tests after it.
  @async_wait 2_000

  # Claude and Antigravity, the providers the operator's own install runs.
  @both %{"agent" => %{"type" => ["claude", "gemini"]}}

  setup do
    ws = Ash.create!(Workspace, %{name: "default", config: @both})
    {:ok, ws: ws}
  end

  defp claude!(ws, u5 \\ "0.24"),
    do: {:ok, _} = Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", u5}])

  defp codex!(ws),
    do:
      {:ok, _} =
        Quota.capture(ws.id, [{"anthropic-ratelimit-unified-5h-utilization", "0.5"}],
          provider: "codex"
        )

  # Reads the row afresh: patching a stale struct back to its own config is a
  # no-op write.
  defp configure!(ws, types) do
    Workspace
    |> Ash.get!(ws.id)
    |> Ash.update!(%{patch: %{"agent" => %{"type" => types}}, unset_paths: []},
      action: :patch_config
    )

    Quota.QuotaCache.invalidate(ws.id)
  end

  defp rings(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#quota-chip [data-ring-provider]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-ring-provider"))
  end

  describe "which providers are shown (the shared visibility rule)" do
    test "a Claude-only installation shows only Claude, even with an Antigravity row", %{
      conn: conn,
      ws: ws
    } do
      configure!(ws, "claude")
      claude!(ws)
      antigravity_quota!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert rings(view) == ["claude"]
      refute has_element?(view, "#quota-popover-antigravity")

      {:ok, usage, _html} = live(conn, "/usage")
      render_async(usage, @async_wait)

      assert has_element?(usage, "#usage-quota-claude")
      refute has_element?(usage, "#usage-quota-antigravity")
    end

    test "an Antigravity-only installation shows no Claude logo, bars or overage", %{
      conn: conn,
      ws: ws
    } do
      configure!(ws, "gemini")

      {:ok, _} =
        Quota.capture(ws.id, [
          {"anthropic-ratelimit-unified-5h-utilization", "1.0"},
          {"anthropic-ratelimit-unified-overage-status", "in_overage"}
        ])

      antigravity_quota!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert rings(view) == ["antigravity"]
      refute has_element?(view, "#quota-topbar svg[aria-label=Claude]")
      refute has_element?(view, "#quota-popover-claude")

      {:ok, usage, _html} = live(conn, "/usage")
      render_async(usage, @async_wait)

      assert has_element?(usage, "#usage-quota-antigravity")
      refute has_element?(usage, "#usage-quota-claude")
      refute has_element?(usage, "#overage-indicator")
    end

    test "codex is shown when the installation runs it", %{conn: conn, ws: ws} do
      configure!(ws, ["claude", "codex"])
      claude!(ws)
      codex!(ws)

      {:ok, view, _html} = live(conn, "/")
      html = render_async(view, @async_wait)

      assert rings(view) == ["claude", "codex"]
      assert html =~ "Codex"

      {:ok, usage, _html} = live(conn, "/usage")
      assert render_async(usage, @async_wait) =~ "Codex"
    end

    test "the override forces a provider on and off", %{conn: conn, ws: ws} do
      configure!(ws, "claude")
      claude!(ws)
      antigravity_quota!(ws)

      {:ok, _} = Arbiter.Settings.set_quota_providers_shown(["antigravity"])
      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      assert rings(view) == ["claude", "antigravity"]

      {:ok, _} = Arbiter.Settings.set_quota_providers_hidden(["claude"])
      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      assert rings(view) == ["antigravity"]
    end

    test "a used provider with no snapshot yet shows a no-data ring and popover entry", %{
      conn: conn,
      ws: ws
    } do
      claude!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert rings(view) == ["claude", "antigravity"]
      assert has_element?(view, "#quota-ring-antigravity[data-ring-state=no-data]")
      assert has_element?(view, "#quota-ring-antigravity-5h[data-ring-state=no-data]")
      assert has_element?(view, "#quota-ring-antigravity-7d[data-ring-state=no-data]")
      refute has_element?(view, "#quota-ring-antigravity [data-ring-arc]")

      assert has_element?(
               view,
               ~s(#quota-ring-antigravity[aria-label="Antigravity: no data yet"])
             )

      assert has_element?(view, "#quota-popover-antigravity [data-quota-no-data]", "No data yet")

      {:ok, usage, _html} = live(conn, "/usage")
      render_async(usage, @async_wait)
      assert has_element?(usage, "#usage-quota-antigravity [data-quota-no-data]", "No data yet")
    end

    test "with nothing visible the chip is gone and /usage says so", %{conn: conn, ws: ws} do
      claude!(ws)
      {:ok, _} = Arbiter.Settings.set_quota_providers_hidden(["claude", "antigravity"])

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      refute has_element?(view, "#quota-topbar")
      refute has_element?(view, "#quota-chip")
      assert has_element?(view, "#app-status-bar #appshell-live")

      {:ok, usage, _html} = live(conn, "/usage")
      render_async(usage, @async_wait)

      assert has_element?(usage, "#usage-quota-empty", "No providers configured")

      assert has_element?(
               usage,
               "#usage-quota-empty a[href='/workspaces/#{ws.id}?section=providers']"
             )
    end

    @tag :capture_log
    test "a failed provider-detection read is the error state, never 'no providers'", %{
      conn: conn
    } do
      :meck.new(Arbiter.Accounts.ProviderSettings, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Arbiter.Accounts.ProviderSettings) end)

      :meck.expect(Arbiter.Accounts.ProviderSettings, :effective, fn _ws, _role, _links ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, "/usage")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-topbar-error")
      assert has_element?(view, "#usage-quota-error")
      refute has_element?(view, "#usage-quota-empty")
    end

    test "a broadcast for an unused provider does not add it", %{conn: conn, ws: ws} do
      configure!(ws, "claude")
      claude!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      broadcast!(antigravity_quota!(ws))

      assert rings(view) == ["claude"]
    end
  end

  describe "the chip" do
    test "one ring object per provider, the same chip for one, two and three", %{
      conn: conn,
      ws: ws
    } do
      configure!(ws, "claude")
      claude!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      assert rings(view) == ["claude"]

      configure!(ws, ["claude", "gemini"])
      antigravity_quota!(ws)
      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      assert rings(view) == ["claude", "antigravity"]

      configure!(ws, ["claude", "gemini", "codex"])
      codex!(ws)
      with_hidden_providers([])
      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      assert rings(view) == ["claude", "antigravity", "codex"]

      for provider <- ~w(claude antigravity codex) do
        # The logo in the centre, inside an inner 5h and an outer 7d ring.
        assert has_element?(view, "#quota-ring-#{provider} svg[data-ring-svg]")
        assert has_element?(view, "#quota-ring-#{provider}-5h[data-ring-window=inner]")
        assert has_element?(view, "#quota-ring-#{provider}-7d[data-ring-window=outer]")
        assert has_element?(view, "#quota-ring-#{provider} [data-ring-logo] svg[role=img]")
        assert has_element?(view, "#quota-popover-#{provider}")
      end

      # The chip is a fixed-height control, hidden only below `sm`.
      assert has_element?(view, "#quota-topbar.max-sm\\:hidden")
      assert has_element?(view, "#quota-chip.h-\\[36px\\]")
      assert has_element?(view, "#appshell-live")
      assert has_element?(view, "#coordinator-inbox-trigger")
      assert has_element?(view, "#theme-toggle")
    end

    test "the ring arc is utilisation; claude and antigravity have the elapsed hairline, codex none",
         %{conn: conn, ws: ws} do
      configure!(ws, ["claude", "gemini", "codex"])
      with_hidden_providers([])
      now = DateTime.to_unix(DateTime.utc_now())

      {:ok, _} =
        Quota.capture(ws.id, [
          {"anthropic-ratelimit-unified-5h-utilization", "0.38"},
          {"anthropic-ratelimit-unified-5h-reset", to_string(now + 9_000)},
          {"anthropic-ratelimit-unified-7d-utilization", "0.41"},
          {"anthropic-ratelimit-unified-7d-reset", to_string(now + 302_400)}
        ])

      antigravity_quota!(ws)
      codex!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-ring-claude-5h[data-ring-pct='38']")
      assert has_element?(view, "#quota-ring-claude-7d[data-ring-pct='41']")
      assert has_element?(view, "#quota-ring-claude-5h [data-ring-hairline]")
      assert has_element?(view, "#quota-ring-claude-7d [data-ring-hairline]")
      assert has_element?(view, "#quota-ring-antigravity-5h [data-ring-hairline]")
      refute has_element?(view, "#quota-ring-codex [data-ring-hairline]")
    end

    test "the popover is a closed disclosure the chip controls", %{conn: conn, ws: ws} do
      claude!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(
               view,
               "button#quota-chip[aria-expanded=false][aria-controls=quota-popover][phx-click]"
             )

      assert has_element?(
               view,
               "#quota-topbar[phx-click-away][phx-window-keydown][phx-key=Escape]"
             )

      assert has_element?(view, "#quota-popover.hidden")
    end
  end

  # bd-clzkvp: the colour is the dispatch gate's pace verdict for the linked
  # account. The ring takes it from the same `quota_pace/3` the bars use.
  describe "ring and bar colour follow the gate's pace verdict" do
    defp link_account!(ws, quota_config) do
      account =
        Ash.create!(Arbiter.Accounts.ProviderAccount, %{
          provider: :claude,
          slug: "acct-#{System.unique_integer([:positive])}",
          quota_config: quota_config
        })

      Ash.create!(Arbiter.Accounts.WorkspaceProviderAccount, %{
        workspace_id: ws.id,
        provider: :claude,
        provider_account_id: account.id
      })
    end

    # `u5` used 10% into the 5h window; `u7` used 29% into the 7d window.
    defp capture!(ws, u5, u7 \\ 0.01) do
      now = DateTime.to_unix(DateTime.utc_now())

      {:ok, _} =
        Quota.capture(ws.id, [
          {"anthropic-ratelimit-unified-5h-utilization", to_string(u5)},
          {"anthropic-ratelimit-unified-5h-reset", to_string(now + round(0.9 * 18_000))},
          {"anthropic-ratelimit-unified-5h-status", "allowed"},
          {"anthropic-ratelimit-unified-7d-utilization", to_string(u7)},
          {"anthropic-ratelimit-unified-7d-reset", to_string(now + round(0.71 * 604_800))},
          {"anthropic-ratelimit-unified-7d-status", "allowed"}
        ])
    end

    test "holding: a paced account's 5h is red, ring and bar, on the top bar and /usage", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{"threshold_mode" => "paced"})
      capture!(ws, 0.4)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-ring-claude-5h[data-ring-state=holding]")
      assert ring_stroke(view, "#quota-ring-claude-5h") =~ "var(--arb-fail)"

      assert has_element?(
               view,
               "#quota-popover-claude-5h[data-quota-state=red][data-quota-hold=enforcing]"
             )

      assert has_element?(
               view,
               "#quota-popover-claude [data-quota-pace-note]",
               "holding dispatch"
             )

      {:ok, usage, _html} = live(conn, "/usage")
      render_async(usage, @async_wait)

      assert has_element?(
               usage,
               "#usage-quota-claude [data-quota-state=red][data-quota-hold=enforcing]"
             )
    end

    test "a flat account's bar is red at the paced thresholds but only would hold", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{})
      capture!(ws, 0.4)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-ring-claude-5h[data-ring-state=holding]")

      assert has_element?(
               view,
               "#quota-popover-claude-5h[data-quota-state=red][data-quota-hold=not_enforcing]"
             )

      assert view |> element("#quota-popover-claude-5h") |> render() =~ "(gate not enforcing)"
    end

    test "approaching: 7d at 35% / 29% elapsed under a 40% floor is amber", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{"threshold_mode" => "paced", "weekly_paced_floor" => 0.4})
      capture!(ws, 0.01, 0.35)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-ring-claude-7d[data-ring-state=approaching]")
      assert ring_stroke(view, "#quota-ring-claude-7d") =~ "var(--arb-attention)"
      assert has_element?(view, "#quota-popover-claude-7d[data-quota-state=amber]")
      refute has_element?(view, "#quota-popover-claude-7d[data-quota-hold]")
    end

    test "ok and sampling, with both windows and statuses stated in words", %{
      conn: conn,
      ws: ws
    } do
      link_account!(ws, %{"threshold_mode" => "paced"})
      capture!(ws, 0.01, 0.1)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-ring-claude-5h[data-ring-state=sampling]")
      assert ring_stroke(view, "#quota-ring-claude-5h") =~ "var(--arb-done)"
      assert has_element?(view, "#quota-ring-claude-7d[data-ring-state=ok]")
      assert ring_stroke(view, "#quota-ring-claude-7d") =~ "var(--arb-live)"

      summary = "Claude: 5h 1%, sampling; 7d 10%, on pace"
      assert has_element?(view, ~s(#quota-ring-claude[role=img][aria-label="#{summary}"]))
      assert has_element?(view, ~s(#quota-ring-claude[title^="#{summary}"]))
    end

    test "a live update keeps the account's gate policy", %{conn: conn, ws: ws} do
      link_account!(ws, %{"threshold_mode" => "paced"})
      capture!(ws, 0.1)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      refute has_element?(view, "#quota-popover-claude-5h[data-quota-hold]")

      capture!(ws, 0.4)

      assert has_element?(view, "#quota-ring-claude-5h[data-ring-state=holding]")

      assert has_element?(
               view,
               "#quota-popover-claude-5h[data-quota-state=red][data-quota-hold=enforcing]"
             )
    end
  end

  describe "antigravity (bd-gukyy1)" do
    test "the popover carries both bucket groups; the rings take the tighter one", %{
      conn: conn,
      ws: ws
    } do
      # Gemini Models 25% / 60% used, Claude and GPT models 10% / 20%.
      antigravity_quota!(ws)

      {:ok, view, _html} = live(conn, "/")
      html = render_async(view, @async_wait)
      doc = LazyHTML.from_fragment(html)

      gemini = "#quota-popover-antigravity-gemini_models"
      claude_gpt = "#quota-popover-antigravity-claude_and_gpt_models"
      assert has_element?(view, gemini, "Gemini Models")
      assert has_element?(view, claude_gpt, "Claude and GPT models")
      assert pcts(doc, gemini) == ["25%", "60%"]
      assert pcts(doc, claude_gpt) == ["10%", "20%"]
      assert labels(doc, gemini) == ["5h", "weekly"]

      assert has_element?(view, "#quota-ring-antigravity-5h[data-ring-pct='25']")
      assert has_element?(view, "#quota-ring-antigravity-7d[data-ring-pct='60']")

      assert has_element?(
               view,
               ~s(#quota-ring-antigravity[aria-label^="Antigravity: 5h 25% \(Gemini Models\)"])
             )
    end

    test "successive broadcasts update the one antigravity entry in place", %{conn: conn, ws: ws} do
      claude!(ws)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)
      assert has_element?(view, "#quota-ring-antigravity[data-ring-state=no-data]")

      broadcast!(antigravity_quota!(ws, gemini_5h_remaining: 90.0))
      broadcast!(antigravity_quota!(ws, gemini_5h_remaining: 30.0))

      doc = view |> render() |> LazyHTML.from_fragment()
      assert doc |> LazyHTML.query("#quota-ring-antigravity") |> Enum.count() == 1
      assert pcts(doc, "#quota-popover-antigravity-gemini_models") == ["70%", "60%"]
      assert has_element?(view, "#quota-ring-antigravity-5h[data-ring-pct='70']")
    end

    test "a stale reading is muted, neutral, with the message in its titles", %{
      conn: conn,
      ws: ws
    } do
      antigravity_quota!(ws, message: agy_missing_message())

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_wait)

      assert has_element?(view, "#quota-ring-antigravity[data-ring-state=stale].opacity-60")
      assert ring_stroke(view, "#quota-ring-antigravity-5h") =~ "var(--arb-done)"

      assert has_element?(
               view,
               ~s(#quota-ring-antigravity[title*="is not installed on this host"])
             )

      assert has_element?(view, "#quota-popover-antigravity [data-quota-bar][data-quota-stale]")

      assert has_element?(
               view,
               ~s(#quota-popover-antigravity [data-quota-bar][title*="is not installed on this host"])
             )
    end

    test "a snapshot with no parseable buckets: one bar, and only the inner ring", %{
      conn: conn,
      ws: ws
    } do
      antigravity_quota!(ws, models: [])

      {:ok, view, _html} = live(conn, "/")
      html = render_async(view, @async_wait)
      doc = LazyHTML.from_fragment(html)

      assert bars(doc, "#quota-popover-antigravity") == 1
      assert labels(doc, "#quota-popover-antigravity") == ["used"]
      assert has_element?(view, "#quota-ring-antigravity-5h [data-ring-arc]")
      assert has_element?(view, "#quota-ring-antigravity-7d[data-ring-state=no-data]")
    end
  end

  defp ring_stroke(view, ring) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{ring} [data-ring-arc]")
    |> LazyHTML.attribute("style")
    |> Enum.join()
  end

  defp bars(doc, scope), do: doc |> LazyHTML.query("#{scope} [data-quota-bar]") |> Enum.count()

  defp labels(doc, scope),
    do:
      doc
      |> LazyHTML.query("#{scope} [data-quota-label]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  defp pcts(doc, scope),
    do:
      doc
      |> LazyHTML.query("#{scope} [data-quota-bar] [data-quota-pct]")
      |> Enum.map(&String.trim(LazyHTML.text(&1)))

  # The production fan-out `CloudCode.refresh/2` ends in: account → every
  # workspace it meters → `{:quota_updated, ws_id, view}`.
  defp broadcast!(row) do
    Arbiter.Quota.Broadcast.quota_updated(
      row.provider_account_id,
      Arbiter.Quota.CloudCode.view(row)
    )
  end
end
