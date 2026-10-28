defmodule Arbiter.DrainTaskSupervisorTest do
  @moduledoc """
  bd-5ljhfg: `DataCase.drain_task_supervisor/2` used to wait the full 5s for a
  child that never exits and then leave it running, so a single leaked
  `Arbiter.TaskSupervisor` task cost every later DataCase test 5s. It now kills
  the stuck child after the wait and logs its initial call.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  test "kills and logs a child that never exits, instead of leaving it for later tests" do
    sup = :"drain_sup_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: sup})

    {:ok, stuck} =
      Task.Supervisor.start_child(sup, fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(stuck)

    log = capture_log(fn -> Arbiter.DataCase.drain_task_supervisor(sup, 50) end)

    assert_received {:DOWN, ^ref, :process, ^stuck, :killed}
    assert Task.Supervisor.children(sup) == []
    assert log =~ "did not exit within 50ms"
    assert log =~ "initial_call"
  end

  test "returns promptly without logging when children exit on their own" do
    sup = :"drain_sup_#{System.unique_integer([:positive])}"
    start_supervised!({Task.Supervisor, name: sup})
    test = self()

    {:ok, child} =
      Task.Supervisor.start_child(sup, fn ->
        receive do
          :go -> send(test, :done)
        end
      end)

    send(child, :go)

    log = capture_log(fn -> Arbiter.DataCase.drain_task_supervisor(sup, 5_000) end)
    assert log == ""
  end
end
