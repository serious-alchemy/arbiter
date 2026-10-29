defmodule Arbiter.Worker.ReviewGateRepeatUnmetTest do
  @moduledoc """
  bd-hrhkzj: a criterion `[NOT MET]` on two consecutive gate rounds parks for
  the coordinator (no further implementer round); different unmet criteria on
  consecutive rounds still get a normal fix round.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.RepeatUnmetCriterion

  @revise_commit Path.expand("../../fixtures/revise_commit.sh", __DIR__)

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

  defp seed_feature_branch(repo, branch) do
    {_, 0} = git(["checkout", "-q", "-b", branch], repo)
    File.write!(Path.join(repo, "feature.txt"), "worker work\n")
    {_, 0} = git(["add", "feature.txt"], repo)
    {_, 0} = git(["commit", "-q", "-m", "feature work"], repo)
    {_, 0} = git(["checkout", "-q", "main"], repo)
    :ok
  end

  defp wait_until(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met within timeout")
      true -> Process.sleep(15) |> then(fn _ -> do_wait(fun, deadline) end)
    end
  end

  # A reviewer that prints `rounds[n-1]` on its nth invocation (last one repeats).
  defp sequenced_reviewer(rounds) do
    dir = Path.join(System.tmp_dir!(), "rg_repeat-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    rounds
    |> Enum.with_index(1)
    |> Enum.each(fn {text, n} -> File.write!(Path.join(dir, "r#{n}.md"), text) end)

    script = Path.join(dir, "review.sh")

    File.write!(script, """
    #!/bin/sh
    n=0
    [ -f "#{dir}/count" ] && n="$(cat "#{dir}/count")"
    n=$((n + 1))
    echo "$n" > "#{dir}/count"
    [ -f "#{dir}/r$n.md" ] || n=#{length(rounds)}
    cat "#{dir}/r$n.md"
    exit 0
    """)

    File.chmod!(script, 0o755)
    script
  end

  defp run_gate(repo, ws, reviewer, rounds) do
    {:ok, task} =
      Ash.create(Issue, %{title: "repeat task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)
    branch = "feature/repeat-#{System.unique_integer([:positive])}"
    :ok = seed_feature_branch(repo, branch)

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          repo_path: repo,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_rounds: rounds,
          worktree_path: repo,
          review_command: [reviewer],
          revise_command: [@revise_commit],
          review_timeout_ms: 5_000
        }
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    wait_until(fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end, 15_000)
    Worker.state(pid).meta
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg_repeat_repo-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)
    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "repeat-ws-#{System.unique_integer([:positive])}",
        prefix: "rp",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws}
  end

  defp findings(criteria_lines) do
    "VERDICT: REQUEST_CHANGES\nCRITERIA:\n" <>
      Enum.join(criteria_lines, "\n") <>
      "\nFindings:\n1. **[MEDIUM] A criterion is unmet.** Location: `feature.txt:1`.\n   - See the criteria above.\n   - **Suggested fix:** address the criterion.\nVERIFICATION: FULL\n"
  end

  test "the same criterion unmet twice parks without a second implementer round",
       %{repo: repo, ws: ws} do
    reviewer =
      sequenced_reviewer([
        findings(["- [NOT MET] 50/50 local runs pass — no evidence in round one"]),
        findings(["1. [NOT MET]  50/50 LOCAL runs  pass — still no evidence in round two"])
      ])

    meta = run_gate(repo, ws, reviewer, 4)
    assert RepeatUnmetCriterion.escalation?(meta.review_gate_findings)
    assert meta.review_gate_findings =~ "50/50 local runs pass"
    assert meta.review_gate_findings =~ "no evidence in round one"
    assert meta.review_gate_findings =~ "still no evidence in round two"
    assert meta.review_gate_findings =~ "FIXED: anchored the match"

    # Exactly the one implementer round between the two reviews ran.
    assert File.read!(Path.join([repo, ".git", "revise_commit_pass"])) |> String.trim() == "1"
  end

  test "different unmet criteria on consecutive rounds still get a fix round",
       %{repo: repo, ws: ws} do
    reviewer =
      sequenced_reviewer([
        findings(["- [NOT MET] criterion alpha — a"]),
        findings(["- [NOT MET] criterion beta — b"]),
        findings(["- [NOT MET] criterion gamma — c"])
      ])

    meta = run_gate(repo, ws, reviewer, 3)
    refute RepeatUnmetCriterion.escalation?(meta.review_gate_findings)
    assert File.read!(Path.join([repo, ".git", "revise_commit_pass"])) |> String.trim() == "2"
  end
end
