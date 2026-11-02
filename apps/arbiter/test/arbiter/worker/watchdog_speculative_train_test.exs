defmodule Arbiter.Worker.WatchdogSpeculativeTrainTest do
  @moduledoc """
  bd-6dyva0 — the speculative merge train on the auto-merge lane. With
  `merge.train.depth` K > 1 a target's approved, green, stale MRs are tested at
  once on stacked cars (`main + A`, `main + A + B`, …) on Arbiter-owned refs and
  merged in order, each landing exactly the tree its car tested.

  Real Watchdog processes and real git: a bare origin the stub forge merges into
  (a merge commit of `main` and the guarded MR head, as GitLab's merge-commit
  method does), and the `repo_paths` checkout the cars are built in.
  """
  # async: false — shared sandbox with the Watchdog processes, the singleton
  # stubs, the app-env freshness probe and the application's MergeTrain.
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Test.StubAutoResumeDispatcher
  alias Arbiter.Test.StubFixPassDispatcher
  alias Arbiter.Test.StubMerger
  alias Arbiter.Test.TrainForge
  alias Arbiter.Worker.MergeTrain
  alias Arbiter.Worker.Watchdog

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    StubMerger.reset()
    StubFixPassDispatcher.reset()
    StubAutoResumeDispatcher.reset()

    # Freshness from real git: these MRs really lack main's tip.
    probe = Application.get_env(:arbiter, :merge_freshness_probe)
    Application.delete_env(:arbiter, :merge_freshness_probe)
    on_exit(fn -> Application.put_env(:arbiter, :merge_freshness_probe, probe) end)

    forge = TrainForge.new(dir)

    # The forge merges for real: a merge commit of main and the guarded head.
    StubMerger.set_merge_result(fn _ref, sha ->
      TrainForge.merge!(forge, sha)
      :ok
    end)

    {:ok, forge: forge}
  end

  defp workspace(forge, merge \\ %{}) do
    %Workspace{
      id: "ws-spec-#{System.unique_integer([:positive])}",
      config: %{
        "repo_paths" => %{"app" => forge.repo},
        "merge" => Map.merge(%{"train" => %{"depth" => 3}}, merge)
      }
    }
  end

  defp mr(id), do: "!" <> id
  defp branch(id), do: "feature/" <> id

  # MRs `ids` off the current main, then main moves on, so every one of them
  # is stale. Returns `%{id => head}`.
  defp stale_mrs(forge, ids) do
    heads = Map.new(ids, &{&1, TrainForge.branch!(forge, branch(&1), "#{&1}.txt", "#{&1}\n")})
    TrainForge.advance_main!(forge, "hotfix.txt", "main moved on\n")
    Enum.each(ids, &serve(forge, &1))
    heads
  end

  # Approved and green on its own pipeline, at whatever head its branch has on
  # origin now; merged once the forge merged it.
  defp serve(forge, id) do
    StubMerger.queue_get(mr(id), [
      fn ->
        if StubMerger.merge_count(mr(id)) > 0 do
          %{status: :merged}
        else
          %{
            status: :open,
            approved: true,
            ci_clean: true,
            pipeline: :success,
            head_sha: TrainForge.head(forge, branch(id)),
            base_ref: "main"
          }
        end
      end
    ])
  end

  defp watch(id, ws, head, opts \\ []) do
    base = [
      task_id: id,
      mr_ref: mr(id),
      adapter: StubMerger,
      workspace: ws,
      repo: "app",
      auto_merge: true,
      interval_ms: 20,
      initial_delay_ms: 0,
      max_polls: :infinity,
      fix_pass_dispatcher: StubFixPassDispatcher,
      auto_resume_dispatcher: StubAutoResumeDispatcher,
      last_reviewed_sha: head
    ]

    :ok = Watchdog.subscribe(id)
    {:ok, wpid} = Watchdog.start(Keyword.merge(base, opts))
    on_exit(fn -> stop_quietly(wpid) end)
    wpid
  end

  # Start the Watchdogs one after another, each once the one before has its car,
  # so the seats are a, b, c… in that order.
  defp board_in_order(ids, ws, heads, opts \\ []) do
    Enum.map(ids, fn id ->
      w = watch(id, ws, heads[id], opts)
      wait_until(fn -> car(w) != nil end)
      {id, w}
    end)
    |> Map.new()
  end

  defp car(w), do: :sys.get_state(w).train_car

  defp stop_quietly(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp after_polls(wpid, n) do
    target = :sys.get_state(wpid).poll_count + n
    wait_until(fn -> :sys.get_state(wpid).poll_count >= target end)
  end

  defp wait_until(fun, timeout \\ 8_000) do
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

  defp main_first_parents(forge, n) do
    {out, 0} =
      System.cmd("git", [
        "-C",
        forge.origin,
        "log",
        "--first-parent",
        "-n",
        "#{n}",
        "--format=%H",
        "main"
      ])

    String.split(out, "\n", trim: true)
  end

  describe "depth 1 (the default)" do
    test "is the serial train: only the head is synced, and no car is built", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b))
      ws = workspace(forge, %{"train" => %{"depth" => 1}})

      # Once synced, A's CI runs on its synced head: the serial head's wait.
      synced = String.duplicate("5", 40)

      StubMerger.queue_get(mr("a"), [
        fn ->
          if StubMerger.update_branch_count(mr("a")) > 0,
            do: %{
              status: :open,
              approved: true,
              pipeline: :running,
              head_sha: synced,
              base_ref: "main"
            },
            else: %{
              status: :open,
              approved: true,
              ci_clean: true,
              pipeline: :success,
              head_sha: heads["a"],
              base_ref: "main"
            }
        end
      ])

      a = watch("a", ws, heads["a"])
      wait_until(fn -> StubMerger.update_branch_count(mr("a")) == 1 end)
      b = watch("b", ws, heads["b"])
      after_polls(b, 4)

      assert :sys.get_state(a).train_role == :head
      assert :sys.get_state(b).train_role == {:wait, "a"}
      assert StubMerger.update_branch_count(mr("b")) == 0
      assert StubMerger.car_runs() == []
      assert car(a) == nil
      assert TrainForge.head(forge, "arbiter/train/a") == nil
    end
  end

  describe "with depth 3" do
    test "builds up to depth stacked cars and runs CI on all of them at once", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b c d))
      tip = TrainForge.head(forge, "main")
      ws = workspace(forge)

      w = board_in_order(~w(a b c), ws, heads)
      d = watch("d", ws, heads["d"])
      after_polls(d, 5)

      ca = car(w["a"])
      cb = car(w["b"])
      cc = car(w["c"])

      # main + A, main + A + B, main + A + B + C: merge commits, nothing else.
      assert TrainForge.parents(forge, ca.sha) == [tip, heads["a"]]
      assert TrainForge.parents(forge, cb.sha) == [ca.sha, heads["b"]]
      assert TrainForge.parents(forge, cc.sha) == [cb.sha, heads["c"]]

      # On Arbiter-owned refs, each with its own pipeline, all running at once.
      for {id, c} <- [{"a", ca}, {"b", cb}, {"c", cc}],
          do: assert(TrainForge.head(forge, "arbiter/train/" <> id) == c.sha)

      assert Enum.map(StubMerger.car_runs(), & &1.sha) == [ca.sha, cb.sha, cc.sha]

      # The fourth waits for a seat; no MR branch moved, nothing synced or merged.
      assert car(d) == nil

      for id <- ~w(a b c d) do
        assert TrainForge.head(forge, branch(id)) == heads[id]
        assert StubMerger.update_branch_count(mr(id)) == 0
        assert StubMerger.merge_count(mr(id)) == 0
      end
    end

    test "merges in order, each landing exactly the tree its car tested", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b c))
      w = board_in_order(~w(a b c), workspace(forge), heads)
      ca = car(w["a"])
      cb = car(w["b"])
      cc = car(w["c"])

      # B's car is green first: B still waits for A.
      StubMerger.set_car_status(cb.sha, "success")
      after_polls(w["b"], 5)
      assert StubMerger.merge_count(mr("b")) == 0

      StubMerger.set_car_status(cc.sha, "success")
      StubMerger.set_car_status(ca.sha, "success")

      for id <- ~w(a b c), do: assert_receive({:watchdog, ^id, {:merged, _}}, 8_000)

      # The MR heads merged, in order, each guarded on its reviewed head.
      assert StubMerger.merges_in_order() == Enum.map(~w(a b c), &{mr(&1), heads[&1]})

      # Main's three new merge commits carry exactly the three cars' trees.
      [m_c, m_b, m_a] = main_first_parents(forge, 3)
      assert TrainForge.tree(forge, m_a) == ca.tree
      assert TrainForge.tree(forge, m_b) == cb.tree
      assert TrainForge.tree(forge, m_c) == cc.tree

      # No car was rebuilt or re-run, and every car ref is gone.
      assert length(StubMerger.car_runs()) == 3
      for id <- ~w(a b c), do: assert(TrainForge.head(forge, "arbiter/train/" <> id) == nil)

      # The guards saw reviewed heads only: no review round, no page.
      assert StubAutoResumeDispatcher.resumes() == []
      assert StubAutoResumeDispatcher.escalations() == []
    end

    test "a pipeline that ran on another commit never authorises the merge", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      w = board_in_order(~w(a), workspace(forge), heads)
      ca = car(w["a"])

      StubMerger.set_car_status(ca.sha, %{
        id: 1,
        sha: String.duplicate("e", 40),
        status: "success",
        url: "u"
      })

      after_polls(w["a"], 6)
      assert StubMerger.merge_count(mr("a")) == 0
    end
  end

  describe "a red car" do
    test "holds behind a car still running, then ejects only its MR; the cars behind are rebuilt",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b c))
      w = board_in_order(~w(a b c), workspace(forge), heads)
      ca = car(w["a"])
      cb = car(w["b"])
      cc = car(w["c"])

      # A's verdict is not in: B's failure may be A's, so B holds.
      StubMerger.set_car_status(cb.sha, "failed")
      after_polls(w["b"], 5)
      assert car(w["b"]) == cb
      assert StubMerger.car_cancels() == []

      # A goes green and merges; B, now first and red, is ejected.
      StubMerger.set_car_status(ca.sha, "success")
      assert_receive {:watchdog, "a", {:merged, _}}, 8_000
      wait_until(fn -> :sys.get_state(w["b"]).train_ejected_head == heads["b"] end)
      wait_until(fn -> TrainForge.head(forge, "arbiter/train/b") == nil end)

      # B goes back to its normal path: synced with main, its own CI decides.
      wait_until(fn -> StubMerger.update_branch_count(mr("b")) == 1 end)

      # C is rebuilt on main (which now carries A), and its old pipeline cancelled.
      wait_until(fn -> car(w["c"]).sha != cc.sha end)
      new_c = car(w["c"])
      assert Enum.any?(StubMerger.car_cancels(), &(&1.sha == cc.sha))
      main_now = TrainForge.head(forge, "main")
      assert TrainForge.parents(forge, new_c.sha) == [main_now, heads["c"]]

      StubMerger.set_car_status(new_c.sha, "success")
      assert_receive {:watchdog, "c", {:merged, _}}, 8_000
      assert TrainForge.tree(forge, "main") == new_c.tree
      assert StubMerger.merge_count(mr("b")) == 0
    end
  end

  describe "an ejected MR's fix path" do
    test "a fix pass on its own red CI is briefed with the car's pipeline", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      {:ok, red?} = Agent.start_link(fn -> false end)

      # After the ejection the MR is synced and its own CI goes red.
      StubMerger.queue_get(mr("a"), [
        fn ->
          if Agent.get(red?, & &1),
            do: %{
              status: :open,
              approved: true,
              block_reason: :ci_failed,
              pipeline: :failed,
              head_sha: heads["a"],
              base_ref: "main"
            },
            else: %{
              status: :open,
              approved: true,
              ci_clean: true,
              pipeline: :success,
              head_sha: heads["a"],
              base_ref: "main"
            }
        end
      ])

      StubMerger.set_failing_checks(mr("a"), [%{name: "unit", summary: "1 failure in lib/x.ex"}])

      w = board_in_order(~w(a), workspace(forge), heads)
      StubMerger.set_car_status(car(w["a"]).sha, "failed")
      wait_until(fn -> :sys.get_state(w["a"]).train_ejected_head == heads["a"] end)

      # Its own pipeline now decides (and is current: the sync landed).
      Application.put_env(:arbiter, :merge_freshness_probe, fn _r, _b, _h -> {:ok, 0} end)
      Agent.update(red?, fn _ -> true end)

      wait_until(fn -> StubFixPassDispatcher.call_count() >= 1 end)
      checks = StubFixPassDispatcher.last_args().checks
      assert Enum.any?(checks, &(&1.name == "unit"))

      assert %{summary: summary} =
               Enum.find(checks, &(&1.name == "merge-train car arbiter/train/a"))

      assert summary =~ "pipeline"
      assert summary =~ "failed"
    end
  end

  describe "hold-on-red-target (bd-5owt7w)" do
    test "no car is built while the target is red, and a red car is held, not ejected",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b))
      ws = workspace(forge)

      red_target =
        {:ok,
         %{
           id: 9,
           sha: "f00",
           status: "failed",
           url: "u",
           jobs: [%{name: "test", stage: "test", status: "failed"}]
         }}

      StubMerger.set_branch_pipeline(red_target)
      a = watch("a", ws, heads["a"])
      after_polls(a, 5)
      assert StubMerger.car_runs() == []

      StubMerger.set_branch_pipeline({:ok, %{id: 10, sha: "f01", status: "success", url: "u"}})
      wait_until(fn -> car(a) != nil end)
      b = watch("b", ws, heads["b"])
      wait_until(fn -> car(b) != nil end)
      ca = car(a)

      # Main goes red, then A's car fails: the failure may be main's.
      StubMerger.set_branch_pipeline(red_target)
      StubMerger.set_car_status(ca.sha, "failed")
      after_polls(a, 5)
      assert car(a) == ca
      assert :sys.get_state(a).train_ejected_head == nil

      # Main is green again: A's car is rebuilt on the new main, not ejected.
      fixed = TrainForge.advance_main!(forge, "fix.txt", "main fixed\n")
      StubMerger.set_branch_pipeline({:ok, %{id: 11, sha: fixed, status: "success", url: "u"}})
      wait_until(fn -> car(a).sha != ca.sha end)
      assert TrainForge.parents(forge, car(a).sha) == [fixed, heads["a"]]
      assert :sys.get_state(a).train_ejected_head == nil
    end

    test "a failed deploy job on a car does not make it red (bd-dtbsgx)", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      w = board_in_order(~w(a), workspace(forge), heads)
      ca = car(w["a"])

      StubMerger.set_car_status(ca.sha, %{
        id: 1,
        sha: ca.sha,
        status: "failed",
        url: "u",
        jobs: [
          %{name: "test", stage: "test", status: "success"},
          %{name: "deploy-review", stage: "deploy", status: "failed"}
        ]
      })

      assert_receive {:watchdog, "a", {:merged, _}}, 8_000
      assert TrainForge.tree(forge, "main") == ca.tree
    end
  end

  describe "CI backpressure (#1126)" do
    test "while the CI queue is saturated only the front car is built", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b c))
      {:ok, gate} = Agent.start_link(fn -> {:hold, "6 pending, oldest 42m"} end)
      backpressure = fn _ws, _repo -> Agent.get(gate, & &1) end
      ws = workspace(forge)

      a = watch("a", ws, heads["a"], ci_backpressure: backpressure)
      wait_until(fn -> car(a) != nil end)
      b = watch("b", ws, heads["b"], ci_backpressure: backpressure)
      c = watch("c", ws, heads["c"], ci_backpressure: backpressure)
      after_polls(b, 5)
      after_polls(c, 5)

      assert length(StubMerger.car_runs()) == 1
      assert car(b) == nil
      assert car(c) == nil

      Agent.update(gate, fn _ -> :ok end)
      wait_until(fn -> car(b) != nil and car(c) != nil end)
      assert length(StubMerger.car_runs()) == 3
    end
  end

  describe "ReviewGate coverage" do
    test "an authored push after the car was built is never merged on that car",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b c))
      w = board_in_order(~w(a b c), workspace(forge), heads)
      cb = car(w["b"])
      cc = car(w["c"])

      # Someone pushes to B after its car was built and before it merged.
      pushed = TrainForge.push_to!(forge, branch("b"), "b2.txt", "unreviewed\n")
      StubMerger.set_car_status(cb.sha, "success")

      # The unreviewed head goes to a review round; B leaves the train.
      assert_receive {:watchdog, "b", {:unreviewed_head, ^pushed}}, 8_000
      wait_until(fn -> TrainForge.head(forge, "arbiter/train/b") == nil end)
      assert StubMerger.merge_count(mr("b")) == 0

      # C stood on B's car: it is rebuilt without it.
      wait_until(fn -> car(w["c"]).sha != cc.sha end)
      refute TrainForge.contains?(forge, car(w["c"]).sha, heads["b"])
    end
  end

  describe "a car that is not a non-authored merge" do
    test "is never merged on: its proof fails and it is rebuilt", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      w = board_in_order(~w(a), workspace(forge), heads)
      honest = car(w["a"])

      # Its commit swapped for one with the same parents and a smuggled file,
      # and that commit's pipeline green.
      {forged, forged_tree} = TrainForge.forge_car!(forge, honest, "smuggled.txt", "unreviewed\n")
      StubMerger.set_car_status(forged, "success")

      :sys.replace_state(w["a"], fn s ->
        %{s | train_car: %{honest | sha: forged, tree: forged_tree}, train_car_status: :running}
      end)

      # Rebuilt as what it should be (cars are deterministic), never merged on.
      wait_until(fn -> car(w["a"]).sha == honest.sha end)
      after_polls(w["a"], 3)
      assert StubMerger.merge_count(mr("a")) == 0
      refute TrainForge.contains?(forge, TrainForge.head(forge, "main"), forged)
    end
  end

  describe "restart" do
    test "the train survives a server restart without double-merging or skipping a car",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b c))
      ws = workspace(forge)
      t1 = start_supervised!({MergeTrain, name: nil, settle_ms: 0}, id: :before_restart)

      w = board_in_order(~w(a b c), ws, heads, merge_train: t1)
      cars = Map.new(w, fn {id, pid} -> {id, car(pid)} end)
      since = Map.new(w, fn {id, pid} -> {id, :sys.get_state(pid).train_ready_since} end)
      StubMerger.set_car_status(cars["b"].sha, "success")
      runs = length(StubMerger.car_runs())

      # The server goes down: every Watchdog and the train with it.
      for {_id, pid} <- w, do: Process.exit(pid, :kill)
      :ok = stop_supervised(:before_restart)

      # Back up: a fresh train, forming; the Watchdogs come back from their
      # lanes (the car recorded there), slowest first.
      t2 = start_supervised!({MergeTrain, name: nil, settle_ms: :infinity}, id: :after_restart)

      restarted =
        for id <- ~w(c b a), into: %{} do
          lane_car = Map.new(cars[id], fn {k, v} -> {Atom.to_string(k), v} end)

          {id,
           watch(id, ws, heads[id],
             merge_train: t2,
             train_car: lane_car,
             train_ready_since: since[id]
           )}
        end

      # B's car is green, but A's is still running: B does not merge first.
      after_polls(restarted["b"], 6)
      assert StubMerger.merge_count(mr("b")) == 0
      assert MergeTrain.seats({ws.id, "app", "main"}, t2) |> Enum.map(& &1.task_id) == ~w(a b c)

      :ok = MergeTrain.settle_now(t2)
      StubMerger.set_car_status(cars["a"].sha, "success")
      StubMerger.set_car_status(cars["c"].sha, "success")

      for id <- ~w(a b c), do: assert_receive({:watchdog, ^id, {:merged, _}}, 8_000)

      # Each merged exactly once, in order, on the cars built before the restart.
      assert StubMerger.merges_in_order() == Enum.map(~w(a b c), &{mr(&1), heads[&1]})
      assert length(StubMerger.car_runs()) == runs
      assert TrainForge.tree(forge, "main") == cars["c"].tree
    end

    test "a car merged just before the restart is not merged again, and the next goes on",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a b))
      ws = workspace(forge)
      t1 = start_supervised!({MergeTrain, name: nil, settle_ms: 0}, id: :before_merge_restart)

      w = board_in_order(~w(a b), ws, heads, merge_train: t1)
      cars = Map.new(w, fn {id, pid} -> {id, car(pid)} end)
      StubMerger.set_car_status(cars["b"].sha, "success")

      # A's merge landed, and the server died before its Watchdog saw it.
      for {_id, pid} <- w, do: Process.exit(pid, :kill)
      :ok = stop_supervised(:before_merge_restart)
      TrainForge.merge!(forge, heads["a"])
      StubMerger.merge("!a", heads["a"])

      t2 = start_supervised!({MergeTrain, name: nil, settle_ms: 0}, id: :after_merge_restart)

      for id <- ~w(b a) do
        lane_car = Map.new(cars[id], fn {k, v} -> {Atom.to_string(k), v} end)
        watch(id, ws, heads[id], merge_train: t2, train_car: lane_car)
      end

      assert_receive {:watchdog, "a", {:merged, _}}, 8_000
      assert_receive {:watchdog, "b", {:merged, _}}, 8_000
      assert StubMerger.merge_count(mr("a")) == 1
      assert StubMerger.merge_count(mr("b")) == 1
      assert TrainForge.tree(forge, "main") == cars["b"].tree
    end
  end

  describe "the rebuild bound (I1)" do
    test "a car the target keeps moving under is rebuilt a bounded number of times",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      a = watch("a", workspace(forge), heads["a"])
      wait_until(fn -> car(a) != nil end)

      # Something else lands on main every time the car is rebuilt.
      Enum.reduce_while(1..10, car(a).sha, fn i, last ->
        TrainForge.advance_main!(forge, "busy#{i}.txt", "#{i}\n")

        wait_until(fn ->
          :sys.get_state(a).train_ejected_head == heads["a"] or
            (car(a) != nil and car(a).sha != last)
        end)

        case car(a) do
          %{sha: sha} -> {:cont, sha}
          nil -> {:halt, :ejected}
        end
      end)

      # The first build and five rebuilds; the next one sends it to the serial path.
      wait_until(fn -> :sys.get_state(a).train_ejected_head == heads["a"] end)
      assert length(StubMerger.car_runs()) == 6
      wait_until(fn -> StubMerger.update_branch_count(mr("a")) == 1 end)
    end
  end

  describe "back on the train" do
    test "an MR riding a car again gives up the serial sync place it held", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      ws = workspace(forge)
      key = {ws.id, "app", "main"}

      # A holds the serial place (as after an ejection's sync) when it boards.
      claim = %{task_id: "a", status: :behind_base, priority: 2, last_head_sha: heads["a"]}
      assert :head = MergeTrain.claim(key, claim)
      a = watch("a", ws, heads["a"], initial_delay_ms: 200)

      evidence = %{
        head: "old",
        ref: "arbiter/train/a",
        car: nil,
        base: nil,
        url: nil,
        reason: "x"
      }

      :sys.replace_state(a, &%{&1 | train_role: :head, train_eject_evidence: evidence})

      wait_until(fn -> car(a) != nil end)
      assert MergeTrain.view(key).head == nil
      assert :sys.get_state(a).train_role == nil
      # The evidence of an earlier ejection is not this car's to brief a fix pass with.
      assert :sys.get_state(a).train_eject_evidence == nil
    end
  end

  describe "falling back to the serial train" do
    test "a project whose CI refuses car pipelines syncs the MR instead", %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))

      StubMerger.set_run_ref_result(
        {:error, %{kind: :pipeline_refused, message: "workflow rules"}}
      )

      a = watch("a", workspace(forge), heads["a"])
      wait_until(fn -> StubMerger.update_branch_count(mr("a")) == 1 end)
      assert :sys.get_state(a).train_ejected_head == heads["a"]
      assert TrainForge.head(forge, "arbiter/train/a") == nil
    end

    test "an MR within up_to_date_tolerance at the front merges on its own pipeline",
         %{forge: forge} do
      heads = stale_mrs(forge, ~w(a))
      watch("a", workspace(forge, %{"up_to_date_tolerance" => 1}), heads["a"])

      assert_receive {:watchdog, "a", {:merged, _}}, 8_000
      assert StubMerger.car_runs() == []
    end
  end
end
