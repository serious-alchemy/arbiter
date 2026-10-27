defmodule Arbiter.Worker.MergeFreshness do
  @moduledoc """
  The merge-time freshness check (bd-5z9yvb, follow-up to bd-8slhrb / #951).

  ReviewGate no longer merges `origin/<target>` into a branch at every gate, so
  the one sync a merge needs happens right before the merge. The forge-reported
  `:behind_base` block only covers forges that enforce up-to-date (GitHub
  "require branches to be up to date", GitLab fast-forward / semi-linear merge
  methods). GitLab `merge_method: merge` on the Free tier has neither merged-results
  pipelines nor merge trains: its MR pipeline tests the branch head alone, and the
  forge never calls the branch behind, so a stale branch would merge after CI saw
  only its old head.

  This check is forge-independent. Before merging an approved PR, if the branch
  head lacks more than `merge.up_to_date_tolerance` commits of the target, the
  caller syncs the branch once (`adapter.update_branch/1`), waits for CI on the
  synced head and only then merges.

  ## Config (`merge.*`)

    * `require_up_to_date` — default `true`. Set `false` only when the forge
      itself refuses stale merges and you want to skip the extra local check.
      **GitLab `merge_method=merge` on Free needs it on.**
    * `up_to_date_tolerance` — default `0` (sync for any missing target commit;
      correctness first). A positive N lets a branch up to N commits behind
      merge unsynced, trading a small untested-combination window for fewer
      sync pipelines on busy targets.

  When the forge already reports `:behind_base`, the existing update-branch
  path handles it; callers consult this module only for an otherwise-mergeable
  PR, so there is no double sync.

  The probe is overridable with `config :arbiter, :merge_freshness_probe`
  (`fn repo_path, base, head -> {:ok, n} | {:error, term} end`) for tests.
  """

  alias Arbiter.Mergers.LocalCompare

  @doc "Is the freshness check on for `workspace`? Default `true`."
  @spec required?(map() | nil) :: boolean()
  def required?(workspace) do
    case merge_setting(workspace, "require_up_to_date") do
      false -> false
      "false" -> false
      _ -> true
    end
  end

  @default_max_syncs 3

  @doc "Freshness syncs allowed per head (`merge.max_freshness_syncs`). Default `3`."
  @spec max_syncs(map() | nil) :: pos_integer()
  def max_syncs(workspace) do
    case merge_setting(workspace, "max_freshness_syncs") do
      n when is_integer(n) and n >= 1 -> n
      s when is_binary(s) -> parse_pos(s)
      _ -> @default_max_syncs
    end
  end

  defp parse_pos(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 -> n
      _ -> @default_max_syncs
    end
  end

  @doc "Commits the head may lack and still merge unsynced. Default `0`."
  @spec tolerance(map() | nil) :: non_neg_integer()
  def tolerance(workspace) do
    case merge_setting(workspace, "up_to_date_tolerance") do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  @doc """
  How many target commits `head` lacks, from the local checkout at `repo_path`
  after fetching `origin/<base>`. An error means "could not tell".
  """
  @spec behind_by(String.t() | nil, String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def behind_by(repo_path, base, head) do
    case Application.get_env(:arbiter, :merge_freshness_probe) do
      fun when is_function(fun, 3) -> fun.(repo_path, base, head)
      _ -> LocalCompare.behind_by(repo_path, base, head)
    end
  end

  @doc """
  `:fresh` (no sync needed), `{:stale, n}` (sync first) or `{:unknown, reason}`
  (could not tell; callers fail open and log).
  """
  @spec check(map() | nil, String.t() | nil, String.t() | nil, String.t() | nil) ::
          :fresh | {:stale, pos_integer()} | {:unknown, term()}
  def check(workspace, repo_path, base, head) do
    cond do
      not required?(workspace) -> :fresh
      not (present?(base) and present?(head)) -> {:unknown, :no_base_or_head}
      true -> classify(workspace, behind_by(repo_path, base, head))
    end
  end

  defp classify(workspace, {:ok, n}) when n > 0,
    do: if(n > tolerance(workspace), do: {:stale, n}, else: :fresh)

  defp classify(_workspace, {:ok, _}), do: :fresh
  defp classify(_workspace, {:error, reason}), do: {:unknown, reason}

  defp present?(value), do: is_binary(value) and value != ""

  defp merge_setting(%{config: %{} = config}, key), do: get_in(config, ["merge", key])
  defp merge_setting(_workspace, _key), do: nil
end
