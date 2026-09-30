defmodule ArbiterWeb.RunIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Workers.Run

  # The result page arrives by `start_async/3` after the connected mount
  # (bd-1gshps); everything but the async tests themselves wants the page
  # once it has landed.
  @async_timeout 5_000

  defp live_runs(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  defp run(attrs) do
    {:ok, r} =
      Ash.create(
        Run,
        Map.merge(
          %{
            repo: "arbiter",
            workspace_id: "ws-1",
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            completed_at: DateTime.utc_now()
          },
          attrs
        )
      )

    r
  end

  test "lists completed and failed runs with the new component structure", %{conn: conn} do
    completed =
      run(%{
        task_id: "bd-ok",
        task_title: "the-good-run",
        state: :finished,
        outcome: :succeeded,
        kind: :implement,
        role: "base"
      })

    _failed =
      run(%{
        task_id: "bd-bad",
        task_title: "the-bad-run",
        state: :finished,
        outcome: :failed,
        kind: :review,
        role: "review"
      })

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history")

    # Check for new component structure
    assert html =~ ~s(id="runs-history")
    assert html =~ "the-good-run"
    assert html =~ "the-bad-run"
    assert html =~ ~s(href="/workers/history/#{completed.id}")
  end

  test "the failed filter excludes completed runs", %{conn: conn} do
    _completed =
      run(%{
        task_id: "bd-ok2",
        task_title: "completed-only",
        state: :finished,
        outcome: :succeeded
      })

    _failed =
      run(%{task_id: "bd-bad2", task_title: "failed-only", state: :finished, outcome: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :failed}}")

    assert html =~ "failed-only"
    refute html =~ "completed-only"
  end

  test "the succeeded filter excludes failed runs", %{conn: conn} do
    _ok = run(%{task_id: "bd-ok4", task_title: "ok-only", state: :finished, outcome: :succeeded})
    _bad = run(%{task_id: "bd-bad4", task_title: "bad-only", state: :finished, outcome: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :succeeded}}")

    assert html =~ "ok-only"
    refute html =~ "bad-only"
  end

  test "the live filter shows every run that has not finished", %{conn: conn} do
    _starting = run(%{task_id: "bd-st", task_title: "starting-run", state: :starting})
    _working = run(%{task_id: "bd-wk", task_title: "working-run", state: :working})
    _waiting = run(%{task_id: "bd-wt", task_title: "waiting-run", state: :waiting})

    _done =
      run(%{task_id: "bd-dn", task_title: "finished-run", state: :finished, outcome: :succeeded})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :live}}")

    assert html =~ "starting-run"
    assert html =~ "working-run"
    assert html =~ "waiting-run"
    refute html =~ "finished-run"
  end

  test "the handed_off filter shows runs a resume took over", %{conn: conn} do
    _handed =
      run(%{task_id: "bd-ho", task_title: "handed-run", state: :finished, outcome: :handed_off})

    _bad = run(%{task_id: "bd-bad5", task_title: "bad-run", state: :finished, outcome: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :handed_off}}")

    assert html =~ "handed-run"
    refute html =~ "bad-run"
  end

  test "pre-5/13 status links land on their new tab", %{conn: conn} do
    _working = run(%{task_id: "bd-lg1", task_title: "legacy-working", state: :working})

    _ok =
      run(%{task_id: "bd-lg2", task_title: "legacy-ok", state: :finished, outcome: :succeeded})

    _bad =
      run(%{task_id: "bd-lg3", task_title: "legacy-bad", state: :finished, outcome: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :running}}")
    assert html =~ "legacy-working"
    refute html =~ "legacy-ok"
    refute html =~ "legacy-bad"

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :completed}}")
    assert html =~ "legacy-ok"
    refute html =~ "legacy-working"
    refute html =~ "legacy-bad"

    for legacy <- [:review_parked, :review_not_started] do
      {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: legacy}}")
      assert html =~ "legacy-bad"
      refute html =~ "legacy-ok"
      refute html =~ "legacy-working"
    end
  end

  test "the interrupted filter shows runs shut down with the server, not failures (bd-aje6fj)",
       %{conn: conn} do
    _interrupted =
      run(%{
        task_id: "bd-int",
        task_title: "interrupted-only",
        state: :finished,
        outcome: :interrupted,
        failure_reason: "server shutdown"
      })

    _failed =
      run(%{task_id: "bd-bad3", task_title: "crashed-only", state: :finished, outcome: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :interrupted}}")

    assert html =~ "interrupted-only"
    refute html =~ "crashed-only"
  end

  test "empty state uses the moon icon when no runs match", %{conn: conn} do
    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :live}}")

    # Moon icon should be present in empty state
    assert html =~ "runs-empty"
    assert html =~ "hero-moon"
  end

  # bd-1gshps: the result page used to run synchronously in mount/
  # handle_params. It now arrives by `start_async/3` on the connected mount
  # only.
  describe "the async load" do
    setup do
      :meck.new(ArbiterWeb.RunIndexLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.RunIndexLive) end)
      :ok
    end

    test "the dead render shows the loading state and reads nothing", %{conn: conn} do
      test = self()

      :meck.expect(ArbiterWeb.RunIndexLive, :load_runs, fn status, page ->
        send(test, :runs_read)
        :meck.passthrough([status, page])
      end)

      doc = conn |> get(~p"/workers/history") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query(~s(#runs-panel[data-state="loading"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("#runs-loading") |> Enum.count() == 1
      refute_received :runs_read
    end

    test "renders a loading skeleton before the async load lands, then the data",
         %{conn: conn} do
      run(%{task_id: "bd-load", task_title: "loading-run", state: :finished, outcome: :succeeded})

      test = self()

      :meck.expect(ArbiterWeb.RunIndexLive, :load_runs, fn status, page ->
        result = :meck.passthrough([status, page])
        send(test, {:loading_runs, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_runs_load, self()})
        end

        result
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/history")
      assert_receive {:loading_runs, loader}

      assert has_element?(view, ~s(#runs-panel[data-state="loading"]))
      assert has_element?(view, "#runs-loading")
      refute has_element?(view, "#runs-empty")

      send(loader, :release)
      html = render_async(view, @async_timeout)

      assert has_element?(view, ~s(#runs-panel[data-state="loaded"]))
      refute has_element?(view, "#runs-loading")
      assert html =~ "loading-run"
      refute_received {:unreleased_runs_load, _}
    end

    @tag :capture_log
    test "a failed run-page load renders an inline error, and Retry recovers",
         %{conn: conn} do
      run(%{
        task_id: "bd-err",
        task_title: "behind-the-error",
        state: :finished,
        outcome: :succeeded
      })

      :meck.expect(ArbiterWeb.RunIndexLive, :load_runs, fn _status, _page ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/history")
      render_async(view, @async_timeout)

      assert has_element?(view, ~s(#runs-panel[data-state="error"]))
      assert has_element?(view, "#runs-error", "database is locked")
      assert has_element?(view, "#runs-retry")
      refute has_element?(view, "#runs-loading")

      :meck.expect(ArbiterWeb.RunIndexLive, :load_runs, fn status, page ->
        :meck.passthrough([status, page])
      end)

      view |> element("#runs-retry") |> render_click()
      html = render_async(view, @async_timeout)

      refute has_element?(view, "#runs-error")
      assert has_element?(view, ~s(#runs-panel[data-state="loaded"]))
      assert html =~ "behind-the-error"
    end

    @tag :capture_log
    test "a lifecycle refresh that fails keeps the last page on screen and says so", %{
      conn: conn
    } do
      run(%{
        task_id: "bd-stay",
        task_title: "was-on-the-page",
        state: :finished,
        outcome: :succeeded
      })

      {:ok, view, _html} = live(conn, ~p"/workers/history")
      render_async(view, @async_timeout)
      assert has_element?(view, "#runs-history", "was-on-the-page")

      :meck.expect(ArbiterWeb.RunIndexLive, :load_runs, fn _status, _page ->
        raise "database is locked"
      end)

      Phoenix.PubSub.broadcast(Arbiter.PubSub, "workers", {:worker_lifecycle, :updated, %{}})
      :sys.get_state(view.pid)
      render_async(view, @async_timeout)

      assert has_element?(view, "#runs-error", "database is locked")
      assert has_element?(view, "#runs-history", "was-on-the-page")
    end
  end

  test "live: a worker_lifecycle broadcast refreshes the page", %{conn: conn} do
    {:ok, view, html} = live_runs(conn, ~p"/workers/history")
    refute html =~ "freshly-finished"

    run(%{
      task_id: "bd-new",
      task_title: "freshly-finished",
      state: :finished,
      outcome: :succeeded
    })

    Phoenix.PubSub.broadcast(Arbiter.PubSub, "workers", {:worker_lifecycle, :updated, %{}})
    :sys.get_state(view.pid)

    assert render_async(view, @async_timeout) =~ "freshly-finished"
  end

  test "renders the provider icon next to runs with a provider", %{conn: conn} do
    run(%{
      task_id: "bd-claude-run",
      task_title: "claude-run",
      state: :finished,
      outcome: :succeeded,
      provider: "claude"
    })

    run(%{
      task_id: "bd-codex-run",
      task_title: "codex-run",
      state: :finished,
      outcome: :succeeded,
      provider: "codex"
    })

    run(%{
      task_id: "bd-no-provider",
      task_title: "no-provider",
      state: :finished,
      outcome: :succeeded,
      provider: nil
    })

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history")

    doc = LazyHTML.from_fragment(html)
    # Claude run should show the claude provider icon
    claude_icons = LazyHTML.query(doc, "svg[aria-label=\"Claude\"]")
    assert Enum.count(claude_icons) > 0

    # Codex run should show the codex provider icon
    codex_icons = LazyHTML.query(doc, "svg[aria-label=\"Codex\"]")
    assert Enum.count(codex_icons) > 0

    # Verify the icons are within the runs-history container
    assert html =~ "claude-run"
    assert html =~ "codex-run"
    assert html =~ "no-provider"
  end
end
