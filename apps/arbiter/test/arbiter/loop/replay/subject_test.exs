defmodule Arbiter.Loop.Replay.SubjectTest do
  @moduledoc """
  bd-c7lx65 (R15, `docs/design/paced-quota-routing-signals.md` §7.2): which
  closed tasks a replay may re-run, and where its known-good result and base
  commit are. Closed tasks are the ones that got solved; a task with
  permissions is coupled to external state and is never replayed. Neither the
  base nor the merge commit is recorded, so they are worked out from git: the
  PR head the forge last reported and where it left the target branch, or the
  squash commit the PR landed as.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.LifecycleFixtures
  alias Arbiter.Loop.Replay.Subject
  alias Arbiter.Repo
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.GitFixture

  import GitFixture, only: [git!: 2, commit!: 3]

  # The forge (`origin`) has `main` at `base`, a PR branch whose head is `head`,
  # and, after the base, an unrelated commit and the PR squash-merged as
  # "Add the feature (#7)". The checkout has fetched all of it.
  setup do
    %{origin: origin, clone: repo} =
      GitFixture.origin_and_clone(%{"README.md" => "readme\n", "lib/app.ex" => "app\n"})

    base = git!(origin, ["rev-parse", "HEAD"])
    git!(origin, ["checkout", "-q", "-b", "feature"])
    head = commit!(origin, %{"lib/feature.ex" => "feature\n"}, "wip: the feature")
    git!(origin, ["checkout", "-q", "main"])
    commit!(origin, %{"lib/other.ex" => "other\n"}, "Something else (#6)")
    squash = commit!(origin, %{"lib/feature.ex" => "feature\n"}, "Add the feature (#7)")
    git!(repo, ["fetch", "-q", "origin"])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "replay-subject-#{System.unique_integer([:positive])}",
        config: %{"repo_paths" => %{"app" => repo}}
      })

    %{repo: repo, base: base, head: head, squash: squash, ws: ws}
  end

  defp ticket!(ctx, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(
          %{
            title: "Add the feature",
            description: "Make the feature exist.",
            acceptance: "- lib/feature.ex exists",
            difficulty: 2,
            workspace_id: ctx.ws.id,
            repo: "app"
          },
          attrs
        )
      )

    issue
  end

  defp closed!(ctx, attrs \\ %{}),
    do: ctx |> ticket!(attrs) |> LifecycleFixtures.put_state!(:closed)

  defp set!(issue, column, value) do
    value = if is_map(value) or is_list(value), do: Jason.encode!(value), else: value
    Repo.query!("UPDATE issues SET #{column} = ?2 WHERE id = ?1", [issue.id, value])
    issue
  end

  defp first_attempt!(issue, ws, attrs) do
    Repo.query!(
      """
      INSERT INTO worker_runs (id, task_id, base_task_id, workspace_id, repo, kind, role, model,
                               provider, difficulty_at_dispatch, state, outcome,
                               started_at, inserted_at, updated_at)
      VALUES (?1, ?2, ?2, ?3, 'app', 'implement', 'base', ?4, ?5, ?6, 'finished', 'succeeded',
              ?7, ?7, ?7)
      """,
      [
        Ecto.UUID.generate(),
        issue.id,
        ws.id,
        attrs.model,
        attrs.provider,
        attrs.difficulty,
        DateTime.to_iso8601(attrs.started_at)
      ]
    )
  end

  describe "resolve/1: provenance" do
    test "the PR head the forge last reported, and where it left the target branch", ctx do
      issue =
        ctx |> closed!() |> set!("merger_status", %{"head_sha" => ctx.head, "status" => "merged"})

      assert {:ok, subject} = Subject.resolve(issue.id)

      assert subject.known_good_sha == ctx.head
      assert subject.base_sha == ctx.base
      assert subject.provenance == :pr_head
      assert subject.repo == "app"
      assert subject.repo_path == ctx.repo
      assert subject.target_branch == "main"
      assert subject.issue.id == issue.id
      assert subject.workspace.id == ctx.ws.id
    end

    test "the head the merge lane recorded when the forge reported none", ctx do
      issue = ctx |> closed!() |> set!("merge_watch", %{"local_head_sha" => ctx.head})

      assert {:ok, %{known_good_sha: head, base_sha: base}} = Subject.resolve(issue.id)
      assert {head, base} == {ctx.head, ctx.base}
    end

    test "the squash commit the PR landed as, when its head is gone", ctx do
      gone = String.duplicate("a", 40)

      issue =
        ctx
        |> closed!()
        |> set!("merger_status", %{"head_sha" => gone})
        |> set!("pr_ref", "https://example.test/pull/7")

      assert {:ok, subject} = Subject.resolve(issue.id)

      assert subject.known_good_sha == ctx.squash
      assert subject.base_sha == git!(ctx.repo, ["rev-parse", ctx.squash <> "^"])
      assert subject.provenance == :squash_commit
    end

    test "a head that is not a sha is never handed to git", ctx do
      issue = ctx |> closed!() |> set!("merger_status", %{"head_sha" => "--upload-pack=touch x"})

      assert {:error, :no_known_good} = Subject.resolve(issue.id)
    end

    test "no recorded head and no PR: nothing to score against", ctx do
      assert {:error, :no_known_good} = Subject.resolve(closed!(ctx).id)
    end

    test "the cell coordinates are the first attempt's: difficulty at dispatch, and its model",
         ctx do
      issue =
        ctx
        |> closed!(%{difficulty: 3})
        |> set!("merger_status", %{"head_sha" => ctx.head})

      first_attempt!(issue, ctx.ws, %{
        model: "claude-sonnet-5-5",
        provider: "claude",
        difficulty: 2,
        started_at: ~U[2026-10-01 10:00:00Z]
      })

      first_attempt!(issue, ctx.ws, %{
        model: "claude-opus-5-5",
        provider: "claude",
        difficulty: 3,
        started_at: ~U[2026-10-01 12:00:00Z]
      })

      assert {:ok, subject} = Subject.resolve(issue.id)
      assert subject.difficulty == 2
      assert subject.issue_type == "feature"
      assert subject.live_model == "claude-sonnet-5-5"
      assert subject.live_provider == "claude"
    end

    test "with no attempt on record, the ticket's own difficulty", ctx do
      issue = ctx |> closed!(%{difficulty: 3}) |> set!("merger_status", %{"head_sha" => ctx.head})

      assert {:ok, %{difficulty: 3, live_model: nil}} = Subject.resolve(issue.id)
    end
  end

  describe "resolve/1: eligibility" do
    test "only a closed ticket", ctx do
      issue = ctx |> ticket!() |> LifecycleFixtures.put_state!(:active)
      assert {:error, {:not_closed, :active}} = Subject.resolve(issue.id)
    end

    test "only one that closed completed: the others have no known-good result", ctx do
      issue = ctx |> closed!() |> set!("close_reason", "wont_do")
      assert {:error, {:not_completed, :wont_do}} = Subject.resolve(issue.id)
    end

    test "never one with permissions: it is coupled to external state", ctx do
      issue =
        ctx
        |> closed!()
        |> set!("merger_status", %{"head_sha" => ctx.head})
        |> set!("permissions", ["prod_read"])

      assert {:error, {:permissions, ["prod_read"]}} = Subject.resolve(issue.id)
    end

    test "never a review-only ticket: it changed no code", ctx do
      issue = ctx |> closed!() |> set!("review_only", 1)
      assert {:error, :review_only} = Subject.resolve(issue.id)
    end

    test "only one whose repo has a local checkout", ctx do
      # A repo the workspace no longer maps (the create action refuses an
      # unmapped one, so the row is edited after the fact).
      issue =
        ctx
        |> closed!()
        |> set!("merger_status", %{"head_sha" => ctx.head})
        |> set!("repo", "elsewhere")

      assert {:error, {:no_repo_path, "elsewhere"}} = Subject.resolve(issue.id)
    end

    test "an unknown ticket", _ctx do
      assert {:error, :not_found} = Subject.resolve("bd-nosuch")
    end
  end

  describe "candidates/1" do
    test "closed tickets in the workspace, newest close first, each with its resolution", ctx do
      older =
        ctx |> closed!(%{title: "older"}) |> set!("merger_status", %{"head_sha" => ctx.head})

      set!(older, "closed_at", "2026-10-01T10:00:00Z")

      newer = ctx |> closed!(%{title: "newer"}) |> set!("permissions", ["tracker_write"])
      set!(newer, "closed_at", "2026-10-02T10:00:00Z")

      _open = ctx |> ticket!(%{title: "open"}) |> LifecycleFixtures.put_state!(:active)

      listed =
        for {issue, resolution} <- Subject.candidates(workspace_id: ctx.ws.id),
            do: {issue.id, resolution}

      assert [{newer_id, {:error, {:permissions, ["tracker_write"]}}}, {older_id, {:ok, subject}}] =
               listed

      assert {newer_id, older_id} == {newer.id, older.id}
      assert subject.known_good_sha == ctx.head
    end

    test "filters by difficulty and type, and stops at the limit", ctx do
      for d <- [1, 2, 2], do: closed!(ctx, %{difficulty: d})

      assert length(Subject.candidates(workspace_id: ctx.ws.id, difficulty: 2)) == 2
      assert Subject.candidates(workspace_id: ctx.ws.id, issue_type: "bug") == []
      assert length(Subject.candidates(workspace_id: ctx.ws.id, limit: 1)) == 1
    end
  end
end
