defmodule Arbiter.Tasks.Issue.Changes.SyncPrBody do
  @moduledoc """
  After-action hook for `:update`: when `pr_body` changes on an open ticket that
  already has a `pr_ref`, push the new text to the forge MR/PR description
  through the merger adapter (`Arbiter.Mergers.update_description/3`).

  Workers can only write `pr_body` and hold no forge credential, while
  reviewers read the forge description — so this closes that gap. The adapter's
  own credential is the only one ever used; there is no fallback.

  The call is synchronous inside the update, so a review round that starts
  after a successful `pr_body` update reads the updated description. A failure
  is logged and raised as the ticket's `:tracker_sync_failed` attention cause
  (detail names `pr_body` and the error); the local update still succeeds.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Mergers
  alias Arbiter.Tasks.Attention
  alias Arbiter.Tasks.Workspace

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn cs, issue ->
      if cs.data.pr_body != issue.pr_body, do: maybe_sync(issue)
      {:ok, issue}
    end)
  end

  defp maybe_sync(%{pr_ref: ref}) when ref in [nil, ""], do: :ok
  defp maybe_sync(%{state: :closed}), do: :ok
  defp maybe_sync(%{pr_body: body}) when body in [nil, ""], do: :ok

  defp maybe_sync(issue) do
    with {:ok, %Workspace{} = ws} <- Ash.get(Workspace, issue.workspace_id),
         scoped = Mergers.scope(ws, issue.repo),
         adapter = Mergers.for_workspace(scoped),
         true <- Mergers.forge?(Mergers.strategy(ws, issue.repo)) do
      Mergers.prepare(ws, repo: issue.repo)

      case Mergers.update_description(adapter, issue.pr_ref, issue.pr_body) do
        :ok -> :ok
        {:error, reason} -> failed(issue, reason)
      end
    else
      _ -> :ok
    end
  rescue
    e -> failed(issue, Exception.message(e))
  catch
    :exit, reason -> failed(issue, {:exit, reason})
  end

  defp failed(issue, reason) do
    detail = "pr_body could not be synced to #{issue.pr_ref}: #{describe(reason)}"
    Logger.warning("SyncPrBody: task=#{issue.id} #{detail}")
    Attention.raise_cause(issue.id, :tracker_sync_failed, detail)
    :ok
  end

  defp describe(%{kind: kind, status: status}), do: "#{kind} (HTTP #{inspect(status)})"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
