defmodule ArbiterWeb.BoardCapacityPopupLiveTest do
  @moduledoc """
  bd-5fl9sx: the board explains its slot cap and its capacity holds in plain
  language, in popups that open on hover, keyboard focus and tap. The old
  scheduler-cap form is gone from the toolbar (capacity is set per node and per
  account; the popup says which command changes each limit).
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @async_timeout 5_000

  alias Arbiter.Board.Autopilot
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Autopilot.resume(Autopilot)

    {:ok, _} = Settings.set_conductor_system_max_concurrent(nil)

    # No settings cleanup: the write lives in the test's sandbox transaction,
    # which rolls back. (A write from on_exit runs after the owner is gone.)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cap-#{System.unique_integer([:positive])}",
        prefix: "cp#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp workspace_cap!(ws, n) do
    {:ok, ws} =
      Ash.update(ws, %{config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => n})})

    ws
  end

  defp ready_ticket(ws, title) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, acceptance: "- fixture"})

    {:ok, issue} = Ash.update(issue, %{}, action: :promote_to_ready)
    issue
  end

  # In progress with no agent behind it: it holds its slot, parked.
  defp parked_ticket(ws, title) do
    {:ok, issue} = Issue.start_work(ready_ticket(ws, title))
    issue
  end

  defp mount_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    view
  end

  describe "the scheduler-cap form is gone" do
    test "the toolbar has no cap form or input", %{conn: conn} do
      view = mount_board(conn)

      refute has_element?(view, "#board-concurrency-form")
      refute has_element?(view, "#board-concurrency-input")
      refute has_element?(view, "#board-concurrency-save")
      refute has_element?(view, "#board-concurrency-limited")
    end

    test "the figure is still the effective cap", %{conn: conn, ws: ws} do
      workspace_cap!(ws, 2)
      view = mount_board(conn)

      assert view |> element("#board-slot-cap-figure") |> render() =~ "2"
    end

    test "a cap saved on /settings shows on the board without a refresh", %{conn: conn} do
      board = mount_board(conn)
      {:ok, settings, _html} = live(conn, "/settings")

      settings
      |> form("#settings-concurrency-form", %{"value" => "3"})
      |> render_submit()

      render_async(board, @async_timeout)

      assert board |> element("#board-slot-cap-figure") |> render() =~ "3"
      assert has_element?(board, "#board-slot-cap-limits [data-limit='ceiling']")
    end
  end

  describe "the cap popup" do
    test "opens on tap and focus as well as hover: a real button wired to the panel", %{
      conn: conn
    } do
      view = mount_board(conn)

      assert has_element?(
               view,
               "#board-slot-cap-trigger[type='button'][aria-expanded='false'][aria-controls='board-slot-cap-panel']"
             )

      # The tap toggles aria-expanded client-side; hover and keyboard focus are
      # CSS on the wrapper.
      trigger = view |> element("#board-slot-cap-trigger") |> render()
      assert trigger =~ "phx-click"

      panel = view |> element("#board-slot-cap-panel") |> render()
      assert panel =~ "group-hover/pop:block"
      assert panel =~ "group-has-[:focus-visible]/pop:block"
      assert panel =~ "group-has-[[aria-expanded=true]]/pop:block"
    end

    test "marks the workspace setting as the binding input", %{conn: conn, ws: ws} do
      workspace_cap!(ws, 2)
      view = mount_board(conn)

      assert has_element?(view, "#board-slot-cap-headline", "Limited to 2 by the workspace setting.")
      assert has_element?(view, "#board-slot-cap-limits [data-limit='workspace'][data-binding='true']")
      assert has_element?(view, "#board-slot-cap-limits [data-limit='nodes'][data-binding='false']")
    end

    test "lists every input in plain language and where each is changed", %{conn: conn, ws: ws} do
      workspace_cap!(ws, 2)
      view = mount_board(conn)
      panel = view |> element("#board-slot-cap-panel") |> render()

      assert panel =~ "Capacity "
      assert panel =~ "this machine ("
      assert panel =~ "arb node set local --max-workers N"
      assert panel =~ "arb config set conductor.max_concurrent N"
      refute panel =~ "max_concurrent /"
    end

    test "says which tickets use the slots, parked ones included", %{conn: conn, ws: ws} do
      workspace_cap!(ws, 3)
      parked = parked_ticket(ws, "waiting between rounds")
      view = mount_board(conn)

      assert has_element?(
               view,
               "#board-slot-cap-users [data-slot-user='#{parked.id}'][data-state='parked']"
             )

      assert has_element?(view, "#board-slot-cap-parked", "no agent running")
      assert view |> element("#board-slot-cap-users") |> render() =~ "still holds a slot"
    end

    test "with nothing running, it says so", %{conn: conn} do
      view = mount_board(conn)
      assert has_element?(view, "#board-slot-cap-users", "Nothing holds a slot")
    end
  end

  describe "held cards" do
    setup %{ws: ws} do
      workspace_cap!(ws, 1)
      parked = parked_ticket(ws, "holds the only slot")
      waiting = ready_ticket(ws, "waits for the slot")
      %{parked: parked, waiting: waiting}
    end

    test "wear one short badge instead of the long warning", %{conn: conn, waiting: waiting} do
      view = mount_board(conn)

      assert has_element?(view, "#card-#{waiting.id} [data-hold-badge='capacity']", "Waiting for capacity")

      card = view |> element("#card-#{waiting.id}") |> render()
      # The visible card text is the badge; the long phrase lives only in the popup's details.
      refute card =~ "blocked — no free worker slot"
    end

    test "explain themselves in the popup, in words", %{
      conn: conn,
      waiting: waiting,
      parked: parked
    } do
      view = mount_board(conn)

      assert has_element?(
               view,
               "#hold-#{waiting.id}-trigger[aria-expanded='false'][aria-controls='hold-#{waiting.id}-panel']"
             )

      summary = view |> element("#hold-#{waiting.id}-panel [data-hold-summary]") |> render()
      assert summary =~ "Waiting for a free worker slot"
      assert summary =~ "The workspace allows 1 at once"
      assert summary =~ parked.id
      assert summary =~ "starts when one finishes"
      refute summary =~ "no_slot"
      refute summary =~ "max_concurrent"
    end

    test "keep the raw reason as a details line", %{conn: conn, waiting: waiting} do
      view = mount_board(conn)

      assert has_element?(
               view,
               "#hold-#{waiting.id}-panel [data-hold-details]",
               "no free worker slot"
             )
    end

    test "a card behind the head is just queued, with no badge", %{conn: conn, ws: ws} do
      _second = ready_ticket(ws, "second in line")
      view = mount_board(conn)

      assert view |> render() |> String.split("data-hold-badge=\"capacity\"") |> length() == 2
    end
  end

  describe "a paused scheduler" do
    test "keeps its own short badge", %{conn: conn, ws: ws} do
      waiting = ready_ticket(ws, "ready while paused")
      Autopilot.pause(Autopilot)
      view = mount_board(conn)

      assert has_element?(
               view,
               "#card-#{waiting.id} [data-hold-badge='scheduler_paused']",
               "Scheduler paused"
             )
    end
  end
end
