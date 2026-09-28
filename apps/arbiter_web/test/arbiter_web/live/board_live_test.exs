defmodule ArbiterWeb.BoardLiveTest.BoardMerger do
  @moduledoc "Stub merger whose PR puts a ticket in Merging, i.e. in Waiting."
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!77"}
  @impl true
  def get(_ref), do: {:ok, %{status: :open, approved: false}}
  @impl true
  def merge(_ref, _expected_sha), do: :ok
  @impl true
  def close(_ref), do: :ok
  @impl true
  def add_comment(_ref, _body), do: :ok
  @impl true
  def request_review(_ref, _reviewers), do: :ok
  @impl true
  def link_for(_ref), do: "https://example.test/mr/77"
  @impl true
  def get_diff(_ref, _opts), do: {:ok, ""}
  @impl true
  def post_inline_comment(_ref, _finding, _opts), do: :ok
  @impl true
  def submit_review(_ref, _verdict, _body, _opts), do: :ok
  @impl true
  def list_review_feedback(_ref),
    do: {:ok, %{changes_requested: false, latest_review_id: nil, feedback: []}}
end

defmodule ArbiterWeb.BoardLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # The board loads by start_async (bd-15bn6s) and a real Snapshot.load can
  # outrun render_async's 100ms default under a loaded suite.
  @async_timeout 5_000

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.{Dependency, Issue, PullRequest, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.Watchdog
  alias ArbiterWeb.BoardLiveTest.BoardMerger

  setup do
    # Workers are supervised at the VM level — a prior test in the umbrella may
    # have left children running, and every one of them lands in a column.
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    # The autopilot is one process for the whole VM and ships paused, which
    # would make every Ready card read "scheduler paused". These tests are
    # about a board whose scheduler is live, so resume it for the duration and
    # put it back afterwards. `interval_ms: :never` in the test env means a
    # resumed autopilot still never dispatches on its own.
    Autopilot.resume(Autopilot)
    on_exit(fn -> Autopilot.pause(Autopilot) end)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "board-#{System.unique_integer([:positive])}", prefix: "bd"})

    {:ok, ws: ws}
  end

  # bd-b5wyjd: a freshly created issue is unrefined, i.e. Backlog. Almost every
  # test here is about a card that has already been refined into the queue, so
  # this helper promotes; `backlog_issue/3` is the un-promoted one.
  defp issue(ws, title, attrs \\ %{}) do
    {:ok, issue} = Ash.update(backlog_issue(ws, title, attrs), %{}, action: :promote_to_ready)
    issue
  end

  defp backlog_issue(ws, title, attrs \\ %{}) do
    # bd-7mbrlg: `:promote_to_ready` now refuses a gated type with no
    # acceptance criteria. Nothing in this file is testing that guard, so the
    # fixture carries a placeholder AC unless the caller overrides it.
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: title, workspace_id: ws.id, acceptance: "- board fixture"}, attrs)
      )

    issue
  end

  # `:status` is not a create input — a task becomes in_progress by being
  # worked, which is exactly the state these drags start from.
  defp working_issue(ws, title) do
    {:ok, issue} = Ash.update(issue(ws, title), %{status: :in_progress})
    issue
  end

  # The one gesture the client reports: this card, out of that column, into
  # this one. The board decides what — if anything — that means.
  # Returns the page as it stands once the refresh the drag asked for lands.
  defp drag(view, id, from, to) do
    render_hook(view, "drag", %{"id" => id, "from" => from, "to" => to})
    render_async(view, @async_timeout)
  end

  # The board arrives by `start_async/3` after the connected mount (bd-15bn6s);
  # everything but the async tests themselves wants the page once it has.
  defp live_board(conn) do
    {:ok, view, _html} = live(conn, "/")
    {:ok, view, render_async(view, @async_timeout)}
  end

  # A worker waiting on a question (state :waiting, waiting_on :question) —
  # the escalation case that flags in Waiting.
  defp parked_worker(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :verify)
    :ok = Worker.await(pid, :question)
    pid
  end

  # An In-progress ticket's worker opens its MR, so the ticket is Merging — the
  # other half of Waiting (bd-741sid). The run ends once the MR is open; the
  # ticket's Watchdog is pushed far enough out that it never polls, so the
  # card's merger status is only ever what a test records by hand.
  defp open_pr(ws, task) do
    {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
    :ok = Worker.advance(pid, :integrate)
    run = Process.monitor(pid)

    {:ok, "!77"} =
      Worker.open_mr(pid, "feature/x", "Integrate x", "", %{
        adapter: BoardMerger,
        workspace: nil,
        auto_merge: false,
        interval_ms: 600_000,
        initial_delay_ms: 600_000
      })

    assert_receive {:DOWN, ^run, :process, ^pid, _}, 2_000
    task
  end

  describe "columns" do
    test "renders the five stage columns", %{conn: conn} do
      {:ok, view, html} = live_board(conn)

      assert html =~ "Backlog"
      assert html =~ "Ready"
      assert html =~ "Running"
      assert html =~ "Waiting"
      assert html =~ "Closed · last 24h"

      assert has_element?(view, "#board-column-backlog")
      assert has_element?(view, "#board-column-waiting")
      # The two columns Waiting replaced are gone, not renamed alongside it.
      # ("Merge queue" as a phrase survives in the top nav, so match the
      # columns themselves rather than the page text.)
      refute has_element?(view, "#board-column-needs-you")
      refute has_element?(view, "#board-column-merge")
      refute html =~ "Needs you"
    end

    test "an open issue nobody is working shows up in Ready", %{conn: conn, ws: ws} do
      task = issue(ws, "collapse duplicate status helpers")

      {:ok, _view, html} = live_board(conn)

      assert html =~ task.id
      assert html =~ "collapse duplicate status helpers"
    end

    test "the mine/all toggle is not rendered (Arbiter is single-user)", %{conn: conn} do
      {:ok, view, _html} = live_board(conn)

      refute has_element?(view, ~s(button[phx-click="scope"]))
      refute has_element?(view, ~s(button[phx-value-option="mine"]))
      refute has_element?(view, ~s(button[phx-value-option="all"][phx-click="scope"]))
    end

    test "a closed issue leaves Ready for Closed today", %{conn: conn, ws: ws} do
      task = issue(ws, "already landed")
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-closed [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end

    # bd-38of5i (design bd-2s901b §4): Closed-today was the one column an epic
    # could still reach. It is a rollup of the children below it, not a piece
    # of work that landed.
    test "an epic closed today does not appear in the Closed column", %{conn: conn, ws: ws} do
      epic = issue(ws, "wave one", %{issue_type: :epic})
      task = issue(ws, "an actual change")
      {:ok, _} = Ash.update(epic, %{}, action: :close)
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-closed [id="card-#{task.id}"]))
      refute has_element?(view, ~s([id="card-#{epic.id}"]))
    end

    # The board's whole replacement for the epic cards it no longer shows.
    test "a card whose issue has a parent shows a ↳ chip linking to the parent", %{
      conn: conn,
      ws: ws
    } do
      epic = issue(ws, "browser coordinator sessions", %{issue_type: :epic})
      task = issue(ws, "the terminal channel")
      {:ok, _} = Arbiter.Tasks.Dependencies.add(epic.id, task.id, :parent_of)

      {:ok, view, _html} = live_board(conn)

      chip = ~s([id="card-#{task.id}"] [data-role="parent-chip"])

      assert has_element?(view, chip)
      assert has_element?(view, ~s(#{chip}[href="/tasks/#{epic.id}"]))
      # Title and progress ride in the tooltip: the card has no room for them.
      assert render(view) =~ ~s(title="browser coordinator sessions — 0/1 closed")
    end

    test "a card whose issue has no parent shows no chip", %{conn: conn, ws: ws} do
      task = issue(ws, "an orphan of no epic")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{task.id}"]))
      refute has_element?(view, ~s([id="card-#{task.id}"] [data-role="parent-chip"]))
    end

    # bd-5l88o5 — every board card carries a copy-id control so an operator
    # can grab the issue id without leaving the board. bd-1rreu1 moved card
    # navigation off a wrapping `<a>` onto a `phx-click={JS.navigate(...)}`
    # div, so the copy button is no longer nested inside a link at all — it
    # relies solely on the CopyId hook's `e.preventDefault()` +
    # `e.stopPropagation()` to keep its click from also bubbling into the
    # card's own navigation. That hook JS is asserted directly in
    # core_test.exs; this test only pins the button's presence and that it
    # is not nested inside any `<a>` (no `<a>`-in-`<a>` regression either).
    test "a card carries a copy-id button naming the issue id, not nested inside a link", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "collapse duplicate status helpers")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(div[id="card-#{task.id}"] button[type="button"][aria-label="Copy issue id #{task.id}"])
             )

      refute has_element?(
               view,
               ~s(div[id="card-#{task.id}"] a button[type="button"][aria-label="Copy issue id #{task.id}"])
             )
    end
  end

  # bd-1rreu1 — before this, the same click opened a task, a worker, or the
  # merge queue depending on which column the card sat in. Now the card body
  # and title always go to the issue's own page, in every column; a column's
  # contextual destination (the running worker, the merge queue, a dead
  # watchdog's restart) survives only as an explicit inner link, never as
  # the whole-card click target. Card navigation moved off a wrapping `<a>`
  # onto `phx-click={JS.navigate(...)}` so those inner links (activity line,
  # action chips) can be real `<a>` elements without nesting one `<a>`
  # inside another.
  describe "card body navigation always opens the issue" do
    # The attribute substring selector pins the check to the card wrapper's
    # own `phx-click` attribute, not any link nested inside it (e.g. the
    # Running activity line or a Waiting action chip, both of which may
    # legitimately point elsewhere within the same card).
    defp card_navigates_to?(view, card_id, href) do
      has_element?(view, ~s([id="card-#{card_id}"][phx-click*="#{href}"]))
    end

    test "Backlog card body navigates to the task page", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "half an idea")

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "Ready card body navigates to the task page", %{conn: conn, ws: ws} do
      task = issue(ws, "queued work")

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "Running card body navigates to the task page, not the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
      refute card_navigates_to?(view, task.id, "/workers/#{task.id}")
    end

    test "Waiting card body navigates to the task page, not the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "still in review")
      open_pr(ws, task)

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "Closed card body navigates to the task page", %{conn: conn, ws: ws} do
      task = issue(ws, "already landed")
      {:ok, _} = Ash.update(task, %{}, action: :close)

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "no board card nests an <a> inside another <a>", %{conn: conn, ws: ws} do
      running = issue(ws, "running card")
      {:ok, _pid} = Worker.start(task_id: running.id, repo: "r", workspace_id: ws.id)

      waiting = working_issue(ws, "waiting card")
      open_pr(ws, waiting)

      {:ok, view, html} = live_board(conn)

      refute Regex.match?(~r/<a\b[^>]*>(?:(?!<\/a>).)*<a\b/s, html)

      # The action chips still render real links even though the card
      # wrapper itself is no longer an `<a>`.
      assert has_element?(view, ~s([id="card-#{waiting.id}"] a))
    end
  end

  describe "Running column: the activity line links to the worker" do
    test "the activity line is a link to the worker page", %{conn: conn, ws: ws} do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(#board-column-running [id="card-#{task.id}"] a[href="/workers/#{task.id}"])
             )
    end
  end

  describe "Waiting column: the action chip keeps today's contextual destination" do
    test "awaiting verification points the chip at the task page", %{conn: conn, ws: ws} do
      task = working_issue(ws, "doctor probe")
      {:ok, task} = Ash.update(task, %{}, action: :await_verification)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s([id="card-#{task.id}"] a[href="/tasks/#{task.id}"])
             )
    end

    test "a dead watchdog points the chip at the worker page, not the merge queue", %{
      conn: conn,
      ws: ws
    } do
      dead = working_issue(ws, "nobody is watching this")
      {:ok, pid} = Worker.start(task_id: dead.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)

      {:ok, _} =
        Worker.open_mr(pid, "feature/x", "Integrate x", "", %{
          adapter: BoardMerger,
          workspace: nil,
          auto_merge: false,
          interval_ms: 600_000,
          initial_delay_ms: 600_000,
          watchdog_start_error: true
        })

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{dead.id}"] a[href="/workers/#{dead.id}"]))
    end

    test "an open MR under review points the chip at the merge queue", %{conn: conn, ws: ws} do
      task = working_issue(ws, "under review")
      open_pr(ws, task)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/merge_queue"]))
    end

    test "a parked worker awaiting an answer points the chip at the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "needs an answer")
      parked_worker(ws, task)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/workers/#{task.id}"]))
    end
  end

  # bd-b5wyjd — Backlog is where work is born, and the promote button on the
  # detail page is the only door out of it.
  describe "the Backlog column" do
    test "a brand-new issue lands in Backlog, not Ready", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "half an idea")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end

    test "promoting moves the card into Ready", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "now refined")
      {:ok, _} = Ash.update(task, %{}, action: :promote_to_ready)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))
    end

    test "an unrefined card never claims the head of the queue", %{conn: conn, ws: ws} do
      backlog_issue(ws, "unrefined")

      {:ok, _view, html} = live_board(conn)

      refute html =~ "next up — dispatching"
    end

    test "Backlog is newest-first", %{conn: conn, ws: ws} do
      first = backlog_issue(ws, "thought one")
      second = backlog_issue(ws, "thought two")

      {:ok, _view, html} = live_board(conn)

      assert board_position(html, second.id) < board_position(html, first.id)
    end

    test "the filter box reaches Backlog like every other column", %{conn: conn, ws: ws} do
      keep = backlog_issue(ws, "caching strategy")
      drop = backlog_issue(ws, "unrelated")

      {:ok, view, _html} = live_board(conn)
      html = render_change(view, "filter", %{"filter" => "caching"})

      assert html =~ keep.id
      refute html =~ drop.id
    end
  end

  describe "the queue reads its own reason" do
    test "the head of an idle queue says it is next up", %{conn: conn, ws: ws} do
      issue(ws, "first in line")

      {:ok, _view, html} = live_board(conn)

      assert html =~ "next up"
    end

    test "a card behind the head shows its queue position", %{conn: conn, ws: ws} do
      issue(ws, "leader", %{priority: 1})
      issue(ws, "follower", %{priority: 3})

      {:ok, _view, html} = live_board(conn)

      assert html =~ "1 ahead in queue"
    end

    test "a dependency-blocked card names the blocker instead of a position", %{
      conn: conn,
      ws: ws
    } do
      blocker = issue(ws, "must land first")
      blocked = issue(ws, "waits on the other")

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: blocked.id,
          to_issue_id: blocker.id,
          type: :depends_on
        })

      {:ok, _view, html} = live_board(conn)

      assert html =~ "blocked"
      assert html =~ blocker.id
    end

    # bd-6bax7s acceptance 3: a card held by a `conflicts_with` mutex reads the
    # same way a dependency-held one does, and names the counterpart's state so
    # an operator knows what they are waiting on.
    test "a conflict-blocked card names the counterpart and its state", %{conn: conn, ws: ws} do
      first = issue(ws, "holds the mutex", %{priority: 1})
      second = issue(ws, "waits for it", %{priority: 3})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: second.id,
          to_issue_id: first.id,
          type: :conflicts_with
        })

      {:ok, _view, html} = live_board(conn)

      assert html =~ "conflicts with #{first.id}"
      assert html =~ "(dispatching)"
      refute html =~ "1 ahead in queue"
    end
  end

  describe "the Ready column: return to Backlog" do
    test "a Ready card offers the demote button", %{conn: conn, ws: ws} do
      task = issue(ws, "ready now")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(#board-column-ready [id="card-#{task.id}"] button[phx-click="return_to_backlog"])
             )
    end

    test "clicking the demote button returns the card to Backlog", %{conn: conn, ws: ws} do
      task = issue(ws, "demote me")

      {:ok, view, _html} = live_board(conn)

      _html =
        view
        |> element(
          ~s(#board-column-ready [id="card-#{task.id}"] button[phx-click="return_to_backlog"])
        )
        |> render_click()

      render_async(view, @async_timeout)

      {:ok, reloaded} = Ash.get(Issue, task.id)
      refute reloaded.refined

      assert has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end
  end

  describe "reordering Ready (bd-asxw4e)" do
    test "a reorder leaves the scheduler's order alone and says why", %{conn: conn, ws: ws} do
      leader = issue(ws, "machine's pick", %{priority: 1})
      underdog = issue(ws, "operator's pick", %{priority: 4})

      {:ok, view, _html} = live_board(conn)

      render_hook(view, "reorder_ready", %{"order" => [underdog.id, leader.id]})

      html = render_async(view, @async_timeout)
      # Autopilot dispatches in priority-then-rank order, so the board shows
      # that order rather than a hand-ranking nothing else would follow.
      assert board_position(html, leader.id) < board_position(html, underdog.id)
      assert html =~ "priority order, then rank"
    end
  end

  describe "drag is a human action, and Running is not one of its targets" do
    test "dragging a card INTO Running is refused with an explanation", %{conn: conn, ws: ws} do
      task = issue(ws, "impatient")

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "ready", "running")

      assert html =~ "scheduler"
      # The card did not move. Whether it dispatches is the scheduler's call,
      # and it makes it from Ready.
      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-running [id="card-#{task.id}"]))
    end
  end

  describe "pulling work out of Running" do
    test "asks for confirmation before it stops anything", %{conn: conn, ws: ws} do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "running", "ready")

      assert html =~ "Stop"
      # Still running — nothing was stopped by asking.
      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))

      view |> element(~s(button[phx-click="confirm_stop"])) |> render_click()
      Process.sleep(80)

      refute Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end

    test "putting a Running card back down where it was asks nothing", %{conn: conn, ws: ws} do
      task = issue(ws, "picked up, thought better of it")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "running", "running")

      # A drag that changed nothing must not offer to destroy live work: the
      # confirmation is one click from killing the agent.
      refute html =~ "Stop"
      refute has_element?(view, ~s(button[phx-click="confirm_stop"]))
      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end

    test "cancelling the confirmation leaves the worker alone", %{conn: conn, ws: ws} do
      task = issue(ws, "leave me be")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)
      drag(view, task.id, "running", "ready")

      view |> element(~s(button[phx-click="cancel_stop"])) |> render_click()

      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end
  end

  describe "Running column rendering" do
    test "displays difficulty on running cards", %{conn: conn, ws: ws} do
      task = issue(ws, "work with difficulty", %{difficulty: 2})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(#board-column-running [id="card-#{task.id}"] [aria-label="Difficulty D2"])
             )
    end

    test "does not crash when difficulty is not set", %{conn: conn, ws: ws} do
      task = issue(ws, "no difficulty set")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, _view, html} = live_board(conn)

      assert html =~ task.id
    end

    test "shows the worker's provider icon", %{conn: conn, ws: ws} do
      task = issue(ws, "work on codex")
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.report(pid, :provider, "codex")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(#board-column-running [id="card-#{task.id}"] [aria-label="Codex"])
             )
    end
  end

  describe "the Waiting column holds everything out of the worker's hands" do
    # bd-8jixav: the Watchdog is a :temporary process, so a crash leaves the
    # ticket Merging on an open MR nothing polls. The board used to keep
    # showing an ordinary merge card.
    defp open_pr_without_watchdog(ws, task) do
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      run = Process.monitor(pid)

      {:ok, _} =
        Worker.open_mr(pid, "feature/x", "Integrate x", "", %{
          adapter: BoardMerger,
          workspace: nil,
          auto_merge: false,
          interval_ms: 600_000,
          initial_delay_ms: 600_000,
          watchdog_start_error: true
        })

      assert_receive {:DOWN, ^run, :process, ^pid, _}, 2_000
      task
    end

    test "a card whose watchdog died says so and offers the restart", %{conn: conn, ws: ws} do
      dead = working_issue(ws, "nobody is watching this")
      open_pr_without_watchdog(ws, dead)

      {:ok, view, html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{dead.id}"]))
      assert html =~ "no watchdog"
      # A dead watchdog means nothing is left for the system to try.
      assert has_element?(view, ~s([id="card-#{dead.id}"] [data-needs-you]))
      # And the card routes to the worker page — where the restart lives —
      # rather than to the merge queue, which can do nothing about it.
      assert has_element?(view, ~s([id="card-#{dead.id}"] a[href="/workers/#{dead.id}"]))
    end

    test "a card with a live watchdog says nothing about one", %{conn: conn, ws: ws} do
      polling = working_issue(ws, "still in review")
      open_pr(ws, polling)

      {:ok, _view, html} = live_board(conn)

      refute html =~ "no watchdog"
    end

    # The other half of bd-8jixav: a task with both a primary worker parked on
    # its open PR (the pre-bd-741sid `awaiting_review` status, now gone) and a
    # subordinate failed fix-pass row rendered as two cards. Since
    # bd-741sid the card is the Merging ticket's, and a pass is the ticket's
    # own run, registered under the ticket id.
    test "a Merging ticket with a failed pass under it renders one card, not two", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "one card please")
      open_pr(ws, task)

      # The pass carries its role in meta — the same shape
      # MergeQueue.FixPassDispatcher starts.
      {:ok, fixpass} =
        Worker.start(
          task_id: task.id,
          repo: "r",
          workspace_id: ws.id,
          meta: %{role: :fix_pass}
        )

      :ok = Worker.fail(fixpass, "fix pass blew up")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{task.id}"]))

      assert view
             |> render()
             |> then(&Regex.scan(~r/id="card-#{task.id}"/, &1))
             |> length() == 1

      # The collapsed pass keeps its failure on the one card.
      assert has_element?(view, ~s([id="card-#{task.id}"]), "fix pass failed")
    end

    test "a parked worker and a Merging ticket share the column", %{conn: conn, ws: ws} do
      parked = working_issue(ws, "answer me")
      parked_worker(ws, parked)

      merging = working_issue(ws, "land it later")
      open_pr(ws, merging)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{parked.id}"]))
      assert has_element?(view, ~s(#board-column-waiting [id="card-#{merging.id}"]))
    end

    test "the flag marks only what the system has run out of moves for", %{conn: conn, ws: ws} do
      parked = working_issue(ws, "answer me")
      parked_worker(ws, parked)

      polling = working_issue(ws, "still in review")
      open_pr(ws, polling)

      stuck = working_issue(ws, "conflicted")
      open_pr(ws, stuck)

      :ok =
        PullRequest.record_merger_status(stuck.id, %{
          status: :open,
          approved: true,
          block_reason: :conflict
        })

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{parked.id}"] [data-needs-you]))
      assert has_element?(view, ~s([id="card-#{stuck.id}"] [data-needs-you]))
      # An MR the forge is simply still chewing on is pipeline-wait, not yours.
      refute has_element?(view, ~s([id="card-#{polling.id}"] [data-needs-you]))
    end

    test "dragging a card back to Ready sends the work back to the queue", %{conn: conn, ws: ws} do
      task = working_issue(ws, "answer was: redo it")
      parked_worker(ws, task)

      {:ok, view, _html} = live_board(conn)
      assert has_element?(view, ~s(#board-column-waiting [id="card-#{task.id}"]))

      html = drag(view, task.id, "waiting", "ready")
      Process.sleep(80)

      assert html =~ "queue"
      # The worker is gone and the issue is open again, so the scheduler picks
      # it up on its own terms rather than resuming a halted session.
      refute Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
      assert Ash.get!(Issue, task.id).status == :open

      html = render(view)
      assert html =~ task.id
      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end

    test "dragging a parked card toward Closed lets the worker proceed", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "answer was: carry on")
      pid = parked_worker(ws, task)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "waiting", "closed")

      assert html =~ "proceed"
      assert %{state: :working, waiting_on: nil} = Worker.state(pid)
      # Un-parking is not a promotion: it went back to its own work, so it
      # belongs in Running, not still waiting.
      assert has_element?(view, ~s(#board-column-running [id="card-#{task.id}"]))
    end

    # bd-asxw4e: a ticket parked on a question is still In progress, so it
    # never gave its slot up — letting it proceed is not a new admission, and
    # a full cap does not stop it (bd-92mx1m's refusal is for tickets that are
    # not In progress).
    test "at a full cap a parked card still proceeds: it holds its own slot", %{
      conn: conn,
      ws: ws
    } do
      prior = Application.fetch_env(:arbiter, :conductor_system_max_concurrent)
      Application.put_env(:arbiter, :conductor_system_max_concurrent, 1)

      on_exit(fn ->
        case prior do
          {:ok, v} -> Application.put_env(:arbiter, :conductor_system_max_concurrent, v)
          :error -> Application.delete_env(:arbiter, :conductor_system_max_concurrent)
        end
      end)

      parked = working_issue(ws, "asked a question")
      pid = parked_worker(ws, parked)

      holder = working_issue(ws, "admitted into the freed slot")
      {:ok, holder_pid} = Worker.start(task_id: holder.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.advance(holder_pid, :implement)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, parked.id, "waiting", "closed")

      assert html =~ "proceed"
      refute html =~ "cap is 1"
      assert Worker.state(pid).state == :working
    end

    test "a card the worker FSM will not un-park says so rather than moving", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "reviewer said no")
      pid = parked_worker(ws, task)
      :ok = Worker.fail(pid, :review_rejected)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "waiting", "closed")

      assert html =~ "failed"
      assert %{state: :finished, outcome: :failed} = Worker.state(pid)
    end

    # bd-741sid: no worker sits on an open MR — the ticket's Watchdog is what
    # keeps it in the merge queue, so that is what the drag stops.
    test "dragging a Merging card out stops its Watchdog and leaves the MR", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "land it later")
      open_pr(ws, task)
      watchdog = Watchdog.whereis(task.id)
      assert is_pid(watchdog)
      watching = Process.monitor(watchdog)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "waiting", "closed")

      assert html =~ "merge request is untouched"
      assert_receive {:DOWN, ^watching, :process, ^watchdog, _}, 1_000
      assert %{state: :merging, pr_ref: "!77"} = Ash.get!(Issue, task.id)

      # bd-741sid, review round 1 (finding 4): the pull is on the ticket, so
      # no automatic restart undoes it, and the card reads as a pull rather
      # than as a Watchdog that died.
      assert PullRequest.pulled?(Ash.get!(Issue, task.id))
      assert {:error, :pulled} = Watchdog.restart(task.id)
      assert html =~ "pulled from merge queue"
      refute html =~ "no watchdog polling"
      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/workers/#{task.id}"]))
    end

    test "merge-queue cards render merger_status text correctly", %{conn: conn, ws: ws} do
      # nil merger_status renders as "checks"
      nil_status = working_issue(ws, "nil status card")
      open_pr(ws, nil_status)

      # pending card (no block_reason) renders as "checks"
      pending = working_issue(ws, "pending card")
      open_pr(ws, pending)

      :ok =
        PullRequest.record_merger_status(pending.id, %{
          status: :open,
          approved: false,
          pipeline: :success
        })

      # approved card (no block_reason) renders as "approved"
      approved = working_issue(ws, "approved card")
      open_pr(ws, approved)

      :ok =
        PullRequest.record_merger_status(approved.id, %{
          status: :open,
          approved: true,
          pipeline: :success
        })

      # merged card renders as "merged"
      merged = working_issue(ws, "merged card")
      open_pr(ws, merged)

      :ok =
        PullRequest.record_merger_status(merged.id, %{
          status: :merged,
          approved: true,
          pipeline: :success
        })

      # blocked cards with various block_reasons
      conflict_card = working_issue(ws, "conflict card")
      open_pr(ws, conflict_card)

      :ok =
        PullRequest.record_merger_status(conflict_card.id, %{
          status: :open,
          approved: true,
          block_reason: :conflict
        })

      ci_failed_card = working_issue(ws, "ci failed card")
      open_pr(ws, ci_failed_card)

      :ok =
        PullRequest.record_merger_status(ci_failed_card.id, %{
          status: :open,
          approved: true,
          pipeline: :failed,
          block_reason: :ci_failed
        })

      behind_base_card = working_issue(ws, "behind base card")
      open_pr(ws, behind_base_card)

      :ok =
        PullRequest.record_merger_status(behind_base_card.id, %{
          status: :open,
          approved: true,
          block_reason: :behind_base
        })

      {:ok, _view, html} = live_board(conn)

      # The key assertion: rendering doesn't crash when merger_status is a populated map.
      # All cards appear in the board, proving the render succeeded.
      assert html =~ nil_status.id
      assert html =~ pending.id
      assert html =~ approved.id
      assert html =~ merged.id
      assert html =~ conflict_card.id
      assert html =~ ci_failed_card.id
      assert html =~ behind_base_card.id

      # Verify correct merger_status text appears (merge_status_text/1 rendering)
      # nil status and pending cards
      assert html =~ "checks"
      assert html =~ "approved"
      assert html =~ "merged"
      assert html =~ "conflict"
      assert html =~ "ci failed"
      assert html =~ "behind base"
    end
  end

  # bd-9so315 — a merged-but-unverified task has no worker, so without its own
  # card it would be invisible on the board: exactly the gap the state exists
  # to close.
  describe "the Waiting column lists tasks awaiting verification" do
    defp awaiting_issue(ws, title) do
      task = working_issue(ws, title)
      {:ok, awaiting} = Ash.update(task, %{}, action: :await_verification)
      awaiting
    end

    test "a parked task renders a Waiting card with its age and needs-you", %{conn: conn, ws: ws} do
      task = awaiting_issue(ws, "doctor probe")

      {:ok, view, html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-waiting [id="card-#{task.id}"]))
      assert html =~ "awaiting verification"
      assert has_element?(view, ~s([id="card-#{task.id}"] [data-needs-you]))
      # It routes to the task, where the verification evidence lives — not to a
      # worker page for a worker the merge already tore down.
      assert has_element?(view, ~s([id="card-#{task.id}"] a[href="/tasks/#{task.id}"]))
    end

    test "dragging it out points at the verify verb instead of guessing", %{conn: conn, ws: ws} do
      task = awaiting_issue(ws, "capture path")

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "waiting", "closed")
      assert html =~ "arb issue verify"

      # And the task did not move.
      assert Ash.get!(Issue, task.id).status == :awaiting_verification
    end
  end

  describe "drops that mean nothing" do
    test "dropping onto Closed today changes nothing and says nothing", %{conn: conn, ws: ws} do
      task = issue(ws, "not done yet")

      {:ok, view, _html} = live_board(conn)

      drag(view, task.id, "ready", "closed")

      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      assert Ash.get!(Issue, task.id).status == :open
    end
  end

  describe "the scheduler switch" do
    test "pausing is visible on every Ready card", %{conn: conn, ws: ws} do
      issue(ws, "would have gone next")

      {:ok, view, _html} = live_board(conn)

      view |> element(~s(button[phx-click="toggle_scheduler"])) |> render_click()

      assert render_async(view, @async_timeout) =~ "scheduler paused"
    end

    test "scheduler toggle button has cursor-pointer class", %{conn: conn} do
      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-scheduler-toggle.cursor-pointer))
    end
  end

  describe "toolbar" do
    test "reports the fleet's slot arithmetic", %{conn: conn} do
      {:ok, _view, html} = live_board(conn)

      assert html =~ "slots free"
    end

    # "agents live" (live agent sessions) and "slots used" (tickets In
    # progress, bd-asxw4e) are different numbers — a ticket between rounds
    # burns no agent but holds its slot, and one Merging on an open MR holds
    # neither.
    test "shows agents live and slots used separately, and they can differ", %{
      conn: conn,
      ws: ws
    } do
      _between_rounds = working_issue(ws, "between review rounds")
      on_its_mr = working_issue(ws, "parked on its MR")
      open_pr(ws, on_its_mr)
      assert Ash.get!(Issue, on_its_mr.id).state == :merging

      {:ok, _view, html} = live_board(conn)

      assert html =~ "agents live: 0"
      assert html =~ "slots used: 1"
    end

    test "the filter narrows the board to matching issues", %{conn: conn, ws: ws} do
      keep = issue(ws, "keep this one")
      drop = issue(ws, "unrelated work")

      {:ok, view, _html} = live_board(conn)

      html =
        view
        |> form("#board-filter-form", %{"filter" => "keep this"})
        |> render_change()

      assert html =~ keep.id
      refute html =~ drop.id
    end
  end

  # Index of a card's DOM id in the rendered page — a crude but sufficient
  # proxy for "which one comes first in the column".
  defp board_position(html, id) do
    case :binary.match(html, ~s(id="card-#{id}")) do
      {at, _} -> at
      :nomatch -> flunk("card #{id} is not on the board")
    end
  end

  describe "mobile horizontal scrolling layout" do
    test "board columns container uses flexbox with horizontal scrolling", %{conn: conn} do
      {:ok, _view, html} = live_board(conn)

      # Verify the board-columns div has flex and overflow-x-auto for horizontal scrolling
      assert html =~ ~s(id="board-columns")
      assert html =~ ~s(flex overflow-x-auto snap-x snap-mandatory)
    end

    test "each column div has fixed width and prevents shrinking", %{conn: conn, ws: ws} do
      issue(ws, "test issue")
      {:ok, _view, html} = live_board(conn)

      # Each column should have flex-shrink-0 to maintain width while scrolling
      # and a responsive width (w-[85vw] on mobile, md:w-72 on desktop)
      assert html =~ ~s(id="board-column-backlog")
      assert html =~ ~s(flex-shrink-0)
      assert html =~ ~s(snap-start)
    end

    test "toolbar dropdowns are responsive and do not have fixed widths", %{conn: conn} do
      {:ok, _view, html} = live_board(conn)

      # Verify the toolbar form inputs don't have restrictive fixed widths
      assert html =~ ~s(id="board-workspace-form")
      assert html =~ ~s(id="board-filter-form")
      # Should NOT have the old fixed widths
      refute html =~ ~s(w-[136px])
      refute html =~ ~s(w-[260px])
    end

    test "toolbar wraps on narrow viewports instead of overflowing", %{conn: conn} do
      {:ok, _view, html} = live_board(conn)

      # The toolbar outer container must wrap items to multiple rows on mobile
      assert html =~ ~s(id="board" class="border border-solid)
      # Verify the toolbar div has flex-wrap for wrapping behavior
      assert html =~ ~s(flex flex-wrap items-center gap-3)
      # Verify the ml-auto span also wraps independently
      assert html =~ ~s(ml-auto flex flex-wrap items-center gap-2.5)
      # Verify board-slots text is hidden on mobile (sm:inline shows on small+)
      assert html =~ ~s(hidden sm:inline)
      # Verify old fixed widths from before #1395 are gone
      refute html =~ ~s(w-[136px])
      refute html =~ ~s(w-[260px])
    end

    test "columns fill the full width on xl breakpoint and above", %{conn: conn, ws: ws} do
      issue(ws, "test issue")
      {:ok, _view, html} = live_board(conn)

      # The board-columns container must switch to grid layout on xl:
      # xl:grid switches display from flex to grid at that breakpoint
      assert html =~ "xl:grid xl:grid-cols-5"

      # Each column must have xl:w-auto so grid tracks stretch to fill width
      assert html =~ "xl:w-auto"
    end
  end

  # bd-8j9i9p (design bd-9jj5lf §3): an open card whose worker spend has passed
  # its estimate group's p90 carries the same kind of flag `needs_you` does —
  # the board is read from across a room, and "this one is burning money" is a
  # thing to notice without opening it.
  describe "over-budget flag on a card" do
    setup %{ws: ws} do
      # n=10 closed D2 features costing $1..$10 → p90 $9.
      Enum.each(1..10, fn n ->
        {:ok, closed} =
          Ash.update(
            backlog_issue(ws, "history #{n}", %{difficulty: 2, issue_type: :feature}),
            %{close_upstream: false},
            action: :close
          )

        spend!(closed.id, ws, n * 1.0)
      end)

      :ok
    end

    test "a Ready card past p90 flags; one inside its range does not",
         %{conn: conn, ws: ws} do
      over = issue(ws, "runaway", %{difficulty: 2, issue_type: :feature})
      fine = issue(ws, "ordinary", %{difficulty: 2, issue_type: :feature})
      spend!(over.id, ws, 40.0)
      spend!(fine.id, ws, 4.0)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{over.id}"] [data-over-budget]))
      refute has_element?(view, ~s([id="card-#{fine.id}"] [data-over-budget]))
    end

    test "a closed card never flags, however far over it ran", %{conn: conn, ws: ws} do
      task = backlog_issue(ws, "ran over, then landed", %{difficulty: 2, issue_type: :feature})
      spend!(task.id, ws, 40.0)
      {:ok, closed} = Ash.update(task, %{close_upstream: false}, action: :close)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s([id="card-#{closed.id}"]))
      refute has_element?(view, ~s([id="card-#{closed.id}"] [data-over-budget]))
    end
  end

  # bd-15bn6s: the snapshot is a 280–400ms read, and this is the landing page.
  # It runs in `start_async/3` on the connected mount only — the dead render
  # reads nothing and draws a skeleton board — and every later refresh goes
  # the same way, so a slow read can never hold the LiveView process.
  describe "the async load" do
    setup do
      :meck.new(Snapshot, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Snapshot) end)
      :ok
    end

    # Redirects the board's `Snapshot.load/1` to `fun`. The autopilot reads the
    # same function from its own (VM-wide) process; that read passes through.
    defp on_board_load(fun) do
      autopilot = Process.whereis(Autopilot)

      :meck.expect(Snapshot, :load, fn opts ->
        if self() == autopilot, do: :meck.passthrough([opts]), else: fun.(opts)
      end)
    end

    # Holds each board read in its loader until the test says go, so the
    # loading state is something to assert on rather than a race. A read no
    # test released gives up well inside @async_timeout and reports itself,
    # so the test fails on `refute_held_load/0`, not on a render_async timeout.
    defp hold_board_load do
      test = self()

      on_board_load(fn opts ->
        board = :meck.passthrough([opts])
        send(test, {:loading_board, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_board_load, self()})
        end

        board
      end)
    end

    # The LiveView has handled everything sent to it before this returns.
    defp settle(view), do: :sys.get_state(view.pid)

    defp refute_held_load, do: refute_received({:unreleased_board_load, _})

    test "the dead render shows the loading state and reads nothing", %{conn: conn} do
      test = self()

      on_board_load(fn opts ->
        send(test, :board_read)
        :meck.passthrough([opts])
      end)

      doc = conn |> get(~p"/") |> html_response(200) |> LazyHTML.from_document()

      assert doc |> LazyHTML.query(~s(#board[data-state="loading"])) |> Enum.count() == 1
      assert doc |> LazyHTML.query("#board-loading") |> Enum.count() == 1
      refute_received :board_read
    end

    test "renders a skeleton board, then the snapshot", %{conn: conn, ws: ws} do
      task = issue(ws, "arrives with the snapshot")
      hold_board_load()

      {:ok, view, _html} = live(conn, "/")
      assert_receive {:loading_board, loader}

      assert has_element?(view, ~s(#board[data-state="loading"]))
      assert has_element?(view, "#board-loading")
      refute has_element?(view, "#card-#{task.id}")
      refute has_element?(view, "#board-backlog-empty")

      send(loader, :release)
      render_async(view, @async_timeout)

      assert has_element?(view, ~s(#board[data-state="loaded"]))
      refute has_element?(view, "#board-loading")
      assert has_element?(view, "#card-#{task.id}")
      refute_held_load()
    end

    @tag :capture_log
    test "a failed load renders an inline error, and Retry recovers", %{conn: conn, ws: ws} do
      task = issue(ws, "behind the error")
      on_board_load(fn _opts -> raise "database is locked" end)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_timeout)

      assert has_element?(view, ~s(#board[data-state="error"]))
      assert has_element?(view, "#board-error", "database is locked")
      refute has_element?(view, "#board-loading")

      on_board_load(&:meck.passthrough([&1]))
      view |> element("#board-retry") |> render_click()
      render_async(view, @async_timeout)

      refute has_element?(view, "#board-error")
      assert has_element?(view, ~s(#board[data-state="loaded"]))
      assert has_element?(view, "#card-#{task.id}")
    end

    @tag :capture_log
    test "a refresh that fails keeps the last board on screen and says so", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "was on the board")

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_timeout)
      assert has_element?(view, "#card-#{task.id}")

      on_board_load(fn _opts -> raise "database is locked" end)
      send(view.pid, {:worker_lifecycle, :started, %{}})
      settle(view)
      render_async(view, @async_timeout)

      assert has_element?(view, "#board-error", "database is locked")
      assert has_element?(view, "#card-#{task.id}")
    end

    test "a lifecycle broadcast still refreshes the board", %{conn: conn, ws: ws} do
      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_timeout)

      task = issue(ws, "created after the mount")
      Phoenix.PubSub.broadcast(Arbiter.PubSub, "workers", {:worker_lifecycle, :started, %{}})
      settle(view)
      render_async(view, @async_timeout)

      assert has_element?(view, "#card-#{task.id}")
    end

    # A tab closed mid-load must not kill its read mid-query: a DB client that
    # dies holding a checkout costs the pool that connection (and, under test,
    # the one shared sandbox connection — bd-5scl0c). The read finishes, and
    # only then does the task go.
    test "a board that goes away mid-load lets its read finish", %{conn: conn} do
      hold_board_load()
      Process.flag(:trap_exit, true)

      {:ok, view, _html} = live(conn, "/")
      assert_receive {:loading_board, loader}
      loader_ref = Process.monitor(loader)
      view_ref = Process.monitor(view.pid)

      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^view_ref, :process, _pid, :killed}
      refute_receive {:DOWN, ^loader_ref, :process, _pid, _reason}, 100

      send(loader, :release)
      assert_receive {:DOWN, ^loader_ref, :process, _pid, :shutdown}, @async_timeout
      refute_held_load()
    end

    # bd-81vbzg's concern from the other side: a burst of broadcasts during a
    # slow read is one more read, not one each — and the LiveView answers
    # while the read is out.
    test "broadcasts during a refresh coalesce into one more read", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_timeout)

      hold_board_load()
      send(view.pid, {:worker_lifecycle, :started, %{}})
      assert_receive {:loading_board, first}

      for _ <- 1..5, do: send(view.pid, {:task_lifecycle, :updated, %{}})
      settle(view)
      assert has_element?(view, ~s(#board[data-state="loaded"]))

      send(first, :release)
      assert_receive {:loading_board, second}
      send(second, :release)
      render_async(view, @async_timeout)

      refute_receive {:loading_board, _}, 200
      refute_held_load()
    end
  end

  defp spend!(task_id, ws, cost) do
    {:ok, ev} =
      Ash.create(Arbiter.Usage.Event, %{
        task_id: task_id,
        base_task_id: task_id,
        source: :task,
        step: :work,
        role: "base",
        workspace_id: ws.id,
        occurred_at: DateTime.utc_now(),
        cost_usd: cost
      })

    ev
  end
end
