defmodule Arbiter.NodeAgent.K8s.EventFollowerTest do
  # The `LogFollower` in event mode (bd-1nl506): the run's output is the NDJSON the pod
  # ships (byte-offset chunks), never the kubelet's log, so a line the kubelet drops,
  # reorders or re-stamps changes nothing. Frames, cursors, acks, window and re-attach are
  # the follower's own, as for the log.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.LogFollower
  alias Arbiter.Nodes.StdoutFrame

  @run "run-1"

  defp follower(opts \\ []) do
    me = self()

    {:ok, pid} =
      LogFollower.start(
        [
          run: @run,
          pod: "pod-1",
          source: :events,
          client: nil,
          owner: me,
          emit: fn frame -> send(me, {:frame, frame}) end,
          final_wait_ms: 100
        ] ++ opts
      )

    on_exit(fn -> if Process.alive?(pid), do: LogFollower.stop(pid) end)
    pid
  end

  defp frame! do
    assert_receive {:frame, frame}, 2_000
    assert {:ok, @run, {:cursor, cursor}, bytes} = StdoutFrame.decode(frame)
    {cursor, bytes}
  end

  test "lines of a shipped chunk become frames whose cursor is the offset after the line" do
    pid = follower(frame_bytes: 4)
    assert {:ok, 8} = LogFollower.push_events(pid, 0, "one\ntwo\n", false)

    assert {"e4", "one\n"} = frame!()
    assert {"e8", "two\n"} = frame!()
    assert LogFollower.position(pid) == "e8"
  end

  test "a retried chunk is not emitted twice and a gap is refused with the offset wanted" do
    pid = follower()
    assert {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    assert {"e4", "one\n"} = frame!()

    assert {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    assert {:gap, 4} = LogFollower.push_events(pid, 99, "zzz\n", false)
    refute_receive {:frame, _}, 50
  end

  test "resumes at the offset of the cursor it is started with" do
    pid = follower(cursor: "e4")
    assert {:gap, 4} = LogFollower.push_events(pid, 9, "x\n", false)
    assert {:ok, 8} = LogFollower.push_events(pid, 4, "two\n", false)
    assert {"e8", "two\n"} = frame!()
  end

  test "an upload waits while the window of unacknowledged bytes is full" do
    pid = follower(window_bytes: 4, frame_bytes: 4)
    assert {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    {c1, _} = frame!()

    task = Task.async(fn -> LogFollower.push_events(pid, 4, "two\n", false) end)
    refute_receive {:frame, _}, 100
    LogFollower.ack(pid, c1)
    assert {:ok, 8} = Task.await(task)
    assert {"e8", "two\n"} = frame!()
  end

  test "a second upload while one is held answers busy" do
    pid = follower(window_bytes: 4, frame_bytes: 4)
    {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    {_c1, _} = frame!()
    task = Task.async(fn -> LogFollower.push_events(pid, 4, "two\n", false) end)
    refute_receive {:frame, _}, 50
    assert {:busy, 8} = LogFollower.push_events(pid, 8, "three\n", false)
    Task.shutdown(task, :brutal_kill)
  end

  test "an attach resends only what the primary lacks" do
    pid = follower(frame_bytes: 4)
    {:ok, 12} = LogFollower.push_events(pid, 0, "one\ntwo\nthr\n", false)
    {c1, _} = frame!()
    {_, _} = frame!()
    {c3, _} = frame!()

    LogFollower.attach(pid, c1)
    assert {"e8", "two\n"} = frame!()
    assert {^c3, "thr\n"} = frame!()
  end

  test "drains once the worker has ended and the pod sent its final chunk" do
    pid = follower()
    {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    {_, _} = frame!()
    LogFollower.finish(pid)
    refute_receive {:log_drained, _, _}, 50

    assert {:ok, 8} = LogFollower.push_events(pid, 4, "end\n", true)
    assert_receive {:log_drained, @run, "e8"}, 2_000
    assert {"e8", "end\n"} = frame!()
    refute_receive {:log_truncated, _, _}, 50
  end

  test "a final chunk that arrives before the worker is seen to end drains on finish" do
    pid = follower()
    {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", true)
    refute_receive {:log_drained, _, _}, 50
    LogFollower.finish(pid)
    assert_receive {:log_drained, @run, "e4"}, 2_000
  end

  test "a pod that never sends a final chunk drains after the wait, without its partial line" do
    pid = follower(final_wait_ms: 50)
    {:ok, 17} = LogFollower.push_events(pid, 0, "one\n{\"type\":\"resu", false)
    {"e4", "one\n"} = frame!()
    LogFollower.finish(pid)

    assert_receive {:log_truncated, @run, 13}, 2_000
    assert_receive {:log_drained, @run, "e4"}, 2_000
    refute_receive {:frame, _}, 50
  end

  test "a final chunk ending mid-line reports the truncation and emits no partial line" do
    pid = follower()
    {:ok, _} = LogFollower.push_events(pid, 0, "one\n{\"type\":\"resu", true)
    LogFollower.finish(pid)
    assert_receive {:log_truncated, @run, 13}, 2_000
    assert_receive {:log_drained, @run, "e4"}, 2_000
    assert {"e4", "one\n"} = frame!()
    refute_receive {:frame, _}, 50
  end

  test "a run with no output drains to a nil cursor" do
    pid = follower()
    LogFollower.finish(pid)
    {:ok, 0} = LogFollower.push_events(pid, 0, "", true)
    assert_receive {:log_drained, @run, nil}, 2_000
  end
end
