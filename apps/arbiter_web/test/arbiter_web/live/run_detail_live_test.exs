defmodule ArbiterWeb.RunDetailLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Workers.Run

  # The run load arrives via `start_async/3` after the connected mount
  # (bd-ap05jy); everything but the async-path tests themselves wants the
  # page once it has landed.
  @async_timeout 5_000

  defp run(attrs) do
    {:ok, r} =
      Ash.create(
        Run,
        Map.merge(
          %{
            repo: "arbiter",
            workspace_id: "ws-1",
            started_at: DateTime.add(DateTime.utc_now(), -120, :second),
            completed_at: DateTime.utc_now(),
            state: :finished,
            outcome: :succeeded
          },
          attrs
        )
      )

    r
  end

  defp live_run(conn, id) do
    {:ok, view, _html} = live(conn, ~p"/workers/history/#{id}")
    {:ok, view, render_async(view, @async_timeout)}
  end

  describe "node (RW7)" do
    alias Arbiter.Nodes
    alias Arbiter.Nodes.Registry

    setup do
      previous = Application.fetch_env(:arbiter, :node_primary_version)
      Application.put_env(:arbiter, :node_primary_version, "1.2.3")

      on_exit(fn ->
        case previous do
          {:ok, v} -> Application.put_env(:arbiter, :node_primary_version, v)
          :error -> Application.delete_env(:arbiter, :node_primary_version)
        end

        for {pid, _} <- Registry.list(),
            do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
      end)
    end

    defp connected_node!(name, run_ids) do
      {:ok, %{token: t}} = Nodes.mint_join_token([name: name], Arbiter.Actor.operator("test"))
      {:ok, %{node: node}} = Nodes.redeem_join_token(t)

      {:ok, _} =
        Registry.attach(
          node,
          self(),
          %{
            "agent_version" => "1.2.3",
            "proto" => 1,
            "caps" => %{},
            "capacity" => %{"suggestion" => 2},
            "runs" => Enum.map(run_ids, &%{"id" => &1})
          },
          tick_ms: :infinity
        )

      node
    end

    test "a run on a node names the node and links to it", %{conn: conn} do
      r = run(%{task_id: "bd-on-node", state: :working, completed_at: nil, outcome: nil})
      node = connected_node!("gpu-1", [r.id])

      {:ok, view, _html} = live_run(conn, r.id)

      assert has_element?(view, "#run-node", "gpu-1")
      assert has_element?(view, ~s(#run-node a[href="/nodes/#{node.id}"]))
    end

    test "a run on the primary shows no node", %{conn: conn} do
      r = run(%{task_id: "bd-local-run"})
      _node = connected_node!("idle", [])

      {:ok, view, _html} = live_run(conn, r.id)

      refute has_element?(view, "#run-node")
    end
  end

  describe "mount" do
    test "renders the loading state then the run", %{conn: conn} do
      r = run(%{task_id: "bd-detail-ok", task_title: "the-good-run", output_lines: ["hello"]})

      {:ok, _view, html} = live_run(conn, r.id)

      assert html =~ "bd-detail-ok"
      assert html =~ "hello"
      refute html =~ ~s(id="run-detail-loading")
    end

    test "shows the run's kind and its outcome label (bd-1uu19b)", %{conn: conn} do
      r =
        run(%{
          task_id: "bd-detail-kind",
          task_title: "revise-run",
          kind: :implement,
          role: "impl",
          outcome: :handed_off
        })

      {:ok, _view, html} = live_run(conn, r.id)

      assert html =~ "KIND"
      refute html =~ "TYPE"
      assert html =~ "impl"
      assert html =~ "Handed off"
    end

    test "shows a distinct not-found state for an unknown id", %{conn: conn} do
      {:ok, _view, html} = live_run(conn, Ash.UUID.generate())

      assert html =~ ~s(id="run-detail-not-found")
      refute html =~ ~s(id="run-detail-loading")
      refute html =~ ~s(id="run-detail-error")
    end
  end

  describe "async load" do
    setup do
      :meck.new(ArbiterWeb.RunDetailLive, [:passthrough, :no_link])
      on_exit(fn -> :meck.unload(ArbiterWeb.RunDetailLive) end)
      :ok
    end

    test "the dead render shows the loading state and reads nothing", %{conn: conn} do
      r = run(%{task_id: "bd-detail-dead", task_title: "dead-render"})
      test = self()

      :meck.expect(ArbiterWeb.RunDetailLive, :load_run_data, fn id ->
        send(test, :run_read)
        :meck.passthrough([id])
      end)

      doc =
        conn
        |> get(~p"/workers/history/#{r.id}")
        |> html_response(200)
        |> LazyHTML.from_document()

      assert doc |> LazyHTML.query("#run-detail-loading") |> Enum.count() == 1
      refute_received :run_read
    end

    test "renders a loading skeleton before the async load lands, then the data", %{conn: conn} do
      r = run(%{task_id: "bd-detail-loading", task_title: "loading-run"})
      test = self()

      :meck.expect(ArbiterWeb.RunDetailLive, :load_run_data, fn id ->
        result = :meck.passthrough([id])
        send(test, {:loading, self()})

        receive do
          :continue -> result
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/history/#{r.id}")

      assert_receive {:loading, loader}
      assert has_element?(view, "#run-detail-loading")
      refute has_element?(view, "#run-detail-error")

      send(loader, :continue)
      html = render_async(view, @async_timeout)

      assert html =~ "bd-detail-loading"
      refute has_element?(view, "#run-detail-loading")
    end

    test "a failed load renders an inline error, not a crash", %{conn: conn} do
      r = run(%{task_id: "bd-detail-error", task_title: "error-run"})

      :meck.expect(ArbiterWeb.RunDetailLive, :load_run_data, fn _id ->
        raise "database is locked"
      end)

      {:ok, view, _html} = live(conn, ~p"/workers/history/#{r.id}")
      render_async(view, @async_timeout)

      assert has_element?(view, "#run-detail-error")
      assert has_element?(view, "#run-detail-error", "database is locked")
      refute has_element?(view, "#run-detail-loading")
    end
  end

  describe "provider icon display (bd-7he5xm)" do
    test "shows the provider icon and display name when run has a provider", %{conn: conn} do
      r =
        run(%{
          task_id: "bd-provider-display",
          task_title: "provider-display-run",
          provider: "claude"
        })

      {:ok, _view, html} = live_run(conn, r.id)

      # Check that the PROVIDER card is present
      assert html =~ "PROVIDER"

      # Use LazyHTML to verify the provider icon is present
      doc = LazyHTML.from_fragment(html)
      claude_icons = LazyHTML.query(doc, "svg[aria-label=\"Claude\"]")
      assert Enum.count(claude_icons) > 0, "Claude provider icon should be present"

      # Check that the display name is shown
      assert html =~ "Claude"
    end

    test "shows 'unknown' when run has no provider", %{conn: conn} do
      r =
        run(%{
          task_id: "bd-no-provider-detail",
          task_title: "no-provider-run",
          provider: nil
        })

      {:ok, _view, html} = live_run(conn, r.id)

      # Check that the PROVIDER card is present
      assert html =~ "PROVIDER"

      # Should show "unknown" for nil provider
      assert html =~ "unknown"

      # Should not show any provider icon
      doc = LazyHTML.from_fragment(html)
      # (the app shell carries its own "arbiter" logo svgs, so match provider labels only)
      icons =
        LazyHTML.query(
          doc,
          ~s(svg[aria-label="Claude"], svg[aria-label="Codex"], svg[aria-label="Antigravity"], svg[aria-label="Ollama"], svg[aria-label="Unknown provider"])
        )

      assert Enum.count(icons) == 0, "No provider icon should render for nil provider"
    end

    test "displays different provider icons correctly", %{conn: conn} do
      codex_run =
        run(%{
          task_id: "bd-codex-detail",
          task_title: "codex-run",
          provider: "codex"
        })

      {:ok, _view, html} = live_run(conn, codex_run.id)

      # Use LazyHTML to verify the correct provider icon
      doc = LazyHTML.from_fragment(html)
      codex_icons = LazyHTML.query(doc, "svg[aria-label=\"Codex\"]")
      assert Enum.count(codex_icons) > 0, "Codex provider icon should be present"
      assert html =~ "Codex"

      # Test with gemini/Antigravity
      gemini_run =
        run(%{
          task_id: "bd-gemini-detail",
          task_title: "gemini-run",
          provider: "gemini"
        })

      {:ok, _view, html} = live_run(conn, gemini_run.id)

      doc = LazyHTML.from_fragment(html)
      gemini_icons = LazyHTML.query(doc, "svg[aria-label=\"Antigravity\"]")
      assert Enum.count(gemini_icons) > 0, "Antigravity (gemini) provider icon should be present"
      assert html =~ "Antigravity"
    end
  end
end
