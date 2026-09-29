defmodule Arbiter.Worker.ReviewGateAgyDenialTest do
  @moduledoc """
  bd-cwe9n2: a single command the permission policy refuses ends a headless agy
  turn (exit 0, `result.denied_actions`). On the review path that used to leave
  the ReviewGate with no VERDICT and an `inconclusive` park. The gate now waits
  for the reviewer Worker to resume the SAME agy conversation, and, when no
  verdict ever arrives, names the denied command in its escalation.

  Drives the real adapter spawn path with `agy` and `claude` stubbed onto PATH;
  the agy stub replays the captured soft-deny stream
  (`test/fixtures/agy_strict_denial_turn_end.jsonl`).
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  @turn_end Path.expand("../../fixtures/agy_strict_denial_turn_end.jsonl", __DIR__)

  # First call: the captured soft-deny turn. A `--conversation` resume: a
  # verdict (when `resume_verdict?`), else the same denial again.
  defp stub_agy(dir, log, resume_verdict?) do
    resumed =
      if resume_verdict?,
        do: "echo 'VERDICT: APPROVE'; echo 'looks consistent'; echo 'arb done'",
        else: "cat '#{@turn_end}'"

    write_stub(dir, "agy", """
    case " $* " in
      *" --conversation "*)
        echo resume >> #{log}
        #{resumed}
        exit 0 ;;
      *)
        echo first >> #{log}
        cat '#{@turn_end}'
        exit 0 ;;
    esac
    """)
  end

  defp stub_claude_approve(dir, log) do
    write_stub(dir, "claude", """
    echo claude >> #{log}
    echo "VERDICT: APPROVE"
    echo "looks consistent"
    echo "arb done"
    exit 0
    """)
  end

  defp write_stub(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp prepend_path(dir) do
    old = System.get_env("PATH") || ""
    System.put_env("PATH", "#{dir}:#{old}")
    on_exit(fn -> System.put_env("PATH", old) end)
    :ok
  end

  defp calls(log) do
    case File.read(log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  # ---- repo / workspace scaffolding ---------------------------------------

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

  defp merge_commit_count(repo) do
    {out, 0} = git(["rev-list", "--merges", "--count", "main"], repo)
    out |> String.trim() |> String.to_integer()
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
        Process.sleep(20)
        do_wait(fun, deadline)
    end
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-deny-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    stub_dir = Path.join(tmp, "stub-bin")
    File.mkdir_p!(stub_dir)
    %{repo: repo, stub_dir: stub_dir, log: Path.join(tmp, "calls.txt")}
  end

  defp workspace(type) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "trib-deny-ws-#{System.unique_integer([:positive])}",
        prefix: "td",
        config: %{
          "review" => %{"required" => true, "rounds" => 1},
          "review_agent" => %{"type" => type}
        }
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{title: "denial task", workspace_id: ws.id, issue_type: :feature})

    put_state!(task, :active)
  end

  defp run_gate(task, repo, branch) do
    :ok = seed_feature_branch(repo, branch)

    meta = %{
      branch: branch,
      repo_path: repo,
      target_branch: "main",
      merge_title: "Merge #{task.id}",
      review_required: true,
      review_rounds: 1,
      worktree_path: repo,
      review_verdict_retries: 0,
      review_timeout_ms: 30_000
    }

    {:ok, pid} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: task.workspace_id,
        meta: meta
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    :ok = Worker.advance(pid, :claude)
    send(pid, {:__claude_session_done__, "arb done"})
    pid
  end

  defp escalation_for(task_id, ws) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task_id))
  end

  test "one denied command does not end the review: the conversation resumes and a verdict merges",
       %{repo: repo, stub_dir: stub_dir, log: log} do
    stub_agy(stub_dir, log, true)
    prepend_path(stub_dir)

    task = new_task(workspace(["gemini"]))
    run_gate(task, repo, "feature/deny-resume")

    wait_until(fn -> merge_commit_count(repo) == 1 end, 15_000)
    assert calls(log) == ["first", "resume"]
  end

  test "when the resumed conversation is denied too, the escalation names the denied command",
       %{repo: repo, stub_dir: stub_dir, log: log} do
    stub_agy(stub_dir, log, false)
    prepend_path(stub_dir)

    ws = workspace(["gemini"])
    task = new_task(ws)
    pid = run_gate(task, repo, "feature/deny-exhausted")

    wait_until(
      fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end,
      30_000
    )

    assert merge_commit_count(repo) == 0
    assert Worker.state(pid).meta.failure_reason == :review_gate_inconclusive
    assert [escalation] = escalation_for(task.id, ws)
    assert escalation.body =~ "`whoami`"
    assert escalation.body =~ "Denied by the permission policy"
  end

  test "the Claude review path is unchanged", %{repo: repo, stub_dir: stub_dir, log: log} do
    stub_claude_approve(stub_dir, log)
    prepend_path(stub_dir)

    task = new_task(workspace(["claude"]))
    run_gate(task, repo, "feature/deny-claude")

    wait_until(fn -> merge_commit_count(repo) == 1 end, 15_000)
    assert calls(log) == ["claude"]
  end
end
