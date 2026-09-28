defmodule ArbiterWeb.WorkspaceIndexLiveTest do
  @moduledoc """
  bd-3jibxx: `/workspaces` index used to read and sort the workspace list
  synchronously in `mount/3`, blocking both the dead render and the connected
  one. The list is small, so the win is modest, but the pattern is established
  and this completes it for consistency.

  The workspaces now load via `start_async/3` on the connected mount, and the
  page renders a loading state, then the data. These tests pin the loading
  state, the loaded state, and the inline error state.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.Workspace

  @async_timeout 5_000

  defp new_workspace(attrs \\ %{}) do
    base = %{name: "ws-#{System.unique_integer([:positive])}", prefix: "wx"}
    {:ok, ws} = Ash.create(Workspace, Map.merge(base, attrs))
    ws
  end

  defp live_workspaces(conn) do
    {:ok, view, _html} = live(conn, ~p"/workspaces")
    {:ok, view, render_async(view, @async_timeout)}
  end

  describe "mount" do
    setup do
      :meck.new(ArbiterWeb.WorkspaceIndexLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.WorkspaceIndexLive) end)
      :ok
    end

    test "the dead render shows the loading state and reads no workspaces", %{conn: conn} do
      _ws1 = new_workspace()
      _ws2 = new_workspace()
      test = self()

      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        send(test, :workspaces_read)
        :meck.passthrough([])
      end)

      html = conn |> get(~p"/workspaces") |> html_response(200)

      assert html =~ ~s(id="workspaces-loading")
      refute html =~ ~s(id="workspaces-table")
      refute_received :workspaces_read
    end

    test "renders a loading state, then the workspaces", %{conn: conn} do
      ws1 = new_workspace(%{name: "alpha"})
      ws2 = new_workspace(%{name: "beta"})
      test = self()

      # Hold the read in the background so we can observe the loading state
      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        send(test, {:loading_workspaces, self()})

        receive do
          :release -> :meck.passthrough([])
        after
          5_000 -> exit(:timeout)
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces")
      assert_receive {:loading_workspaces, loader}

      assert has_element?(view, "#workspaces-loading")
      refute has_element?(view, "#workspaces-table")

      # Now release the loader and wait for the async result
      send(loader, :release)
      render_async(view, @async_timeout)

      refute has_element?(view, "#workspaces-loading")
      assert has_element?(view, "#workspaces-table")
      assert render(view) =~ ws1.name
      assert render(view) =~ ws2.name
    end
  end

  describe "async load" do
    setup do
      :meck.new(ArbiterWeb.WorkspaceIndexLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.WorkspaceIndexLive) end)
      :ok
    end

    test "a failed load renders an inline error, and Retry recovers", %{conn: conn} do
      _ws = new_workspace()

      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, ~p"/workspaces")
      render_async(view, @async_timeout)

      assert has_element?(view, "#workspaces-error", "database is locked")
      refute has_element?(view, "#workspaces-loading")
      refute has_element?(view, "#workspaces-table")

      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        :meck.passthrough([])
      end)

      view |> element("#workspaces-retry") |> render_click()
      render_async(view, @async_timeout)

      refute has_element?(view, "#workspaces-error")
      assert has_element?(view, "#workspaces-table")
    end

    test "workspaces are sorted by name", %{conn: conn} do
      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        :meck.passthrough([])
      end)

      _ws3 = new_workspace(%{name: "charlie"})
      _ws1 = new_workspace(%{name: "alpha"})
      _ws2 = new_workspace(%{name: "beta"})

      {:ok, _view, html} = live_workspaces(conn)

      # Extract workspace names in order from the HTML
      names =
        html
        |> LazyHTML.from_document()
        |> LazyHTML.query("li span.text-\\[13px\\]")
        |> Enum.map(&LazyHTML.text/1)

      # Filter to only the workspace names (skip other text)
      assert Enum.any?(names, &String.contains?(&1, "alpha"))
      assert Enum.any?(names, &String.contains?(&1, "beta"))
      assert Enum.any?(names, &String.contains?(&1, "charlie"))

      # Check ordering: alpha should come before beta, beta before charlie
      alpha_idx = Enum.find_index(names, &String.contains?(&1, "alpha"))
      beta_idx = Enum.find_index(names, &String.contains?(&1, "beta"))
      charlie_idx = Enum.find_index(names, &String.contains?(&1, "charlie"))

      assert alpha_idx < beta_idx
      assert beta_idx < charlie_idx
    end

    test "shows empty state when no workspaces exist", %{conn: conn} do
      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        :meck.passthrough([])
      end)

      {:ok, _view, html} = live_workspaces(conn)

      assert html =~ "no workspaces yet"
    end
  end

  describe "PubSub refresh" do
    setup do
      :meck.new(ArbiterWeb.WorkspaceIndexLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.WorkspaceIndexLive) end)
      ws = new_workspace(%{name: "pubsub-test"})
      {:ok, ws: ws}
    end

    test "list is populated after load completes", %{conn: conn, ws: existing} do
      :meck.expect(ArbiterWeb.WorkspaceIndexLive, :read_workspaces, fn ->
        :meck.passthrough([])
      end)

      {:ok, _view, html} = live_workspaces(conn)

      # Verify we have the existing workspace
      assert html =~ existing.name
    end
  end
end
