defmodule Arbiter.Tasks.Issue.Changes.ResetDemotedTaskStatus do
  @moduledoc """
  For the `:return_to_backlog` action, resets an in_progress task's status to
  open if it has no live worker.

  This ensures the status and refined flag are updated atomically, preventing
  Autopilot from re-grabbing the task between updates.
  """

  use Ash.Resource.Change

  alias Arbiter.Worker.Registry, as: WorkerRegistry
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    task_id = changeset.data.id
    current_status = changeset.data.status

    if current_status == :in_progress && !has_live_workers?(task_id) do
      Changeset.change_attribute(changeset, :status, :open)
    else
      changeset
    end
  end

  defp has_live_workers?(task_id) do
    WorkerRegistry.live_for(task_id) |> Enum.any?()
  rescue
    _ -> false
  end
end
