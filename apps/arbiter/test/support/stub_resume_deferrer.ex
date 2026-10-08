defmodule Arbiter.Test.StubResumeDeferrer do
  @moduledoc """
  In-memory stand-in for `Arbiter.Board.Autopilot.defer_resume/3` (bd-92mx1m).

  This is the DEFAULT deferrer in the test environment (`config/test.exs`):
  an automatic resume that finds the cap full is recorded here instead of
  being queued on the app's own Autopilot, which would otherwise replay it —
  a real `Dispatch.resume/2` — behind some later test's back the moment that
  test frees a slot. Tests that care assert against `deferrals/0`.

  Backed by a named `Agent` started with `Agent.start/2`, like
  `Arbiter.Test.StubFixRoundDispatcher`, so a deferral made from a worker's
  or a Task's process is observable from the test process.
  """

  @name __MODULE__.Store

  def reset do
    ensure_started()
    Agent.update(@name, fn _ -> [] end)
    :ok
  end

  @doc "Every `defer_resume/3` call as `{task_id, kind, opts}`, oldest first."
  def deferrals do
    ensure_started()
    for {_id, _kind, _opts} = deferral <- Agent.get(@name, &Enum.reverse/1), do: deferral
  end

  @doc "Every `cancel_deferred/1` call's task id (bd-4l7l2n), oldest first."
  def cancellations do
    ensure_started()
    for {:cancel, id} <- Agent.get(@name, &Enum.reverse/1), do: id
  end

  @doc "Task ids currently deferred (deferred and not cancelled), like Autopilot's."
  def deferred_resume_ids do
    ensure_started()

    Agent.get(@name, &Enum.reverse/1)
    |> Enum.reduce([], fn
      {:cancel, id}, acc -> List.delete(acc, id)
      {id, _kind, _opts}, acc -> [id | List.delete(acc, id)]
    end)
    |> Enum.reverse()
  end

  def cancel_deferred(task_id) do
    ensure_started()
    Agent.update(@name, &[{:cancel, task_id} | &1])
    :ok
  end

  def defer_resume(task_id, kind, opts) do
    ensure_started()
    Agent.update(@name, &[{task_id, kind, opts} | &1])
    :ok
  end

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> [] end, name: @name) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end
