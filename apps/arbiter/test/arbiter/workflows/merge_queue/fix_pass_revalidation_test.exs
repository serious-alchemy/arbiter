defmodule Arbiter.Workflows.MergeQueue.FixPassRevalidationTest do
  @moduledoc """
  bd-4l7l2n: a fix pass queued for a red CI is re-checked when it finally
  starts. A ticket that merged and closed meanwhile, a PR that merged or
  closed, or a head whose CI went green must not spawn a pass on a scarce slot.
  """

  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Test.StubResumeDeferrer
  alias Arbiter.Worker
  alias Arbiter.Worker.BranchNamer
  alias Arbiter.Workflows.MergeQueue.FixPassDispatcher

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    tmp = Path.join(System.tmp_dir!(), "fpr-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)

    for args <- [
          ["init", "-q", "-b", "main", repo],
          ["-C", repo, "config", "user.email", "t@e.com"],
          ["-C", repo, "config", "user.name", "T"],
          ["-C", repo, "config", "commit.gpgsign", "false"]
        ] do
      {_, 0} = System.cmd("git", args)
    end

    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "fpr-ws-#{System.unique_integer([:positive])}",
        prefix: "fpr#{System.unique_integer([:positive])}"
      })

    {:ok, issue} =
      Ash.create(Issue, %{title: "has a PR", workspace_id: ws.id, acceptance: "- works"})

    {_, 0} = System.cmd("git", ["-C", repo, "branch", BranchNamer.derive(issue)])

    merging =
      issue
      |> Ash.update!(%{}, action: :promote)
      |> Ash.update!(%{}, action: :start)
      |> Ash.update!(%{pr_ref: "#77"}, action: :open_pr)

    {:ok, ws: ws, repo: repo, issue: merging}
  end

  defp args(ctx, status) do
    %{
      task_id: ctx.issue.id,
      workspace_id: ctx.ws.id,
      repo_path: ctx.repo,
      repo: "test/repo",
      checks: [],
      start_claude: false,
      slot_admitted: true,
      pr_status: fn -> status end
    }
  end

  defp refute_started(ctx, status, error) do
    log =
      capture_log(fn ->
        assert {:error, ^error} = FixPassDispatcher.dispatch(args(ctx, status))
      end)

    assert log =~ "fix pass for #{ctx.issue.id} not started"
    assert Worker.whereis(ctx.issue.id) == nil
  end

  test "a genuine pass (ticket open, PR open, head still red) still dispatches", ctx do
    assert {:ok, %{worker_pid: pid}} =
             FixPassDispatcher.dispatch(
               args(ctx, {:ok, %{status: :open, pipeline: :failed, head_sha: "abc"}})
             )

    on_exit(fn -> stop_quietly(pid) end)
  end

  test "a pass is not started once the ticket is closed", ctx do
    Ash.update!(ctx.issue, %{}, action: :close)
    refute_started(ctx, {:ok, %{status: :open, pipeline: :failed}}, :task_closed)
  end

  test "a pass is not started once the ticket is verifying", ctx do
    Ash.update!(ctx.issue, %{}, action: :await_verification)
    refute_started(ctx, {:ok, %{status: :open, pipeline: :failed}}, :task_closed)
  end

  test "a pass is not started once the PR merged", ctx do
    refute_started(ctx, {:ok, %{status: :merged, pipeline: :failed}}, :pr_not_open)
  end

  test "a pass is not started once the PR closed", ctx do
    refute_started(ctx, {:ok, %{status: :closed, pipeline: :failed}}, :pr_not_open)
  end

  test "a pass is not started once the head's CI is green", ctx do
    refute_started(ctx, {:ok, %{status: :open, pipeline: :passed}}, :ci_not_failing)
  end

  test "an unreadable PR does not block a pass", ctx do
    assert {:ok, %{worker_pid: pid}} = FixPassDispatcher.dispatch(args(ctx, {:error, :boom}))
    on_exit(fn -> stop_quietly(pid) end)
  end

  test "the forge is not consulted on a first (non-replay) dispatch", ctx do
    first = ctx |> args({:error, :unused}) |> Map.delete(:slot_admitted)
    first = Map.put(first, :pr_status, fn -> flunk("forge read on first dispatch") end)
    assert {:ok, %{worker_pid: pid}} = FixPassDispatcher.dispatch(first)
    on_exit(fn -> stop_quietly(pid) end)
  end

  describe "cancel on close" do
    setup do
      StubResumeDeferrer.reset()
    end

    test "closing a ticket cancels its queued pass", ctx do
      Ash.update!(ctx.issue, %{}, action: :close)
      assert ctx.issue.id in StubResumeDeferrer.cancellations()
    end

    test "a ticket parking at verifying cancels its queued pass", ctx do
      Ash.update!(ctx.issue, %{}, action: :await_verification)
      assert ctx.issue.id in StubResumeDeferrer.cancellations()
    end
  end

  defp stop_quietly(pid),
    do: Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pid)
end
