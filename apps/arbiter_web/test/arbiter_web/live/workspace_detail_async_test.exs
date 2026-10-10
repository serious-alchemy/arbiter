defmodule ArbiterWeb.WorkspaceDetailAsyncTest do
  @moduledoc """
  bd-7p07gw: `/workspaces/:id` used to read the workspace and ask the board
  scheduler for its status synchronously in `mount/3`, on the dead render and
  the connected one alike, and the Repos section ran a `git status` per
  configured repo path in its first `update/2`. A slow or large repo held the
  whole page.

  The workspace and the scheduler status now load via `start_async/3` on the
  connected mount, and the worktree probe is the Repos section's own async
  load, chipped `checking` until it lands. These tests pin the loading state,
  the loaded state and the inline error state of each.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Board.Autopilot
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.Worktree

  defp new_workspace(attrs \\ %{}) do
    base = %{name: "ws-#{System.unique_integer([:positive])}", prefix: "wx"}
    {:ok, ws} = Ash.create(Workspace, Map.merge(base, attrs))
    ws
  end

  # Holds `fun`'s caller (a load task) until `test` sends `:release`, reporting the
  # blocked process so the test can assert on the loading state rather than
  # race it. A load the test never releases gives up well inside the
  # render_async timeout and says so, so the test fails on the assertion
  # rather than on a timeout.
  defp hold(test, tag, fun) do
    send(test, {tag, self()})

    receive do
      :release -> :ok
    after
      1_000 -> send(test, {:unreleased, tag})
    end

    fun.()
  end

  describe "the workspace load" do
    setup do
      :meck.new(Ash, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Ash) end)
      :ok
    end

    test "the dead render shows the loading state and reads no workspace", %{conn: conn} do
      ws = new_workspace()
      test = self()

      :meck.expect(Ash, :get, fn resource, id ->
        send(test, {:workspace_read, resource})
        :meck.passthrough([resource, id])
      end)

      html = conn |> get(~p"/workspaces/#{ws.id}") |> html_response(200)

      assert html =~ ~s(id="ws-loading")
      refute html =~ ~s(id="ws-rail")
      refute_received {:workspace_read, Workspace}
    end

    test "renders a loading state, then the workspace", %{conn: conn} do
      ws = new_workspace()
      test = self()

      :meck.expect(Ash, :get, fn
        Workspace, id ->
          hold(test, :loading_workspace, fn -> :meck.passthrough([Workspace, id]) end)

        resource, id ->
          :meck.passthrough([resource, id])
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")
      assert_receive {:loading_workspace, loader}

      assert has_element?(view, "#ws-loading")
      refute has_element?(view, "#ws-rail")

      send(loader, :release)
      render_async(view)

      refute has_element?(view, "#ws-loading")
      assert has_element?(view, "#ws-rail")
      assert render(view) =~ ws.name
      refute_received {:unreleased, :loading_workspace}
    end

    @tag :capture_log
    test "a failed load renders an inline error, and Retry recovers", %{conn: conn} do
      ws = new_workspace()

      :meck.expect(Ash, :get, fn
        Workspace, _id -> raise "database is locked"
        resource, id -> :meck.passthrough([resource, id])
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")
      render_async(view)

      assert has_element?(view, "#ws-error", "database is locked")
      refute has_element?(view, "#ws-loading")
      refute has_element?(view, "#ws-rail")

      :meck.expect(Ash, :get, fn resource, id -> :meck.passthrough([resource, id]) end)
      view |> element("#ws-retry") |> render_click()
      render_async(view)

      refute has_element?(view, "#ws-error")
      assert has_element?(view, "#ws-rail")
    end
  end

  test "an unknown id still lands on the not-found state", %{conn: conn} do
    {:ok, _view, html} = live_workspace(conn, Ash.UUID.generate())

    assert html =~ "Workspace not found"
  end

  describe "the auto-dispatch switch" do
    @switch ~s(button[role="switch"][aria-label="Auto-dispatch ready tickets"])

    setup do
      :meck.new(Autopilot, [:passthrough, :no_link])
      :meck.new(Ash, [:passthrough, :no_link])

      on_exit(fn ->
        :meck.unload(Autopilot)
        :meck.unload(Ash)
      end)

      :ok
    end

    # The switch reads the board scheduler, which can be slow; until it has
    # answered, the page must not claim either position or let a click flip a
    # switch whose current state it does not know.
    test "is disabled until the scheduler status has loaded", %{conn: conn} do
      ws = new_workspace()

      test = self()

      :meck.expect(Autopilot, :running?, fn server ->
        hold(test, :asking_scheduler, fn -> :meck.passthrough([server]) end)
      end)

      # `render_async/1` would wait on the held scheduler call too, so wait on
      # the workspace load's own task instead.
      :meck.expect(Ash, :get, fn
        Workspace, id ->
          send(test, {:loading_workspace, self()})
          :meck.passthrough([Workspace, id])

        resource, id ->
          :meck.passthrough([resource, id])
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")
      assert_receive {:asking_scheduler, asker}
      assert_receive {:loading_workspace, loader}
      ref = Process.monitor(loader)
      assert_receive {:DOWN, ^ref, :process, ^loader, _}

      assert has_element?(view, "#ws-rail")
      assert has_element?(view, @switch <> "[disabled]")

      send(asker, :release)
      render_async(view)

      assert has_element?(view, @switch)
      refute has_element?(view, @switch <> "[disabled]")
      refute_received {:unreleased, :asking_scheduler}
    end
  end

  describe "the worktree probe" do
    setup do
      :meck.new(Worktree, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(Worktree) end)

      ws =
        new_workspace(%{config: %{"repo_paths" => %{"arbiter" => "/tmp/arb-probe-path"}}})

      {:ok, ws: ws}
    end

    test "chips each repo checking, then its state", %{conn: conn, ws: ws} do
      test = self()

      :meck.expect(Worktree, :has_uncommitted?, fn _path ->
        hold(test, :probing, fn -> {:ok, true} end)
      end)

      # The probe starts only once the workspace has landed and the section
      # exists; its message is the signal, not a `render_async/1` that would
      # wait on the held probe itself.
      {:ok, view, _html} = live(conn, ~p"/workspaces/#{ws.id}")
      assert_receive {:probing, prober}

      assert has_element?(view, ~s(#repo-paths [data-worktree-state="checking"]))

      send(prober, :release)
      render_async(view)

      assert has_element?(view, ~s(#repo-paths [data-worktree-state="dirty"]))
      refute has_element?(view, ~s(#repo-paths [data-worktree-state="checking"]))
      refute_received {:unreleased, :probing}
    end

    @tag :capture_log
    test "a crashed probe chips unknown with an inline error", %{conn: conn, ws: ws} do
      :meck.expect(Worktree, :has_uncommitted?, fn _path -> raise "git exploded" end)

      {:ok, view, _html} = live_workspace(conn, ws.id)

      assert has_element?(view, ~s(#repo-paths [data-worktree-state="unknown"]))
      assert has_element?(view, "#repo-paths-worktree-error", "git exploded")
      assert has_element?(view, "#ws-rail")
    end

    test "a newly registered repo is probed without blocking the write", %{conn: conn, ws: ws} do
      test = self()

      :meck.expect(Worktree, :has_uncommitted?, fn
        "/tmp/arb-probe-new" -> hold(test, :probing, fn -> {:ok, false} end)
        _path -> {:ok, false}
      end)

      {:ok, view, _html} = live_workspace(conn, ws.id)

      view
      |> form("form[phx-submit=add_repo_path]", %{
        "repo_path" => %{"repo" => "newrepo", "path" => "/tmp/arb-probe-new"}
      })
      |> render_submit()

      assert_receive {:probing, prober}
      # The new repo is checking; the one whose path did not change keeps the
      # state it already had rather than blinking back to checking.
      assert has_element?(view, "#repo-paths", "newrepo")
      assert has_element?(view, ~s(#repo-paths [data-worktree-state="checking"]))
      assert has_element?(view, ~s(#repo-paths [data-worktree-state="clean"]))

      send(prober, :release)
      render_async(view)

      refute has_element?(view, ~s(#repo-paths [data-worktree-state="checking"]))
      refute_received {:unreleased, :probing}
    end
  end
end
