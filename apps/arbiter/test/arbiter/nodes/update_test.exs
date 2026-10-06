defmodule Arbiter.Nodes.UpdateTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Actor
  alias Arbiter.Nodes

  @operator Actor.operator("cli")

  defp enroll!(name \\ "box-1") do
    {:ok, %{token: token}} = Nodes.mint_join_token([], @operator)
    {:ok, %{node: node}} = Nodes.redeem_join_token(token, %{name: name})
    node
  end

  describe "update_node/3" do
    test "sets labels and max_workers and records an `updated` event" do
      node = enroll!()

      assert {:ok, updated} =
               Nodes.update_node(node, %{labels: ["gpu=no", "zone=a"], max_workers: 3}, @operator)

      assert updated.labels == ["gpu=no", "zone=a"]
      assert updated.max_workers == 3

      assert [event] = Nodes.events(node_id: node.id, kind: :updated)
      assert event.actor == "operator:cli"
      assert event.detail["changes"] == %{"labels" => ["gpu=no", "zone=a"], "max_workers" => 3}
    end

    test "renames, refusing a name another node holds" do
      node = enroll!("a")
      _other = enroll!("b")

      assert {:ok, %{name: "c"}} = Nodes.update_node(node, %{name: "c"}, @operator)

      assert {:error, :name_taken} =
               Nodes.update_node(Nodes.get_node(node.id), %{name: "b"}, @operator)
    end

    test "max_workers: nil clears the cap; zero is refused" do
      node = enroll!()
      {:ok, node} = Nodes.update_node(node, %{max_workers: 2}, @operator)
      assert {:error, _} = Nodes.update_node(node, %{max_workers: 0}, @operator)
      assert {:ok, %{max_workers: nil}} = Nodes.update_node(node, %{max_workers: nil}, @operator)
    end

    test "cannot touch credentials or status" do
      node = enroll!()

      assert {:ok, same} =
               Nodes.update_node(
                 node,
                 %{status: :revoked, credential_hash: "x", join_token_id: "y"},
                 @operator
               )

      assert same.status == :active
      assert same.credential_hash == node.credential_hash
      assert Nodes.events(node_id: node.id, kind: :updated) == []
    end

    test "a revoked node is not editable" do
      node = enroll!()
      {:ok, _} = Nodes.revoke(node, @operator)

      assert {:error, :revoked} =
               Nodes.update_node(Nodes.get_node(node.id), %{max_workers: 1}, @operator)
    end
  end

  describe "find_node/1" do
    test "resolves by id or by name" do
      node = enroll!("named")
      assert %{id: id} = Nodes.find_node("named")
      assert id == node.id
      assert %{id: ^id} = Nodes.find_node(node.id)
      assert Nodes.find_node("nope") == nil
    end
  end
end
