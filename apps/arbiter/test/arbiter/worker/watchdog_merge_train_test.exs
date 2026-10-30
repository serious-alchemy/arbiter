defmodule Arbiter.Worker.WatchdogMergeTrainTest do
  @moduledoc """
  bd-1754qj — on the auto-merge lane the Watchdogs of one target's approved MRs
  share a merge head: one MR at a time is synced (merge-time freshness, a
  forge-reported `:behind_base`, a CI-remediation sync) and waited on in CI; the
  others wait without syncing. Real Watchdog processes, a stub adapter.
  """
  # async: false — shared sandbox with the Watchdog processes, singleton stubs,
  # the app-env freshness probe and the application's one MergeTrain.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.MergeTrain
  alias Arbiter.Worker.Watchdog

  @reviewed_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1111111..2222222 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -10,6 +10,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  @merge_from_main_diff """
  diff --git a/lib/a.ex b/lib/a.ex
  index 3333333..4444444 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -41,6 +41,7 @@ defmodule A do
     def run do
       :ok
  +    :extra
     end
   end
  """

  setup do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    StubAutoResumeDispatcher.reset()

    on_exit(fn ->
      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)
    end)

    {:ok, ws: workspace()}
  end

  defp workspace(config \\ %{}),
    do: %Workspace{id: "ws-train-#{System.unique_integer([:positive])}", config: config}

  # `behind` maps head sha -> commits of the target that head lacks.
  defp probe(behind) do
    Application.put_env(:arbiter, :merge_freshness_probe, fn _repo, _base, head ->
      {:ok, Map.fetch!(behind, head)}
    end)
  end

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  # A task `id` whose MR is "!<id>", reviewed at "<id>0" and synced to "<id>1".
  defp mr(id), do: "!" <> id

  defp watch(id, ws, opts \\ []) do
    base = [
      task_id: id,
      mr_ref: mr(id),
      adapter: StubMerger,
      workspace: ws,
      auto_merge: true,
      interval_ms: 15,
      initial_delay_ms: 0,
      max_polls: :infinity,
      fix_pass_dispatcher: StubFixPassDispatcher,
      auto_resume_dispatcher: StubAutoResumeDispatcher,
      last_reviewed_sha: id <> "0"
    ]

    :ok = Watchdog.subscribe(id)
    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  defp diffs(id) do
    StubMerger.set_diff(mr(id), id <> "0", @reviewed_diff)
    StubMerger.set_diff(mr(id), id <> "1", @merge_from_main_diff)
  end

  # A stale approved MR: green on its old head until it is synced, then CI runs on
  # the synced head until the test lets it pass. Answered from live state, so a
  # MR that waits keeps showing its old head however often it is polled.
  defp stale_then_running(id, base \\ "main"), do: serve(id, base, :running)

  defp let_ci_pass(id, base \\ "main"), do: serve(id, base, :success)

  defp serve(id, base, ci) do
    diffs(id)

    synced =
      case ci do
        :running -> running(id <> "1", base)
        :success -> green(id <> "1", base)
        :closed -> %{status: :closed}
      end

    StubMerger.queue_get(mr(id), [
      fn -> if syncs(id) > 0, do: synced, else: green(id <> "0", base) end
    ])
  end

  defp green(head, base \\ "main"),
    do: %{
      status: :open,
      approved: true,
      ci_clean: true,
      pipeline: :success,
      head_sha: head,
      base_ref: base
    }

  defp running(head, base),
    do: %{status: :open, approved: true, pipeline: :running, head_sha: head, base_ref: base}

  defp red(head, base \\ "main"),
    do: %{
      status: :open,
      approved: true,
      block_reason: :ci_failed,
      pipeline: :failed,
      head_sha: head,
      base_ref: base
    }

  defp syncs(id), do: StubMerger.update_branch_count(mr(id))

  # The Watchdog has polled `n` more times: whatever it was going to do by now, it did.
  defp after_polls(wpid, n) do
    target = :sys.get_state(wpid).poll_count + n
    wait_until(fn -> :sys.get_state(wpid).poll_count >= target end)
  end

  defp role(wpid), do: :sys.get_state(wpid).train_role

  defp wait_until(fun, timeout \\ 3_000) do
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

  describe "two or more approved, green, stale MRs on one target" do
    test "only the head is synced; the others wait and spend no sync", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0, "c0" => 4, "c1" => 0})
      for id <- ~w(a b c), do: stale_then_running(id)

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)

      b = watch("b", ws)
      c = watch("c", ws)
      after_polls(b, 4)
      after_polls(c, 4)

      assert role(a) == :head
      assert role(b) == {:wait, "a"}
      assert role(c) == {:wait, "a"}
      assert syncs("a") == 1
      assert syncs("b") == 0
      assert syncs("c") == 0
      assert StubMerger.merge_count("!b") == 0
      # The sync budget of a waiting MR is untouched, and it is not parked.
      assert :sys.get_state(b).freshness_syncs == 0
      assert :sys.get_state(b).freshness_failed_head == nil
    end

    test "when the head merges the next is synced, then merges after green CI", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      for id <- ~w(a b), do: stale_then_running(id)

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 4)
      assert syncs("b") == 0

      let_ci_pass("a")
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000

      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
      after_polls(b, 3)
      assert syncs("b") == 1
      assert StubMerger.merge_count("!b") == 0

      let_ci_pass("b")
      assert_receive {:watchdog, "b", {:merged, _}}, 3_000
      assert StubMerger.merge_count("!a") == 1
      assert StubMerger.merge_count("!b") == 1
      assert syncs("a") == 1
      assert syncs("b") == 1
      refute Process.alive?(a)
    end

    test "the next head is chosen by priority, then by when it became merge-ready", %{ws: ws} do
      probe(%{
        "a0" => 4,
        "a1" => 0,
        "b0" => 4,
        "b1" => 0,
        "c0" => 4,
        "c1" => 0,
        "d0" => 4,
        "d1" => 0
      })

      for id <- ~w(a b c d), do: stale_then_running(id)

      _a = watch("a", ws, train_priority: 2)
      wait_until(fn -> syncs("a") == 1 end)

      # b: P2, ready first. c: P1, ready second. d: P1, ready last.
      b = watch("b", ws, train_priority: 2)
      after_polls(b, 2)
      c = watch("c", ws, train_priority: 1)
      after_polls(c, 2)
      d = watch("d", ws, train_priority: 1)
      after_polls(d, 2)

      let_ci_pass("a")
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000

      wait_until(fn -> syncs("c") == 1 end)
      after_polls(b, 3)
      assert syncs("b") == 0
      assert syncs("d") == 0

      let_ci_pass("c")
      assert_receive {:watchdog, "c", {:merged, _}}, 3_000
      wait_until(fn -> syncs("d") == 1 end)
      after_polls(b, 3)
      assert syncs("b") == 0
    end
  end

  describe "an MR within up_to_date_tolerance" do
    test "merges without a sync even though it is not the head" do
      ws = workspace(%{"merge" => %{"up_to_date_tolerance" => 1}})
      probe(%{"a0" => 3, "a1" => 0, "b0" => 1})
      stale_then_running("a")
      diffs("b")
      StubMerger.queue_get(mr("b"), [green("b0")])

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      assert role(a) == :head

      watch("b", ws)
      assert_receive {:watchdog, "b", {:merged, _}}, 3_000
      assert StubMerger.merge_count("!b") == 1
      assert syncs("b") == 0
      assert syncs("a") == 1
    end

    test "merges one at a time per target: the next waits for the merge slot", %{ws: ws} do
      probe(%{"b0" => 0})
      diffs("b")
      StubMerger.queue_get(mr("b"), [green("b0")])

      assert :ok = MergeTrain.acquire_merge({ws.id, nil, "main"}, "someone-else")

      b = watch("b", ws)
      after_polls(b, 4)
      assert StubMerger.merge_count("!b") == 0

      :ok = MergeTrain.release_merge({ws.id, nil, "main"}, "someone-else")
      assert_receive {:watchdog, "b", {:merged, _}}, 3_000
      assert StubMerger.merge_count("!b") == 1
    end

    test "the merge slot is per target", %{ws: ws} do
      probe(%{"b0" => 0})
      diffs("b")
      StubMerger.queue_get(mr("b"), [green("b0", "release")])

      assert :ok = MergeTrain.acquire_merge({ws.id, nil, "main"}, "someone-else")
      watch("b", ws)
      assert_receive {:watchdog, "b", {:merged, _}}, 3_000
    end
  end

  describe "hand-off" do
    test "a head whose sync fails is parked and hands its place on", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4})
      StubMerger.set_update_branch_result({:error, :conflict})
      for id <- ~w(a b), do: StubMerger.queue_get(mr(id), [green(id <> "0")])

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      _b = watch("b", ws)

      wait_until(fn -> syncs("b") == 1 end)
      after_polls(a, 3)
      assert syncs("a") == 1
    end

    test "a closed head hands its place on", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4})
      for id <- ~w(a b), do: stale_then_running(id)

      watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 3)
      assert syncs("b") == 0

      serve("a", "main", :closed)
      assert_receive {:watchdog, "a", {:closed, _}}, 3_000
      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
    end

    test "a head whose CI stays red hands its place on", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4})
      for id <- ~w(a b), do: StubMerger.queue_get(mr(id), [red(id <> "0")])

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)

      # `a` synced and its CI is still red on the same head: after the grace
      # ticks the train hands its place to `b`, which syncs in its turn.
      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
      assert Process.alive?(a)
    end

    test "a head whose Watchdog dies hands its place on", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4})
      for id <- ~w(a b), do: stale_then_running(id)

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 3)
      assert syncs("b") == 0

      ref = Process.monitor(a)
      Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, a)
      assert_receive {:DOWN, ^ref, :process, ^a, _}

      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
    end
  end

  describe "targets" do
    test "MRs on different targets have independent heads", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4, "c0" => 4})
      stale_then_running("a", "main")
      stale_then_running("b", "release")
      stale_then_running("c", "main")

      watch("a", ws)
      watch("b", ws)
      wait_until(fn -> syncs("a") == 1 and syncs("b") == 1 end)

      c = watch("c", ws)
      after_polls(c, 3)
      assert role(c) == {:wait, "a"}
      assert syncs("c") == 0
    end

    test "MRs of different workspaces have independent heads" do
      probe(%{"a0" => 4, "b0" => 4})
      for id <- ~w(a b), do: stale_then_running(id)

      watch("a", workspace())
      watch("b", workspace())
      wait_until(fn -> syncs("a") == 1 and syncs("b") == 1 end)
    end

    test "MRs of different repos have independent heads", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4})
      for id <- ~w(a b), do: stale_then_running(id)

      watch("a", ws, repo: "repo-one")
      watch("b", ws, repo: "repo-two")
      wait_until(fn -> syncs("a") == 1 and syncs("b") == 1 end)
    end
  end

  describe "a restart" do
    setup do
      on_exit(fn ->
        Application.put_env(:arbiter, :merge_train_settle_ms, 0)
        restart_train()
      end)
    end

    defp restart_train do
      old = Process.whereis(MergeTrain)
      ref = Process.monitor(old)
      GenServer.stop(old)
      assert_receive {:DOWN, ^ref, :process, ^old, _}

      wait_until(fn ->
        is_pid(Process.whereis(MergeTrain)) and Process.whereis(MergeTrain) != old
      end)
    end

    test "of the train re-forms the order and never starts two heads", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0, "c0" => 4, "c1" => 0})
      for id <- ~w(a b c), do: stale_then_running(id)

      Application.put_env(:arbiter, :merge_train_settle_ms, :infinity)
      restart_train()

      a = watch("a", ws, train_priority: 3)
      b = watch("b", ws, train_priority: 2)
      c = watch("c", ws, train_priority: 0)
      for w <- [a, b, c], do: after_polls(w, 4)

      # Forming: nobody is synced, whoever polled first.
      assert [syncs("a"), syncs("b"), syncs("c")] == [0, 0, 0]
      assert role(a) == {:wait, :forming}

      :ok = MergeTrain.settle_now()

      wait_until(fn -> syncs("c") == 1 end)
      for w <- [a, b, c], do: after_polls(w, 3)
      assert [syncs("a"), syncs("b"), syncs("c")] == [0, 0, 1]
      assert role(c) == :head
      assert role(a) == {:wait, "c"}
    end

    test "of the head's Watchdog does not let a second MR sync beside the new head", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      for id <- ~w(a b), do: stale_then_running(id)

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 3)

      ref = Process.monitor(a)
      Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, a)
      assert_receive {:DOWN, ^ref, :process, ^a, _}
      wait_until(fn -> syncs("b") == 1 end)

      # The restarted Watchdog of `a` is no head while `b` is.
      StubMerger.queue_get(mr("a"), [green("a0")])
      a2 = watch("a", ws)
      after_polls(a2, 4)
      assert role(a2) == {:wait, "b"}
      assert syncs("a") == 1
      assert syncs("b") == 1
    end
  end

  describe "CI remediation" do
    test "does not sync a non-head MR: it re-runs its failed jobs on the existing head", %{ws: ws} do
      probe(%{"a0" => 4, "b0" => 4})
      stale_then_running("a")
      StubMerger.queue_get(mr("b"), [red("b0")])

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)

      b = watch("b", ws)
      after_polls(b, 5)

      assert syncs("b") == 0
      assert role(b) == {:wait, "a"}
      # No fix pass, no attempt spent, one re-run of the failed jobs on the head.
      assert StubFixPassDispatcher.call_count() == 0
      assert :sys.get_state(b).auto_resolve_attempts == 0
      assert [{"!b", _}] = Enum.filter(StubMerger.ci_reruns(), &match?({"!b", _}, &1))
      assert role(a) == :head
    end

    test "syncs the MR once it is the head", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      stale_then_running("a")
      StubMerger.queue_get(mr("b"), [red("b0")])

      watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 3)
      assert syncs("b") == 0

      let_ci_pass("a")
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      wait_until(fn -> syncs("b") == 1 end)
      assert StubFixPassDispatcher.call_count() == 0
    end
  end

  describe "a lone approved MR" do
    test "is synced once, exactly as before", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0})
      stale_then_running("a")
      watch("a", ws)

      wait_until(fn -> syncs("a") == 1 end)
      let_ci_pass("a")
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      assert syncs("a") == 1
      assert StubMerger.merge_count("!a") == 1
    end
  end

  describe "hand-off bounds (bd-az0dcu)" do
    test "merge.train_ci_wait_ms bounds the head's running CI; queued time does not count" do
      # 60ms at a 15ms poll: the head may run CI for four polls.
      ws =
        workspace(%{"merge" => %{"train_ci_wait_ms" => 60, "train_ci_pending_max_ms" => 100_000}})

      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      diffs("a")
      stale_then_running("b")

      {:ok, phase} = Agent.start_link(fn -> :pending end)

      StubMerger.queue_get(mr("a"), [
        fn ->
          if syncs("a") > 0,
            do: %{running("a1", "main") | pipeline: Agent.get(phase, & &1)},
            else: green("a0", "main")
        end
      ])

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)

      # Queued far longer than the bound: the head keeps its place.
      after_polls(a, 25)
      after_polls(b, 3)
      assert role(a) == :head
      assert role(b) == {:wait, "a"}
      assert syncs("b") == 0

      # Once the pipeline runs, the bound applies and the place is handed on.
      Agent.update(phase, fn _ -> :running end)
      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
    end

    test "merge.train_ci_pending_max_ms hands a head with no running pipeline on" do
      # 60ms CI-wait, 150ms pending cap at a 15ms poll: ten pending polls.
      ws =
        workspace(%{
          "merge" => %{"train_ci_wait_ms" => 60, "train_ci_pending_max_ms" => 150}
        })

      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      diffs("a")
      stale_then_running("b")

      # The sync triggered no pipeline: the forge reports it pending, for good.
      StubMerger.queue_get(mr("a"), [
        fn ->
          if syncs("a") > 0,
            do: %{running("a1", "main") | pipeline: :pending},
            else: green("a0", "main")
        end
      ])

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)

      after_polls(b, 3)
      assert role(a) == :head
      assert syncs("b") == 0

      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
      assert role(a) == {:wait, "b"}
      assert :sys.get_state(a).train_synced_from == nil
    end

    test "merge.train_ready_ticks of 0 is normalised: a green head still merges" do
      ws = workspace(%{"merge" => %{"train_ready_ticks" => 0}})
      probe(%{"a0" => 4, "a1" => 0})
      stale_then_running("a")

      watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      let_ci_pass("a")
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      assert StubMerger.merge_count("!a") == 1
    end

    test "a head parked on an undecidable coverage releases its place" do
      ws =
        Ash.create!(Workspace, %{
          name: "ws-cov-#{System.unique_integer([:positive])}",
          prefix: "tc#{System.unique_integer([:positive])}",
          config: %{"merge" => %{"coverage_enabled" => true}}
        })

      task =
        Ash.create!(Arbiter.Tasks.Issue, %{title: "cov", description: "d", workspace_id: ws.id})

      id = task.id
      h0 = Base.encode16(:crypto.hash(:sha, "cov0"), case: :lower)
      h1 = Base.encode16(:crypto.hash(:sha, "cov1"), case: :lower)
      probe(%{h0 => 4, h1 => 0, "b0" => 4, "b1" => 0})
      stale_then_running("b")

      {:ok, _} =
        Arbiter.Reviews.Coverage.record(%{
          task_id: id,
          mr_ref: mr(id),
          head_sha: h0,
          base_ref: "main",
          net_diff_id: Arbiter.Mergers.NetDiff.fingerprint(@reviewed_diff),
          kind: :reviewed,
          source: :review_gate
        })

      # After the sync the head is green, but whether the synced commit is covered
      # cannot be decided: the probe errors.
      StubMerger.set_diff(mr(id), h0, @reviewed_diff)
      StubMerger.set_ancestor(mr(id), {h1, h0}, {:error, :timeout})

      StubMerger.queue_get(mr(id), [
        fn -> if syncs(id) > 0, do: green(h1), else: green(h0) end
      ])

      a = watch(id, ws, local_head_sha: h0, last_reviewed_sha: h0)
      wait_until(fn -> syncs(id) == 1 end)
      b = watch("b", ws)

      wait_until(fn -> :sys.get_state(a).coverage_parked? end, 5_000)

      # Parked: it no longer holds the target, so the next MR syncs.
      wait_until(fn -> syncs("b") == 1 end)
      assert role(b) == :head
      assert role(a) == nil
      assert StubMerger.merge_count(mr(id)) == 0
    end
  end

  describe "a restart (bd-az0dcu)" do
    # The train process restarting, without restarting it: its supervisor
    # tolerates only so many restarts in a few seconds. The state is what a fresh
    # train has: no entries, no merge slots, forming.
    setup do
      on_exit(fn -> MergeTrain.settle_now() end)
    end

    defp forget_train do
      :sys.replace_state(MergeTrain, fn state -> %{state | settle: :forming, trains: %{}} end)
    end

    defp kill(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    test "of the train orders the re-formed train by persisted merge-ready time", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0, "c0" => 4, "c1" => 0})
      for id <- ~w(a b c), do: stale_then_running(id)

      forget_train()

      # Same priority; the Watchdogs poll in the order a, b, c, but became
      # merge-ready in the order c, b, a.
      a = watch("a", ws, train_ready_since: ~U[2026-10-29 12:00:00Z])
      b = watch("b", ws, train_ready_since: ~U[2026-10-29 11:00:00Z])
      c = watch("c", ws, train_ready_since: ~U[2026-10-29 10:00:00Z])
      for w <- [a, b, c], do: after_polls(w, 4)
      assert [syncs("a"), syncs("b"), syncs("c")] == [0, 0, 0]

      :ok = MergeTrain.settle_now()

      wait_until(fn -> syncs("c") == 1 end)
      for w <- [a, b, c], do: after_polls(w, 3)
      assert [syncs("a"), syncs("b"), syncs("c")] == [0, 0, 1]
      assert role(c) == :head
      assert role(b) == {:wait, "c"}
    end

    test "of a head's crashed Watchdog keeps its place while the synced pipeline runs", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      for id <- ~w(a b), do: stale_then_running(id)

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 3)

      kill(a)
      after_polls(b, 8)

      # The old head's pipeline is still running: no second sync pipeline.
      assert syncs("b") == 0
      assert role(b) == {:wait, "a"}

      # The restarted Watchdog (its ticket's lane says a sync was under way) is
      # the head again, and b still waits.
      a2 = watch("a", ws, train_synced_from: "a0")
      wait_until(fn -> role(a2) == :head end)
      after_polls(b, 4)
      assert syncs("b") == 0
      assert syncs("a") == 1

      let_ci_pass("a")
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      wait_until(fn -> syncs("b") == 1 end)
    end

    test "of the server (train and Watchdogs) keeps the synced head's place", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0})
      for id <- ~w(a b), do: stale_then_running(id)

      a = watch("a", ws)
      wait_until(fn -> syncs("a") == 1 end)
      b = watch("b", ws)
      after_polls(b, 3)

      kill(a)
      forget_train()

      a2 = watch("a", ws, train_synced_from: "a0")
      wait_until(fn -> role(a2) == :head end)

      :ok = MergeTrain.settle_now()
      after_polls(b, 5)
      assert role(b) == {:wait, "a"}
      assert syncs("b") == 0
    end
  end

  describe "the ticket's lane (bd-az0dcu)" do
    import Arbiter.LifecycleFixtures

    alias Arbiter.Tasks.{Issue, PullRequest}

    # Real tickets, so the lane (`train_synced_from`) is what a restart reads back.
    defp lane_task(ws) do
      issue = Ash.create!(Issue, %{title: "lane", workspace_id: ws.id}) |> put_state!(:active)

      {:ok, merging} =
        Issue.pr_opened(issue.id, mr(issue.id),
          merge_watch: %{"adapter" => "Elixir.Arbiter.Test.StubMerger"}
        )

      merging.id
    end

    defp lane_marker(id), do: Ash.get!(Issue, id).merge_watch["train_synced_from"]

    defp restart(id, ws) do
      {:ok, opts} = PullRequest.watch_opts(id)
      watch(id, ws, opts)
    end

    defp train_workspace(config) do
      Ash.create!(Workspace, %{
        name: "ws-hand-#{System.unique_integer([:positive])}",
        prefix: "th#{System.unique_integer([:positive])}",
        config: config
      })
    end

    test "a hand-off clears the sync marker, and a restart does not seat the handed-off MR" do
      ws = train_workspace(%{"merge" => %{"train_ci_wait_ms" => 60}})
      [a, b] = [lane_task(ws), lane_task(ws)]
      probe(%{(a <> "0") => 4, (a <> "1") => 0, (b <> "0") => 4, (b <> "1") => 0})
      for id <- [a, b], do: stale_then_running(id)

      wa = watch(a, ws)
      wait_until(fn -> syncs(a) == 1 end)
      wait_until(fn -> lane_marker(a) == a <> "0" end)
      wb = watch(b, ws)

      # a's CI-wait bound passes; b takes over and syncs.
      wait_until(fn -> syncs(b) == 1 end)
      assert role(wa) == {:wait, b}
      assert lane_marker(a) == nil
      wait_until(fn -> lane_marker(b) == b <> "0" end)

      # The server restarts and a polls first.
      kill(wa)
      kill(wb)
      forget_train()

      a2 = restart(a, ws)
      after_polls(a2, 3)
      refute role(a2) == :head

      b2 = restart(b, ws)
      wait_until(fn -> role(b2) == :head end)
      :ok = MergeTrain.settle_now()
      refute role(a2) == :head
      assert syncs(a) == 1
    end

    test "a deliberate stop clears the sync marker, so a restart is not seated" do
      ws = train_workspace(%{})
      [a, b] = [lane_task(ws), lane_task(ws)]
      probe(%{(a <> "0") => 4, (a <> "1") => 0, (b <> "0") => 4, (b <> "1") => 0})
      for id <- [a, b], do: stale_then_running(id)

      wa = watch(a, ws)
      wait_until(fn -> syncs(a) == 1 end)
      wait_until(fn -> lane_marker(a) == a <> "0" end)

      Watchdog.stop(a)
      refute Process.alive?(wa)
      assert lane_marker(a) == nil

      forget_train()
      b2 = watch(b, ws)
      after_polls(b2, 3)
      a2 = restart(a, ws)
      after_polls(a2, 3)
      :ok = MergeTrain.settle_now()
      wait_until(fn -> role(b2) == :head end)
      after_polls(a2, 4)
      refute role(a2) == :head
    end

    test "records merge-ready time and the sync under way, and watch_opts hands them back" do
      ws =
        Ash.create!(Workspace, %{
          name: "ws-lane-#{System.unique_integer([:positive])}",
          prefix: "tl#{System.unique_integer([:positive])}"
        })

      issue = Ash.create!(Issue, %{title: "lane", workspace_id: ws.id}) |> put_state!(:active)

      {:ok, merging} =
        Issue.pr_opened(issue.id, mr(issue.id),
          merge_watch: %{"adapter" => "Elixir.Arbiter.Test.StubMerger"}
        )

      id = merging.id

      probe(%{(id <> "0") => 4, (id <> "1") => 0})
      stale_then_running(id)
      w = watch(id, ws)
      wait_until(fn -> syncs(id) == 1 end)

      since = :sys.get_state(w).train_ready_since
      lane = Ash.get!(Issue, id).merge_watch
      assert lane["train_ready_since"] == DateTime.to_iso8601(since)
      assert lane["train_synced_from"] == id <> "0"

      assert {:ok, opts} = PullRequest.watch_opts(id)
      assert opts[:train_ready_since] == DateTime.to_iso8601(since)
      assert opts[:train_synced_from] == id <> "0"

      # A deliberate stop (pull, resume to work, watch replacement) clears the sync.
      Watchdog.stop(id)
      assert Ash.get!(Issue, id).merge_watch["train_synced_from"] == nil
      assert Ash.get!(Issue, id).merge_watch["train_ready_since"] == DateTime.to_iso8601(since)
    end

    test "leaving the sync place clears the sync, not the merge-ready time" do
      ws =
        Ash.create!(Workspace, %{
          name: "ws-lane2-#{System.unique_integer([:positive])}",
          prefix: "tm#{System.unique_integer([:positive])}"
        })

      issue = Ash.create!(Issue, %{title: "lane", workspace_id: ws.id}) |> put_state!(:active)

      {:ok, merging} =
        Issue.pr_opened(issue.id, mr(issue.id),
          merge_watch: %{"adapter" => "Elixir.Arbiter.Test.StubMerger"}
        )

      id = merging.id
      probe(%{(id <> "0") => 4, (id <> "1") => 0})
      stale_then_running(id)
      w = watch(id, ws)
      wait_until(fn -> syncs(id) == 1 end)
      since = :sys.get_state(w).train_ready_since

      # Leaving the sync place clears the sync, not the merge-ready time.

      serve(id, "main", :closed)
      assert_receive {:watchdog, ^id, {:closed, _}}, 3_000
      wait_until(fn -> Ash.get!(Issue, id).merge_watch["train_synced_from"] == nil end)
      lane = Ash.get!(Issue, id).merge_watch
      assert lane["train_synced_from"] == nil
      assert lane["train_ready_since"] == DateTime.to_iso8601(since)
    end
  end

  describe "election (bd-az0dcu)" do
    test "a non-head MR in CI remediation is elected behind a green stale one", %{ws: ws} do
      probe(%{"a0" => 4, "a1" => 0, "b0" => 4, "b1" => 0, "c0" => 4, "c1" => 0})
      stale_then_running("a")
      StubMerger.queue_get(mr("b"), [red("b0")])
      stale_then_running("c")

      a = watch("a", ws, train_ready_since: ~U[2026-10-29 10:00:00Z])
      wait_until(fn -> syncs("a") == 1 end)

      # b became merge-ready before c, but it is red.
      b = watch("b", ws, train_ready_since: ~U[2026-10-29 10:30:00Z])
      c = watch("c", ws, train_ready_since: ~U[2026-10-29 11:00:00Z])
      after_polls(b, 3)
      after_polls(c, 3)

      ref = Process.monitor(a)
      Arbiter.ProcessTeardown.stop_child(Arbiter.Worker.WatchdogSupervisor, a)
      assert_receive {:DOWN, ^ref, :process, ^a, _}

      wait_until(fn -> syncs("c") == 1 end)
      assert syncs("b") == 0
      assert role(c) == :head
    end
  end
end
