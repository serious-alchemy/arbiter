defmodule Arbiter.Tasks.Issue.Changes.SetFloor do
  @moduledoc """
  ES2 (bd-3e7inj): the `:set_floor` action's implementation — the only writer
  of `Issue.floor_priority` (`docs/design/epic-aware-scheduling.md` §6.2).

  Two refusals, both before any write:

    * **Who.** An actor that is an `Arbiter.MCP.Scope` must be
      `:coordinator`-tier — the tier both the operator's and the
      coordinator's tokens mint. A `:worker` or `:refine` token is refused,
      consistent with workers not changing priority. No actor means an
      in-process caller (the epic page's LiveView, which sits behind the
      operator's session); the HTTP and MCP surfaces gate by tier before
      they get here and pass the scope as the actor as well.
    * **What.** Only an epic may carry a floor. Setting one on anything else
      is an error; clearing one (`nil`) on a non-epic is a no-op.

  The 1..3 range is the argument constraint and the column's `CHECK`.
  """

  use Ash.Resource.Change

  alias Arbiter.MCP.Scope
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, context) do
    floor = Changeset.get_argument(changeset, :floor_priority)

    with :ok <- authorize(context.actor),
         :ok <- epic_only(changeset.data.issue_type, floor) do
      Changeset.force_change_attribute(changeset, :floor_priority, floor)
    else
      {:error, field, message} ->
        Changeset.add_error(changeset, field: field, message: message)
    end
  end

  defp authorize(%Scope{tier: :coordinator}), do: :ok

  defp authorize(%Scope{tier: tier}),
    do: {:error, :floor_priority, "a #{tier}-tier token may not set an epic's priority floor"}

  defp authorize(_in_process), do: :ok

  defp epic_only(_type, nil), do: :ok
  defp epic_only(:epic, _floor), do: :ok

  defp epic_only(_type, _floor),
    do: {:error, :floor_priority, "only an epic can carry a priority floor"}
end
