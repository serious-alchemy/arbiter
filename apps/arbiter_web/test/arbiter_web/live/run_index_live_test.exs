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
        status: :completed,
        worker_type: "main"
      })

    _failed =
      run(%{task_id: "bd-bad", task_title: "the-bad-run", status: :failed, worker_type: "review"})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history")

    # Check for new component structure
    assert html =~ ~s(id="runs-history")
    assert html =~ "the-good-run"
    assert html =~ "the-bad-run"
    assert html =~ ~s(href="/workers/history/#{completed.id}")
  end

  test "the failed filter excludes completed runs", %{conn: conn} do
    _completed = run(%{task_id: "bd-ok2", task_title: "completed-only", status: :completed})
    _failed = run(%{task_id: "bd-bad2", task_title: "failed-only", status: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :failed}}")

    assert html =~ "failed-only"
    refute html =~ "completed-only"
  end

  test "the interrupted filter shows runs shut down with the server, not failures (bd-aje6fj)",
       %{conn: conn} do
    _interrupted =
      run(%{
        task_id: "bd-int",
        task_title: "interrupted-only",
        status: :interrupted,
        failure_reason: "server shutdown"
      })

    _failed = run(%{task_id: "bd-bad3", task_title: "crashed-only", status: :failed})

    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :interrupted}}")

    assert html =~ "interrupted-only"
    refute html =~ "crashed-only"
  end

  test "empty state uses the moon icon when no runs match", %{conn: conn} do
    {:ok, _view, html} = live_runs(conn, ~p"/workers/history?#{%{status: :running}}")

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
      run(%{task_id: "bd-load", task_title: "loading-run", status: :completed})

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
      run(%{task_id: "bd-err", task_title: "behind-the-error", status: :completed})

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
      run(%{task_id: "bd-stay", task_title: "was-on-the-page", status: :completed})

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

    run(%{task_id: "bd-new", task_title: "freshly-finished", status: :completed})
    Phoenix.PubSub.broadcast(Arbiter.PubSub, "workers", {:worker_lifecycle, :updated, %{}})
    :sys.get_state(view.pid)

    assert render_async(view, @async_timeout) =~ "freshly-finished"
  end
end
