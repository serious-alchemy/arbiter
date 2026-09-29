defmodule ArbiterWeb.AuditLogLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}

  # The audit query arrives via `start_async/3` after the connected mount
  # (bd-7or1v7); everything but the async-path tests themselves wants the
  # page once it has landed.
  @async_timeout 5_000

  defp live_audit(conn, path \\ "/audit") do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "audit-#{System.unique_integer([:positive])}", prefix: "au"})

    {:ok, ws: ws}
  end

  describe "mount" do
    test "renders the header, filter tabs, and search input when there are no events", %{
      conn: conn,
      ws: _ws
    } do
      {:ok, _view, html} = live_audit(conn)

      assert html =~ "Audit log"
      assert html =~ "All"
      assert html =~ "Human"
      assert html =~ "Machine"
      assert html =~ "subject:"
    end

    test "lists a create event for the subject/action columns", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "audit me", workspace_id: ws.id})

      {:ok, _view, html} = live_audit(conn)

      assert html =~ task.id
      assert html =~ "create"
    end
  end

  describe "async load" do
    setup do
      :meck.new(ArbiterWeb.AuditLogLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.AuditLogLive) end)
      :ok
    end

    test "the dead render shows the loading state and reads nothing", %{conn: conn} do
      test = self()

      :meck.expect(ArbiterWeb.AuditLogLive, :read_events, fn sql_clauses ->
        send(test, :events_read)
        :meck.passthrough([sql_clauses])
      end)

      doc = conn |> get(~p"/audit") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#audit-loading") |> Enum.count() == 1
      assert doc |> LazyHTML.query("#audit-table") |> Enum.count() == 0
      refute_received :events_read
    end

    test "renders a loading skeleton before the async load lands, then the data", %{
      conn: conn,
      ws: ws
    } do
      {:ok, task} = Ash.create(Issue, %{title: "loading-task", workspace_id: ws.id})

      test = self()

      :meck.expect(ArbiterWeb.AuditLogLive, :read_events, fn sql_clauses ->
        result = :meck.passthrough([sql_clauses])
        send(test, {:loading, self()})

        receive do
          :continue -> result
        end
      end)

      {:ok, view, _html} = live(conn, "/audit")

      assert_receive {:loading, loader}
      assert has_element?(view, "#audit-loading")
      refute has_element?(view, "#audit-table")

      send(loader, :continue)
      html = render_async(view, @async_timeout)

      assert html =~ task.id
      refute has_element?(view, "#audit-loading")
    end

    test "a failed load renders an inline error, and Retry recovers", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "behind-the-error", workspace_id: ws.id})

      :meck.expect(ArbiterWeb.AuditLogLive, :read_events, fn _sql_clauses ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, "/audit")
      render_async(view, @async_timeout)

      assert has_element?(view, "#audit-error")
      assert has_element?(view, "#audit-error", "database is locked")
      refute has_element?(view, "#audit-loading")
      refute has_element?(view, "#audit-table")

      :meck.expect(ArbiterWeb.AuditLogLive, :read_events, fn sql_clauses ->
        :meck.passthrough([sql_clauses])
      end)

      html = render_click(view, "retry", %{})
      html = if html =~ "audit-loading", do: render_async(view, @async_timeout), else: html

      refute html =~ "audit-error"
      assert html =~ task.id
    end

    test "a search that changes the pushed-down filter shows a loading state, not stale rows", %{
      conn: conn,
      ws: ws
    } do
      {:ok, b1} = Ash.create(Issue, %{title: "first", workspace_id: ws.id})
      {:ok, b2} = Ash.create(Issue, %{title: "second", workspace_id: ws.id})

      {:ok, view, html} = live_audit(conn)
      assert html =~ b1.id
      assert html =~ b2.id

      test = self()

      :meck.expect(ArbiterWeb.AuditLogLive, :read_events, fn sql_clauses ->
        send(test, {:loading, self()})

        receive do
          :continue -> :meck.passthrough([sql_clauses])
        end
      end)

      render_change(view, "search", %{"q" => "subject:#{b1.id}"})

      assert_receive {:loading, loader}
      assert has_element?(view, "#audit-loading")
      refute has_element?(view, "#audit-table")

      send(loader, :continue)
      html = render_async(view, @async_timeout)

      assert html =~ b1.id
      refute html =~ b2.id
      refute has_element?(view, "#audit-loading")
    end
  end

  describe "state transitions" do
    test "renders the literal old → new state, never prettified", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "transition me", workspace_id: ws.id})

      {:ok, _task} =
        Ash.update(task, %{acceptance_waived: "test"}, action: :promote_to_ready)

      {:ok, _view, html} = live_audit(conn)

      assert html =~ "backlog → queued"
    end
  end

  describe "actor filter tabs" do
    test "Machine tab narrows to worker-attributed events", %{conn: conn, ws: ws} do
      {:ok, human_task} = Ash.create(Issue, %{title: "human edit", workspace_id: ws.id})
      {:ok, machine_task} = Ash.create(Issue, %{title: "machine edit", workspace_id: ws.id})

      {:ok, _} =
        Ash.update(human_task, %{title: "edited", change_origin: "cli"}, action: :update)

      {:ok, _} =
        Ash.update(machine_task, %{title: "edited", change_origin: "worker:au-1"},
          action: :update
        )

      {:ok, view, _html} = live_audit(conn)

      html = render_click(view, "filter-tab", %{"tab" => "machine"})

      assert html =~ "worker:au-1"
      refute html =~ ~r/>\s*cli\s*</
    end

    test "Human tab narrows to non-worker-attributed events", %{conn: conn, ws: ws} do
      {:ok, human_task} = Ash.create(Issue, %{title: "human edit", workspace_id: ws.id})
      {:ok, machine_task} = Ash.create(Issue, %{title: "machine edit", workspace_id: ws.id})

      {:ok, _} =
        Ash.update(human_task, %{title: "edited", change_origin: "cli"}, action: :update)

      {:ok, _} =
        Ash.update(machine_task, %{title: "edited", change_origin: "worker:au-1"},
          action: :update
        )

      {:ok, view, _html} = live_audit(conn)

      html = render_click(view, "filter-tab", %{"tab" => "human"})

      assert html =~ ~r/>\s*cli\s*</
      refute html =~ "worker:au-1"
    end
  end

  describe "query search" do
    test "subject: narrows to the matching task id", %{conn: conn, ws: ws} do
      {:ok, b1} = Ash.create(Issue, %{title: "first", workspace_id: ws.id})
      {:ok, b2} = Ash.create(Issue, %{title: "second", workspace_id: ws.id})

      {:ok, view, _html} = live_audit(conn)

      render_change(view, "search", %{"q" => "subject:#{b1.id}"})
      html = render_async(view, @async_timeout)

      assert html =~ b1.id
      refute html =~ b2.id
    end
  end

  describe "deep link from the task detail screen" do
    test "?entity_id= seeds the subject filter", %{conn: conn, ws: ws} do
      {:ok, b1} = Ash.create(Issue, %{title: "linked", workspace_id: ws.id})
      {:ok, b2} = Ash.create(Issue, %{title: "other", workspace_id: ws.id})

      {:ok, _view, html} = live_audit(conn, "/audit?entity_id=#{b1.id}")

      assert html =~ "value=\"subject:#{b1.id}\""
      assert html =~ b1.id
      refute html =~ b2.id
    end

    test "the subject filter survives a truncated 500-row read window", %{conn: conn, ws: ws} do
      {:ok, target} = Ash.create(Issue, %{title: "old history", workspace_id: ws.id})

      for n <- 1..500 do
        {:ok, filler} = Ash.create(Issue, %{title: "filler #{n}", workspace_id: ws.id})

        {:ok, _} =
          Ash.update(filler, %{title: "edited", change_origin: "cli"}, action: :update)
      end

      {:ok, _view, html} = live_audit(conn, "/audit?entity_id=#{target.id}")

      assert html =~ target.id
    end
  end

  describe "mobile usability" do
    test "search input has responsive min-width for mobile viewports", %{conn: conn, ws: _ws} do
      {:ok, _view, html} = live_audit(conn)

      # Should have min-w-0 for mobile and sm:min-w-[240px] for larger screens
      # instead of fixed min-w-[240px] that pushes tabs to wrap on narrow viewports
      assert html =~ ~r/class="[^"]*min-w-0[^"]*sm:min-w-\[240px\][^"]*"/
    end

    test "subject column has defined width to prevent compression", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "width test", workspace_id: ws.id})

      {:ok, _view, html} = live_audit(conn)

      # Subject column should have a width attribute to maintain legibility
      assert html =~ "width="
      assert html =~ task.id
    end
  end
end
