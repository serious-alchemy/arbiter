defmodule Arbiter.Worker.ReviewGateSpawnFailureTest do
  @moduledoc """
  bd-7ud35b: a reviewer process that dies at startup (agy exiting 1 with
  "invalid model selection" because a tier model no longer exists) never
  reviewed anything. The ReviewGate must classify that as a reviewer SPAWN
  failure, not a `review_gate_inconclusive` round: it spends no round and no
  verdict re-prompt, the review is retried on a different provider, and the
  coordinator is paged only once every eligible provider has failed to spawn.

  Like `ReviewGateProviderRotationTest`, these drive the real adapter spawn
  path with `agy` and `claude` stubbed onto `PATH`.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  # ---- stubs ---------------------------------------------------------------

  # agy's startup crash for a retired tier model: one stderr line, exit 1, no
  # assistant turn.
  defp stub_invalid_model(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "Error: invalid model selection: gemini-3.1-pro-high" >&2
    exit 1
    """)
  end

  # The same kind of startup crash from an argv error.
  defp stub_bad_argv(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "error: unknown option '--bogus-flag'" >&2
    exit 1
    """)
  end

  defp stub_approve(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "reviewing the diff..."
    echo "VERDICT: APPROVE"
    echo "findings: the change looks consistent with the acceptance criteria"
    echo "arb done"
    exit 0
    """)
  end

  # A reviewer that runs to completion but never states a verdict.
  defp stub_silent_review(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    echo "I looked at the diff and have thoughts."
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
    tmp = Path.join(System.tmp_dir!(), "rg-spawnfail-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn -> File.rm_rf!(tmp) end)

    stub_dir = Path.join(tmp, "stub-bin")
    File.mkdir_p!(stub_dir)
    log = Path.join(tmp, "reviewer-calls.txt")

    %{repo: repo, tmp: tmp, stub_dir: stub_dir, log: log}
  end

  defp workspace(type) do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "trib-spawnfail-ws-#{System.unique_integer([:positive])}",
        prefix: "tsf",
        config: %{
          "review" => %{"required" => true, "rounds" => 1},
          "review_agent" => %{"type" => type}
        }
      })

    ws
  end

  defp new_task(ws) do
    {:ok, task} =
      Ash.create(Issue, %{
        title: "review_gate spawn failure task",
        workspace_id: ws.id,
        issue_type: :feature
      })

    put_state!(task, :active)
  end

  # `review_verdict_retries: 1` leaves a verdict re-prompt budget on the table,
  # so a spawn failure that wrongly fell into the re-prompt path would show up
  # as a second call of the same stub.
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
      review_verdict_retries: 1,
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

  defp finished_failed?(pid), do: match?(%{state: :finished, outcome: :failed}, Worker.state(pid))

  defp review_rounds(task_id) do
    require Ash.Query

    Round
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  defp escalation_for(task_id, ws) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task_id))
  end

  # ---- AC1 / AC2 -----------------------------------------------------------

  describe "a reviewer that dies at startup is a spawn failure, not an inconclusive round" do
    test "the review is retried on the next provider, which is not the one that just failed",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_invalid_model(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      run_gate(task, repo, "feature/spawn-rotate")

      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      # AC2: agy ran once (no verdict re-prompt on the broken model), then the
      # other provider reviewed.
      assert calls(log) == ["agy", "claude"]

      # AC1: the crash is not a round. Only the real review is on record, and
      # it is the first round.
      assert [%Round{verdict: :approve, reviewer_provider: "claude", round: 1}] =
               review_rounds(task.id)

      # The failed spawn paged nobody (the unrelated coverage-row escalation a
      # fixture-repo merge raises is not a reviewer escalation).
      refute Enum.any?(escalation_for(task.id, ws), &(&1.body =~ "failed to spawn"))
    end

    test "the order of the pool does not matter: a failing second entry rotates back to the first",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_bad_argv(stub_dir, "claude", log)
      stub_approve(stub_dir, "agy", log)
      prepend_path(stub_dir)

      ws = workspace(["claude", "gemini"])
      task = new_task(ws)

      run_gate(task, repo, "feature/spawn-rotate-back")

      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["claude", "agy"]
      assert [%Round{verdict: :approve, reviewer_provider: "gemini"}] = review_rounds(task.id)
    end
  end

  # ---- AC3 -----------------------------------------------------------------

  describe "every eligible provider failing to spawn" do
    test "escalates once, naming each provider/model and its error, and never says inconclusive",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_invalid_model(stub_dir, "agy", log)
      stub_bad_argv(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/spawn-exhausted")

      wait_until(fn -> finished_failed?(pid) end, 12_000)

      assert calls(log) == ["agy", "claude"], "each provider is tried exactly once"
      assert merge_commit_count(repo) == 0

      assert [escalation] = escalation_for(task.id, ws)
      assert escalation.body =~ "reviewer failed to spawn: gemini/"
      assert escalation.body =~ "invalid model selection"
      assert escalation.body =~ "reviewer failed to spawn: claude/"
      assert escalation.body =~ "unknown option"

      refute String.downcase(escalation.subject <> escalation.body) =~ "inconclusive"
      refute escalation.body =~ "no parseable VERDICT line"

      assert Ash.get!(Issue, task.id).attention_cause == :reviewer_failed

      # Neither failed spawn is a review round.
      assert review_rounds(task.id) == []
    end

    test "a single-provider pool escalates immediately with the spawn error",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_invalid_model(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace("gemini")
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/spawn-single")

      wait_until(fn -> finished_failed?(pid) end, 12_000)

      assert calls(log) == ["agy"]
      assert merge_commit_count(repo) == 0

      assert [escalation] = escalation_for(task.id, ws)
      assert escalation.body =~ "reviewer failed to spawn: gemini/"
      assert escalation.body =~ "invalid model selection"
      refute String.downcase(escalation.subject <> escalation.body) =~ "inconclusive"
      assert Ash.get!(Issue, task.id).attention_cause == :reviewer_failed
    end
  end

  # ---- AC4 -----------------------------------------------------------------

  describe "the bd-651ine invariant holds after a spawn failure" do
    test "a rotated reviewer that returns no verdict does not merge the PR",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_invalid_model(stub_dir, "agy", log)
      stub_silent_review(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/spawn-then-silent")

      wait_until(fn -> finished_failed?(pid) end, 12_000)

      assert hd(calls(log)) == "agy"
      assert merge_commit_count(repo) == 0
      refute Enum.any?(review_rounds(task.id), &(&1.verdict == :approve))
    end

    test "when no provider can spawn, nothing merges and no approval is recorded",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_invalid_model(stub_dir, "agy", log)
      stub_invalid_model(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws)

      pid = run_gate(task, repo, "feature/spawn-never-merges")

      wait_until(fn -> finished_failed?(pid) end, 12_000)

      assert merge_commit_count(repo) == 0
      refute Enum.any?(review_rounds(task.id), &(&1.verdict == :approve))
    end
  end
end
