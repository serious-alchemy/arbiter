defmodule Arbiter.Worker.ReviewGateConflictReviewTest do
  @moduledoc """
  bd-954ym8 / #134 — a head that follows an approved commit only by integrating
  the target branch does not cost a full review round:

    * a clean merge/rebase is auto-covered with no round (AC1);
    * hand-resolved conflict regions get a scoped `:conflict_review` round at
      the standard tier, shown only those regions (AC2);
    * anything else — a smuggled hunk — is reviewed in full (AC3, the safety
      property);
    * the scoped reviewer is cross-family against whoever resolved (AC4);
    * the rounds list tells the round apart and a counter reports all three
      outcomes (AC5).

  Driven against real git: a bare `origin`, a feature branch with an approved
  commit, a `main` that moves, and a worktree the gate reviews.
  """

  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  require Ash.Query

  alias Arbiter.ReviewGate.Round
  alias Arbiter.Reviews.ConflictReview
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker
  alias Arbiter.Worker.ReviewGate
  alias Arbiter.Workers.Run

  @reviewer Path.expand("../../fixtures/review_verdict.sh", __DIR__)
  @shared Enum.map_join(1..12, "", &"shared line #{&1}\n")
  @mr "owner/repo#134"

  setup do
    tmp = Path.join(System.tmp_dir!(), "rg-cr-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    repo = init_repo(tmp)

    put_app_env(:arbiter, :worktree_root, Path.join(tmp, "worktrees"))
    put_app_env(:arbiter, :repo_paths, %{"trib/repo" => repo})
    on_exit(fn -> File.rm_rf!(tmp) end)

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "rg-cr-#{System.unique_integer([:positive])}",
        prefix: "rc",
        config: %{"review" => %{"required" => true}}
      })

    %{repo: repo, ws: ws, tmp: tmp}
  end

  # ---- AC1 -------------------------------------------------------------------

  test "a clean merge of the target is auto-covered: no reviewer, no round, a recorded reason",
       %{repo: repo, ws: ws, tmp: tmp} do
    {approved, wt, task} = approved_branch(repo, ws, tmp, "feature/clean")
    advance_main(repo, "other.ex", "main moved, nowhere near the feature\n")

    gate = start_gate(task, ws, wt, "feature/clean", command: slow_reviewer())
    assert_gate_stops(gate)

    head = sha(wt, "HEAD")
    refute head == approved

    # A :mechanical row for the new head, derived from the approval's own row.
    assert [row] = Enum.filter(Coverage.for_mr(@mr), &(&1.head_sha == head))
    assert row.kind == :mechanical
    assert row.source == :review_gate
    assert row.derived_from == approved_row_id(approved)

    # The merge guard's two readers both cover it: the coverage predicate (rule
    # 1) and the legacy last_reviewed_sha stamp the Watchdog compares.
    assert {:covered, ^head} = Coverage.decide(Coverage.for_mr(@mr), head, %{})
    assert Ash.get!(Issue, task.id).last_reviewed_sha == head

    # No review round was paid for, and the counter and reason say why.
    assert rounds(task.id) == []

    assert %{"auto_cover" => 1, "scoped_review" => 0, "fallback" => 0} =
             ConflictReview.report(task.id)

    assert conflict_event(task.id, "auto_cover")["reason"] =~ "no review round"
  end

  # ---- AC2 -------------------------------------------------------------------

  test "hand-resolved conflicts get a scoped conflict review, shown only the regions, and its APPROVE covers the head",
       %{repo: repo, ws: ws, tmp: tmp} do
    {approved, wt, task} = approved_branch(repo, ws, tmp, "feature/resolved")

    advance_main(
      repo,
      "shared.ex",
      String.replace(@shared, "shared line 4", "shared line 4 (main)")
    )

    resolve_merge(wt, "shared.ex", "shared line 4 (main + feature)\n")

    gate = start_gate(task, ws, wt, "feature/resolved", command: slow_reviewer())
    prompt = prompt_of(gate)

    # Both sides and the resolution, and nothing else of the PR.
    assert prompt =~ "SCOPED CONFLICT-RESOLUTION"
    assert prompt =~ "shared line 4 (main)"
    assert prompt =~ "shared line 4 (feature)"
    assert prompt =~ "shared line 4 (main + feature)"
    assert prompt =~ approved
    refute prompt =~ "shared line 9"
    refute prompt =~ "feature_only_marker"
    refute prompt =~ "gh pr diff"

    # The round is its own kind, at the standard tier, on a short timeout.
    assert :sys.get_state(gate).timeout_ms == 5 * 60 * 1000

    head = sha(wt, "HEAD")
    wait_until(fn -> Enum.any?(Coverage.for_mr(@mr), &(&1.head_sha == head)) end)

    assert [%{kind: :reviewed, source: :review_gate}] =
             Enum.filter(Coverage.for_mr(@mr), &(&1.head_sha == head))

    assert [%Round{role: :conflict_review, verdict: :approve, reviewer_tier: "standard"}] =
             rounds(task.id)

    assert Ash.get!(Issue, task.id).last_reviewed_sha == head

    assert %{"scoped_review" => 1, "scoped_approved" => 1, "auto_cover" => 0, "fallback" => 0} =
             ConflictReview.report(task.id)
  end

  test "a REQUEST_CHANGES from the scoped review is a conflict_review row and counts as rejected",
       %{repo: repo, ws: ws, tmp: tmp} do
    {_approved, wt, task} = approved_branch(repo, ws, tmp, "feature/rejected")

    advance_main(
      repo,
      "shared.ex",
      String.replace(@shared, "shared line 4", "shared line 4 (main)")
    )

    resolve_merge(wt, "shared.ex", "shared line 4 (dropped the feature side)\n")

    gate =
      start_gate(task, ws, wt, "feature/rejected",
        command: ["sh", "-c", "sleep 1; exec \"$0\" REQUEST_CHANGES", @reviewer],
        rounds: 1
      )

    assert_gate_stops(gate)

    assert [%Round{role: :conflict_review, verdict: :request_changes}] = rounds(task.id)
    assert %{"scoped_rejected" => 1, "scoped_approved" => 0} = ConflictReview.report(task.id)
    # An unapproved resolution covers nothing.
    refute Enum.any?(Coverage.for_mr(@mr), &(&1.head_sha == sha(wt, "HEAD")))
  end

  # ---- AC3: the safety property ------------------------------------------------

  test "a hunk smuggled into a clean merge commit falls back to a full review",
       %{repo: repo, ws: ws, tmp: tmp} do
    {_approved, wt, task} = approved_branch(repo, ws, tmp, "feature/smuggled-clean")
    advance_main(repo, "other.ex", "main moved\n")

    git!(wt, ["fetch", "-q", "origin"])
    git!(wt, ["merge", "-q", "--no-edit", "--no-commit", "origin/main"])
    File.write!(Path.join(wt, "backdoor.ex"), "smuggled_authored_change\n")
    git!(wt, ["add", "."])
    git!(wt, ["commit", "-q", "-m", "Merge main"])

    gate = start_gate(task, ws, wt, "feature/smuggled-clean", command: slow_reviewer())
    prompt = prompt_of(gate)

    refute prompt =~ "SCOPED CONFLICT-RESOLUTION"
    assert prompt =~ "gh pr diff 134"
    assert Enum.map(Coverage.for_mr(@mr), & &1.kind) == [:reviewed]

    wait_until(fn -> rounds(task.id) != [] end)
    assert [%Round{role: :review, verdict: :approve}] = rounds(task.id)

    assert %{"fallback" => 1, "auto_cover" => 0, "scoped_review" => 0} =
             ConflictReview.report(task.id)

    assert conflict_event(task.id, "fallback")["reason"] =~ "backdoor.ex"
  end

  test "a hunk smuggled into a hand-resolved merge, outside the conflicted region, falls back to a full review",
       %{repo: repo, ws: ws, tmp: tmp} do
    {_approved, wt, task} = approved_branch(repo, ws, tmp, "feature/smuggled-resolved")

    advance_main(
      repo,
      "shared.ex",
      String.replace(@shared, "shared line 4", "shared line 4 (main)")
    )

    resolve_merge(wt, "shared.ex", "shared line 4 (both)\n",
      also: {"shared line 9", "shared line 9 (smuggled)"}
    )

    gate = start_gate(task, ws, wt, "feature/smuggled-resolved", command: slow_reviewer())
    prompt = prompt_of(gate)

    refute prompt =~ "SCOPED CONFLICT-RESOLUTION"
    assert prompt =~ "gh pr diff 134"
    assert %{"fallback" => 1, "scoped_review" => 0} = ConflictReview.report(task.id)
  end

  test "a fix commit on top of the approved head is still the delta review, counted as a fallback",
       %{repo: repo, ws: ws, tmp: tmp} do
    {_approved, wt, task} = approved_branch(repo, ws, tmp, "feature/fixpass")
    File.write!(Path.join(wt, "lint.ex"), "fixpass_marker\n")
    git!(wt, ["add", "."])
    git!(wt, ["commit", "-q", "-m", "credo fix"])

    gate = start_gate(task, ws, wt, "feature/fixpass", command: slow_reviewer())
    prompt = prompt_of(gate)

    assert prompt =~ "DELTA REVIEW"
    assert prompt =~ "fixpass_marker"
    assert %{"fallback" => 1} = ConflictReview.report(task.id)
  end

  test "review_gate.conflict_review: false keeps a clean merge on the full review",
       %{repo: repo, ws: ws, tmp: tmp} do
    {:ok, ws} =
      Ash.update(ws, %{config: Map.put(ws.config, "review_gate", %{"conflict_review" => false})})

    {_approved, wt, task} = approved_branch(repo, ws, tmp, "feature/optout")
    advance_main(repo, "other.ex", "main moved\n")

    gate = start_gate(task, ws, wt, "feature/optout", command: slow_reviewer())
    _ = prompt_of(gate)

    assert %{"auto_cover" => 0, "fallback" => 0} = ConflictReview.report(task.id)
    assert Enum.map(Coverage.for_mr(@mr), & &1.kind) == [:reviewed]
  end

  # ---- AC4 ---------------------------------------------------------------------

  describe "the conflict reviewer's family differs from the conflict resolver's (bd-a1ke2c)" do
    test "a Gemini-resolved conflict is reviewed by Anthropic, at the standard tier",
         %{repo: repo, tmp: tmp} do
      stub_dir = Path.join(tmp, "stub-bin")
      File.mkdir_p!(stub_dir)
      log = Path.join(tmp, "calls.txt")
      stub(stub_dir, "claude", log)
      stub(stub_dir, "agy", log)
      prepend_path(stub_dir)

      {:ok, ws} =
        Ash.create(Workspace, %{
          name: "rg-cr-xf-#{System.unique_integer([:positive])}",
          prefix: "rx",
          config: %{
            "review" => %{"required" => true},
            # Gemini first: without cross-family review it would be the reviewer.
            "review_agent" => %{"type" => ["gemini", "claude"], "cross_family" => true}
          }
        })

      {_approved, wt, task} = approved_branch(repo, ws, tmp, "feature/xfam")

      Ash.create!(Run, %{
        task_id: task.id,
        base_task_id: task.id,
        repo: "trib/repo",
        kind: :conflict,
        provider: "gemini",
        started_at: DateTime.utc_now()
      })

      advance_main(
        repo,
        "shared.ex",
        String.replace(@shared, "shared line 4", "shared line 4 (main)")
      )

      resolve_merge(wt, "shared.ex", "shared line 4 (both)\n")

      gate = start_gate(task, ws, wt, "feature/xfam", [])
      assert_gate_stops(gate)

      assert File.read!(log) |> String.split("\n", trim: true) == ["claude"]

      assert [round] = rounds(task.id)
      assert round.role == :conflict_review
      assert round.reviewer_family == "anthropic"
      assert round.implementer_family == "google"
      assert round.same_family_fallback == false
      assert round.reviewer_tier == "standard"
    end
  end

  # ---- fixtures ------------------------------------------------------------------

  defp stub(dir, name, log) do
    path = Path.join(dir, name)

    File.write!(path, """
    #!/bin/sh
    echo "#{name}" >> #{log}
    echo "reviewing the resolved regions..."
    echo "VERDICT: APPROVE"
    echo "findings: both sides survive in every resolution"
    echo "arb done"
    exit 0
    """)

    File.chmod!(path, 0o755)
  end

  defp prepend_path(dir) do
    old = System.get_env("PATH") || ""
    System.put_env("PATH", "#{dir}:#{old}")
    on_exit(fn -> System.put_env("PATH", old) end)
  end

  defp git(repo, args), do: System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)

  defp git!(repo, args) do
    {out, code} = git(repo, args)
    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed (#{code}): #{out}")
    out
  end

  defp sha(repo, ref), do: repo |> git!(["rev-parse", ref]) |> String.trim()

  defp init_repo(dir) do
    repo = Path.join(dir, "repo")
    bare = Path.join(dir, "origin.git")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", repo])
    git!(repo, ["config", "user.email", "repo@example.com"])
    git!(repo, ["config", "user.name", "Repo"])
    git!(repo, ["config", "commit.gpgsign", "false"])
    File.write!(Path.join(repo, "shared.ex"), @shared)
    File.write!(Path.join(repo, "other.ex"), "other\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "seed"])
    {_, 0} = System.cmd("git", ["clone", "--bare", "-q", repo, bare])
    git!(repo, ["remote", "add", "origin", bare])
    git!(repo, ["fetch", "-q", "origin"])
    repo
  end

  # The feature branch with its approved commit A (edits shared.ex line 4 and
  # adds a file of its own), a worktree on it, an active task and a :reviewed
  # coverage row for A. Main is back checked out in `repo`.
  defp approved_branch(repo, ws, tmp, branch) do
    git!(repo, ["checkout", "-q", "-b", branch])
    shared = Path.join(repo, "shared.ex")
    File.write!(shared, String.replace(@shared, "shared line 4", "shared line 4 (feature)"))
    File.write!(Path.join(repo, "feature.ex"), "feature_only_marker\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "feature work"])
    approved = sha(repo, "HEAD")
    git!(repo, ["checkout", "-q", "main"])

    wt = Path.join(tmp, "wt-#{:erlang.unique_integer([:positive])}")

    {_, 0} =
      System.cmd("git", ["worktree", "add", "-q", wt, branch], cd: repo, stderr_to_stdout: true)

    on_exit(fn ->
      _ = System.cmd("git", ["-C", repo, "worktree", "remove", "--force", wt])
      File.rm_rf!(wt)
    end)

    {:ok, task} =
      Ash.create(Issue, %{title: "conflict task", workspace_id: ws.id, issue_type: :feature})

    task = put_state!(task, :active)

    {:ok, _} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: @mr,
        head_sha: approved,
        base_ref: "main",
        net_diff_id: "fp-#{approved}",
        kind: :reviewed,
        source: :review_gate,
        round: 1
      })

    {approved, wt, task}
  end

  # Moves main (and origin/main) on.
  defp advance_main(repo, file, content) do
    git!(repo, ["checkout", "-q", "main"])
    File.write!(Path.join(repo, file), content)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "main moves: #{file}"])
    git!(repo, ["push", "-q", "origin", "main"])
  end

  # Merges origin/main into the worktree's branch by hand, resolving the
  # expected conflict in `file` with `content` — the head a conflict resolver
  # hands the gate. `also: {from, to}` makes one more edit in the same file.
  defp resolve_merge(wt, file, content, opts \\ []) do
    git!(wt, ["fetch", "-q", "origin"])
    {_, 1} = git(wt, ["merge", "--no-edit", "origin/main"])

    path = Path.join(wt, file)
    current = File.read!(path)
    assert current =~ "<<<<<<<", "the fixture expected a conflict in #{file}"

    resolved = Regex.replace(~r/<<<<<<<.*?>>>>>>>[^\n]*\n/s, current, content, global: false)

    resolved =
      case Keyword.get(opts, :also) do
        {from, to} -> String.replace(resolved, from, to, global: false)
        nil -> resolved
      end

    File.write!(path, resolved)
    git!(wt, ["add", file])
    git!(wt, ["commit", "-q", "--no-edit"])
  end

  defp approved_row_id(approved) do
    Coverage.for_mr(@mr) |> Enum.find(&(&1.head_sha == approved)) |> Map.fetch!(:id)
  end

  defp rounds(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!()
  end

  defp conflict_event(task_id, outcome) do
    Arbiter.Events.Record
    |> Ash.Query.filter(topic == "conflict_review")
    |> Ash.read!()
    |> Enum.map(& &1.payload)
    |> Enum.find(&(&1["task_id"] == task_id and &1["outcome"] == outcome))
  end

  # A reviewer that takes a moment before approving, so the pass's prompt can
  # be read off the gate while it is in flight.
  defp slow_reviewer, do: ["sh", "-c", "sleep 1; exec \"$0\" APPROVE", @reviewer]

  defp start_gate(task, ws, wt, branch, opts) do
    {:ok, author} =
      Worker.start(
        task_id: task.id,
        repo: "trib/repo",
        workspace_id: ws.id,
        meta: %{
          branch: branch,
          target_branch: "main",
          merge_title: "Merge #{task.id}",
          review_required: true,
          review_spawn: false
        }
      )

    on_exit(fn -> if Process.alive?(author), do: GenServer.stop(author, :normal) end)
    :ok = Worker.advance(author, :claude)
    send(author, {:__claude_session_done__, "arb done"})

    wait_until(fn ->
      match?(%{state: :waiting, waiting_on: :review_gate}, Worker.state(author))
    end)

    {:ok, gate} =
      ReviewGate.start(
        [
          author: author,
          task_id: task.id,
          workspace_id: ws.id,
          repo: "trib/repo",
          worktree_path: wt,
          branch: branch,
          target_branch: "main",
          pr_ref: @mr
        ] ++ opts
      )

    gate
  end

  defp assert_gate_stops(gate) do
    ref = Process.monitor(gate)
    assert_receive {:DOWN, ^ref, :process, ^gate, _}, 20_000
  end

  defp prompt_of(gate) do
    wait_until(fn -> is_binary(:sys.get_state(gate).current_prompt) end)
    :sys.get_state(gate).current_prompt
  end

  defp wait_until(fun, timeout \\ 15_000) do
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
        Process.sleep(15)
        do_wait(fun, deadline)
    end
  end
end
