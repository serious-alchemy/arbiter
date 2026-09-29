defmodule Arbiter.Tasks.Issue.Changes.CleanupWorktree do
  @moduledoc """
  After-action hook for the `:close` action: if a git worktree exists for
  this task, remove it.

  Path is derived from the task via `Arbiter.Worker.BranchNamer.derive/1`
  + `Arbiter.Worker.Worktree.worktree_path/1` — the same convention
  `Dispatch` uses on provisioning, so we never need a stored path.

  Two paths are reclaimed, both derived from the same branch name:

    * the **branch** worktree (`Worktree.worktree_path/1`) — a code dispatch's
      checkout, which may hold uncommitted or unpushed work, so removal is
      skipped when it is dirty;
    * the **inspect** worktree (`Worktree.inspect_path/1`, bd-9r1tta) — the
      detached checkout a `task`-type audit/spike runs in. Nothing there is
      meant to be preserved (no branch, so nothing unpushed; the agent's
      deliverable is `notes`), so it is removed even when dirty. Leaving it
      would leak a worktree per audited task, which is the cost of giving the
      inspect checkout its own leaf.

  Best-effort. Skipped silently when:

    * no directory exists at the derived path,
    * `BranchNamer.derive/1` cannot produce a branch (e.g. legacy tasks
      with unrecognised issue types).

  ## What counts as work (bd-9iv4qd)

  The branch worktree is judged by `Worktree.leftover_work/2`, not by a bare
  `git status`: untracked build junk (`__pycache__`, `_build`, `deps`,
  `node_modules`, ...) and Arbiter's own injected config (`.mcp.json`, even
  when the repo tracks one) are not work, so a worktree holding only those is
  removed. Staged or modified files, untracked source files and commits on no
  remote ARE work: the worktree is left in place, a warning names its path,
  and a patch of that work (injected config excluded) is appended to the
  task's `notes`, so the leftover is discoverable from the ticket rather than
  only from a directory listing. A probe that fails is treated as "might hold
  work": kept and warned about, notes untouched.

  ## Merged-branch reap (bd-9iv4qd)

  When the close is a merge — `:close` with `pr_merged: true` (what
  `Tasks.Verification.finalize_merged/2` passes) or the `:await_verification`
  park (`merged: true` on the change) — the task's local branch is deleted
  from the repository once its worktree is gone, via
  `Worktree.delete_merged_branch/3`. That only deletes a branch whose every
  commit is on a remote ref or is the PR head the ticket recorded
  (`merger_status.head_sha`, `merge_watch.local_head_sha`) — the case of a
  squash merge whose remote branch the forge then deleted. A close that is not
  a merge keeps the branch: a reopened ticket re-attaches to it.

  Runs as an `after_transaction` hook, so nothing on disk is destroyed for a
  close that did not commit, and the notes write happens after the close row
  is committed.

  Liveness guard (bd-bmmj4w): git status alone cannot prove a worktree is
  safe to delete — a clean, fully-pushed worktree can still have a live
  sub-worker (a `#review` round, a fix pass, ...) mid-`mix test` inside it, and
  removing it then destroys the directory out from under a running process.

  The guard has two halves, and it is the pair that makes it sound:

    * `Worker.terminate/2` SIGKILLs the agent's OS process **and its
      descendants** before the worker GenServer finishes dying. Erlang does
      not reap a `:spawn_executable` port's OS process on owner death, so
      without that half a stopped worker still leaves a live `claude` (and
      its `mix test` child) running in the worktree, and no registry check
      could see it.
    * This hook then waits (briefly) for every worker registered under this
      task to actually leave the registry, because `StopWorker` — which runs
      immediately before it — uses a *bounded* per-worker stop and may return
      while a worker is still mid-`terminate/2`. If any is still alive when
      the grace window closes, both removals are skipped with a warning, same
      as the dirty path.

  So what this hook checks directly is "no worker GenServer for this task is
  still registered and alive"; that stands in for "no agent still owns the
  directory" only because of the first half above. It is not a general
  live-process probe of the directory, and two residual cases stay invisible
  to it:

    * a process that never belonged to a worker at all — an operator's own
      shell sitting in the worktree, say;
    * an *orphaned* agent, whose worker died without `terminate/2` running
      (`Process.exit(pid, :kill)`, or a teardown that overran its shutdown
      grace and was killed — `Worker` traps every other exit since
      bd-aje6fj). Nothing killed its OS process, and the registry row for the
      dead worker is filtered out by `live_for/1` as a corpse, so the drain
      reports `:drained` while the agent is still running in the directory.
      Every path that stops a worker deliberately (`Worker.stop/3`, and so
      `StopWorker`) goes through `GenServer.stop`, which always runs
      `terminate/2` — so this is the abnormal-kill case, not the `:close`
      path the incident came from. Closing it would take an OS-level probe
      of the directory (`/proc/*/cwd`, `lsof`), which is platform-specific;
      it is deliberately out of scope here.

  Failures from `Worktree.cleanup/1` are logged but never propagated — the
  `:close` action must succeed even if teardown does not.

  Pairs with `Arbiter.Tasks.Issue.Changes.StopWorker`, which handles the
  in-memory side of teardown.
  """

  use Ash.Resource.Change

  require Logger

  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Registry, as: WorkerRegistry
  alias Arbiter.Worker.Worktree

  @drain_poll_ms 50

  @impl true
  def change(changeset, opts, _context) do
    merged? =
      Keyword.get(opts, :merged, false) or
        Ash.Changeset.get_argument(changeset, :pr_merged) == true

    Ash.Changeset.after_transaction(changeset, fn
      _cs, {:ok, issue} -> {:ok, run(issue, merged?)}
      _cs, error -> error
    end)
  end

  defp run(issue, merged?) do
    case cleanup(issue, merged?) do
      {:kept, work} -> record_leftover(issue, work)
      :ok -> issue
    end
  rescue
    e ->
      Logger.warning("CleanupWorktree: error for task=#{issue.id}: #{Exception.message(e)}")
      issue
  catch
    :exit, reason ->
      Logger.warning("CleanupWorktree: exit for task=#{issue.id}: #{inspect(reason)}")
      issue
  end

  defp cleanup(issue, merged?) do
    case branch_for(issue) do
      nil ->
        :ok

      branch ->
        branch_path = Worktree.worktree_path(branch)
        inspect_path = Worktree.inspect_path(branch)

        # Only pay the drain wait when there is actually something to remove.
        if File.dir?(branch_path) or File.dir?(inspect_path) do
          case await_worker_drain(issue.id) do
            :drained ->
              remove_inspect_worktree(issue, inspect_path)
              remove_branch_worktree(issue, branch, branch_path, merged?)

            {:live, registry_keys} ->
              Logger.warning(
                "CleanupWorktree: live worker(s) still registered for task=#{issue.id} " <>
                  "(#{Enum.join(registry_keys, ", ")}); skipping worktree removal"
              )

              :ok
          end
        else
          :ok
        end
    end
  end

  # A filesystem-destroying operation must not trust that StopWorker (which
  # runs just before this hook, with a bounded per-worker stop) fully drained
  # every worker owned by this task: re-check liveness here, giving a worker
  # that is mid-terminate a short grace window to actually exit. Returns
  # `:drained` once no live worker remains registered under the task, or
  # `{:live, registry_keys}` when the window closes with some still alive —
  # in which case the caller skips removal entirely (bd-bmmj4w).
  defp await_worker_drain(task_id) do
    deadline = System.monotonic_time(:millisecond) + drain_ms()
    await_worker_drain(task_id, deadline)
  end

  defp await_worker_drain(task_id, deadline) do
    # `live_for/1` (not `all_for/1`) so an unreaped registry corpse — a worker
    # that died without terminate/2 running, whose row Registry clears
    # asynchronously — cannot block cleanup forever.
    #
    # bd-741sid: the ticket's Watchdog is not in the worktree — it only talks
    # to the forge — and it is often the very process closing the ticket
    # (the PR merged), so it never holds the worktree up.
    case task_id |> WorkerRegistry.live_for() |> Enum.reject(&watchdog?(&1, task_id)) do
      [] ->
        :drained

      live ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:live, Enum.map(live, fn {registry_key, _pid} -> registry_key end)}
        else
          Process.sleep(@drain_poll_ms)
          await_worker_drain(task_id, deadline)
        end
    end
  end

  defp watchdog?({registry_key, pid}, task_id) do
    pid == self() or registry_key == task_id <> Arbiter.Worker.Watchdog.registry_suffix()
  end

  defp drain_ms do
    Application.get_env(:arbiter, :cleanup_worktree_drain_ms, 2_000)
  end

  defp remove_branch_worktree(issue, branch, path, merged?) do
    if File.dir?(path) do
      case Worktree.leftover_work(path, pushed_shas: pushed_shas(issue)) do
        {:ok, nil} ->
          # Resolve the repository before the worktree (and its gitdir link)
          # is gone.
          repo = merged? && Worktree.repo_path(path)
          remove(issue, path)
          if repo, do: delete_branch(issue, repo, branch)
          :ok

        {:ok, work} ->
          Logger.warning(
            "CleanupWorktree: worktree for task=#{issue.id} holds work that is on no remote " <>
              "(#{length(work.changes)} changed path(s), #{work.unpushed} unpushed commit(s)); " <>
              "leaving it at #{path} and saving a patch to the task notes"
          )

          {:kept, work}

        {:error, reason} ->
          Logger.warning(
            "CleanupWorktree: could not tell whether the worktree for task=#{issue.id} holds " <>
              "work (#{inspect(reason)}); leaving it at #{path}"
          )

          :ok
      end
    else
      :ok
    end
  end

  # No dirty-check: a detached inspect checkout has no branch and holds no
  # deliverable, so scratch files in it are not work to preserve (bd-9r1tta).
  defp remove_inspect_worktree(issue, path) do
    if File.dir?(path), do: remove(issue, path), else: :ok
  end

  defp remove(issue, path) do
    case Worktree.cleanup(path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupWorktree: removal failed for task=#{issue.id} at #{path}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp delete_branch(issue, repo, branch) do
    case Worktree.delete_merged_branch(repo, branch, pushed_shas: pushed_shas(issue)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "CleanupWorktree: kept local branch #{branch} in #{repo} for task=#{issue.id}: " <>
            inspect(reason)
        )
    end
  end

  # The PR heads this ticket recorded: commits the forge has, even once the
  # merged branch is deleted there and no local remote ref reaches them.
  defp pushed_shas(issue) do
    watch = issue.merge_watch || %{}

    [
      (PullRequest.merger_status(issue) || %{})[:head_sha],
      watch["local_head_sha"] || watch[:local_head_sha]
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp record_leftover(issue, work) do
    notes = Enum.join(Enum.reject([issue.notes, leftover_note(work)], &(&1 in [nil, ""])), "\n\n")

    case Ash.update(issue, %{notes: notes}, action: :update) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning(
          "CleanupWorktree: could not save the leftover patch to task=#{issue.id}'s notes: " <>
            inspect(reason)
        )

        issue
    end
  end

  defp leftover_note(work) do
    changes =
      case work.changes do
        [] -> ""
        lines -> "- changed: " <> Enum.map_join(lines, ", ", &"`#{&1}`") <> "\n"
      end

    unpushed =
      case work.unpushed do
        0 -> ""
        1 -> "- 1 unpushed commit\n"
        n -> "- #{n} unpushed commits\n"
      end

    """
    ## Worktree kept on close (#{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()})

    `#{work.path}` was not removed: it holds work that is on no remote.

    #{changes}#{unpushed}
    ````diff
    #{work.patch}
    ````
    """
  end

  defp branch_for(issue) do
    BranchNamer.derive(issue)
  rescue
    ArgumentError ->
      # BranchNamer rejects tasks with unknown issue_type or missing
      # title+id — those predate per-task branching and have no worktree
      # to clean up.
      nil
  end
end
