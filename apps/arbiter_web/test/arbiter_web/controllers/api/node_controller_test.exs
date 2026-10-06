defmodule ArbiterWeb.Api.NodeControllerTest do
  @moduledoc """
  `/api/nodes`: node administration over REST (`docs/design/remote-workers.md`
  §5.3, §5.6). Minting and editing are `:operator` (the human's own token);
  reads are `:coordinator`. Backs `arb node`.
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
               "curl --proto '=https' --tlsv1.2 -fsSL #{@url}/nodes/join | bash"

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

  describe "reads (coordinator)" do
    test "GET /api/nodes lists nodes without any credential material" do
      enroll!("alpha")
      enroll!("beta")

      body = json_response(get(session_conn(), "/api/nodes"), 200)
      assert Enum.map(body["nodes"], & &1["name"]) == ["alpha", "beta"]

      raw = Jason.encode!(body)
      refute raw =~ "credential_hash"
      refute raw =~ "token_hash"
      assert hd(body["nodes"])["status"] == "active"
      assert hd(body["nodes"])["credential_prefix"]
    end

    test "GET /api/nodes/:ref finds by name or id; 404 otherwise" do
      node = enroll!("alpha")

      assert json_response(get(session_conn(), "/api/nodes/alpha"), 200)["node"]["id"] == node.id

      assert json_response(get(session_conn(), "/api/nodes/#{node.id}"), 200)["node"]["name"] ==
               "alpha"

      assert get(session_conn(), "/api/nodes/ghost").status == 404
    end

    test "GET /api/nodes/:ref/events returns the audit trail oldest first" do
      node = enroll!("alpha")
      {:ok, _} = Nodes.update_node(node, %{max_workers: 2}, @operator)

      body = json_response(get(session_conn(), "/api/nodes/alpha/events"), 200)
      assert Enum.map(body["events"], & &1["kind"]) == ["enrolled", "updated"]
      assert hd(body["events"])["actor"] == "node:alpha"
      assert get(session_conn(), "/api/nodes/ghost/events").status == 404
    end

    test "a worker token cannot read nodes" do
      worker = as(Scope.mint_worker(%{id: "bd-x", workspace_id: "ws"}))
      assert get(worker, "/api/nodes").status == 403
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
