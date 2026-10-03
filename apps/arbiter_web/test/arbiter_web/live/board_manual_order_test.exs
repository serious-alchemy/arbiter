defmodule ArbiterWeb.BoardManualOrderTest do
  @moduledoc """
  ES6 (`docs/design/epic-aware-scheduling.md` §6.3): a board drag inside a band
  pins the card (`rank_pinned`) and the cards above it, a drop into a band worse
  than the card's epic floor is refused with a flash, and a board with no
  floors drags exactly as it always did.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Dependencies, Issue, Workspace}

  @async_timeout 5_000

  setup do
    on_exit(fn -> Arbiter.Settings.set_scheduling_max_lifted_in_flight(nil) end)
    {:ok, 5} = Arbiter.Settings.set_scheduling_max_lifted_in_flight(5)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "es6-#{System.unique_integer([:positive])}", prefix: "es6"})

    {:ok, epic} =
      Ash.create(Issue, %{title: "Add reports", workspace_id: ws.id, issue_type: :epic})

    {:ok, ws: ws, epic: epic}
  end

  defp floor!(epic, floor) do
    {:ok, epic} = Ash.update(epic, %{floor_priority: floor}, action: :set_floor)
    epic
  end

  defp backlog(ws, priority, parent \\ nil) do
    {:ok, issue} =
      Ash.create(Issue, %{
        title: "card-#{System.unique_integer([:positive])}",
        workspace_id: ws.id,
        priority: priority,
        acceptance: "- ok"
      })

    if parent, do: {:ok, _} = Dependencies.add(parent.id, issue.id, :parent_of)
    issue
  end

  defp ready(ws, priority, parent \\ nil) do
    {:ok, issue} = Ash.update(backlog(ws, priority, parent), %{}, action: :promote)
    issue
  end

  defp live_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    render_async(view, @async_timeout)
    view
  end

  defp drag(view, id, column, key, target_id) do
    render_hook(view, "reorder", %{"id" => id, "column" => column, key => target_id})
    render_async(view, @async_timeout)
  end

  defp card_order(view, column) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#board-column-#{column} [data-card]")
    |> LazyHTML.attribute("data-card")
  end

  defp reload(issue), do: Ash.get!(Issue, issue.id)

  describe "a drag inside a band" do
    test "pins the dragged card and the cards above the drop", %{conn: conn, ws: ws} do
      a = ready(ws, 2)
      b = ready(ws, 2)
      c = ready(ws, 2)
      d = ready(ws, 2)

      view = live_board(conn)
      drag(view, d.id, "ready", "after_id", b.id)

      assert card_order(view, "ready") == [a.id, b.id, d.id, c.id]
      assert reload(d).rank_pinned
      assert reload(a).rank_pinned
      assert reload(b).rank_pinned
      refute reload(c).rank_pinned
    end

    test "dropping at the bottom keeps the card at the bottom, not the top", %{
      conn: conn,
      ws: ws
    } do
      a = ready(ws, 2)
      b = ready(ws, 2)
      c = ready(ws, 2)

      view = live_board(conn)
      drag(view, a.id, "ready", "after_id", c.id)

      assert card_order(view, "ready") == [b.id, c.id, a.id]
      assert card_order(live_board(conn), "ready") == [b.id, c.id, a.id]
    end

    test "a drag within Backlog pins too", %{conn: conn, ws: ws} do
      a = backlog(ws, 2)
      b = backlog(ws, 2)

      view = live_board(conn)
      drag(view, a.id, "backlog", "after_id", b.id)

      assert card_order(view, "backlog") == [b.id, a.id]
      assert reload(a).rank_pinned
    end

    test "a pinned card whose rank is stale after a priority edit keeps its place", %{
      conn: conn,
      ws: ws
    } do
      a = ready(ws, 2)
      b = ready(ws, 2)
      x = ready(ws, 3)
      y = ready(ws, 3)

      # X is pinned by a drag in the P3 band, so its rank sits past B's.
      view = live_board(conn)
      drag(view, x.id, "ready", "after_id", y.id)
      assert reload(x).rank_pinned

      # Editing X to P2 moves it first in the P2 band with its old rank.
      {:ok, _} = Ash.update(reload(x), %{priority: 2})
      assert card_order(live_board(conn), "ready") == [x.id, a.id, b.id, y.id]

      view = live_board(conn)
      drag(view, a.id, "ready", "after_id", b.id)

      assert card_order(view, "ready") == [x.id, b.id, a.id, y.id]
      assert card_order(live_board(conn), "ready") == [x.id, b.id, a.id, y.id]
    end

    test "a move that fails part-way leaves the cards above the drop unpinned", %{
      conn: conn,
      ws: ws
    } do
      a = ready(ws, 2)
      b = ready(ws, 2)
      c = ready(ws, 2)

      view = live_board(conn)

      # B vanishes after the board loaded: A is pinned first, then B's turn fails.
      Arbiter.Repo.query!("PRAGMA defer_foreign_keys = ON")
      Arbiter.Repo.query!("DELETE FROM issues WHERE id = ?1", [b.id])

      drag(view, c.id, "ready", "after_id", b.id)

      refute reload(a).rank_pinned
      refute reload(c).rank_pinned
    end

    test "a pinned card goes ahead of the finish-first tiebreak in its band", %{
      conn: conn,
      ws: ws,
      epic: epic
    } do
      {:ok, true} = Arbiter.Settings.set_scheduling_finish_first(true)
      on_exit(fn -> Arbiter.Settings.set_scheduling_finish_first(false) end)

      {:ok, done} = Ash.create(Issue, %{title: "done leaf", workspace_id: ws.id})
      {:ok, _} = Dependencies.add(epic.id, done.id, :parent_of)
      {:ok, _} = Ash.update(done, %{close_upstream: false}, action: :close)

      child = ready(ws, 2, epic)
      other = ready(ws, 2)

      view = live_board(conn)
      assert card_order(view, "ready") == [child.id, other.id]

      drag(view, other.id, "ready", "before_id", child.id)

      assert card_order(view, "ready") == [other.id, child.id]
      assert card_order(live_board(conn), "ready") == [other.id, child.id]
    end
  end

  describe "a floored epic" do
    setup %{epic: epic} do
      %{epic: floor!(epic, 1)}
    end

    test "a drop into a band worse than the floor is refused with the flash", %{
      conn: conn,
      ws: ws,
      epic: epic
    } do
      lifted = ready(ws, 3, epic)
      p2 = ready(ws, 2)
      before_rank = reload(lifted).rank

      view = live_board(conn)
      assert card_order(view, "ready") == [lifted.id, p2.id]

      drag(view, lifted.id, "ready", "after_id", p2.id)

      assert render(view) =~
               "#{lifted.id} is lifted to P1 by #{epic.id}&#39;s floor — clear the floor or order it within P1"

      lifted = reload(lifted)
      assert lifted.priority == 3
      assert lifted.rank == before_rank
      refute lifted.rank_pinned
      assert card_order(view, "ready") == [lifted.id, p2.id]
    end

    test "a drop inside the floor's band pins and leaves the own priority alone", %{
      conn: conn,
      ws: ws,
      epic: epic
    } do
      a = ready(ws, 3, epic)
      b = ready(ws, 4, epic)

      view = live_board(conn)
      drag(view, b.id, "ready", "before_id", a.id)

      assert card_order(view, "ready") == [b.id, a.id]
      assert reload(b).priority == 4
      assert reload(b).rank_pinned
      refute render(view) =~ "is lifted to"
    end

    test "a drop into a better band changes the own priority", %{conn: conn, ws: ws, epic: epic} do
      lifted = ready(ws, 3, epic)
      p0 = ready(ws, 0)

      view = live_board(conn)
      drag(view, lifted.id, "ready", "after_id", p0.id)

      assert reload(lifted).priority == 0
      assert card_order(view, "ready") == [p0.id, lifted.id]
    end

    test "an unlifted card dropped into the floor's band takes that band", %{
      conn: conn,
      ws: ws,
      epic: epic
    } do
      lifted = ready(ws, 3, epic)
      plain = ready(ws, 2)

      view = live_board(conn)
      drag(view, plain.id, "ready", "before_id", lifted.id)

      assert reload(plain).priority == 1
      assert card_order(view, "ready") == [plain.id, lifted.id]
    end
  end

  describe "with no floors" do
    test "a drop into another band changes the own priority, as it always did", %{
      conn: conn,
      ws: ws
    } do
      p1 = ready(ws, 1)
      p2 = ready(ws, 2)

      view = live_board(conn)
      drag(view, p2.id, "ready", "after_id", p1.id)

      assert reload(p2).priority == 1
      assert card_order(view, "ready") == [p1.id, p2.id]
      refute render(view) =~ "is lifted to"
    end
  end
end
