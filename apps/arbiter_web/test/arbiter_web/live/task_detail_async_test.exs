defmodule ArbiterWeb.TaskDetailAsyncTest do
  @moduledoc """
  bd-dhghus: `/tasks/:id` no longer runs its dozen loaders in mount. The
  connected mount starts the header load (task, workspace, worker) via
  `start_async/3`; its arrival starts one independent load per secondary
  panel. The dead render reads nothing and draws the loading state; a failed
  load renders inline with a Retry rather than crashing the view.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ArbiterWeb.TaskDetailLiveHelpers

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run
  alias ArbiterWeb.TaskDetailLive

  @async_timeout 5_000

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "ta-#{System.unique_integer([:positive])}", prefix: "tat"})

    {:ok, task} =
      Ash.create(Issue, %{
        title: "async-loaded title",
        description: "the body",
        workspace_id: ws.id
      })

    {:ok, ws: ws, task: task}
  end

  defp release_header_loaders do
    receive do
      {:read_header, loader} ->
        send(loader, :release)
        release_header_loaders()
    after
      200 -> :ok
    end
  end

  defp mock_loaders do
    :meck.new(TaskDetailLive, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(TaskDetailLive) end)
  end

  # Park the named panel's load until the test sends `:release` to the
  # loader process it reports.
  defp block_panel(panel) do
    test_pid = self()

    :meck.expect(TaskDetailLive, :load_panel, fn
      ^panel, ctx ->
        send(test_pid, {:loading_panel, panel, self()})

        receive do
          :release -> :meck.passthrough([panel, ctx])
        end

      other, ctx ->
        :meck.passthrough([other, ctx])
    end)
  end

  defp run(task, marker) do
    {:ok, run} =
      Ash.create(Run, %{
        task_id: task.id,
        repo: "test/repo",
        kind: :implement,
        state: :finished,
        outcome: :succeeded,
        started_at: DateTime.utc_now(),
        mr_ref: marker
      })

    run
  end

  describe "dead render" do
    test "draws the loading state and runs no loader", %{conn: conn, task: task} do
      mock_loaders()

      html = conn |> get(~p"/tasks/#{task.id}") |> html_response(200)

      assert html =~ ~s(id="task-header-loading")
      refute html =~ "async-loaded title"
      refute html =~ "not found"
      assert :meck.num_calls(TaskDetailLive, :load_header, :_) == 0
      assert :meck.num_calls(TaskDetailLive, :load_panel, :_) == 0
    end
  end

  describe "connected mount" do
    test "renders loading, then the header, then each panel", %{conn: conn, task: task} do
      mock_loaders()
      block_panel(:runs)

      {:ok, view, html} = live(conn, ~p"/tasks/#{task.id}")

      # First connected render: nothing has landed yet.
      assert html =~ ~s(id="task-header-loading")
      refute html =~ "async-loaded title"

      # The header has landed (its arrival is what started the panel loads);
      # the runs panel is parked, so it is still drawing its skeleton.
      assert_receive {:loading_panel, :runs, loader}, @async_timeout
      html = render(view)

      assert html =~ "async-loaded title"
      refute has_element?(view, "#task-header-loading")
      refute has_element?(view, "#task-body-loading")
      assert has_element?(view, "#panel-runs #panel-runs-loading")

      send(loader, :release)
      render_async(view, @async_timeout)

      refute has_element?(view, "#panel-runs-loading")
      refute has_element?(view, "#panel-activity-loading")
      refute has_element?(view, "#panel-messages-loading")
      assert has_element?(view, "#panel-runs")
      assert has_element?(view, "#task-activity")
    end

    test "a task that does not exist renders not-found once the header lands", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/tasks/tat-doesnotexist")
      html = render_task(view)

      assert html =~ "not found"
      refute has_element?(view, "#task-header-loading")
    end
  end

  describe "failures" do
    @tag :capture_log
    test "a failed header load renders an inline error, and Retry recovers",
         %{conn: conn, task: task} do
      mock_loaders()

      :meck.expect(TaskDetailLive, :load_header, fn _task_id ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      render_task(view)

      assert has_element?(view, "#task-header-error", "database is locked")
      refute has_element?(view, "#task-header-loading")
      refute render(view) =~ "not found"

      :meck.expect(TaskDetailLive, :load_header, fn task_id ->
        :meck.passthrough([task_id])
      end)

      view |> element("#task-header-retry") |> render_click()
      html = render_task(view)

      assert html =~ "async-loaded title"
      refute has_element?(view, "#task-header-error")
    end

    @tag :capture_log
    test "a failed panel load renders inline in that panel only, and Retry recovers",
         %{conn: conn, task: task} do
      run(task, "!7-async-run")
      mock_loaders()

      :meck.expect(TaskDetailLive, :load_panel, fn
        :runs, _ctx -> raise "database is locked"
        other, ctx -> :meck.passthrough([other, ctx])
      end)

      {:ok, view, html} = live_task(conn, ~p"/tasks/#{task.id}")

      assert html =~ "async-loaded title"
      assert has_element?(view, "#panel-runs #panel-runs-error", "database is locked")
      refute has_element?(view, "#panel-runs-loading")
      refute has_element?(view, "#panel-activity-error")

      :meck.expect(TaskDetailLive, :load_panel, fn panel, ctx ->
        :meck.passthrough([panel, ctx])
      end)

      view |> element("#panel-runs-retry") |> render_click()
      render_async(view, @async_timeout)

      refute has_element?(view, "#panel-runs-error")
      assert render(view) =~ "!7-async-run"
    end
  end

  describe "refreshes" do
    test "a lifecycle event after the load repaints the header", %{conn: conn, task: task} do
      {:ok, view, _html} = live_task(conn, ~p"/tasks/#{task.id}")

      {:ok, _} = Ash.update(task, %{title: "renamed while open"})
      :sys.get_state(view.pid)

      assert render(view) =~ "renamed while open"
    end

    test "a refresh while a panel is still loading settles it with fresh data",
         %{conn: conn, task: task} do
      mock_loaders()
      block_panel(:runs)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert_receive {:loading_panel, :runs, loader}, @async_timeout
      assert has_element?(view, "#panel-runs-loading")

      run(task, "!8-late-run")

      send(
        view.pid,
        {:worker_lifecycle, :started, %{task_id: task.id}}
      )

      html = render(view)
      refute has_element?(view, "#panel-runs-loading")
      assert html =~ "!8-late-run"

      # The superseded load was cancelled: releasing it changes nothing.
      send(loader, :release)
      render_async(view, @async_timeout)
      refute has_element?(view, "#panel-runs-loading")
      assert render(view) =~ "!8-late-run"
    end

    # The result of a load that had already finished — read before the event,
    # queued behind it — must not paint over the refresh the event ran.
    test "a load a refresh superseded never paints over it", %{conn: conn, task: task} do
      mock_loaders()
      test_pid = self()

      :meck.expect(TaskDetailLive, :load_panel, fn
        :runs, ctx ->
          data = :meck.passthrough([:runs, ctx])
          send(test_pid, {:read_panel, :runs, self()})

          receive do
            :release -> data
          end

        other, ctx ->
          :meck.passthrough([other, ctx])
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert_receive {:read_panel, :runs, loader}, @async_timeout

      run(task, "!9-fresh-run")

      # Queue the refresh ahead of the stale result, then let the result in.
      :sys.suspend(view.pid)
      send(view.pid, {:worker_lifecycle, :started, %{task_id: task.id}})
      ref = Process.monitor(loader)
      send(loader, :release)
      assert_receive {:DOWN, ^ref, :process, ^loader, _}, @async_timeout
      :sys.resume(view.pid)

      render_async(view, @async_timeout)
      refute has_element?(view, "#panel-runs-loading")
      assert render(view) =~ "!9-fresh-run"
    end

    test "a lifecycle event while the header is loading restarts it", %{conn: conn, task: task} do
      mock_loaders()
      test_pid = self()

      :meck.expect(TaskDetailLive, :load_header, fn task_id ->
        data = :meck.passthrough([task_id])
        send(test_pid, {:read_header, self()})

        receive do
          :release -> data
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/tasks/#{task.id}")
      assert_receive {:read_header, stale_loader}, @async_timeout

      {:ok, _} = Ash.update(task, %{title: "renamed mid-load"})
      assert_receive {:read_header, fresh_loader}, @async_timeout

      # One `Ash.update` broadcasts more than one `:task_lifecycle`, and each
      # one while the header loads restarts it, cancelling the loader before
      # it. Which of the loaders is still alive depends on how fast the view
      # drains its mailbox, so release every loader that reports instead of
      # naming two of them (bd-cixhhs: a faster chrome mount exposed it).
      send(stale_loader, :release)
      send(fresh_loader, :release)
      release_header_loaders()
      html = render_task(view)

      assert html =~ "renamed mid-load"
    end
  end
end
