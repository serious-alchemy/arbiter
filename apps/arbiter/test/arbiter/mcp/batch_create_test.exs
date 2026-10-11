defmodule Arbiter.MCP.BatchCreateTest do
  @moduledoc """
  MCP side of batch ticket create and bulk dep_add: `ticket_create` with inline
  `depends_on` / `blocks`, `ticket_create_batch`, and `dep_add` with `edges`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Tasks.{BatchCreate, Dependencies, Dependency, Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "mcp-batch-#{System.unique_integer([:positive])}",
        prefix: "mb#{System.unique_integer([:positive])}"
      })

    coordinator = %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}
    %{ws: ws, coordinator: coordinator}
  end

  defp issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  # `Catalog.call/3` renders handler errors for the transport; fold them back to
  # `{:error, {kind, message}}` so the assertions read as the domain contract.
  defp call(scope, tool, args) do
    case Catalog.call(scope, tool, args) do
      {:tool_error, msg, "validation_error"} -> {:error, {:invalid, msg}}
      {:tool_error, msg, type} -> {:error, {String.to_existing_atom(type), msg}}
      {:rpc_error, _code, msg} -> {:error, {:unauthorized, msg}}
      other -> other
    end
  end

  defp worker_scope(ws, task) do
    %Scope{tier: :worker, workspace_id: ws.id, task_id: task.id, issue_id: task.id}
  end

  defp titles(ws) do
    Issue |> Ash.read!() |> Enum.filter(&(&1.workspace_id == ws.id)) |> Enum.map(& &1.title)
  end

  describe "ticket_create with depends_on / blocks" do
    test "creates the ticket and both edge kinds in one call", %{ws: ws, coordinator: c} do
      dep = issue!(ws, %{title: "dep"})
      target = issue!(ws, %{title: "target"})

      assert {:ok, created} =
               call(c, "ticket_create", %{
                 "title" => "gate",
                 "acceptance" => "x",
                 "depends_on" => [dep.id],
                 "blocks" => [target.id]
               })

      edges = Ash.read!(Dependency)

      assert Enum.any?(
               edges,
               &(&1.type == :blocks and &1.from_issue_id == dep.id and
                   &1.to_issue_id == created.id)
             )

      assert Enum.any?(
               edges,
               &(&1.type == :blocks and &1.from_issue_id == created.id and
                   &1.to_issue_id == target.id)
             )
    end

    test "a bad edge target creates nothing", %{ws: ws, coordinator: c} do
      assert {:error, {:not_found, msg}} =
               call(c, "ticket_create", %{
                 "title" => "orphan",
                 "acceptance" => "x",
                 "depends_on" => ["mb-nope"]
               })

      assert msg =~ "mb-nope"
      assert titles(ws) == []
    end

    test "a cycle creates nothing", %{ws: ws, coordinator: c} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})
      {:ok, _} = Dependencies.add(a.id, b.id, :blocks)

      assert {:error, {:invalid, msg}} =
               call(c, "ticket_create", %{
                 "title" => "loop",
                 "acceptance" => "x",
                 "depends_on" => [b.id],
                 "blocks" => [a.id]
               })

      assert msg =~ "cycle"
      refute "loop" in titles(ws)
    end

    test "a worker may not set depends_on or blocks", %{ws: ws} do
      task = issue!(ws, %{title: "worker task"})
      other = issue!(ws, %{title: "other"})

      assert {:error, {:unauthorized, msg}} =
               call(worker_scope(ws, task), "ticket_create", %{
                 "title" => "follow-up",
                 "parent_id" => task.id,
                 "depends_on" => [other.id]
               })

      assert msg =~ "depends_on"
      refute "follow-up" in titles(ws)
    end
  end

  describe "ticket_create_batch" do
    test "creates tickets and edges by ref and returns the ref map", %{ws: ws, coordinator: c} do
      existing = issue!(ws, %{title: "existing"})

      assert {:ok, res} =
               call(c, "ticket_create_batch", %{
                 "tickets" => [
                   %{"ref" => "epic", "title" => "the epic", "issue_type" => "epic"},
                   %{
                     "ref" => "a",
                     "title" => "step a",
                     "acceptance" => "x",
                     "parent_id" => "epic"
                   },
                   %{
                     "ref" => "b",
                     "title" => "step b",
                     "acceptance" => "x",
                     "parent_id" => "epic",
                     "depends_on" => ["a", existing.id]
                   }
                 ]
               })

      assert Map.keys(res.refs) |> Enum.sort() == ["a", "b", "epic"]
      assert res.counts == %{tickets: 3, edges: 4}
      assert [%{ref: "epic", state: "backlog"}, %{ref: "a"}, %{ref: "b"}] = res.tickets

      edges = Ash.read!(Dependency)

      assert Enum.any?(
               edges,
               &(&1.from_issue_id == existing.id and &1.to_issue_id == res.refs["b"])
             )

      assert Enum.any?(edges, &(&1.type == :parent_of and &1.to_issue_id == res.refs["a"]))
      refute Map.has_key?(res, :promote)
    end

    test "is atomic: a failing entry creates nothing and is named", %{ws: ws, coordinator: c} do
      assert {:error, {:not_found, msg}} =
               call(c, "ticket_create_batch", %{
                 "tickets" => [
                   %{"ref" => "a", "title" => "fine", "acceptance" => "x"},
                   %{"title" => "broken", "acceptance" => "x", "depends_on" => ["ghost"]}
                 ]
               })

      assert msg =~ "tickets[1]"
      assert titles(ws) == []
    end

    test "a duplicate title without force is refused naming the entry", %{ws: ws, coordinator: c} do
      issue!(ws, %{title: "taken"})

      assert {:error, {:conflict, msg}} =
               call(c, "ticket_create_batch", %{
                 "tickets" => [
                   %{"title" => "new one", "acceptance" => "x"},
                   %{"title" => "Taken", "acceptance" => "x"}
                 ]
               })

      assert msg =~ "tickets[1]"
      refute "new one" in titles(ws)

      assert {:ok, _} =
               call(c, "ticket_create_batch", %{
                 "force" => true,
                 "tickets" => [%{"title" => "Taken", "acceptance" => "x"}]
               })
    end

    test "promote: true promotes every ticket after the edges exist", %{ws: ws, coordinator: c} do
      assert {:ok, res} =
               call(c, "ticket_create_batch", %{
                 "promote" => true,
                 "tickets" => [
                   %{"ref" => "a", "title" => "first", "acceptance" => "x"},
                   %{
                     "ref" => "b",
                     "title" => "second",
                     "acceptance" => "x",
                     "depends_on" => ["a"]
                   }
                 ]
               })

      assert %{counts: %{total: 2, ok: 2}, results: [r0, _]} = res.promote
      assert r0.status == "ok"
      assert r0.ticket.state == "queued"

      assert Enum.all?(
               Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id)),
               &(&1.state == :queued)
             )
    end

    test "the batch size cap is a clear error", %{coordinator: c} do
      tickets = for i <- 1..(BatchCreate.max_batch() + 1), do: %{"title" => "t#{i}"}

      assert {:error, {:invalid_request, msg}} =
               call(c, "ticket_create_batch", %{"tickets" => tickets})

      assert msg =~ "at most #{BatchCreate.max_batch()}"
    end

    test "a missing tickets array is invalid", %{coordinator: c} do
      assert {:error, {kind, _msg}} = call(c, "ticket_create_batch", %{})
      assert kind in [:invalid, :invalid_request]
    end

    test "a worker may file children of its own task, by entry", %{ws: ws} do
      task = issue!(ws, %{title: "worker task"})
      scope = worker_scope(ws, task)

      assert {:ok, res} =
               call(scope, "ticket_create_batch", %{
                 "tickets" => [
                   %{"title" => "child one", "parent_id" => task.id},
                   %{"title" => "child two", "parent_id" => task.id}
                 ]
               })

      assert res.counts.tickets == 2
    end

    test "a worker entry that is not a child of its own task refuses the whole batch", %{ws: ws} do
      task = issue!(ws, %{title: "worker task"})
      other = issue!(ws, %{title: "somebody else's"})
      scope = worker_scope(ws, task)

      assert {:error, {:unauthorized, msg}} =
               call(scope, "ticket_create_batch", %{
                 "tickets" => [
                   %{"title" => "child one", "parent_id" => task.id},
                   %{"title" => "sneaky", "parent_id" => other.id}
                 ]
               })

      assert msg =~ "tickets[1]"
      refute "child one" in titles(ws)
    end

    test "a worker may not use refs for the parent, depends_on or promote", %{ws: ws} do
      task = issue!(ws, %{title: "worker task"})
      scope = worker_scope(ws, task)

      assert {:error, {:unauthorized, _}} =
               call(scope, "ticket_create_batch", %{
                 "tickets" => [
                   %{"ref" => "p", "title" => "p", "parent_id" => task.id},
                   %{"title" => "c", "parent_id" => "p"}
                 ]
               })

      assert {:error, {:unauthorized, msg}} =
               call(scope, "ticket_create_batch", %{
                 "tickets" => [
                   %{"title" => "c", "parent_id" => task.id, "depends_on" => [task.id]}
                 ]
               })

      assert msg =~ "depends_on"

      assert {:error, {:unauthorized, msg}} =
               call(scope, "ticket_create_batch", %{
                 "promote" => true,
                 "tickets" => [%{"title" => "c", "parent_id" => task.id}]
               })

      assert msg =~ "promote"
    end
  end

  describe "dep_add with edges" do
    test "applies each edge and reports per-edge results", %{ws: ws, coordinator: c} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})
      d = issue!(ws, %{title: "d"})

      assert {:ok, res} =
               call(c, "dep_add", %{
                 "edges" => [
                   %{"from" => a.id, "to" => b.id, "type" => "blocks"},
                   %{"from" => b.id, "to" => a.id, "type" => "blocks"},
                   %{"from" => b.id, "to" => d.id, "type" => "parent_of"}
                 ]
               })

      assert %{counts: %{total: 3, ok: 2, rejected: 1}, results: [r0, r1, r2]} = res
      assert r0.status == "ok"
      assert r1.status == "rejected"
      assert r1.reason =~ "cycle"
      assert r2.status == "ok"
      assert length(Ash.read!(Dependency)) == 2
    end

    test "an unknown ticket is a per-edge rejection", %{ws: ws, coordinator: c} do
      a = issue!(ws, %{title: "a"})

      assert {:ok, %{results: [r]}} =
               call(c, "dep_add", %{
                 "edges" => [%{"from" => a.id, "to" => "mb-nope", "type" => "blocks"}]
               })

      assert r.status == "rejected"
    end

    test "the single form is unchanged", %{ws: ws, coordinator: c} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})

      assert {:ok, dep} =
               call(c, "dep_add", %{
                 "from_issue_id" => a.id,
                 "to_issue_id" => b.id,
                 "type" => "blocks"
               })

      assert dep.type == "blocks"
    end

    test "the batch size cap is a clear error", %{ws: ws, coordinator: c} do
      a = issue!(ws, %{title: "a"})

      edges =
        for i <- 1..(Arbiter.Tasks.BulkEdges.max_batch() + 1),
            do: %{"from" => a.id, "to" => "x#{i}", "type" => "blocks"}

      assert {:error, {:invalid, msg}} = call(c, "dep_add", %{"edges" => edges})
      assert msg =~ "at most"
    end

    test "worker rules apply per edge: only parent_of from its own task", %{ws: ws} do
      task = issue!(ws, %{title: "worker task"})
      kid = issue!(ws, %{title: "kid"})
      other = issue!(ws, %{title: "other"})
      scope = worker_scope(ws, task)

      assert {:ok, %{results: [ok, bad], counts: %{ok: 1, rejected: 1}}} =
               call(scope, "dep_add", %{
                 "edges" => [
                   %{"from" => task.id, "to" => kid.id, "type" => "parent_of"},
                   %{"from" => other.id, "to" => kid.id, "type" => "blocks"}
                 ]
               })

      assert ok.status == "ok"
      assert bad.status == "rejected"
      assert bad.reason =~ "parent_of"
      assert [%{type: :parent_of}] = Ash.read!(Dependency)
    end
  end
end
