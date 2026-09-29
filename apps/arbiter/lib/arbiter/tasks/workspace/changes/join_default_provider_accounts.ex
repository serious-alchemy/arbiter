defmodule Arbiter.Tasks.Workspace.Changes.JoinDefaultProviderAccounts do
  @moduledoc """
  After-action hook that joins a newly created workspace to
  `<provider>:default` on an install the boot classified as fresh
  (bd-cvvb02, `Arbiter.Accounts.Enablement.auto_join?/0`) — the
  install's first workspace is usually created after boot (`arb init`, the
  dashboard), so the boot-time join alone would miss it.

  A no-op otherwise: an already migrated install's links are the operator's.
  Best-effort — a failed join is
  logged by `Enablement.join_default/1` and never fails the create.
  """

  use Ash.Resource.Change

  alias Arbiter.Accounts.Enablement

  @impl true
  def change(changeset, _opts, _context) do
    if Enablement.auto_join?() do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        Enablement.join_default(workspace)
        {:ok, workspace}
      end)
    else
      changeset
    end
  end
end
