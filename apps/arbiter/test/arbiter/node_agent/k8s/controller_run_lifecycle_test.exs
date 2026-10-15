defmodule Arbiter.NodeAgent.K8s.ControllerRunLifecycleTest do
  # K15 on the controller core, against the fake API server and the real informer: the
  # worker's log becomes a `stdout` stream, `exit` is held until the snapshotter's final
  # checkpoint and the log tail are in (and carries the stream's end), and a restarted
  # controller picks its runs, their stream and their pod channel up again.
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.Nodes.StdoutFrame
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.FakePodChannel
  alias Arbiter.Test.K8sPodFixtures

  @moduletag :tmp_dir

  @t0 ~U[2026-10-10 12:00:00Z]
  @labels %{"arbiter.dev/install" => "inst-1", "arbiter.dev/node" => "node-1"}
  @scheduled %{"type" => "PodScheduled", "status" => "True"}

  setup %{tmp_dir: dir} do
    env = FakeK8sApi.start!(namespace: "arb")
    config_path = Path.join(dir, "controller.yaml")

    File.write!(config_path, """
    max_concurrent: 2
    timeouts: {schedule_s: 30, grace_s: 120, retain_failed_s: 300}
    """)

    loader =
      start_supervised!(
        {ConfigLoader, path: config_path, interval_ms: nil, notify: nil},
        id: :loader
      )

    channel = start_supervised!(FakePodChannel)
    clock = start_supervised!({Agent, fn -> @t0 end}, id: :clock)
    {:ok, Map.merge(env, %{loader: loader, channel: channel, clock: clock})}
  end

  # -- harness -------------------------------------------------------------------

  defp start_informer(env, id) do
    informer =
      start_supervised!(
        {Informer,
         client: env.client,
         label_selector: Client.label_selector(@labels),
         backoff_ms: {5, 20},
         name: nil},
        id: id
      )

    :ok = Informer.await_sync(informer, 5_000)
    informer
  end

  defp start_controller(env, n \\ 1) do
    informer = start_informer(env, {:informer, n})
    clock = env.clock

    controller =
      start_supervised!(
        {Controller,
         client: env.client,
         informer: informer,
         config_loader: env.loader,
         lease: nil,
         pod_channel: {FakePodChannel, env.channel},
         identity: %{
           registry: K8sPodFixtures.registry(),
           install_id: "inst-1",
           node_id: "node-1",
           owner_uid: "0b6c1d7e-8f35-4a58-9c1f-3d2f1b1c1a11",
           bridge_addr: "10.43.98.199",
           gate_addr: "10.43.0.1:443",
           own_pod: "arbiter-controller-7d9f-abc",
           max_wall_s: 3600
         },
         sink: self(),
         observer: self(),
         now_fun: fn -> Agent.get(clock, & &1) end,
         tick_ms: nil,
         name: nil},
        id: {:controller, n}
      )

    _ = Controller.run_ids(controller)
    controller
  end

  defp stop_controller(n) do
    stop_supervised!({:controller, n})
    stop_supervised!({:informer, n})
  end

  defp advance(env, seconds), do: Agent.update(env.clock, &DateTime.add(&1, seconds, :second))

  defp wire(n) do
    id = "run-" <> Base.encode16(<<n::64>>, case: :lower)

    K8sPodFixtures.wire_spec(%{
      "run" => id,
      "name" => "arb-run-" <> binary_part(Base.encode16(<<n::64>>, case: :lower), 4, 12),
      "image" => %{
        "tag" => "arbiter-dev/beam:abc",
        "plan" => nil,
        "ref" => "#{K8sPodFixtures.registry()}/beam@sha256:#{K8sPodFixtures.digest()}"
      }
    })
  end

  defp run_id(n), do: wire(n)["run"]
  defp pod_name(n), do: wire(n)["name"]

  defp assign!(controller, n) do
    assert {:ok, run} = Controller.assign(controller, wire(n))
    run
  end

  defp set_status(env, n, status) do
    pod = FakeK8sApi.handle(env.api, {:get, pod_name(n)})
    updated = FakeK8sApi.put_pod(env.api, Map.put(pod, "status", status))
    Process.put({:rv, run_id(n)}, updated["metadata"]["resourceVersion"])
    updated
  end

  defp observed(run, :deleted), do: assert_receive({:run_observed, ^run, :deleted, _}, 5_000)

  defp observed(run, tag) do
    rv = Process.get({:rv, run})
    assert_receive {:run_observed, ^run, ^tag, ^rv}, 5_000
  end

  defp running_status do
    %{
      "phase" => "Running",
      "startTime" => "2026-10-10T12:00:05Z",
      "podIP" => "10.42.0.17",
      "conditions" => [@scheduled],
      "containerStatuses" => [
        %{"name" => "worker", "state" => %{"running" => %{"startedAt" => "2026-10-10T12:00:20Z"}}}
      ],
      "initContainerStatuses" => [
        %{"name" => "seed", "state" => %{"terminated" => %{"exitCode" => 0}}},
        %{"name" => "snapshotter", "state" => %{"running" => %{}}}
      ]
    }
  end

  # The worker is done; the snapshotter is `:running` (taking the final snapshot) or has
  # `:complete`d / been `:killed`.
  defp exited_status(snapshotter, code \\ 0) do
    snap =
      case snapshotter do
        :running -> %{"running" => %{}}
        :complete -> %{"terminated" => %{"exitCode" => 0, "reason" => "Completed"}}
        :killed -> %{"terminated" => %{"exitCode" => 137, "reason" => "Error"}}
      end

    %{
      "phase" => if(code == 0, do: "Succeeded", else: "Failed"),
      "startTime" => "2026-10-10T12:00:05Z",
      "podIP" => "10.42.0.17",
      "conditions" => [@scheduled],
      "containerStatuses" => [
        %{
          "name" => "worker",
          "state" => %{"terminated" => %{"exitCode" => code, "reason" => "Completed"}}
        }
      ],
      "initContainerStatuses" => [
        %{"name" => "seed", "state" => %{"terminated" => %{"exitCode" => 0}}},
        %{"name" => "snapshotter", "state" => snap}
      ]
    }
  end

  defp running!(env, controller, n) do
    run = assign!(controller, n)
    set_status(env, n, running_status())
    observed(run, :running)
    run
  end

  defp frame!(run) do
    assert_receive {:run_push, ^run, "stdout", {:binary, frame}}, 5_000
    assert {:ok, ^run, {:cursor, cursor}, bytes} = StdoutFrame.decode(frame)
    {cursor, bytes}
  end

  defp calls(env), do: FakePodChannel.calls(env.channel)

  # -- the stdout stream ---------------------------------------------------------------

  describe "the log follower" do
    test "a running worker's log reaches the sink as ARB2 frames", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)

      ts = FakeK8sApi.push_log(env.api, pod_name(1), "hello")
      assert {cursor, "hello\n"} = frame!(run)
      assert cursor == ts <> " 1"

      ts2 = FakeK8sApi.push_log(env.api, pod_name(1), "again")
      assert {cursor2, "again\n"} = frame!(run)
      assert cursor2 == ts2 <> " 1"
    end

    test "nothing is read before the worker is running", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      FakeK8sApi.push_log(env.api, pod_name(1), "early")
      refute_receive {:run_push, ^run, "stdout", _}, 200
    end

    test "an attach resends what the primary has not acknowledged, and only that", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      FakeK8sApi.push_log(env.api, pod_name(1), "one")
      {c1, _} = frame!(run)
      FakeK8sApi.push_log(env.api, pod_name(1), "two")
      {c2, _} = frame!(run)

      # the primary took "one" (its ack was lost) and never saw "two"
      Controller.resume(controller, %{run => c1})
      :ok = Controller.attach_all(controller, [])
      assert {^c2, "two\n"} = frame!(run)
      refute_receive {:run_push, ^run, "stdout", _}, 100

      # an ack for it, then another attach: nothing left to send
      Controller.ack(controller, run, c2)
      _ = Controller.run_ids(controller)
      :ok = Controller.attach_all(controller, [])
      refute_receive {:run_push, ^run, "stdout", _}, 100
    end

    test "a restarted controller resumes after the primary's cursor", env do
      first = start_controller(env, 1)
      run = running!(env, first, 1)
      FakeK8sApi.push_log(env.api, pod_name(1), "one")
      {c1, _} = frame!(run)
      FakeK8sApi.push_log(env.api, pod_name(1), "two")
      {_c2, _} = frame!(run)
      stop_controller(1)

      second = start_controller(env, 2)
      observed(run, :running)

      # an adopted run is not read until the primary says where it is
      refute_receive {:run_push, ^run, "stdout", _}, 150

      Controller.resume(second, %{run => c1})
      :ok = Controller.attach_all(second, [])
      assert {_, "two\n"} = frame!(run)
      refute_receive {:run_push, ^run, "stdout", _}, 100
    end

    test "a restarted controller whose primary holds nothing replays from the start", env do
      first = start_controller(env, 1)
      run = running!(env, first, 1)
      FakeK8sApi.push_log(env.api, pod_name(1), "one")
      {_c1, _} = frame!(run)
      stop_controller(1)

      second = start_controller(env, 2)
      observed(run, :running)
      Controller.resume(second, %{})
      :ok = Controller.attach_all(second, [])
      assert {_, "one\n"} = frame!(run)
    end
  end

  # -- holding the exit -------------------------------------------------------------------

  describe "exit is held until the final checkpoint and the log tail are in" do
    test "the exit waits for the snapshotter and carries the stream's final cursor", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      ts = FakeK8sApi.push_log(env.api, pod_name(1), "last words")
      {cursor, _} = frame!(run)
      assert cursor == ts <> " 1"

      # the worker ends; the snapshotter is still uploading the final checkpoint
      set_status(env, 1, exited_status(:running))
      observed(run, :exit)
      refute_receive {:run_push, ^run, "exit", _}, 300
      refute {:release, run} in calls(env)
      assert %{"state" => "terminating"} = Enum.find(Controller.report(controller).runs, & &1)

      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", exit}, 5_000
      assert exit["status"] == 0
      assert exit["snapshot"] == "complete"
      assert exit["cursor"] == cursor
      refute Map.has_key?(exit, "size")
      assert {:release, run} in calls(env)
    end

    test "lines written just before the worker ended are in the stream before the exit", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      FakeK8sApi.push_log(env.api, pod_name(1), "one")
      {_c1, _} = frame!(run)

      # not yet seen by the follow when the pod flips to terminated
      ts = FakeK8sApi.push_log(env.api, pod_name(1), "the tail")
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)

      assert_receive {:run_push, ^run, "exit", exit}, 5_000
      assert exit["cursor"] == ts <> " 1"

      frames = collect_frames(run)
      assert Enum.any?(frames, fn {c, bytes} -> c == exit["cursor"] and bytes == "the tail\n" end)
    end

    test "a run with no output exits with size 0", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", exit}, 5_000
      assert exit["size"] == 0
      refute Map.has_key?(exit, "cursor")
    end

    test "a snapshotter that never finishes is waited for grace_s, then the exit goes out",
         env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      set_status(env, 1, exited_status(:running))
      observed(run, :exit)

      advance(env, 119)
      Controller.tick(controller)
      refute_receive {:run_push, ^run, "exit", _}, 200

      advance(env, 1)
      Controller.tick(controller)
      assert_receive {:run_push, ^run, "exit", %{"snapshot" => "absent", "status" => 0}}, 5_000
    end

    test "a snapshotter killed at the grace limit releases the exit", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      set_status(env, 1, exited_status(:killed))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", %{"snapshot" => "killed"}}, 5_000
    end

    test "a failed checkpoint upload is said in the exit", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      send(controller, {:pod_channel_upload, run, :checkpoint, {:error, {:rejected, 422}}})
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", %{"checkout" => "failed: " <> reason}}, 5_000
      assert reason =~ "422"
    end

    test "a good checkpoint upload is said too", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      send(controller, {:pod_channel_upload, run, :checkpoint, {:ok, 200}})
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", %{"checkout" => "ok"}}, 5_000
    end

    test "a pod that failed before the worker ran is not waited for", env do
      controller = start_controller(env)
      run = assign!(controller, 1)

      set_status(env, 1, %{
        "phase" => "Failed",
        "conditions" => [@scheduled],
        "initContainerStatuses" => [
          %{"name" => "seed", "state" => %{"terminated" => %{"exitCode" => 1}}}
        ]
      })

      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", %{"size" => 0}}, 5_000
    end

    test "a pod deleted from outside is not waited for (there is no snapshotter left)", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      FakeK8sApi.delete_pod(env.api, pod_name(1))
      observed(run, :deleted)
      assert_receive {:run_push, ^run, "exit", %{"pod_disrupted" => true}}, 5_000
      _ = controller
    end

    test "a cancelled run with collect exits after its snapshotter, not before", env do
      controller = start_controller(env)
      FakeK8sApi.graceful_deletes(env.api)
      run = running!(env, controller, 1)
      assert :ok = Controller.cancel(controller, run, "stop", collect: true)

      set_status(env, 1, exited_status(:running, 143))
      observed(run, :exit)
      refute_receive {:run_push, ^run, "exit", _}, 200

      set_status(env, 1, exited_status(:complete, 143))
      observed(run, :exit)

      assert_receive {:run_push, ^run, "exit", %{"cancelled" => true, "snapshot" => "complete"}},
                     5_000
    end

    test "after the exit is acked the follower is gone and the clean pod is deleted", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", _}, 5_000
      :ok = Controller.exit_ack(controller, run)
      observed(run, :deleted)
      assert Controller.report(controller).runs == []
    end
  end

  # -- the pod channel after a restart ------------------------------------------------------

  describe "the pod channel after a controller restart" do
    test "assign writes the channel record on the pod", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      pod = FakeK8sApi.handle(env.api, {:get, pod_name(1)})
      record = pod["metadata"]["annotations"]["arbiter.dev/channel"]
      assert Jason.decode!(record) == %{"fake" => "record", "run" => run}
    end

    test "an adopted running pod is re-registered with the pod channel and its IP bound",
         env do
      first = start_controller(env, 1)
      run = running!(env, first, 1)
      stop_controller(1)

      second = start_controller(env, 2)
      observed(run, :running)

      assert {:adopt, run, %{"fake" => "record", "run" => run}} in calls(env)

      assert {:bind, run, {10, 42, 0, 17}} in Enum.filter(
               calls(env),
               &match?({:bind, ^run, _}, &1)
             )

      assert %{"state" => "running"} = Enum.find(Controller.report(second).runs, & &1)
    end

    test "a pod whose record is damaged stays adopted but its bridges stay down", env do
      first = start_controller(env, 1)
      run = running!(env, first, 1)
      binds = fn -> Enum.count(calls(env), &match?({:bind, ^run, _}, &1)) end
      before_restart = binds.()
      assert before_restart >= 1
      stop_controller(1)
      FakePodChannel.adopt_answers(env.channel, {:error, :bad_record})

      second = start_controller(env, 2)
      observed(run, :running)
      assert %{"state" => "running"} = Enum.find(Controller.report(second).runs, & &1)
      assert binds.() == before_restart
    end

    test "a run the pod channel lost (its table crashed) is put back from the pod's record",
         env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      assert run in FakePodChannel.live_runs(env.channel)

      FakePodChannel.forget(env.channel, run)
      refute run in FakePodChannel.live_runs(env.channel)

      Controller.tick(controller)
      assert {:adopt, run, %{"fake" => "record", "run" => run}} in calls(env)
      assert run in FakePodChannel.live_runs(env.channel)
      # and its address is told again
      binds = Enum.filter(calls(env), &match?({:bind, ^run, {10, 42, 0, 17}}, &1))
      assert length(binds) == 2

      # nothing more to do on the next pass
      Controller.tick(controller)
      assert Enum.count(calls(env), &match?({:adopt, ^run, _}, &1)) == 1
    end

    test "a run whose channel entry cannot be put back is not retried every pass", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      FakePodChannel.forget(env.channel, run)
      FakePodChannel.adopt_answers(env.channel, {:error, :deadline_passed})

      Controller.tick(controller)
      Controller.tick(controller)
      assert Enum.count(calls(env), &match?({:adopt, ^run, _}, &1)) == 1
    end

    test "a pod with no record (made before K15) is adopted without a channel", env do
      first = start_controller(env, 1)
      run = running!(env, first, 1)
      pod = FakeK8sApi.handle(env.api, {:get, pod_name(1)})
      bare = update_in(pod, ["metadata"], &Map.delete(&1, "annotations"))
      FakeK8sApi.put_pod(env.api, bare)
      stop_controller(1)

      second = start_controller(env, 2)
      assert_receive {:run_observed, ^run, :running, _}, 5_000
      refute Enum.any?(calls(env), &match?({:adopt, ^run, _}, &1))
      assert %{"state" => "running"} = Enum.find(Controller.report(second).runs, & &1)
    end

    test "an adopted pod that has already exited is not registered", env do
      first = start_controller(env, 1)
      run = running!(env, first, 1)
      stop_controller(1)
      set_status(env, 1, exited_status(:complete))

      _second = start_controller(env, 2)
      observed(run, :exit)
      refute Enum.any?(calls(env), &match?({:adopt, ^run, _}, &1))
    end
  end

  defp collect_frames(run, acc \\ []) do
    receive do
      {:run_push, ^run, "stdout", {:binary, frame}} ->
        {:ok, ^run, {:cursor, c}, bytes} = StdoutFrame.decode(frame)
        collect_frames(run, [{c, bytes} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
