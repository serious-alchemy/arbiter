defmodule Arbiter.Nodes.LostResumeTest do
  @moduledoc """
  A run cut off by a lost node / preempted pod is resumed in place when its worktree
  survives. A ticket with no worktree (`research`, `task`) has nothing to resume
  (`:no_outpost`), so it is requeued for a fresh dispatch, bounded by
  `LostResume.max_redispatches/0`, then escalated naming the cause.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Nodes.LostResume
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Workers.Run
  alias Arbiter.Worker.PromptBuilder

  require Ash.Query

  setup do
    previous = Application.fetch_env(:arbiter, :node_lost_resume)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :node_lost_resume, v)
        :error -> Application.delete_env(:arbiter, :node_lost_resume)
      end
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "lost-resume", prefix: "lrs"})
    %{ws: ws}
  end

  defp stub_resume(result) do
    test = self()

    Application.put_env(:arbiter, :node_lost_resume,
      enabled: true,
      resume_fun: fn id ->
        send(test, {:resume_called, id})
        result
      end
    )
  end

  defp active_task!(ws, type, notes \\ "") do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "t",
        workspace_id: ws.id,
        acceptance: "ok",
        issue_type: type,
        notes: notes
      })

    {:ok, task} = Ash.update(task, %{}, action: :promote_to_ready)
    {:ok, task} = Ash.update(task, %{}, action: :start)
    task
  end

  defp preempted_run!(task, n \\ 1) do
    for i <- 1..n do
      Ash.create!(Run, %{
        task_id: task.id,
        kind: :implement,
        repo: "r",
        state: :finished,
        outcome: :interrupted,
        stop_category: "preempted",
        started_at: DateTime.add(DateTime.utc_now(), -(n - i + 1) * 60, :second)
      })
    end
  end

  defp run_sync(task_id), do: LostResume.run_now(task_id)

  for type <- [:research, :task] do
    test "a preempted #{type} run with no worktree is requeued, no resume attempt consumed",
         %{ws: ws} do
      stub_resume({:error, :no_outpost})
      task = active_task!(ws, unquote(type))
      preempted_run!(task)

      run_sync(task.id)

      assert Ash.get!(Issue, task.id).state == :queued
      assert [] = escalations(task.id)
    end
  end

  test "a run whose worktree survives is resumed, not requeued", %{ws: ws} do
    stub_resume({:ok, :stub})
    task = active_task!(ws, :research)
    preempted_run!(task)

    run_sync(task.id)

    assert_received {:resume_called, _}
    assert Ash.get!(Issue, task.id).state == :active
  end

  test "repeated preemptions stop after a bounded number and escalate once, naming preemption",
       %{ws: ws} do
    stub_resume({:error, :no_outpost})
    task = active_task!(ws, :research)
    preempted_run!(task, LostResume.max_redispatches() + 1)

    run_sync(task.id)

    assert Ash.get!(Issue, task.id).state == :active
    assert [msg] = escalations(task.id)
    assert msg.subject =~ "preempted"
  end

  test "notes written before preemption are kept and the fresh prompt mentions them",
       %{ws: ws} do
    stub_resume({:error, :no_outpost})
    task = active_task!(ws, :research, "found X so far")
    preempted_run!(task)

    run_sync(task.id)

    reloaded = Ash.get!(Issue, task.id)
    assert reloaded.notes == "found X so far"
    prompt = PromptBuilder.prompt_for_task(reloaded, [])
    assert prompt =~ "found X so far"
    assert prompt =~ "earlier run"
  end

  defp escalations(task_id) do
    Message
    |> Ash.Query.filter(task_ref == ^task_id and kind == :escalation)
    |> Ash.read!()
  end
end
