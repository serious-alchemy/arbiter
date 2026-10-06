defmodule ArbiterWeb.NodeJoinTest do
  @moduledoc """
  The server side of the join flow (`docs/design/remote-workers.md` §5.2,
  §5.4, §5.5, §6): the script, enrolment, ping and the credential-gated agent
  download.
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

  setup %{tmp_dir: home} do
    {:ok, _} = Arbiter.Settings.set_nodes_public_url(@url)
    on_exit(fn -> Arbiter.Settings.set_nodes_public_url(nil) end)
    RateLimit.reset()
    use_data_home!(home)
    release = install_release!(home)
    {:ok, release: release}
  end

  defp mint, do: elem(Nodes.mint_join_token([], @operator), 1).token

  defp raw(method, path, opts \\ []) do
    body = Keyword.get(opts, :body)

    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, Keyword.get(opts, :peer, {127, 0, 0, 1}))
    |> then(fn c ->
      Enum.reduce(Keyword.get(opts, :headers, []), c, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)
    end)
    |> Phoenix.ConnTest.dispatch(@endpoint, method, path, body)
  end

  defp enroll(token, opts \\ []) do
    body = Jason.encode!(Map.merge(%{"token" => token}, Keyword.get(opts, :extra, %{})))

    raw(
      :post,
      "/nodes/enroll",
      body: body,
      peer: Keyword.get(opts, :peer, {127, 0, 0, 1}),
      headers:
        [{"content-type", "application/json"}, {"accept", "application/json"}] ++
          Keyword.get(opts, :headers, [])
    )
  end

  defp enrolled!(extra \\ %{}) do
    conn = enroll(mint(), extra: extra)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  describe "GET /nodes/join" do
    test "is anonymous and serves the rendered script" do
      conn = raw(:get, "/nodes/join")

      assert conn.status == 200
      assert [type] = get_resp_header(conn, "content-type")
      assert type =~ "text/x-shellscript"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert conn.resp_body =~ "ARB_PRIMARY_URL='#{@url}'"
      assert conn.resp_body |> String.trim_trailing() |> String.ends_with?(~s(main "$@"))
    end

    test "is unavailable until nodes.public_url is set" do
      {:ok, _} = Arbiter.Settings.set_nodes_public_url(nil)
      conn = raw(:get, "/nodes/join")
      assert conn.status == 503
      assert conn.resp_body =~ "nodes.public_url"
      refute conn.resp_body =~ "main()"
    end
  end

  describe "GET /nodes/ping" do
    test "answers pong with no credential" do
      conn = raw(:get, "/nodes/ping")
      assert conn.status == 200
      assert conn.resp_body == "pong"
    end
  end

  describe "POST /nodes/enroll" do
    test "swaps a valid token for a credential, the agent version and its sha256",
         %{release: release} do
      resp = enrolled!(%{"name" => "box-1", "labels" => ["zone=a"], "max_workers" => 2})

      assert resp["credential"] =~ ~r/\Aarbn_[0-9a-f-]{36}\.[a-z2-7]{52}\z/
      assert resp["agent_version"] == release.tag
      assert resp["tarball_sha256"] == release.sha256
      assert resp["name"] == "box-1"
      assert resp["ws_url"] == "wss://primary.example.ts.net/node/socket"
      refute Map.has_key?(resp, "credential_hash")

      node = Nodes.get_node(resp["node_id"])
      assert node.labels == ["zone=a"]
      assert node.max_workers == 2
      assert {:ok, _} = Nodes.authenticate(resp["credential"])

      assert [event] = Nodes.events(kind: :enrolled)
      assert event.node_id == node.id
      assert event.remote_addr_hint == "127.0.0.1"
    end

    test "is single use: the second exchange of one token is a generic 401" do
      token = mint()
      assert enroll(token).status == 200

      conn = enroll(token)
      assert conn.status == 401
      assert [%{detail: %{"reason" => "invalid_token"}}] = Nodes.events(kind: :join_failed)
      assert length(Nodes.list_nodes()) == 1
    end

    test "unknown, used and expired tokens are indistinguishable" do
      used = mint()
      assert enroll(used).status == 200

      {:ok, %{token: expired}} = Nodes.mint_join_token([ttl_seconds: 60], @operator)

      Arbiter.Repo.query!(
        "UPDATE join_tokens SET expires_at = '2000-01-01 00:00:00.000000' WHERE token_hash = ?",
        [Arbiter.Nodes.Credentials.hash(expired)]
      )

      bodies =
        for token <- [used, expired, "arbj_" <> String.duplicate("a", 52), "garbage", ""] do
          conn = enroll(token)
          assert conn.status == 401
          conn.resp_body
        end

      assert bodies |> Enum.uniq() |> length() == 1
    end

    test "the token is read from the body only, never a header or the query string" do
      token = mint()

      via_header =
        raw(:post, "/nodes/enroll",
          body: "{}",
          headers: [{"content-type", "application/json"}, {"authorization", "Bearer #{token}"}]
        )

      via_query =
        raw(:post, "/nodes/enroll?token=#{token}",
          body: "{}",
          headers: [{"content-type", "application/json"}]
        )

      assert via_header.status == 401
      assert via_query.status == 401
      # and the token is still good
      assert enroll(token).status == 200
    end

    test "a name clash is a 409 and does not spend the token" do
      assert enroll(mint(), extra: %{"name" => "dup"}).status == 200
      token = mint()
      assert enroll(token, extra: %{"name" => "dup"}).status == 409
      assert enroll(token, extra: %{"name" => "other"}).status == 200
    end

    test "an invalid joiner-supplied name is a 422 and does not spend the token" do
      token = mint()
      assert enroll(token, extra: %{"name" => "gpu box"}).status == 422
      assert Nodes.list_nodes() == []
      assert enroll(token, extra: %{"name" => "gpu-box"}).status == 200
    end

    test "with no agent build to serve it refuses and does not spend the token",
         %{tmp_dir: home} do
      File.rm!(Path.join(home, "current"))
      token = mint()
      conn = enroll(token)
      assert conn.status == 503
      assert Nodes.list_nodes() == []
    end

    test "Accept: text/plain answers shell-safe KEY=value lines for the join script",
         %{release: release} do
      conn =
        raw(:post, "/nodes/enroll",
          body: Jason.encode!(%{"token" => mint()}),
          headers: [{"content-type", "application/json"}, {"accept", "text/plain"}]
        )

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "text/plain"

      pairs =
        conn.resp_body
        |> String.split("\n", trim: true)
        |> Map.new(fn line -> line |> String.split("=", parts: 2) |> List.to_tuple() end)

      assert pairs["agent_version"] == release.tag
      assert pairs["tarball_sha256"] == release.sha256
      assert pairs["credential"] =~ "arbn_"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "is rate limited per source after repeated failures, with Retry-After" do
      for _ <- 1..5, do: assert(enroll("arbj_" <> String.duplicate("b", 52)).status == 401)

      blocked = enroll(mint())
      assert blocked.status == 429
      assert [retry] = get_resp_header(blocked, "retry-after")
      assert String.to_integer(retry) >= 1
    end

    test "the global attempt cap answers 429 too" do
      statuses = for _ <- 1..11, do: enroll("garbage").status
      assert List.last(statuses) == 429
    end

    test "behind a loopback proxy the source is X-Forwarded-For; each source has its own budget" do
      bad = "arbj_" <> String.duplicate("c", 52)
      hdr = fn ip -> [{"x-forwarded-for", ip}] end

      for _ <- 1..5, do: enroll(bad, headers: hdr.("100.64.0.9"))
      assert enroll(mint(), headers: hdr.("100.64.0.9")).status == 429
      assert enroll(mint(), headers: hdr.("100.64.0.10")).status == 200
      assert [%{remote_addr_hint: "100.64.0.10"}] = Nodes.events(kind: :enrolled)
    end

    test "from a non-loopback peer X-Forwarded-For is ignored (it cannot pick its own bucket)" do
      bad = "arbj_" <> String.duplicate("d", 52)

      for n <- 1..5,
          do: enroll(bad, peer: {100, 64, 0, 7}, headers: [{"x-forwarded-for", "10.0.0.#{n}"}])

      assert enroll(mint(), peer: {100, 64, 0, 7}, headers: [{"x-forwarded-for", "10.9.9.9"}]).status ==
               429
    end
  end

  describe "GET /nodes/agent/<version>.tar.gz" do
    test "needs a node credential", %{release: release} do
      path = "/nodes/agent/#{release.tag}.tar.gz"
      assert raw(:get, path).status == 401

      for token <- [
            Scope.mint_coordinator(nil, operator: true),
            Scope.mint_worker(%{id: "bd-x", workspace_id: "ws"}),
            mint()
          ] do
        assert raw(:get, path, headers: [{"authorization", "Bearer #{token}"}]).status == 401
      end
    end

    test "serves the retained bytes; their sha256 is the one enroll reported", %{release: release} do
      resp = enrolled!()
      cred = resp["credential"]

      conn =
        raw(:get, "/nodes/agent/#{resp["agent_version"]}.tar.gz",
          headers: [{"authorization", "Bearer #{cred}"}]
        )

      assert conn.status == 200
      assert hd(get_resp_header(conn, "content-type")) =~ "gzip"

      assert :crypto.hash(:sha256, conn.resp_body) |> Base.encode16(case: :lower) ==
               resp["tarball_sha256"]

      assert conn.resp_body == File.read!(release.tarball)
    end

    test "another version is a 404", %{release: _} do
      resp = enrolled!()

      conn =
        raw(:get, "/nodes/agent/v0.0.1.tar.gz",
          headers: [{"authorization", "Bearer #{resp["credential"]}"}]
        )

      assert conn.status == 404
    end

    test "a revoked node is refused" do
      resp = enrolled!()
      {:ok, _} = Nodes.revoke(Nodes.get_node(resp["node_id"]), @operator)

      conn =
        raw(:get, "/nodes/agent/#{resp["agent_version"]}.tar.gz",
          headers: [{"authorization", "Bearer #{resp["credential"]}"}]
        )

      assert conn.status == 401
    end
  end

  describe "GET /nodes/files/:sha" do
    test "serves the artifact by content hash, to a node credential only", %{release: release} do
      resp = enrolled!()
      path = "/nodes/files/#{release.sha256}"

      assert raw(:get, path).status == 401

      conn = raw(:get, path, headers: [{"authorization", "Bearer #{resp["credential"]}"}])
      assert conn.status == 200
      assert conn.resp_body == File.read!(release.tarball)
    end

    test "an unknown or malformed hash is a 404" do
      resp = enrolled!()
      auth = [{"authorization", "Bearer #{resp["credential"]}"}]

      assert raw(:get, "/nodes/files/#{String.duplicate("0", 64)}", headers: auth).status == 404
      assert raw(:get, "/nodes/files/..%2F..%2Fetc%2Fpasswd", headers: auth).status == 404
      assert raw(:get, "/nodes/files/short", headers: auth).status == 404
    end
  end
end
