defmodule Arbiter.NodeAgent.K8s.SweeperTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Sweeper

  @labels %{"arbiter.dev/install" => "inst-1", "arbiter.dev/node" => "node-1"}

  defp pod(name, labels, extra \\ %{}) do
    %{
      "metadata" =>
        Map.merge(%{"name" => name, "uid" => "uid-#{name}", "labels" => labels}, extra)
    }
  end

  defp run_pod(run, extra_labels \\ %{}, meta \\ %{}),
    do: pod("pod-#{run}", Map.merge(@labels, Map.put(extra_labels, "arbiter.dev/run", run)), meta)

  defp select(pods, overrides \\ []) do
    opts =
      Keyword.merge(
        [install: "inst-1", node: "node-1", live_set: [], own_pod: "arbiter-controller-abc"],
        overrides
      )

    pods |> Sweeper.select(opts) |> Enum.map(& &1.run)
  end

  test "a pod of ours whose run is outside the live set is selected" do
    assert select([run_pod("r1"), run_pod("r2")], live_set: ["r2"]) == ["r1"]
  end

  test "the selection carries what the delete needs: name, uid, run" do
    assert [%{name: "pod-r1", uid: "uid-pod-r1", run: "r1"}] =
             Sweeper.select([run_pod("r1")], install: "inst-1", node: "node-1", live_set: [])
  end

  test "a pod missing any one of the three labels is never selected" do
    base = Map.put(@labels, "arbiter.dev/run", "r1")

    for missing <- Map.keys(base) do
      assert select([pod("p", Map.delete(base, missing))]) == []
    end

    assert select([pod("p", %{})]) == []
    assert select([pod("p", %{"arbiter.dev/run" => "r1"})]) == []
  end

  test "an empty run label is not a run" do
    assert select([pod("p", Map.put(@labels, "arbiter.dev/run", ""))]) == []
  end

  test "another install's or another node's pods are never selected" do
    other_install = pod("a", %{@labels | "arbiter.dev/install" => "inst-2"} |> Map.put("arbiter.dev/run", "r1"))
    other_node = pod("b", %{@labels | "arbiter.dev/node" => "node-2"} |> Map.put("arbiter.dev/run", "r2"))
    assert select([other_install, other_node]) == []
  end

  test "never its own pod, by name or by uid, even if it were mislabelled" do
    own_by_name =
      pod("arbiter-controller-abc", Map.put(@labels, "arbiter.dev/run", "r1"))

    own_by_uid =
      pod("other-name", Map.put(@labels, "arbiter.dev/run", "r2"), %{"uid" => "own-uid"})

    assert select([own_by_name, own_by_uid], own_uid: "own-uid") == []
  end

  test "an empty or missing install/node never sweeps anything" do
    assert Sweeper.select([run_pod("r1")], install: "", node: "node-1", live_set: []) == []
    assert Sweeper.select([run_pod("r1")], install: "inst-1", node: nil, live_set: []) == []
  end

  test "a pod already being deleted is left alone" do
    deleting = run_pod("r1", %{}, %{"deletionTimestamp" => "2026-10-10T00:00:00Z"})
    assert select([deleting]) == []
  end

  test "protected runs (just assigned, not yet in the live set) are kept" do
    assert select([run_pod("r1"), run_pod("r2")], protected: ["r1"]) == ["r2"]
  end

  test "ordering is stable" do
    assert select([run_pod("b"), run_pod("a"), run_pod("c")]) == ["a", "b", "c"]
  end
end
