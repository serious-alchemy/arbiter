defmodule ArbiterWeb.NodeClusterJoinTest do
  @moduledoc """
  K9 (bd-6ez9yn, `docs/design/remote-workers.md` K§2.1–K§2.2): the cluster half of the
  join flow. `GET /nodes/join/k8s.yaml` renders the install manifests anonymously and
  without a secret; `POST /nodes/enroll` accepts `kind: cluster`; the operator API mints a
  cluster token and returns the manifest URL and join-Secret command.
  """
  use ArbiterWeb.ConnCase, async: false

  import ArbiterWeb.NodeFixtures

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Nodes
  alias Arbiter.Nodes.RateLimit

  @moduletag :tmp_dir
  @operator Actor.operator("cli")
  @url "https://primary.example.ts.net"
  @registry "registry.example.test/arbiter"

  setup %{tmp_dir: home} do
    {:ok, _} = Arbiter.Settings.set_nodes_public_url(@url)
    {:ok, _} = Arbiter.Settings.set_nodes_registry(@registry)

    on_exit(fn ->
      Arbiter.Settings.set_nodes_public_url(nil)
      Arbiter.Settings.set_nodes_registry(nil)
    end)

    RateLimit.reset()
    use_data_home!(home)
    {:ok, release: install_release!(home)}
  end

  defp raw(method, path, opts \\ []) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, Keyword.get(opts, :peer, {127, 0, 0, 1}))
    |> then(fn c ->
      Enum.reduce(Keyword.get(opts, :headers, []), c, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)
    end)
    |> Phoenix.ConnTest.dispatch(@endpoint, method, path, Keyword.get(opts, :body))
  end

  defp operator_conn do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> Scope.mint_coordinator(nil, operator: true))
    |> put_req_header("content-type", "application/json")
  end

  defp enroll(token, extra) do
    raw(:post, "/nodes/enroll",
      body: Jason.encode!(Map.merge(%{"token" => token}, extra)),
      headers: [{"content-type", "application/json"}, {"accept", "application/json"}]
    )
  end

  describe "GET /nodes/join/k8s.yaml" do
    test "is anonymous and renders both documents, pinned to this server's controller image",
         %{release: release} do
      conn = raw(:get, "/nodes/join/k8s.yaml?name=mesaana-k3s&max=3")

      assert conn.status == 200
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "yaml"

      docs = YamlElixir.read_all_from_string!(conn.resp_body)
      kinds = Enum.map(docs, & &1["kind"])
      assert "Namespace" in kinds
      assert List.last(kinds) == "Deployment"

      deployment = List.last(docs)
      [controller] = deployment["spec"]["template"]["spec"]["containers"]
      assert controller["image"] == "#{@registry}/controller:#{release.tag}"
      env = Map.new(controller["env"], &{&1["name"], &1["value"]})
      assert env["ARB_PRIMARY_URL"] == @url
      assert env["ARB_NODE_NAME"] == "mesaana-k3s"
    end

    test "carries no secret, even when the request offers one" do
      token = elem(Nodes.mint_join_token([kind: "cluster"], @operator), 1).token

      conn =
        raw(
          :get,
          "/nodes/join/k8s.yaml?name=n&token=#{token}&credential=arbn_x&reach=tailscale&admission=policy"
        )

      assert conn.status == 200
      refute conn.resp_body =~ token
      refute conn.resp_body =~ "arbj_"
      refute conn.resp_body =~ "arbn_"
      refute conn.resp_body =~ "PRIVATE KEY"
      assert conn.resp_body =~ "ValidatingAdmissionPolicy"
      assert conn.resp_body =~ "tailscale"
    end

    test "?part= serves one half" do
      bootstrap = raw(:get, "/nodes/join/k8s.yaml?name=n&part=bootstrap").resp_body
      node = raw(:get, "/nodes/join/k8s.yaml?name=n&part=node").resp_body
      refute bootstrap =~ "kind: Deployment"
      assert node =~ "kind: Deployment"
      refute node =~ "kind: Namespace"
    end

    test "a bad value is a 422 naming the field; nothing is rendered" do
      conn = raw(:get, "/nodes/join/k8s.yaml?name=n&max=0&namespace=Bad_NS")
      assert conn.status == 422
      assert conn.resp_body =~ "max"
      assert conn.resp_body =~ "namespace"
      refute conn.resp_body =~ "kind: Deployment"
    end

    test "a missing name is a 422" do
      assert raw(:get, "/nodes/join/k8s.yaml").status == 422
    end

    test "is unavailable until nodes.public_url and nodes.registry are set" do
      {:ok, _} = Arbiter.Settings.set_nodes_registry(nil)
      conn = raw(:get, "/nodes/join/k8s.yaml?name=n")
      assert conn.status == 503
      assert conn.resp_body =~ "nodes.registry"

      {:ok, _} = Arbiter.Settings.set_nodes_public_url(nil)
      conn = raw(:get, "/nodes/join/k8s.yaml?name=n")
      assert conn.status == 503
      assert conn.resp_body =~ "nodes.public_url"
    end
  end

  describe "POST /nodes/enroll with kind: cluster" do
    test "a cluster token and `kind: cluster` enrol a cluster node" do
      {:ok, %{token: token}} = Nodes.mint_join_token([kind: "cluster", name: "k3s"], @operator)

      conn = enroll(token, %{"kind" => "cluster", "k8s_version" => "v1.36.5+k3s1", "proto" => 1})
      assert conn.status == 200
      resp = Jason.decode!(conn.resp_body)

      assert resp["name"] == "k3s"
      assert resp["kind"] == "cluster"
      assert resp["credential"] =~ ~r/\Aarbn_/
      assert resp["ws_url"] == "wss://primary.example.ts.net/node/socket"
      assert Nodes.get_node(resp["node_id"]).kind == "cluster"
    end

    test "a cluster enrolment does not need the tarball the primary serves to machines",
         %{tmp_dir: _} do
      empty = Path.join(System.tmp_dir!(), "arb-empty-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      use_data_home!(empty)
      on_exit(fn -> File.rm_rf(empty) end)

      {:ok, %{token: token}} = Nodes.mint_join_token([kind: "cluster"], @operator)
      conn = enroll(token, %{"kind" => "cluster"})
      assert conn.status == 200
      refute Map.has_key?(Jason.decode!(conn.resp_body), "tarball_sha256")
    end

    test "a machine token with `kind: cluster` is a 422 and is not spent" do
      {:ok, %{token: token}} = Nodes.mint_join_token([], @operator)
      conn = enroll(token, %{"kind" => "cluster"})
      assert conn.status == 422
      assert conn.resp_body =~ "kind"
      assert enroll(token, %{"name" => "m"}).status == 200
    end

    test "a cluster token without `kind: cluster` is a 422 and is not spent" do
      {:ok, %{token: token}} = Nodes.mint_join_token([kind: "cluster"], @operator)
      assert enroll(token, %{"name" => "x"}).status == 422
      assert enroll(token, %{"name" => "x", "kind" => "cluster"}).status == 200
    end
  end

  describe "POST /api/nodes/join-tokens with kind: cluster" do
    test "mints a cluster token and returns the manifest URL and the join-Secret command",
         %{release: release} do
      conn =
        post(operator_conn(), "/api/nodes/join-tokens", %{
          kind: "cluster",
          name: "mesaana-k3s",
          namespace: "ci-workers",
          max_workers: 3,
          reach: "tailscale"
        })

      body = json_response(conn, 201)
      assert body["token"] =~ ~r/\Aarbj_/
      assert body["join_token"]["kind"] == "cluster"
      assert body["join_token"]["name"] == "mesaana-k3s"
      assert body["join_token"]["max_workers"] == 3

      cluster = body["cluster"]

      assert cluster["manifest_url"] ==
               "#{@url}/nodes/join/k8s.yaml?name=mesaana-k3s&namespace=ci-workers&max=3&reach=tailscale"

      assert cluster["apply_command"] =~ cluster["manifest_url"]
      assert cluster["secret_command"] =~ "read -rs T"
      assert cluster["secret_command"] =~ "-n ci-workers create secret generic arbiter-join"
      assert cluster["image"] == "#{@registry}/controller:#{release.tag}"

      # The secret never travels in anything the operator pastes.
      for {key, value} <- cluster, is_binary(value), do: refute(value =~ body["token"], key)
      refute Map.has_key?(body, "one_liner") and body["one_liner"] =~ body["token"]

      {:ok, %{node: node}} =
        Nodes.redeem_join_token(body["token"], %{kind: "cluster"})

      assert node.kind == "cluster" and node.name == "mesaana-k3s"
    end

    test "a cluster token needs a name (the manifest and the node must agree on it)" do
      conn = post(operator_conn(), "/api/nodes/join-tokens", %{kind: "cluster"})
      assert json_response(conn, 422)["error"]["message"] =~ "name"
      assert Nodes.events(kind: :token_minted) == []
    end

    test "is refused, and mints nothing, without nodes.registry" do
      {:ok, _} = Arbiter.Settings.set_nodes_registry(nil)
      conn = post(operator_conn(), "/api/nodes/join-tokens", %{kind: "cluster", name: "k3s"})
      assert json_response(conn, 422)["error"]["message"] =~ "nodes.registry"
      assert Nodes.events(kind: :token_minted) == []
    end

    test "a value the renderer refuses is a 422 and mints nothing" do
      conn =
        post(operator_conn(), "/api/nodes/join-tokens", %{
          kind: "cluster",
          name: "k3s",
          max_workers: 1000
        })

      assert json_response(conn, 422)["error"]["message"] =~ "max"
      assert Nodes.events(kind: :token_minted) == []
    end

    test "an unknown kind is a 422" do
      conn = post(operator_conn(), "/api/nodes/join-tokens", %{kind: "mainframe"})
      assert json_response(conn, 422)["error"]["message"] =~ "kind"
    end

    test "a machine token response is unchanged: no cluster block" do
      body = json_response(post(operator_conn(), "/api/nodes/join-tokens", %{name: "box"}), 201)
      refute Map.has_key?(body, "cluster")
      assert body["join_token"]["kind"] == "machine"
    end
  end
end
