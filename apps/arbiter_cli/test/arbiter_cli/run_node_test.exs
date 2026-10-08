defmodule ArbiterCli.RunNodeTest do
  @moduledoc """
  bd-1b4k9r: every CLI view of a run says where it executes — the node's name,
  `local` for the primary. A payload with no `node_id` key (an older server)
  says nothing rather than guessing.
  """
  use ArbiterCli.CliCase, async: true

  alias ArbiterCli.Cmd.{Issue, Prime, Worker}
  alias ArbiterCli.RunLabel

  @remote %{"node_id" => "n-1", "node_name" => "gpu-box"}
  @local %{"node_id" => nil, "node_name" => nil}

  describe "RunLabel.where/1" do
    test "names the node, or local" do
      assert RunLabel.where(Map.merge(%{}, @remote)) == "gpu-box"
      assert RunLabel.where(@local) == "local"
      assert RunLabel.where(%{"node_id" => "n-9"}) == "n-9"
      assert RunLabel.where(%{}) == nil
      assert RunLabel.node_suffix(%{}) == ""
      assert RunLabel.node_suffix(@remote) == "  node=gpu-box"
    end
  end

  defp run(extra),
    do:
      Map.merge(
        %{
          "task_id" => "bd-001",
          "kind" => "implement",
          "state" => "working",
          "current_step" => "implement",
          "repo" => "test/repo",
          "started_at" => "2026-05-20T19:00:00Z"
        },
        extra
      )

  test "arb worker list shows the node per row" do
    stub_get("/api/workers", %{
      "data" => [run(@remote), run(Map.put(@local, "task_id", "bd-002"))]
    })

    {out, _err, 0} = capture(fn -> Worker.run(["list"]) end)

    assert out =~ ~r/bd-001 .*node=gpu-box/
    assert out =~ ~r/bd-002 .*node=local/
  end

  test "arb worker show prints a Node line, and node on each recent run" do
    stub_get(
      "/api/workers/bd-001",
      run(
        Map.merge(@remote, %{
          "output_lines" => [],
          "runs" => [
            Map.merge(@remote, %{"run_id" => "run-b", "kind" => "implement", "state" => "working"}),
            Map.merge(@local, %{"run_id" => "run-a", "kind" => "review", "state" => "finished"})
          ]
        })
      )
    )

    {out, _err, 0} = capture(fn -> Worker.run(["show", "bd-001"]) end)

    assert out =~ "Node:       gpu-box"
    assert out =~ ~r/run-b .*node=gpu-box/
    assert out =~ ~r/run-a .*node=local/
  end

  test "arb worker show on a local run says local" do
    stub_get("/api/workers/bd-001", run(Map.put(@local, "output_lines", [])))
    {out, _err, 0} = capture(fn -> Worker.run(["show", "bd-001"]) end)
    assert out =~ "Node:       local"
  end

  test "arb worker runs shows the node of each historical run" do
    stub_get("/api/workers/history", %{
      "data" => [
        Map.merge(@remote, %{"id" => "run-2", "task_id" => "bd-010", "kind" => "review"}),
        Map.merge(@local, %{"id" => "run-1", "task_id" => "bd-010", "kind" => "implement"})
      ]
    })

    {out, _err, 0} = capture(fn -> Worker.run(["runs", "bd-010"]) end)

    assert out =~ ~r/run-2 .*node=gpu-box/
    assert out =~ ~r/run-1 .*node=local/
  end

  test "arb prime's active workers section shows the node" do
    stub_routes([
      {{"get", "/api/workspaces"},
       {%{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd", "config" => %{}}]},
        200}},
      {{"get", "/api/workers"},
       {%{"data" => [run(Map.put(@remote, "workspace_id", "ws-1"))]}, 200}},
      {{"get", "/api/issues/lifecycle"}, {%{"data" => []}, 200}},
      {{"get", "/api/attention"}, {%{"attention" => []}, 200}},
      {{"get", "/api/messages"}, {%{"data" => []}, 200}}
    ])

    {out, _err, 0} = capture(fn -> Prime.run([]) end)

    assert out =~ ~r/bd-001 .*node=gpu-box/
  end

  test "arb ticket show's current run shows the node" do
    stub_get("/api/issues/bd-1", %{
      "id" => "bd-1",
      "title" => "on a node",
      "state" => "in_progress",
      "column" => "in_progress",
      "attention" => nil,
      "current_run" =>
        Map.merge(@remote, %{"kind" => "implement", "state" => "working", "phase" => nil})
    })

    {out, _err, 0} = capture(fn -> Issue.run(["show", "bd-1"]) end)

    [line] = Regex.run(~r/^Current run:.*$/m, out)
    assert line =~ "implement working"
    assert line =~ "node=gpu-box"
  end
end
