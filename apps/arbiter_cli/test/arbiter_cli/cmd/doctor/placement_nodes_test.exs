defmodule ArbiterCli.Cmd.Doctor.PlacementNodesTest do
  use ExUnit.Case, async: true

  alias ArbiterCli.Cmd.Doctor.Checks
  alias ArbiterCli.Cmd.Doctor.Scope

  test "shows each remote-placing workspace's effective node set" do
    scope = %Scope{
      known?: true,
      placement_nodes: [
        %{
          "workspace" => "emricare",
          "mode" => "remote_only",
          "allowlist" => "kind:machine",
          "nodes" => ["mesaana"]
        },
        %{
          "workspace" => "default",
          "mode" => "prefer_remote",
          "allowlist" => nil,
          "nodes" => ["a", "b"]
        },
        %{"workspace" => "solo", "mode" => "local_only", "allowlist" => nil, "nodes" => []}
      ]
    }

    results = Checks.check_placement_nodes(scope)
    assert length(results) == 2
    em = Enum.find(results, &(&1.name =~ "emricare"))
    assert em.detail =~ "kind:machine"
    assert em.detail =~ "mesaana"
    assert Enum.find(results, &(&1.name =~ "default")).detail =~ "unset: any node"
  end

  test "n/a when nothing places remotely" do
    assert [%{status: :na}] = Checks.check_placement_nodes(%Scope{})
  end
end
