defmodule Arbiter.Loop.Replay.Subject do
  @moduledoc """
  The closed task an offline replay re-runs, and its known-good result (R15,
  bd-c7lx65; `docs/design/paced-quota-routing-signals.md` §7.2).

  ## Which tasks (`eligible/1`)

  A task closed `completed`: closed tasks are the ones that got solved, so each
  has a merged change to score against (the design's selection risk). Never one
  that declares permissions (`network:…`, `tracker_write`, `secrets:…`,
  `prod_read`, `prod_ssh`, …): it is coupled to external state a replay must
  not reach. Never a review-only ticket (it changed no code) nor an epic.

  ## Where the known-good result is (`resolve/1`)

  Neither the base commit a worker started from nor the merge commit is
  recorded, so both are worked out in the repo's local checkout:

    1. **The PR head.** The first of the heads the ticket recorded that the
       checkout has, in order: the forge's last report (`merger_status`), the
       reviewed head the merge lane latched and the ReviewGate's
       (`merge_watch.reviewed_sha`, `last_reviewed_sha`), the head the run
       pushed (`merge_watch.local_head_sha`). The base is where that head left
       the target branch (`git merge-base`), and the known-good change is
       `base..head`, the change the PR merged.
    2. **The squash commit.** When no recorded head is left (a merged branch's
       objects are pruned in time), the commit the PR landed as on the target
       branch, found by its number the way GitHub writes it (`Title (#N)`, or
       `Merge pull request #N …`): exactly one match, never a revert. The base
       is its first parent.

  A recorded head comes from the forge, so it reaches git only if it looks
  like a commit id.

  The cell a replay's evidence belongs to is the first attempt's, as in
  `Arbiter.Loop.SubjectStats`: its `difficulty_at_dispatch` (the ticket's own
  difficulty when no attempt is on record) and the ticket's type.
  """

  require Ash.Query

  alias Arbiter.Loop.Replay.Sandbox
  alias Arbiter.Mergers.LocalCompare
  alias Arbiter.Nodes.Checkout.Git
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.TargetBranch
  alias Arbiter.Workers.Run

  @sha ~r/\A[0-9a-fA-F]{7,64}\z/
  @default_limit 20

  @type t :: %{
          task_id: String.t(),
          issue: Issue.t(),
          workspace: Workspace.t(),
          repo: String.t(),
          repo_path: Path.t(),
          target_branch: String.t(),
          base_sha: String.t(),
          known_good_sha: String.t(),
          provenance: :pr_head | :squash_commit,
          difficulty: integer() | nil,
          issue_type: String.t() | nil,
          live_provider: String.t() | nil,
          live_model: String.t() | nil
        }

  @doc "Resolve a closed task (an `Issue` or its id) for a replay. See the moduledoc."
  @spec resolve(Issue.t() | String.t()) :: {:ok, t()} | {:error, term()}
  def resolve(task_id) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = issue} -> resolve(issue)
      _ -> {:error, :not_found}
    end
  end

  def resolve(%Issue{} = issue) do
    with :ok <- eligible(issue),
         {:ok, workspace} <- workspace(issue),
         {:ok, repo_path} <- repo_path(workspace, issue.repo),
         {:ok, common} <- Sandbox.common_dir(repo_path),
         target = TargetBranch.resolve(issue, repo: issue.repo),
         {:ok, found} <- known_good(issue, common, target) do
      first = first_attempt(issue.id)

      {:ok,
       Map.merge(found, %{
         task_id: issue.id,
         issue: issue,
         workspace: workspace,
         repo: issue.repo,
         repo_path: repo_path,
         target_branch: target,
         difficulty: (first && first.difficulty_at_dispatch) || issue.difficulty,
         issue_type: issue.issue_type && to_string(issue.issue_type),
         live_provider: first && first.provider,
         live_model: first && first.model
       })}
    end
  end

  @doc """
  Whether a ticket may be replayed at all, before anything is read from git.
  See the moduledoc.
  """
  @spec eligible(Issue.t()) :: :ok | {:error, term()}
  def eligible(%Issue{state: state}) when state != :closed, do: {:error, {:not_closed, state}}

  def eligible(%Issue{close_reason: reason}) when reason != :completed,
    do: {:error, {:not_completed, reason}}

  def eligible(%Issue{permissions: [_ | _] = permissions}),
    do: {:error, {:permissions, permissions}}

  def eligible(%Issue{review_only: true}), do: {:error, :review_only}

  def eligible(%Issue{issue_type: type}) when is_atom(type) and not is_nil(type) do
    if type in Issue.non_dispatchable_types(),
      do: {:error, {:not_dispatchable, type}},
      else: :ok
  end

  def eligible(%Issue{}), do: :ok

  @doc """
  The closed, completed tickets a replay could take, newest close first, each
  with its `resolve/1` answer (so a refusal says why). Options: `:workspace_id`,
  `:repo`, `:difficulty` (the ticket's), `:issue_type`, `:limit` (default
  #{@default_limit}).
  """
  @spec candidates(keyword()) :: [{Issue.t(), {:ok, t()} | {:error, term()}}]
  def candidates(opts \\ []) do
    Issue
    |> Ash.Query.filter(state == :closed and close_reason == :completed)
    |> maybe_filter(:workspace_id, opts[:workspace_id])
    |> maybe_filter(:repo, opts[:repo])
    |> maybe_filter(:difficulty, opts[:difficulty])
    |> maybe_filter(:issue_type, opts[:issue_type])
    |> Ash.Query.sort(closed_at: :desc)
    |> Ash.Query.limit(Keyword.get(opts, :limit, @default_limit))
    |> Ash.read!()
    |> Enum.map(&{&1, resolve(&1)})
  end

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value),
    do: Ash.Query.filter(query, ^Ash.Expr.ref(field) == ^value)

  # ---- workspace and checkout --------------------------------------------------

  defp workspace(%Issue{workspace_id: id}) when is_binary(id) do
    case Ash.get(Workspace, id) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> {:error, :no_workspace}
    end
  end

  defp workspace(_issue), do: {:error, :no_workspace}

  defp repo_path(_workspace, repo) when repo in [nil, ""], do: {:error, :no_repo}

  defp repo_path(workspace, repo) do
    case LocalCompare.repo_path(workspace, repo) do
      nil -> {:error, {:no_repo_path, repo}}
      path -> {:ok, path}
    end
  end

  # ---- the known-good result -------------------------------------------------

  defp known_good(issue, common, target) do
    case target_ref(common, target) do
      nil ->
        {:error, {:unknown_branch, target}}

      ref ->
        found =
          issue
          |> recorded_heads()
          |> Enum.find_value(&from_head(common, ref, &1)) || squash_commit(issue, common, ref)

        if found, do: {:ok, found}, else: {:error, :no_known_good}
    end
  end

  defp target_ref(common, target) do
    Enum.find(["refs/remotes/origin/" <> target, "refs/heads/" <> target], fn ref ->
      Git.rev_parse(common, ref) != nil
    end)
  end

  defp recorded_heads(issue) do
    [
      field(issue.merger_status, "head_sha", :head_sha),
      field(issue.merge_watch, "reviewed_sha", :reviewed_sha),
      issue.last_reviewed_sha,
      field(issue.merge_watch, "local_head_sha", :local_head_sha)
    ]
    |> Enum.filter(&sha?/1)
    |> Enum.uniq()
  end

  # A stored map reads back with string keys; one still in memory may have atoms.
  defp field(%{} = map, key, atom), do: Map.get(map, key) || Map.get(map, atom)
  defp field(_other, _key, _atom), do: nil

  defp sha?(value), do: is_binary(value) and Regex.match?(@sha, value)

  defp from_head(common, ref, head) do
    with sha when is_binary(sha) <- Git.rev_parse(common, head <> "^{commit}"),
         {:ok, base} <- Git.run(["merge-base", ref, sha], git_dir: common),
         true <- base != sha do
      %{base_sha: base, known_good_sha: sha, provenance: :pr_head}
    else
      _ -> nil
    end
  end

  defp squash_commit(%Issue{pr_ref: pr_ref}, common, ref) do
    with n when is_binary(n) <- pr_number(pr_ref),
         {:ok, out} <-
           Git.run(["log", ref, "--format=%H%x09%P%x09%s", "-F", "--grep=(#" <> n <> ")"],
             git_dir: common
           ),
         [[sha, parents, _subject]] <- landed(out, n),
         [parent | _] <- String.split(parents, " ", trim: true) do
      %{base_sha: parent, known_good_sha: sha, provenance: :squash_commit}
    else
      _ -> nil
    end
  end

  defp pr_number(ref) when is_binary(ref) do
    case Regex.run(~r/(\d+)\s*\z/, ref) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp pr_number(_ref), do: nil

  defp landed(out, n) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(&String.split(&1, "\t", parts: 3))
    |> Enum.filter(fn
      [_sha, _parents, subject] ->
        (String.ends_with?(subject, "(#" <> n <> ")") and
           not String.starts_with?(subject, "Revert")) or
          String.starts_with?(subject, "Merge pull request #" <> n <> " ")

      _ ->
        false
    end)
  end

  # ---- the first attempt -------------------------------------------------------

  defp first_attempt(task_id) do
    Run
    |> Ash.Query.filter(
      task_id == ^task_id and kind == :implement and (is_nil(role) or role == "base")
    )
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read()
    |> case do
      {:ok, [run]} -> run
      _ -> nil
    end
  end
end
