defmodule Arbiter.Worker.WatchdogMergeTrainPhase2Test do
  @moduledoc """
  bd-4y9dno — phase 2 of the coalesced merge train (bd-1754qj): find conflicts
  early while MRs wait, push their commits without CI, spend CI on the head only.

    * a waiting (non-head) approved MR gets a conflict probe when the target moves;
      a conflict dispatches the conflict pass now, a clean probe does nothing;
    * passes dispatched for a waiting MR carry the forge's CI-skip mechanism;
    * a head whose last push skipped CI is merged only after Arbiter triggers its
      pipeline and that pipeline is green; a skipped pipeline never merges;
    * an MR alone in its queue behaves as before.

  Real Watchdog processes, a stub adapter, a stub resolver and probe.
  """
  # async: false — shared sandbox with the Watchdog processes, singleton stubs,
  # the app-env freshness probe and the application's one MergeTrain.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Worker.Watchdog

  defmodule RecordingResolver do
    @moduledoc false
    @behaviour Arbiter.Workflows.MergeQueue.ConflictResolver

    def arm(task_id, test_pid), do: :persistent_term.put({__MODULE__, task_id}, test_pid)

    @impl true
    def resolve(%{task_id: task_id} = args) do
      if pid = :persistent_term.get({__MODULE__, task_id}, nil),
        do: send(pid, {:conflict_pass, task_id, args})

      {:ok, %{worker_pid: nil, branch: "feat/x"}}
    end

    @impl true
    def escalate_unresolved(_task_id, _workspace_id, _branch, _reason), do: :ok

    @impl true
    def notify_resolution(_task_id, _workspace_id, _branch), do: :ok
  end

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
    {:ok, probe_log} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)
    end)

    {:ok, ws: workspace(), probe_log: probe_log}
  end

  defp workspace(config \\ %{}),
    do: %Workspace{id: "ws-p2-#{System.unique_integer([:positive])}", config: config}

  defp freshness(behind) do
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

  defp mr(id), do: "!" <> id

  # A conflict probe answering `verdict` for every call, logging the task asked.
  defp probe_fn(log, id, verdict) do
    fn args ->
      Agent.update(log, &[{id, args} | &1])
      %{verdict: verdict, target_tip: "tip1", head: "h"}
    end
  end

  defp probed(log, id), do: log |> Agent.get(& &1) |> Enum.count(&(elem(&1, 0) == id))

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
      conflict_resolver: RecordingResolver,
      last_reviewed_sha: id <> "0"
    ]

    RecordingResolver.arm(id, self())
    :ok = Watchdog.subscribe(id)
    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  defp diffs(id) do
    StubMerger.set_diff(mr(id), id <> "0", @reviewed_diff)
    StubMerger.set_diff(mr(id), id <> "1", @merge_from_main_diff)
  end

  defp green(head, base \\ "main"),
    do: %{
      status: :open,
      approved: true,
      ci_clean: true,
      pipeline: :success,
      head_sha: head,
      head_ref: "feat/" <> head,
      base_ref: base
    }

  defp running(head, base \\ "main"),
    do: %{
      status: :open,
      approved: true,
      pipeline: :running,
      head_sha: head,
      head_ref: "feat/" <> head,
      base_ref: base
    }

  defp skipped(head, base \\ "main"), do: Map.put(green(head, base), :pipeline, :neutral)

  defp syncs(id), do: StubMerger.update_branch_count(mr(id))

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

  # `a` is the head: stale on its first head, synced (CI running) after.
  defp seat_head(ws, id \\ "a") do
    diffs(id)

    StubMerger.queue_get(mr(id), [
      fn -> if syncs(id) > 0, do: running(id <> "1"), else: green(id <> "0") end
    ])

    wpid = watch(id, ws)
    wait_until(fn -> syncs(id) == 1 end)
    assert role(wpid) == :head
    wpid
  end

  # `b` is a stale approved MR that waits behind head `a`.
  defp seat_waiter(ws, log, verdict, id \\ "b", opts \\ []) do
    diffs(id)
    StubMerger.queue_get(mr(id), [green(id <> "0")])

    wpid =
      watch(id, ws, Keyword.merge([conflict_probe: probe_fn(log, id, verdict)], opts))

    wait_until(fn -> role(wpid) == {:wait, "a"} end)
    wpid
  end

  describe "conflict probe of a waiting MR" do
    test "a conflict dispatches the conflict pass now, while the MR waits", %{
      ws: ws,
      probe_log: log
    } do
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      a = seat_head(ws)
      b = seat_waiter(ws, log, {:conflict, ["lib/a.ex"]})

      assert_receive {:conflict_pass, "b", %{pr_ref: "!b", task_id: "b"}}, 3_000
      assert role(b) == {:wait, "a"}
      # the conflict pass is the only thing b did: no sync, no merge, no head change for a
      assert syncs("b") == 0
      assert StubMerger.merge_count("!b") == 0
      assert role(a) == :head
      assert syncs("a") == 1
    end

    test "a clean probe does nothing", %{ws: ws, probe_log: log} do
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      _a = seat_head(ws)
      b = seat_waiter(ws, log, :clean)

      wait_until(fn -> probed(log, "b") >= 1 end)
      after_polls(b, 4)

      refute_received {:conflict_pass, "b", _}
      assert syncs("b") == 0
      assert StubMerger.merge_count("!b") == 0
      assert :sys.get_state(b).conflict_attempts == 0
    end

    test "an answer git cannot give is no conflict", %{ws: ws, probe_log: log} do
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      _a = seat_head(ws)
      b = seat_waiter(ws, log, :unknown)

      wait_until(fn -> probed(log, "b") >= 1 end)
      after_polls(b, 3)
      refute_received {:conflict_pass, "b", _}
    end

    test "the head is not probed", %{ws: ws, probe_log: log} do
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      diffs("a")

      StubMerger.queue_get(mr("a"), [
        fn -> if syncs("a") > 0, do: running("a1"), else: green("a0") end
      ])

      a = watch("a", ws, conflict_probe: probe_fn(log, "a", {:conflict, ["x"]}))
      wait_until(fn -> syncs("a") == 1 end)
      after_polls(a, 4)

      assert probed(log, "a") == 0
      refute_received {:conflict_pass, "a", _}
    end

    test "merge.train_conflict_probe=false turns the probe off", %{probe_log: log} do
      ws = workspace(%{"merge" => %{"train_conflict_probe" => false}})
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      _a = seat_head(ws)
      b = seat_waiter(ws, log, {:conflict, ["lib/a.ex"]})

      after_polls(b, 4)
      assert probed(log, "b") == 0
      refute_received {:conflict_pass, "b", _}
    end

    test "the probe is handed the MR's branch, head and target", %{ws: ws, probe_log: log} do
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      _a = seat_head(ws)
      b = seat_waiter(ws, log, :clean)

      wait_until(fn -> probed(log, "b") >= 1 end)
      after_polls(b, 1)
      {"b", args} = log |> Agent.get(& &1) |> List.last()
      assert %{branch: "feat/b0", target: "main"} = args
    end
  end

  describe "passes for a waiting MR skip CI" do
    test "the conflict pass carries the forge's CI-skip mechanism", %{ws: ws, probe_log: log} do
      StubMerger.set_ci_skip_mechanism({:push_option, "ci.skip"})
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      _a = seat_head(ws)
      _b = seat_waiter(ws, log, {:conflict, ["lib/a.ex"]})

      assert_receive {:conflict_pass, "b", %{ci_skip: {:push_option, "ci.skip"}}}, 3_000
    end

    test "without a mechanism (or with merge.train_ci_skip=false) the pass is ordinary", %{
      probe_log: log
    } do
      ws = workspace()
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4})
      _a = seat_head(ws)
      _b = seat_waiter(ws, log, {:conflict, ["lib/a.ex"]})
      assert_receive {:conflict_pass, "b", args}, 3_000
      refute Map.has_key?(args, :ci_skip)

      StubMerger.set_ci_skip_mechanism({:push_option, "ci.skip"})
      ws2 = workspace(%{"merge" => %{"train_ci_skip" => false}})
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 4, "c0" => 4, "c1" => 0, "d0" => 4})
      _c = seat_head(ws2, "c")
      StubMerger.queue_get(mr("d"), [green("d0")])
      diffs("d")

      _d =
        watch("d", ws2, conflict_probe: probe_fn(log, "d", {:conflict, ["lib/a.ex"]}))

      assert_receive {:conflict_pass, "d", args2}, 3_000
      refute Map.has_key?(args2, :ci_skip)
    end

    test "a conflict the forge reports on the head itself is not skipped", %{ws: ws} do
      StubMerger.set_ci_skip_mechanism({:push_option, "ci.skip"})
      freshness(%{"a0" => 0})
      diffs("a")
      StubMerger.queue_get(mr("a"), [Map.put(green("a0"), :block_reason, :conflict)])
      _a = watch("a", ws)

      assert_receive {:conflict_pass, "a", args}, 3_000
      refute Map.has_key?(args, :ci_skip)
    end
  end

  describe "CI only for the head" do
    setup do
      StubMerger.set_ci_skip_mechanism({:push_option, "ci.skip"})
      :ok
    end

    test "a CI-skipped head is triggered, and merged only once that pipeline is green", %{ws: ws} do
      freshness(%{"a0" => 0})
      diffs("a")
      StubMerger.queue_get(mr("a"), [skipped("a0")])
      a = watch("a", ws)
      :ok = Watchdog.note_ci_skipped_push("a", "a0")

      wait_until(fn -> length(StubMerger.pipeline_triggers()) == 1 end)
      after_polls(a, 4)

      # the skipped pipeline reads neutral: it must never merge
      assert StubMerger.merge_count("!a") == 0
      assert [{"!a", _}] = StubMerger.pipeline_triggers()

      StubMerger.queue_get(mr("a"), [running("a0")])
      after_polls(a, 3)
      assert StubMerger.merge_count("!a") == 0

      StubMerger.queue_get(mr("a"), [green("a0")])
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      assert StubMerger.merge_count("!a") == 1
      assert length(StubMerger.pipeline_triggers()) == 1
    end

    test "a skipped pipeline never merges, even after the trigger", %{ws: ws} do
      freshness(%{"a0" => 0})
      diffs("a")
      StubMerger.queue_get(mr("a"), [skipped("a0")])
      a = watch("a", ws)
      :ok = Watchdog.note_ci_skipped_push("a", "a0")

      wait_until(fn -> StubMerger.pipeline_triggers() != [] end)
      after_polls(a, 6)
      assert StubMerger.merge_count("!a") == 0
    end

    test "a waiting MR with a skipped head does not trigger; it waits for the head", %{
      ws: ws,
      probe_log: log
    } do
      freshness(%{"a0" => 4, "a1" => 0, "b0" => 0})
      _a = seat_head(ws)
      diffs("b")
      StubMerger.queue_get(mr("b"), [skipped("b0")])
      b = watch("b", ws, conflict_probe: probe_fn(log, "b", :clean))
      :ok = Watchdog.note_ci_skipped_push("b", "b0")

      wait_until(fn -> role(b) == {:wait, "a"} end)
      after_polls(b, 4)
      assert StubMerger.pipeline_triggers() == []
      assert StubMerger.merge_count("!b") == 0
    end

    test "a forge that reports no pipeline for our own skipped head gets one triggered, not a page",
         %{ws: ws} do
      freshness(%{"a0" => 0})
      diffs("a")

      no_pipeline =
        skipped("a0") |> Map.put(:pipeline, nil) |> Map.put(:block_reason, :no_pipeline)

      StubMerger.queue_get(mr("a"), [no_pipeline])
      a = watch("a", ws, ci_skipped_head: "a0")

      wait_until(fn -> length(StubMerger.pipeline_triggers()) == 1 end)
      after_polls(a, 3)

      assert :sys.get_state(a).park_reason == nil
      assert StubMerger.merge_count("!a") == 0

      StubMerger.queue_get(mr("a"), [green("a0")])
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
    end

    test "a head that moved on (a sync, a new push) is no longer skipped", %{ws: ws} do
      freshness(%{"a1" => 0})
      diffs("a")
      StubMerger.queue_get(mr("a"), [green("a1")])
      watch("a", ws, ci_skipped_head: "a0")

      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      assert StubMerger.pipeline_triggers() == []
    end

    test "a trigger the forge refuses is retried a bounded number of times, then pages", %{
      ws: ws
    } do
      StubMerger.set_trigger_result({:error, :pipeline_refused})
      freshness(%{"a0" => 0})
      diffs("a")
      StubMerger.queue_get(mr("a"), [skipped("a0")])
      a = watch("a", ws)
      :ok = Watchdog.note_ci_skipped_push("a", "a0")

      wait_until(fn -> length(StubMerger.pipeline_triggers()) >= 3 end)
      wait_until(fn -> :sys.get_state(a).park_reason == :no_pipeline end)
      assert length(StubMerger.pipeline_triggers()) == 3
      assert StubMerger.merge_count("!a") == 0
    end
  end

  describe "an MR alone in its queue" do
    test "is the head: no wait, no probe, no skip, no trigger, merges as today", %{
      ws: ws,
      probe_log: log
    } do
      StubMerger.set_ci_skip_mechanism({:push_option, "ci.skip"})
      freshness(%{"a0" => 0})
      diffs("a")
      StubMerger.queue_get(mr("a"), [green("a0")])
      watch("a", ws, conflict_probe: probe_fn(log, "a", {:conflict, ["x"]}))

      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      assert StubMerger.merge_count("!a") == 1
      assert probed(log, "a") == 0
      assert StubMerger.pipeline_triggers() == []
      refute_received {:conflict_pass, "a", _}
    end

    test "a stale lone MR is synced (normally, with CI) and merges after green", %{ws: ws} do
      StubMerger.set_ci_skip_mechanism({:push_option, "ci.skip"})
      freshness(%{"a0" => 4, "a1" => 0})
      diffs("a")

      StubMerger.queue_get(mr("a"), [
        fn -> if syncs("a") > 0, do: green("a1"), else: green("a0") end
      ])

      watch("a", ws)
      assert_receive {:watchdog, "a", {:merged, _}}, 3_000
      assert syncs("a") == 1
      assert StubMerger.pipeline_triggers() == []
    end
  end
end
