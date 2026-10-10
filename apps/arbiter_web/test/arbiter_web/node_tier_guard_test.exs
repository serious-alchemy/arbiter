defmodule ArbiterWeb.NodeTierGuardTest do
  @moduledoc """
  RW3 cross-tier guard (`docs/design/remote-workers.md` §5.3, §15.4). The node
  tier is structurally separate from the `Arbiter.MCP.Scope` tiers, and these
  tests fail the build if any route ever accepts the wrong one:

    * a node credential is refused (401) by **every** `/api` route (any verb),
      by `/mcp` and by `/events`;
    * every route in the node namespace (`/nodes/*`, `/node/*`) refuses each
      `Scope` tier's token, except routes explicitly listed as anonymous;
    * a join token opens nothing, and a node credential cannot enroll.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Nodes

  @operator Actor.operator("cli")

  # The node-namespace routes that are deliberately reachable without a node
  # credential (the join script, enrolment with a join token in the body, the
  # reachability ping). `NodeJoinTest` covers what each of them does.
  @anonymous_node_routes [
    "get /nodes/join",
    "get /nodes/join/k8s.yaml",
    "get /nodes/ping",
    "post /nodes/enroll",
    "post /nodes/pair",
    "post /nodes/pair/poll"
  ]

  @moduletag :tmp_dir

  # `/nodes/*` and `/node/*` minus the operator's own pages: `/nodes` and
  # `/nodes/:id` (RW7's `NodesLive`) are dashboard LiveViews behind
  # `:dashboard_auth`, a different tier by design, not node-credential routes.
  defp node_namespace?(r) do
    (String.starts_with?(r.path, "/nodes") or String.starts_with?(r.path, "/node/")) and
      r.plug != Phoenix.LiveView.Plug
  end

  setup %{tmp_dir: home} do
    # Enrolment answers 503 until the primary has a public URL and an agent
    # build to hand out, which would hide the 401 these tests are after.
    {:ok, _} = Arbiter.Settings.set_nodes_public_url("https://primary.example.ts.net")
    on_exit(fn -> Arbiter.Settings.set_nodes_public_url(nil) end)
    ArbiterWeb.NodeFixtures.use_data_home!(home)
    ArbiterWeb.NodeFixtures.install_release!(home)
    Arbiter.Nodes.RateLimit.reset()

    {:ok, %{token: token}} = Nodes.mint_join_token([], @operator)

    {:ok, %{node: node, credential: credential}} =
      Nodes.redeem_join_token(token, %{name: "guard-box"})

    {:ok, %{token: join_token}} = Nodes.mint_join_token([], @operator)
    {:ok, node: node, credential: credential, join_token: join_token}
  end

  defp routes, do: ArbiterWeb.Router.__routes__()

  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", fn
      ":" <> _ -> "bd-nonexistent"
      "*" <> _ -> "x"
      seg -> seg
    end)
  end

  defp present(token, method, path, body \\ "{}") do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Phoenix.ConnTest.dispatch(@endpoint, method, path, body)
  end

  describe "a node credential" do
    test "is refused (401) by every /api route, on every verb", %{credential: credential} do
      api = Enum.filter(routes(), &String.starts_with?(&1.path, "/api/"))
      assert length(api) > 50, "the router walk found suspiciously few /api routes"

      accepted =
        for route <- api,
            conn = present(credential, route.verb, concrete(route.path)),
            conn.status != 401,
            do: {route.verb, route.path, conn.status}

      assert accepted == [], "node credential not refused by: #{inspect(accepted)}"
    end

    test "is refused even on the anonymous /api routes (a presented bad token is never downgraded)",
         %{credential: credential} do
      for path <- ["/api/version", "/api/server/migrations"] do
        assert present(credential, :get, path).status == 401, path
      end
    end

    test "is refused (401) by /mcp: JSON-RPC POST and the SSE GET", %{credential: credential} do
      body = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})

      assert present(credential, :post, "/mcp", body).status == 401

      sse =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("accept", "text/event-stream")
        |> put_req_header("authorization", "Bearer #{credential}")
        |> get("/mcp")

      assert sse.status == 401
    end

    test "gets no 2xx from /mcp on any other verb either", %{credential: credential} do
      # `MCP.Plug` answers 405 to everything but the POST and the SSE GET, before
      # looking at a credential; the point is that none of them succeeds.
      for verb <- [:get, :put, :patch, :delete] do
        assert present(credential, verb, "/mcp").status in [401, 405], "#{verb} /mcp"
      end
    end

    test "is refused (401) by /events as a bearer header and as ?token=", %{
      credential: credential
    } do
      assert present(credential, :get, "/events").status == 401

      conn =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> get("/events?token=#{credential}")

      assert conn.status == 401
    end

    test "gets no new authority from a revoked or rotated state either",
         %{node: node, credential: credential} do
      {:ok, _} = Nodes.rotate_credential(node, @operator)
      assert present(credential, :get, "/api/issues").status == 401
      {:ok, _} = Nodes.revoke(Nodes.get_node(node.id), @operator)
      assert present(credential, :get, "/api/issues").status == 401
    end

    test "can reach nothing on the dashboard either", %{credential: credential} do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Bearer #{credential}")
        |> get("/")

      assert conn.status in [302, 401, 403]
      refute conn.status == 200
    end
  end

  describe "the node namespace" do
    setup do
      node_routes =
        Enum.filter(routes(), &node_namespace?/1)
        |> Enum.reject(&("#{&1.verb} #{&1.path}" in @anonymous_node_routes))

      {:ok, node_routes: node_routes}
    end

    test "refuses every Scope tier's token and a join token with 401", ctx do
      tokens = [
        coordinator: Scope.mint_coordinator(nil),
        operator: Scope.mint_coordinator(nil, operator: true),
        worker: Scope.mint_worker(%{id: "bd-x", workspace_id: "ws-1"}),
        refine: Scope.mint_refine("sess-1", "ws-1", "bd-x"),
        join_token: ctx.join_token
      ]

      admitted =
        for route <- ctx.node_routes,
            {tier, token} <- tokens,
            conn = present(token, route.verb, concrete(route.path)),
            conn.status != 401,
            do: {tier, route.verb, route.path, conn.status}

      assert admitted == [], "node route admitted the wrong tier: #{inspect(admitted)}"
    end

    test "refuses a request with no credential at all", ctx do
      for route <- ctx.node_routes do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Map.put(:remote_ip, {127, 0, 0, 1})
          |> put_req_header("accept", "application/json")
          |> Phoenix.ConnTest.dispatch(@endpoint, route.verb, concrete(route.path), nil)

        assert conn.status == 401, "#{route.verb} #{route.path} answered #{conn.status}"
      end
    end

    test "the anonymous routes are exactly the join script, the ping and enrolment" do
      anon =
        for r <- routes(),
            node_namespace?(r),
            "#{r.verb} #{r.path}" in @anonymous_node_routes,
            do: "#{r.verb} #{r.path}"

      assert Enum.sort(anon) == Enum.sort(@anonymous_node_routes)
    end

    test "a node credential cannot enroll: it is not a join token", ctx do
      conn =
        present(ctx.credential, :post, "/nodes/enroll", Jason.encode!(%{token: ctx.credential}))

      assert conn.status == 401
      assert length(Nodes.list_nodes()) == 1
    end

    test "a Scope token in the enroll body is not a join token either" do
      token = Scope.mint_coordinator(nil, operator: true)
      conn = present("", :post, "/nodes/enroll", Jason.encode!(%{token: token}))
      assert conn.status == 401
    end

    test "a jailed worker's bridge cannot reach it: /nodes is not on the bridge allowlist" do
      # `WorkerBridge` admits only `/api` and `/mcp` prefixes; this pins that
      # `/nodes` and `/node` stay outside them.
      for prefix <- ["nodes", "node"] do
        refute prefix in ["api", "mcp"]
      end

      source = File.read!(Path.expand("../../lib/arbiter_web/plugs/worker_bridge.ex", __DIR__))
      assert source =~ ~s(@allowed_prefixes ["api", "mcp"])
    end
  end
end
