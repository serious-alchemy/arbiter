defmodule Arbiter.Nodes.PairingTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Credentials, Pairing}

  @operator Actor.operator("cli")
  @peer "100.64.0.7"

  defp request!(attrs \\ %{}, opts \\ []) do
    attrs = Map.merge(%{hostname: "laptop"}, attrs)
    opts = Keyword.merge([peer: @peer], opts)
    assert {:ok, %{request: req, secret: secret}} = Pairing.request(attrs, opts)
    {req, secret}
  end

  defp events(kind), do: Nodes.events() |> Enum.filter(&(&1.kind == kind))

  describe "request/2" do
    test "returns a short code and a long poll secret; stores only the secret's hash" do
      {req, secret} = request!()

      assert req.code =~ ~r/\A[2-9A-HJ-NP-Z]{8}\z/
      assert String.starts_with?(secret, "arbp_")
      assert req.secret_hash == Credentials.hash(secret)
      assert req.state == :pending
      assert req.peer == @peer
      assert req.hostname == "laptop"
      assert_in_delta DateTime.diff(req.expires_at, DateTime.utc_now()), 10 * 60, 5
      refute inspect(Map.from_struct(req)) =~ secret
    end

    test "the code is not the secret: knowing it yields nothing" do
      {req, _secret} = request!()

      assert {:error, :invalid} = Pairing.redeem(req.id, req.code)

      assert {:error, :invalid} =
               Pairing.redeem(req.id, Credentials.format_pairing_code(req.code))
    end

    test "audits the request with the peer" do
      {req, _} = request!()

      assert [event] = events(:pairing_requested)
      assert event.remote_addr_hint == @peer
      assert event.detail["request_id"] == req.id
      assert event.detail["hostname"] == "laptop"
    end

    test "sanitises the node-supplied hostname" do
      {req, _} = request!(%{hostname: "evil\e[31m host\n" <> String.duplicate("a", 200)})

      assert req.hostname =~ ~r/\A[A-Za-z0-9._-]{1,64}\z/
    end

    test "a request without a usable hostname shows as unknown" do
      {req, _} = request!(%{hostname: nil})
      assert req.hostname == "unknown"
    end

    test "refuses an invalid proposed name" do
      assert {:error, :invalid_name} =
               Pairing.request(%{hostname: "h", name: "bad name!"}, peer: @peer)
    end

    test "is capped per source" do
      for _ <- 1..Pairing.max_pending_per_peer(), do: request!()

      assert {:error, :too_many_pending} = Pairing.request(%{hostname: "x"}, peer: @peer)
      assert [%{detail: %{"reason" => "too_many_pending"}}] = events(:pairing_rejected)

      # another source is unaffected
      assert {:ok, _} = Pairing.request(%{hostname: "x"}, peer: "100.64.0.8")
    end

    test "is capped in total" do
      for n <- 1..Pairing.max_pending() do
        assert {:ok, _} = Pairing.request(%{hostname: "h"}, peer: "100.64.1.#{n}")
      end

      assert {:error, :too_many_pending} = Pairing.request(%{hostname: "x"}, peer: "100.64.2.1")
    end

    test "expired requests do not count toward the caps" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      for _ <- 1..Pairing.max_pending_per_peer(), do: request!(%{}, now: past)

      assert {:ok, _} = Pairing.request(%{hostname: "x"}, peer: @peer)
    end
  end

  describe "listing and lookup" do
    test "list_pending/1 shows pending requests with hostname and peer, newest last" do
      {a, _} = request!(%{hostname: "a"})
      {b, _} = request!(%{hostname: "b"}, peer: "100.64.0.9")

      assert [%{id: id1}, %{id: id2}] = Pairing.list_pending()
      assert [id1, id2] == [a.id, b.id]
    end

    test "list_pending/1 drops expired requests and audits their expiry" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      {old, _} = request!(%{}, now: past)

      assert Pairing.list_pending() == []
      assert [event] = events(:pairing_expired)
      assert event.detail["request_id"] == old.id
    end

    test "get/1 finds a live request by id or by a typed, lenient code" do
      {req, _} = request!()
      typed = Credentials.format_pairing_code(req.code) |> String.downcase()

      assert %{id: id} = Pairing.get(req.id)
      assert id == req.id
      assert %{id: ^id} = Pairing.get(typed)
      assert Pairing.get("nonsense") == nil
    end
  end

  describe "approve/4" do
    test "moves a pending request to approved and audits the operator" do
      {req, _} = request!()

      assert {:ok, approved} = Pairing.approve(req.id, %{name: "box-1"}, @operator)
      assert approved.state == :approved
      assert approved.approved_by == "operator:cli"

      assert [event] = events(:pairing_approved)
      assert event.actor == "operator:cli"
      assert event.remote_addr_hint == @peer
    end

    test "works by code" do
      {req, _} = request!()
      assert {:ok, %{state: :approved}} = Pairing.approve(req.code, %{}, @operator)
    end

    test "an unknown code is not_found" do
      assert {:error, :not_found} = Pairing.approve("ABCD-EFGH", %{}, @operator)
    end

    test "an expired request cannot be approved" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      {req, _} = request!(%{}, now: past)

      assert {:error, :not_found} = Pairing.approve(req.id, %{}, @operator)
    end

    test "a request can be approved once" do
      {req, _} = request!()
      assert {:ok, _} = Pairing.approve(req.id, %{}, @operator)
      assert {:error, :not_pending} = Pairing.approve(req.id, %{}, @operator)
    end

    test "refuses an invalid or taken name without approving" do
      {token, _} = mint()
      {:ok, _} = Nodes.redeem_join_token(token, %{name: "taken"})
      {req, _} = request!()

      assert {:error, :invalid_name} = Pairing.approve(req.id, %{name: "no good"}, @operator)
      assert {:error, :name_taken} = Pairing.approve(req.id, %{name: "taken"}, @operator)
      assert %{state: :pending} = Pairing.get(req.id)
    end
  end

  describe "deny/3" do
    test "denies and audits" do
      {req, _} = request!()

      assert {:ok, %{state: :denied}} = Pairing.deny(req.id, @operator)
      assert [event] = events(:pairing_denied)
      assert event.actor == "operator:cli"
      assert Pairing.list_pending() == []
    end

    test "an approved request can no longer be denied" do
      {req, _} = request!()
      {:ok, _} = Pairing.approve(req.id, %{}, @operator)
      assert {:error, :not_pending} = Pairing.deny(req.id, @operator)
    end
  end

  describe "redeem/3" do
    test "a pending request gets nothing" do
      {req, secret} = request!()
      assert {:pending, %{id: id}} = Pairing.redeem(req.id, secret)
      assert id == req.id
      assert Nodes.list_nodes() == []
    end

    test "an approved request gets a node credential, once" do
      {req, secret} = request!(%{name: "proposed"})
      {:ok, _} = Pairing.approve(req.id, %{name: "box-1", max_workers: 3}, @operator)

      assert {:ok, %{node: node, credential: credential}} =
               Pairing.redeem(req.id, secret, remote_addr_hint: @peer)

      assert node.name == "box-1"
      assert node.max_workers == 3
      assert {:ok, node_id, _} = Credentials.parse_node_credential(credential)
      assert node_id == node.id
      assert {:ok, _} = Nodes.authenticate(credential)

      assert [event] = events(:enrolled)
      assert event.detail["pairing_request_id"] == req.id
      assert event.remote_addr_hint == @peer

      # single use
      assert {:error, :invalid} = Pairing.redeem(req.id, secret)
      assert length(Nodes.list_nodes()) == 1
    end

    test "the node's proposed name is the fallback when the operator names none" do
      {a, sa} = request!(%{name: "proposed"})
      {:ok, _} = Pairing.approve(a.id, %{}, @operator)
      assert {:ok, %{node: %{name: "proposed"}}} = Pairing.redeem(a.id, sa)
    end

    test "a wrong secret gets nothing, even once approved" do
      {req, _secret} = request!()
      {:ok, _} = Pairing.approve(req.id, %{}, @operator)
      {other, _} = Credentials.generate_pairing_secret()

      assert {:error, :invalid} = Pairing.redeem(req.id, other)
      assert {:error, :invalid} = Pairing.redeem(req.id, nil)
      assert {:error, :invalid} = Pairing.redeem("no-such-id", other)
      assert Nodes.list_nodes() == []
    end

    test "a denied request never gets a credential" do
      {req, secret} = request!()
      {:ok, _} = Pairing.deny(req.id, @operator)

      assert {:error, :denied} = Pairing.redeem(req.id, secret)
      assert Nodes.list_nodes() == []
    end

    test "an expired request never gets a credential, approved or not" do
      {req, secret} = request!()
      {:ok, _} = Pairing.approve(req.id, %{}, @operator)
      later = DateTime.add(DateTime.utc_now(), 11 * 60, :second)

      assert {:error, :expired} = Pairing.redeem(req.id, secret, now: later)
      assert [event] = events(:pairing_expired)
      assert event.detail["request_id"] == req.id
      assert Nodes.list_nodes() == []
      # and stays expired
      assert {:error, :expired} = Pairing.redeem(req.id, secret)
    end

    test "an unapproved request that expires is audited and gets nothing" do
      {req, secret} = request!()
      later = DateTime.add(DateTime.utc_now(), 11 * 60, :second)
      assert {:error, :expired} = Pairing.redeem(req.id, secret, now: later)
      assert length(events(:pairing_expired)) == 1
    end

    test "racing redemptions of one approval yield exactly one node" do
      {req, secret} = request!()
      {:ok, _} = Pairing.approve(req.id, %{name: "racer"}, @operator)
      parent = self()

      results =
        1..6
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, parent, self())
            Pairing.redeem(req.id, secret)
          end,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert length(Nodes.list_nodes()) == 1
    end

    test "a name taken after approval hands the approval back" do
      {req, secret} = request!()
      {:ok, _} = Pairing.approve(req.id, %{name: "late"}, @operator)
      {token, _} = mint()
      {:ok, _} = Nodes.redeem_join_token(token, %{name: "late"})

      assert {:error, :name_taken} = Pairing.redeem(req.id, secret)
      assert %{state: :approved} = Pairing.get(req.id)
    end
  end

  describe "unattended join tokens still work" do
    test "arbj_ tokens redeem as before" do
      {token, _} = mint()

      assert {:ok, %{node: %{name: "unattended"}}} =
               Nodes.redeem_join_token(token, %{name: "unattended"})
    end
  end

  defp mint do
    assert {:ok, %{token: token} = minted} = Nodes.mint_join_token([], @operator)
    {token, minted}
  end
end
