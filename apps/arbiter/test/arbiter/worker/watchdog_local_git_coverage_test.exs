defmodule Arbiter.Worker.WatchdogLocalGitCoverageTest do
  @moduledoc """
  bd-wjpxok / #26 — the merge guard's local-git fallback.

  vs-4v8cf0 (vstim !270): the ReviewGate approved `56e80ef6`, a CI fix pass
  added one test-only commit, and every compare the guard needed failed with
  GitLab's 403 `insufficient_granular_scope`. The coverage predicate answered
  `{:unknown, :diff_unavailable}` and the approved MR sat undecided until it
  parked, while `git merge-base --is-ancestor` / `git log` in the checkout
  Arbiter already has answered the question in one step.

  Here the stub forge fails every compare and every ancestry probe, and the
  workspace maps the watched repo to a real clone. The guard must decide from
  local git: covered heads (a pure rebase, a no-op delta) merge, a real
  unreviewed delta goes back to review — or pages with the delta named — and
  never merges, and `diff_unavailable` is left for when local git cannot
  answer either.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.GitFixture
  import ExUnit.CaptureLog

  require Logger

  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.CoverageShadow.Tally
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  @forbidden %{kind: :forbidden, status: 403, message: "insufficient_granular_scope"}

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    Tally.reset()
    on_exit(&Tally.reset/0)

    # AC5's "which path decided" lines are info-level; test.exs runs at warning.
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok
  end

  # ---- fixtures ------------------------------------------------------------

  # `reviewed` is the approved commit on `feature`; the clone (the workspace's
  # `repo_paths` checkout) has fetched it, as the ReviewGate's worktree would.
  defp approved_branch do
    fx = origin_and_clone(%{"lib/a.ex" => "a1\n", "test/a_test.exs" => "t1\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])
    reviewed = commit!(fx.origin, %{"lib/a.ex" => "a1\na2\n"}, "feature work")
    git!(fx.clone, ["fetch", "-q", "origin"])
    Map.put(fx, :reviewed, reviewed)
  end

  # The vs-4v8cf0 shape: one test-only commit on top of the approved one,
  # pushed from elsewhere (the clone has not fetched it).
  defp add_fix_pass_commit!(fx) do
    commit!(fx.origin, %{"test/a_test.exs" => "t1\nt2\n"}, "test fix")
  end

  defp rebase_onto_moved_main!(fx) do
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, %{"lib/b.ex" => "b1\n"}, "unrelated main work")
    git!(fx.origin, ["checkout", "-q", "feature"])
    git!(fx.origin, ["rebase", "-q", "main"])
    git!(fx.origin, ["rev-parse", "HEAD"])
  end

  # What `ReviewGate.coverage_net_diff_id/1` stamps on the `:reviewed` row.
  defp review_gate_fingerprint(repo, sha) do
    mb = git!(repo, ["merge-base", "origin/main", sha])
    NetDiff.fingerprint_local(repo, "#{mb}..#{sha}")
  end

  defp workspace(coverage_enabled?, repo_paths) do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "lg#{System.unique_integer([:positive])}",
      config: %{
        "merge" => %{"coverage_enabled" => coverage_enabled?},
        "repo_paths" => repo_paths
      }
    })
  end

  # A reviewed ticket whose approval was stamped (and covered) at `reviewed`,
  # with every forge compare failing.
  defp reviewed_ticket(fx, mr_ref, coverage_enabled?, opts \\ []) do
    repo_paths = Keyword.get(opts, :repo_paths, %{"vstim" => fx.clone})
    ws = workspace(coverage_enabled?, repo_paths)

    task =
      Ash.create!(Issue, %{
        title: "local git coverage",
        description: "body",
        workspace_id: ws.id,
        last_reviewed_sha: fx.reviewed
      })

    {:ok, _} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: mr_ref,
        head_sha: fx.reviewed,
        base_ref: "main",
        net_diff_id: review_gate_fingerprint(fx.clone, fx.reviewed),
        kind: :reviewed,
        source: :review_gate
      })

    StubMerger.set_diff_error(mr_ref, @forbidden)
    {task, ws}
  end

  defp serve_head(mr_ref, head) do
    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, head_sha: head, base_ref: "main"}
    ])
  end

  defp start_watchdog(task, mr_ref, ws, reviewed, opts \\ []) do
    base = [
      task_id: task.id,
      mr_ref: mr_ref,
      adapter: StubMerger,
      workspace: ws,
      repo: "vstim",
      auto_merge: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      auto_resume_dispatcher: StubAutoResumeDispatcher,
      last_reviewed_sha: reviewed,
      local_head_sha: reviewed
    ]

    :ok = Watchdog.subscribe(task.id)
    {:ok, pid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(pid) end)
    pid
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp assert_merged(task_id, timeout \\ 5_000) do
    assert_receive {:watchdog, ^task_id, {:merged, _}}, timeout
  end

  defp wait_until(fun, timeout \\ 5_000) do
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
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  # ---- merge.coverage_enabled: true ---------------------------------------

  describe "coverage predicate decides (flag on), compare API down" do
    test "AC4: the vs-4v8cf0 shape goes back to review at once, never merges" do
      fx = approved_branch()
      head = add_fix_pass_commit!(fx)
      mr_ref = "!270"
      {task, ws} = reviewed_ticket(fx, mr_ref, true)
      # Rule 2's probe fails too — the same token scope covers merge_base.
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:error, @forbidden})
      serve_head(mr_ref, head)

      log =
        capture_log(fn ->
          start_watchdog(task, mr_ref, ws, fx.reviewed)
          wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)
        end)

      assert StubMerger.merge_count(mr_ref) == 0, "an unreviewed delta must never merge"
      refute log =~ "coverage is undecided", "local git answers: no undecided polls"
      refute log =~ "diff_unavailable"
      assert log =~ "local_git"
      assert log =~ "test/a_test.exs", "the refusal names the unreviewed files"
      assert log =~ "test fix", "the refusal names the unreviewed commits"
    end

    test "AC4: with no re-review budget, pages at once naming the commits and files" do
      fx = approved_branch()
      head = add_fix_pass_commit!(fx)
      mr_ref = "!270b"
      {task, ws} = reviewed_ticket(fx, mr_ref, true)
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:error, @forbidden})
      serve_head(mr_ref, head)

      capture_log(fn ->
        start_watchdog(task, mr_ref, ws, fx.reviewed, max_auto_resumes: 0)
        wait_until(fn -> StubAutoResumeDispatcher.escalations() != [] end)
      end)

      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 0

      assert [{_, _, ^mr_ref, 0, reason}] = StubAutoResumeDispatcher.escalations()
      reviewed = fx.reviewed
      assert {:stale_reviewed_sha, ^reviewed, ^head, delta} = reason
      assert delta.files == ["test/a_test.exs"]
      assert [commit] = delta.commits
      assert commit =~ String.slice(head, 0, 7)
      assert commit =~ "test fix"
    end

    test "AC3: a pure rebase onto a moved base is covered and merges" do
      fx = approved_branch()
      head = rebase_onto_moved_main!(fx)
      mr_ref = "!rebase"
      {task, ws} = reviewed_ticket(fx, mr_ref, true)
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:error, @forbidden})
      serve_head(mr_ref, head)

      log =
        capture_log(fn ->
          start_watchdog(task, mr_ref, ws, fx.reviewed)
          assert_merged(task.id)
        end)

      assert StubMerger.last_merge() == {mr_ref, head}, "the merge is pinned to the head"
      assert StubAutoResumeDispatcher.resume_count() == 0
      assert log =~ "local_git"

      assert Enum.any?(
               Coverage.for_mr(mr_ref),
               &(&1.kind == :mechanical and &1.head_sha == head)
             ),
             "the rule-3 proof is persisted, as on the API path"
    end

    test "AC2: a descendant whose delta nets to nothing is covered and merges" do
      fx = approved_branch()
      commit!(fx.origin, %{"tmp.txt" => "scratch\n"}, "add scratch")
      head = commit!(fx.origin, %{"tmp.txt" => :delete}, "drop scratch")
      mr_ref = "!noop"
      {task, ws} = reviewed_ticket(fx, mr_ref, true)
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:error, @forbidden})
      serve_head(mr_ref, head)

      capture_log(fn ->
        start_watchdog(task, mr_ref, ws, fx.reviewed)
        assert_merged(task.id)
      end)

      assert StubMerger.last_merge() == {mr_ref, head}
    end

    test "AC5: diff_unavailable only when local git cannot answer either" do
      fx = approved_branch()
      head = add_fix_pass_commit!(fx)
      mr_ref = "!nolocal"
      # The repo is not mapped to any checkout: local git has nothing to ask.
      {task, ws} = reviewed_ticket(fx, mr_ref, true, repo_paths: %{})
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:ok, false})
      serve_head(mr_ref, head)

      log =
        capture_log(fn ->
          pid = start_watchdog(task, mr_ref, ws, fx.reviewed)
          wait_until(fn -> :sys.get_state(pid).coverage_unknown_polls >= 1 end)
        end)

      assert log =~ "coverage is undecided (diff_unavailable)"
      assert log =~ "local git could not answer either"
      assert StubMerger.merge_count(mr_ref) == 0
      assert StubAutoResumeDispatcher.resume_count() == 0
    end
  end

  # ---- merge.coverage_enabled: false (the legacy guard decides) -----------

  describe "last_reviewed_sha guard decides (flag off), compare API down" do
    test "AC3: a pure rebase merges on the local content check; the shadow agrees" do
      fx = approved_branch()
      head = rebase_onto_moved_main!(fx)
      mr_ref = "!legacyrebase"
      {task, ws} = reviewed_ticket(fx, mr_ref, false)
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:error, @forbidden})
      serve_head(mr_ref, head)

      log =
        capture_log(fn ->
          start_watchdog(task, mr_ref, ws, fx.reviewed, local_head_sha: head)
          assert_merged(task.id)
        end)

      assert StubMerger.last_merge() == {mr_ref, head}
      assert log =~ "identical net diff"
      assert log =~ "local_git"
      refute log =~ "treating the head as unreviewed"
      refute log =~ "DISAGREEMENT", "both predicates decide from the same local answer"
    end

    test "AC4: the vs-4v8cf0 shape is refused and routed to review; the shadow agrees" do
      fx = approved_branch()
      head = add_fix_pass_commit!(fx)
      mr_ref = "!legacy270"
      {task, ws} = reviewed_ticket(fx, mr_ref, false)
      StubMerger.set_ancestor(mr_ref, {head, fx.reviewed}, {:error, @forbidden})
      serve_head(mr_ref, head)

      log =
        capture_log(fn ->
          start_watchdog(task, mr_ref, ws, fx.reviewed, local_head_sha: head)
          wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)
        end)

      assert StubMerger.merge_count(mr_ref) == 0
      assert log =~ "branch advanced past the reviewed commit"
      assert log =~ "local_git"
      refute log =~ "could not compare the reviewed and current net diffs"
      refute log =~ "DISAGREEMENT"
    end
  end
end
