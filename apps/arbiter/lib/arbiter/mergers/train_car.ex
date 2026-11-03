defmodule Arbiter.Mergers.TrainCar do
  @moduledoc """
  The git side of a speculative merge-train car (bd-6dyva0).

  With `merge.train.depth` K > 1 the auto-merge lane tests up to K queued MRs at
  once on stacked bases: car 1 is `target + A`, car 2 is `car 1 + B`, and so on
  (`Arbiter.Worker.MergeTrain`). A car is one merge commit on an
  **Arbiter-owned ref** (`arbiter/train/<task id>`), never on an MR branch:

    * built with plumbing in the repo's own `repo_paths` checkout — `git
      merge-tree --write-tree` for the tree, `git commit-tree` for the commit —
      so no worktree, index or HEAD is touched and no MR branch moves;
    * its tree is exactly the tree `merge-tree` gives for its two parents (the
      car or target commit it stands on, and the MR head), so it carries no
      content of its own: a car commit is *non-authored* (`verify/2` proves it);
    * deterministic: the same base and head build the same commit (author and
      committer are Arbiter's, dated by the newer parent), so a rebuild that
      changes nothing re-pushes nothing new.

  ## Why a car's pipeline can authorise the MR's own merge

  The MR is still merged by the forge, with the MR head as the atomic `sha`
  precondition — the car is only the test vehicle. A forge merge commit of
  `tip` and the MR head has the tree `merge-tree(tip, head)`; `landing_tree/3`
  computes that tree before the merge. When it equals the car's tree, the tree
  that lands on the target is the tree the car's pipeline tested. After car 1's
  MR merges, the target tip is the forge's merge commit of the same parents car
  1 had, so car 2's prediction still equals car 2's tree and its running
  pipeline stays valid; anything else that moved the target makes them differ,
  and the car is rebuilt instead of merged. `landed/4` is the after-the-fact
  check.

  ## Safety

  Every failure is an error, never a car: a commit git cannot resolve (after a
  fetch by sha, which both GitHub and GitLab serve for a reachable commit), a
  conflict (`merge-tree` exits 1), a push the remote refuses. Shas and refs that
  reach git argv are validated, so nothing from a forge response is read as an
  option.
  """

  @default_prefix "arbiter/train/"
  @sha ~r/\A[0-9a-fA-F]{7,64}\z/
  @landed_depth 50

  @identity [
    {"GIT_AUTHOR_NAME", "arbiter"},
    {"GIT_AUTHOR_EMAIL", "arbiter@localhost"},
    {"GIT_COMMITTER_NAME", "arbiter"},
    {"GIT_COMMITTER_EMAIL", "arbiter@localhost"}
  ]

  @type car :: %{
          required(:sha) => String.t(),
          required(:tree) => String.t(),
          required(:base) => String.t(),
          required(:mr_head) => String.t(),
          optional(atom()) => term()
        }

  @doc """
  The Arbiter-owned branch a ticket's car lives on: `<prefix><task id>`,
  `arbiter/train/` by default (`merge.train.ref_prefix`). Characters git would
  read as structure are replaced.
  """
  @spec ref_name(String.t(), String.t() | nil) :: String.t()
  def ref_name(task_id, prefix \\ nil) when is_binary(task_id) do
    prefix =
      case prefix do
        p when is_binary(p) and p != "" -> p
        _ -> @default_prefix
      end

    prefix <> String.replace(task_id, ~r/[^A-Za-z0-9_-]+/, "-")
  end

  @doc """
  Build the car `base + mr_head` in `repo_path`: `{:ok, %{sha, tree, base,
  mr_head}}` with full shas, `{:error, {:conflict, files}}` when the merge does
  not apply cleanly, else `{:error, reason}`. Missing commits are fetched from
  `origin` by sha. `opts`: `:message`.
  """
  @spec build(String.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, car()} | {:error, term()}
  def build(repo_path, base, mr_head, opts \\ []) do
    with {:ok, repo} <- usable(repo_path),
         {:ok, [base, head]} <- commits(repo, [base, mr_head]),
         {:ok, tree} <- merge_tree(repo, base, head),
         {:ok, sha} <- commit_tree(repo, tree, base, head, Keyword.get(opts, :message)) do
      {:ok, %{sha: sha, tree: tree, base: base, mr_head: head}}
    end
  end

  @doc """
  Prove `car` is a non-authored merge: its commit's parents are exactly
  `[car.base, car.mr_head]`, and its tree is both the recorded `car.tree` and
  the tree `merge-tree` gives for those parents. `:ok`, or `{:error, reason}`.
  """
  @spec verify(String.t() | nil, car()) :: :ok | {:error, term()}
  def verify(repo_path, %{sha: sha, tree: recorded, base: base, mr_head: head}) do
    with {:ok, repo} <- usable(repo_path),
         {:ok, [sha, base, head]} <- commits(repo, [sha, base, head]),
         {:ok, parents} <- parents(repo, sha),
         :ok <- if(parents == [base, head], do: :ok, else: {:error, :parents_differ}),
         {:ok, actual} <- tree(repo, sha),
         {:ok, merged} <- merge_tree(repo, base, head) do
      cond do
        actual != merged -> {:error, :tree_differs_from_merge}
        actual != recorded -> {:error, :tree_differs_from_record}
        true -> :ok
      end
    end
  end

  def verify(_repo_path, _car), do: {:error, :bad_car}

  @doc """
  The tree a forge merge commit of `tip` and `mr_head` would have:
  `{:ok, tree}`, `{:error, {:conflict, files}}`, or `{:error, reason}`.
  """
  @spec landing_tree(String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def landing_tree(repo_path, tip, mr_head) do
    with {:ok, repo} <- usable(repo_path),
         {:ok, [tip, head]} <- commits(repo, [tip, mr_head]) do
      merge_tree(repo, tip, head)
    end
  end

  @doc """
  The current tip of `target` on `origin`, freshly fetched. A fetch that fails
  is an error: an old tip would make a stale car look current.
  """
  @spec target_tip(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def target_tip(repo_path, target) do
    with {:ok, repo} <- usable(repo_path),
         :ok <- valid_ref(target),
         {:ok, _} <- git(repo, ["fetch", "--quiet", "--no-tags", "origin", target]),
         {:ok, out} <- git(repo, ["rev-parse", "--verify", "refs/remotes/origin/#{target}"]) do
      {:ok, String.trim(out)}
    else
      {:error, {:git_failed, _, _} = why} -> {:error, {:fetch_failed, why}}
      other -> other
    end
  end

  @doc "The tree of commit `sha`."
  @spec tree_of(String.t() | nil, String.t()) :: {:ok, String.t()} | {:error, term()}
  def tree_of(repo_path, sha) do
    with {:ok, repo} <- usable(repo_path),
         {:ok, [sha]} <- commits(repo, [sha]) do
      tree(repo, sha)
    end
  end

  @doc """
  Point `ref` (an Arbiter-owned branch) on `origin` at `sha`. Forced: the ref is
  Arbiter's and a rebuilt car replaces the old one. `push_options` are extra
  `git push` arguments the forge wants (GitLab: `-o ci.skip`, so the push itself
  starts no pipeline beside the one the train asks for).
  """
  @spec push(String.t() | nil, String.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def push(repo_path, sha, ref, push_options \\ []) when is_list(push_options) do
    with {:ok, repo} <- usable(repo_path),
         :ok <- valid_sha(sha),
         :ok <- valid_ref(ref),
         {:ok, _} <-
           git(repo, ["push", "--force" | push_options] ++ ["origin", "#{sha}:refs/heads/#{ref}"]) do
      :ok
    end
  end

  @doc "Delete `ref` from `origin`. A ref that is already gone is `:ok`."
  @spec delete(String.t() | nil, String.t()) :: :ok | {:error, term()}
  def delete(repo_path, ref) do
    with {:ok, repo} <- usable(repo_path),
         :ok <- valid_ref(ref) do
      case git(repo, ["push", "origin", "--delete", "refs/heads/#{ref}"]) do
        {:ok, _} ->
          :ok

        {:error, {:git_failed, _code, out}} = error ->
          if out =~ ~r/remote ref does not exist|unable to delete .*: remote ref/i,
            do: :ok,
            else: error
      end
    end
  end

  @doc """
  After the merge: the commit on `target`'s first-parent chain (newest
  #{@landed_depth}) whose tree is `car.tree` and which contains the car's MR
  head — the tree the car tested, landed. `{:ok, sha}` or `{:error,
  :not_landed}` (or a git error).
  """
  @spec landed(String.t() | nil, String.t(), car(), pos_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def landed(repo_path, target, %{tree: want, mr_head: head}, depth \\ @landed_depth) do
    with {:ok, tip} <- target_tip(repo_path, target),
         {:ok, repo} <- usable(repo_path),
         {:ok, out} <-
           git(repo, [
             "log",
             "--first-parent",
             "-n",
             Integer.to_string(depth),
             "--format=%H %T",
             tip
           ]) do
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)
      |> Enum.find_value({:error, :not_landed}, fn
        [sha, ^want] -> if ancestor?(repo, head, sha), do: {:ok, sha}
        _ -> nil
      end)
    end
  end

  # ---- git ---------------------------------------------------------------

  defp usable(path) when is_binary(path) and path != "" do
    if File.dir?(path), do: {:ok, path}, else: {:error, {:no_such_repo, path}}
  end

  defp usable(_), do: {:error, :no_repo_path}

  # Full shas for `revs`, fetching by sha whatever the checkout lacks.
  defp commits(repo, revs) do
    Enum.reduce_while(revs, {:ok, []}, fn rev, {:ok, acc} ->
      case commit(repo, rev) do
        {:ok, full} -> {:cont, {:ok, [full | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, full} -> {:ok, Enum.reverse(full)}
      error -> error
    end
  end

  defp commit(repo, rev) do
    with :ok <- valid_sha(rev) do
      case rev_parse_commit(repo, rev) do
        {:ok, full} ->
          {:ok, full}

        :error ->
          _ = git(repo, ["fetch", "--quiet", "--no-tags", "origin", rev])

          case rev_parse_commit(repo, rev) do
            {:ok, full} -> {:ok, full}
            :error -> {:error, {:unknown_commit, rev}}
          end
      end
    end
  end

  defp rev_parse_commit(repo, rev) do
    case git(repo, ["rev-parse", "--verify", "--quiet", rev <> "^{commit}"]) do
      {:ok, out} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp merge_tree(repo, ours, theirs) do
    case run(repo, ["merge-tree", "--write-tree", "--no-messages", "--name-only", ours, theirs]) do
      {out, 0} ->
        {:ok, out |> String.split("\n", trim: true) |> hd() |> String.trim()}

      {out, 1} ->
        [_tree | files] = String.split(out, "\n", trim: true)
        {:error, {:conflict, files |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()}}

      {out, code} ->
        {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  defp commit_tree(repo, tree, base, head, message) do
    message = message || "Arbiter merge-train car\n\nbase #{base}\nhead #{head}\n"
    date = "@#{max(commit_time(repo, base), commit_time(repo, head))} +0000"
    env = @identity ++ [{"GIT_AUTHOR_DATE", date}, {"GIT_COMMITTER_DATE", date}]

    case run(repo, ["commit-tree", tree, "-p", base, "-p", head, "-m", message], env) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  defp commit_time(repo, sha) do
    with {:ok, out} <- git(repo, ["show", "-s", "--format=%ct", sha]),
         {n, _} <- Integer.parse(String.trim(out)) do
      n
    else
      _ -> 0
    end
  end

  defp parents(repo, sha) do
    with {:ok, out} <- git(repo, ["rev-list", "--parents", "-n", "1", sha]) do
      case String.split(out) do
        [^sha | parents] -> {:ok, parents}
        _ -> {:error, {:unexpected_rev_list, sha}}
      end
    end
  end

  defp tree(repo, sha) do
    with {:ok, out} <- git(repo, ["rev-parse", "--verify", sha <> "^{tree}"]),
         do: {:ok, String.trim(out)}
  end

  defp ancestor?(repo, ancestor, descendant) do
    match?({_, 0}, run(repo, ["merge-base", "--is-ancestor", ancestor, descendant]))
  end

  defp valid_sha(value) do
    if is_binary(value) and Regex.match?(@sha, value), do: :ok, else: {:error, {:bad_sha, value}}
  end

  defp valid_ref(value) do
    if is_binary(value) and value != "" and not String.starts_with?(value, "-") and
         not String.contains?(value, [" ", "..", ":", "~", "^", "?", "*", "[", "\\"]),
       do: :ok,
       else: {:error, {:bad_ref, value}}
  end

  defp git(repo, args) do
    case run(repo, args) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  # `GIT_TERMINAL_PROMPT=0`: a fetch or push that wants credentials fails
  # instead of waiting on a prompt nobody will answer inside the Watchdog.
  defp run(repo, args, env \\ []) do
    System.cmd("git", ["-C", repo | args],
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"} | env]
    )
  rescue
    e -> {Exception.message(e), -1}
  end
end
