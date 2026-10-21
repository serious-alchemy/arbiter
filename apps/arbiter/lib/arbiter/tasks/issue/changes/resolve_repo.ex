defmodule Arbiter.Tasks.Issue.Changes.ResolveRepo do
  @moduledoc """
  bd-9dwbvt: bind every new issue to a repo at creation time.

  Runs on `:create` only, and delegates the whole policy to
  `Arbiter.Tasks.IssueRepo.resolve/2`: an explicit repo (canonicalized onto
  the configured `repo_paths` key it matches), else the workspace's only repo,
  else its `default_repo`, else a validation error on the `:repo` field naming
  the configured keys.

  Every creation path — `ticket_create`, `arb ticket create` (via
  `POST /api/issues`), `tracker_claim` / `arb ticket claim`, `tracker_sync`'s
  auto-claim, the dashboard create form, PRPatrol follow-ups and
  ExternalReview engagements — goes through `Ash.create(Issue, …)`, so this
  one hook covers all of them rather than each re-deriving the rule.

  `:update` is hooked too, but only when the update *changes* `repo` to a
  non-blank value: that value is canonicalized onto its configured key or
  refused with the valid keys (bd-7u1b6n — a hand-set or tool-set
  `emricare/tonic` used to persist, then dispatch and the reconciler's resume
  disagreed about it). Clearing the repo stays possible, and an update that
  leaves `repo` alone never re-validates it, so an issue already holding a
  stale value can still be edited — and repaired.
  """

  use Ash.Resource.Change

  alias Arbiter.Tasks.IssueRepo
  alias Ash.Changeset

  @impl true
  def change(changeset, _opts, _context) do
    Changeset.before_action(changeset, fn changeset ->
      if changeset.action_type == :create or repo_set?(changeset),
        do: resolve(changeset),
        else: changeset
    end)
  end

  # On :update, only a changed, non-blank repo is validated.
  defp repo_set?(changeset) do
    Changeset.changing_attribute?(changeset, :repo) and
      is_binary(Changeset.get_attribute(changeset, :repo)) and
      String.trim(Changeset.get_attribute(changeset, :repo)) != ""
  end

  # A create filed under a `parent_id` with no repo of its own takes the
  # parent's repo, ahead of the workspace's only/default repo.
  defp parent_repo(%{action_type: :create} = changeset) do
    with parent_id when is_binary(parent_id) and parent_id != "" <-
           Changeset.get_argument(changeset, :parent_id),
         {:ok, %{repo: repo}} when is_binary(repo) <- Ash.get(Arbiter.Tasks.Issue, parent_id) do
      repo
    else
      _ -> nil
    end
  end

  defp parent_repo(_changeset), do: nil

  defp resolve(changeset) do
    workspace_id = Changeset.get_attribute(changeset, :workspace_id)
    explicit = Changeset.get_attribute(changeset, :repo) || parent_repo(changeset)

    case IssueRepo.resolve(workspace_id, explicit) do
      {:ok, nil} ->
        changeset

      {:ok, repo} ->
        Changeset.force_change_attribute(changeset, :repo, repo)

      {:error, reason} ->
        Changeset.add_error(changeset, field: :repo, message: IssueRepo.describe_error(reason))
    end
  end
end
