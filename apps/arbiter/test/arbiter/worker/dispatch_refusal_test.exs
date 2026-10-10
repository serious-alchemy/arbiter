defmodule Arbiter.Worker.DispatchRefusalTest do
  @moduledoc """
  K12 (A3), through the real dispatch path: a node's `refuse{...}` on the spawn is a **hold**
  (`{:error, {:no_node_capacity, info}}`), the ticket goes back to Ready, the run is
  interrupted with no resume attempt consumed and no escalation — while any other spawn
  failure still fails the worker (`bd-bi5pn0`), unchanged.

  The agent binary is stubbed by `Arbiter.TestSandbox`; the node's answer is injected at the
  `:claude_start` seam, in the exact shape `ClaudeSession.start/1` returns it.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Nodes.Placement
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.TestSandbox
  alias Arbiter.Worker
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workers.Run

  require Ash.Query

  @repo "pr/repo"

  setup do
    claude_credential_env!()
    sandbox = TestSandbox.provision!("dispatch-refusal")
    put_app_env(:arbiter, :worktree_root, sandbox.worktree_root)
    put_app_env(:arbiter, :repo_paths, %{@repo => sandbox.repo})
    on_exit(fn -> TestSandbox.own_live_workers!(sandbox) end)

    {:ok, ws} = Ash.create(Workspace, %{name: "refusal-dispatch-ws", prefix: "rfd"})
    {:ok, task} = Ash.create(Issue, %{title: "refused work", workspace_id: ws.id})
    %{ws: ws, task: task, sandbox: sandbox}
  end

  defp dispatch(task, refusal_or_error) do
    Dispatch.dispatch(task.id,
      force: true,
      repo: @repo,
      start_driver: false,
      start_claude: true,
      node: %{id: "node-1", name: "kube-1"},
      claude_start: fn _session_opts -> {:error, refusal_or_error} end
    )
  end

  defp latest_run(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
  end

  for reason <- ~w(no_capacity unschedulable image_unavailable bad_spec) do
    test "refuse{#{reason}} holds the card: no failure, no escalation, slot released",
         %{task: task, ws: ws, sandbox: sandbox} do
      :ok = Placement.reserve(task.id, "node-1")

      assert {:error, {:no_node_capacity, info}} =
               dispatch(task, {:remote_placement_failed, {:refused, unquote(reason), "why"}})

      assert info.refused == unquote(reason)
      assert info.node == "kube-1"

      pid = Worker.whereis(task.id)
      TestSandbox.own!(sandbox, pid)
      snap = Worker.state(pid)
      assert %{state: :finished, outcome: :interrupted} = snap
      assert snap.meta.stop_reason.category == :placement_refused
      assert Map.get(snap.meta, :resume_attempts, 0) == 0
      assert latest_run(task.id).stop_category == "placement_refused"

      # back in Ready: the slot it took is free again
      assert %{state: :queued} = Ash.get!(Issue, task.id)
      refute Enum.any?(Placement.reservations(), &(&1.task_id == task.id))

      assert [] =
               Message.inbox("admiral", workspace_id: ws.id)
               |> Enum.filter(&(&1.directive_ref == task.id))
    end
  end

  test "any other spawn failure still fails the worker and escalates (unchanged)",
       %{task: task, ws: ws, sandbox: sandbox} do
    assert {:error, {:claude_start_failed, {:remote_placement_failed, :prepare_timeout}}} =
             dispatch(task, {:remote_placement_failed, :prepare_timeout})

    pid = Worker.whereis(task.id)
    TestSandbox.own!(sandbox, pid)
    assert Worker.state(pid).outcome == :failed
    assert Worker.state(pid).meta.stop_reason.category == :spawn_failed
    assert %{state: :active} = Ash.get!(Issue, task.id)

    assert [_escalation] =
             Message.inbox("admiral", workspace_id: ws.id)
             |> Enum.filter(&(&1.directive_ref == task.id))
  end
end
