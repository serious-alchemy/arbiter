defmodule Arbiter.Worker.ReviewSync do
  @moduledoc """
  The staleness thresholds for the pre-review target sync (bd-8slhrb).

  A ReviewGate used to merge `origin/<target>` into the branch and push it at the
  start of every gate whenever the branch was merely behind, which started a full
  CI pipeline per gate. It now reviews against `merge-base(HEAD, origin/<target>)`
  and merges the target only when the branch conflicts with it (the conflict
  escalation) or is stale past either threshold:

    * `review.max_commits_behind` — merge once the target is MORE than this many
      commits ahead of the branch. Default `100`; `0` disables.
    * `review.max_hours_behind` — merge once the target tip is MORE than this many
      hours newer than the branch's fork point. Default `0` (disabled).

  Both can be overridden per repo at `review.repos.<repo>.<key>`. The one sync a
  merge needs happens at merge time (MergeQueue / Watchdog `update_branch`).
  """

  alias Arbiter.Tasks.{RepoConfig, Workspace}

  @default_max_commits_behind 100
  @default_max_hours_behind 0

  @doc "Default for `review.max_commits_behind`."
  @spec default_max_commits_behind() :: non_neg_integer()
  def default_max_commits_behind, do: @default_max_commits_behind

  @doc "Default for `review.max_hours_behind`."
  @spec default_max_hours_behind() :: non_neg_integer()
  def default_max_hours_behind, do: @default_max_hours_behind

  @doc """
  The `Worktree.review_sync/3` options for `repo` of `workspace`. A missing
  workspace or unparsable value falls back to the default.
  """
  @spec opts(Workspace.t() | nil, String.t() | nil) :: keyword()
  def opts(workspace, repo) do
    [
      max_commits_behind:
        setting(workspace, repo, "max_commits_behind", @default_max_commits_behind),
      max_hours_behind: setting(workspace, repo, "max_hours_behind", @default_max_hours_behind)
    ]
  end

  defp setting(%Workspace{config: config}, repo, key, default) do
    review = Map.get(config || %{}, "review")

    with true <- is_map(review),
         value when not is_nil(value) <- repo_value(review, repo, key) || Map.get(review, key),
         n when is_integer(n) <- to_int(value) do
      n
    else
      _ -> default
    end
  end

  defp setting(_workspace, _repo, _key, default), do: default

  defp repo_value(review, repo, key) do
    with true <- is_binary(repo),
         %{} = repos <- Map.get(review, "repos"),
         %{} = entry <- RepoConfig.find_entry(repos, repo) do
      Map.get(entry, key)
    else
      _ -> nil
    end
  end

  defp to_int(n) when is_integer(n) and n >= 0, do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
