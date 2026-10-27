defmodule Arbiter.Workflows.MergeQueueClosedTicketTest do
  @moduledoc """
  bd-545yem: a ticket the Watchdog already finalized (merged + closed) must
  not be adopted by the MergeQueue. Adopting it slotted a phantom item into
  the queue whose later `Issue.close` failed on the already-closed ticket.
  """

  # async: false — same rationale as the parent merge_queue_test.
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workflows.MergeQueue

  @ws_github %{
    "merge" => %{
      "strategy" => "github",
      "config" => %{"owner" => "octo", "repo" => "widget", "credentials_ref" => "test-token"}
    }
  }

  setup do
    {:ok, workspace} =
      Ash.create(Workspace, %{
        name: "ws-#{System.unique_integer([:positive])}",
        prefix: "mcc#{System.unique_integer([:positive])}",
        config: @ws_github
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "closed", description: "d", workspace_id: workspace.id})

    {:ok, task} = Ash.update(task, %{pr_ref: "#1051"}, action: :update)

    name = :"merge_queue_closed_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      MergeQueue.start_link(
        workspace_id: workspace.id,
        base: "main",
        auto_tick: false,
        name: name
      )

    Ecto.Adapters.SQL.Sandbox.allow(Arbiter.Repo, self(), pid)
    %{task: task, name: name}
  end

  test "enqueueing a closed ticket that has an MR does not adopt it", %{task: task, name: name} do
    {:ok, _closed} = Ash.update(task, %{reason: "merged"}, action: :close)

    log =
      capture_log(fn ->
        assert :ok = MergeQueue.enqueue(name, task.id)
      end)

    assert %{items: []} = MergeQueue.state(name)
    refute log =~ "adopting it"
    assert :ok = MergeQueue.tick(name)
    refute capture_log(fn -> MergeQueue.tick(name) end) =~ "failed to close task"
  end

  test "an adopted item whose ticket closes meanwhile is not closed a second time", %{
    task: task,
    name: name
  } do
    Req.Test.allow(Arbiter.Mergers.Github.HTTP, self(), Process.whereis(name))

    Req.Test.stub(Arbiter.Mergers.Github.HTTP, fn conn ->
      conn
      |> Plug.Conn.put_status(200)
      |> Req.Test.json(%{
        "number" => 1051,
        "state" => "closed",
        "merged" => true,
        "html_url" => "https://github.com/octo/widget/pull/1051"
      })
    end)

    assert :ok = MergeQueue.enqueue(name, task.id)
    assert %{items: [_]} = MergeQueue.state(name)

    {:ok, _closed} = Ash.update(task, %{reason: "merged"}, action: :close)

    log = capture_log(fn -> MergeQueue.tick(name) end)
    refute log =~ "failed to close task"
  end

  test "a worker_done racing the close does not adopt either", %{task: task, name: name} do
    {:ok, _closed} = Ash.update(task, %{reason: "merged"}, action: :close)

    send(Process.whereis(name), {:worker_done, task.id})
    assert %{items: []} = MergeQueue.state(name)
  end
end
