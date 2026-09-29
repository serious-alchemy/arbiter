defmodule Arbiter.Tasks.Issue.Changes.CleanupWorktreeTest do
  @moduledoc """
  bd-9iv4qd: what the `:close` teardown does with a worktree that still holds
  something — build junk (removed), real work (kept, saved into the task
  notes, warned about) — plus the merged-branch reap, and that the merge and
  upstream-close paths reach the same teardown.

  `TeardownTest` covers the original clean/dirty/inspect/liveness behaviour.
  """

  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog
  import Arbiter.Test.GitFixture, only: [origin_and_clone: 0, git!: 2]

  alias Arbiter.Tasks.Claim
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.PullRequest
  alias Arbiter.Tasks.Verification
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workflows.MergedPRFinalizer

  @stub_name Arbiter.Mergers.Github.HTTP

  setup do
    fx = origin_and_clone()
    root = Path.join(fx.root, "wt")
    File.mkdir_p!(root)

    prior = Application.fetch_env(:arbiter, :worktree_root)
    Application.put_env(:arbiter, :worktree_root, root)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:arbiter, :worktree_root, value)
        :error -> Application.delete_env(:arbiter, :worktree_root)
      end
    end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cw-#{System.unique_integer([:positive])}",
        prefix: "cw#{System.unique_integer([:positive])}",
        config: %{
          "merge" => %{
            "strategy" => "github",
            "config" => %{
              "owner" => "owner",
              "repo" => "repo",
              "credentials_ref" => "env:GITHUB_TOKEN"
            }
          }
        }
      })

    Map.merge(fx, %{ws: ws})
  end

  defp task!(ws, attrs \\ %{}) do
    {:ok, task} =
      Ash.create(
        Issue,
        Map.merge(
          %{title: "cw #{System.unique_integer([:positive])}", workspace_id: ws.id},
          attrs
        )
      )

    {:ok, task} = Ash.update(task, %{status: :in_progress})
    task
  end

  defp worktree!(%{clone: clone}, task) do
    branch = BranchNamer.derive(task)
    {:ok, path} = Worktree.create(clone, branch, "main")
    git!(path, ["config", "user.email", "t@example.com"])
    git!(path, ["config", "user.name", "t"])
    git!(path, ["config", "commit.gpgsign", "false"])
    {branch, path}
  end

  defp commit_in!(path, file, content) do
    File.mkdir_p!(Path.dirname(Path.join(path, file)))
    File.write!(Path.join(path, file), content)
    git!(path, ["add", file])
    git!(path, ["commit", "-q", "-m", "change #{file}"])
    git!(path, ["rev-parse", "HEAD"])
  end

  defp local_branch?(repo, branch) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", repo, "rev-parse", "--verify", "--quiet", "refs/heads/" <> branch])
    )
  end

  defp reload!(task), do: Ash.get!(Issue, task.id)

  describe "build junk is not work" do
    test "a worktree whose only dirt is untracked build artifacts is removed", %{ws: ws} = fx do
      task = task!(ws)
      {_branch, path} = worktree!(fx, task)
      File.mkdir_p!(Path.join(path, "scripts/__pycache__"))
      File.write!(Path.join(path, "scripts/__pycache__/a.cpython-312.pyc"), "bytecode")
      File.mkdir_p!(Path.join(path, "_build/dev"))
      File.write!(Path.join(path, "_build/dev/x"), "x")
      File.write!(Path.join(path, ".mcp.json"), ~s({"token":"t"}))

      {:ok, _closed} = Ash.update(task, %{}, action: :close)

      refute File.dir?(path)
      assert reload!(task).notes in [nil, ""]
    end
  end

  describe "real work is kept and saved to the task notes" do
    test "staged changes: worktree kept, patch in notes, warning names the path",
         %{ws: ws} = fx do
      task = task!(ws)
      {:ok, task} = Ash.update(task, %{notes: "coordinator addendum: keep me"})
      {_branch, path} = worktree!(fx, task)
      File.write!(Path.join(path, "README.md"), "readme\nstaged follow-up\n")
      git!(path, ["add", "README.md"])
      File.write!(Path.join(path, ".mcp.json"), ~s({"token":"never-in-notes"}))

      log =
        capture_log(fn ->
          assert {:ok, closed} = Ash.update(task, %{}, action: :close)
          assert closed.status == :closed
        end)

      assert File.dir?(path)
      assert log =~ path
      assert log =~ task.id

      notes = reload!(task).notes
      assert notes =~ "coordinator addendum: keep me"
      assert notes =~ path
      assert notes =~ "+staged follow-up"
      refute notes =~ "never-in-notes"
    end

    test "an unpushed commit: worktree kept, commit saved as a patch", %{ws: ws} = fx do
      task = task!(ws)
      {_branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/only_here.ex", "unpushed body\n")

      capture_log(fn -> {:ok, _} = Ash.update(task, %{}, action: :close) end)

      assert File.dir?(path)
      notes = reload!(task).notes
      assert notes =~ "+unpushed body"
      assert notes =~ "1 unpushed commit"
    end

    test "a probe failure keeps the worktree without touching the notes", %{ws: ws} = fx do
      task = task!(ws)
      {_branch, path} = worktree!(fx, task)
      # Break the gitdir link: every git probe in the worktree now fails.
      File.write!(Path.join(path, ".git"), "gitdir: /nonexistent/metadata\n")

      capture_log(fn -> {:ok, _} = Ash.update(task, %{}, action: :close) end)

      assert File.dir?(path)
      assert reload!(task).notes in [nil, ""]
    end
  end

  describe "merged-branch reap" do
    test "a merged close deletes the pushed local branch", %{ws: ws, clone: clone} = fx do
      task = task!(ws)
      {branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)

      {:ok, _} = Ash.update(task, %{pr_merged: true}, action: :close)

      refute File.dir?(path)
      refute local_branch?(clone, branch)
    end

    test "a close that is not a merge keeps the local branch", %{ws: ws, clone: clone} = fx do
      task = task!(ws)
      {branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)

      {:ok, _} = Ash.update(task, %{}, action: :close)

      refute File.dir?(path)
      assert local_branch?(clone, branch)
    end

    # Squash merge, then the forge deleted the branch and a prune dropped the
    # remote-tracking ref: the commits are on no remote ref, but they are the
    # head the PR merged, which the ticket recorded.
    test "a squash-merged branch whose remote ref is gone is reaped via the recorded head",
         %{ws: ws, clone: clone} = fx do
      task = task!(ws)
      {branch, path} = worktree!(fx, task)
      head = commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)
      git!(clone, ["push", "-q", "origin", "--delete", branch])
      git!(clone, ["fetch", "-q", "--prune", "origin"])
      :ok = PullRequest.record_merger_status(task.id, %{status: :merged, head_sha: head})

      {:ok, _} = Ash.update(reload!(task), %{pr_merged: true}, action: :close)

      refute File.dir?(path)
      refute local_branch?(clone, branch)
    end

    test "a merged close never deletes a branch holding unpushed commits",
         %{ws: ws, clone: clone} = fx do
      task = task!(ws)
      {branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)
      commit_in!(path, "lib/b.ex", "not pushed\n")

      capture_log(fn -> {:ok, _} = Ash.update(task, %{pr_merged: true}, action: :close) end)

      assert File.dir?(path)
      assert local_branch?(clone, branch)
    end
  end

  describe "every close path runs the same teardown" do
    test "Verification.finalize_merged (Watchdog / MergeQueue / Driver / finalizer funnel)",
         %{ws: ws, clone: clone} = fx do
      task = task!(ws)
      {branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)

      assert {:ok, :closed, _} = Verification.finalize_merged(task, close_upstream: false)

      refute File.dir?(path)
      refute local_branch?(clone, branch)
    end

    test "a verify_after_deploy merge parks and still reaps worktree and branch",
         %{ws: ws, clone: clone} = fx do
      task = task!(ws, %{verify_after_deploy: true})
      {branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)

      assert {:ok, :awaiting_verification, _} =
               Verification.finalize_merged(task, close_upstream: false)

      refute File.dir?(path)
      refute local_branch?(clone, branch)
    end

    test "MergedPRFinalizer closing an externally merged PR", %{ws: ws, clone: clone} = fx do
      task = task!(ws)
      {:ok, task} = Ash.update(task, %{pr_ref: "4242"}, action: :update)
      {branch, path} = worktree!(fx, task)
      commit_in!(path, "lib/a.ex", "x\n")
      {:ok, _} = Worktree.push(path)

      prior = System.get_env("GITHUB_TOKEN")
      System.put_env("GITHUB_TOKEN", "test-token-cw")

      on_exit(fn ->
        if prior,
          do: System.put_env("GITHUB_TOKEN", prior),
          else: System.delete_env("GITHUB_TOKEN")
      end)

      Req.Test.stub(@stub_name, fn conn ->
        case conn.request_path do
          "/repos/owner/repo/pulls/4242" ->
            Req.Test.json(conn, %{
              "number" => 4242,
              "merged" => true,
              "state" => "closed",
              "html_url" => "https://github.com/owner/repo/pull/4242"
            })

          "/repos/owner/repo/pulls/4242/reviews" ->
            Req.Test.json(conn, [])

          _ ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "Not Found"})
        end
      end)

      name = String.to_atom("MergedPRFinalizer_cw_#{System.unique_integer([:positive])}")

      pid =
        start_supervised!(
          {MergedPRFinalizer,
           repo: "owner/repo", workspace_id: ws.id, interval_ms: 60_000, name: name}
        )

      Req.Test.allow(@stub_name, self(), pid)
      :ok = MergedPRFinalizer.tick(name)

      assert reload!(task).status == :closed
      refute File.dir?(path)
      refute local_branch?(clone, branch)
    end

    test "the upstream-close sync (Claim) closing a ticket whose issue closed upstream",
         %{ws: ws} = fx do
      task = task!(ws, %{tracker_type: :github, tracker_ref: "77"})
      {_branch, path} = worktree!(fx, task)

      assert {:ok, [{:closed, _}]} = Claim.apply_plan(ws, [{:close, task.id, "closed upstream"}])

      assert reload!(task).status == :closed
      refute File.dir?(path)
    end
  end
end
