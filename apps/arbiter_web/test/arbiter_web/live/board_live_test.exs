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

  # bd-b5wyjd: a freshly created issue is `:backlog`. Almost every test here is
  # about a card that has already been promoted into the queue, so this helper
  # promotes; `backlog_issue/3` is the un-promoted one.
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

  # `:state` is not a create input — a task becomes `:active` by being
  # started, which is exactly the state these drags start from.
  defp working_issue(ws, title) do
    {:ok, issue} = Ash.update(issue(ws, title), %{}, action: :start)
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

  describe "paused providers (bd-5ef587)" do
    test "a banner chip appears once a provider is paused and clears on resume", %{conn: conn} do
      {:ok, view, _html} = live_board(conn)
      refute has_element?(view, "#board-paused-providers")

      {:ok, _} = Arbiter.Providers.Pause.pause("codex", reason: "jail escape", by: "test")
      render_async(view, @async_timeout)
      assert has_element?(view, "#board-paused-providers")

      {:ok, _} = Arbiter.Providers.Pause.resume("codex", by: "test")
      render_async(view, @async_timeout)
      refute has_element?(view, "#board-paused-providers")
    end
  end

  describe "local cap 0 (RW8)" do
    setup do
      on_exit(fn -> Arbiter.Settings.set_nodes_local_max_workers(nil) end)
      :ok
    end

    test "a persistent chip shows while the primary's cap is 0 and clears when it rises",
         %{conn: conn} do
      {:ok, view, _html} = live_board(conn)
      refute has_element?(view, "#board-local-cap-zero")

      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)
      render_async(view, @async_timeout)
      assert has_element?(view, "#board-local-cap-zero")

      {:ok, 2} = Arbiter.Nodes.set_local_max_workers(2, nil)
      render_async(view, @async_timeout)
      refute has_element?(view, "#board-local-cap-zero")
    end
  end

  describe "columns" do
    test "renders the seven lifecycle columns", %{conn: conn} do
      {:ok, view, html} = live_board(conn)

      for label <- ~w(Backlog Blocked Ready Merging Verifying) do
        assert html =~ label
      end

      assert html =~ "In progress"
      assert html =~ "Closed · last 24h"

      for key <- ~w(backlog blocked ready in_progress merging verifying closed) do
        assert has_element?(view, "#board-column-#{key}")
      end

      # bd-79w1fs: the interim five columns are gone, not renamed alongside.
      refute has_element?(view, "#board-column-running")
      refute has_element?(view, "#board-column-waiting")
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

    # bd-crk6tb: a review engagement (`review_only == true and source_pr` set) is
    # long-lived review babysitting, not work on the board — it lives on /reviews.
    # Neither half alone makes one, so the two look-alikes must still render.
    test "a review engagement is not a card, but its look-alikes are", %{conn: conn, ws: ws} do
      engagement =
        issue(ws, "Review engagement: 7", %{
          tracker_type: :none,
          review_only: true,
          source_pr: "7"
        })

      worker_review = issue(ws, "worker review pass", %{review_only: true})
      follow_up = issue(ws, "author follow-up", %{tracker_type: :none, source_pr: "8"})

      {:ok, view, _html} = live_board(conn)

      refute has_element?(view, ~s([id="card-#{engagement.id}"]))
      assert has_element?(view, ~s(#board-column-ready [id="card-#{worker_review.id}"]))
      assert has_element?(view, ~s(#board-column-ready [id="card-#{follow_up.id}"]))
    end

    test "a closed engagement does not reach the Closed column either", %{conn: conn, ws: ws} do
      engagement =
        issue(ws, "Review engagement: 9", %{
          tracker_type: :none,
          review_only: true,
          source_pr: "9"
        })

      {:ok, _} = Ash.update(engagement, %{}, action: :close)

      {:ok, view, _html} = live_board(conn)

      refute has_element?(view, ~s([id="card-#{engagement.id}"]))
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
               ~s(div[id="card-#{task.id}"] button[type="button"][aria-label="Copy ticket id #{task.id}"])
             )

      refute has_element?(
               view,
               ~s(div[id="card-#{task.id}"] a button[type="button"][aria-label="Copy ticket id #{task.id}"])
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

    test "In progress card body navigates to the task page, not the worker page", %{
      conn: conn,
      ws: ws
    } do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
      refute card_navigates_to?(view, task.id, "/workers/#{task.id}")
    end

    test "Merging card body navigates to the task page, not the worker page", %{
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

  describe "In progress column: the activity line links to the worker" do
    test "the activity line is a link to the worker page", %{conn: conn, ws: ws} do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(#board-column-in_progress [id="card-#{task.id}"] a[href="/workers/#{task.id}"])
             )
    end
  end

  describe "the activity line keeps its contextual destination" do
    test "a Verifying card goes to the task page, where the evidence is recorded", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "doctor probe")
      {:ok, task} = Ash.update(task, %{}, action: :await_verification)

      {:ok, view, _html} = live_board(conn)

      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
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

    test "an In progress card with no run has no worker to link to", %{conn: conn, ws: ws} do
      task = working_issue(ws, "dispatching, no run yet")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-in_progress [id="card-#{task.id}"]))
      refute has_element?(view, ~s([id="card-#{task.id}"] a[href="/workers/#{task.id}"]))
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

    test "Backlog is in priority order, then rank", %{conn: conn, ws: ws} do
      first = backlog_issue(ws, "thought one", %{priority: 3})
      second = backlog_issue(ws, "thought two", %{priority: 1})
      third = backlog_issue(ws, "thought three", %{priority: 3})

      {:ok, _view, html} = live_board(conn)

      assert board_position(html, second.id) < board_position(html, first.id)
      assert board_position(html, first.id) < board_position(html, third.id)
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

  describe "the quota hold reason names the account (bd-1qjv3j)" do
    test "a Ready card says which account is held, in percentages", %{conn: conn, ws: ws} do
      issue(ws, "held for quota")

      {:ok, account_id} = Arbiter.Quota.ensure_account_id(ws.id, "claude")
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Ash.create!(Arbiter.Quota.AnthropicQuota, %{
        provider_account_id: account_id,
        provider: "claude",
        utilization_5h: 0.1,
        status_5h: "allowed",
        reset_5h_at: DateTime.add(now, 3600, :second),
        utilization_7d: 0.95,
        status_7d: "allowed",
        reset_7d_at: DateTime.add(now, 3 * 86_400, :second),
        captured_at: now
      })

      slug = Arbiter.Accounts.Resolver.get(account_id).slug
      {:ok, _view, html} = live_board(conn)

      assert html =~ "held — claude:#{slug} 7d 95% ≥ 90%"
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
      assert reloaded.state == :backlog

      assert has_element?(view, ~s(#board-column-backlog [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
    end
  end

  describe "drag is a human action, and In progress is not one of its targets" do
    test "dragging a card INTO In progress is refused with an explanation", %{conn: conn, ws: ws} do
      task = issue(ws, "impatient")

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "ready", "in_progress")

      assert html =~ "scheduler"
      # The card did not move. Whether it dispatches is the scheduler's call,
      # and it makes it from Ready.
      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      refute has_element?(view, ~s(#board-column-in_progress [id="card-#{task.id}"]))
    end
  end

  # bd-79w1fs: pulling a card out of In progress used to offer to stop its
  # worker. Every cross-column drag but promote / demote is now refused: a
  # live agent is stopped from its worker page, deliberately.
  describe "dragging work out of In progress" do
    test "is refused, and the worker keeps running", %{conn: conn, ws: ws} do
      task = issue(ws, "in flight")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "in_progress", "ready")

      assert html =~ "cannot be dragged"
      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
      assert has_element?(view, ~s(#board-column-in_progress [id="card-#{task.id}"]))
    end

    test "putting a card back down where it was says nothing", %{conn: conn, ws: ws} do
      task = issue(ws, "picked up, thought better of it")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "in_progress", "in_progress")

      refute html =~ "cannot be dragged"
      assert Enum.any?(Worker.list_children(), &(&1.task_id == task.id))
    end
  end

  describe "In progress column rendering" do
    test "displays difficulty on running cards", %{conn: conn, ws: ws} do
      task = issue(ws, "work with difficulty", %{difficulty: 2})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(
               view,
               ~s(#board-column-in_progress [id="card-#{task.id}"] [aria-label="Difficulty D2"])
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
               ~s(#board-column-in_progress [id="card-#{task.id}"] [aria-label="Codex"])
             )
    end

    test "a remote run's card carries a node badge naming the node", %{conn: conn, ws: ws} do
      node = enroll_node!("gpu-box")
      task = issue(ws, "work on a node")
      {:ok, pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)
      :ok = Worker.report(pid, :node_id, node.id)

      {:ok, view, _html} = live_board(conn)

      badge = ~s(#board-column-in_progress [id="card-#{task.id}"] [data-node-badge="gpu-box"])
      assert has_element?(view, ~s(#board-column-in_progress [id="card-#{task.id}"]))
      assert has_element?(view, badge)
      assert has_element?(view, ~s(#{badge}[title="Runs on node gpu-box"]))
    end

    # bd-b2iigy: a resume the scheduler holds for the primary's own worker cap.
    test "an In-progress card whose resume is held for local capacity says so",
         %{conn: conn, ws: ws} do
      # Cap 0 keeps the (resumed, shared) autopilot from replaying it mid-test.
      {:ok, 0} = Arbiter.Nodes.set_local_max_workers(0, nil)

      on_exit(fn ->
        Arbiter.Settings.set_nodes_local_max_workers(nil)
      end)

      task = issue(ws, "cut off by a restart")
      {:ok, task} = Issue.start_work(task)

      :ok = Autopilot.defer_resume(Autopilot, task.id, :resume, held_for: :local_capacity)
      on_exit(fn -> Autopilot.cancel_deferred(Autopilot, task.id) end)

      {:ok, view, _html} = live_board(conn)

      card = ~s(#board-column-in_progress [id="card-#{task.id}"])
      assert has_element?(view, card)
      assert has_element?(view, ~s(#{card} [data-detail="in_progress"]), "held: local capacity")

      :ok = Autopilot.cancel_deferred(Autopilot, task.id)
      {:ok, view, _html} = live_board(conn)
      refute has_element?(view, ~s(#{card} [data-detail="in_progress"]), "held: local capacity")
    end

    test "a local run's card has no node badge", %{conn: conn, ws: ws} do
      task = issue(ws, "work on the primary")
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "r", workspace_id: ws.id)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-in_progress [id="card-#{task.id}"]))
      refute has_element?(view, "[data-node-badge]")
    end

    defp enroll_node!(name) do
      Ash.create!(
        Arbiter.Nodes.Node,
        %{
          name: name,
          credential_hash: "h-#{System.unique_integer([:positive])}",
          credential_prefix: "p",
          enrolled_at: DateTime.utc_now()
        },
        action: :enroll
      )
    end
  end

  # bd-79w1fs: what used to share the Waiting column now sits in its own
  # lifecycle column — a parked run in In progress, an open PR in Merging —
  # and what needs someone is the card's attention marker, not a column.
  describe "In progress and Merging cards out of the worker's hands" do
    # bd-8jixav: the Watchdog is a :temporary process, so a crash leaves the
    # ticket Merging on an open MR nothing polls.
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

    test "a card whose watchdog died says so, as the coordinator's", %{conn: conn, ws: ws} do
      dead = working_issue(ws, "nobody is watching this")
      open_pr_without_watchdog(ws, dead)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-merging [id="card-#{dead.id}"]))

      assert has_element?(
               view,
               ~s([id="card-#{dead.id}"] [data-attention="coordinator"]),
               "no Watchdog is polling its PR"
             )

      # The restart lives on the worker page, not in the merge queue.
      assert has_element?(view, ~s([id="card-#{dead.id}"] a[href="/workers/#{dead.id}"]))
    end

    test "a card with a live watchdog says nothing about one", %{conn: conn, ws: ws} do
      polling = working_issue(ws, "still in review")
      open_pr(ws, polling)

      {:ok, view, html} = live_board(conn)

      refute html =~ "no Watchdog"
      refute has_element?(view, ~s([id="card-#{polling.id}"] [data-attention]))
    end

    test "a Merging ticket with a failed pass under it renders one card, not two", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "one card please")
      open_pr(ws, task)

      {:ok, fixpass} =
        Worker.start(
          task_id: task.id,
          repo: "r",
          workspace_id: ws.id,
          meta: %{role: :fix_pass}
        )

      :ok = Worker.fail(fixpass, "fix pass blew up")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-merging [id="card-#{task.id}"]))

      assert view
             |> render()
             |> then(&Regex.scan(~r/id="card-#{task.id}"/, &1))
             |> length() == 1

      assert has_element?(view, ~s([id="card-#{task.id}"]), "fix pass failed")
    end

    test "a parked run stays In progress; an open PR is Merging", %{conn: conn, ws: ws} do
      parked = working_issue(ws, "answer me")
      parked_worker(ws, parked)

      merging = working_issue(ws, "land it later")
      open_pr(ws, merging)

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-in_progress [id="card-#{parked.id}"]))
      assert has_element?(view, ~s(#board-column-merging [id="card-#{merging.id}"]))
    end

    # bd-8if9zt: the coordinator comes first, so a parked run or a conflict is
    # its to act on; only what the fleet cannot do itself — an approval on its
    # own PR — is the operator's.
    test "the marker names the owner: the operator only for what the fleet cannot do", %{
      conn: conn,
      ws: ws
    } do
      parked = working_issue(ws, "answer me")
      parked_worker(ws, parked)

      approval = working_issue(ws, "needs a human approval")
      open_pr(ws, approval)

      :ok =
        PullRequest.record_merger_status(approval.id, %{
          status: :open,
          approved: true,
          block_reason: :needs_approval
        })

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

      assert has_element?(view, ~s([id="card-#{approval.id}"] [data-attention="operator"]))
      assert has_element?(view, ~s([id="card-#{parked.id}"] [data-attention="coordinator"]))
      assert has_element?(view, ~s([id="card-#{stuck.id}"] [data-attention="coordinator"]))
      refute has_element?(view, ~s([id="card-#{polling.id}"] [data-attention]))
    end

    test "dragging a Merging card anywhere is refused, and its PR is left alone", %{
      conn: conn,
      ws: ws
    } do
      task = working_issue(ws, "merge me")
      open_pr(ws, task)

      {:ok, view, _html} = live_board(conn)

      for to <- ~w(ready in_progress closed) do
        assert drag(view, task.id, "merging", to) =~ "cannot be dragged"
      end

      assert Ash.get!(Issue, task.id).state == :merging
      assert Watchdog.alive?(task.id)
    end

    test "a Merging card's detail is its computed step", %{conn: conn, ws: ws} do
      queued = working_issue(ws, "in the queue")
      open_pr(ws, queued)

      ci = working_issue(ws, "ci running")
      open_pr(ws, ci)
      :ok = PullRequest.record_merger_status(ci.id, %{status: :open, pipeline: :running})

      behind = working_issue(ws, "behind base")
      open_pr(ws, behind)

      :ok =
        PullRequest.record_merger_status(behind.id, %{
          status: :open,
          approved: true,
          block_reason: :behind_base
        })

      conflict = working_issue(ws, "conflict")
      open_pr(ws, conflict)

      :ok =
        PullRequest.record_merger_status(conflict.id, %{
          status: :open,
          approved: true,
          block_reason: :conflict
        })

      {:ok, view, _html} = live_board(conn)

      for {task, step, label} <- [
            {queued, "in_merge_queue", "in merge queue"},
            {ci, "waiting_ci", "waiting on CI"},
            {behind, "behind_base", "behind base"},
            {conflict, "merge_blocked", "merge blocked"}
          ] do
        assert has_element?(view, ~s([id="card-#{task.id}"] [data-step="#{step}"]), label)
      end
    end
  end

  # bd-9so315 — a merged-but-unverified task has no worker, so without its own
  # card it would be invisible on the board: exactly the gap the state exists
  # to close.
  describe "the Verifying column lists tasks awaiting verification" do
    defp awaiting_issue(ws, title) do
      task = working_issue(ws, title)
      {:ok, awaiting} = Ash.update(task, %{}, action: :await_verification)
      awaiting
    end

    test "a parked task renders a Verifying card", %{conn: conn, ws: ws} do
      task = awaiting_issue(ws, "doctor probe")

      {:ok, view, _html} = live_board(conn)

      assert has_element?(view, ~s(#board-column-verifying [id="card-#{task.id}"]))
      assert has_element?(view, ~s([id="card-#{task.id}"]), "awaiting verification")
      # The restart-and-observe is the coordinator's (bd-8if9zt).
      assert has_element?(view, ~s([id="card-#{task.id}"] [data-attention="coordinator"]))
      # It routes to the task, where the verification evidence lives.
      assert card_navigates_to?(view, task.id, "/tasks/#{task.id}")
    end

    test "dragging it out is refused", %{conn: conn, ws: ws} do
      task = awaiting_issue(ws, "capture path")

      {:ok, view, _html} = live_board(conn)

      html = drag(view, task.id, "verifying", "closed")
      assert html =~ "cannot be dragged"

      # And the task did not move.
      assert Ash.get!(Issue, task.id).state == :verifying
    end
  end

  describe "drops onto Closed" do
    test "dropping onto Closed today is refused and changes nothing", %{conn: conn, ws: ws} do
      task = issue(ws, "not done yet")

      {:ok, view, _html} = live_board(conn)

      assert drag(view, task.id, "ready", "closed") =~ "cannot be dragged"

      assert has_element?(view, ~s(#board-column-ready [id="card-#{task.id}"]))
      assert Ash.get!(Issue, task.id).state == :queued
    end
  end

  describe "the scheduler switch" do
    test "pausing is visible on every Ready card", %{conn: conn, ws: ws} do
      issue(ws, "would have gone next")

      {:ok, view, _html} = live_board(conn)

      view |> element(~s(button[phx-click="toggle_scheduler"])) |> render_click()

      assert render_async(view, @async_timeout) =~ "scheduler paused"
    end

    test "pausing asks for confirmation; resuming does not", %{conn: conn} do
      :ok = Autopilot.resume()
      {:ok, view, _html} = live_board(conn)
      render_async(view, @async_timeout)

      assert has_element?(view, "#board-scheduler-toggle[data-confirm]")

      view |> element("#board-scheduler-toggle") |> render_click()
      render_async(view, @async_timeout)

      refute has_element?(view, "#board-scheduler-toggle[data-confirm]")

      assert [%{paused: true, actor: "operator:test", surface: "dashboard"} | _] =
               Arbiter.Settings.scheduler_changes()
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

    test "columns fill the full width on 2xl breakpoint and above", %{conn: conn, ws: ws} do
      issue(ws, "test issue")
      {:ok, _view, html} = live_board(conn)

      # Seven columns need the room: the board-columns container switches from
      # a horizontal scroller to a seven-track grid at 2xl.
      assert html =~ "2xl:grid 2xl:grid-cols-[repeat(7,minmax(16rem,1fr))]"

      # Each column must have 2xl:w-auto so grid tracks stretch to fill width
      assert html =~ "2xl:w-auto"
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

    # bd-81vbzg: worker lifecycle broadcasts are trailing-debounced. The test
    # config sets the window to 0 (refresh immediately); this one widens it.
    test "a burst of worker lifecycle broadcasts is one refresh, after the window", %{
      conn: conn,
      ws: ws
    } do
      previous = Application.get_env(:arbiter_web, :board_worker_debounce_ms)
      Application.put_env(:arbiter_web, :board_worker_debounce_ms, 300)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter_web, :board_worker_debounce_ms, previous),
          else: Application.delete_env(:arbiter_web, :board_worker_debounce_ms)
      end)

      {:ok, view, _html} = live(conn, "/")
      render_async(view, @async_timeout)

      test = self()

      on_board_load(fn opts ->
        send(test, :board_read)
        :meck.passthrough([opts])
      end)

      for _ <- 1..10 do
        Phoenix.PubSub.broadcast(Arbiter.PubSub, "workers", {:worker_lifecycle, :updated, %{}})
      end

      settle(view)
      refute_received :board_read

      assert_receive :board_read, 2_000
      render_async(view, @async_timeout)
      refute_receive :board_read, 400
      assert has_element?(view, ~s(#board[data-state="loaded"]))

      # A task event is not debounced, and the board still reflects it.
      task = issue(ws, "created after the burst")
      assert_receive :board_read, 2_000
      render_async(view, @async_timeout)
      assert has_element?(view, "#card-#{task.id}")
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
