defmodule Arbiter.Tasks.BulkEdgesTest do
  @moduledoc """
  Bulk `dep_add` core: a list of `{from, to, type}` edges, applied in order,
  each with its own `ok | rejected` result. A rejected edge (cycle, unknown
  ticket, cross-workspace, bad type) does not roll back the accepted ones.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.BulkEdges
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "bulk-edges-#{System.unique_integer([:positive])}",
        prefix: "be#{System.unique_integer([:positive])}"
      })

    [a, b, c] =
      for t <- ~w(a b c) do
        {:ok, i} = Ash.create(Issue, %{title: "issue #{t}", workspace_id: ws.id})
        i
      end

    %{ws: ws, a: a, b: b, c: c}
  end

  describe "fetch_edges/1" do
    test "accepts from/to or from_issue_id/to_issue_id" do
      assert {:ok,
              [%{from: "x", to: "y", type: "blocks"}, %{from: "p", to: "q", type: "parent_of"}]} =
               BulkEdges.fetch_edges(%{
                 "edges" => [
                   %{"from" => "x", "to" => "y", "type" => "blocks"},
                   %{"from_issue_id" => "p", "to_issue_id" => "q", "type" => "parent_of"}
                 ]
               })
    end

    test "rejects a missing, empty or malformed list and names the bad entry" do
      assert {:error, msg} = BulkEdges.fetch_edges(%{})
      assert msg =~ "edges"
      assert {:error, _} = BulkEdges.fetch_edges(%{"edges" => []})

      assert {:error, msg} =
               BulkEdges.fetch_edges(%{
                 "edges" => [%{"from" => "x", "to" => "y", "type" => "blocks"}, %{"from" => "x"}]
               })

      assert msg =~ "edges[1]"
    end

    test "enforces the batch size cap" do
      edges =
        for i <- 1..(BulkEdges.max_batch() + 1),
            do: %{"from" => "a#{i}", "to" => "b", "type" => "blocks"}

      assert {:error, msg} = BulkEdges.fetch_edges(%{"edges" => edges})
      assert msg =~ "at most #{BulkEdges.max_batch()}"
    end
  end

  describe "run/2" do
    test "applies every edge and reports ok per edge", %{a: a, b: b, c: c} do
      edges = [
        %{from: a.id, to: b.id, type: "blocks"},
        %{from: b.id, to: c.id, type: "depends_on"}
      ]

      assert %{results: [r0, r1], counts: counts} = BulkEdges.run(edges, [])
      assert %{index: 0, status: "ok"} = r0
      assert %{index: 1, status: "ok"} = r1
      assert counts == %{total: 2, ok: 2, rejected: 0}
      assert length(Ash.read!(Dependency)) == 2
    end

    test "a cycle is rejected with its reason; the other edges still land", %{a: a, b: b, c: c} do
      edges = [
        %{from: a.id, to: b.id, type: "blocks"},
        # b blocks a would close a -> b -> a
        %{from: b.id, to: a.id, type: "blocks"},
        %{from: b.id, to: c.id, type: "blocks"}
      ]

      assert %{results: [r0, r1, r2], counts: counts} = BulkEdges.run(edges, [])
      assert r0.status == "ok"
      assert r1.status == "rejected"
      assert r1.reason =~ "cycle"
      assert r1.code == "cyclic"
      assert r2.status == "ok"
      assert counts == %{total: 3, ok: 2, rejected: 1}
      assert length(Ash.read!(Dependency)) == 2
    end

    test "later edges see earlier ones for the cycle check", %{a: a, b: b, c: c} do
      edges = [
        %{from: a.id, to: b.id, type: "blocks"},
        %{from: b.id, to: c.id, type: "blocks"},
        %{from: c.id, to: a.id, type: "blocks"}
      ]

      assert %{results: [_, _, r2]} = BulkEdges.run(edges, [])
      assert r2.status == "rejected"
      assert r2.code == "cyclic"
    end

    test "unknown tickets and bad types are per-edge rejections", %{a: a} do
      edges = [
        %{from: a.id, to: "nope-1", type: "blocks"},
        %{from: a.id, to: a.id, type: "nonsense"}
      ]

      assert %{results: [r0, r1]} = BulkEdges.run(edges, [])
      assert r0.status == "rejected"
      assert r0.code == "not_found"
      assert r1.status == "rejected"
      assert r1.code == "invalid_type"
    end

    test "a duplicate edge is rejected, not a crash", %{a: a, b: b} do
      edges = [%{from: a.id, to: b.id, type: "blocks"}, %{from: a.id, to: b.id, type: "blocks"}]
      assert %{results: [r0, r1]} = BulkEdges.run(edges, [])
      assert r0.status == "ok"
      assert r1.status == "rejected"
    end

    test "the authorize hook refuses an edge per edge", %{a: a, b: b, c: c} do
      edges = [%{from: a.id, to: b.id, type: "blocks"}, %{from: b.id, to: c.id, type: "blocks"}]

      authorize = fn
        %{from: from} when from == b.id -> {:error, "not yours"}
        _ -> :ok
      end

      assert %{results: [r0, r1]} = BulkEdges.run(edges, authorize: authorize)
      assert r0.status == "ok"
      assert r1.status == "rejected"
      assert r1.reason == "not yours"
    end

    test "created_by and notes are stamped on the edge", %{a: a, b: b} do
      edges = [%{from: a.id, to: b.id, type: "blocks", notes: "why"}]
      assert %{results: [%{status: "ok"}]} = BulkEdges.run(edges, created_by: "tester")
      assert [%{created_by: "tester", notes: "why"}] = Ash.read!(Dependency)
    end
  end
end
