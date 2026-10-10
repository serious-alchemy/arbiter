defmodule Arbiter.Tasks.Issue.Changes.ResolvePermissions do
  @moduledoc """
  G12 (bd-54m4vv): resolve a new ticket's `permissions` at creation
  (`docs/design/guardrail-profiles.md` §5.3 (1)–(2)).

  Runs on `:create` after `ResolveRepo` — the repo selects the
  `guardrails.repos.<repo>.defaults.permissions` layer — on every create path,
  the way `ResolveRepo` does. It:

    1. canonicalises what the filer declared (`Arbiter.Guardrails.Permissions`);
    2. checks the caller's authority and decides, per permission, between
       `declared` and — for a `grant_by: operator` permission declared by a
       coordinator — `requested`;
    3. unions in the workspace and repo `defaults.permissions`, recorded
       `defaulted` (operator-owned config, so they need no caller authority) —
       unless the filer already declared the same permission;
    4. writes the `permission_events` after the insert, inside its transaction.

  The caller's authority and label arrive as the Ash context keys
  `:guardrail_authority` (`:operator | :coordinator | :restricted`) and
  `:permission_actor`. A caller that passes neither is in-process trusted code
  (`:operator`, source `system`: a PR-thread follow-up, the dashboard form);
  every untrusted entry point — REST, MCP, the CLI over REST — passes both.
  """

  use Ash.Resource.Change

  alias Arbiter.Guardrails.Permissions, as: Vocabulary
  alias Arbiter.Tasks.Permissions
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Changeset.before_action(&resolve/1)
  end

  defp resolve(changeset) do
    context = changeset.context || %{}
    authority = Map.get(context, :guardrail_authority, :operator)
    source = if Map.has_key?(context, :guardrail_authority), do: :filer, else: :system
    block = Permissions.workspace_block(Changeset.get_attribute(changeset, :workspace_id))
    declared = Changeset.get_attribute(changeset, :permissions)

    with {:ok, declared} <- Vocabulary.normalize(declared),
         :ok <-
           Vocabulary.check_issue_type(declared, Changeset.get_attribute(changeset, :issue_type)),
         {:ok, planned} <- Vocabulary.plan([], declared, authority, block) do
      repo = Changeset.get_attribute(changeset, :repo)
      carried = MapSet.new(declared, &Vocabulary.required_form/1)

      defaults =
        for {permission, default_source} <- Vocabulary.defaults(block, repo),
            Vocabulary.required_form(permission) not in carried,
            do: {permission, default_source}

      default_events =
        for {permission, default_source} <- defaults,
            do: %{permission: permission, event: :defaulted, source: default_source}

      permissions = Enum.sort(Enum.uniq(declared ++ Enum.map(defaults, &elem(&1, 0))))
      actor = Map.get(context, :permission_actor)

      changeset
      |> Changeset.force_change_attribute(:permissions, permissions)
      |> Changeset.after_action(fn _cs, issue ->
        Permissions.record!(planned ++ default_events, issue.id, source, actor: actor)
        {:ok, issue}
      end)
    else
      {:error, message} -> Changeset.add_error(changeset, field: :permissions, message: message)
    end
  end
end
