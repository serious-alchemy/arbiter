defmodule Arbiter.Mergers.SyncProof do
  @moduledoc """
  Is a moved PR head the reviewed head synced with the target, and nothing else?
  (bd-2oo8kf / #1062.)

  A queue sync (`update_branch`) or a forge rebase moves the head of a ruled or
  approved MR, and every guard keyed on the reviewed SHA then asks whether the
  new commit is still the thing somebody looked at. `verify/4` answers for the
  two shapes a sync takes, in the task's own checkout (never the forge's
  compare, whose rendering need not match):

    * **rebase** — the commits of `base..to` have the same
      `git patch-id --stable`s, in the same order, as the commits of
      `base..from`, and neither range holds a merge. That is `git range-diff`
      reporting every pair as `=`. A commit added, dropped, squashed, reordered
      or edited changes the list. The ids are taken over zero-context diffs
      (`-U0`): the target changing the lines *around* a hunk shifts its context
      but not a single added or removed line, and must not read as an edit.
    * **merge** — `to` is a two-parent merge of the reviewed commit and a commit
      that is **already on the target** (an ancestor of the target tip), and its
      tree is exactly the tree `git merge-tree --write-tree` produces for those
      two parents. A conflict (`merge-tree` exits 1) or any hunk the merge
      commit adds beyond the merge — a conflict resolution, a smuggled file —
      makes the trees differ. A merge of anything that is not the target, or an
      extra commit on top of the merge, is not this shape. Syncs stack (the
      queue syncs again while main keeps moving), so the branch-side parent may
      itself be a proven merge of `from`, bounded at `@max_depth` levels.

  ## Safety

  This widens what a ruling or an approval covers, so every failure is "not
  proven": a commit git cannot resolve, a fetch that fails, a git too old for
  `merge-tree --write-tree`, an empty range, a merge with other than two
  parents. Callers fall back to the behaviour they had before this module
  existed — the head is judged as any other new head.
  """

  alias Arbiter.Mergers.LocalCompare

  @max_depth 8

  @type kind :: :rebase | :merge

  @doc """
  `{:ok, kind, proof}` when `to` is `from` synced with `base` (see the moduledoc),
  else `{:error, reason}`. `proof` is a one-line, human-readable statement of how
  it was established, for the record. `repo_path` is the task's checkout.
  """
  @spec verify(String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, kind(), String.t()} | {:error, term()}
  def verify(repo_path, base, from, to) when is_binary(from) and is_binary(to) do
    with {:ok, repo, base_rev, [from_rev, to_rev]} <-
           LocalCompare.prepare(repo_path, base, [from, to]),
         :ok <- distinct(from_rev, to_rev) do
      case rebase_proof(repo, base_rev, from_rev, to_rev) do
        {:ok, proof} ->
          {:ok, :rebase, proof}

        {:error, rebase_reason} ->
          case merge_proof(repo, base_rev, from_rev, to_rev, @max_depth) do
            {:ok, proof} -> {:ok, :merge, proof}
            {:error, merge_reason} -> {:error, %{rebase: rebase_reason, merge: merge_reason}}
          end
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  def verify(_repo_path, _base, _from, _to), do: {:error, :bad_input}

  defp distinct(same, same), do: {:error, :same_head}
  defp distinct(_from, _to), do: :ok

  # ---- rebase ------------------------------------------------------------

  defp rebase_proof(repo, base, from, to) do
    with {:ok, from_ids} <- patch_ids(repo, base, from),
         {:ok, to_ids} <- patch_ids(repo, base, to) do
      if from_ids == to_ids do
        {:ok,
         "rebase: the #{length(from_ids)} commit(s) of #{String.slice(to, 0, 12)} have " <>
           "identical patch-ids (git patch-id --stable) to those of #{String.slice(from, 0, 12)}"}
      else
        {:error, :patch_ids_differ}
      end
    end
  end

  # The ordered patch-ids of `base..sha`. Refuses a range holding a merge, an
  # empty range, and a range where any commit yields no patch-id (an empty
  # commit): the id list must account for every commit.
  defp patch_ids(repo, base, sha) do
    range = "#{base}..#{sha}"

    with {:ok, merges} <- git_int(repo, ["rev-list", "--merges", "--count", range]),
         :ok <- if(merges == 0, do: :ok, else: {:error, {:merge_in_range, sha}}),
         {:ok, count} <- git_int(repo, ["rev-list", "--count", range]),
         :ok <- if(count > 0, do: :ok, else: {:error, {:empty_range, sha}}),
         {:ok, ids} <- log_patch_ids(repo, range),
         :ok <- if(length(ids) == count, do: :ok, else: {:error, {:commit_without_patch, sha}}) do
      {:ok, ids}
    end
  end

  # `git log -p | git patch-id --stable`, piped by `sh` with the repo and range
  # as positional parameters (never interpolated into the script).
  defp log_patch_ids(repo, range) do
    script =
      ~S(git -C "$1" log --reverse --no-merges --no-color --no-ext-diff -p -U0 "$2" ) <>
        "| git patch-id --stable"

    case System.cmd("sh", ["-c", script, "sh", repo, range],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} ->
        {:ok,
         out
         |> String.split("\n", trim: true)
         |> Enum.map(&(&1 |> String.split(" ", parts: 2) |> hd()))}

      {out, code} ->
        {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  # ---- merge -------------------------------------------------------------

  defp merge_proof(_repo, _base, _from, _to, 0), do: {:error, :merge_chain_too_deep}

  defp merge_proof(repo, base, from, to, depth) do
    with {:ok, parents} <- parents(repo, to),
         [p1, p2] <- parents,
         {:ok, target_parent, branch_parent} <- split_parents(repo, base, p1, p2),
         :ok <- clean_merge_tree(repo, to, branch_parent, target_parent),
         {:ok, chain} <- reach_from(repo, base, from, branch_parent, depth) do
      {:ok,
       "merge: #{String.slice(to, 0, 12)} is #{String.slice(from, 0, 12)} merged with " <>
         "#{String.slice(target_parent, 0, 12)} (on #{short_base(base)}); its tree equals " <>
         "git merge-tree of the two parents, so it adds no resolution hunk" <> chain}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_a_two_parent_merge}
    end
  end

  # The branch-side parent is `from` itself, or a proven merge of it.
  defp reach_from(_repo, _base, from, from, _depth), do: {:ok, ""}

  defp reach_from(repo, base, from, branch_parent, depth) do
    case merge_proof(repo, base, from, branch_parent, depth - 1) do
      {:ok, _} -> {:ok, " (stacked on an earlier proven sync)"}
      {:error, _} = error -> error
    end
  end

  # Exactly one parent is on the target (an ancestor of its tip); the other is
  # the branch side. Neither or both: not a sync of the target into a branch.
  defp split_parents(repo, base, p1, p2) do
    with {:ok, p1_on_target?} <- ancestor?(repo, p1, base),
         {:ok, p2_on_target?} <- ancestor?(repo, p2, base) do
      case {p1_on_target?, p2_on_target?} do
        {false, true} -> {:ok, p2, p1}
        {true, false} -> {:ok, p1, p2}
        {true, true} -> {:error, :both_parents_on_target}
        {false, false} -> {:error, :merged_commit_not_on_target}
      end
    end
  end

  defp clean_merge_tree(repo, merge, branch_parent, target_parent) do
    case System.cmd(
           "git",
           [
             "-C",
             repo,
             "merge-tree",
             "--write-tree",
             "--no-messages",
             branch_parent,
             target_parent
           ],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} ->
        expected = out |> String.split("\n", trim: true) |> List.first()

        with {:ok, actual} <- git(repo, ["rev-parse", "--verify", "#{merge}^{tree}"]) do
          if is_binary(expected) and String.trim(actual) == String.trim(expected),
            do: :ok,
            else: {:error, :tree_differs_from_merge_tree}
        end

      {_out, 1} ->
        {:error, :merge_would_conflict}

      {out, code} ->
        {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  # ---- git ---------------------------------------------------------------

  defp parents(repo, sha) do
    with {:ok, out} <- git(repo, ["rev-list", "--parents", "-n", "1", sha]) do
      case String.split(out) do
        [^sha | parents] -> {:ok, parents}
        _ -> {:error, {:unexpected_rev_list, sha}}
      end
    end
  end

  defp ancestor?(repo, ancestor, descendant) do
    case System.cmd("git", ["-C", repo, "merge-base", "--is-ancestor", ancestor, descendant],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> {:ok, true}
      {_out, 1} -> {:ok, false}
      {out, code} -> {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  defp git_int(repo, args) do
    with {:ok, out} <- git(repo, args) do
      case Integer.parse(String.trim(out)) do
        {n, ""} -> {:ok, n}
        _ -> {:error, {:unparsable_count, String.trim(out)}}
      end
    end
  end

  defp git(repo, args) do
    case System.cmd("git", ["-C", repo | args],
           stderr_to_stdout: true,
           env: [{"GIT_TERMINAL_PROMPT", "0"}]
         ) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  defp short_base(base), do: String.slice(base, 0, 12)
end
