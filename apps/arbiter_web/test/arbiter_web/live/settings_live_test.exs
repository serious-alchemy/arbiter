defmodule ArbiterWeb.SettingsLiveTest do
  @moduledoc """
  `/settings` (bd-3tnoi9): the install-wide settings in one place — the
  scheduler's concurrency cap and autopilot switch, the credential watchdog's
  adapters and intervals, the theme switcher, and a read-only About section.

  Every save goes through `ArbiterWeb.InstallationSettings` (the board's cap
  form shares it), so a bad value is refused before anything is written.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Settings

  setup do
    Autopilot.resume(Autopilot)
    reset_settings()

    on_exit(fn ->
      reset_settings()
      Autopilot.pause(Autopilot)
    end)

    :ok
  end

  defp reset_settings do
    {:ok, _} = Settings.set_conductor_system_max_concurrent(nil)
    {:ok, _} = Settings.set_credential_watchdog_adapters(nil)
    {:ok, _} = Settings.set_credential_watchdog_interval_ms(nil)
    {:ok, _} = Settings.set_credential_watchdog_recovery_interval_ms(nil)
    {:ok, _} = Settings.set_output_offload_enabled(nil)
  end

  defp live_settings(conn) do
    {:ok, view, _html} = live(conn, ~p"/settings")
    view
  end

  defp submit(view, form, params), do: view |> form(form, params) |> render_submit()

  describe "output-offload switch" do
    test "ships off, and the buttons turn it on, off and back to the default", %{conn: conn} do
      view = live_settings(conn)
      assert has_element?(view, "#settings-output_offload-effective", "off")
      assert has_element?(view, "#settings-output_offload-source", "default")

      view |> element("#settings-output_offload-btn-on") |> render_click()
      assert Settings.output_offload_enabled() == true
      assert has_element?(view, "#settings-output_offload-effective", "on")
      assert has_element?(view, "#settings-output_offload-source", "override")

      view |> element("#settings-output_offload-btn-off") |> render_click()
      assert Settings.output_offload_enabled() == false

      view |> element("#settings-output_offload-btn-default") |> render_click()
      assert Settings.output_offload_enabled() == nil
      assert has_element?(view, "#settings-output_offload-source", "default")
    end
  end

  describe "the route and the nav" do
    test "mounts under /settings", %{conn: conn} do
      view = live_settings(conn)
      assert has_element?(view, "#settings-page")
      assert has_element?(view, "#settings-scheduler")
      assert has_element?(view, "#settings-watchdog")
      assert has_element?(view, "#settings-appearance")
      assert has_element?(view, "#settings-about")
    end

    test "Settings is the active item in the Config group of the rail", %{conn: conn} do
      view = live_settings(conn)

      assert has_element?(
               view,
               ~s(#nav-rail a[aria-current="page"][href="/settings"]),
               "Settings"
             )
    end
  end

  describe "system max concurrent workers" do
    test "shows the default, marked as not overridden, when nothing is set", %{conn: conn} do
      view = live_settings(conn)

      assert has_element?(view, "#settings-concurrency[data-override='false']")
      default = to_string(Arbiter.Board.Snapshot.default_system_max_concurrent())
      assert has_element?(view, "#settings-concurrency-effective", default)
      assert has_element?(view, "#settings-concurrency-default", default)
    end

    test "saving a positive integer persists it and marks the override", %{conn: conn} do
      view = live_settings(conn)

      submit(view, "#settings-concurrency-form", %{"value" => "3"})

      assert Settings.conductor_system_max_concurrent() == 3
      assert has_element?(view, "#settings-concurrency[data-override='true']")
      assert has_element?(view, "#settings-concurrency-effective", "3")
      assert has_element?(view, "#toast-info", "set to 3")
    end

    test "a blank value clears the override", %{conn: conn} do
      {:ok, 3} = Settings.set_conductor_system_max_concurrent(3)
      view = live_settings(conn)
      assert has_element?(view, "#settings-concurrency[data-override='true']")

      submit(view, "#settings-concurrency-form", %{"value" => "  "})

      assert Settings.conductor_system_max_concurrent() == nil
      assert has_element?(view, "#settings-concurrency[data-override='false']")
    end

    test "invalid input shows an inline error and changes nothing", %{conn: conn} do
      {:ok, 5} = Settings.set_conductor_system_max_concurrent(5)
      view = live_settings(conn)

      for bad <- ["0", "-2", "abc", "1.5", "3 workers"] do
        submit(view, "#settings-concurrency-form", %{"value" => bad})

        assert has_element?(
                 view,
                 "#settings-concurrency-field[data-invalid='true']",
                 "positive whole number"
               )

        assert Settings.conductor_system_max_concurrent() == 5
      end
    end

    test "a change made elsewhere shows without a refresh", %{conn: conn} do
      view = live_settings(conn)
      assert has_element?(view, "#settings-concurrency[data-override='false']")

      {:ok, 7} = Settings.set_conductor_system_max_concurrent(7)

      assert render(view) =~ "settings-concurrency"
      assert has_element?(view, "#settings-concurrency[data-override='true']")
      assert has_element?(view, "#settings-concurrency-effective", "7")
    end
  end

  describe "autopilot" do
    test "shows running, and who changed it and when", %{conn: conn} do
      :ok = Autopilot.pause(Autopilot, "the-test")
      :ok = Autopilot.resume(Autopilot, "the-test")

      view = live_settings(conn)

      assert has_element?(view, "#settings-autopilot[data-state='running']")
      assert has_element?(view, "#settings-autopilot-changed", "the-test")
    end

    test "pause stops the queue draining; resume restarts it", %{conn: conn} do
      view = live_settings(conn)
      assert has_element?(view, "#settings-autopilot[data-state='running']")
      assert has_element?(view, "#settings-autopilot-toggle[data-confirm]")

      view |> element("#settings-autopilot-toggle") |> render_click()
      assert Autopilot.paused?(Autopilot)
      assert has_element?(view, "#settings-autopilot[data-state='paused']")
      assert has_element?(view, "#settings-autopilot-changed", "operator:test via dashboard")
      refute has_element?(view, "#settings-autopilot-toggle[data-confirm]")

      assert [%{paused: true, actor: "operator:test", surface: "dashboard"} | _] =
               Arbiter.Settings.scheduler_changes()

      view |> element("#settings-autopilot-toggle") |> render_click()
      refute Autopilot.paused?(Autopilot)
      assert has_element?(view, "#settings-autopilot[data-state='running']")
    end

    test "a pause made elsewhere (the board, the CLI) shows without a refresh", %{conn: conn} do
      view = live_settings(conn)

      :ok = Autopilot.pause(Autopilot, "elsewhere")

      assert render(view) =~ "settings-autopilot"
      assert has_element?(view, "#settings-autopilot[data-state='paused']")
    end
  end

  describe "credential watchdog adapters" do
    test "unset means all, and says so", %{conn: conn} do
      view = live_settings(conn)

      assert has_element?(view, "#settings-adapters[data-override='false']")
      assert has_element?(view, "#settings-adapters-mode-all[checked]")
      assert has_element?(view, "#settings-adapters-effective", "claude")
    end

    test "an explicit list is stored as that list", %{conn: conn} do
      view = live_settings(conn)

      submit(view, "#settings-adapters-form", %{
        "mode" => "only",
        "adapters" => ["claude", "codex"]
      })

      assert Settings.credential_watchdog_adapters() == ["claude", "codex"]
      assert has_element?(view, "#settings-adapters[data-override='true']")
      assert has_element?(view, "#settings-adapters-mode-only[checked]")
      assert has_element?(view, "#settings-adapter-claude[checked]")
      assert has_element?(view, "#settings-adapter-codex[checked]")
      refute has_element?(view, "#settings-adapter-gemini[checked]")
    end

    test "none is [] — distinct from unset", %{conn: conn} do
      view = live_settings(conn)

      submit(view, "#settings-adapters-form", %{"mode" => "none"})

      assert Settings.credential_watchdog_adapters() == []
      assert has_element?(view, "#settings-adapters[data-override='true']")
      assert has_element?(view, "#settings-adapters-mode-none[checked]")
      assert has_element?(view, "#settings-adapters-effective", "none")
    end

    test "all clears an existing override back to nil", %{conn: conn} do
      {:ok, []} = Settings.set_credential_watchdog_adapters([])
      view = live_settings(conn)
      assert has_element?(view, "#settings-adapters-mode-none[checked]")

      submit(view, "#settings-adapters-form", %{"mode" => "all"})

      assert Settings.credential_watchdog_adapters() == nil
      assert has_element?(view, "#settings-adapters[data-override='false']")
      assert has_element?(view, "#settings-adapters-mode-all[checked]")
    end

    test "only with nothing ticked is refused rather than quietly becoming none", %{conn: conn} do
      {:ok, ["claude"]} = Settings.set_credential_watchdog_adapters(["claude"])
      view = live_settings(conn)

      # The form's current ticks are posted too; untick them all.
      submit(view, "#settings-adapters-form", %{"mode" => "only", "adapters" => []})

      assert has_element?(view, "#settings-adapters-field[data-invalid='true']")
      assert Settings.credential_watchdog_adapters() == ["claude"]
    end
  end

  for {id, label, getter, setter, default} <- [
        {"interval", "interval", :credential_watchdog_interval_ms,
         :set_credential_watchdog_interval_ms, :interval_ms},
        {"recovery", "recovery interval", :credential_watchdog_recovery_interval_ms,
         :set_credential_watchdog_recovery_interval_ms, :recovery_interval_ms}
      ] do
    describe "credential watchdog #{label}" do
      test "shows the default, marked as not overridden", %{conn: conn} do
        view = live_settings(conn)

        assert has_element?(view, "#settings-#{unquote(id)}[data-override='false']")
        default = Arbiter.Agents.CredentialWatchdog.default_interval_ms(unquote(default))
        assert has_element?(view, "#settings-#{unquote(id)}-effective", to_string(default))
      end

      test "saving a positive integer persists it", %{conn: conn} do
        view = live_settings(conn)

        submit(view, "#settings-#{unquote(id)}-form", %{"value" => "1234"})

        assert apply(Settings, unquote(getter), []) == 1234
        assert has_element?(view, "#settings-#{unquote(id)}[data-override='true']")
        assert has_element?(view, "#settings-#{unquote(id)}-effective", "1234")
      end

      test "blank clears the override", %{conn: conn} do
        {:ok, 1234} = apply(Settings, unquote(setter), [1234])
        view = live_settings(conn)

        submit(view, "#settings-#{unquote(id)}-form", %{"value" => ""})

        assert apply(Settings, unquote(getter), []) == nil
        assert has_element?(view, "#settings-#{unquote(id)}[data-override='false']")
      end

      test "invalid input is refused inline and changes nothing", %{conn: conn} do
        {:ok, 1234} = apply(Settings, unquote(setter), [1234])
        view = live_settings(conn)

        for bad <- ["0", "-1", "soon", "2.5"] do
          submit(view, "#settings-#{unquote(id)}-form", %{"value" => bad})

          assert has_element?(
                   view,
                   "#settings-#{unquote(id)}-field[data-invalid='true']",
                   "positive whole number"
                 )

          assert apply(Settings, unquote(getter), []) == 1234
        end
      end
    end
  end

  describe "appearance" do
    test "has a theme switcher wired to the phx:set-theme event", %{conn: conn} do
      view = live_settings(conn)

      assert has_element?(view, "#settings-theme-toggle")
      assert has_element?(view, "#settings-theme-toggle [data-phx-theme='dark']")
      assert has_element?(view, "#settings-theme-toggle [data-phx-theme='light']")
      assert has_element?(view, "#settings-theme-toggle [data-phx-theme='system']")
    end
  end

  describe "about" do
    test "shows the cached version, the paths and the bind address", %{conn: conn} do
      view = live_settings(conn)

      version = ArbiterWeb.VersionHelper.get_version()
      assert has_element?(view, "#about-version", version.version)
      assert has_element?(view, "#about-version", version.sha)

      assert has_element?(view, "#about-path-worktree_root", Arbiter.Config.Paths.worktree_root())

      assert has_element?(
               view,
               "#about-path-output_log_root",
               Arbiter.Config.Paths.output_log_root()
             )

      assert has_element?(view, "#about-path-sessions_root", Arbiter.Config.Paths.sessions_root())
      assert has_element?(view, "#about-bind-address")
    end

    test "links to Providers rather than duplicating them", %{conn: conn} do
      view = live_settings(conn)
      assert has_element?(view, ~s(#settings-providers-link[href="/providers"]))
    end

    test "carries no secret fields", %{conn: conn} do
      view = live_settings(conn)
      refute has_element?(view, ~s(input[type="password"]))
    end
  end
end
