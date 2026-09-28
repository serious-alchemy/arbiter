defmodule ArbiterWeb.MergeQueueIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}

  # The Merging tickets, workspace/queue-position reads and the landed query
  # all arrive by `start_async/3` on the connected mount (bd-aebiwf); every
  # test but the loading/error ones themselves wants the page once it has
  # landed.
  @async_timeout 5_000

  defp live_merge_queue(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "cr-#{System.unique_integer([:positive])}", prefix: "crx"})

    {:ok, ws: ws}
  end

  # bd-741sid: an open PR belongs to its ticket — Merging, with the PR and the
  # forge's last answer on the row — not to a worker parked on it.
  defp merging_ticket(ws, title, merger_status \\ nil) do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    {:ok, _} = Ash.update(task, %{status: :in_progress})
    {:ok, task} = Issue.pr_opened(task.id, "!77", merger_url: "https://example.test/mr/77")

    if merger_status, do: :ok = PullRequest.record_merger_status(task.id, merger_status)

    task
  end

  defp landed_ticket(ws, title) do
    task = merging_ticket(ws, title)
    Ash.update!(Ash.get!(Issue, task.id), %{}, action: :close)
  end

  describe "Queued tab" do
    test "empty state when nothing is integrating", %{conn: conn} do
      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")
      assert html =~ ~s(id="merge_queue-empty")
      assert html =~ "integrating right now"
    end

    test "row anatomy: position, id, title, PR link, check dots, time-in-queue",
         %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "merging-now")

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")

      assert html =~ ~s(id="merge_queue")
      # position badge
      assert html =~ "#1"
      assert html =~ task.id
      assert html =~ "merging-now"
      assert html =~ "!77"
      assert html =~ "https://example.test/mr/77"
      assert html =~ ~s(href="/workers/#{task.id}")
      assert html =~ "in queue"
      # check dots — three checks (CI / Approval / Mergeable) rendered as dots
      assert html =~ "title=\"CI\""
      assert html =~ "title=\"Approval\""
      assert html =~ "title=\"Mergeable\""
    end

    test "a ticket that is not Merging is not in the queue", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "still-working", workspace_id: ws.id})
      {:ok, _} = Ash.update(task, %{status: :in_progress})

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")

      assert html =~ ~s(id="merge_queue-empty")
      refute html =~ "still-working"
    end

    test "Queued tab is the default and shows in the tab bar with a live count",
         %{conn: conn, ws: ws} do
      merging_ticket(ws, "merging-now")

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")
      assert html =~ "Queued"
      assert html =~ "Landed today"
      assert html =~ "Rejected"
    end

    test "a draft PR lights the Mergeable dot red, not green", %{conn: conn, ws: ws} do
      merging_ticket(ws, "draft-pr", %{pipeline: :success, approved: true, block_reason: :draft})

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")

      [_, mergeable_dot] =
        Regex.run(~r/<span[^>]*title="Mergeable"[^>]*class="([^"]*)"/, html) ||
          Regex.run(~r/class="([^"]*)"[^>]*title="Mergeable"/, html)

      assert mergeable_dot =~ "bg-error"
    end

    test "an unknown/not-yet-started CI signal renders as unknown, not passed",
         %{conn: conn, ws: ws} do
      merging_ticket(ws, "no-ci-yet", %{pipeline: :not_started, approved: false})

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")

      [_, ci_dot] =
        Regex.run(~r/class="([^"]*)"[^>]*title="CI"/, html) ||
          Regex.run(~r/<span[^>]*title="CI"[^>]*class="([^"]*)"/, html)

      refute ci_dot =~ "bg-success"
      assert ci_dot =~ "bg-base-300"
    end

    test "the header count and subtitle describe the active tab, not always Queued",
         %{conn: conn, ws: ws} do
      merging_ticket(ws, "merging-now")
      landed_ticket(ws, "shipped")

      {:ok, _view, queued_html} = live_merge_queue(conn, ~p"/merge_queue")
      assert queued_html =~ "integrating now, longest-waiting first"

      {:ok, _view, landed_html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")
      refute landed_html =~ "integrating now, longest-waiting first"
      assert landed_html =~ "merged since midnight UTC"

      {:ok, _view, rejected_html} = live_merge_queue(conn, ~p"/merge_queue?tab=rejected")
      refute rejected_html =~ "integrating now, longest-waiting first"
      assert rejected_html =~ "reopen their task instead of collecting here"
    end
  end

  describe "Landed today tab" do
    test "shows a 3-col grid of muted TaskCards for tickets whose PR merged today",
         %{conn: conn, ws: ws} do
      task = landed_ticket(ws, "shipped-thing")

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")

      assert html =~ ~s(id="merge_queue-landed")
      assert html =~ "grid-cols-1"
      assert html =~ "lg:grid-cols-3"
      assert html =~ task.id
      assert html =~ "shipped-thing"
      assert html =~ "UTC"
      refute html =~ ~s(id="merge_queue-landed-empty")
    end

    # bd-741sid: the run that opens a PR completes when the PR opens, so a
    # completed run with a PR on it is not a merge — the ticket says when.
    test "a PR that is open, not merged, has not landed", %{conn: conn, ws: ws} do
      merging_ticket(ws, "opened-not-merged")

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")

      assert html =~ ~s(id="merge_queue-landed-empty")
      refute html =~ "opened-not-merged"
    end

    test "a merged ticket waiting on its post-merge check has landed", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "verifying-thing")
      Ash.update!(Ash.get!(Issue, task.id), %{}, action: :await_verification)

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")

      assert html =~ task.id
      assert html =~ "verifying-thing"
    end

    test "a ticket closed without its PR merging has not landed", %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "wont-do")
      Ash.update!(Ash.get!(Issue, task.id), %{close_reason: :wont_do}, action: :close)

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")

      assert html =~ ~s(id="merge_queue-landed-empty")
      refute html =~ "wont-do"
    end

    test "empty state when nothing landed today", %{conn: conn} do
      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")
      assert html =~ ~s(id="merge_queue-landed-empty")
      assert html =~ "landed today"
    end

    test "a ticket merged before today does not show up", %{conn: conn, ws: ws} do
      task = landed_ticket(ws, "old-news")
      two_days_ago = DateTime.add(DateTime.utc_now(), -172_000, :second)

      Arbiter.Repo.update_all(
        from(i in "issues", where: i.id == ^task.id),
        set: [closed_at: two_days_ago]
      )

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")
      assert html =~ ~s(id="merge_queue-landed-empty")
      refute html =~ "old-news"
    end
  end

  describe "Rejected tab" do
    test "always shows the empty state explaining a rejected merge reopens its task",
         %{conn: conn} do
      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=rejected")

      assert html =~ ~s(id="merge_queue-rejected-empty")
      assert html =~ "don&#39;t collect here"
      assert html =~ "reopens its task"
    end
  end

  describe "async mount" do
    # Holds the Merging-ticket read (`PullRequest.merging_tickets/0`) in
    # flight until the test says go, so the loading state is something to
    # assert on rather than a race — same discipline as
    # `worker_index_live_test.exs`'s `hold_workers_load/0` (bd-4gtia5).
    defp hold_merge_queue_load do
      test = self()

      :meck.new(PullRequest, [:passthrough, :no_link])

      :meck.expect(PullRequest, :merging_tickets, fn ->
        tickets = :meck.passthrough([])
        send(test, {:loading_merge_queue, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_merge_queue_load, self()})
        end

        tickets
      end)

      on_exit(fn -> :meck.unload(PullRequest) end)
    end

    test "the dead render shows the loading state and does not read the queue",
         %{conn: conn} do
      test = self()
      :meck.new(PullRequest, [:passthrough, :no_link])
      :meck.expect(PullRequest, :merging_tickets, fn -> send(test, :queue_read) && [] end)
      on_exit(fn -> :meck.unload(PullRequest) end)

      doc = conn |> get(~p"/merge_queue") |> html_response(200) |> LazyHTML.from_document()

      assert doc
             |> LazyHTML.query(~s(#merge_queue-panel[data-state="loading"]))
             |> Enum.count() == 1

      assert doc |> LazyHTML.query("#merge_queue-loading") |> Enum.count() == 1
      refute_received :queue_read
    end

    test "renders a loading skeleton before the async load lands, then the data",
         %{conn: conn, ws: ws} do
      task = merging_ticket(ws, "async-loading")

      hold_merge_queue_load()

      {:ok, view, _html} = live(conn, ~p"/merge_queue")
      assert_receive {:loading_merge_queue, loader}

      assert has_element?(view, ~s(#merge_queue-panel[data-state="loading"]))
      assert has_element?(view, "#merge_queue-loading")
      refute has_element?(view, "#merge_queue")

      send(loader, :release)
      html = render_async(view, @async_timeout)

      assert has_element?(view, ~s(#merge_queue-panel[data-state="loaded"]))
      refute has_element?(view, "#merge_queue-loading")
      assert html =~ task.id
      refute_received {:unreleased_merge_queue_load, _}
    end

    test "an async merge-queue-load failure renders an inline error, not a crash",
         %{conn: conn} do
      # An `:exit` from the read lands in
      # `handle_async(:merge_queue, {:exit, _}, socket)`.
      :meck.new(PullRequest, [:passthrough, :no_link])
      :meck.expect(PullRequest, :merging_tickets, fn -> exit(:boom) end)
      on_exit(fn -> :meck.unload(PullRequest) end)

      {:ok, view, _html} = live(conn, ~p"/merge_queue")
      html = render_async(view, @async_timeout)

      assert html =~ ~s(id="merge_queue-error")
      assert has_element?(view, "#merge_queue-retry")
    end

    test "a ticket going Merging while the page is open refreshes the queued tab",
         %{conn: conn, ws: ws} do
      {:ok, view, html} = live_merge_queue(conn, ~p"/merge_queue")
      refute html =~ "broadcast-refresh"

      merging_ticket(ws, "broadcast-refresh")

      html = render_async(view, @async_timeout)

      assert html =~ "broadcast-refresh"
    end

    test "navigating to a new page while a load is in flight keeps the requested page",
         %{conn: conn, ws: ws} do
      for i <- 1..25 do
        landed_ticket(ws, "landed-#{String.pad_leading(to_string(i), 2, "0")}")
      end

      hold_merge_queue_load()

      {:ok, view, _html} = live(conn, ~p"/merge_queue?tab=landed")
      assert_receive {:loading_merge_queue, loader1}

      # The in-flight load was fetched for page 1; ask for page 2 before it lands.
      render_patch(view, ~p"/merge_queue?tab=landed&page=2")

      send(loader1, :release)

      # The stale page-1 result must not clobber the page-2 request: a
      # refetch for page 2 follows immediately.
      assert_receive {:loading_merge_queue, loader2}
      send(loader2, :release)

      html = render_async(view, @async_timeout)

      assert html =~ "2 / 2"
      assert html =~ "landed-01"
      refute html =~ "landed-25"
      refute_received {:unreleased_merge_queue_load, _}
    end

    test "switching tabs while a load is in flight shows the loading state, not the old tab's data",
         %{conn: conn, ws: ws} do
      merging_ticket(ws, "queued-thing")
      landed_ticket(ws, "landed-thing")

      hold_merge_queue_load()

      {:ok, view, _html} = live(conn, ~p"/merge_queue")
      assert_receive {:loading_merge_queue, loader1}

      render_patch(view, ~p"/merge_queue?tab=landed")

      # Switching tabs must not leave the still-in-flight queued-tab load
      # marked as "loaded" once it lands — the skeleton should still show.
      assert has_element?(view, ~s(#merge_queue-panel[data-state="loading"]))
      refute has_element?(view, "#merge_queue-landed-empty")

      send(loader1, :release)
      assert_receive {:loading_merge_queue, loader2}

      # The queued-tab result landed but is now stale; still loading, still
      # not showing the landed tab's empty state from mismatched data.
      assert has_element?(view, ~s(#merge_queue-panel[data-state="loading"]))
      refute has_element?(view, "#merge_queue-landed-empty")

      send(loader2, :release)
      html = render_async(view, @async_timeout)

      assert has_element?(view, ~s(#merge_queue-panel[data-state="loaded"]))
      assert html =~ "landed-thing"
      refute_received {:unreleased_merge_queue_load, _}
    end
  end
end
