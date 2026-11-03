defmodule Arbiter.NodeAgent.K8s.EventFeedSilentTest do
  # bd-db8ez4: a pod annotated for the event feed whose feed delivers nothing (the wrapper
  # cannot reach `/events`, or never started) used to lose the whole run: the follower waited
  # for chunks that never came and the run ended with no output and no done signal. Such a
  # follower now falls back to the kubelet log, which carries the same bytes, and says so.
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

  defp follower(env, opts) do
    me = self()

    {:ok, pid} =
      LogFollower.start(
        [
          run: @run,
          pod: @pod,
          source: :events,
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

  test "a live worker whose feed stays silent is read from the log instead", %{api: api} = env do
    FakeK8sApi.push_log(api, @pod, "one")
    pid = follower(env, silent_ms: 50, final_wait_ms: 5_000)

    assert_receive {:event_feed_silent, @run}, 2_000
    assert {c1, "one\n"} = frame!()
    refute String.starts_with?(c1, "e")

    FakeK8sApi.push_log(api, @pod, "two")
    assert {_, "two\n"} = frame!()

    # a feed that wakes up late is told it was taken, and is not emitted twice
    assert {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    refute_receive {:frame, _}, 100
  end

  test "a worker that ends without its feed ever speaking has its log tail drained",
       %{api: api} =
         env do
    FakeK8sApi.push_log(api, @pod, "one")
    FakeK8sApi.push_log(api, @pod, "arb done")
    pid = follower(env, silent_ms: 60_000, final_wait_ms: 50)
    LogFollower.finish(pid)

    assert_receive {:event_feed_silent, @run}, 2_000
    assert_receive {:log_drained, @run, cursor}, 2_000
    assert {^cursor, "one\narb done\n"} = frame!()
  end

  test "a feed that has spoken is never replaced by the log", %{api: api} = env do
    FakeK8sApi.push_log(api, @pod, "from the log")
    pid = follower(env, silent_ms: 50, final_wait_ms: 50)
    assert {:ok, 4} = LogFollower.push_events(pid, 0, "one\n", false)
    assert {"e4", "one\n"} = frame!()

    refute_receive {:event_feed_silent, _}, 200
    LogFollower.finish(pid)
    assert_receive {:log_drained, @run, "e4"}, 2_000
    refute_receive {:event_feed_silent, _}, 50
    refute_receive {:frame, _}, 50
  end

  test "an empty final chunk is a feed that spoke: a run with no output is not a failure" do
    env = FakeK8sApi.start!(namespace: "arb")
    pid = follower(env, silent_ms: 50, final_wait_ms: 50)
    assert {:ok, 0} = LogFollower.push_events(pid, 0, "", true)
    LogFollower.finish(pid)

    assert_receive {:log_drained, @run, nil}, 2_000
    refute_receive {:event_feed_silent, _}, 100
  end
end
