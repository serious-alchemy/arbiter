defmodule Arbiter.ReviewGate.RulingResumeDirectTest do
  @moduledoc """
  A merge-permitting ruling on a `direct`-strategy repo: the same flow as a forge
  PR, with the local merge — a real repository, the real `Arbiter.Mergers.Direct`.
  The merge is guarded on the ruled head exactly as a forge merge is.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, PullRequest, Workspace}

  @branch "feature/ruled"

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    {_, 0} = git(["remote", "add", "origin", bare], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)
    repo
  end

  defp commit_on_branch(repo, file) do
    {_, 0} = git(["checkout", "-q", "-B", @branch], repo)
    File.write!(Path.join(repo, file), "work\n")
    {_, 0} = git(["add", file], repo)
    {_, 0} = git(["commit", "-q", "-m", "work on #{file}"], repo)
    {sha, 0} = git(["rev-parse", "HEAD"], repo)
    String.trim(sha)
  end

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "rrd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"rrd/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rrd-#{System.unique_integer([:positive])}",
        prefix: "rd",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} = Ash.create(Issue, %{title: "ruled", workspace_id: ws.id, issue_type: :feature})
    task = put_state!(task, :active)

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task.id,
        round: 1,
        role: :review,
        verdict: :request_changes,
        findings: "[high] needs a guard",
        finding_count: 1
      })

    head = commit_on_branch(repo, "feature.txt")

    :ok =
      PullRequest.record_review_gate(task.id, %{
        branch: @branch,
        worktree_path: repo,
        repo_path: repo,
        repo: "rrd/repo",
        target_branch: "main",
        verdict: "request_changes"
      })

    Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))
    %{repo: repo, task: task, ws: ws, head: head}
  end

  defp rule(task, decision, extra \\ %{}) do
    {:ok, resolution} =
      Resolutions.record(
        Map.merge(%{task_id: task.id, decision: decision, reasoning: "ship it"}, extra)
      )

    resolution
  end

  # The local merge lands inside the hand-off; the ticket's Watchdog finalizes it
  # (closes) on its first poll.
  defp assert_closed(task_id, tries \\ 200) do
    cond do
      Ash.get!(Issue, task_id).state == :closed -> :ok
      tries == 0 -> flunk("ticket #{task_id} never closed")
      true -> Process.sleep(15) && assert_closed(task_id, tries - 1)
    end
  end

  for decision <- [:accept_as_is, :amend] do
    test "#{decision}: merges the ruled head locally and closes the ticket",
         %{repo: repo, task: task, head: head} do
      resolution = rule(task, unquote(decision))

      assert resolution.head_sha == head, "the ruling is stamped with the worktree's head"
      assert merge_commit_count(repo) == 1

      assert_receive {:event, %{topic: "review_gate", ruling_event: "resumed"}}
      assert_receive {:event, %{topic: "review_gate", ruling_event: "merged"} = merged}
      assert merged.task_id == task.id
      assert_closed(task.id)
    end
  end

  test "a branch that moved past the ruled head is not merged: both SHAs are named",
       %{repo: repo, task: task, head: head, ws: ws} do
    newer = commit_on_branch(repo, "second.txt")
    refute newer == head

    rule(task, :accept_as_is, %{head_sha: head})

    assert Ash.get!(Issue, task.id).state == :active
    assert merge_commit_count(repo) == 0

    assert_receive {:event, %{topic: "review_gate", ruling_event: "head_changed"} = event}
    assert event.message =~ "#{head} -> #{newer}"

    assert Enum.any?(
             Arbiter.Messages.Message.inbox(Arbiter.Messages.Message.coordinator_ref(),
               workspace_id: ws.id
             ),
             &(&1.task_ref == task.id and &1.subject =~ "#{head} -> #{newer}")
           )
  end
end
