defmodule Arbiter.Worker.ReviewGateCrossFamilyTest do
  @moduledoc """
  bd-a1ke2c: under `review_agent.cross_family` every ReviewGate reviewer pass
  runs in a model family other than the implementer's — rounds, re-reviews
  and print-timeout rotations alike — and records the reviewer family, the
  implementer family and any same-family fallback on its round row.

  Drives the REAL adapter spawn path (no `review_command:` fixture), with
  `agy` and `claude` stubbed onto `PATH`, so the CLI that actually ran each
  pass — and the `--model` it was handed — is read off the stub's own log.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Messages.Message
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker

  # ---- stubs ---------------------------------------------------------------

  defp stub_approve(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    printf '%s' "$*" | tr '\\n' ' ' >> #{log}.args
    echo >> #{log}.args
    echo "reviewing the diff..."
    echo "VERDICT: APPROVE"
    echo "findings: the change looks consistent with the acceptance criteria"
    echo "arb done"
    exit 0
    """)
  end

  defp stub_print_timeout(dir, name, log) do
    write_stub(dir, name, """
    echo "#{name}" >> #{log}
    printf '%s' "$*" | tr '\\n' ' ' >> #{log}.args
    echo >> #{log}.args
    echo "reviewing the diff..."
    echo "[agy] print timeout after 5m0s with turn in progress; returning partial output"
    echo "gemini session SUCCESS · 297s · ~300k tok"
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

  defp log_lines(log) do
    case File.read(log) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      _ -> []
    end
  end

  defp calls(log), do: log_lines(log)

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
    File.write!(Path.join(repo, "#{String.replace(branch, "/", "-")}.txt"), "worker work\n")
    {_, 0} = git(["add", "."], repo)
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
    tmp = Path.join(System.tmp_dir!(), "rg-xfam-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})

    on_exit(fn ->
      File.rm_rf!(tmp)
      :ets.delete_all_objects(:arbiter_provider_circuit_breakers)
    end)

    stub_dir = Path.join(tmp, "stub-bin")
    File.mkdir_p!(stub_dir)
    log = Path.join(tmp, "reviewer-calls.txt")

    %{repo: repo, stub_dir: stub_dir, log: log}
  end

  defp workspace(types, cross_family \\ true) do
    Ash.create!(Workspace, %{
      name: "xfam-ws-#{System.unique_integer([:positive])}",
      prefix: "xf",
      config: %{
        "review" => %{"required" => true, "rounds" => 1},
        "review_agent" => %{"type" => types, "cross_family" => cross_family}
      }
    })
  end

  defp new_task(ws, implementer_family) do
    ws
    |> then(&Ash.create!(Issue, %{title: "cross-family task", workspace_id: &1.id}))
    |> put_state!(:active)
    |> Ash.Changeset.for_update(:pin_implementer, %{implementer_family: implementer_family})
    |> Ash.update!()
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

  defp review_rounds(task_id) do
    require Ash.Query

    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  defp escalation_for(task_id, ws) do
    "admiral"
    |> Message.inbox(workspace_id: ws.id)
    |> Enum.filter(&(&1.directive_ref == task_id))
  end

  # ---- AC1 / AC5 -------------------------------------------------------------

  describe "the reviewer is from another model family (AC1, AC5)" do
    test "Claude implements → a Google reviewer runs Gemini's top model, and the round records it",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_approve(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      # Claude is listed first: without cross-family review it would review.
      ws = workspace(["claude", "gemini"])
      task = new_task(ws, "anthropic")

      run_gate(task, repo, "feature/xf-claude-impl")
      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["agy"]
      assert [line] = log_lines(log <> ".args")
      assert line =~ "--model gemini-3.1-pro-high"

      assert [round] = review_rounds(task.id)
      assert round.verdict == :approve
      assert round.reviewer_provider == "gemini"
      assert round.reviewer_family == "google"
      assert round.implementer_family == "anthropic"
      assert round.same_family_fallback == false
      assert round.same_family_fallback_reason == nil
      assert round.reviewer_tier == "premium"

      task_after = Ash.get!(Issue, task.id)
      assert task_after.reviewer_family == "google"
      assert task_after.notes =~ "reviewer: google (gemini) · implementer: anthropic"
    end

    test "Google implements → an Anthropic reviewer runs",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_approve(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws, "google")

      run_gate(task, repo, "feature/xf-google-impl")
      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["claude"]

      assert [round] = review_rounds(task.id)
      assert round.reviewer_provider == "claude"
      assert round.reviewer_family == "anthropic"
      assert round.implementer_family == "google"
      assert round.same_family_fallback == false
    end

    test "a later gate on the same task (a post-approval re-review) keeps the pinned family",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_approve(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      # An OpenAI implementer: both configured reviewers are eligible, and with
      # no quota readings configured order decides — gemini first.
      ws = workspace(["gemini", "claude"])
      task = new_task(ws, "openai")

      pid = run_gate(task, repo, "feature/xf-first")
      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)
      assert Ash.get!(Issue, task.id).reviewer_family == "google"

      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # Claude is now listed first — an unpinned pick would take it.
      config = put_in(ws.config, ["review_agent", "type"], ["claude", "gemini"])
      Ash.update!(ws, %{config: config})

      run_gate(Ash.get!(Issue, task.id), repo, "feature/xf-second")
      wait_until(fn -> merge_commit_count(repo) == 2 end, 10_000)

      assert calls(log) == ["agy", "agy"]
      assert Enum.map(review_rounds(task.id), & &1.reviewer_family) == ["google", "google"]
    end
  end

  # ---- AC1 / AC4: the print-timeout rotation ------------------------------------

  describe "the print-timeout rotation stays in eligible families (AC1, AC4)" do
    test "a timed-out Google reviewer is never rotated into the implementer's own family",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_print_timeout(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws, "anthropic")

      pid = run_gate(task, repo, "feature/xf-rotate-blocked")

      wait_until(
        fn -> match?(%{state: :finished, outcome: :failed}, Worker.state(pid)) end,
        12_000
      )

      assert calls(log) == ["agy"], "a timeout is not a same-family fallback trigger"
      assert merge_commit_count(repo) == 0

      assert [escalation] = escalation_for(task.id, ws)
      assert escalation.body =~ "cross_family"

      assert [%Round{verdict: :timed_out, reviewer_family: "google"} | _] =
               review_rounds(task.id)
    end

    test "a timed-out reviewer rotates to another eligible family",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_print_timeout(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws, "openai")

      run_gate(task, repo, "feature/xf-rotate")
      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["agy", "claude"]

      assert [
               %Round{verdict: :timed_out, reviewer_family: "google"},
               %Round{verdict: :approve, reviewer_family: "anthropic", implementer_family: "openai"}
             ] = review_rounds(task.id)
    end
  end

  # ---- AC4 / AC5: the recorded fallback -----------------------------------------

  describe "a same-family fallback is immediate and recorded (AC4, AC5)" do
    test "with the other family circuit-broken the implementer's family reviews at once, recorded",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_approve(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ProviderPool.mark_exhausted(:gemini)

      ws = workspace(["gemini", "claude"])
      task = new_task(ws, "anthropic")

      run_gate(task, repo, "feature/xf-fallback")
      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["claude"]

      assert [round] = review_rounds(task.id)
      assert round.reviewer_family == "anthropic"
      assert round.implementer_family == "anthropic"
      assert round.same_family_fallback == true
      assert round.same_family_fallback_reason =~ "google"
      assert round.same_family_fallback_reason =~ "circuit_broken"

      assert Ash.get!(Issue, task.id).notes =~ "SAME-FAMILY FALLBACK"
    end
  end

  # ---- AC7 -------------------------------------------------------------------

  describe "cross_family off (AC7)" do
    test "the workspace's first-choice reviewer runs and nothing family-related is recorded",
         %{repo: repo, stub_dir: stub_dir, log: log} do
      stub_approve(stub_dir, "agy", log)
      stub_approve(stub_dir, "claude", log)
      prepend_path(stub_dir)

      ws = workspace(["claude", "gemini"], false)
      task = new_task(ws, "anthropic")

      run_gate(task, repo, "feature/xf-off")
      wait_until(fn -> merge_commit_count(repo) == 1 end, 10_000)

      assert calls(log) == ["claude"]
      assert [round] = review_rounds(task.id)
      assert round.reviewer_family == nil
      assert round.same_family_fallback == nil
      assert Ash.get!(Issue, task.id).reviewer_family == nil
      refute Ash.get!(Issue, task.id).notes =~ "implementer:"
    end
  end
end
