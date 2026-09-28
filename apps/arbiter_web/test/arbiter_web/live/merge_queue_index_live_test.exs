defmodule ArbiterWeb.MergeQueueIndexLiveTest.QueueMerger do
  @moduledoc "Stub merger that parks a worker at :awaiting_review (see dashboard test)."
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

defmodule ArbiterWeb.MergeQueueIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ArbiterWeb.MergeQueueIndexLiveTest.QueueMerger
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  # The worker walk, workspace/title/queue-position reads and the landed
  # query all arrive by `start_async/3` on the connected mount (bd-aebiwf);
  # every test but the loading/error ones themselves wants the page once
  # it has landed.
  @async_timeout 5_000

  defp live_merge_queue(conn, path) do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "cr-#{System.unique_integer([:positive])}", prefix: "crx"})

    {:ok, ws: ws}
  end

  defp merge_opts do
    %{
      adapter: QueueMerger,
      workspace: nil,
      auto_merge: false,
      interval_ms: 600_000,
      initial_delay_ms: 600_000
    }
  end

  describe "Queued tab" do
    test "empty state when nothing is integrating", %{conn: conn} do
      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")
      assert html =~ ~s(id="merge_queue-empty")
      assert html =~ "integrating right now"
    end

    test "row anatomy: position, id, title, PR link, check dots, time-in-queue",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

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

    test "Queued tab is the default and shows in the tab bar with a live count",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")
      assert html =~ "Queued"
      assert html =~ "Landed today"
      assert html =~ "Rejected"
    end

    test "a draft PR lights the Mergeable dot red, not green", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "draft-pr", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      :ok =
        Worker.record_merger_status(pid, %{
          pipeline: :success,
          approved: true,
          block_reason: :draft
        })

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")

      [_, mergeable_dot] =
        Regex.run(~r/<span[^>]*title="Mergeable"[^>]*class="([^"]*)"/, html) ||
          Regex.run(~r/class="([^"]*)"[^>]*title="Mergeable"/, html)

      assert mergeable_dot =~ "bg-error"
    end

    test "an unknown/not-yet-started CI signal renders as unknown, not passed",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "no-ci-yet", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      :ok = Worker.record_merger_status(pid, %{pipeline: :not_started, approved: false})

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue")

      [_, ci_dot] =
        Regex.run(~r/class="([^"]*)"[^>]*title="CI"/, html) ||
          Regex.run(~r/<span[^>]*title="CI"[^>]*class="([^"]*)"/, html)

      refute ci_dot =~ "bg-success"
      assert ci_dot =~ "bg-base-300"
    end

    test "the header count and subtitle describe the active tab, not always Queued",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "merging-now", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      Ash.create!(Run, %{
        task_id: task.id,
        task_title: task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        completed_at: DateTime.utc_now(),
        mr_ref: "!42"
      })

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
    test "shows a 3-col grid of muted TaskCards for runs completed today", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "shipped-thing", workspace_id: ws.id})

      Ash.create!(Run, %{
        task_id: task.id,
        task_title: task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        completed_at: DateTime.utc_now(),
        mr_ref: "!42"
      })

      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")

      assert html =~ ~s(id="merge_queue-landed")
      assert html =~ "grid-cols-1"
      assert html =~ "lg:grid-cols-3"
      assert html =~ task.id
      assert html =~ "shipped-thing"
      assert html =~ "UTC"
      refute html =~ ~s(id="merge_queue-landed-empty")
    end

    test "empty state when nothing landed today", %{conn: conn} do
      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")
      assert html =~ ~s(id="merge_queue-landed-empty")
      assert html =~ "landed today"
    end

    test "two landed runs for the same task render without a duplicate DOM id",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "landed-twice", workspace_id: ws.id})

      for mr_ref <- ["!42", "!43"] do
        Ash.create!(Run, %{
          task_id: task.id,
          task_title: task.title,
          repo: "test/repo",
          workspace_id: ws.id,
          status: :completed,
          started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          completed_at: DateTime.utc_now(),
          mr_ref: mr_ref
        })
      end

      # `live/2` raises on duplicate DOM ids found while rendering the LiveView.
      {:ok, _view, html} = live_merge_queue(conn, ~p"/merge_queue?tab=landed")

      assert html =~ ~s(id="merge_queue-landed")
      assert html =~ task.id
    end

    test "a run completed before today does not show up", %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "old-news", workspace_id: ws.id})

      Ash.create!(Run, %{
        task_id: task.id,
        task_title: task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -172_800, :second),
        completed_at: DateTime.add(DateTime.utc_now(), -172_000, :second),
        mr_ref: "!41"
      })

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
    # Holds the worker walk (`Worker.list_children/0`) in flight until the
    # test says go, so the loading state is something to assert on rather
    # than a race — same discipline as `worker_index_live_test.exs`'s
    # `hold_workers_load/0` (bd-4gtia5).
    defp hold_merge_queue_load do
      test = self()

      :meck.new(Arbiter.Worker, [:passthrough, :no_link])

      :meck.expect(Arbiter.Worker, :list_children, fn ->
        children = :meck.passthrough([])
        send(test, {:loading_merge_queue, self()})

        receive do
          :release -> :ok
        after
          1_000 -> send(test, {:unreleased_merge_queue_load, self()})
        end

        children
      end)

      on_exit(fn -> :meck.unload(Arbiter.Worker) end)
    end

    test "the dead render shows the loading state and does not walk live workers",
         %{conn: conn} do
      test = self()
      :meck.new(Arbiter.Worker, [:passthrough, :no_link])
      :meck.expect(Arbiter.Worker, :list_children, fn -> send(test, :worker_walk) && [] end)
      on_exit(fn -> :meck.unload(Arbiter.Worker) end)

      doc = conn |> get(~p"/merge_queue") |> html_response(200) |> LazyHTML.from_document()

      assert doc
             |> LazyHTML.query(~s(#merge_queue-panel[data-state="loading"]))
             |> Enum.count() == 1

      assert doc |> LazyHTML.query("#merge_queue-loading") |> Enum.count() == 1
      refute_received :worker_walk
    end

    test "renders a loading skeleton before the async load lands, then the data",
         %{conn: conn, ws: ws} do
      {:ok, task} = Ash.create(Issue, %{title: "async-loading", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

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
      # `list_children/0` rescues raised exceptions (best-effort, matching
      # the original synchronous code) but not an `:exit` — this exercises
      # the genuinely-unguarded failure mode and lands in
      # `handle_async(:merge_queue, {:exit, _}, socket)`.
      :meck.new(Arbiter.Worker, [:passthrough, :no_link])
      :meck.expect(Arbiter.Worker, :list_children, fn -> exit(:boom) end)
      on_exit(fn -> :meck.unload(Arbiter.Worker) end)

      {:ok, view, _html} = live(conn, ~p"/merge_queue")
      html = render_async(view, @async_timeout)

      assert html =~ ~s(id="merge_queue-error")
      assert has_element?(view, "#merge_queue-retry")
    end

    test "a :worker_lifecycle broadcast refreshes the queued tab", %{conn: conn, ws: ws} do
      {:ok, view, html} = live_merge_queue(conn, ~p"/merge_queue")
      refute html =~ "broadcast-refresh"

      {:ok, task} = Ash.create(Issue, %{title: "broadcast-refresh", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      html = render_async(view, @async_timeout)

      assert html =~ "broadcast-refresh"
    end

    test "navigating to a new page while a load is in flight keeps the requested page",
         %{conn: conn, ws: ws} do
      for i <- 1..25 do
        title = "landed-#{String.pad_leading(to_string(i), 2, "0")}"

        Ash.create!(Run, %{
          task_id: Ash.create!(Issue, %{title: title, workspace_id: ws.id}).id,
          task_title: title,
          repo: "test/repo",
          workspace_id: ws.id,
          status: :completed,
          started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          completed_at: DateTime.add(DateTime.utc_now(), -(26 - i), :second),
          mr_ref: "!#{i}"
        })
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
      {:ok, queued_task} = Ash.create(Issue, %{title: "queued-thing", workspace_id: ws.id})
      {:ok, pid} = Worker.start(task_id: queued_task.id, repo: "test/repo", workspace_id: ws.id)
      :ok = Worker.advance(pid, :integrate)
      {:ok, "!77"} = Worker.open_mr(pid, "feature/x", "Integrate x", "", merge_opts())

      {:ok, landed_task} = Ash.create(Issue, %{title: "landed-thing", workspace_id: ws.id})

      Ash.create!(Run, %{
        task_id: landed_task.id,
        task_title: landed_task.title,
        repo: "test/repo",
        workspace_id: ws.id,
        status: :completed,
        started_at: DateTime.add(DateTime.utc_now(), -3600, :second),
        completed_at: DateTime.utc_now(),
        mr_ref: "!42"
      })

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
