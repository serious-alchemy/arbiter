defmodule ArbiterWeb.NodesLiveTest do
  @moduledoc """
  `/nodes` and `/nodes/:id` (RW7, `docs/design/remote-workers.md` §14): the node
  list with the primary as a `local` row, per-node caps editable inline, the Add
  node flow, and drain / revoke / remove from the page.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{RateLimit, Registry}
  alias Arbiter.Settings

  @operator Actor.operator("cli")
  @version "1.2.3"
  @url "https://primary.example.ts.net"

  setup do
    previous = Application.fetch_env(:arbiter, :node_primary_version)
    Application.put_env(:arbiter, :node_primary_version, @version)
    {:ok, _} = Settings.set_nodes_public_url(@url)
    RateLimit.reset()

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :node_primary_version, v)
        :error -> Application.delete_env(:arbiter, :node_primary_version)
      end

      Settings.set_nodes_public_url(nil)
      Settings.set_nodes_local_max_workers(nil)
      Settings.set_conductor_system_max_concurrent(nil)

      for {pid, _} <- Registry.list(),
          do: Arbiter.ProcessTeardown.stop_child(Arbiter.Nodes.SessionSupervisor, pid)
    end)

    :ok
  end

  defp enroll!(name, opts \\ []) do
    {:ok, %{token: t}} = Nodes.mint_join_token([name: name] ++ opts, @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(t)
    node
  end

  defp connect!(node, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          "agent_version" => @version,
          "proto" => 1,
          "caps" => %{"backend" => "podman"},
          "capacity" => %{"suggestion" => 4},
          "runs" => []
        },
        overrides
      )

    {:ok, _} = Registry.attach(node, self(), params, tick_ms: :infinity)
  end

  describe "the list" do
    test "has the primary as a local row and one row per node", %{conn: conn} do
      node = enroll!("alpha")
      connect!(node)

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-table")
      assert has_element?(view, "#node-local")
      assert has_element?(view, "#node-#{node.id}")
      assert has_element?(view, "#node-#{node.id} [data-role=state]", "online")
      assert has_element?(view, "#node-#{node.id} [data-role=version]", @version)
      assert has_element?(view, "#node-#{node.id} [data-role=capacity]", "0/4")
      assert has_element?(view, "#node-local [data-role=state]", "online")
    end

    test "shows suggested, override, ceiling and live/max for each row", %{conn: conn} do
      node = enroll!("capped", max_workers: 8)
      connect!(node, %{"capacity" => %{"suggestion" => 4, "ceiling" => 3}})

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#node-#{node.id} [data-role=suggested]", "4")
      assert has_element?(view, "#node-#{node.id} [data-role=ceiling]", "3")
      assert has_element?(view, "#node-#{node.id} [data-role=capacity]", "0/3")
      assert has_element?(view, "#cap-form-#{node.id} input[name=max_workers][value='8']")
      assert has_element?(view, "#node-#{node.id} [data-role=cap-bound]")
    end

    test "an offline, a draining and a revoked node each say so", %{conn: conn} do
      cold = enroll!("cold")
      drained = enroll!("drained")
      gone = enroll!("gone")
      connect!(drained)
      {:ok, _} = Nodes.drain(drained, @operator)
      {:ok, _} = Nodes.revoke(gone, @operator)

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#node-#{cold.id} [data-role=state]", "offline")
      assert has_element?(view, "#node-#{drained.id} [data-role=state]", "draining")
      assert has_element?(view, "#node-#{gone.id} [data-role=state]", "revoked")
    end

    test "the header breaks capacity down by machine, under an optional ceiling", %{conn: conn} do
      Application.put_env(:arbiter, :remote_execution, true)
      on_exit(fn -> Application.delete_env(:arbiter, :remote_execution) end)

      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      {:ok, _} = Settings.set_conductor_system_max_concurrent(10)
      connect!(enroll!("alpha", max_workers: 3))

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-capacity-summary", "local 2")
      assert has_element?(view, "#nodes-capacity-summary", "alpha 3")
      assert has_element?(view, "#nodes-capacity-summary", "5")
      assert has_element?(view, "#nodes-capacity-summary", "10")
      refute has_element?(view, "#nodes-ceiling-warning")
    end

    test "with no ceiling the sum applies and nothing warns", %{conn: conn} do
      Application.put_env(:arbiter, :remote_execution, true)
      on_exit(fn -> Application.delete_env(:arbiter, :remote_execution) end)

      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      connect!(enroll!("alpha", max_workers: 3))

      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-capacity-summary", "not set")
      refute has_element?(view, "#nodes-ceiling-warning")
    end

    test "warns only when an explicit conductor.max_concurrent cuts the sum", %{conn: conn} do
      Application.put_env(:arbiter, :remote_execution, true)
      on_exit(fn -> Application.delete_env(:arbiter, :remote_execution) end)

      {:ok, 2} = Nodes.set_local_max_workers(2, @operator)
      {:ok, _} = Settings.set_conductor_system_max_concurrent(2)
      connect!(enroll!("alpha", max_workers: 5))

      {:ok, view, _} = live(conn, ~p"/nodes")
      assert has_element?(view, "#nodes-ceiling-warning")
    end

    test "a local cap of 0 shows a persistent warning", %{conn: conn} do
      {:ok, 0} = Nodes.set_local_max_workers(0, @operator)

      {:ok, view, _} = live(conn, ~p"/nodes")
      assert has_element?(view, "#nodes-local-cap-warning")
      assert has_element?(view, "#nodes-local-cap-warning", "wait")

      {:ok, _} = Nodes.set_local_max_workers(2, @operator)
      send(view.pid, :refresh)
      refute has_element?(view, "#nodes-local-cap-warning")
    end

    test "the nav links to the page", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      assert has_element?(view, ~s(nav a[href="/nodes"]))
    end
  end

  describe "inline caps" do
    test "overrides a node's cap, up or down, and audits it", %{conn: conn} do
      node = enroll!("alpha")
      connect!(node)
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> form("#cap-form-#{node.id}", %{max_workers: "2"}) |> render_submit()

      assert Nodes.get_node(node.id).max_workers == 2
      assert has_element?(view, "#node-#{node.id} [data-role=capacity]", "0/2")
      assert [%{detail: %{"changes" => %{"max_workers" => 2}}}] = Nodes.events(kind: :updated)
    end

    test "a blank value clears the override", %{conn: conn} do
      node = enroll!("alpha", max_workers: 2)
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> form("#cap-form-#{node.id}", %{max_workers: ""}) |> render_submit()
      assert Nodes.get_node(node.id).max_workers == nil
    end

    test "the local cap can go to 0", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> form("#cap-form-local", %{max_workers: "0"}) |> render_submit()

      assert Settings.nodes_local_max_workers() == 0
      assert has_element?(view, "#nodes-local-cap-warning")
      assert [%{node_id: nil, detail: %{"node" => "local"}}] = Nodes.events(kind: :updated)
    end

    test "a node's cap cannot be 0 or junk, and nothing is written", %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes")

      for bad <- ["0", "-1", "abc", "1.5"] do
        view |> form("#cap-form-#{node.id}", %{max_workers: bad}) |> render_submit()
        assert has_element?(view, "#cap-error-#{node.id}")
      end

      assert Nodes.get_node(node.id).max_workers == nil
      assert Nodes.events(kind: :updated) == []
    end
  end

  describe "row actions" do
    test "drain and undrain", %{conn: conn} do
      node = enroll!("alpha")
      connect!(node)
      {:ok, view, _} = live(conn, ~p"/nodes")

      view |> element("#drain-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :draining
      assert has_element?(view, "#node-#{node.id} [data-role=state]", "draining")

      view |> element("#undrain-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :active
      assert [_, _] = Nodes.events(kind: :drained)
    end

    test "revoke, then remove", %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes")

      refute has_element?(view, "#remove-#{node.id}")
      view |> element("#revoke-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :revoked
      assert [%{actor: "operator:dashboard"}] = Nodes.events(kind: :revoked)

      view |> element("#remove-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id) == nil
      refute has_element?(view, "#node-#{node.id}")
      assert [_] = Nodes.events(kind: :removed)
    end

    test "upgrade is offered only to a connected node that is behind", %{conn: conn} do
      old = enroll!("old")
      current = enroll!("current")
      connect!(old, %{"agent_version" => "1.0.0"})
      connect!(current)
      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#upgrade-#{old.id}")
      refute has_element?(view, "#upgrade-#{current.id}")
    end

    test "a change made elsewhere shows without a reload", %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes")

      {:ok, _} = Nodes.revoke(node, @operator)
      render(view)
      assert has_element?(view, "#node-#{node.id} [data-role=state]", "revoked")
    end
  end

  describe "Add node" do
    test "issues a token and shows the one-liner and the token separately", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      refute has_element?(view, "#add-node-modal")

      view |> element("#add-node-button") |> render_click()
      assert has_element?(view, "#add-node-modal")

      view
      |> form("#add-node-form", %{name: "gpu-1", max_workers: "2", ttl_minutes: "30"})
      |> render_submit()

      assert has_element?(view, "#join-command", "curl")
      assert has_element?(view, "#join-command", "#{@url}/nodes/join")
      assert has_element?(view, "#join-token", "arbj_")
      refute has_element?(view, "#join-command", "arbj_")
      assert has_element?(view, "#copy-join-command")
      assert has_element?(view, "#copy-join-token")
      assert has_element?(view, "#join-countdown")
      assert has_element?(view, "#join-status", "Waiting")

      assert [%{kind: :token_minted}] = Nodes.events(kind: :token_minted)
    end

    test "flips to Connected when the node enrolls", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()
      view |> form("#add-node-form", %{name: "joiner"}) |> render_submit()

      token =
        view
        |> element("#join-token")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()

      {:ok, %{node: node}} = Nodes.redeem_join_token(token)

      render(view)
      assert has_element?(view, "#join-status", "Connected")
      assert has_element?(view, "#node-#{node.id}")
    end

    test "closing the modal discards the secret", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()
      view |> form("#add-node-form", %{name: "joiner"}) |> render_submit()
      assert has_element?(view, "#join-token")

      view |> element("#add-node-close") |> render_click()
      refute has_element?(view, "#add-node-modal")
      refute has_element?(view, "#join-token")
      refute render(view) =~ "arbj_"
    end

    test "a bad name or ttl is reported and mints nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/nodes")
      view |> element("#add-node-button") |> render_click()

      view |> form("#add-node-form", %{name: "gpu box"}) |> render_submit()
      assert has_element?(view, "#add-node-error")
      view |> form("#add-node-form", %{name: "local"}) |> render_submit()
      assert has_element?(view, "#add-node-error")
      view |> form("#add-node-form", %{ttl_minutes: "0"}) |> render_submit()
      assert has_element?(view, "#add-node-error")

      assert Nodes.events(kind: :token_minted) == []
    end

    test "without nodes.public_url the button explains instead of minting", %{conn: conn} do
      {:ok, _} = Settings.set_nodes_public_url(nil)
      {:ok, view, _} = live(conn, ~p"/nodes")

      assert has_element?(view, "#nodes-public-url-missing")
      assert has_element?(view, "#add-node-button[disabled]")
    end
  end

  describe "detail" do
    test "shows the event timeline, live runs and the capacity breakdown", %{conn: conn} do
      node = enroll!("alpha", max_workers: 2)
      run_id = Ash.UUID.generate()

      connect!(node, %{
        "capacity" => %{"suggestion" => 4, "ceiling" => 3},
        "runs" => [%{"id" => run_id, "state" => "running"}]
      })

      {:ok, _} = Nodes.drain(node, @operator)

      {:ok, view, _} = live(conn, ~p"/nodes/#{node.id}")

      assert has_element?(view, "#node-detail")
      assert has_element?(view, "#node-events li", "enrolled")
      assert has_element?(view, "#node-events li", "drained")
      assert has_element?(view, "#node-live-runs", String.slice(run_id, 0, 8))
      assert has_element?(view, "#node-capacity", "suggested")
      assert has_element?(view, "#node-capacity", "3")
    end

    test "drain, revoke and remove work from the detail page; remove returns to the list",
         %{conn: conn} do
      node = enroll!("alpha")
      {:ok, view, _} = live(conn, ~p"/nodes/#{node.id}")

      view |> element("#drain-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :draining
      assert has_element?(view, "#node-events li", "drained")

      view |> element("#revoke-#{node.id}") |> render_click()
      assert Nodes.get_node(node.id).status == :revoked

      view |> element("#remove-#{node.id}") |> render_click()
      assert_redirect(view, ~p"/nodes")
      assert Nodes.get_node(node.id) == nil
    end

    test "an unknown node goes back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/nodes"}}} =
               live(conn, ~p"/nodes/#{Ash.UUID.generate()}")
    end
  end
end
