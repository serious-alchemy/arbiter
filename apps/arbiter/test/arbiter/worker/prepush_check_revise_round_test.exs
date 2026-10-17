defmodule Arbiter.Worker.PrepushCheckReviseRoundTest do
  @moduledoc """
  A ReviewGate fix round (`<id>#review#impl<N>`) is a worker with no `:branch`
  of its own (the gate pushes), so it used to skip the pre-push recipe the main
  run and CI fix passes honour. These tests pin the gate on that path: a red
  recipe parks the round (nothing completes, so the ReviewGate never pushes), a
  green one completes it, and the per-step results are recorded on the run.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.PrepushSteps

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "prepush-revise-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)

    remote = Path.join(tmp, "repo-remote.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", remote])
    {_, 0} = git(["remote", "add", "origin", remote], repo)
    {_, 0} = git(["push", "-q", "origin", "main"], repo)

    put_app_env(:arbiter, :worktree_root,Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"gate/repo" => repo})
    on_exit(fn -> File.rm_rf(tmp) end)

    %{repo: repo}
  end

  defp workspace(command) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rv-ws-#{System.unique_integer([:positive])}",
        prefix: "rv",
        config: %{"worker" => %{"prepush_check" => command}}
      })

    ws
  end

  defp fix_round_worktree(repo, branch) do
    {:ok, path} = Worktree.create(repo, branch, "main")
    {_, 0} = git(["config", "user.email", "wt@example.com"], path)
    {_, 0} = git(["config", "user.name", "WT"], path)
    {_, 0} = git(["config", "commit.gpgsign", "false"], path)
    {head, 0} = git(["rev-parse", "HEAD"], path)
    base = String.trim(head)
    File.write!(Path.join(path, "fix.txt"), "fix\n")
    {_, 0} = git(["add", "fix.txt"], path)
    {_, 0} = git(["commit", "-q", "-m", "fix round"], path)
    {path, base}
  end

  defp start_round(ws, repo, path, base, branch, extra \\ %{}) do
    id = "rv-#{System.unique_integer([:positive])}#review#impl1"

    meta =
      Map.merge(
        %{
          role: :implementer,
          revises: "rv-base",
          revise_worktree: path,
          revise_branch: branch,
          revise_base_head: base,
          revise_workspace_id: ws.id,
          target_branch: "main",
          commit_nudge_cap: 0
        },
        extra
      )

    {:ok, pid} = Worker.start(task_id: id, repo: "gate/repo", workspace_id: nil, meta: meta)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :revising)
    _ = repo
    pid
  end

  defp done(pid), do: send(pid, {:__claude_session_done__, "arb " <> "done"})

  defp wait_until(fun, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: :ok, else: (Process.sleep(15) && :retry)
    end)
    |> Enum.find(fn r -> r == :ok or System.monotonic_time(:millisecond) > deadline end)
    |> case do
      :ok -> :ok
      _ -> flunk("condition not met within timeout")
    end
  end

  test "a red recipe fails the round and records the step results", %{repo: repo} do
    ws = workspace("echo 'credo: alias warning'; exit 2")
    {path, base} = fix_round_worktree(repo, "bd-rv/red")
    pid = start_round(ws, repo, path, base, "bd-rv/red", %{prepush_nudge_cap: 0})

    done(pid)
    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end)

    snap = Worker.state(pid)
    assert snap.meta.commit_gate_reason == :prepush_failed
    assert [%{status: :failed, output: out} | _] = PrepushSteps.list(snap.run_id)
    assert out =~ "alias warning"
  end

  test "a green recipe lets the round complete", %{repo: repo} do
    ws = workspace("echo ok")
    {path, base} = fix_round_worktree(repo, "bd-rv/green")
    pid = start_round(ws, repo, path, base, "bd-rv/green")

    done(pid)
    wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)

    assert [%{status: :passed} | _] = PrepushSteps.list(Worker.state(pid).run_id)
  end

  test "a round that made no new commit does not run the recipe", %{repo: repo} do
    ws = workspace("echo 'should not run'; exit 3")
    {path, _base} = fix_round_worktree(repo, "bd-rv/nochange")
    {head, 0} = git(["rev-parse", "HEAD"], path)
    pid = start_round(ws, repo, path, String.trim(head), "bd-rv/nochange")

    done(pid)
    wait_until(fn -> match?(%{state: :finished, outcome: :succeeded}, Worker.state(pid)) end)
    assert PrepushSteps.list(Worker.state(pid).run_id) == []
  end
end
