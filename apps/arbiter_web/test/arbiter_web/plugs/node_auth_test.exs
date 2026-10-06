defmodule ArbiterWeb.Plugs.NodeAuthTest do
  @moduledoc """
  RW3 (`docs/design/remote-workers.md` §5.3, §15.1): `NodeAuth` admits exactly
  one thing — a live `arbn_` node credential in `Authorization: Bearer` — and
  answers every other presentation with the same generic 401.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Nodes
  alias ArbiterWeb.Plugs.NodeAuth

  @operator Actor.operator("cli")

  setup do
    Actor.put(nil)
    {:ok, token} = mint_join_token()
    {:ok, %{node: node, credential: credential}} = Nodes.redeem_join_token(token, %{name: "plug-box"})
    {:ok, node: node, credential: credential}
  end

  defp mint_join_token do
    with {:ok, %{token: token}} <- Nodes.mint_join_token([], @operator), do: {:ok, token}
  end

  defp call(headers \\ [], query \\ "") do
    conn = Plug.Test.conn(:get, "/nodes/probe" <> query)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    NodeAuth.call(conn, NodeAuth.init([]))
  end

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  defp error_message(conn), do: Jason.decode!(conn.resp_body)["error"]["message"]

  test "a live node credential is admitted and the node is assigned", ctx do
    conn = call(bearer(ctx.credential))

    refute conn.halted
    assert conn.assigns.current_node.id == ctx.node.id
    assert Actor.current() == Actor.node("plug-box")
  end

  test "no credential is a 401", _ctx do
    conn = call()

    assert conn.halted
    assert conn.status == 401
    assert [content_type | _] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
  end

  test "coordinator, operator, worker, refine and session tokens are each refused with 401" do
    tokens = [
      coordinator: Scope.mint_coordinator(nil),
      operator: Scope.mint_coordinator(nil, operator: true),
      worker: Scope.mint_worker(%{id: "bd-x", workspace_id: "ws-1"}),
      refine: Scope.mint_refine("sess-1", "ws-1", "bd-x"),
      session: Scope.mint_session("sess-1")
    ]

    for {tier, token} <- tokens do
      conn = call(bearer(token))
      assert conn.halted, "#{tier} token was admitted"
      assert conn.status == 401, "#{tier} token got #{conn.status}"
      refute Map.has_key?(conn.assigns, :current_node)
    end
  end

  test "a join token cannot authenticate (it only redeems)" do
    {:ok, token} = mint_join_token()

    assert call(bearer(token)).status == 401
  end

  test "a credential in the query string is ignored", ctx do
    conn = call([], "?token=" <> ctx.credential)

    assert conn.status == 401
  end

  test "a wrong secret and an unknown id are 401", ctx do
    assert call(bearer("arbn_#{ctx.node.id}.#{String.duplicate("a", 52)}")).status == 401
    assert call(bearer("arbn_#{Ash.UUIDv7.generate()}.#{String.duplicate("a", 52)}")).status == 401
    assert call(bearer("arbn_")).status == 401
    assert call([{"authorization", "Basic abc"}]).status == 401
  end

  test "a revoked node's credential is rejected on its next request", ctx do
    assert call(bearer(ctx.credential)).status != 401
    {:ok, _} = Nodes.revoke(ctx.node, @operator)

    conn = call(bearer(ctx.credential))
    assert conn.status == 401
    refute Map.has_key?(conn.assigns, :current_node)
  end

  test "a rotated credential: the new one works and so does the old one during the overlap", ctx do
    {:ok, %{credential: new}} = Nodes.rotate_credential(ctx.node, @operator)

    refute call(bearer(new)).halted
    refute call(bearer(ctx.credential)).halted
  end

  test "every failure carries the same message: no oracle between the cases", ctx do
    {:ok, _} = Nodes.revoke(ctx.node, @operator)

    messages =
      for headers <- [
            [],
            bearer(ctx.credential),
            bearer("arbn_nope.nope"),
            bearer(Scope.mint_coordinator(nil)),
            [{"authorization", "garbage"}]
          ] do
        error_message(call(headers))
      end

    assert messages |> Enum.uniq() |> length() == 1
  end

  test "a failed request does not leave a previous request's actor behind", ctx do
    Actor.put(Actor.node("someone-else"))

    call()
    assert Actor.current() == nil

    call(bearer(ctx.credential))
    assert Actor.current() == Actor.node("plug-box")
  end
end
