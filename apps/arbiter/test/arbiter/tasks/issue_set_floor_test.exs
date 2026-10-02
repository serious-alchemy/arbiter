defmodule Arbiter.Tasks.IssueSetFloorTest do
  @moduledoc """
  bd-3e7inj (ES2, `docs/design/epic-aware-scheduling.md` §6.2): the nullable
  `floor_priority` on `Issue` and the `:set_floor` action that is its only
  writer — epic-only, 1..3, operator/coordinator only, in the paper trail.
  """
  use Arbiter.DataCase, async: false

  require Ash.Query

  alias Arbiter.MCP.Scope
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "floor-#{System.unique_integer([:positive])}", prefix: "fl"})

    {:ok, ws: ws}
  end

  defp ticket(ws, attrs) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
      )

    issue
  end

  defp scope(tier), do: %Scope{tier: tier, workspace_id: nil, task_id: nil}

  describe "the column" do
    test "a new ticket has no floor", %{ws: ws} do
      assert ticket(ws, %{issue_type: :epic}).floor_priority == nil
      assert ticket(ws, %{issue_type: :task}).floor_priority == nil
    end

    test "create and update never accept floor_priority", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      assert {:error, _} =
               Ash.create(Issue, %{
                 title: "e",
                 workspace_id: ws.id,
                 issue_type: :epic,
                 floor_priority: 1
               })

      assert {:error, _} = Ash.update(epic, %{floor_priority: 1})
    end

    test "the database refuses a value outside 1..3", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      for bad <- [0, 4, -1] do
        assert_raise Exqlite.Error, ~r/CHECK constraint/, fn ->
          Repo.query!("UPDATE issues SET floor_priority = ?1 WHERE id = ?2", [bad, epic.id])
        end
      end

      for good <- [1, 2, 3] do
        Repo.query!("UPDATE issues SET floor_priority = ?1 WHERE id = ?2", [good, epic.id])
      end

      Repo.query!("UPDATE issues SET floor_priority = NULL WHERE id = ?1", [epic.id])
    end
  end

  describe ":set_floor" do
    test "sets and clears a floor on an epic", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      assert {:ok, floored} = Ash.update(epic, %{floor_priority: 1}, action: :set_floor)
      assert floored.floor_priority == 1
      assert Ash.get!(Issue, epic.id).floor_priority == 1

      assert {:ok, cleared} = Ash.update(floored, %{floor_priority: nil}, action: :set_floor)
      assert cleared.floor_priority == nil
      assert Ash.get!(Issue, epic.id).floor_priority == nil
    end

    test "never touches the epic's own priority", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic, priority: 3})
      {:ok, floored} = Ash.update(epic, %{floor_priority: 1}, action: :set_floor)
      assert floored.priority == 3
    end

    test "rejects a floor on a non-epic", %{ws: ws} do
      for type <- [:task, :feature, :bug, :chore] do
        issue = ticket(ws, %{issue_type: type})

        assert {:error, error} = Ash.update(issue, %{floor_priority: 1}, action: :set_floor)
        assert Exception.message(error) =~ "epic"
        assert Ash.get!(Issue, issue.id).floor_priority == nil
      end
    end

    test "clearing a floor on a non-epic is a no-op, not an error", %{ws: ws} do
      issue = ticket(ws, %{issue_type: :task})
      assert {:ok, same} = Ash.update(issue, %{floor_priority: nil}, action: :set_floor)
      assert same.floor_priority == nil
    end

    test "rejects P0, P4 and anything outside 1..3", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      for bad <- [0, 4, -1, 99] do
        assert {:error, _} = Ash.update(epic, %{floor_priority: bad}, action: :set_floor)
      end

      assert Ash.get!(Issue, epic.id).floor_priority == nil
    end

    test "retyping a floored epic away from :epic clears its floor", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})
      {:ok, floored} = Ash.update(epic, %{floor_priority: 2}, action: :set_floor)

      assert {:ok, retyped} = Ash.update(floored, %{issue_type: :task})
      assert retyped.floor_priority == nil
      assert Ash.get!(Issue, epic.id).floor_priority == nil
    end
  end

  describe "who may call it" do
    test "a coordinator-tier actor (operator and coordinator tokens) may", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      assert {:ok, floored} =
               Ash.update(epic, %{floor_priority: 2},
                 action: :set_floor,
                 actor: scope(:coordinator)
               )

      assert floored.floor_priority == 2
    end

    test "a worker-tier actor is refused and nothing changes", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      assert {:error, error} =
               Ash.update(epic, %{floor_priority: 2}, action: :set_floor, actor: scope(:worker))

      assert Exception.message(error) =~ "worker"
      assert Ash.get!(Issue, epic.id).floor_priority == nil
    end

    test "a refine-tier actor is refused too", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})

      assert {:error, _} =
               Ash.update(epic, %{floor_priority: 2},
                 action: :set_floor,
                 actor: %Scope{tier: :refine, workspace_id: ws.id, issue_id: epic.id}
               )
    end

    test "a worker may not clear a floor either", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})
      {:ok, floored} = Ash.update(epic, %{floor_priority: 2}, action: :set_floor)

      assert {:error, _} =
               Ash.update(floored, %{floor_priority: nil},
                 action: :set_floor,
                 actor: scope(:worker)
               )

      assert Ash.get!(Issue, epic.id).floor_priority == 2
    end
  end

  describe "paper trail" do
    test "set and clear each write a :set_floor version carrying the change", %{ws: ws} do
      epic = ticket(ws, %{issue_type: :epic})
      {:ok, floored} = Ash.update(epic, %{floor_priority: 1}, action: :set_floor)
      {:ok, _} = Ash.update(floored, %{floor_priority: nil}, action: :set_floor)

      versions =
        Issue.Version
        |> Ash.Query.filter(version_source_id == ^epic.id and version_action_name == :set_floor)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!()

      assert length(versions) == 2
      [set, clear] = versions
      assert set.changes["floor_priority"] == 1
      assert Map.has_key?(clear.changes, "floor_priority")
      assert clear.changes["floor_priority"] == nil
    end

    test "a refused call leaves no version row", %{ws: ws} do
      issue = ticket(ws, %{issue_type: :task})
      {:error, _} = Ash.update(issue, %{floor_priority: 1}, action: :set_floor)

      assert [] =
               Issue.Version
               |> Ash.Query.filter(
                 version_source_id == ^issue.id and version_action_name == :set_floor
               )
               |> Ash.read!()
    end
  end
end
