defmodule Arbiter.Tasks.BatchCreateTest do
  @moduledoc """
  `Arbiter.Tasks.BatchCreate` — many tickets plus their edges in one atomic
  write, with in-batch `ref` resolution and an optional promote that runs only
  after every edge exists.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.BatchCreate
  alias Arbiter.Tasks.Dedup
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "batch-ws-#{System.unique_integer([:positive])}",
        prefix: "bt#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp entry(title, extra \\ %{}) do
    Map.merge(%{"title" => title, "acceptance" => "done"}, extra)
  end

  defp run(entries, ws, opts \\ []) do
    {:ok, parsed} = BatchCreate.parse(entries, fn attrs -> {:ok, attrs} end)
    BatchCreate.run(parsed, Keyword.merge([workspace_id: ws.id], opts))
  end

  defp titles(ws) do
    Issue |> Ash.read!() |> Enum.filter(&(&1.workspace_id == ws.id)) |> Enum.map(& &1.title)
  end

  defp edges, do: Ash.read!(Dependency)

  describe "parse/2" do
    test "enforces the batch size cap with a clear error" do
      raw = for i <- 1..(BatchCreate.max_batch() + 1), do: %{"title" => "t#{i}"}

      assert {:error, {:invalid_request, msg, _}} = BatchCreate.parse(raw, &{:ok, &1})
      assert msg =~ "at most #{BatchCreate.max_batch()}"
    end

    test "an empty or non-list batch is refused" do
      assert {:error, {:invalid_request, _, _}} = BatchCreate.parse([], &{:ok, &1})
      assert {:error, {:invalid_request, _, _}} = BatchCreate.parse(%{}, &{:ok, &1})
    end

    test "a malformed entry is named by index and title" do
      assert {:error, {:invalid_request, msg, %{index: 1}}} =
               BatchCreate.parse(
                 [%{"title" => "ok"}, %{"title" => "bad", "depends_on" => "x"}],
                 &{:ok, &1}
               )

      assert msg =~ "tickets[1]"
      assert msg =~ "depends_on"
    end

    test "a prep failure is named by entry" do
      prep = fn attrs ->
        if attrs["title"] == "no", do: {:error, {:invalid, "nope"}}, else: {:ok, attrs}
      end

      assert {:error, {:invalid, msg, %{index: 1, title: "no"}}} =
               BatchCreate.parse([%{"title" => "yes"}, %{"title" => "no"}], prep)

      assert msg =~ "tickets[1]"
      assert msg =~ "nope"
    end
  end

  describe "run/2 — refs and edges" do
    test "creates every ticket and edge and returns the ref → id map", %{ws: ws} do
      assert {:ok, result} =
               run(
                 [
                   entry("epic", %{"ref" => "epic", "issue_type" => "epic"}),
                   entry("first", %{"ref" => "a", "parent_id" => "epic"}),
                   entry("second", %{"ref" => "b", "parent_id" => "epic", "depends_on" => ["a"]}),
                   entry("third", %{
                     "ref" => "c",
                     "parent_id" => "epic",
                     "depends_on" => ["a", "b"]
                   })
                 ],
                 ws
               )

      refs = result.refs
      assert Map.keys(refs) |> Enum.sort() == ["a", "b", "c", "epic"]
      assert [%{ref: "epic"}, %{ref: "a"}, %{ref: "b"}, %{ref: "c"}] = result.tickets

      all = edges()
      assert length(all) == 3 + 3

      assert Enum.any?(
               all,
               &(&1.type == :parent_of and &1.from_issue_id == refs["epic"] and
                   &1.to_issue_id == refs["b"])
             )

      # depends_on: the dependency blocks the new ticket.
      assert Enum.any?(
               all,
               &(&1.type == :blocks and &1.from_issue_id == refs["a"] and
                   &1.to_issue_id == refs["b"])
             )

      assert Enum.any?(
               all,
               &(&1.type == :blocks and &1.from_issue_id == refs["b"] and
                   &1.to_issue_id == refs["c"])
             )
    end

    test "forward refs work: a ticket may depend on one listed after it", %{ws: ws} do
      assert {:ok, %{refs: refs}} =
               run(
                 [
                   entry("later one", %{"ref" => "x", "depends_on" => ["y"]}),
                   entry("earlier one", %{"ref" => "y"})
                 ],
                 ws
               )

      assert [%{from_issue_id: from, to_issue_id: to, type: :blocks}] = edges()
      assert from == refs["y"]
      assert to == refs["x"]
    end

    test "blocks points the other way and ids may be existing tickets", %{ws: ws} do
      {:ok, existing} = Ash.create(Issue, %{title: "existing", workspace_id: ws.id})
      {:ok, parent} = Ash.create(Issue, %{title: "existing parent", workspace_id: ws.id})

      assert {:ok, %{refs: refs}} =
               run(
                 [
                   entry("gate", %{
                     "ref" => "g",
                     "blocks" => [existing.id],
                     "parent_id" => parent.id
                   })
                 ],
                 ws
               )

      all = edges()

      assert Enum.any?(
               all,
               &(&1.type == :blocks and &1.from_issue_id == refs["g"] and
                   &1.to_issue_id == existing.id)
             )

      assert Enum.any?(
               all,
               &(&1.type == :parent_of and &1.from_issue_id == parent.id and
                   &1.to_issue_id == refs["g"])
             )
    end

    test "entries without a ref are created and listed but not in the map", %{ws: ws} do
      assert {:ok, %{refs: refs, tickets: [%{ref: nil, issue: %Issue{}}]}} =
               run([entry("anon")], ws)

      assert refs == %{}
    end

    test "created_by is stamped on the edges", %{ws: ws} do
      assert {:ok, _} =
               run(
                 [entry("p", %{"ref" => "p"}), entry("c", %{"ref" => "c", "parent_id" => "p"})],
                 ws,
                 created_by: "tester"
               )

      assert [%{created_by: "tester"}] = edges()
    end
  end

  describe "run/2 — atomicity" do
    test "an unknown ref creates nothing and names the failing entry", %{ws: ws} do
      assert {:error, {:not_found, msg, details}} =
               run(
                 [entry("fine", %{"ref" => "a"}), entry("broken", %{"depends_on" => ["ghost"]})],
                 ws
               )

      assert msg =~ "tickets[1]"
      assert msg =~ "ghost"
      assert details.index == 1
      assert titles(ws) == []
      assert edges() == []
    end

    test "a cycle among the batch's own edges creates nothing", %{ws: ws} do
      assert {:error, {:invalid, msg, %{index: index}}} =
               run(
                 [
                   entry("one", %{"ref" => "a", "depends_on" => ["b"]}),
                   entry("two", %{"ref" => "b", "depends_on" => ["a"]})
                 ],
                 ws
               )

      assert msg =~ "cycle"
      assert index in [0, 1]
      assert titles(ws) == []
      assert edges() == []
    end

    test "a cycle through an existing ticket creates nothing", %{ws: ws} do
      {:ok, a} = Ash.create(Issue, %{title: "ex a", workspace_id: ws.id})
      {:ok, b} = Ash.create(Issue, %{title: "ex b", workspace_id: ws.id})
      {:ok, _} = Dependencies.add(a.id, b.id, :blocks)

      assert {:error, {:invalid, msg, _}} =
               run(
                 [entry("loop", %{"depends_on" => [b.id], "blocks" => [a.id]})],
                 ws
               )

      assert msg =~ "cycle"
      assert Enum.sort(titles(ws)) == ["ex a", "ex b"]
      assert length(edges()) == 1
    end

    test "a parent_ref cycle is refused", %{ws: ws} do
      assert {:error, {:invalid, msg, _}} =
               run(
                 [
                   entry("one", %{"ref" => "a", "parent_id" => "b"}),
                   entry("two", %{"ref" => "b", "parent_id" => "a"})
                 ],
                 ws
               )

      assert msg =~ "parent"
      assert titles(ws) == []
    end

    test "an entry that references itself is refused", %{ws: ws} do
      assert {:error, {:invalid, msg, %{index: 0}}} =
               run([entry("me", %{"ref" => "a", "depends_on" => ["a"]})], ws)

      assert msg =~ "itself"
      assert titles(ws) == []
    end

    test "an ash validation failure (bad priority) rolls everything back", %{ws: ws} do
      assert {:error, {:invalid, msg, %{index: 2}}} =
               run(
                 [
                   entry("ok one", %{"ref" => "a"}),
                   entry("ok two", %{"ref" => "b", "depends_on" => ["a"]}),
                   entry("bad", %{"priority" => 99})
                 ],
                 ws
               )

      assert msg =~ "tickets[2]"
      assert titles(ws) == []
      assert edges() == []
    end

    test "an edge failing after earlier tickets were written rolls them all back", %{ws: ws} do
      writer = fn from, to, type, opts ->
        if type == :blocks,
          do: {:error, {:not_found, "gone"}},
          else: Dependencies.add(from, to, type, opts)
      end

      assert {:error, {:invalid, msg, %{index: 1}}} =
               run(
                 [
                   entry("p", %{"ref" => "p"}),
                   entry("c", %{"ref" => "c", "parent_id" => "p", "depends_on" => ["p"]})
                 ],
                 ws,
                 edge_writer: writer
               )

      assert msg =~ "gone"
      assert titles(ws) == []
      assert edges() == []
    end

    test "a missing existing ticket and a foreign-workspace ticket are refused", %{ws: ws} do
      {:ok, other} =
        Ash.create(Workspace, %{name: "other-#{System.unique_integer([:positive])}", prefix: "ot"})

      {:ok, foreign} = Ash.create(Issue, %{title: "foreign", workspace_id: other.id})

      assert {:error, {:not_found, msg, %{index: 0}}} =
               run([entry("a", %{"depends_on" => ["bt-nope"]})], ws)

      assert msg =~ "bt-nope"

      assert {:error, {:invalid, msg, %{index: 0}}} =
               run([entry("a", %{"parent_id" => foreign.id})], ws)

      assert msg =~ "workspace"
      assert titles(ws) == []
    end

    test "a ref that collides with an existing ticket id is refused", %{ws: ws} do
      {:ok, existing} = Ash.create(Issue, %{title: "existing", workspace_id: ws.id})

      assert {:error, {:invalid, msg, %{index: 0}}} =
               run([entry("a", %{"ref" => existing.id})], ws)

      assert msg =~ "collides"
    end

    test "duplicate refs are refused", %{ws: ws} do
      assert {:error, {:invalid, msg, %{index: 1}}} =
               run([entry("a", %{"ref" => "r"}), entry("b", %{"ref" => "r"})], ws)

      assert msg =~ "duplicate ref"
    end
  end

  describe "run/2 — duplicate titles" do
    test "an open ticket with the same title refuses the batch and names the entry", %{ws: ws} do
      {:ok, existing} = Ash.create(Issue, %{title: "already here", workspace_id: ws.id})

      assert {:error, {:conflict, msg, %{index: 1, matches: [%{id: id}]}}} =
               run([entry("brand new"), entry("Already Here")], ws)

      assert id == existing.id
      assert msg =~ "tickets[1]"
      assert msg =~ "force"
      assert Dedup.local_matches("brand new", ws.id) == []
    end

    test "two entries with the same title refuse unless forced", %{ws: ws} do
      assert {:error, {:conflict, msg, %{index: 1}}} =
               run([entry("same"), entry("same")], ws)

      assert msg =~ "tickets[1]"
      assert titles(ws) == []

      assert {:ok, _} = run([entry("same"), entry("same", %{"force" => true})], ws)
      assert titles(ws) == ["same", "same"]
    end

    test "a batch-level force skips the check for every entry", %{ws: ws} do
      {:ok, _} = Ash.create(Issue, %{title: "already here", workspace_id: ws.id})
      assert {:ok, _} = run([entry("already here")], ws, force: true)
    end
  end

  describe "run/2 — promote" do
    test "promotes only after every edge exists, with per-id results", %{ws: ws} do
      test_pid = self()

      promoter = fn issue ->
        # At the moment the first promote runs, the whole graph must be there.
        send(test_pid, {:edges_at_promote, issue.id, length(edges())})
        Ash.update(issue, %{}, action: :promote_to_ready)
      end

      assert {:ok, result} =
               run(
                 [
                   entry("first", %{"ref" => "a"}),
                   entry("second", %{"ref" => "b", "depends_on" => ["a"]}),
                   entry("third", %{"ref" => "c", "depends_on" => ["a", "b"], "blocks" => []})
                 ],
                 ws,
                 promote: true,
                 promoter: promoter
               )

      for _ <- 1..3 do
        assert_received {:edges_at_promote, _id, 3}
      end

      assert %{results: results, counts: %{total: 3, ok: 3}} = result.promote
      assert Enum.map(results, & &1.id) == Enum.map(result.tickets, & &1.issue.id)

      assert Enum.all?(
               Ash.read!(Issue) |> Enum.filter(&(&1.workspace_id == ws.id)),
               &(&1.state != :backlog)
             )
    end

    test "a refused promote is a per-id result, not a batch failure", %{ws: ws} do
      promoter = fn issue ->
        if issue.title == "second", do: {:error, "held"}, else: {:ok, issue}
      end

      assert {:ok, result} =
               run([entry("first"), entry("second")], ws, promote: true, promoter: promoter)

      assert result.promote.counts == %{total: 2, ok: 1, refused: 1, not_found: 0}
      assert length(result.tickets) == 2
    end

    test "nothing is promoted when the batch is refused", %{ws: ws} do
      promoter = fn _ -> flunk("promote must not run for a failed batch") end

      assert {:error, _} =
               run([entry("a", %{"depends_on" => ["ghost"]})], ws,
                 promote: true,
                 promoter: promoter
               )
    end

    test "without promote there is no promote result and tickets stay in backlog", %{ws: ws} do
      assert {:ok, %{promote: nil, tickets: [%{issue: issue}]}} = run([entry("a")], ws)
      assert issue.state == :backlog
    end
  end
end
