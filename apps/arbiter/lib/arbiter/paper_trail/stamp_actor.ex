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
  def change(changeset, _opts, context) do
    case Actor.resolve_label(context.actor) do
      nil -> changeset
      label -> Changeset.set_context(changeset, %{paper_trail_metadata: %{actor: label}})
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
