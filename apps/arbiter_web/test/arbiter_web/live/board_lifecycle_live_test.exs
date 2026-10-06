defmodule ArbiterWeb.BoardLifecycleLiveTest do
  @moduledoc """
  bd-79w1fs: the seven-column board — one column per lifecycle column, the
  per-column card detail, the attention marker, the Needs-attention swimlane
  (ticket items, system alerts, the per-viewer toggle) and the drags: rank
  within Backlog and Ready, promote / demote across them, and a refusal for
  every other cross-column drag.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @async_timeout 5_000

  alias Arbiter.Alerts
  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.{Dependency, Issue, Workspace}
  alias Arbiter.Worker

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)

    # The autopilot ships paused, which would make every Ready card read
    # "scheduler paused". `interval_ms: :never` in the test env means a resumed
    # autopilot still never dispatches on its own.
    Autopilot.resume(Autopilot)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "lc-#{System.unique_integer([:positive])}", prefix: "bd"})

    {:ok, ws: ws}
  end

  # ---- fixtures ---------------------------------------------------------------

  defp backlog_issue(ws, title, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: title, workspace_id: ws.id, acceptance: "- board fixture"}, attrs)
      )

    issue
  end

  defp ready_issue(ws, title, attrs \\ %{}) do
    {:ok, issue} = Ash.update(backlog_issue(ws, title, attrs), %{}, action: :promote)
    issue
  end

  defp depends_on!(dependent, blocker) do
    {:ok, _} =
      Ash.create(Dependency, %{
        from_issue_id: dependent.id,
        to_issue_id: blocker.id,
        type: :depends_on
      })
  end

  defp active_issue(ws, title) do
    {:ok, issue} = Ash.update(ready_issue(ws, title), %{}, action: :start)
    issue
  end

  defp merging_issue(ws, title) do
    {:ok, issue} = Ash.update(active_issue(ws, title), %{pr_ref: "!9"}, action: :open_pr)
    issue
  end

  defp verifying_issue(ws, title) do
    {:ok, issue} = Ash.update(active_issue(ws, title), %{}, action: :await_verification)
    issue
  end

  defp closed_issue(ws, title, reason) do
    {:ok, issue} = Ash.update(ready_issue(ws, title), %{close_reason: reason}, action: :close)
    issue
  end

  # An operator-owned attention item: approved, auto-merge off, a person merges.
  defp operator_attention!(issue) do
    {:ok, issue} =
      Ash.update(issue, %{cause: :awaiting_manual_merge}, action: :raise_attention)

    issue
  end

  defp live_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    render_async_settled(view, @async_timeout)
    view
  end

  defp column_order(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#board-columns > [data-column]")
    |> LazyHTML.attribute("data-column")
  end

  defp card_order(view, column) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#board-column-#{column} [data-card]")
    |> LazyHTML.attribute("data-card")
  end

  defp in_column?(view, column, id),
    do: has_element?(view, ~s(#board-column-#{column} [id="card-#{id}"]))

  defp reload(issue), do: Ash.get!(Issue, issue.id)

  # ---- 1. the seven columns ---------------------------------------------------

  describe "columns" do
    test "renders exactly the seven lifecycle columns, in order", %{conn: conn} do
      view = live_board(conn)

      assert column_order(view) ==
               ~w(backlog blocked ready in_progress merging verifying closed)

      refute has_element?(view, "#board-column-running")
      refute has_element?(view, "#board-column-waiting")
    end

    test "one ticket per lifecycle column lands in its own column", %{conn: conn, ws: ws} do
      backlog = backlog_issue(ws, "filed")
      blocker = ready_issue(ws, "goes first")
      blocked = ready_issue(ws, "waits")
      depends_on!(blocked, blocker)
      active = active_issue(ws, "working")
      merging = merging_issue(ws, "pr open")
      verifying = verifying_issue(ws, "merged")
      closed = closed_issue(ws, "done", :completed)

      view = live_board(conn)

      placements = [
        {"backlog", backlog},
        {"blocked", blocked},
        {"ready", blocker},
        {"in_progress", active},
        {"merging", merging},
        {"verifying", verifying},
        {"closed", closed}
      ]

      for {column, ticket} <- placements do
        assert in_column?(view, column, ticket.id), "#{ticket.id} should be in #{column}"

        others = for {other, _} <- placements, other != column, do: other
        for other <- others, do: refute(in_column?(view, other, ticket.id))
      end
    end

    test "epics stay off the board", %{conn: conn, ws: ws} do
      epic = ready_issue(ws, "the container", %{issue_type: :epic})

      view = live_board(conn)

      refute has_element?(view, ~s([id="card-#{epic.id}"]))
    end
  end

  # ---- 2. card detail ---------------------------------------------------------

  describe "card detail" do
    test "a Blocked card says what it is waiting on", %{conn: conn, ws: ws} do
      blocker = ready_issue(ws, "goes first")
      blocked = ready_issue(ws, "waits")
      depends_on!(blocked, blocker)

      view = live_board(conn)

      assert has_element?(view, ~s(#card-#{blocked.id}), "waiting on #{blocker.id}")
    end

    test "a Ready card carries the scheduler's reason", %{conn: conn, ws: ws} do
      head = ready_issue(ws, "first", %{priority: 1})
      behind = ready_issue(ws, "second", %{priority: 2})

      view = live_board(conn)

      assert has_element?(view, ~s(#card-#{head.id}), "next up")
      assert has_element?(view, ~s(#card-#{behind.id}), "1 ahead in queue")
    end

    test "a Ready card held by the scheduler says held, not blocked", %{conn: conn, ws: ws} do
      task = ready_issue(ws, "queued")
      Autopilot.pause(Autopilot)

      view = live_board(conn)

      assert has_element?(view, ~s(#card-#{task.id}), "scheduler paused")
    end

    test "In progress and Merging cards show the computed step", %{conn: conn, ws: ws} do
      active = active_issue(ws, "working")
      merging = merging_issue(ws, "pr open")

      view = live_board(conn)

      assert has_element?(view, ~s(#card-#{active.id} [data-step="implementing"]))
      assert has_element?(view, ~s(#card-#{active.id}), "implementing")
      assert has_element?(view, ~s(#card-#{merging.id} [data-step="in_merge_queue"]))
      assert has_element?(view, ~s(#card-#{merging.id}), "in merge queue")
    end

    # bd-dc468g: a ticket whose ReviewGate waits on CI appears in Merging
    # (holding no slot), keeping its "waiting on CI" badge, while In progress
    # contains only slot-holding tickets.
    test "a ticket waiting on CI appears in Merging with waiting on CI badge and In progress holds slot",
         %{conn: conn, ws: ws} do
      waiting = active_issue(ws, "waiting on ci")
      other = active_issue(ws, "working")
      sha = "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0"

      # The author is parked on its review gate with no agent live.
      {:ok, author} = Worker.start(task_id: waiting.id, repo: "r", workspace_id: ws.id)
      on_exit(fn -> if Process.alive?(author), do: Worker.stop(author) end)

      :sys.replace_state(author, fn s ->
        %{s | state: :waiting, waiting_on: :review_gate}
      end)

      :ok =
        Arbiter.Tasks.PullRequest.record_review_gate(waiting.id, %{
          ci_wait: Arbiter.Worker.ReviewCi.marker(sha, 1, %{interval_ms: 60_000, max_polls: 30})
        })

      view = live_board(conn)

      assert in_column?(view, "merging", waiting.id)
      assert has_element?(view, ~s(#card-#{waiting.id} [data-step="awaiting_ci"]))

      assert has_element?(
               view,
               ~s(#card-#{waiting.id}),
               "waiting on CI #{String.slice(sha, 0, 12)}"
             )

      assert in_column?(view, "in_progress", other.id)
      assert has_element?(view, ~s(#card-#{other.id} [data-step="implementing"]))
      refute in_column?(view, "in_progress", waiting.id)
    end

    test "a Closed card shows its close reason", %{conn: conn, ws: ws} do
      done = closed_issue(ws, "done", :completed)
      dropped = closed_issue(ws, "dropped", :wont_do)
      dup = closed_issue(ws, "again", :duplicate)

      view = live_board(conn)

      assert has_element?(view, ~s(#card-#{done.id} [data-close-reason="completed"]), "completed")
      assert has_element?(view, ~s(#card-#{dropped.id} [data-close-reason="wont_do"]), "won't do")
      assert has_element?(view, ~s(#card-#{dup.id} [data-close-reason="duplicate"]), "duplicate")
    end
  end

  # ---- 3. attention: marker and swimlane --------------------------------------

  describe "the attention marker and the Needs-attention swimlane" do
    test "operator-owned attention marks the card in its own column and fills the lane", %{
      conn: conn,
      ws: ws
    } do
      ticket = ws |> merging_issue("needs a person") |> operator_attention!()

      view = live_board(conn)

      assert in_column?(view, "merging", ticket.id)
      assert has_element?(view, ~s(#card-#{ticket.id} [data-attention="operator"]))
      assert has_element?(view, ~s(#card-#{ticket.id} [data-attention]), "a person merges it")
      assert has_element?(view, ~s(#board-attention-lane #lane-ticket-#{ticket.id}))
    end

    test "coordinator-owned attention reaches the lane only with the coordinator chip on", %{
      conn: conn,
      ws: ws
    } do
      ticket = verifying_issue(ws, "restart and observe")

      view = live_board(conn)

      assert has_element?(view, ~s(#card-#{ticket.id} [data-attention="coordinator"]))
      refute has_element?(view, "#lane-ticket-#{ticket.id}")

      view |> element("#board-attention-coordinator") |> render_click()

      assert has_element?(view, "#lane-ticket-#{ticket.id}")
      assert has_element?(view, ~s(#board-attention-coordinator[aria-pressed="true"]))
    end

    test "collapsing the lane hides its items and shows the count", %{conn: conn, ws: ws} do
      ticket = ws |> merging_issue("needs a person") |> operator_attention!()

      view = live_board(conn)
      view |> element("#board-attention-toggle") |> render_click()

      refute has_element?(view, "#lane-ticket-#{ticket.id}")
      assert has_element?(view, "#board-attention-count", "1")
      assert has_element?(view, ~s(#board-attention-toggle[aria-expanded="false"]))
    end

    test "swimlane ticket navigates to the task detail page", %{conn: conn, ws: ws} do
      ticket = ws |> merging_issue("needs a person") |> operator_attention!()

      view = live_board(conn)

      assert has_element?(view, ~s(a#lane-ticket-#{ticket.id}[href="/tasks/#{ticket.id}"]))
    end
  end

  # ---- 4. system alerts -------------------------------------------------------

  describe "system alerts in the swimlane" do
    test "an active alert is a lane card with no ticket, and a cleared one goes", %{
      conn: conn,
      ws: ws
    } do
      {:ok, alert} =
        Alerts.raise_alert(%{
          kind: :credential_expired,
          key: "claude:probe-#{ws.id}",
          workspace_id: ws.id,
          subject: "Claude credential expired",
          detail: "re-run claude setup-token"
        })

      view = live_board(conn)

      assert has_element?(view, "#board-attention-lane #lane-alert-#{alert.id}")
      assert has_element?(view, "#lane-alert-#{alert.id}", "Claude credential expired")
      refute has_element?(view, ~s(#lane-alert-#{alert.id} a[href^="/tasks/"]))

      {:ok, [_cleared]} = Alerts.clear(:credential_expired, alert.key)
      # The clear is announced on the workspace's event stream; once the view
      # has handled that message, its refresh is the async read to wait on.
      _ = :sys.get_state(view.pid)
      render_async_settled(view, @async_timeout)

      refute has_element?(view, "#lane-alert-#{alert.id}")
    end
  end

  # ---- 5. the per-viewer toggle -----------------------------------------------

  describe "the lane's toggle, remembered in browser storage by the hook" do
    test "the lane carries the hook that reads and writes browser storage", %{conn: conn} do
      view = live_board(conn)

      assert has_element?(view, ~s(#board-attention-lane[phx-hook]))
    end

    test "a stored preference restores the lane collapsed with the chip on", %{
      conn: conn,
      ws: ws
    } do
      ticket = verifying_issue(ws, "coordinator's")

      view = live_board(conn)

      render_hook(view, "attention_lane_restore", %{"open" => false, "coordinator" => true})

      assert has_element?(view, ~s(#board-attention-toggle[aria-expanded="false"]))
      assert has_element?(view, "#board-attention-count", "1")
      refute has_element?(view, "#lane-ticket-#{ticket.id}")
    end

    test "toggling pushes the new preference for the hook to store", %{conn: conn} do
      view = live_board(conn)

      view |> element("#board-attention-toggle") |> render_click()

      assert_push_event(view, "attention_lane_pref", %{open: false, coordinator: false})
    end

    test "no stored preference (storage unavailable) leaves the defaults", %{conn: conn, ws: ws} do
      ticket = ws |> merging_issue("needs a person") |> operator_attention!()

      view = live_board(conn)

      # What the hook sends when storage throws or holds nothing usable.
      render_hook(view, "attention_lane_restore", %{})
      render_hook(view, "attention_lane_restore", %{"open" => "garbage"})

      assert has_element?(view, ~s(#board-attention-toggle[aria-expanded="true"]))
      assert has_element?(view, "#lane-ticket-#{ticket.id}")
      assert column_order(view) |> length() == 7
    end
  end

  # ---- 6. manual order --------------------------------------------------------

  describe "drag to rank" do
    test "a drag within Ready persists rank, and the order survives a reload", %{
      conn: conn,
      ws: ws
    } do
      a = ready_issue(ws, "a")
      b = ready_issue(ws, "b")
      c = ready_issue(ws, "c")

      view = live_board(conn)
      assert card_order(view, "ready") == [a.id, b.id, c.id]

      render_hook(view, "reorder", %{"id" => c.id, "column" => "ready", "before_id" => a.id})
      render_async_settled(view, @async_timeout)

      assert card_order(view, "ready") == [c.id, a.id, b.id]
      assert reload(c).rank < reload(a).rank

      assert card_order(live_board(conn), "ready") == [c.id, a.id, b.id]
    end

    test "a drag within Backlog persists rank", %{conn: conn, ws: ws} do
      a = backlog_issue(ws, "a")
      b = backlog_issue(ws, "b")

      view = live_board(conn)
      assert card_order(view, "backlog") == [a.id, b.id]

      render_hook(view, "reorder", %{"id" => a.id, "column" => "backlog", "after_id" => b.id})
      render_async_settled(view, @async_timeout)

      assert card_order(view, "backlog") == [b.id, a.id]
      assert card_order(live_board(conn), "backlog") == [b.id, a.id]
    end

    test "dropping a P2 card among P1 cards makes it P1", %{conn: conn, ws: ws} do
      p1a = ready_issue(ws, "p1 a", %{priority: 1})
      p1b = ready_issue(ws, "p1 b", %{priority: 1})
      p2 = ready_issue(ws, "p2", %{priority: 2})

      view = live_board(conn)

      render_hook(view, "reorder", %{"id" => p2.id, "column" => "ready", "after_id" => p1a.id})
      render_async_settled(view, @async_timeout)

      assert reload(p2).priority == 1
      assert card_order(view, "ready") == [p1a.id, p2.id, p1b.id]
    end

    test "Autopilot dispatches in the Ready column's displayed order", %{conn: conn, ws: ws} do
      a = ready_issue(ws, "a", %{priority: 1})
      b = ready_issue(ws, "b", %{priority: 2})
      c = ready_issue(ws, "c", %{priority: 2})

      view = live_board(conn)
      render_hook(view, "reorder", %{"id" => c.id, "column" => "ready", "before_id" => a.id})
      render_async_settled(view, @async_timeout)

      displayed = card_order(view, "ready")
      assert displayed == [c.id, a.id, b.id]

      plan = Autopilot.board(Autopilot)
      planned = plan.ready |> Enum.map(& &1.id) |> Enum.filter(&(&1 in displayed))

      assert planned == displayed
      assert plan.promote == hd(displayed)
    end

    test "a reorder naming a card that is not in that column changes nothing", %{
      conn: conn,
      ws: ws
    } do
      a = ready_issue(ws, "a")
      b = backlog_issue(ws, "b")

      view = live_board(conn)
      before = reload(a).rank

      render_hook(view, "reorder", %{"id" => a.id, "column" => "ready", "before_id" => b.id})

      assert reload(a).rank == before
    end
  end

  # ---- 7. column drags --------------------------------------------------------

  describe "column drags" do
    defp drag(view, id, from, to) do
      render_hook(view, "drag", %{"id" => id, "from" => from, "to" => to})
      render_async_settled(view, @async_timeout)
    end

    test "Backlog → Ready promotes", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "promote me")

      view = live_board(conn)
      drag(view, task.id, "backlog", "ready")

      assert reload(task).state == :queued
      assert in_column?(view, "ready", task.id)
    end

    test "Backlog → Blocked promotes, and the ticket lands where its blockers put it", %{
      conn: conn,
      ws: ws
    } do
      blocker = ready_issue(ws, "first")
      task = backlog_issue(ws, "promote me")
      depends_on!(task, blocker)

      view = live_board(conn)
      drag(view, task.id, "backlog", "blocked")

      assert reload(task).state == :queued
      assert in_column?(view, "blocked", task.id)
    end

    test "promotion follows the acceptance-criteria rule", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "no AC", %{acceptance: nil, issue_type: :feature, difficulty: 2})

      view = live_board(conn)
      html = drag(view, task.id, "backlog", "ready")

      assert reload(task).state == :backlog
      assert html =~ "acceptance"
    end

    test "Ready → Backlog and Blocked → Backlog demote", %{conn: conn, ws: ws} do
      ready = ready_issue(ws, "ready")
      blocker = ready_issue(ws, "first")
      blocked = ready_issue(ws, "blocked")
      depends_on!(blocked, blocker)

      view = live_board(conn)
      drag(view, ready.id, "ready", "backlog")
      drag(view, blocked.id, "blocked", "backlog")

      assert reload(ready).state == :backlog
      assert reload(blocked).state == :backlog
      assert in_column?(view, "backlog", ready.id)
      assert in_column?(view, "backlog", blocked.id)
    end

    test "every other cross-column drag is refused with a flash", %{conn: conn, ws: ws} do
      ready = ready_issue(ws, "ready")
      active = active_issue(ws, "working")

      view = live_board(conn)

      for {id, from, to} <- [
            {ready.id, "ready", "in_progress"},
            {ready.id, "ready", "blocked"},
            {active.id, "in_progress", "ready"},
            {active.id, "in_progress", "closed"}
          ] do
        html = drag(view, id, from, to)
        assert html =~ "cannot be dragged", "#{from} → #{to} was not refused"
      end

      assert reload(ready).state == :queued
      assert reload(active).state == :active
    end

    test "dropping a card back on its own column does nothing", %{conn: conn, ws: ws} do
      active = active_issue(ws, "working")

      view = live_board(conn)
      html = drag(view, active.id, "in_progress", "in_progress")

      refute html =~ "cannot be dragged"
      assert reload(active).state == :active
    end
  end
end
