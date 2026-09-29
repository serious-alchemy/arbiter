defmodule Arbiter.Mergers.LocalCompare do
  @moduledoc """
  The merge guard's compare questions, answered from the task's own local
  checkout when the forge's compare API cannot answer them (bd-wjpxok / #26).

  The stale-reviewed-SHA guard and the coverage predicate
  (`Arbiter.Reviews.Coverage`) both need two facts about a PR head the forge
  reports: its **net diff** against the base (`base...head`, three-dot) and,
  for rule 2, whether one commit is an **ancestor** of another. Both hosted
  adapters serve them from their compare endpoints, so any compare outage —
  the captured one was GitLab's 403 `insufficient_granular_scope` on vstim
  !270 (vs-4v8cf0), but a 404, a 5xx or a timeout is the same shape — left an
  approved MR undecided (`diff_unavailable`) until it parked, while the answer
  sat one `git merge-base --is-ancestor` away in a repo Arbiter already has
  checked out.

  Everything here is plain git in a `repo_paths` checkout, after a fetch from
  its `origin`, and so is the same for every merger adapter.

  ## Why the local answer is comparable with the recorded one

  `Arbiter.Worker.ReviewGate` fingerprints its `:reviewed` coverage rows with
  `NetDiff.fingerprint_local/2` — a plain `git diff <merge_base>..HEAD` in the
  task's worktree. `net_diffs/3` runs the same `git diff` over the same range
  (`git diff A...B` *is* the diff from `merge-base(A, B)` to `B`) in a checkout
  that shares the repo's config, so a head carrying exactly the reviewed
  content fingerprints to exactly the reviewed row. A forge-rendered diff is
  not guaranteed to (GitLab's JSON `changes` carry no mode/rename headers),
  which is why `diffs/4` never mixes the two sources within one comparison.

  ## Safety

  The answer only ever feeds a *content-equality* test, so the direction of
  every failure is "not equal": a commit git cannot resolve, a base that
  will not resolve, or a git error is an `{:error, _}`, never a diff. A fetch
  that fails is logged and the question is still answered from what the
  checkout already has — the commits are content-addressed, so an answer about
  them is true regardless of how fresh the fetch was, and a stale
  `origin/<base>` can only make the head's net diff *larger* (it includes base
  commits the head already carries), which fails the equality test rather
  than passing it.
  """

  require Logger

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Tasks.RepoConfig
  alias Arbiter.Tasks.Workspace

  @typedoc "Which path produced an answer — for the guard's log lines (AC5)."
  @type source :: :api | :local_git

  @typedoc "`{base, head} -> {:ok, diff} | {:error, _}`, the adapter's compare."
  @type api_diff :: (String.t(), String.t() -> term()) | nil

  @typedoc "`{ancestor, descendant} -> {:ok, boolean} | {:error, _}`, the adapter's probe."
  @type api_ancestor :: (String.t(), String.t() -> term()) | nil

  @typedoc "What `delta/4` hands the escalation: the commits and files no reviewer saw."
  @type delta :: %{commits: [String.t()], files: [String.t()]}

  # Commit-ish values that come from a forge response are interpolated into git
  # argv. A leading `-` would be read as an option; nothing legitimate starts
  # with one.
  @sha ~r/\A[0-9a-fA-F]{7,64}\z/

  @doc """
  The local checkout for `repo` — the workspace's `repo_paths` entry, else the
  global `:arbiter, :repo_paths` one, the lookup order `Arbiter.Worker.Dispatch`
  provisions worktrees from. `nil` when no repo is named or it is not mapped.
  """
  @spec repo_path(Workspace.t() | nil, String.t() | nil) :: String.t() | nil
  def repo_path(_workspace, repo) when not is_binary(repo) or repo == "", do: nil

  def repo_path(workspace, repo) do
    workspace_paths =
      case workspace do
        %Workspace{config: %{} = config} -> Map.get(config, "repo_paths")
        _ -> nil
      end

    RepoConfig.find_path(workspace_paths, repo) ||
      RepoConfig.find_path(Application.get_env(:arbiter, :repo_paths, %{}), repo)
  end

  @doc """
  The three-dot net diff `base...head` for every one of `heads`, from the
  adapter's compare (`api`) when it answers for **all** of them, else from
  local git in `repo_path` for all of them.

  One source per call, never a mix: two diffs are only comparable when both
  were rendered the same way. Returns the source alongside the diffs, or both
  failure reasons when neither could answer.
  """
  @spec diffs(api_diff(), String.t() | nil, String.t(), [String.t()]) ::
          {:ok, [String.t()], source()} | {:error, %{api: term(), local_git: term()}}
  def diffs(api, repo_path, base, heads) when is_list(heads) do
    case api_diffs(api, base, heads) do
      {:ok, diffs} ->
        {:ok, diffs, :api}

      {:error, api_reason} ->
        case net_diffs(repo_path, base, heads) do
          {:ok, diffs} -> {:ok, diffs, :local_git}
          {:error, local_reason} -> {:error, %{api: api_reason, local_git: local_reason}}
        end
    end
  end

  @doc """
  Is `ancestor` an ancestor of `descendant`? The adapter's probe first; local
  git when it cannot answer. Same return discipline as `diffs/4`.
  """
  @spec ancestry(api_ancestor(), String.t() | nil, String.t(), String.t()) ::
          {:ok, boolean(), source()} | {:error, %{api: term(), local_git: term()}}
  def ancestry(api, repo_path, ancestor, descendant) do
    case api_ancestry(api, ancestor, descendant) do
      {:ok, answer} ->
        {:ok, answer, :api}

      {:error, api_reason} ->
        case ancestor?(repo_path, ancestor, descendant) do
          {:ok, answer} -> {:ok, answer, :local_git}
          {:error, local_reason} -> {:error, %{api: api_reason, local_git: local_reason}}
        end
    end
  end

  @doc """
  `git diff <base>...<head>` for each head in `repo_path`, after fetching
  `base` and any head the checkout does not have yet. `base` is read as
  `origin/<base>` when that resolves, else as given.
  """
  @spec net_diffs(String.t() | nil, String.t(), [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def net_diffs(repo_path, base, heads) when is_list(heads) do
    with {:ok, repo} <- usable_repo(repo_path),
         :ok <- refresh(repo, base, heads),
         {:ok, base_rev} <- resolve_base(repo, base),
         {:ok, shas} <- resolve_commits(repo, heads) do
      collect(shas, fn sha -> git(repo, ["diff", "#{base_rev}...#{sha}"]) end)
    end
  end

  @doc """
  `git merge-base --is-ancestor` in `repo_path`, after fetching whichever of
  the two commits the checkout is missing. A commit git cannot resolve is an
  `{:error, _}` — "could not tell", never "no".
  """
  @spec ancestor?(String.t() | nil, String.t(), String.t()) ::
          {:ok, boolean()} | {:error, term()}
  def ancestor?(repo_path, ancestor, descendant) do
    with {:ok, repo} <- usable_repo(repo_path),
         :ok <- refresh(repo, nil, [ancestor, descendant]),
         {:ok, [a, d]} <- resolve_commits(repo, [ancestor, descendant]) do
      case run(repo, ["merge-base", "--is-ancestor", a, d]) do
        {_out, 0} -> {:ok, true}
        {_out, 1} -> {:ok, false}
        {out, code} -> {:error, {:git_failed, code, String.trim(out)}}
      end
    end
  end

  @doc """
  The unreviewed delta between `reviewed` and `head`, for an escalation that
  has to name it (AC4):

    * `:commits` — `<short sha> <subject>` for every non-merge commit on the
      head side that is not on the base and has no patch-equivalent on the
      reviewed side (`git log --cherry-pick --right-only`). When `reviewed` is
      an ancestor of `head` that is exactly `reviewed..head`; for a rebase it
      drops the replayed commits and keeps only what was added.
    * `:files` — every file whose net diff against the base differs between
      the two heads, which is what a re-review actually has to read.
  """
  @spec delta(String.t() | nil, String.t(), String.t(), String.t()) ::
          {:ok, delta()} | {:error, term()}
  def delta(repo_path, base, reviewed, head) do
    with {:ok, [reviewed_diff, head_diff]} <- net_diffs(repo_path, base, [reviewed, head]),
         {:ok, repo} <- usable_repo(repo_path),
         {:ok, base_rev} <- resolve_base(repo, base),
         {:ok, [r, h]} <- resolve_commits(repo, [reviewed, head]),
         {:ok, log} <-
           git(repo, [
             "log",
             "--no-merges",
             "--cherry-pick",
             "--right-only",
             "--format=%h %s",
             "#{r}...#{h}",
             "^#{base_rev}"
           ]) do
      {:ok, %{commits: lines(log), files: changed_files(reviewed_diff, head_diff)}}
    end
  end

  # ---- the API side ------------------------------------------------------

  defp api_diffs(api, base, heads) when is_function(api, 2) do
    collect(heads, fn head ->
      case safely(fn -> api.(base, head) end) do
        {:ok, {:ok, diff}} when is_binary(diff) -> {:ok, diff}
        {:ok, {:error, reason}} -> {:error, reason}
        {:ok, other} -> {:error, {:bad_return, other}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp api_diffs(_api, _base, _heads), do: {:error, :no_api}

  defp api_ancestry(api, ancestor, descendant) when is_function(api, 2) do
    case safely(fn -> api.(ancestor, descendant) end) do
      {:ok, {:ok, answer}} when is_boolean(answer) -> {:ok, answer}
      {:ok, answer} when is_boolean(answer) -> {:ok, answer}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:bad_return, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp api_ancestry(_api, _ancestor, _descendant), do: {:error, :no_api}

  # ---- the local side ----------------------------------------------------

  defp usable_repo(path) when is_binary(path) and path != "" do
    if File.dir?(path), do: {:ok, path}, else: {:error, {:no_such_repo, path}}
  end

  defp usable_repo(_path), do: {:error, :no_repo_path}

  # Best-effort, and deliberately so — see "Safety" in the moduledoc. The base
  # is fetched so `origin/<base>` names current upstream; a head is fetched by
  # sha only when the checkout lacks it (a push from elsewhere — a CI fix pass,
  # a human), which both GitHub and GitLab serve for a reachable commit.
  defp refresh(repo, base, shas) do
    if ref_name?(base), do: fetch(repo, base)

    shas
    |> Enum.filter(&sha?/1)
    |> Enum.reject(&commit?(repo, &1))
    |> Enum.each(&fetch(repo, &1))

    :ok
  end

  defp fetch(repo, ref) do
    case run(repo, ["fetch", "--quiet", "--no-tags", "origin", ref]) do
      {_out, 0} ->
        :ok

      {out, code} ->
        Logger.info(
          "Mergers.LocalCompare: git fetch origin #{ref} failed in #{repo} (#{code}): " <>
            String.slice(String.trim(out), 0, 300) <> "; answering from the local objects"
        )
    end
  end

  defp resolve_base(repo, base) do
    if ref_name?(base) do
      ["refs/remotes/origin/#{base}", base]
      |> Enum.find_value({:error, {:unknown_base, base}}, fn ref ->
        case rev_parse(repo, ref) do
          {:ok, sha} -> {:ok, sha}
          :error -> nil
        end
      end)
    else
      {:error, {:bad_base, base}}
    end
  end

  defp resolve_commits(repo, shas) do
    collect(shas, fn sha ->
      with true <- sha?(sha) || {:error, {:bad_sha, sha}},
           {:ok, full} <- rev_parse(repo, sha) do
        {:ok, full}
      else
        :error -> {:error, {:unknown_commit, sha}}
        {:error, _} = error -> error
      end
    end)
  end

  defp commit?(repo, sha), do: rev_parse(repo, sha) != :error

  defp rev_parse(repo, ref) do
    case run(repo, ["rev-parse", "--verify", "--quiet", "#{ref}^{commit}"]) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  defp git(repo, args) do
    case run(repo, args) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, code, String.slice(String.trim(out), 0, 300)}}
    end
  end

  # `GIT_TERMINAL_PROMPT=0`: a fetch that wants credentials fails instead of
  # waiting on a prompt nobody will answer inside the Watchdog's process.
  defp run(repo, args) do
    System.cmd("git", ["-C", repo | args],
      stderr_to_stdout: true,
      env: [{"GIT_TERMINAL_PROMPT", "0"}]
    )
  rescue
    e -> {Exception.message(e), -1}
  end

  # ---- helpers -----------------------------------------------------------

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  # The files whose per-file net diff differs, normalized exactly as NetDiff
  # normalizes the whole diff (hunk ranges and index lines do not count).
  defp changed_files(left, right) do
    left = per_file(left)
    right = per_file(right)

    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(left, &1) == Map.get(right, &1)))
    |> Enum.sort()
  end

  defp per_file(diff) do
    diff
    |> String.split(~r/^(?=diff --git )/m, trim: true)
    |> Enum.flat_map(fn chunk ->
      case Regex.run(~r/\Adiff --git a\/.* b\/(.*)$/m, chunk) do
        [_, path] -> [{path, NetDiff.fingerprint(chunk)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp lines(text), do: text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)

  defp sha?(value), do: is_binary(value) and Regex.match?(@sha, value)

  defp ref_name?(value),
    do: is_binary(value) and value != "" and not String.starts_with?(value, "-")

  defp safely(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end
end
