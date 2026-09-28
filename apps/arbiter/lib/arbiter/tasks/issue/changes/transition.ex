defmodule Arbiter.Tasks.Issue.Changes.Transition do
  @moduledoc """
  Applies one named lifecycle transition (bd-842qio) inside an Issue action:
  checks the ticket's current `state` against `Arbiter.Tasks.Lifecycle`, moves
  it to the transition's target, and dual-writes the legacy columns
  (`status`, and `refined` except on close) per `Lifecycle.legacy_fields/1`.

  It also owns `close_reason`: a close records the action's `close_reason`
  argument (`:completed` when none is given), and every other transition
  clears it, so it is nil whenever the ticket is not closed.

  And it clears the ticket's attention (bd-8if9zt): the cause, the legacy
  ReviewGate park columns, and — after commit — the ticket's open escalations
  (`Changes.ClearAttention`). An action that raises its own cause declares
  that change after this one.

  The target attributes are written at change time, so the changes declared
  after this one (`SyncTracker`, `StopWorker`, …) see the new status. A refusal
  is raised from a `before_action` hook instead, so an older guard declared
  ahead of this change (`GuardStatus`, `GuardDemote`) still reports first with
  its own message.

  ## Options

    * `:transition` (required) — one of `Arbiter.Tasks.Lifecycle.transitions/0`.
    * `:idempotent` (default `false`) — for the legacy doors
      `:promote_to_ready` and `:return_to_backlog`, which predate the table and
      promised a no-op rather than an error when the card is not where the
      transition starts. A named transition action never sets it.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.Issue.Changes.ClearAttention
  alias Arbiter.Tasks.Lifecycle
  alias Ash.Changeset

  @impl true
  def change(changeset, opts, _context) do
    transition = Keyword.fetch!(opts, :transition)
    from = changeset.data.state

    cond do
      Lifecycle.allowed?(transition, from) ->
        write(changeset, transition)

      Keyword.get(opts, :idempotent, false) ->
        changeset

      true ->
        Changeset.before_action(changeset, &refuse(&1, transition, from))
    end
  end

  defp write(changeset, transition) do
    {_sources, to} = Lifecycle.rule(transition)

    changeset
    |> Changeset.force_change_attribute(:state, to)
    |> Changeset.force_change_attributes(Lifecycle.legacy_fields(to))
    |> Changeset.force_change_attribute(:close_reason, close_reason(changeset, to))
    |> ClearAttention.clear()
  end

  defp close_reason(changeset, :closed),
    do: Changeset.get_argument(changeset, :close_reason) || :completed

  defp close_reason(_changeset, _state), do: nil

  defp refuse(changeset, transition, from) do
    {sources, to} = Lifecycle.rule(transition)

    Changeset.add_error(changeset,
      field: :state,
      message:
        "Cannot #{transition} a ticket that is #{inspect(from)}: #{transition} moves " <>
          "#{Enum.map_join(sources, " | ", &inspect/1)} → #{inspect(to)}."
    )
  end
end
