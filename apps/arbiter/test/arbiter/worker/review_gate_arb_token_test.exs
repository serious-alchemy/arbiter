defmodule Arbiter.Worker.ReviewGateArbTokenTest do
  @moduledoc """
  bd-asawcq: `/api` needs a bearer token, so a ReviewGate revise-round
  implementer — which works the task exactly like its first-round worker and
  may run `arb ticket update` / `arb message` — gets that task's own
  worker-tier token as `ARB_TOKEN`, never a coordinator one. The reviewer gets
  none: it only reads the diff and prints a verdict.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.MCP.Scope
  alias Arbiter.ProcessTeardown
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate

  @reviewer Path.expand("../../fixtures/review_record_arb_token.sh", __DIR__)
  @implementer Path.expand("../../fixtures/revise_record_arb_token.sh", __DIR__)

  @teardown_ms 15_000

  defp git(args, repo), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg_arb_token-#{System.unique_integer([:positive])}")
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(tmp) end)

    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    {_, 0} = git(["config", "user.email", "repo@example.com"], repo)
    {_, 0} = git(["config", "user.name", "Repo"], repo)
    {_, 0} = git(["config", "commit.gpgsign", "false"], repo)
    File.write!(Path.join(repo, "README.md"), "seed\n")
    {_, 0} = git(["add", "README.md"], repo)
    {_, 0} = git(["commit", "-q", "-m", "seed"], repo)
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, Path.join(tmp, "origin.git")])
    {_, 0} = git(["remote", "add", "origin", Path.join(tmp, "origin.git")], repo)
    {_, 0} = git(["fetch", "-q", "origin"], repo)

    {_, 0} = git(["checkout", "-q", "-b", "feature/rev"], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-arb-token-#{System.unique_integer([:positive])}",
        prefix: "rt",
        config: %{"review" => %{"required" => true}}
      })

    {:ok, task} =
      Ash.create(Issue, %{title: "arb token", workspace_id: ws.id, issue_type: :feature})

    %{repo: repo, ws: ws, task: put_state!(task, :active)}
  end

  test "the implementer pass gets its task's worker token; the reviewer gets none",
       %{repo: repo, ws: ws, task: task} do
    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: "feature/rev",
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_rounds: 2,
          worktree_path: repo,
          review_command: [@reviewer],
          revise_command: [@implementer],
          review_timeout_ms: 10_000
        }
      )

    # Runs before setup's `File.rm_rf!(tmp)` (on_exit is LIFO).
    on_exit(fn -> stop_review_tree(pid, task.id) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})

    implementer_file = Path.join([repo, ".git", "implementer_arb_token"])
    reviewer_file = Path.join([repo, ".git", "reviewer_arb_token"])
    wait_until(fn -> File.exists?(implementer_file) end, 10_000)

    assert File.read!(reviewer_file) == "<unset>"

    assert {:ok,
            %Scope{tier: :worker, task_id: task_id, workspace_id: ws_id, can_dispatch: false}} =
             Scope.from_token(File.read!(implementer_file))

    assert task_id == task.id
    assert ws_id == ws.id
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within timeout")

      true ->
        Process.sleep(25)
        do_wait(fun, deadline)
    end
  end

  # Everything this test starts that writes under tmp: the author worker, the
  # ReviewGate it spawns (git fetch/checkout into tmp/worktrees), and the gate's
  # reviewer/implementer pass workers, each of which owns the port running a
  # fixture script. `Worker.terminate/2` SIGKILLs a pass's OS process tree and
  # confirms it exited, so a pass's :DOWN means its script is gone too.
  #
  # Order matters: the gate first, so it cannot launch another pass; then the
  # author, so nothing can start another gate; only then list the passes.
  defp stop_review_tree(author, task_id) do
    author_ref = Process.monitor(author)

    case Worker.state(author) do
      %{meta: %{review_gate_pid: gate}} when is_pid(gate) ->
        gate_ref = Process.monitor(gate)
        :ok = ProcessTeardown.stop(gate, @teardown_ms)
        assert_receive {:DOWN, ^gate_ref, :process, ^gate, _}, @teardown_ms

      _no_gate_yet ->
        :ok
    end

    :ok = ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, author, @teardown_ms)
    assert_receive {:DOWN, ^author_ref, :process, ^author, _}, @teardown_ms

    prefix = ReviewGate.reviewer_task_id(task_id)

    passes =
      for {key, pass} <- Worker.Registry.all(), String.starts_with?(key, prefix) do
        {Process.monitor(pass), pass}
      end

    for {_ref, pass} <- passes do
      :ok = ProcessTeardown.stop_child(Arbiter.Worker.Supervisor, pass, @teardown_ms)
    end

    for {ref, pass} <- passes do
      assert_receive {:DOWN, ^ref, :process, ^pass, _}, @teardown_ms
    end

    :ok
  end
end
