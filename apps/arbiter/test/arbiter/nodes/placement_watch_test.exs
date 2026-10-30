defmodule Arbiter.Nodes.PlacementWatchTest do
  @moduledoc """
  bd-cch1jh: every remote placement attempt is registered, logged at its start and at
  its outcome (placed, refused with its reason, or timed out), and bounded by one
  deadline over everything the primary does for it (its own half *and* the node's
  answer), so a step that never returns can no longer hold a run in `placing` for ever.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Arbiter.Nodes.PlacementWatch

  @node %{id: "node-1", name: "mesaana"}

  # The suite logs at :warning; the start and placed lines are :info.
  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
  end

  defp begin(opts \\ []) do
    PlacementWatch.begin(
      Keyword.merge([task_id: "bd-abc123", node: @node, run: "run-1", timeout_ms: 5_000], opts)
    )
  end

  describe "logging" do
    test "an attempt logs its start and a placed outcome with task, node and run" do
      log =
        capture_log([level: :info], fn ->
          attempt = begin()
          assert {:ok, :handle} = PlacementWatch.step(attempt, :assign, fn -> {:ok, :handle} end)
          assert {:ok, :handle} = PlacementWatch.finish(attempt, {:ok, :handle})
        end)

      assert log =~ "placement started"
      assert log =~ "task=bd-abc123"
      assert log =~ "node=mesaana"
      assert log =~ "run=run-1"
      assert log =~ "placement placed"
    end

    test "a refusal logs its reason and detail" do
      log =
        capture_log([level: :info], fn ->
          attempt = begin()
          result = {:error, {:remote_placement_failed, {:refused, "unschedulable", "no room"}}}
          assert ^result = PlacementWatch.finish(attempt, result)
        end)

      assert log =~ "placement refused"
      assert log =~ "unschedulable"
      assert log =~ "no room"
      assert log =~ "task=bd-abc123"
    end

    test "any other failure is logged as failed with its reason" do
      log =
        capture_log([level: :info], fn ->
          attempt = begin()
          PlacementWatch.finish(attempt, {:error, {:egress_unavailable, :boom}})
        end)

      assert log =~ "placement failed"
      assert log =~ "egress_unavailable"
    end
  end

  describe "the deadline" do
    test "a step that never returns times out, is logged, and returns a placement error" do
      log =
        capture_log([level: :info], fn ->
          attempt = begin(timeout_ms: 50)

          assert {:error, {:remote_placement_failed, {:placement_timeout, :assign, 50}}} =
                   result =
                   PlacementWatch.step(attempt, :assign, fn -> Process.sleep(:infinity) end)

          assert ^result = PlacementWatch.finish(attempt, result)
        end)

      assert log =~ "placement timed out"
      assert log =~ "task=bd-abc123"
      assert log =~ "node=mesaana"
      assert log =~ "stage=assign"
    end

    test "the deadline spans the steps: time spent in one is not given again to the next" do
      attempt = begin(timeout_ms: 150)
      assert :ok = PlacementWatch.step(attempt, :prepare, fn -> Process.sleep(100) && :ok end)

      assert {:error, {:remote_placement_failed, {:placement_timeout, :assign, 150}}} =
               PlacementWatch.step(attempt, :assign, fn -> Process.sleep(:infinity) end)
    end

    test "the step runs in a task that is killed when it times out" do
      attempt = begin(timeout_ms: 50)
      parent = self()

      PlacementWatch.step(attempt, :assign, fn ->
        send(parent, {:task, self()})
        Process.sleep(:infinity)
      end)

      assert_received {:task, pid}
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
    end

    test "an :infinity timeout runs the step inline, unbounded" do
      attempt = begin(timeout_ms: :infinity)
      caller = self()
      assert ^caller = PlacementWatch.step(attempt, :assign, fn -> self() end)
    end

    test "a step that raises still raises in the caller" do
      attempt = begin()

      assert_raise RuntimeError, "boom", fn ->
        PlacementWatch.step(attempt, :assign, fn -> raise "boom" end)
      end
    end

    test "the configured timeout is read from :node_placement" do
      previous = Application.get_env(:arbiter, :node_placement)
      Application.put_env(:arbiter, :node_placement, placement_timeout_ms: 1234)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter, :node_placement, previous),
          else: Application.delete_env(:arbiter, :node_placement)
      end)

      assert PlacementWatch.timeout_ms() == 1234
    end
  end

  describe "watch/4 (bd-3jjt3p)" do
    test "a spawn that hangs outside any step is ended by the attempt-level timer" do
      previous = Application.get_env(:arbiter, :node_placement)
      Application.put_env(:arbiter, :node_placement, placement_timeout_ms: 100)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:arbiter, :node_placement, previous),
          else: Application.delete_env(:arbiter, :node_placement)
      end)

      log =
        capture_log(fn ->
          assert {:error, {:remote_placement_failed, {:placement_timeout, :start, 100}}} =
                   PlacementWatch.watch(
                     @node,
                     "bd-gap001",
                     fn -> {:ok, []} end,
                     fn opts ->
                       assert %PlacementWatch{} = Keyword.fetch!(opts, :placement_attempt)
                       Process.sleep(:infinity)
                     end
                   )
        end)

      assert log =~ "placement timed out task=bd-gap001"
      assert [] = Enum.filter(PlacementWatch.in_flight(), &(&1.task_id == "bd-gap001"))
    end

    test "a build that overruns is a build error, a start error is the start's" do
      attempt_opts = fn -> {:ok, [x: 1]} end

      assert {:build_error, :nope} =
               PlacementWatch.watch(@node, "bd-b1", fn -> {:error, :nope} end, & &1)

      assert {:error, :refused} =
               PlacementWatch.watch(@node, "bd-b2", attempt_opts, fn _ -> {:error, :refused} end)

      assert {:ok, :port} =
               PlacementWatch.watch(nil, "bd-b3", attempt_opts, fn _ -> {:ok, :port} end)
    end
  end

  describe "in-flight attempts (what doctor reports)" do
    test "an attempt is listed until it finishes" do
      attempt = begin()
      assert [entry] = Enum.filter(PlacementWatch.in_flight(), &(&1.task_id == "bd-abc123"))
      assert %{node_name: "mesaana", node_id: "node-1", run: "run-1", stage: :started} = entry

      PlacementWatch.finish(attempt, {:ok, :handle})
      assert [] = Enum.filter(PlacementWatch.in_flight(), &(&1.task_id == "bd-abc123"))
    end

    test "the stage follows the step being run" do
      attempt = begin()
      test = self()

      PlacementWatch.step(attempt, :assign, fn ->
        send(test, {:stage, Enum.find(PlacementWatch.in_flight(), &(&1.task_id == "bd-abc123"))})
      end)

      assert_received {:stage, %{stage: :assign}}
      PlacementWatch.finish(attempt, {:ok, :handle})
    end

    test "stuck/1 names the attempts older than the timeout" do
      attempt = begin(timeout_ms: 20)
      Process.sleep(60)

      assert [%{task_id: "bd-abc123", age_ms: age, timeout_ms: 20}] =
               Enum.filter(PlacementWatch.stuck(), &(&1.task_id == "bd-abc123"))

      assert age >= 20
      PlacementWatch.finish(attempt, {:ok, :handle})
      assert [] = Enum.filter(PlacementWatch.stuck(), &(&1.task_id == "bd-abc123"))
    end

    test "stuck_runs/2 names a run left in placing past the timeout, whatever step it is stuck in" do
      long_ago = DateTime.add(DateTime.utc_now(), -3_600, :second)

      snap = fn task_id, attrs ->
        Map.merge(
          %{
            task_id: task_id,
            run_id: "run-" <> task_id,
            state: :starting,
            started_at: long_ago,
            meta: %{placed_node_id: "node-1"}
          },
          attrs
        )
      end

      snaps = [
        snap.("bd-placing", %{}),
        # young: inside the budget
        snap.("bd-young", %{started_at: DateTime.utc_now()}),
        # the agent started on the node: no longer placing
        snap.("bd-started", %{meta: %{placed_node_id: "node-1", node_id: "node-1"}}),
        snap.("bd-working", %{state: :working}),
        # a local run
        snap.("bd-local", %{meta: %{}})
      ]

      assert [
               %{task_id: "bd-placing", node_id: "node-1", run: "run-bd-placing", age_ms: age} =
                 entry
             ] =
               PlacementWatch.stuck_runs(snaps, 60_000)

      assert age >= 3_600_000
      assert entry.stage == :placing
      assert entry.timeout_ms == 60_000

      assert [] = PlacementWatch.stuck_runs(snaps, :infinity)
    end

    test "an attempt whose process dies is dropped" do
      test = self()

      pid =
        spawn(fn ->
          begin(task_id: "bd-dead01")
          send(test, :registered)
          Process.sleep(:infinity)
        end)

      assert_receive :registered
      assert Enum.any?(PlacementWatch.in_flight(), &(&1.task_id == "bd-dead01"))

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      _ = :sys.get_state(PlacementWatch)
      refute Enum.any?(PlacementWatch.in_flight(), &(&1.task_id == "bd-dead01"))
    end
  end
end
