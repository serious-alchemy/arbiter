defmodule Arbiter.Tasks.Issue.Changes.NormalizeProviderConstraint do
  @moduledoc """
  bd-13pqcp: validate and canonicalize a ticket's `provider_constraint` on
  create and update, so the stored value is always `nil`, `%{"require" => [..]}`
  or `%{"exclude" => [..]}` over adapter types (`Arbiter.Agents.ProviderConstraint`).
  A blank value clears the constraint. Does nothing when the field is not
  being written.
  """

  use Ash.Resource.Change

  alias Arbiter.Agents.ProviderConstraint
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    if Changeset.changing_attribute?(changeset, :provider_constraint) do
      normalize(changeset)
    else
      changeset
    end
  end

  defp normalize(changeset) do
    raw = Changeset.get_attribute(changeset, :provider_constraint)

    case ProviderConstraint.normalize(raw) do
      {:ok, constraint} ->
        Changeset.force_change_attribute(changeset, :provider_constraint, constraint)

      {:error, message} ->
        Changeset.add_error(changeset, field: :provider_constraint, message: message)
    end
  end
end
