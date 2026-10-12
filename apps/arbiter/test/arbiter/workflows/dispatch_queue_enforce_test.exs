defmodule Arbiter.Workflows.DispatchQueueEnforceTest do
  @moduledoc """
  The `DispatchQueue` under `scheduler_admission: enforce` (DC8, design
  `provider-dynamic-concurrency.md` §7, E11):

    * **Fresh quota holds are dropped.** A fresh dispatch is not quota-held under
      `enforce`: it waits in Ready, where the scheduler walk admits it by seat
      and in queue order. A fresh intent the gate held before the switch is
      dropped at the next drain, not replayed past the walk.
    * **A held follow-up drains on the hard rules alone** (`pace: false`): once
      the provider accepts again it goes, even past the paced line (I9, O2).

  Under `legacy` the same queue drains exactly as before.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Quota.AnthropicQuota
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Workflows.{DispatchQueue, DispatchQueueSupervisor}

  defmodule RecordingDispatcher do
    def dispatch(task_id, opts) do
      send(Application.get_env(:arbiter, :dq_enforce_test_pid), {:dispatched, task_id, opts})
      {:ok, %{task_id: task_id}}
    end
  end

  setup do
    Application.put_env(:arbiter, :dq_enforce_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:arbiter, :dq_enforce_test_pid)
      Arbiter.Settings.set_scheduler_admission(nil)
    end)

    ws =
      Ash.create!(Workspace, %{
        name: "dqe-#{System.unique_integer([:positive])}",
        prefix: "dqe#{System.unique_integer([:positive])}",
        config: %{"quota" => %{"on_exhaustion" => "throttle"}}
      })

    {:ok, pid} =
      DispatchQueueSupervisor.start_dispatch_queue(ws.id,
        dispatcher: RecordingDispatcher,
        auto_subscribe: false
      )

    on_exit(fn -> Arbiter.ProcessTeardown.stop_child(DispatchQueueSupervisor, pid) end)
    %{ws: ws, queue: pid}
  end

  defp seed_quota(ws, attrs) do
    Ash.create!(
      AnthropicQuota,
      Map.merge(
        %{
          provider_account_id: quota_account_id!(ws.id),
          provider: "claude",
          reset_5h_at: DateTime.add(DateTime.utc_now(), 9_000, :second),
          captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        attrs
      )
    )
  end

  defp task!(ws), do: Ash.create!(Issue, %{title: "held", workspace_id: ws.id})

  defp mode!(mode), do: {:ok, _} = Arbiter.Settings.set_scheduler_admission(mode)

  describe "a fresh quota hold" do
    setup %{ws: ws} do
      seed_quota(ws, %{status_5h: "rejected", utilization_5h: 0.99})
      task = task!(ws)
      assert {:error, {:quota_held, _}} = Dispatch.dispatch(task.id, force: true, start_driver: false)
      assert DispatchQueue.held?(ws.id, task.id)
      %{task: task}
    end

    test "legacy: kept while the gate holds, drained once it allows (today)", ctx do
      :ok = DispatchQueue.drain(ctx.queue)
      assert DispatchQueue.held?(ctx.ws.id, ctx.task.id)

      seed_quota(ctx.ws, %{status_5h: "allowed", utilization_5h: 0.10})
      :ok = DispatchQueue.drain(ctx.queue)

      task_id = ctx.task.id
      assert_receive {:dispatched, ^task_id, _opts}, 5_000
    end

    test "enforce: dropped at the next drain — the card waits in Ready for the walk", ctx do
      mode!(:enforce)
      seed_quota(ctx.ws, %{status_5h: "allowed", utilization_5h: 0.10})
      :ok = DispatchQueue.drain(ctx.queue)

      refute DispatchQueue.held?(ctx.ws.id, ctx.task.id)
      refute_receive {:dispatched, _, _}, 200
      assert Ash.get!(Issue, ctx.task.id).state in [:backlog, :queued]
    end
  end

  describe "a held follow-up (a round of a ticket In progress)" do
    setup %{ws: ws} do
      task = ws |> task!() |> put_state!(:active)

      :ok =
        DispatchQueue.hold(
          ws.id,
          task.id,
          [resume: true],
          %{window: "5h", signal: :status, phrase: "quota exhausted"},
          :claude
        )

      # The provider accepts again, but the window is past its line.
      seed_quota(ws, %{status_5h: "allowed", utilization_5h: 0.99})
      %{task: task}
    end

    test "legacy: still held by the line", ctx do
      :ok = DispatchQueue.drain(ctx.queue)
      assert DispatchQueue.held?(ctx.ws.id, ctx.task.id)
      refute_receive {:dispatched, _, _}, 200
    end

    test "enforce: kept in the queue, and drained on the hard rules alone", ctx do
      mode!(:enforce)
      :ok = DispatchQueue.drain(ctx.queue)

      task_id = ctx.task.id
      assert_receive {:dispatched, ^task_id, opts}, 5_000
      assert Keyword.get(opts, :skip_quota_gate) == true
    end
  end
end
