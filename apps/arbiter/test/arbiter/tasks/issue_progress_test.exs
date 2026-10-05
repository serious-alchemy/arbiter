defmodule Arbiter.Tasks.IssueProgressTest do
  @moduledoc """
  Unit coverage for the unified parent-with-progress concept: a task's
  `:child_total` / `:child_closed` rollup over its `:parent_of` children, and the
  `auto_close` flag that closes a parent once all its children are done. This is
  the surface that replaced the removed `Convoy` / `ConvoyMembership` resources.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Dependency, Issue, Workspace}

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "progress-ws", prefix: "pg"})
    {:ok, ws: ws}
  end

  defp child_of(parent, child) do
    {:ok, _} =
      Ash.create(Dependency, %{
        from_issue_id: parent.id,
        to_issue_id: child.id,
        type: :parent_of
      })
  end

  defp epic_escalations(epic) do
    Arbiter.Messages.Message
    |> Ash.read!()
    |> Enum.filter(&(&1.task_ref == epic.id and &1.escalation_kind == :epic_children_closed))
  end

  describe "child-progress calculations" do
    test "count children and closed children over :parent_of edges", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent", workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})
      {:ok, c3} = Ash.create(Issue, %{title: "c3", workspace_id: ws.id})

      Enum.each([c1, c2, c3], &child_of(parent, &1))
      {:ok, _} = Ash.update(c1, %{}, action: :close)

      parent = Ash.load!(parent, [:child_total, :child_closed])
      assert parent.child_total == 3
      assert parent.child_closed == 1
    end

    test "a leaf task has zero children", %{ws: ws} do
      {:ok, leaf} = Ash.create(Issue, %{title: "leaf", workspace_id: ws.id})
      leaf = Ash.load!(leaf, [:child_total, :child_closed])
      assert leaf.child_total == 0
      assert leaf.child_closed == 0
    end

    test "only :parent_of edges count — other dep types are ignored", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent", workspace_id: ws.id})
      {:ok, related} = Ash.create(Issue, %{title: "related", workspace_id: ws.id})

      {:ok, _} =
        Ash.create(Dependency, %{
          from_issue_id: parent.id,
          to_issue_id: related.id,
          type: :relates_to
        })

      parent = Ash.load!(parent, [:child_total, :child_closed])
      assert parent.child_total == 0
    end
  end

  describe "auto_close" do
    test "an auto_close parent closes when the last child closes", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "epic", auto_close: true, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})

      Enum.each([c1, c2], &child_of(parent, &1))

      {:ok, _} = Ash.update(c1, %{}, action: :close)
      assert Ash.get!(Issue, parent.id).state == :backlog

      {:ok, _} = Ash.update(c2, %{}, action: :close)
      assert Ash.get!(Issue, parent.id).state == :closed
    end

    test "switching auto_close on rolls up an epic whose children already all closed", %{ws: ws} do
      # bd-4i7kky: the flag used to be re-evaluated only when a child closed or an
      # edge was written, so setting it afterwards left a finished epic open until
      # someone closed it by hand.
      {:ok, parent} = Ash.create(Issue, %{title: "epic", issue_type: :epic, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})
      Enum.each([c1, c2], &child_of(parent, &1))
      Enum.each([c1, c2], &Ash.update!(&1, %{}, action: :close))

      assert Ash.get!(Issue, parent.id).state == :backlog

      {:ok, updated} = Ash.update(parent, %{auto_close: true}, action: :update)

      assert updated.state == :closed
      assert Ash.get!(Issue, parent.id).state == :closed
    end

    test "switching auto_close on leaves an epic with open children open", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "epic", issue_type: :epic, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})
      Enum.each([c1, c2], &child_of(parent, &1))
      Ash.update!(c1, %{}, action: :close)

      {:ok, updated} = Ash.update(parent, %{auto_close: true}, action: :update)

      assert updated.state == :backlog
    end

    test "an unrelated update of an auto_close epic does not re-run the rollup", %{ws: ws} do
      # Only a *change to* auto_close is the trigger; an epic that is already
      # auto_close and open is closed by its children closing, not by a retitle.
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", auto_close: true, workspace_id: ws.id})

      {:ok, updated} = Ash.update(parent, %{title: "renamed"}, action: :update)
      assert updated.state == :backlog
    end

    test "the last child closing under an auto_close-OFF epic notifies the coordinator once, and does not close it",
         %{ws: ws} do
      {:ok, epic} = Ash.create(Issue, %{title: "epic", issue_type: :epic, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      {:ok, c2} = Ash.create(Issue, %{title: "c2", workspace_id: ws.id})
      Enum.each([c1, c2], &child_of(epic, &1))

      Ash.update!(c1, %{}, action: :close)
      assert epic_escalations(epic) == []

      Ash.update!(c2, %{}, action: :close)

      assert Ash.get!(Issue, epic.id).state == :backlog

      assert [escalation] = epic_escalations(epic)
      assert escalation.workspace_id == ws.id
      assert escalation.subject =~ "all 2 children closed"
      assert escalation.body =~ "auto_close"
    end

    test "reopening a child and closing it again does not stack a second open notification",
         %{ws: ws} do
      {:ok, epic} = Ash.create(Issue, %{title: "epic", issue_type: :epic, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      child_of(epic, c1)

      c1 = Ash.update!(c1, %{}, action: :close)
      assert [_] = epic_escalations(epic)

      c1 = Ash.update!(c1, %{}, action: :reopen)
      Ash.update!(c1, %{}, action: :close)

      assert [_] = epic_escalations(epic)
    end

    test "an auto_close epic closes and raises no notification", %{ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{
          title: "epic",
          issue_type: :epic,
          auto_close: true,
          workspace_id: ws.id
        })

      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      child_of(epic, c1)
      Ash.update!(c1, %{}, action: :close)

      assert Ash.get!(Issue, epic.id).state == :closed
      assert epic_escalations(epic) == []
    end

    test "attaching an already-closed child is not 'the last child just closed'", %{ws: ws} do
      {:ok, epic} = Ash.create(Issue, %{title: "epic", issue_type: :epic, workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      Ash.update!(c1, %{}, action: :close)
      child_of(epic, c1)

      assert epic_escalations(epic) == []
    end

    test "a non-epic parent without auto_close raises no notification", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "parent", workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      child_of(parent, c1)
      Ash.update!(c1, %{}, action: :close)

      assert epic_escalations(parent) == []
    end

    test "a parent without auto_close stays open even when all children close", %{ws: ws} do
      {:ok, parent} = Ash.create(Issue, %{title: "owned epic", workspace_id: ws.id})
      {:ok, c1} = Ash.create(Issue, %{title: "c1", workspace_id: ws.id})
      child_of(parent, c1)

      {:ok, _} = Ash.update(c1, %{}, action: :close)
      assert Ash.get!(Issue, parent.id).state == :backlog
    end

    test "auto_close with no children never closes the parent", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "childless", auto_close: true, workspace_id: ws.id})

      assert Issue.maybe_auto_close(parent).state == :backlog
    end

    test "auto_close parent created with zero children returns with open state", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", auto_close: true, workspace_id: ws.id})

      assert parent.state == :backlog
    end

    test "auto_close parent stays open when first child is attached if child is open", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", auto_close: true, workspace_id: ws.id})

      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ws.id})

      child_of(parent, child)

      parent = Ash.get!(Issue, parent.id)
      assert parent.state == :backlog
    end

    test "auto_close parent has child_total = 0 when created with no children", %{ws: ws} do
      {:ok, parent} =
        Ash.create(Issue, %{title: "epic", auto_close: true, workspace_id: ws.id})

      parent = Ash.load!(parent, [:child_total, :child_closed])
      assert parent.child_total == 0
      assert parent.child_closed == 0
    end

    test "closing a child cascades up a chain of auto_close ancestors", %{ws: ws} do
      {:ok, grandparent} =
        Ash.create(Issue, %{title: "grandparent", auto_close: true, workspace_id: ws.id})

      {:ok, parent} = Ash.create(Issue, %{title: "parent", auto_close: true, workspace_id: ws.id})
      {:ok, child} = Ash.create(Issue, %{title: "child", workspace_id: ws.id})

      child_of(grandparent, parent)
      child_of(parent, child)

      {:ok, _} = Ash.update(child, %{}, action: :close)

      assert Ash.get!(Issue, parent.id).state == :closed
      assert Ash.get!(Issue, grandparent.id).state == :closed
    end

    test "a child with two parents rolls up into each", %{ws: ws} do
      {:ok, p1} = Ash.create(Issue, %{title: "p1", auto_close: true, workspace_id: ws.id})
      {:ok, p2} = Ash.create(Issue, %{title: "p2", workspace_id: ws.id})
      {:ok, child} = Ash.create(Issue, %{title: "shared child", workspace_id: ws.id})

      child_of(p1, child)
      child_of(p2, child)

      {:ok, _} = Ash.update(child, %{}, action: :close)

      # p1 auto-closes; p2 (no auto_close) stays open but still counts the child.
      assert Ash.get!(Issue, p1.id).state == :closed
      p2 = Ash.load!(Ash.get!(Issue, p2.id), [:child_total, :child_closed])
      assert p2.state == :backlog
      assert p2.child_total == 1
      assert p2.child_closed == 1
    end
  end
end
