defmodule Arbiter.Worker.WatchdogConflictReviewTest do
  @moduledoc """
  bd-954ym8 / #134 — the Watchdog's stale-reviewed-SHA guard no longer buys a
  re-review for a head that is the approved commit plus a clean integration of
  the base branch, and still refuses everything else.

  Real git: `origin` carries the PR branch, the workspace's `repo_paths`
  checkout is a clone, the forge stub only serves the head.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.Test.GitFixture

  alias Arbiter.Reviews.ConflictReview
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Tasks.Issue
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  @body Enum.map_join(1..10, "", &"x#{&1}\n")

  setup do
    StubMerger.reset()
    StubAutoResumeDispatcher.reset()
    :ok
  end

  # The approved commit adds a2 after x5; the clone has fetched it.
  defp approved_branch do
    fx = origin_and_clone(%{"lib/a.ex" => @body, "lib/b.ex" => "b\n"})
    git!(fx.origin, ["checkout", "-q", "-b", "feature"])

    reviewed =
      commit!(fx.origin, %{"lib/a.ex" => String.replace(@body, "x5\n", "x5\na2\n")}, "feature")

    git!(fx.clone, ["fetch", "-q", "origin"])
    Map.put(fx, :reviewed, reviewed)
  end

  defp main_commit!(fx, files) do
    git!(fx.origin, ["checkout", "-q", "main"])
    commit!(fx.origin, files, "main moves")
    git!(fx.origin, ["checkout", "-q", "feature"])
  end

  # Main edits a line two below the feature's addition: the feature hunk's
  # context changes, so its net diff no longer fingerprints as reviewed.
  defp context_shifting_main!(fx),
    do: main_commit!(fx, %{"lib/a.ex" => String.replace(@body, "x7\n", "x7 (main)\n")})

  defp rebase!(fx) do
    git!(fx.origin, ["rebase", "-q", "main"])
    git!(fx.origin, ["rev-parse", "HEAD"])
  end

  defp workspace(coverage_enabled?, fx) do
    Ash.create!(Arbiter.Tasks.Workspace, %{
      name: "ws-#{System.unique_integer([:positive])}",
      prefix: "cr#{System.unique_integer([:positive])}",
      config: %{
        "merge" => %{"coverage_enabled" => coverage_enabled?},
        "repo_paths" => %{"vstim" => fx.clone}
      }
    })
  end

  defp reviewed_ticket(fx, mr_ref, coverage_enabled?) do
    ws = workspace(coverage_enabled?, fx)

    task =
      Ash.create!(Issue, %{
        title: "conflict review",
        description: "body",
        workspace_id: ws.id,
        last_reviewed_sha: fx.reviewed
      })

    mb = git!(fx.clone, ["merge-base", "origin/main", fx.reviewed])

    {:ok, row} =
      Coverage.record(%{
        task_id: task.id,
        mr_ref: mr_ref,
        head_sha: fx.reviewed,
        base_ref: "main",
        net_diff_id: Arbiter.Mergers.NetDiff.fingerprint_local(fx.clone, "#{mb}..#{fx.reviewed}"),
        kind: :reviewed,
        source: :review_gate
      })

    StubMerger.set_diff_error(mr_ref, %{kind: :forbidden, status: 403, message: "no compare"})
    {task, ws, row}
  end

  defp serve_head(mr_ref, head) do
    StubMerger.queue_get(mr_ref, [
      %{status: :open, approved: true, head_sha: head, base_ref: "main"}
    ])
  end

  defp start_watchdog(task, mr_ref, ws, reviewed) do
    :ok = Watchdog.subscribe(task.id)

    {:ok, pid} =
      Watchdog.start(
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
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  defp wait_until(fun, timeout \\ 8_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      cond do
        fun.() ->
          :done

        System.monotonic_time(:millisecond) > deadline ->
          flunk("condition not met within timeout")

        true ->
          Process.sleep(10)
      end
    end)
    |> Enum.find(&(&1 == :done))
  end

  for flag <- [true, false] do
    test "a clean rebase whose hunk context shifted merges without a re-review (coverage_enabled=#{flag})" do
      fx = approved_branch()
      context_shifting_main!(fx)
      head = rebase!(fx)
      mr_ref = "!clean#{unquote(flag)}"
      {task, ws, row} = reviewed_ticket(fx, mr_ref, unquote(flag))
      serve_head(mr_ref, head)

      start_watchdog(task, mr_ref, ws, fx.reviewed)
      assert_receive {:watchdog, _, {:merged, _}}, 8_000

      assert StubMerger.last_merge() == {mr_ref, head}
      assert StubAutoResumeDispatcher.resume_count() == 0

      # Why it was covered is on record: a :mechanical row from the approval.
      assert [mech] = Enum.filter(Coverage.for_mr(mr_ref), &(&1.head_sha == head))
      assert mech.kind == :mechanical
      assert mech.source == :watchdog
      assert mech.derived_from == row.id

      assert ConflictReview.report(task.id)["auto_cover"] == 1
    end
  end

  test "a head with a hunk smuggled into the merge is refused and sent back to review" do
    fx = approved_branch()
    main_commit!(fx, %{"lib/b.ex" => "b (main)\n"})
    git!(fx.origin, ["merge", "-q", "--no-edit", "--no-commit", "main"])
    File.write!(Path.join(fx.origin, "lib/backdoor.ex"), "smuggled\n")
    git!(fx.origin, ["add", "."])
    git!(fx.origin, ["commit", "-q", "-m", "Merge main"])
    head = git!(fx.origin, ["rev-parse", "HEAD"])

    mr_ref = "!smuggled"
    {task, ws, _row} = reviewed_ticket(fx, mr_ref, true)
    serve_head(mr_ref, head)

    start_watchdog(task, mr_ref, ws, fx.reviewed)
    wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)

    assert StubMerger.merge_count(mr_ref) == 0, "authored content must never merge unreviewed"
    refute Enum.any?(Coverage.for_mr(mr_ref), &(&1.head_sha == head))
    assert ConflictReview.report(task.id)["auto_cover"] == 0
  end

  test "a hand-resolved conflict is not auto-covered: it goes to the gate's scoped review" do
    fx = approved_branch()
    main_commit!(fx, %{"lib/a.ex" => String.replace(@body, "x5\n", "x5 (main)\n")})

    {_, 1} =
      System.cmd("git", ["-C", fx.origin, "rebase", "main"], stderr_to_stdout: true)

    File.write!(
      Path.join(fx.origin, "lib/a.ex"),
      String.replace(@body, "x5\n", "x5 (both)\na2\n")
    )

    git!(fx.origin, ["add", "lib/a.ex"])

    {_, 0} =
      System.cmd("git", ["-C", fx.origin, "-c", "core.editor=true", "rebase", "--continue"],
        stderr_to_stdout: true
      )

    head = git!(fx.origin, ["rev-parse", "HEAD"])

    mr_ref = "!resolved"
    {task, ws, _row} = reviewed_ticket(fx, mr_ref, true)
    serve_head(mr_ref, head)

    start_watchdog(task, mr_ref, ws, fx.reviewed)
    wait_until(fn -> StubAutoResumeDispatcher.resume_count() == 1 end)

    assert StubMerger.merge_count(mr_ref) == 0
    assert ConflictReview.report(task.id)["auto_cover"] == 0
  end
end
