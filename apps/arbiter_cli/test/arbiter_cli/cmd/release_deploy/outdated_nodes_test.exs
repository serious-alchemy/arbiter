defmodule ArbiterCli.Cmd.ReleaseDeploy.OutdatedNodesTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.ReleaseDeploy.OutdatedNodes

  @cmd "helm upgrade arbiter-node oci://x/chart --set image.tag=v0.2.90"

  defp row(attrs),
    do:
      Map.merge(
        %{"name" => "n", "state" => "online", "agent_version" => "0.2.90", "kind" => "cluster"},
        attrs
      )

  test "lists nodes behind the deployed version with their upgrade command" do
    nodes = [
      row(%{"name" => "mesaana", "agent_version" => "0.2.88", "upgrade_command" => @cmd}),
      row(%{"name" => "fresh"}),
      row(%{"name" => "gone", "agent_version" => "0.2.1", "state" => "revoked"}),
      row(%{"name" => "box", "kind" => "machine", "agent_version" => "0.2.80"})
    ]

    behind = OutdatedNodes.behind(nodes, "v0.2.90")
    assert Enum.map(behind, & &1.name) == ["mesaana", "box"]

    text = OutdatedNodes.text(behind, "v0.2.90")
    assert text =~ "mesaana"
    assert text =~ "0.2.88"
    assert text =~ "0.2.90"
    assert text =~ @cmd
    assert text =~ "arb node upgrade box"
    refute text =~ "fresh"
  end

  test "nothing behind prints nothing" do
    assert OutdatedNodes.behind([row(%{})], "v0.2.90") == []
    assert OutdatedNodes.text([], "v0.2.90") == nil
  end
end
