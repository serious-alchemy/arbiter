defmodule Arbiter.Nodes.AllowlistTest do
  use ExUnit.Case, async: true

  alias Arbiter.Nodes.Allowlist

  defp ws(selectors), do: %{config: %{"worker" => %{"placement_nodes" => selectors}}}

  test "unset (or empty) means any node" do
    assert Allowlist.selectors(nil) == nil
    assert Allowlist.selectors(%{config: %{}}) == nil
    assert Allowlist.selectors(ws([])) == nil
    assert Allowlist.allows?(nil, %{name: "x", kind: :cluster, labels: []})
  end

  test "parses prefixed and bare selectors" do
    assert Allowlist.selectors(
             ws(["kind:machine", "name:mesaana", "label:gpu=1", "cluster", "a=b", "oryx"])
           ) ==
             [
               {:kind, "machine"},
               {:name, "mesaana"},
               {:label, "gpu=1"},
               {:kind, "cluster"},
               {:label, "a=b"},
               {:name, "oryx"}
             ]
  end

  test "allows?/2 matches by kind, name and label; any selector suffices" do
    cluster = %{name: "vstim-k8s", kind: :cluster, labels: ["team=v"]}
    machine = %{name: "mesaana", kind: :machine, labels: []}

    assert Allowlist.allows?([{:kind, "machine"}], machine)
    refute Allowlist.allows?([{:kind, "machine"}], cluster)
    assert Allowlist.allows?([{:name, "mesaana"}], machine)
    refute Allowlist.allows?([{:name, "mesaana"}], cluster)
    assert Allowlist.allows?([{:label, "team=v"}], cluster)
    assert Allowlist.allows?([{:name, "mesaana"}, {:label, "team=v"}], cluster)
  end

  test "describe/1" do
    assert Allowlist.describe(nil) == "any node"
    assert Allowlist.describe([{:kind, "machine"}, {:name, "m"}]) == "kind:machine, name:m"
  end
end
