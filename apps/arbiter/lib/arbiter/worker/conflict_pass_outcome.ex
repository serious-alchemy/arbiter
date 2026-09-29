defmodule Arbiter.Worker.ConflictPassOutcome do
  @moduledoc """
  Did a conflict pass deliver? And what does it leave behind in its worktree?
  (bd-4olwyg)

  A conflict pass (`Arbiter.Workflows.MergeQueue.ConflictResolver`, role
  `:conflict_resolver`) has exactly one deliverable: a push that moves the PR
  branch off the conflicting head. Before bd-4olwyg a pass was recorded
  `succeeded` whenever its run ended without an error — including the incident
  run that the ticket's Watchdog stopped 19 seconds in, mid-rebase, with nothing
  pushed. The ticket then read as "resolved" to everything downstream while its
  PR stayed `CONFLICTING`.

  `verdict/1` is the check a pass's end goes through instead:

    * a rebase or merge still stopped part-way in the worktree → unresolved,
      whatever was pushed earlier: the pass did not finish its job;
    * the PR branch's remote head (`Worktree.remote_head/2`) still where it was
      when the pass started (`meta[:conflict_start_head]`) → unresolved: nothing
      was pushed;
    * otherwise → resolved.

  It fails open — `:resolved`, the pre-bd-4olwyg behaviour — when it lacks the
  facts to judge: no worktree or branch in the pass's meta, no recorded start
  head, or a remote it cannot read. A false "unresolved" costs a bounded retry
  and a page; a false "resolved" costs what bd-4olwyg cost, so only a verdict
  git can actually back is allowed to fail a run.

  `settle_worktree/1` aborts whatever operation the pass left stopped, so the
  worktree is back on its branch at its pre-pass tip — the state the next
  dispatch (`Worktree.attach/2`) and a resume both expect.
  """

  alias Arbiter.Worker.Worktree

  require Logger

  @doc """
  `:resolved`, or `{:unresolved, reason}` naming the unresolved state, for the
  conflict pass whose run meta is `meta`. Read BEFORE `settle_worktree/1`: an
  abort erases the mid-rebase evidence.
  """
  @spec verdict(map()) :: :resolved | {:unresolved, String.t()}
  def verdict(meta) when is_map(meta) do
    path = worktree(meta)
    branch = Map.get(meta, :conflict_resolver_branch)

    if is_binary(path) and is_binary(branch) do
      start_head = Map.get(meta, :conflict_start_head)
      judge(Worktree.in_progress_operation(path), path, branch, start_head)
    else
      :resolved
    end
  end

  def verdict(_meta), do: :resolved

  @doc """
  Abort any rebase or merge left stopped in the pass's worktree. `{:ok, op}` for
  what was aborted (`nil` when nothing was, or there is no worktree), or the
  abort's own error. Logged either way; never raises.
  """
  @spec settle_worktree(map()) :: {:ok, :rebase | :merge | nil} | {:error, term()}
  def settle_worktree(meta) when is_map(meta) do
    case worktree(meta) do
      nil -> {:ok, nil}
      path -> abort(path)
    end
  end

  def settle_worktree(_meta), do: {:ok, nil}

  defp judge(op, path, branch, start_head) when op in [:rebase, :merge] do
    files = Worktree.unmerged_files(path)

    {:unresolved,
     "conflict pass ended mid-#{op} of #{branch}" <>
       unmerged_clause(files) <> "; " <> pushed_clause(path, branch, start_head)}
  end

  defp judge(nil, path, branch, start_head) when is_binary(start_head) do
    case Worktree.remote_head(path, branch) do
      ^start_head ->
        {:unresolved,
         "conflict pass ended without pushing: the PR head of #{branch} is still " <>
           short(start_head) <> ", so the conflict is unresolved"}

      _moved_or_unreadable ->
        :resolved
    end
  end

  defp judge(nil, _path, _branch, _start_head), do: :resolved

  defp unmerged_clause([]), do: ""

  defp unmerged_clause(files) do
    shown = files |> Enum.take(5) |> Enum.join(", ")
    more = if length(files) > 5, do: ", …", else: ""
    " with #{length(files)} unmerged file(s) (#{shown}#{more})"
  end

  defp pushed_clause(path, branch, start_head) when is_binary(start_head) do
    case Worktree.remote_head(path, branch) do
      ^start_head -> "nothing was pushed — the PR head is still #{short(start_head)}"
      nil -> "the PR head could not be read"
      head -> "the PR head moved to #{short(head)} before it stopped"
    end
  end

  defp pushed_clause(_path, _branch, _start_head), do: "the PR head at its start was not recorded"

  defp abort(path) do
    case Worktree.abort_in_progress(path) do
      {:ok, nil} = none ->
        none

      {:ok, op} = aborted ->
        Logger.info("ConflictPassOutcome: aborted the #{op} a pass left stopped in #{path}")
        aborted

      {:error, reason} = error ->
        Logger.warning(
          "ConflictPassOutcome: could not abort the operation a pass left stopped in " <>
            "#{path}: #{inspect(reason)}"
        )

        error
    end
  end

  defp worktree(meta) do
    case Map.get(meta, :worktree_path) do
      path when is_binary(path) -> if File.dir?(path), do: path
      _ -> nil
    end
  end

  defp short(sha), do: String.slice(sha, 0, 8)
end
