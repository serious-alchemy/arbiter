defmodule ArbiterWeb.WorkerIndexLiveTest.TestMerger do
  @behaviour Arbiter.Mergers.Merger

  @impl true
  def open(_branch, _title, _desc, _opts), do: {:ok, "!99"}
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
  def link_for(_ref), do: "https://example.test/mr/99"
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

defmodule ArbiterWeb.WorkerIndexLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}
  alias Arbiter.Worker
  alias ArbiterWeb.WorkerIndexLiveTest.TestMerger

  # The worker walk arrives by `start_async/3` after the connected mount
  # (bd-4gtia5); everything but the async tests themselves wants the page
  # once it has landed.
  @async_timeout 5_000

  defp live_workers(conn, path \\ ~p"/workers") do
    {:ok, view, _html} = live(conn, path)
    {:ok, view, render_async(view, @async_timeout)}
  end

  setup do
    for snap <- Worker.list_children(), do: Worker.stop(snap.task_id)
    Process.sleep(50)

    {:ok, ws} =
      Ash.create(Workspace, %{name: "pi-#{System.unique_integer([:positive])}", prefix: "pix"})

    {:ok, ws: ws}
  end

  defp merge_opts do
    %{
      adapter: TestMerger,
      workspace: nil,
      auto_merge: false,
      interval_ms: 600_000,
      initial_delay_ms: 600_000
    }
  end

  test "empty state when no workers are active", %{conn: conn} do
    {:ok, _view, html} = live_workers(conn)
    assert html =~ ~s(id="workers-empty")
    assert html =~ "hero-moon"
  end

  test "lists an active worker with its workspace, linking to detail", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "active-worker", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, _view, html} = live_workers(conn)

    assert html =~ ~s(id="workers")
    assert html =~ task.id
    assert html =~ ws.name
    assert html =~ ~s(href="/workers/#{task.id}")
  end

  test "shows the worker's provider icon", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "provider-worker", workspace_id: ws.id})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.report(pid, :provider, "gemini")

    {:ok, _view, html} = live_workers(conn)

    assert html =~ ~s(aria-label="Antigravity")
  end

  test "live: stopping a worker removes it via PubSub", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "soon-stopped", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    {:ok, view, html} = live_workers(conn)
    assert html =~ task.id

    Worker.stop(task.id)
    Process.sleep(150)

    refute render_async(view, @async_timeout) =~ task.id
  end

  # bd-741sid: the worker that opens a PR no longer parks on it at
  # :awaiting_review — its run ends and the ticket owns the PR. The MR's badge
  # went with it, from this list to the ticket's Merge request panel.
  defp open_pr(ws, title) do
    {:ok, task} = Ash.create(Issue, %{title: title, workspace_id: ws.id})
    {:ok, _} = Ash.update(task, %{status: :in_progress})
    {:ok, pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    :ok = Worker.advance(pid, :integrate)
    run = Process.monitor(pid)
    {:ok, _} = Worker.open_mr(pid, "feature/test", "Test", "", merge_opts())
    assert_receive {:DOWN, ^run, :process, ^pid, _}, 2_000
    task
  end

  test "an MR awaiting approval leaves the list and badges the ticket's merge request", %{
    conn: conn,
    ws: ws
  } do
    task = open_pr(ws, "awaiting-task")

    # Record merger status: MR is open, not approved (awaiting review)
    :ok = PullRequest.record_merger_status(task.id, %{status: :open, approved: false})

    {:ok, view, _html} = live_workers(conn, ~p"/workers?status=awaiting")
    assert has_element?(view, ~s(#workers-panel[data-state="loaded"]))
    refute has_element?(view, ~s(#workers a[href="/workers/#{task.id}"]))

    {:ok, view, _html} = live_worker(conn, task.id)
    # When CI is not running, should show "Open · awaiting approval"
    assert has_element?(view, "#worker-merge-request", "Open · awaiting approval")
  end

  test "an MR with running CI badges the ticket's merge request CI running", %{
    conn: conn,
    ws: ws
  } do
    task = open_pr(ws, "ci-running-task")

    # Record merger status: MR is open, not approved, but CI is running
    :ok =
      PullRequest.record_merger_status(task.id, %{
        status: :open,
        approved: false,
        pipeline: :running
      })

    {:ok, view, _html} = live_worker(conn, task.id)
    # When CI is running, should show "Open · CI running"
    assert has_element?(view, "#worker-merge-request", "Open · CI running")
  end

  # bd-45tkhq round 2: a wedged worker whose registry key has no matching
  # `Arbiter.Workers.Run` row degrades to `started_at: nil` (Worker.worker_test.exs
  # covers the degrade path itself). `refresh/1`'s `Enum.sort_by(&1.started_at,
  # {:asc, DateTime})` had no nil clause and crashed the whole page on every
  # `:worker_lifecycle` refresh once such an entry existed, alongside a normal
  # worker with a real `started_at`.
  test "a degraded entry with nil started_at does not crash the page", %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "normal-worker", workspace_id: ws.id})
    {:ok, normal_pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, normal_pid) end)

    orphan_task_id = "gte-orphan-#{System.unique_integer([:positive])}"

    {:ok, wedged_pid} =
      Worker.start(
        task_id: orphan_task_id,
        repo: "test/repo",
        workspace_id: ws.id,
        registry_key: "unmatched-registry-key-#{System.unique_integer([:positive])}"
      )

    # bd-5scl0c: `:sys.suspend/2` a worker so `list_children/0` genuinely hits
    # the degrade path, then hand teardown to `ProcessTeardown.stop_child/3`
    # rather than a bare `:sys.resume/2` — it quiesces before terminating, so
    # a suspended worker still holding the shared sandbox connection can't be
    # killed mid-checkout and take the connection down with it.
    :sys.suspend(wedged_pid)
    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, wedged_pid) end)

    {:ok, _view, html} = live_workers(conn)
    assert html =~ task.id
  end

  # Holds the GenServer fan-out (`Worker.list_children/0`) in flight until the
  # test says go, so the loading state is something to assert on rather than
  # a race — the same discipline board_live_test.exs uses for its own
  # `hold_board_load/0` around `Snapshot.load/1` (bd-15bn6s).
  defp hold_workers_load do
    test = self()

    :meck.new(Arbiter.Worker, [:passthrough, :no_link])

    :meck.expect(Arbiter.Worker, :list_children, fn ->
      children = :meck.passthrough([])
      send(test, {:loading_workers, self()})

      receive do
        :release -> :ok
      after
        1_000 -> send(test, {:unreleased_workers_load, self()})
      end

      children
    end)

    on_exit(fn ->
      :meck.unload(Arbiter.Worker)
    end)
  end

  test "the dead render shows the loading state and does not walk live workers", %{conn: conn} do
    test = self()
    :meck.new(Arbiter.Worker, [:passthrough, :no_link])
    :meck.expect(Arbiter.Worker, :list_children, fn -> send(test, :worker_walk) && [] end)
    on_exit(fn -> :meck.unload(Arbiter.Worker) end)

    doc = conn |> get(~p"/workers") |> html_response(200) |> LazyHTML.from_document()

    assert doc |> LazyHTML.query(~s(#workers-panel[data-state="loading"])) |> Enum.count() == 1
    assert doc |> LazyHTML.query("#workers-loading") |> Enum.count() == 1
    refute_received :worker_walk
  end

  test "renders a loading skeleton before the async worker walk lands, then the data",
       %{conn: conn, ws: ws} do
    {:ok, task} = Ash.create(Issue, %{title: "loading-worker", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    hold_workers_load()

    {:ok, view, _html} = live(conn, ~p"/workers")
    assert_receive {:loading_workers, loader}

    assert has_element?(view, ~s(#workers-panel[data-state="loading"]))
    assert has_element?(view, "#workers-loading")
    refute has_element?(view, "#workers-empty")

    send(loader, :release)
    html = render_async(view, @async_timeout)

    assert has_element?(view, ~s(#workers-panel[data-state="loaded"]))
    refute has_element?(view, "#workers-loading")
    assert html =~ task.id
    refute_received {:unreleased_workers_load, _}
  end

  # bd-4gtia5 round 2: `handle_params` used to clamp `:page` against
  # `workers_raw` before the async load landed, which is `[]` on every fresh
  # mount — so a direct link/reload of `?page=2` (or later) always paged
  # against an empty list and got clamped back to page 1, silently dropping
  # the requested page once real data arrived. The requested page must
  # survive until the load lands.
  test "opening ?page=2 directly shows page 2 once the async load lands", %{conn: conn, ws: ws} do
    page_size = ArbiterWeb.Paging.default_page_size()

    for n <- 1..(page_size + 1) do
      {:ok, task} = Ash.create(Issue, %{title: "paged-worker-#{n}", workspace_id: ws.id})
      {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)
    end

    {:ok, _view, html} = live_workers(conn, ~p"/workers?page=2")

    assert html =~ "2 / 2"
  end

  test "an async worker-walk failure renders an inline error, not a crash", %{
    conn: conn,
    ws: ws
  } do
    {:ok, task} = Ash.create(Issue, %{title: "error-path-worker", workspace_id: ws.id})
    {:ok, _pid} = Worker.start(task_id: task.id, repo: "test/repo", workspace_id: ws.id)

    # `list_children/0` and `index_workspaces/0` both rescue their own reads,
    # so the only unguarded step left in the async load is the phase
    # annotation — raising there is what actually exercises the
    # `handle_async(:workers, {:exit, _}, socket)` clause.
    :meck.new(Arbiter.Worker.Phase, [:passthrough, :no_link])
    :meck.expect(Arbiter.Worker.Phase, :annotate, fn _workers -> raise "boom" end)

    on_exit(fn ->
      :meck.unload(Arbiter.Worker.Phase)
    end)

    {:ok, view, _html} = live(conn, ~p"/workers")
    html = render_async(view, @async_timeout)

    assert html =~ ~s(id="workers-error")
    assert html =~ "boom"
    assert has_element?(view, "#workers-retry")
  end
end
