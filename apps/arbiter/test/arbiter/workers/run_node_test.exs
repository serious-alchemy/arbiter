defmodule Arbiter.Workers.RunNodeTest do
  use Arbiter.DataCase, async: true

  alias Arbiter.Workers.RunNode

  defp node!(name) do
    Ash.create!(
      Arbiter.Nodes.Node,
      %{
        name: name,
        credential_hash: "h-#{System.unique_integer([:positive])}",
        credential_prefix: "p",
        enrolled_at: DateTime.utc_now()
      },
      action: :enroll
    )
  end

  test "a run with no node is local: both fields nil" do
    assert RunNode.fields(%{node_id: nil}) == %{node_id: nil, node_name: nil}
    assert RunNode.fields(%{}) == %{node_id: nil, node_name: nil}
    assert RunNode.label(%{node_id: nil}) == "local"
    refute RunNode.remote?(%{node_id: nil})
  end

  test "a remote run carries the node id and its name" do
    node = node!("box-#{System.unique_integer([:positive])}")
    view = %{node_id: node.id}

    assert RunNode.fields(view) == %{node_id: node.id, node_name: node.name}
    assert RunNode.label(view) == node.name
    assert RunNode.remote?(view)
  end

  test "reads the node off the run row a view carries" do
    node = node!("rowbox-#{System.unique_integer([:positive])}")
    assert RunNode.fields(%{run: %Arbiter.Workers.Run{node_id: node.id}}).node_name == node.name
  end

  test "a node that no longer exists falls back to its id" do
    id = Ecto.UUID.generate()
    assert RunNode.fields(%{node_id: id}) == %{node_id: id, node_name: id}
  end
end
