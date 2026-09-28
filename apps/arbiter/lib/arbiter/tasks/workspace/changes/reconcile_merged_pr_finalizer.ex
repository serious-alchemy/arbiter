defmodule Arbiter.Tasks.Workspace.Changes.ReconcileMergedPRFinalizer do
  @moduledoc """
  After-action hook on workspace `:update` / `:patch_config` that reconciles the
  workspace's MergedPRFinalizer processes against its new config (bd-6dghdv).

  A finalizer is pinned to the `owner/repo` it was started for, and only
  workspace `:create` and boot start one. Without this, a config edit that
  moved the repo — the move to `serious-alchemy/arbiter` changed
  `merge.config.owner` — left the live finalizer sweeping the old repo until a
  server restart. `MergedPRFinalizerSupervisor.reconcile/1` stops a finalizer
  whose repo the config no longer resolves to and starts one for each repo
  that now does; an unchanged repo keeps its running finalizer.

  Runs only when `config` is actually changing, and is gated by
  `MergedPRFinalizerSupervisor.auto_start?/0` like the create hook. Best-effort:
  a failure is logged and never fails the workspace update — the finalizer's
  own per-tick repo check keeps a stale one from sweeping the old repo, and
  the boot enumeration catches it on the next start.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.MergedPRFinalizerSupervisor

  @impl true
  def change(changeset, _opts, _context) do
    if MergedPRFinalizerSupervisor.auto_start?() and
         Ash.Changeset.changing_attribute?(changeset, :config) do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        reconcile(workspace)
        {:ok, workspace}
      end)
    else
      changeset
    end
  end

  defp reconcile(workspace) do
    case MergedPRFinalizerSupervisor.reconcile(workspace) do
      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ReconcileMergedPRFinalizer: failed to reconcile finalizers for workspace " <>
            "#{workspace.id}: #{inspect(reason)}"
        )

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "ReconcileMergedPRFinalizer: reconcile raised for workspace #{workspace.id}: " <>
          Exception.message(e)
      )
  catch
    :exit, reason ->
      Logger.warning(
        "ReconcileMergedPRFinalizer: reconcile exited for workspace #{workspace.id}: " <>
          inspect(reason)
      )
  end
end
