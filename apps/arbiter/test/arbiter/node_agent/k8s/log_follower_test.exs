defmodule Arbiter.NodeAgent.K8s.LogFollowerTest do
  # The `pods/log` follower against the fake API server: lines become `ARB2` frames with
  # unique cursors, the window of unacknowledged bytes is TCP's backpressure, an attach
  # resends only what the primary lacks, and the tail is drained after the worker ends.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.LogFollower
  alias Arbiter.Nodes.StdoutFrame
  alias Arbiter.Test.FakeK8sApi

  @run "run-1"
  @pod "pod-1"

  setup do
    env = FakeK8sApi.start!(namespace: "arb")
    FakeK8sApi.put_pod(env.api, %{"metadata" => %{"name" => @pod, "labels" => %{}}})
    {:ok, env}
  end

  defp follower(env, opts \\ []) do
    me = self()

    {:ok, pid} =
      LogFollower.start(
        [
          run: @run,
          pod: @pod,
          client: env.client,
          owner: me,
          emit: fn frame -> send(me, {:frame, frame}) end,
          retry_ms: 10
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

  test "streams each line as a frame whose cursor names the line", %{api: api} = env do
    FakeK8sApi.push_log(api, @pod, "one")
    pid = follower(env, frame_bytes: 4)
    FakeK8sApi.push_log(api, @pod, "two")

    assert {c1, "one\n"} = frame!()
    assert {c2, "two\n"} = frame!()
    assert c1 != c2
    assert LogFollower.position(pid) == c2
  end

  test "packs the lines of one read into frames of at most frame_bytes", %{api: api} = env do
    for text <- ~w(aa bb cc), do: FakeK8sApi.push_log(api, @pod, text)
    follower(env, frame_bytes: 6)

    assert {_, "aa\nbb\n"} = frame!()
    assert {_, "cc\n"} = frame!()
  end

  test "stops reading while the window of unacknowledged bytes is full", %{api: api} = env do
    for text <- ~w(aa bb cc), do: FakeK8sApi.push_log(api, @pod, text)
    pid = follower(env, frame_bytes: 3, window_bytes: 6)

    assert {c1, "aa\n"} = frame!()
    assert {_c2, "bb\n"} = frame!()
    refute_receive {:frame, _}, 100

    LogFollower.ack(pid, c1)
    assert {_c3, "cc\n"} = frame!()
  end

  test "an attach trims what the primary has and resends the rest", %{api: api} = env do
    for text <- ~w(aa bb cc), do: FakeK8sApi.push_log(api, @pod, text)
    pid = follower(env, frame_bytes: 3)
    {c1, _} = frame!()
    {_c2, _} = frame!()
    {c3, _} = frame!()
    assert c1 != c3

    # the primary took the first two; the third (and its ack) went nowhere
    LogFollower.attach(pid, c1)
    assert {_, "bb\n"} = frame!()
    assert {^c3, "cc\n"} = frame!()
    refute_receive {:frame, _}, 50
  end

  test "resumes after the cursor it is started with", %{api: api} = env do
    c1 = FakeK8sApi.push_log(api, @pod, "one") <> " 1"
    FakeK8sApi.push_log(api, @pod, "two")
    follower(env, cursor: c1)

    assert {_, "two\n"} = frame!()
    refute_receive {:frame, _}, 50
  end

  test "once the worker has ended it drains the tail and reports the final cursor",
       %{api: api} = env do
    FakeK8sApi.push_log(api, @pod, "one")
    pid = follower(env, frame_bytes: 4)
    {c1, "one\n"} = frame!()

    FakeK8sApi.push_log(api, @pod, "last")
    LogFollower.finish(pid)

    assert_receive {:log_drained, @run, final}, 2_000
    assert {^final, "last\n"} = frame!()
    assert final != c1
  end

  test "a run with no output drains to a nil cursor", env do
    pid = follower(env)
    LogFollower.finish(pid)
    assert_receive {:log_drained, @run, nil}, 2_000
  end

  test "a pod that is already gone drains with what was sent", %{api: api} = env do
    FakeK8sApi.push_log(api, @pod, "one")
    pid = follower(env, frame_bytes: 4)
    {c1, _} = frame!()

    FakeK8sApi.delete_pod(api, @pod)
    LogFollower.finish(pid)
    assert_receive {:log_drained, @run, ^c1}, 2_000
  end

  test "a failed follow is retried from the position", %{api: api} = env do
    FakeK8sApi.fail_next(api, :log, 500, 2)
    FakeK8sApi.push_log(api, @pod, "one")
    follower(env)
    assert {_, "one\n"} = frame!()
  end

  test "stops when its owner goes away", env do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, pid} = LogFollower.start(run: @run, pod: @pod, client: env.client, owner: owner)
    ref = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
  end
end
