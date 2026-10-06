defmodule Arbiter.NodesTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Credentials, JoinToken, Node, NodeEvent}

  @operator Actor.operator("cli")

  defp mint!(opts \\ []) do
    assert {:ok, %{token: token} = minted} = Nodes.mint_join_token(opts, @operator)
    {token, minted}
  end

  defp enroll!(attrs \\ %{name: "box-1"}) do
    {token, _} = mint!()
    assert {:ok, enrolled} = Nodes.redeem_join_token(token, attrs)
    enrolled
  end

  defp events(kind), do: Nodes.events() |> Enum.filter(&(&1.kind == kind))

  describe "mint_join_token/2" do
    test "returns the secret once and stores only its hash" do
      {token, %{join_token: row}} = mint!()

      assert Credentials.join_token?(token)
      assert row.token_hash == Credentials.hash(token)
      assert row.created_by == "operator:cli"
      assert is_nil(row.used_at)

      stored = Ash.read!(JoinToken) |> Enum.map(&Map.from_struct/1) |> inspect()
      refute String.contains?(stored, token)
    end

    test "defaults to a 15 minute TTL" do
      {_token, %{join_token: row}} = mint!()

      assert_in_delta DateTime.diff(row.expires_at, DateTime.utc_now()), 15 * 60, 5
    end

    test "honours ttl_seconds up to 24 hours and refuses more" do
      {_token, %{join_token: row}} = mint!(ttl_seconds: 3600)
      assert_in_delta DateTime.diff(row.expires_at, DateTime.utc_now()), 3600, 5

      assert {:error, :invalid_ttl} = Nodes.mint_join_token([ttl_seconds: 24 * 3600 + 1], @operator)
      assert {:error, :invalid_ttl} = Nodes.mint_join_token([ttl_seconds: 0], @operator)
    end

    test "writes a token_minted event attributed to the minting actor" do
      {_token, %{join_token: row}} = mint!(name: "gpu-box")

      assert [event] = events(:token_minted)
      assert event.actor == "operator:cli"
      assert event.detail["join_token_id"] == row.id
      assert is_nil(event.node_id)
    end

    test "the minting secret never lands in an event" do
      {token, _} = mint!()

      refute Nodes.events() |> inspect() |> String.contains?(token)
    end
  end

  describe "redeem_join_token/3" do
    test "enrolls a node and returns its credential once, stored hashed" do
      %{node: node, credential: credential} = enroll!(%{name: "box-1", max_workers: 3})

      assert %Node{name: "box-1", status: :active, max_workers: 3} = node
      assert {:ok, id, secret} = Credentials.parse_node_credential(credential)
      assert id == node.id
      assert node.credential_hash == Credentials.hash(secret)
      assert node.credential_prefix == String.slice(secret, 0, 8)
      refute inspect(Map.from_struct(node)) =~ secret
    end

    test "a join token's pre-bound name, labels and max_workers win over the enroll request" do
      {token, _} = mint!(name: "pinned", labels: ["gpu"], max_workers: 2)

      assert {:ok, %{node: node}} =
               Nodes.redeem_join_token(token, %{name: "requested", labels: [], max_workers: 9})

      assert node.name == "pinned"
      assert node.labels == ["gpu"]
      assert node.max_workers == 2
    end

    test "is single use" do
      {token, _} = mint!()

      assert {:ok, _} = Nodes.redeem_join_token(token, %{name: "a"})
      assert {:error, :invalid_token} = Nodes.redeem_join_token(token, %{name: "b"})
      assert [_] = Ash.read!(Node)
    end

    test "an expired token is refused with the same error as an unknown one" do
      {token, %{join_token: row}} = mint!()
      later = DateTime.add(row.expires_at, 1, :second)

      assert {:error, :invalid_token} = Nodes.redeem_join_token(token, %{name: "a"}, now: later)
      assert {:error, :invalid_token} = Nodes.redeem_join_token("arbj_" <> String.duplicate("a", 52), %{name: "a"})
      assert Ash.read!(Node) == []
    end

    test "anything that is not a join token is refused" do
      assert {:error, :invalid_token} = Nodes.redeem_join_token("nope", %{name: "a"})
      assert {:error, :invalid_token} = Nodes.redeem_join_token(nil, %{name: "a"})
    end

    test "records the used token's node" do
      {token, %{join_token: row}} = mint!()
      {:ok, %{node: node}} = Nodes.redeem_join_token(token, %{name: "a"})

      used = Ash.get!(JoinToken, row.id)
      assert used.used_by_node == node.id
      assert %DateTime{} = used.used_at
    end

    test "writes enrolled (actor node) and join_failed events" do
      {token, _} = mint!()
      {:ok, %{node: node}} = Nodes.redeem_join_token(token, %{name: "a"}, remote_addr_hint: "100.64.0.9")
      {:error, :invalid_token} = Nodes.redeem_join_token(token, %{name: "b"}, remote_addr_hint: "100.64.0.10")

      assert [enrolled] = events(:enrolled)
      assert enrolled.node_id == node.id
      assert enrolled.actor == "node:a"
      assert Actor.parse(enrolled.actor).kind == :node
      assert enrolled.remote_addr_hint == "100.64.0.9"

      assert [failed] = events(:join_failed)
      assert is_nil(failed.node_id)
      assert failed.remote_addr_hint == "100.64.0.10"
      refute inspect(failed.detail) =~ token
    end

    test "a name already in use is refused without burning the token" do
      enroll!(%{name: "taken"})
      {token, _} = mint!()

      assert {:error, :name_taken} = Nodes.redeem_join_token(token, %{name: "taken"})
      assert {:ok, %{node: %{name: "fresh"}}} = Nodes.redeem_join_token(token, %{name: "fresh"})
    end

    test "U15: two processes racing to redeem one token — exactly one wins" do
      {token, %{join_token: row}} = mint!()
      parent = self()

      tasks =
        for n <- 1..8 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, parent, self())
            Nodes.redeem_join_token(token, %{name: "racer-#{n}"})
          end)
        end

      results = Task.await_many(tasks, 30_000)

      assert [{:ok, %{node: node}}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert Enum.count(results, &(&1 == {:error, :invalid_token})) == 7
      assert [only] = Ash.read!(Node)
      assert only.id == node.id
      assert Ash.get!(JoinToken, row.id).used_by_node == node.id
    end
  end

  describe "authenticate/1" do
    test "accepts the issued credential and refuses a wrong secret or id" do
      %{node: node, credential: credential} = enroll!()

      assert {:ok, %Node{id: id}} = Nodes.authenticate(credential)
      assert id == node.id

      {:ok, _id, secret} = Credentials.parse_node_credential(credential)
      assert {:error, :invalid_credential} = Nodes.authenticate("arbn_#{node.id}.#{String.reverse(secret)}")
      assert {:error, :invalid_credential} = Nodes.authenticate("arbn_#{Ash.UUIDv7.generate()}.#{secret}")
      assert {:error, :invalid_credential} = Nodes.authenticate("arbn_not-a-uuid.#{secret}")
      assert {:error, :invalid_credential} = Nodes.authenticate("garbage")
      assert {:error, :invalid_credential} = Nodes.authenticate(nil)
    end

    test "a join token is not a node credential" do
      {token, _} = mint!()

      assert {:error, :invalid_credential} = Nodes.authenticate(token)
    end

    test "stamps last_seen_at" do
      %{node: node, credential: credential} = enroll!()
      assert is_nil(node.last_seen_at)

      {:ok, seen} = Nodes.authenticate(credential)
      assert %DateTime{} = seen.last_seen_at
    end
  end

  describe "revoke/2" do
    test "clears the hash, rejects the credential and writes a revoked event" do
      %{node: node, credential: credential} = enroll!()

      assert {:ok, revoked} = Nodes.revoke(node, @operator)
      assert revoked.status == :revoked
      assert is_nil(revoked.credential_hash)
      assert %DateTime{} = revoked.revoked_at
      assert {:error, :invalid_credential} = Nodes.authenticate(credential)

      assert [event] = events(:revoked)
      assert event.node_id == node.id
      assert event.actor == "operator:cli"
    end

    test "is idempotent and writes one event" do
      %{node: node} = enroll!()

      assert {:ok, _} = Nodes.revoke(node, @operator)
      assert {:ok, %{status: :revoked}} = Nodes.revoke(Ash.get!(Node, node.id), @operator)
      assert [_] = events(:revoked)
    end

    test "also kills a rotation overlap credential" do
      %{node: node, credential: old} = enroll!()
      {:ok, %{node: rotated}} = Nodes.rotate_credential(node, @operator)
      assert {:ok, _} = Nodes.authenticate(old)

      {:ok, _} = Nodes.revoke(rotated, @operator)
      assert {:error, :invalid_credential} = Nodes.authenticate(old)
    end
  end

  describe "rotate_credential/2" do
    test "issues a new credential; the old one stays valid only for the overlap" do
      %{node: node, credential: old} = enroll!()

      assert {:ok, %{node: rotated, credential: new}} = Nodes.rotate_credential(node, @operator)
      assert new != old
      assert rotated.credential_hash != node.credential_hash
      assert {:ok, _} = Nodes.authenticate(new)
      assert {:ok, _} = Nodes.authenticate(old)

      later = DateTime.add(rotated.previous_valid_until, 1, :second)
      assert {:error, :invalid_credential} = Nodes.authenticate(old, now: later)
      assert {:ok, _} = Nodes.authenticate(new, now: later)
    end

    test "writes a rotated event with no secret in it" do
      %{node: node} = enroll!()
      {:ok, %{credential: new}} = Nodes.rotate_credential(node, @operator)

      assert [event] = events(:rotated)
      assert event.node_id == node.id
      refute inspect(event) =~ new
    end

    test "a revoked node cannot be rotated" do
      %{node: node} = enroll!()
      {:ok, revoked} = Nodes.revoke(node, @operator)

      assert {:error, :revoked} = Nodes.rotate_credential(revoked, @operator)
    end
  end

  describe "remove/2" do
    test "deletes a revoked node but keeps its history" do
      %{node: node} = enroll!()
      {:ok, revoked} = Nodes.revoke(node, @operator)

      assert :ok = Nodes.remove(revoked, @operator)
      assert Ash.read!(Node) == []

      assert [event] = events(:removed)
      assert event.node_id == node.id
      assert event.actor == "operator:cli"
      assert length(Nodes.events(node_id: node.id)) >= 3
    end

    test "refuses an active node" do
      %{node: node} = enroll!()

      assert {:error, :not_revoked} = Nodes.remove(node, @operator)
      assert [_] = Ash.read!(Node)
    end
  end

  describe "NodeEvent" do
    test "is append-only: no update or destroy action" do
      assert Ash.Resource.Info.actions(NodeEvent) |> Enum.map(& &1.type) |> Enum.sort() ==
               [:create, :read]
    end
  end
end
