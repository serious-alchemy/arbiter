defmodule ArbiterWeb.NodesLivePairingTest do
  @moduledoc """
  The dashboard's side of device-code pairing (`docs/design/remote-workers.md`
  §5.7): the Nodes page lists pending requests with the code, the hostname the
  node claims and the address the primary saw, and the operator approves or
  denies them there.
  """
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Credentials, Pairing, RateLimit}
  alias Arbiter.Settings

  @url "https://primary.example.ts.net"

  setup do
    {:ok, _} = Settings.set_nodes_public_url(@url)
    RateLimit.reset()
    on_exit(fn -> Settings.set_nodes_public_url(nil) end)
    :ok
  end

  defp pending!(attrs \\ %{hostname: "laptop"}, peer \\ "100.64.0.7") do
    {:ok, %{request: req, secret: secret}} = Pairing.request(attrs, peer: peer)
    {req, secret}
  end

  # Approve, deny and redeem broadcast on the nodes topic, and the page answers
  # each with a refresh that queries the DB. Such a message can still be in the
  # LiveView's mailbox when the test body returns, and teardown kills the channel mid-query, which
  # drops the shared sandbox connection (bd-5scl0c) and fails the next DB
  # writer: the `on_exit` that resets the public URL. A `render/1` is a call
  # queued behind the broadcast, so it returns only once the refresh is done.
  defp settle(view), do: render(view)

  test "shows nothing when no node is waiting", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/nodes")
    refute has_element?(view, "#pairing-requests")
  end

  test "lists a pending request with its code, hostname and source address", %{conn: conn} do
    {req, _} = pending!(%{hostname: "laptop", name: "box-9"})

    {:ok, view, _} = live(conn, ~p"/nodes")

    assert has_element?(view, "#pairing-#{req.id}")

    assert has_element?(
             view,
             "#pairing-#{req.id} [data-role=code]",
             Credentials.format_pairing_code(req.code)
           )

    assert has_element?(view, "#pairing-#{req.id} [data-role=hostname]", "laptop")
    assert has_element?(view, "#pairing-#{req.id} [data-role=peer]", "100.64.0.7")
    assert has_element?(view, "#pairing-form-#{req.id} input[name=name][value=box-9]")
  end

  test "a request opened while the page is open appears live", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/nodes")
    refute has_element?(view, "#pairing-requests")

    {req, _} = pending!()
    _ = render(view)

    assert has_element?(view, "#pairing-#{req.id}")
  end

  test "approving records the operator and lets the node collect its credential", %{conn: conn} do
    {req, secret} = pending!()
    {:ok, view, _} = live(conn, ~p"/nodes")

    view
    |> form("#pairing-form-#{req.id}", %{"name" => "gpu-1", "max_workers" => "2"})
    |> render_submit()

    refute has_element?(view, "#pairing-#{req.id}")
    assert [event] = Nodes.events(kind: :pairing_approved)
    assert event.actor == Actor.label(Actor.operator("dashboard"))

    assert {:ok, %{node: node, credential: "arbn_" <> _}} = Pairing.redeem(req.id, secret)
    assert node.name == "gpu-1"
    assert node.max_workers == 2

    # redeeming creates the node and broadcasts again
    settle(view)
  end

  test "denying leaves the node without a credential", %{conn: conn} do
    {req, secret} = pending!()
    {:ok, view, _} = live(conn, ~p"/nodes")

    view |> element("#pairing-deny-#{req.id}") |> render_click()

    refute has_element?(view, "#pairing-#{req.id}")
    settle(view)
    assert {:error, :denied} = Pairing.redeem(req.id, secret)
    assert [_] = Nodes.events(kind: :pairing_denied)
  end

  test "a taken name is reported and the request stays pending", %{conn: conn} do
    {:ok, %{token: t}} = Nodes.mint_join_token([name: "taken"], Actor.operator("cli"))
    {:ok, _} = Nodes.redeem_join_token(t)
    {req, _} = pending!()
    {:ok, view, _} = live(conn, ~p"/nodes")

    html =
      view
      |> form("#pairing-form-#{req.id}", %{"name" => "taken"})
      |> render_submit()

    assert html =~ "already"
    assert has_element?(view, "#pairing-#{req.id}")
    assert Pairing.get(req.id).state == :pending
  end

  test "an invalid worker cap is refused and the request stays pending", %{conn: conn} do
    {req, _} = pending!()
    {:ok, view, _} = live(conn, ~p"/nodes")

    view
    |> form("#pairing-form-#{req.id}", %{"max_workers" => "abc"})
    |> render_submit()

    assert has_element?(view, "#pairing-#{req.id}")
    assert Pairing.get(req.id).state == :pending
  end
end
