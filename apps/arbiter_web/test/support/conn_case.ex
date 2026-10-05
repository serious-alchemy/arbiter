defmodule ArbiterWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. SQLite with WAL mode
  supports concurrent readers; `async: true` is safe for
  read-heavy tests, but the sandbox serialises writes.

  ## LiveView teardown and the sandbox connection (bd-5scl0c)

  A `Phoenix.LiveView.Channel` mounted by `Phoenix.LiveViewTest` can still be
  holding a checkout on the single shared sandbox connection when it is killed,
  and killing it mid-query drops that connection. Two things keep the fallout
  inside the owning test:

    * `Phoenix.LiveViewTest` starts each channel under the *ExUnit test
      supervisor*, and `ExUnit.OnExitHandler.run/2` terminates that supervisor
      and waits for its `:DOWN` before it runs any `on_exit` callback — so
      every LiveView this test mounted is already dead by the time teardown
      starts, let alone by the time the next test starts.
    * Every module that mounts a LiveView runs `async: false`, so there is no
      concurrently running test to lose the connection out from under.

  The second one is load-bearing and invisible, so it is asserted by
  `ArbiterWeb.ConnCaseSandboxTest`.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ArbiterWeb.Endpoint

      use ArbiterWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ArbiterWeb.ConnCase
    end
  end

  setup tags do
    Arbiter.DataCase.setup_sandbox(tags)

    {:ok, conn: coordinator_conn()}
  end

  @doc """
  A conn carrying a coordinator-tier bearer token — the default `conn` every
  test gets. `/api` requires a token (bd-asawcq), and `arb` always sends
  one, so this is what a real API caller looks like. The header is inert on
  browser routes. A test about anonymous or narrower callers builds its own
  with `Phoenix.ConnTest.build_conn/0`.

  It also carries a dashboard login grant (bd-3gycsz) so browser-route tests
  start logged in; `ArbiterWeb.DashboardAuthTest` builds anonymous conns.
  """
  def coordinator_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(
      ArbiterWeb.DashboardAuth.Default.grant_session("token", "test")
    )
    |> Plug.Conn.put_req_header(
      "authorization",
      "Bearer " <> Arbiter.MCP.Scope.mint_coordinator(nil)
    )
  end

  @doc """
  Give `conn` a dashboard login grant (bd-3gycsz), as `/login` would — what a
  browser test needs to reach any `:browser` route or LiveView. Carries no
  bearer token.
  """
  def dashboard_login(conn) do
    Plug.Test.init_test_session(
      conn,
      ArbiterWeb.DashboardAuth.Default.grant_session("token", "test")
    )
  end

  @doc """
  Mounts `/workspaces/:id` and waits for it to finish loading (bd-7p07gw).

  The page loads in two waves, both via `start_async`: the workspace itself
  (and the scheduler status) on the connected mount, and then — once the
  sections exist to ask — each section's own slow read, such as the per-repo
  `git status` behind the worktree chips. One `render_async/1` only waits for
  the tasks already running, so this waits for both waves.

  A macro because `Phoenix.LiveViewTest.live/2` is one (it reads the
  caller's `@endpoint`). Tests about the loading state itself mount with
  `live/2` directly.
  """
  defmacro live_workspace(conn, id) do
    quote do
      require Phoenix.LiveViewTest

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live(unquote(conn), "/workspaces/#{unquote(id)}")

      _ = Phoenix.LiveViewTest.render_async(view)
      {:ok, view, Phoenix.LiveViewTest.render_async(view)}
    end
  end

  @render_async_settled_rounds 10

  @doc """
  `Phoenix.LiveViewTest.render_async/2`, repeated until the view has no async
  task left running (bd-jw7cb0).

  `render_async/2` only awaits the tasks already running when it is called. A
  view whose `handle_async/3` can start another read — `ArbiterWeb.BoardLive`
  re-reads once when a refresh was asked for while its read was out, which is
  exactly what a drag's own lifecycle broadcast does — can still be rendering
  the older read when `render_async/2` returns.

  Gives up after `@render_async_settled_rounds` rounds: a view that keeps
  starting reads (a polling tick) never settles, and that should fail here,
  by name, rather than at ExUnit's per-test timeout.
  """
  def render_async_settled(view, timeout \\ 5_000),
    do: render_async_settled(view, timeout, @render_async_settled_rounds)

  defp render_async_settled(view, timeout, rounds_left) do
    html = Phoenix.LiveViewTest.render_async(view, timeout)

    case Phoenix.LiveView.Channel.async_pids(view.pid) do
      {:ok, []} ->
        html

      {:ok, running} when rounds_left <= 1 ->
        ExUnit.Assertions.flunk(
          "render_async_settled/2: the view still had #{length(running)} async task(s) " <>
            "running after #{@render_async_settled_rounds} rounds of render_async/2 — " <>
            "it keeps starting new reads and never settles"
        )

      {:ok, _running} ->
        render_async_settled(view, timeout, rounds_left - 1)
    end
  end

  @doc """
  Mounts `/workers/:task_id` and waits for it to finish loading (bd-c5m9b5).

  The worker snapshot and the task's database reads each load via
  `start_async` on the connected mount; this waits for both, so the returned
  HTML is the loaded page. Tests about the loading state itself mount with
  `live/2` directly.
  """
  defmacro live_worker(conn, task_id) do
    quote do
      require Phoenix.LiveViewTest

      {:ok, view, _html} =
        Phoenix.LiveViewTest.live(unquote(conn), "/workers/#{unquote(task_id)}")

      {:ok, view, Phoenix.LiveViewTest.render_async(view)}
    end
  end
end
