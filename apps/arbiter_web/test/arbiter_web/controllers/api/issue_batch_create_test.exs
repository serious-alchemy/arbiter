defmodule ArbiterWeb.Api.IssueBatchCreateTest do
  @moduledoc """
  REST side of batch ticket create and bulk dependency add: `POST /api/issues`
  with `depends_on` / `blocks`, `POST /api/issues/batch` and `POST /api/dependencies`
  with a list of edges.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Tasks.{BatchCreate, BulkEdges, Dependency, Issue, Workspace}

  setup %{conn: conn} do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rest-batch-#{System.unique_integer([:positive])}",
        prefix: "rb#{System.unique_integer([:positive])}"
      })

    {:ok, conn: put_req_header(conn, "accept", "application/json"), ws: ws}
  end

  defp issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- ok"}, attrs))

    issue
  end

  defp titles(ws) do
    Issue |> Ash.read!() |> Enum.filter(&(&1.workspace_id == ws.id)) |> Enum.map(& &1.title)
  end

  defp as_worker(conn, task) do
    put_req_header(conn, "authorization", "Bearer " <> Arbiter.MCP.Scope.mint_worker(task))
  end

  describe "POST /api/issues — depends_on / blocks" do
    test "creates the edges with the ticket", %{conn: conn, ws: ws} do
      dep = issue!(ws, %{title: "dep"})
      target = issue!(ws, %{title: "target"})

      body =
        conn
        |> post(~p"/api/issues", %{
          "title" => "gate",
          "acceptance" => "x",
          "workspace_id" => ws.id,
          "depends_on" => [dep.id],
          "blocks" => [target.id]
        })
        |> json_response(201)

      edges = Ash.read!(Dependency)

      assert Enum.any?(
               edges,
               &(&1.from_issue_id == dep.id and &1.to_issue_id == body["id"] and
                   &1.type == :blocks)
             )

      assert Enum.any?(
               edges,
               &(&1.from_issue_id == body["id"] and &1.to_issue_id == target.id and
                   &1.type == :blocks)
             )
    end

    test "deps stays an alias of depends_on", %{conn: conn, ws: ws} do
      dep = issue!(ws, %{title: "dep"})

      body =
        conn
        |> post(~p"/api/issues", %{
          "title" => "gate",
          "acceptance" => "x",
          "workspace_id" => ws.id,
          "deps" => [dep.id]
        })
        |> json_response(201)

      assert [%{from_issue_id: from, to_issue_id: to}] = Ash.read!(Dependency)
      assert {from, to} == {dep.id, body["id"]}
    end

    test "a bad id or a cycle creates nothing", %{conn: conn, ws: ws} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})
      {:ok, _} = Arbiter.Tasks.Dependencies.add(a.id, b.id, :blocks)

      conn
      |> post(~p"/api/issues", %{
        "title" => "orphan",
        "workspace_id" => ws.id,
        "depends_on" => ["rb-nope"]
      })
      |> json_response(404)

      conn
      |> post(~p"/api/issues", %{
        "title" => "loop",
        "workspace_id" => ws.id,
        "depends_on" => [b.id],
        "blocks" => [a.id]
      })
      |> json_response(422)

      assert Enum.sort(titles(ws)) == ["a", "b"]
    end

    test "a malformed list is a 400", %{conn: conn, ws: ws} do
      conn
      |> post(~p"/api/issues", %{"title" => "x", "workspace_id" => ws.id, "blocks" => "nope"})
      |> json_response(400)
    end

    test "a worker may not set depends_on", %{conn: conn, ws: ws} do
      task = issue!(ws, %{title: "task"})
      other = issue!(ws, %{title: "other"})

      conn
      |> as_worker(task)
      |> post(~p"/api/issues", %{
        "title" => "follow-up",
        "workspace_id" => ws.id,
        "parent_id" => task.id,
        "depends_on" => [other.id]
      })
      |> json_response(403)

      refute "follow-up" in titles(ws)
    end
  end

  describe "POST /api/issues/batch" do
    test "creates tickets and edges by ref and returns the ref map", %{conn: conn, ws: ws} do
      existing = issue!(ws, %{title: "existing"})

      body =
        conn
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [
            %{"ref" => "epic", "title" => "epic", "issue_type" => "epic"},
            %{"ref" => "a", "title" => "a", "acceptance" => "x", "parent_id" => "epic"},
            %{
              "ref" => "b",
              "title" => "b",
              "acceptance" => "x",
              "parent_id" => "epic",
              "depends_on" => ["a", existing.id]
            }
          ]
        })
        |> json_response(201)

      assert body["refs"] |> Map.keys() |> Enum.sort() == ["a", "b", "epic"]
      assert body["counts"] == %{"tickets" => 3, "edges" => 4}
      assert [%{"ref" => "epic"}, %{"ref" => "a"}, %{"ref" => "b"}] = body["tickets"]
      refute Map.has_key?(body, "promote")

      refs = body["refs"]
      edges = Ash.read!(Dependency)
      assert Enum.any?(edges, &(&1.from_issue_id == refs["a"] and &1.to_issue_id == refs["b"]))
      assert Enum.any?(edges, &(&1.from_issue_id == existing.id and &1.to_issue_id == refs["b"]))
    end

    test "is atomic: a failing entry creates nothing and is named", %{conn: conn, ws: ws} do
      body =
        conn
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [
            %{"ref" => "a", "title" => "fine", "acceptance" => "x"},
            %{"title" => "broken", "acceptance" => "x", "depends_on" => ["ghost"]}
          ]
        })
        |> json_response(404)

      assert body["error"]["message"] =~ "tickets[1]"
      assert body["error"]["details"]["index"] == 1
      assert titles(ws) == []
    end

    test "a cycle, a bad priority and a duplicate title each refuse the whole batch",
         %{conn: conn, ws: ws} do
      issue!(ws, %{title: "taken"})

      cyc =
        conn
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [
            %{"ref" => "a", "title" => "a", "depends_on" => ["b"]},
            %{"ref" => "b", "title" => "b", "depends_on" => ["a"]}
          ]
        })
        |> json_response(422)

      assert cyc["error"]["message"] =~ "cycle"

      bad =
        conn
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [%{"title" => "ok one"}, %{"title" => "bad", "priority" => 99}]
        })
        |> json_response(422)

      assert bad["error"]["message"] =~ "tickets[1]"

      dup =
        conn
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [%{"title" => "fresh"}, %{"title" => "Taken"}]
        })
        |> json_response(409)

      assert dup["error"]["details"]["index"] == 1
      assert [%{"title" => "taken"}] = dup["error"]["details"]["matches"]

      assert titles(ws) == ["taken"]

      assert conn
             |> post(~p"/api/issues/batch", %{
               "workspace_id" => ws.id,
               "force" => true,
               "tickets" => [%{"title" => "Taken"}]
             })
             |> json_response(201)
    end

    test "promote: true promotes after the edges exist, per-id results", %{conn: conn, ws: ws} do
      body =
        conn
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "promote" => true,
          "tickets" => [
            %{"ref" => "a", "title" => "first", "acceptance" => "x"},
            %{"ref" => "b", "title" => "second", "acceptance" => "x", "depends_on" => ["a"]}
          ]
        })
        |> json_response(201)

      assert %{"counts" => %{"total" => 2, "ok" => 2}, "results" => [r0, _]} = body["promote"]
      assert r0["status"] == "ok"
      assert r0["ticket"]["state"] == "queued" or r0["ticket"]["state"] == :queued

      assert Enum.all?(
               Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id)),
               &(&1.state == :queued)
             )
    end

    test "the size cap is a 400", %{conn: conn, ws: ws} do
      tickets = for i <- 1..(BatchCreate.max_batch() + 1), do: %{"title" => "t#{i}"}

      body =
        conn
        |> post(~p"/api/issues/batch", %{"workspace_id" => ws.id, "tickets" => tickets})
        |> json_response(400)

      assert body["error"]["message"] =~ "at most #{BatchCreate.max_batch()}"
      assert titles(ws) == []
    end

    test "a missing tickets array is a 400", %{conn: conn, ws: ws} do
      conn |> post(~p"/api/issues/batch", %{"workspace_id" => ws.id}) |> json_response(400)
    end

    test "a worker files children of its own task, entry by entry", %{conn: conn, ws: ws} do
      task = issue!(ws, %{title: "task"})
      other = issue!(ws, %{title: "other"})

      ok =
        conn
        |> as_worker(task)
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [
            %{"title" => "child one", "parent_id" => task.id},
            %{"title" => "child two", "parent_id" => task.id}
          ]
        })
        |> json_response(201)

      assert ok["counts"]["tickets"] == 2

      body =
        conn
        |> as_worker(task)
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [
            %{"title" => "child three", "parent_id" => task.id},
            %{"title" => "sneaky", "parent_id" => other.id}
          ]
        })
        |> json_response(403)

      assert body["error"]["message"] =~ "tickets[1]"
      refute "child three" in titles(ws)

      for extra <- [%{"depends_on" => [other.id]}, %{"blocks" => [other.id]}] do
        conn
        |> as_worker(task)
        |> post(~p"/api/issues/batch", %{
          "workspace_id" => ws.id,
          "tickets" => [Map.merge(%{"title" => "x", "parent_id" => task.id}, extra)]
        })
        |> json_response(403)
      end

      conn
      |> as_worker(task)
      |> post(~p"/api/issues/batch", %{
        "workspace_id" => ws.id,
        "promote" => true,
        "tickets" => [%{"title" => "y", "parent_id" => task.id}]
      })
      |> json_response(403)
    end
  end

  describe "POST /api/dependencies — bulk" do
    test "edges: applies each and reports per-edge results", %{conn: conn, ws: ws} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})
      c = issue!(ws, %{title: "c"})

      body =
        conn
        |> post(~p"/api/dependencies", %{
          "edges" => [
            %{"from" => a.id, "to" => b.id, "type" => "blocks"},
            %{"from" => b.id, "to" => a.id, "type" => "blocks"},
            %{"from_issue_id" => b.id, "to_issue_id" => c.id, "type" => "parent_of"}
          ]
        })
        |> json_response(200)

      assert body["counts"] == %{"total" => 3, "ok" => 2, "rejected" => 1}
      assert [r0, r1, r2] = body["results"]
      assert r0["status"] == "ok"
      assert r1["status"] == "rejected"
      assert r1["code"] == "cyclic"
      assert r1["reason"] =~ "cycle"
      assert r2["status"] == "ok"
      assert length(Ash.read!(Dependency)) == 2
    end

    test "a bare JSON array body is accepted", %{conn: conn, ws: ws} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})

      body =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/dependencies",
          Jason.encode!([%{"from" => a.id, "to" => b.id, "type" => "blocks"}])
        )
        |> json_response(200)

      assert body["counts"]["ok"] == 1
    end

    test "the size cap and an empty list are 400s", %{conn: conn, ws: ws} do
      a = issue!(ws, %{title: "a"})

      edges =
        for i <- 1..(BulkEdges.max_batch() + 1),
            do: %{"from" => a.id, "to" => "x#{i}", "type" => "blocks"}

      body = conn |> post(~p"/api/dependencies", %{"edges" => edges}) |> json_response(400)
      assert body["error"]["message"] =~ "at most"

      conn |> post(~p"/api/dependencies", %{"edges" => []}) |> json_response(400)
    end

    test "worker rules apply per edge", %{conn: conn, ws: ws} do
      task = issue!(ws, %{title: "task"})
      kid = issue!(ws, %{title: "kid"})
      other = issue!(ws, %{title: "other"})

      body =
        conn
        |> as_worker(task)
        |> post(~p"/api/dependencies", %{
          "edges" => [
            %{"from" => task.id, "to" => kid.id, "type" => "parent_of"},
            %{"from" => other.id, "to" => kid.id, "type" => "blocks"}
          ]
        })
        |> json_response(200)

      assert [%{"status" => "ok"}, %{"status" => "rejected", "reason" => reason}] =
               body["results"]

      assert reason =~ "parent_of"
      assert [%{type: :parent_of}] = Ash.read!(Dependency)
    end

    test "the single form is unchanged", %{conn: conn, ws: ws} do
      a = issue!(ws, %{title: "a"})
      b = issue!(ws, %{title: "b"})

      body =
        conn
        |> post(~p"/api/dependencies", %{
          "from_issue_id" => a.id,
          "to_issue_id" => b.id,
          "type" => "blocks"
        })
        |> json_response(201)

      assert body["type"] == "blocks"
    end
  end
end
