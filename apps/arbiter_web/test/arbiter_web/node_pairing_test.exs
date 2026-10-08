defmodule ArbiterWeb.NodePairingTest do
  @moduledoc """
  The node's side of device-code pairing (`docs/design/remote-workers.md`
  §5.7): `GET /join`, `POST /nodes/pair` and `POST /nodes/pair/poll`. The
  operator's side is `ArbiterWeb.Api.NodePairingTest`.
  """
  use ArbiterWeb.ConnCase, async: false

  import ArbiterWeb.NodeFixtures

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Pairing, RateLimit}

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

  defp post_json(path, body, opts \\ []) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, Keyword.get(opts, :peer, {100, 64, 0, 7}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", Keyword.get(opts, :accept, "application/json"))
    |> then(fn c ->
      Enum.reduce(Keyword.get(opts, :headers, []), c, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)
    end)
    |> Phoenix.ConnTest.dispatch(@endpoint, :post, path, Jason.encode!(body))
  end

  defp pair(body \\ %{"hostname" => "laptop"}, opts \\ []),
    do: post_json("/nodes/pair", body, opts)

  defp pair!(body \\ %{"hostname" => "laptop"}) do
    conn = pair(body)
    assert conn.status == 201
    Jason.decode!(conn.resp_body)
  end

  defp poll(resp, opts \\ []),
    do: post_json("/nodes/pair/poll", %{"id" => resp["id"], "secret" => resp["secret"]}, opts)

  describe "GET /join" do
    test "is the same anonymous script as /nodes/join, on a short stable path" do
      conn = Phoenix.ConnTest.dispatch(Phoenix.ConnTest.build_conn(), @endpoint, :get, "/join")

      assert conn.status == 200
      assert conn.resp_body =~ "ARB_PRIMARY_URL='#{@url}'"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  describe "POST /nodes/pair" do
    test "opens a request: a short code for the screen, a long secret for the node" do
      resp = pair!()

      assert resp["code"] =~ ~r/\A[2-9A-HJ-NP-Z]{4}-[2-9A-HJ-NP-Z]{4}\z/
      assert resp["secret"] =~ ~r/\Aarbp_[a-z2-7]{52}\z/
      assert resp["expires_in"] == 600
      assert resp["interval"] in 1..10
      refute Map.has_key?(resp, "credential")

      assert [req] = Pairing.list_pending()
      assert req.hostname == "laptop"
      assert req.peer == "100.64.0.7"
    end

    test "records the forwarded address as the peer behind a loopback proxy" do
      conn =
        pair(%{"hostname" => "laptop"},
          peer: {127, 0, 0, 1},
          headers: [{"x-forwarded-for", "100.64.9.9"}]
        )

      assert conn.status == 201
      assert [%{peer: "100.64.9.9"}] = Pairing.list_pending()
    end

    test "ignores X-Forwarded-For from a non-loopback peer" do
      conn = pair(%{"hostname" => "x"}, headers: [{"x-forwarded-for", "10.9.9.9"}])
      assert conn.status == 201
      assert [%{peer: "100.64.0.7"}] = Pairing.list_pending()
    end

    test "text/plain answers KEY=value lines for the join script" do
      conn = pair(%{"hostname" => "laptop"}, accept: "text/plain")

      assert conn.status == 201
      lines = String.split(conn.resp_body, "\n", trim: true)
      assert Enum.any?(lines, &String.starts_with?(&1, "code="))
      assert Enum.any?(lines, &String.starts_with?(&1, "secret=arbp_"))
      assert Enum.any?(lines, &String.starts_with?(&1, "id="))
    end

    test "a bad proposed name is a 422 and opens nothing" do
      conn = pair(%{"hostname" => "x", "name" => "bad name"})
      assert conn.status == 422
      assert Pairing.list_pending() == []
    end

    test "is rate limited per source (5 per 10 minutes)" do
      statuses = for _ <- 1..6, do: pair(%{"hostname" => "x"}, peer: {100, 64, 0, 9}).status

      # the per-source pending cap (3) bites before the limiter; both are 429
      assert List.last(statuses) == 429
      assert Enum.count(statuses, &(&1 == 201)) <= 5
      assert {:ok, _} = Pairing.request(%{hostname: "other"}, peer: "100.64.0.99")
    end

    test "answers 429 with a Retry-After when the pending cap is reached" do
      for _ <- 1..Pairing.max_pending_per_peer(), do: assert(pair().status == 201)
      conn = pair()

      assert conn.status == 429
      assert [_] = get_resp_header(conn, "retry-after")
    end

    test "is unavailable before nodes.public_url is set or an agent build exists" do
      {:ok, _} = Arbiter.Settings.set_nodes_public_url(nil)
      assert pair().status == 503
      assert Pairing.list_pending() == []
    end
  end

  describe "POST /nodes/pair/poll" do
    test "an unapproved request gets 202 and no credential" do
      resp = pair!()
      conn = poll(resp)

      assert conn.status == 202
      assert Jason.decode!(conn.resp_body) == %{"state" => "pending"}
      assert Nodes.list_nodes() == []
    end

    test "an approved request gets its credential, once", %{release: release} do
      resp = pair!(%{"hostname" => "laptop", "name" => "box-1"})
      {:ok, _} = Pairing.approve(resp["id"], %{max_workers: 2}, @operator)

      conn = poll(resp)
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["credential"] =~ ~r/\Aarbn_[0-9a-f-]{36}\.[a-z2-7]{52}\z/
      assert body["name"] == "box-1"
      assert body["max_workers"] == 2
      assert body["agent_version"] == release.tag
      assert body["tarball_sha256"] == release.sha256
      assert body["ws_url"] == "wss://primary.example.ts.net/node/socket"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert {:ok, _} = Nodes.authenticate(body["credential"])

      second = poll(resp)
      assert second.status == 401
      refute second.resp_body =~ "arbn_"
    end

    test "text/plain returns the KEY=value lines the script reads" do
      resp = pair!(%{"hostname" => "laptop", "name" => "box-2"})
      {:ok, _} = Pairing.approve(resp["id"], %{}, @operator)

      conn =
        post_json("/nodes/pair/poll", %{"id" => resp["id"], "secret" => resp["secret"]},
          accept: "text/plain"
        )

      assert conn.status == 200
      assert conn.resp_body =~ ~r/^credential=arbn_/m
      assert conn.resp_body =~ ~r/^name=box-2$/m
      assert conn.resp_body =~ ~r/^tarball_sha256=[0-9a-f]{64}$/m
    end

    test "a denied request gets 403 and nothing else" do
      resp = pair!()
      {:ok, _} = Pairing.deny(resp["id"], @operator)

      conn = poll(resp)
      assert conn.status == 403
      refute conn.resp_body =~ "arbn_"
    end

    test "an expired request gets 410, even if it was approved" do
      resp = pair!()
      {:ok, _} = Pairing.approve(resp["id"], %{}, @operator)

      Arbiter.Repo.query!(
        "UPDATE pairing_requests SET expires_at = '2000-01-01T00:00:00.000000Z'"
      )

      conn = poll(resp)
      assert conn.status == 410
      refute conn.resp_body =~ "arbn_"
      assert Nodes.list_nodes() == []
      assert [_] = Nodes.events(kind: :pairing_expired)
    end

    test "the code is not the secret, and a wrong secret gets a generic 401" do
      resp = pair!()
      {:ok, _} = Pairing.approve(resp["id"], %{}, @operator)

      by_code = post_json("/nodes/pair/poll", %{"id" => resp["id"], "secret" => resp["code"]})
      assert by_code.status == 401

      unknown = post_json("/nodes/pair/poll", %{"id" => "nope", "secret" => resp["secret"]})
      assert unknown.status == 401
      assert unknown.resp_body == by_code.resp_body
      assert Nodes.list_nodes() == []
    end

    test "the secret is read from the body only, never the query string" do
      resp = pair!()
      {:ok, _} = Pairing.approve(resp["id"], %{}, @operator)

      conn =
        post_json("/nodes/pair/poll?id=#{resp["id"]}&secret=#{resp["secret"]}", %{})

      assert conn.status == 401
      assert Nodes.list_nodes() == []
    end

    test "repeated bad polls from one source are rate limited" do
      statuses =
        for _ <- 1..12,
            do: post_json("/nodes/pair/poll", %{"id" => "nope", "secret" => "arbp_x"}).status

      assert List.last(statuses) == 429
    end
  end
end
