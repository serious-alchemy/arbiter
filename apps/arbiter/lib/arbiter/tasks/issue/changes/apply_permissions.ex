defmodule Arbiter.Tasks.Issue.Changes.ApplyPermissions do
  @moduledoc """
  G12 (bd-54m4vv): the `:update` half of `ResolvePermissions` — a change to a
  ticket's `permissions` is authority-checked and audited
  (`docs/design/guardrail-profiles.md` §5.3).

  Does nothing unless `permissions` is among the changes, so an update that
  doesn't touch them needs no authority. When it is, the old and new lists are
  diffed by `Arbiter.Guardrails.Permissions.plan/4`: additions are `declared`
  (or `requested` when a coordinator adds a `grant_by: operator` permission),
  removals are `revoked`, and removing a data class (`phi_data`) is
  operator-only. A caller with `:restricted` authority — a worker, a refine
  session, no token — changes nothing.

  Authority and label come from the Ash context (`:guardrail_authority`,
  `:permission_actor`), defaulting to in-process `:operator` like the workspace
  guardrail checks (`Arbiter.Guardrails.Authority`).
  """

  use Ash.Resource.Change

  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Tasks.Permissions
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    if Changeset.changing_attribute?(changeset, :permissions) do
      Changeset.before_action(changeset, &apply_change/1)
    else
      changeset
    end
  end

  defp apply_change(changeset) do
    context = changeset.context || %{}
    authority = Map.get(context, :guardrail_authority, :operator)
    source = if Map.has_key?(context, :guardrail_authority), do: :filer, else: :system
    old = changeset.data.permissions || []
    block = Permissions.workspace_block(changeset.data.workspace_id)

    with {:ok, new} <- Vocabulary.normalize(Changeset.get_attribute(changeset, :permissions)),
         {:ok, planned} <- Vocabulary.plan(old, new, authority, block) do
      actor = Map.get(context, :permission_actor)

      changeset
      |> Changeset.force_change_attribute(:permissions, new)
      |> Changeset.after_action(fn _cs, issue ->
        Permissions.record!(planned, issue.id, source, actor: actor)
        {:ok, issue}
      end)
    else
      {:error, message} -> Changeset.add_error(changeset, field: :permissions, message: message)
    end
  end
end
