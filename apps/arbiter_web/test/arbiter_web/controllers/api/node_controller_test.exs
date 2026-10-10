defmodule ArbiterWeb.Api.NodeControllerTest do
  @moduledoc """
  `/api/nodes`: node administration over REST (`docs/design/remote-workers.md`
  §5.3, §5.6). Minting and editing are `:operator` (the human's own token);
  reads and the lifecycle verbs (drain, revoke, remove, upgrade) are
  `:operator` too. Backs `arb node`.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Nodes
  alias Arbiter.Nodes.RateLimit

  @operator Actor.operator("cli")
  @url "https://primary.example.ts.net"

  setup do
    {:ok, _} = Arbiter.Settings.set_nodes_public_url(@url)
    on_exit(fn -> Arbiter.Settings.set_nodes_public_url(nil) end)
    RateLimit.reset()
    :ok
  end

  defp as(scope_token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> scope_token)
    |> put_req_header("content-type", "application/json")
  end

  defp operator_conn, do: as(Scope.mint_coordinator(nil, operator: true))
  defp session_conn, do: as(Scope.mint_coordinator(nil))

  defp enroll!(name) do
    {:ok, %{token: t}} = Nodes.mint_join_token([], @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(t, %{name: name})
    node
  end

  describe "POST /api/nodes/join-tokens" do
    test "a name outside the join script's character set is a 422 and mints nothing" do
      for bad <- ["gpu box", "caf\u00e9", "a\nb"] do
        conn = post(operator_conn(), "/api/nodes/join-tokens", %{name: bad})
        assert conn.status == 422
      end

      assert Nodes.events(kind: :token_minted) == []
    end

    test "an operator mints a token and gets the one-liner separately" do
      conn = post(operator_conn(), "/api/nodes/join-tokens", %{name: "box-1", max_workers: 2})
      body = json_response(conn, 201)

      assert body["token"] =~ ~r/\Aarbj_[a-z2-7]{52}\z/

      assert body["one_liner"] ==
               "curl --proto '=https' --tlsv1.2 -fsSL #{@url}/nodes/join | ARB_JOIN_MODE=token bash"

      refute body["one_liner"] =~ body["token"]
      assert body["public_url"] == @url
      assert body["join_token"]["name"] == "box-1"
      assert body["join_token"]["max_workers"] == 2
      assert body["join_token"]["expires_at"]
      refute Map.has_key?(body["join_token"], "token_hash")

      assert [event] = Nodes.events(kind: :token_minted)
      assert event.actor == "operator:cli"
    end

    test "ttl_seconds is honoured and bounded" do
      ok =
        json_response(post(operator_conn(), "/api/nodes/join-tokens", %{ttl_seconds: 3600}), 201)

      assert_in_delta DateTime.diff(
                        elem(DateTime.from_iso8601(ok["join_token"]["expires_at"]), 1),
                        DateTime.utc_now()
                      ),
                      3600,
                      5

      conn = post(operator_conn(), "/api/nodes/join-tokens", %{ttl_seconds: 48 * 3600})
      assert json_response(conn, 422)["error"]["message"] =~ "ttl"
    end

    test "is refused (and mints nothing) until nodes.public_url is set" do
      {:ok, _} = Arbiter.Settings.set_nodes_public_url(nil)
      conn = post(operator_conn(), "/api/nodes/join-tokens", %{})
      assert json_response(conn, 422)["error"]["message"] =~ "nodes.public_url"
      assert Nodes.events(kind: :token_minted) == []
    end

    test "a coordinator session without operator proof is forbidden (403)" do
      conn = post(session_conn(), "/api/nodes/join-tokens", %{})
      assert json_response(conn, 403)
      assert Nodes.events(kind: :token_minted) == []
    end

    test "a worker token and anonymous callers are refused" do
      worker = as(Scope.mint_worker(%{id: "bd-x", workspace_id: "ws"}))
      assert post(worker, "/api/nodes/join-tokens", %{}).status in [401, 403]

      anon =
        Phoenix.ConnTest.build_conn()
        |> Map.put(:remote_ip, {127, 0, 0, 1})
        |> put_req_header("content-type", "application/json")

      assert post(anon, "/api/nodes/join-tokens", %{}).status == 401
    end

    test "is rate limited per actor (20/hour)" do
      statuses =
        for _ <- 1..21, do: post(operator_conn(), "/api/nodes/join-tokens", %{}).status

      assert Enum.take(statuses, 20) |> Enum.uniq() == [201]
      assert List.last(statuses) == 429
    end
  end

  describe "reads (operator)" do
    test "GET /api/nodes lists nodes without any credential material" do
      enroll!("alpha")
      enroll!("beta")

      body = json_response(get(operator_conn(), "/api/nodes"), 200)
      assert Enum.map(body["nodes"], & &1["name"]) == ["alpha", "beta"]

      raw = Jason.encode!(body)
      refute raw =~ "credential_hash"
      refute raw =~ "token_hash"
      assert hd(body["nodes"])["status"] == "active"
      assert hd(body["nodes"])["credential_prefix"]
    end

    test "GET /api/nodes/:ref finds by name or id; 404 otherwise" do
      node = enroll!("alpha")

      assert json_response(get(operator_conn(), "/api/nodes/alpha"), 200)["node"]["id"] ==
               node.id

      assert json_response(get(operator_conn(), "/api/nodes/#{node.id}"), 200)["node"]["name"] ==
               "alpha"

      assert get(operator_conn(), "/api/nodes/ghost").status == 404
    end

    test "GET /api/nodes/:ref/events returns the audit trail oldest first" do
      node = enroll!("alpha")
      {:ok, _} = Nodes.update_node(node, %{max_workers: 2}, @operator)

      body = json_response(get(operator_conn(), "/api/nodes/alpha/events"), 200)
      assert Enum.map(body["events"], & &1["kind"]) == ["enrolled", "updated"]
      assert hd(body["events"])["actor"] == "node:alpha"
      assert get(operator_conn(), "/api/nodes/ghost/events").status == 404
    end

    test "GET /api/nodes is operator-only: a coordinator session is refused" do
      enroll!("alpha")

      assert get(session_conn(), "/api/nodes").status == 403
      assert get(session_conn(), "/api/nodes/alpha").status == 403
      assert get(session_conn(), "/api/nodes/alpha/events").status == 403
      assert get(build_conn(), "/api/nodes").status == 401
    end

    test "the list carries the local row, the capacity sums and the endpoint's exposure" do
      enroll!("alpha")
      {:ok, _} = Arbiter.Settings.set_nodes_local_max_workers(6)
      on_exit(fn -> Arbiter.Settings.set_nodes_local_max_workers(nil) end)

      body = json_response(get(operator_conn(), "/api/nodes"), 200)

      assert %{"name" => "local", "kind" => "local", "state" => "online", "max" => 6} =
               body["local"]

      assert %{"total" => 6, "warnings" => []} = body
      refute Map.has_key?(body, "ceiling")
      refute Map.has_key?(body, "effective")
      assert body["public_url"] == @url
      assert body["exposure"] == "private"
      assert body["allow_public_endpoint"] == false
      assert [%{"name" => "alpha", "state" => "offline", "live" => 0}] = body["nodes"]
    end

    test "the list reports the image registry: unset by default, never the password (K8)" do
      body = json_response(get(operator_conn(), "/api/nodes"), 200)
      assert body["registry"] == %{"configured" => false}

      previous = Application.get_env(:arbiter, :image_publisher, [])

      Application.put_env(
        :arbiter,
        :image_publisher,
        Keyword.put(previous, :probe, fn _ -> :ok end)
      )

      on_exit(fn -> Application.put_env(:arbiter, :image_publisher, previous) end)

      {:ok, _} = Arbiter.Settings.Registry.put("nodes.registry", "registry.example.com/arb")
      {:ok, _} = Arbiter.Settings.Registry.put("nodes.registry_username", "bot")
      {:ok, _} = Arbiter.Settings.Registry.put("nodes.registry_password", "pw-NEVER-RENDERED")

      raw = response(get(operator_conn(), "/api/nodes"), 200)
      refute raw =~ "pw-NEVER-RENDERED"

      assert %{
               "configured" => true,
               "registry" => "registry.example.com/arb",
               "username" => "bot",
               "password_set" => true,
               "reachable" => true
             } = Jason.decode!(raw)["registry"]
    end

    test "a public endpoint is reported as such" do
      {:ok, _} = Arbiter.Settings.set_nodes_public_url("https://arbiter.example.com")
      assert json_response(get(operator_conn(), "/api/nodes"), 200)["exposure"] == "public"
    end

    test "a worker token cannot read nodes" do
      worker = as(Scope.mint_worker(%{id: "bd-x", workspace_id: "ws"}))
      assert get(worker, "/api/nodes").status == 403
    end
  end

  describe "PATCH /api/nodes/:ref workspace pin (RW8)" do
    test "sets and clears the node's workspace allowlist" do
      enroll!("alpha")

      body =
        json_response(patch(operator_conn(), "/api/nodes/alpha", %{workspace_ids: ["ws-1"]}), 200)

      assert body["node"]["workspace_ids"] == ["ws-1"]

      body = json_response(patch(operator_conn(), "/api/nodes/alpha", %{workspace_ids: []}), 200)
      assert body["node"]["workspace_ids"] == []
    end

    test "refuses anything that is not a list of ids" do
      enroll!("alpha")
      assert patch(operator_conn(), "/api/nodes/alpha", %{workspace_ids: "ws-1"}).status == 422
      assert patch(operator_conn(), "/api/nodes/alpha", %{workspace_ids: [1]}).status == 422
    end

    test "a node's cap reports what bound it" do
      node = enroll!("alpha")
      {:ok, _} = Nodes.update_node(node, %{max_workers: 8}, @operator)
      body = json_response(get(operator_conn(), "/api/nodes/alpha"), 200)
      assert body["node"]["max_workers"] == 8
      assert body["node"]["cap_source"] == "override"
    end
  end

  describe "GET /api/nodes/:ref cluster fields (A3, A7)" do
    test "a node that never connected is a machine with nothing degraded or pending" do
      enroll!("alpha")
      node = json_response(get(operator_conn(), "/api/nodes/alpha"), 200)["node"]

      assert %{"kind" => "machine", "degraded" => [], "pending" => 0, "constrained" => false} =
               node

      assert node["k8s_version"] == nil
      assert node["readiness"] == []
      assert node["upgrade_command"] == nil
    end

    test "the node list rows carry readiness and the unenforced-network override (K13)" do
      node = enroll!("alpha")
      {:ok, _} = Nodes.update_node(node, %{allow_unenforced_network: true}, @operator)

      body = json_response(get(operator_conn(), "/api/nodes"), 200)
      row = Enum.find(body["nodes"], &(&1["name"] == "alpha"))

      assert row["readiness"] == []
      assert row["allow_unenforced_network"] == true
    end

    test "a cluster node enrolled by its token is a cluster before it ever connects (K9)" do

      {:ok, %{token: t}} = Nodes.mint_join_token([name: "k3s", kind: "cluster"], @operator)
      {:ok, _} = Nodes.redeem_join_token(t, %{kind: "cluster"})

      node = json_response(get(operator_conn(), "/api/nodes/k3s"), 200)["node"]
      assert node["kind"] == "cluster"
      assert node["upgrade_command"] == nil
      assert node["self_upgrade"] == false
    end
  end

  describe "PATCH /api/nodes/:ref allow_unenforced_network (A7)" do
    test "the operator sets it, it is audited, and the node view reports it" do
      node = enroll!("alpha")

      assert json_response(get(operator_conn(), "/api/nodes/alpha"), 200)["node"][
               "allow_unenforced_network"
             ] == false

      body =
        json_response(
          patch(operator_conn(), "/api/nodes/alpha", %{allow_unenforced_network: true}),
          200
        )

      assert body["node"]["allow_unenforced_network"] == true
      assert [event] = Nodes.events(node_id: node.id, kind: :network_override)
      assert event.detail["allow_unenforced_network"] == true
    end

    test "only a boolean is accepted" do
      enroll!("alpha")

      for bad <- ["yes", 1, nil] do
        assert patch(operator_conn(), "/api/nodes/alpha", %{allow_unenforced_network: bad}).status ==
                 422
      end
    end

    test "a coordinator session may not set it (403) and nothing is audited" do
      node = enroll!("alpha")

      assert patch(session_conn(), "/api/nodes/alpha", %{allow_unenforced_network: true}).status ==
               403

      assert [] = Nodes.events(node_id: node.id, kind: :network_override)
    end
  end

  describe "PATCH /api/nodes/local" do
    test "sets the primary's cap, 0 included, and audits it" do
      conn = patch(operator_conn(), "/api/nodes/local", %{max_workers: 0})

      assert %{"node" => %{"name" => "local", "override" => 0, "max" => 0}} =
               json_response(conn, 200)

      assert Arbiter.Settings.nodes_local_max_workers() == 0
      assert [%{detail: %{"node" => "local"}}] = Nodes.events(kind: :updated)

      conn = patch(operator_conn(), "/api/nodes/local", %{max_workers: nil})
      assert %{"node" => %{"override" => nil}} = json_response(conn, 200)
    end

    test "takes nothing but max_workers, and refuses a negative one" do
      assert patch(operator_conn(), "/api/nodes/local", %{name: "x"}).status == 422
      assert patch(operator_conn(), "/api/nodes/local", %{max_workers: -1}).status == 422
      assert patch(operator_conn(), "/api/nodes/local", %{}).status == 422
      assert Arbiter.Settings.nodes_local_max_workers() == nil
    end

    test "a coordinator session may not (403)" do
      assert patch(session_conn(), "/api/nodes/local", %{max_workers: 0}).status == 403
      assert Arbiter.Settings.nodes_local_max_workers() == nil
    end
  end

  describe "lifecycle verbs" do
    test "drain and undrain flip the status and write drained events" do
      node = enroll!("alpha")

      conn = post(operator_conn(), "/api/nodes/alpha/drain", %{})
      assert json_response(conn, 200)["node"]["status"] == "draining"
      assert Nodes.get_node(node.id).status == :draining

      conn = post(operator_conn(), "/api/nodes/alpha/undrain", %{})
      assert json_response(conn, 200)["node"]["status"] == "active"

      assert [%{detail: %{"drain" => true}}, %{detail: %{"drain" => false}}] =
               Nodes.events(kind: :drained)
    end

    test "revoke clears the credential and writes a revoked event; remove then deletes the row" do
      node = enroll!("alpha")

      assert delete(operator_conn(), "/api/nodes/alpha").status == 409
      assert Nodes.get_node(node.id)

      conn = post(operator_conn(), "/api/nodes/alpha/revoke", %{})
      assert json_response(conn, 200)["node"]["status"] == "revoked"
      assert [%{node_id: id}] = Nodes.events(kind: :revoked)
      assert id == node.id

      assert delete(operator_conn(), "/api/nodes/alpha").status == 200
      assert Nodes.get_node(node.id) == nil
      assert [%{detail: %{"name" => "alpha"}}] = Nodes.events(kind: :removed)
    end

    test "a revoked node cannot be drained (409); unknown nodes are 404" do
      node = enroll!("alpha")
      {:ok, _} = Nodes.revoke(node, @operator)

      assert post(operator_conn(), "/api/nodes/alpha/drain", %{}).status == 409
      assert post(operator_conn(), "/api/nodes/ghost/drain", %{}).status == 404
      assert post(operator_conn(), "/api/nodes/ghost/revoke", %{}).status == 404
      assert delete(operator_conn(), "/api/nodes/ghost").status == 404
    end

    test "upgrade of a node that is not connected is a 409 and writes nothing" do
      enroll!("alpha")
      assert post(operator_conn(), "/api/nodes/alpha/upgrade", %{}).status == 409
      assert Nodes.events(kind: :upgraded) == []
    end

    test "a coordinator session may do none of them (403) and nothing changes" do
      node = enroll!("alpha")

      for verb <- ["drain", "undrain", "revoke", "upgrade"] do
        assert post(session_conn(), "/api/nodes/alpha/#{verb}", %{}).status == 403
      end

      assert delete(session_conn(), "/api/nodes/alpha").status == 403
      assert Nodes.get_node(node.id).status == :active
    end
  end

  describe "PATCH /api/nodes/:ref" do
    test "an operator edits labels and max_workers" do
      enroll!("alpha")

      conn = patch(operator_conn(), "/api/nodes/alpha", %{labels: ["zone=a"], max_workers: 4})
      body = json_response(conn, 200)["node"]
      assert body["labels"] == ["zone=a"]
      assert body["max_workers"] == 4
    end

    test "a coordinator session may not (403) and the node is unchanged" do
      node = enroll!("alpha")
      conn = patch(session_conn(), "/api/nodes/alpha", %{max_workers: 9})
      assert json_response(conn, 403)
      assert Nodes.get_node(node.id).max_workers == nil
    end

    test "validation and conflicts are reported" do
      enroll!("alpha")
      enroll!("beta")

      assert patch(operator_conn(), "/api/nodes/alpha", %{max_workers: 0}).status == 422
      assert patch(operator_conn(), "/api/nodes/alpha", %{name: "beta"}).status == 409
      assert patch(operator_conn(), "/api/nodes/ghost", %{max_workers: 1}).status == 404
      assert patch(operator_conn(), "/api/nodes/alpha", %{labels: "nope"}).status == 422
      assert patch(operator_conn(), "/api/nodes/alpha", %{name: "gpu box"}).status == 422
      assert Nodes.find_node("alpha")
    end

    test "a revoked node is not editable (409)" do
      node = enroll!("alpha")
      {:ok, _} = Nodes.revoke(node, @operator)
      assert patch(operator_conn(), "/api/nodes/alpha", %{max_workers: 1}).status == 409
    end
  end
end
