defmodule Arbiter.PaperTrail.StampActor do
  @moduledoc """
  Resource-wide change that hands the acting `Arbiter.Actor`'s label to
  AshPaperTrail, so the version row records who made the write.

  AshPaperTrail reads `changeset.context[:paper_trail_metadata]` into every
  `metadata` attribute declared on the version resource, so a resource opts in
  with

      paper_trail do
        metadata :actor, :string, allow_nil?: true
      end

      changes do
        change Arbiter.PaperTrail.StampActor
      end

  Resources that already snapshot the actor as an **attribute** (`Skill`,
  `Workspace` — `attributes_as_attributes([:actor, ...])`) use
  `change {Arbiter.PaperTrail.StampActor, attribute: :actor}` instead: it fills
  that attribute from the same resolution, but only when the caller did not
  supply one (an explicit `actor:` input — the loop's `"loop:proposal:<id>"`
  labels, the CLI's `"cli"` — is never overwritten).

  The actor is the explicit Ash `actor:` (an `Arbiter.Actor` or an MCP
  `Arbiter.MCP.Scope`), else the process's ambient actor
  (`Arbiter.Actor.current/0`), else nothing — an unattributed write is recorded
  exactly as it was before. Attribution only: this never adds an error and never
  reads the actor to allow or refuse anything.
  """

  use Ash.Resource.Change

  alias Arbiter.Actor
  alias Ash.Changeset

  @impl true
  def change(changeset, opts, context) do
    case Actor.resolve_label(context.actor) do
      nil -> changeset
      label -> stamp(changeset, label, opts[:attribute])
    end
  end

  defp stamp(changeset, label, nil),
    do: Changeset.set_context(changeset, %{paper_trail_metadata: %{actor: label}})

  defp stamp(changeset, label, attribute) do
    if Changeset.changing_attribute?(changeset, attribute) do
      changeset
    else
      Changeset.force_change_attribute(changeset, attribute, label)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
