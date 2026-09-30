defmodule Arbiter.Repo.OptimizeSweeperTest do
  use Arbiter.DataCase, async: false

  import ExUnit.CaptureLog
  alias Arbiter.Repo.OptimizeSweeper

  describe "child_spec/1" do
    test "has expected defaults" do
      spec = OptimizeSweeper.child_spec([])
      assert spec.id == OptimizeSweeper
      assert spec.type == :worker
    end
  end

  setup do
    Logger.put_module_level(OptimizeSweeper, :info)
    Logger.put_module_level(Arbiter.Boot.Optimize, :info)

    on_exit(fn ->
      Logger.delete_module_level(OptimizeSweeper)
      Logger.delete_module_level(Arbiter.Boot.Optimize)
    end)
  end

  describe "sweep_now/1" do
    test "runs PRAGMA optimize on primary instance and logs" do
      log =
        capture_log(fn ->
          pid =
            start_supervised!(
              {OptimizeSweeper, name: nil, enabled: false, primary?: fn -> true end}
            )

          assert :ok = OptimizeSweeper.sweep_now(pid)
        end)

      assert log =~ "PRAGMA optimize"
    end

    test "skips when not primary instance" do
      log =
        capture_log(fn ->
          pid =
            start_supervised!(
              {OptimizeSweeper, name: nil, enabled: false, primary?: fn -> false end}
            )

          assert :ok = OptimizeSweeper.sweep_now(pid)
        end)

      assert log =~ "not the primary instance"
    end
  end

  describe "tick scheduling" do
    test "executes sweep on :sweep message" do
      log =
        capture_log(fn ->
          pid =
            start_supervised!(
              {OptimizeSweeper,
               name: nil, enabled: true, interval_ms: 3_600_000, primary?: fn -> true end}
            )

          send(pid, :sweep)
          _ = :sys.get_state(pid)
        end)

      assert log =~ "PRAGMA optimize"
    end
  end
end
