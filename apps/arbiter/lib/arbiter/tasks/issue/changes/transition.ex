defmodule Arbiter.Tasks.Issue.Changes.Transition do
  @moduledoc """
  Applies one named lifecycle transition (bd-842qio) inside an Issue action:
  checks the ticket's current `state` against `Arbiter.Tasks.Lifecycle` and
  moves it to the transition's target.

  It also owns `close_reason`: a close records the action's `close_reason`
  argument (`:completed` when none is given), and every other transition
  clears it, so it is nil whenever the ticket is not closed.

  And it clears the ticket's attention (bd-8if9zt): the cause and — after
  commit — the ticket's open escalations (`Changes.ClearAttention`). An action that raises its own cause declares
  that change after this one.

  The state history (bd-5gkqdr) is not written here: a trigger on `issues`
  appends the `Arbiter.Tasks.TicketTransition` row inside the state write's own
  statement, because AshSqlite opens no transaction this change could share. A
  failing insert therefore fails the action and leaves the ticket where it
  was; an idempotent no-op changes no `state` and writes no row.

  The target attributes are written at change time, so the changes declared
  after this one (`SyncTracker`, `StopWorker`, …) see the new state. A refusal
  is raised from a `before_action` hook instead, so a guard declared ahead of
  this change (`GuardStatus`, `GuardDemote`) still reports first with its own
  message.

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
