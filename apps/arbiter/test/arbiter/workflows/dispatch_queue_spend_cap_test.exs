defmodule Arbiter.Workflows.DispatchQueueSpendCapTest do
  @moduledoc """
  A dispatch held by the dollar spend cap (bd-a6grlr) stays held through the
  drain while the cap holds, drains when it no longer does, and arms its own
  wake so a flat cap lifts at the window reset without waiting for a quota poll.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.WorkspaceProviderAccount
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.DispatchQueue
  alias Arbiter.Workflows.DispatchQueueSupervisor

  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      if pid = Application.get_env(:arbiter, :test_dispatch_pid),
        do: send(pid, {:dispatched, task_id, opts})

      {:ok, %{task_id: task_id}}
    end
  end

  setup do
    Application.put_env(:arbiter, :test_dispatch_pid, self())
    on_exit(fn -> Application.delete_env(:arbiter, :test_dispatch_pid) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "dqs-#{System.unique_integer([:positive])}",
        prefix: "dqs#{System.unique_integer([:positive])}"
      })

    account =
      Ash.create!(ProviderAccount, %{
        provider: :claude,
        slug: "dqs-#{System.unique_integer([:positive])}",
        quota_config: %{"spend_cap" => 20.0, "spend_metered" => true}
      })

    Ash.create!(WorkspaceProviderAccount, %{
      workspace_id: ws.id,
      provider: :claude,
      provider_account_id: account.id
    })

    Ash.create!(UsageEvent, %{
      task_id: "bd-ledger-#{System.unique_integer([:positive])}",
      source: :task,
      step: :work,
      provider: "claude",
      provider_account_id: account.id,
      workspace_id: ws.id,
      cost_usd: 25.0,
      occurred_at: DateTime.utc_now()
    })

    {:ok, pid} =
      DispatchQueueSupervisor.start_dispatch_queue(ws.id,
        dispatcher: RecordingDispatcher,
        auto_subscribe: false
      )

    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(DispatchQueueSupervisor, pid) end)

    {:ok, task} = Ash.create(Issue, %{title: "held by spend", workspace_id: ws.id})
    %{ws: ws, account: account, queue: pid, task: task}
  end

  defp hold!(task) do
    assert {:error, {:quota_held, _}} =
             Dispatch.dispatch(task.id, force: true, start_driver: false)
  end

  test "stays held through a drain while the cap holds", %{queue: queue, task: task} do
    hold!(task)
    :ok = DispatchQueue.drain(queue)
    refute_receive {:dispatched, _, _}, 100
    assert [%{task_id: id}] = DispatchQueue.state(queue).items
    assert id == task.id
  end

  test "a held follow-up on a started ticket is not spend-held at the drain", %{
    ws: ws,
    queue: queue
  } do
    {:ok, started} = Ash.create(Issue, %{title: "already started", workspace_id: ws.id})
    {:ok, %Issue{state: :active} = started} = Issue.start_work(started)

    # Held by the ordinary quota gate (a fix round, say), not by the spend cap.
    :ok = DispatchQueue.hold(ws.id, started.id, [resume: true], %{phrase: "5h quota"}, :claude)

    :ok = DispatchQueue.drain(queue)
    assert_receive {:dispatched, id, _opts}
    assert id == started.id
  end

  test "drains once the cap is raised", %{queue: queue, account: account, task: task} do
    hold!(task)
    Ash.update!(account, %{quota_config: %{"spend_cap" => 100.0, "spend_metered" => true}})

    :ok = DispatchQueue.drain(queue)
    assert_receive {:dispatched, id, opts}
    assert id == task.id
    assert Keyword.get(opts, :skip_quota_gate) == true
  end

  test "arms a wake at the window reset for a flat cap", %{queue: queue, task: task} do
    hold!(task)
    state = DispatchQueue.state(queue)
    assert is_reference(:sys.get_state(queue).reset_timer_ref)
    assert [%{reason: %{gate: :spend, wake_at: %DateTime{}}}] = state.items
  end
end
