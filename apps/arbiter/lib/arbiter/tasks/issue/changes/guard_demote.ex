defmodule Arbiter.Tasks.Issue.Changes.GuardDemote do
  @moduledoc """
  Enforces the preconditions of the `demote` transition (`:demote` and the
  `:return_to_backlog` legacy door) beyond the table itself.

  A ticket can only be demoted back to `:backlog` if it has no live exclusive
  worker (its own worker, a fix pass, or a conflict resolver): demoting under
  a live run would orphan it. That is what lets bd-2098's case through — an
  `:active` or `:merging` ticket whose worker already stopped is demoted in
  one write, so Autopilot cannot re-grab it between two.

  A `:verifying` or `:closed` ticket is refused with its own message, since
  those states are finished work. A ticket already in `:backlog` is left to
  the transition (a no-op for `:return_to_backlog`, an error for `:demote`).
  """

  use Ash.Resource.Change

  alias Arbiter.Worker.Registry, as: WorkerRegistry
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, &validate/1)
  end

  defp validate(cs) do
    task_id = cs.data.id

    case cs.data.state do
      :backlog ->
        cs

      :verifying ->
        Changeset.add_error(cs,
          field: :state,
          message:
            "Cannot demote a task that is awaiting verification. " <>
              "Record a verification outcome first."
        )

      :closed ->
        Changeset.add_error(cs,
          field: :state,
          message: "Cannot demote a closed task. Only undispatched or open tasks can be demoted."
        )

      _queued_or_at_work ->
        if has_live_workers?(task_id) do
          Changeset.add_error(cs,
            field: :state,
            message:
              "Cannot demote a task with a live worker. Stop the worker first " <>
                "(`arb worker stop #{task_id}`) before demoting."
          )
        else
          cs
        end
    end
  end

  defp has_live_workers?(task_id) do
    WorkerRegistry.live_for(task_id) |> Enum.any?()
  rescue
    _ -> false
  end
end
