defmodule Arbiter.Tasks.Workspace.Changes.ReconcilePatrols do
  @moduledoc """
  After-action hook on workspace `:update` / `:patch_config` that reconciles the
  workspace's PRPatrol and ReviewPatrol processes against its new config
  (bd-7feiul) — the patrol counterpart of `ReconcileMergedPRFinalizer`
  (bd-6dghdv).

  A patrol is pinned to the `owner/repo` it was started for, and only
  workspace `:create`, boot, and the `PatrolLifecycle` demand-start start one.
  Without this, a config edit that moved the repo (`merge.config.owner` /
  `repo`, or `repo_paths`) left the live patrols listing and dispatching
  against the old repo until a server restart. Each supervisor's `reconcile/1`
  stops a patrol whose repo the config no longer resolves to and re-runs its
  gated start, so a replacement starts only where the lazy-start gate
  (bd-7tr11p) finds watched work; an unchanged repo keeps its running patrol.

  Runs only when `config` is actually changing, and is gated by
  `PRPatrolSupervisor.auto_start?/0` like the create hooks. Best-effort: a
  failure is logged and never fails the workspace update — each patrol's own
  per-tick repo check keeps a stale one from querying the old repo, and the
  next demand-start or boot enumeration replaces it.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Workflows.{PRPatrolSupervisor, ReviewPatrolSupervisor}

  @impl true
  def change(changeset, _opts, _context) do
    if PRPatrolSupervisor.auto_start?() and
         Ash.Changeset.changing_attribute?(changeset, :config) do
      Ash.Changeset.after_action(changeset, fn _cs, workspace ->
        reconcile(PRPatrolSupervisor, workspace)
        reconcile(ReviewPatrolSupervisor, workspace)
        {:ok, workspace}
      end)
    else
      changeset
    end
  end

  defp reconcile(supervisor, workspace) do
    case supervisor.reconcile(workspace) do
      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ReconcilePatrols: #{inspect(supervisor)} failed to reconcile patrols for workspace " <>
            "#{workspace.id}: #{inspect(reason)}"
        )

      _ ->
        :ok
    end
  rescue
    e ->
      Logger.warning(
        "ReconcilePatrols: #{inspect(supervisor)} reconcile raised for workspace " <>
          "#{workspace.id}: " <> Exception.message(e)
      )
  catch
    :exit, reason ->
      Logger.warning(
        "ReconcilePatrols: #{inspect(supervisor)} reconcile exited for workspace " <>
          "#{workspace.id}: " <> inspect(reason)
      )
  end
end
