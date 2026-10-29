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
end
