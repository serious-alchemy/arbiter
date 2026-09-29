defmodule Arbiter.Test.RefusingConflictResolver do
  @moduledoc """
  A conflict resolver whose every dispatch fails, so a Watchdog polling a
  `:conflict` block exhausts its conflict auto-resolve on the first attempt and
  parks escalated — the state bd-4olwyg's ticket wedged in. Each call is
  reported to the test process `arm/2` registered for the task:
  `{:conflict_resolve_called, task_id}` and `{:conflict_escalated, task_id}`.
  """

  @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

  @spec arm(String.t(), pid()) :: :ok
  def arm(task_id, test_pid) when is_binary(task_id) and is_pid(test_pid),
    do: :persistent_term.put({__MODULE__, task_id}, test_pid)

  @impl true
  def resolve(%{task_id: task_id}) do
    notify(task_id, {:conflict_resolve_called, task_id})
    {:error, :stub_refused}
  end

  @impl true
  def escalate_unresolved(task_id, _workspace_id, _branch, _reason) do
    notify(task_id, {:conflict_escalated, task_id})
    :ok
  end

  @impl true
  def notify_resolution(_task_id, _workspace_id, _branch), do: :ok

  defp notify(task_id, message) do
    case :persistent_term.get({__MODULE__, task_id}, nil) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end
