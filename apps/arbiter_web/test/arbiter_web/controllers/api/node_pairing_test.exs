defmodule ArbiterWeb.Api.NodePairingTest do
  @moduledoc """
  The operator's side of device-code pairing (`docs/design/remote-workers.md`
  §5.7): list, approve and deny pending requests under `/api/nodes/pairings`.
  **Operator proof only** (reads included): approving hands a node the primary's
  provider credentials. The node's side is `ArbiterWeb.NodePairingTest`.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Credentials, Pairing}

  defp as(scope_token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> scope_token)
    |> put_req_header("content-type", "application/json")
  end

  defp operator_conn, do: as(Scope.mint_coordinator(nil, operator: true))
  defp session_conn, do: as(Scope.mint_coordinator(nil))

  defp pending!(attrs \\ %{hostname: "laptop"}, peer \\ "100.64.0.7") do
    {:ok, %{request: req, secret: secret}} = Pairing.request(attrs, peer: peer)
    {req, secret}
  end

  describe "GET /api/nodes/pairings" do
    test "lists pending requests with the code, hostname and peer address" do
      {req, _} = pending!(%{hostname: "laptop", name: "box-1"})

      body = json_response(get(operator_conn(), "/api/nodes/pairings"), 200)

      assert [row] = body["pairings"]
      assert row["id"] == req.id
      assert row["code"] == Credentials.format_pairing_code(req.code)
      assert row["hostname"] == "laptop"
      assert row["peer"] == "100.64.0.7"
      assert row["name"] == "box-1"
      assert row["state"] == "pending"
      assert row["expires_at"]
      refute inspect(body) =~ "secret"
    end

    test "is empty when nothing is pending" do
      assert json_response(get(operator_conn(), "/api/nodes/pairings"), 200) == %{"pairings" => []}
    end

    test "a coordinator session without operator proof is forbidden" do
      assert get(session_conn(), "/api/nodes/pairings").status == 403
    end

    test "no token at all is unauthenticated" do
      conn = Phoenix.ConnTest.build_conn() |> get("/api/nodes/pairings")
      assert conn.status in [401, 403]
    end
  end

  describe "POST /api/nodes/pairings/:ref/approve" do
    test "an operator approves by the typed code, case and dash insensitive" do
      {req, secret} = pending!()
      typed = req.code |> Credentials.format_pairing_code() |> String.downcase()

      conn =
        post(operator_conn(), "/api/nodes/pairings/#{typed}/approve", %{
          name: "gpu-1",
          max_workers: 3
        })

      body = json_response(conn, 200)
      assert body["pairing"]["state"] == "approved"
      assert body["pairing"]["name"] == "gpu-1"
      assert body["pairing"]["max_workers"] == 3
      refute inspect(body) =~ secret

      # approval alone creates no node and no credential
      assert Nodes.list_nodes() == []
      assert [event] = Nodes.events(kind: :pairing_approved)
      assert event.actor =~ "operator"
    end

    test "approving by request id works too" do
      {req, _} = pending!()
      conn = post(operator_conn(), "/api/nodes/pairings/#{req.id}/approve", %{})
      assert json_response(conn, 200)["pairing"]["state"] == "approved"
    end

    test "a coordinator session without operator proof cannot approve" do
      {req, secret} = pending!()

      conn = post(session_conn(), "/api/nodes/pairings/#{req.code}/approve", %{})
      assert conn.status == 403

      assert {:pending, _} = Pairing.redeem(req.id, secret)
      assert Pairing.get(req.id).state == :pending
    end

    test "an unknown code is a 404" do
      conn = post(operator_conn(), "/api/nodes/pairings/ABCD-2345/approve", %{})
      assert conn.status == 404
    end

    test "a bad name is a 422 and leaves the request pending" do
      {req, _} = pending!()
      conn = post(operator_conn(), "/api/nodes/pairings/#{req.code}/approve", %{name: "bad name"})

      assert conn.status == 422
      assert Pairing.get(req.id).state == :pending
    end

    test "a taken name is a 409 and leaves the request pending" do
      {:ok, %{token: t}} = Nodes.mint_join_token([], nil)
      {:ok, _} = Nodes.redeem_join_token(t, %{name: "taken"})
      {req, _} = pending!()

      conn = post(operator_conn(), "/api/nodes/pairings/#{req.code}/approve", %{name: "taken"})
      assert conn.status == 409
      assert Pairing.get(req.id).state == :pending
    end

    test "a second approval is a 409" do
      {req, _} = pending!()
      assert post(operator_conn(), "/api/nodes/pairings/#{req.code}/approve", %{}).status == 200
      assert post(operator_conn(), "/api/nodes/pairings/#{req.code}/approve", %{}).status == 409
    end
  end

  describe "POST /api/nodes/pairings/:ref/deny" do
    test "an operator denies a request; the node never gets a credential" do
      {req, secret} = pending!()

      conn = post(operator_conn(), "/api/nodes/pairings/#{req.code}/deny", %{})
      assert json_response(conn, 200)["pairing"]["state"] == "denied"

      assert {:error, :denied} = Pairing.redeem(req.id, secret)
      assert [_] = Nodes.events(kind: :pairing_denied)
    end

    test "a coordinator session without operator proof cannot deny" do
      {req, _} = pending!()
      assert post(session_conn(), "/api/nodes/pairings/#{req.code}/deny", %{}).status == 403
      assert Pairing.get(req.id).state == :pending
    end

    test "an unknown code is a 404" do
      assert post(operator_conn(), "/api/nodes/pairings/ABCD-2345/deny", %{}).status == 404
    end
  end

  test "pairings do not shadow node lookups" do
    assert get(operator_conn(), "/api/nodes/pairings").status == 200
    assert get(operator_conn(), "/api/nodes/ghost").status == 404
  end
end
