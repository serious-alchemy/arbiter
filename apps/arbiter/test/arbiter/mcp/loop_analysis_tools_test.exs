defmodule Arbiter.MCP.LoopAnalysisToolsTest do
  # async: false — the pass reads via raw SQL on the sandbox connection.
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.PendingWrite
  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  defp workspace!(name \\ nil) do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: name || "lat-#{n}", prefix: "la#{n}"})
    ws
  end

  defp coordinator(ws \\ nil),
    do: %Scope{tier: :coordinator, workspace_id: ws && ws.id, can_dispatch: true}

  defp loop_events do
    Ash.read!(Event)
  end

  describe "loop_analyze" do
    test "returns the markdown report and structured summary, and records its own cost row" do
      ws = workspace!()
      before = length(loop_events())

      assert {:ok, body} = Catalog.call(coordinator(ws), "loop_analyze", %{"since" => "7d"})

      assert body.markdown =~ "Loop-analysis report"
      assert is_map(body.summary)
      assert body.summary.totals
      assert body.workspace_id == ws.id
      refute Map.has_key?(body, :proposals)
      assert length(loop_events()) == before + 1
      assert {:ok, %Event{}} = Ash.get(Event, body.usage_event_id)
    end

    test "queues nothing" do
      ws = workspace!()
      assert {:ok, _} = Catalog.call(coordinator(ws), "loop_analyze", %{})
      assert Loop.list_pending(workspace_id: ws.id, state: Loop.live_states()) == []
    end

    test "rejects a malformed since" do
      ws = workspace!()

      assert {:tool_error, msg, "validation_error"} =
               Catalog.call(coordinator(ws), "loop_analyze", %{"since" => "yesterdayish"})

      assert msg =~ "ISO8601"
    end

    test "rejects a non-positive limit; a huge limit is clamped, not refused" do
      ws = workspace!()

      assert {:tool_error, _, "validation_error"} =
               Catalog.call(coordinator(ws), "loop_analyze", %{"limit" => 0})

      assert {:ok, _} = Catalog.call(coordinator(ws), "loop_analyze", %{"limit" => 10_000_000})
    end

    test "an unknown workspace is not_found" do
      assert {:tool_error, _, "not_found"} =
               Catalog.call(coordinator(), "loop_analyze", %{"workspace" => "nope-nope"})
    end

    test "is not reachable by a worker" do
      ws = workspace!()
      worker = %Scope{tier: :worker, workspace_id: ws.id, task_id: "t", repo: "r"}
      assert {:rpc_error, -32_003, _} = Catalog.call(worker, "loop_analyze", %{})
      assert {:rpc_error, -32_003, _} = Catalog.call(worker, "loop_propose", %{})

      assert {:rpc_error, -32_003, _} =
               Catalog.call(worker, "loop_propose_repo_doc_patch", %{})
    end
  end

  describe "loop_propose" do
    test "is the analyze pass plus persistence: proposals and proposals_dropped keys" do
      ws = workspace!()
      assert {:ok, body} = Catalog.call(coordinator(ws), "loop_propose", %{})
      assert body.markdown =~ "Loop-analysis report"
      assert is_list(body.proposals)
      assert is_list(body.proposals_dropped)
    end
  end

  describe "loop_propose_repo_doc_patch" do
    test "hand-authors a :repo_doc_patch proposal in the resolved workspace" do
      ws = workspace!()

      assert {:ok, row} =
               Catalog.call(coordinator(ws), "loop_propose_repo_doc_patch", %{
                 "repo" => "arbiter",
                 "lesson" => "Run the formatter before pushing.",
                 "category" => "ci"
               })

      assert row.kind == :repo_doc_patch
      assert row.state == :proposed
      assert row.workspace_id == ws.id
      assert row.proposed == true
      assert %PendingWrite{} = Ash.get!(PendingWrite, row.id)
    end

    test "requires repo and lesson" do
      ws = workspace!()

      assert {:tool_error, _, "validation_error"} =
               Catalog.call(coordinator(ws), "loop_propose_repo_doc_patch", %{"lesson" => "x"})

      assert {:tool_error, _, "validation_error"} =
               Catalog.call(coordinator(ws), "loop_propose_repo_doc_patch", %{"repo" => "x"})
    end

    test "never writes into a workspace that merely is called default" do
      _a = workspace!("default")
      _b = workspace!()

      assert {:tool_error, msg, "validation_error"} =
               Catalog.call(coordinator(), "loop_propose_repo_doc_patch", %{
                 "repo" => "arbiter",
                 "lesson" => "x"
               })

      assert msg =~ "workspace"
    end
  end
end
