defmodule Arbiter.Workflows.MergeQueue.PassAdmissionLocalCapacityTest do
  @moduledoc """
  RW8: a fix or conflict pass runs on the primary, so a primary cap of 0 holds
  it (never fails it), and it resumes when the cap rises.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes
  alias Arbiter.Settings
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue.PassAdmission

  setup do
    on_exit(fn -> Settings.set_nodes_local_max_workers(nil) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "pal-#{System.unique_integer([:positive])}",
        prefix: "pal#{System.unique_integer([:positive])}"
      })

    {:ok, issue} = Ash.create(Issue, %{title: "a pass", workspace_id: ws.id})
    {:ok, task: issue}
  end

  for kind <- [:fix_pass, :conflict] do
    test "#{kind}: held at local cap 0 with the follow-up reason, admitted once it rises",
         %{task: task} do
      {:ok, 0} = Nodes.set_local_max_workers(0, nil)

      assert {:error, {:no_node_capacity, info}} = PassAdmission.admit(task, unquote(kind), %{})
      assert info.node == "local"
      assert info.phrase =~ "held — local capacity 0 (run is local-only:"
      assert info.phrase =~ "stay on the primary"

      {:ok, 1} = Nodes.set_local_max_workers(1, nil)

      refute match?(
               {:error, {:no_node_capacity, _}},
               PassAdmission.admit(task, unquote(kind), %{})
             )
    end

    test "#{kind}: not held by an override above 0 or by no override at all", %{task: task} do
      refute match?(
               {:error, {:no_node_capacity, _}},
               PassAdmission.admit(task, unquote(kind), %{})
             )

      {:ok, 1} = Nodes.set_local_max_workers(1, nil)

      refute match?(
               {:error, {:no_node_capacity, _}},
               PassAdmission.admit(task, unquote(kind), %{})
             )
    end
  end
end
