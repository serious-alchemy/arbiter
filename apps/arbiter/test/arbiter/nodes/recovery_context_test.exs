defmodule Arbiter.Nodes.RecoveryContextTest do
  @moduledoc "RW12: the checkout context a run's recovery is authorized against."
  use Arbiter.DataCase, async: false

  alias Arbiter.Nodes.Recovery
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.{BranchNamer, Worktree}
  alias Arbiter.Workers.Run

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@e.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "T"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "README.md"), "x\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "README.md"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "i"])
    remote = Path.join(tmp, "remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "remote", "add", "origin", remote])
    {_, 0} = System.cmd("git", ["-C", repo, "push", "-q", "origin", "main"])

    previous = Application.fetch_env(:arbiter, :worktree_root)
    Application.put_env(:arbiter, :worktree_root, Path.join(tmp, "wt"))

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:arbiter, :worktree_root, v)
        :error -> Application.delete_env(:arbiter, :worktree_root)
      end
    end)

    {:ok, ws} = Ash.create(Workspace, %{name: "rec-ctx-ws", prefix: "rc"})
    {:ok, task} = Ash.create(Issue, %{title: "recover me", workspace_id: ws.id})
    %{repo: repo, task: task, ws: ws}
  end

  defp run_for(task, ws, config_dir) do
    Ash.create!(Run, %{
      task_id: task.id,
      base_task_id: task.id,
      repo: "trib/repo",
      workspace_id: ws.id,
      kind: :implement,
      provider: "claude",
      state: :working,
      config_dir: config_dir,
      started_at: DateTime.utc_now()
    })
  end

  test "is the ticket's preserved private clone: path, branch, base and config dir",
       %{repo: repo, task: task, ws: ws} do
    branch = BranchNamer.derive(task)
    {:ok, clone} = Worktree.create(repo, branch, "main", layout: :private_clone)
    run = run_for(task, ws, "/cfg/dir")

    assert {:ok, ctx} = Recovery.context(run)
    assert ctx.home == clone
    assert ctx.branch == branch
    assert ctx.base == "main"
    assert ctx.config_dir == "/cfg/dir"
    assert is_list(ctx.seeded_paths)
  end

  test "no home clone, no context: the run is not asked for", %{task: task, ws: ws} do
    assert {:error, :no_home_clone} = Recovery.context(run_for(task, ws, nil))
  end

  test "a run whose ticket is gone has no context", %{task: task, ws: ws} do
    run = run_for(task, ws, nil)
    assert {:error, _} = Recovery.context(%{run | task_id: "bd-nope"})
  end
end
