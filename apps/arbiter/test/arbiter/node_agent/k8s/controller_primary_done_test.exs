defmodule Arbiter.NodeAgent.K8s.ControllerPrimaryDoneTest do
  # The whole k8s completion path with real parts and no stand-ins but the cluster API:
  # the controller and its log follower (against the fake API server) push `stdout`
  # frames and `exit` the way the node channel carries them, the primary's stream table
  # (`Arbiter.Nodes.RunStreams`) turns them into the Port-shaped messages a Worker gets,
  # and the Worker classifies the run when its exit arrives. The primary's acks go back
  # to the controller, as `Nodes.Session` pushes them.
  use Arbiter.DataCase, async: false

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.Nodes.RunStreams
  alias Arbiter.Nodes.StdoutFrame
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.FakePodChannel
  alias Arbiter.Test.K8sPodFixtures
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession

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

  defp start_controller(env, n \\ 1, opts \\ []) do
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
         event_feed: Keyword.get(opts, :event_feed, false),
         event_final_wait_ms: 100,
         event_silent_ms: Keyword.get(opts, :event_silent_ms, 600_000),
         name: nil},
        id: {:controller, n}
      )

    _ = Controller.run_ids(controller)
    controller
  end

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

  # -- the primary's side ------------------------------------------------------------------

  setup do
    grace = Application.fetch_env(:arbiter, :worker_exit_grace_ms)
    Application.put_env(:arbiter, :worker_exit_grace_ms, 50)

    on_exit(fn ->
      case grace do
        {:ok, v} -> Application.put_env(:arbiter, :worker_exit_grace_ms, v)
        :error -> Application.delete_env(:arbiter, :worker_exit_grace_ms)
      end
    end)

    :ok
  end

  defp start_worker do
    task_id = "bd-k8sdone-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "r")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    handle = {:remote, {"k8s-node", "run-1", :ref}}

    session =
      task_id
      |> ClaudeSession.build_session_config(nil, redact_values: [])
      |> Map.merge(%{
        output_lines: [],
        line_buf: "",
        exit_status: nil,
        exited_at: nil,
        started_at: DateTime.utc_now(),
        activity: "starting",
        activity_at: DateTime.utc_now(),
        stdout_offset: 0
      })

    :sys.replace_state(pid, fn st ->
      %{st | claude_sessions: Map.put(st.claude_sessions, handle, session)}
    end)

    %{pid: pid, handle: handle}
  end

  # The primary's end of the node channel: every `stdout` frame and the `exit` the
  # controller pushes goes through the stream table, whose messages reach the Worker and
  # whose acks reach the controller. Returns the table once `exit` has been taken.
  defp pump(table, controller, run) do
    receive do
      {:run_push, ^run, "stdout", {:binary, frame}} ->
        {:ok, ^run, {:cursor, cursor}, bytes} = StdoutFrame.decode(frame)
        table |> RunStreams.data_cursor(run, cursor, bytes) |> apply_effects(controller, run)

      {:run_push, ^run, "exit", payload} ->
        table |> RunStreams.exit(run, payload) |> apply_effects(controller, run)

      {:run_push, ^run, _event, _payload} ->
        {table, :continue}
    after
      0 -> {table, :idle}
    end
    |> case do
      {table, :continue} -> pump(table, controller, run)
      {table, :idle} -> table
    end
  end

  defp apply_effects({table, effects}, controller, run) do
    for effect <- effects do
      case effect do
        {:send, pid, message} -> send(pid, message)
        {:push, "ack", %{"cursor" => cursor}} -> Controller.ack(controller, run, cursor)
        {:push, "exit_ack", _} -> Controller.exit_ack(controller, run)
        _ -> :ok
      end
    end

    {table, :continue}
  end

  defp assistant(text) do
    Jason.encode!(%{
      "type" => "assistant",
      "message" => %{"content" => [%{"type" => "text", "text" => text}]}
    })
  end

  defp result_event do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "stop_reason" => "end_turn",
      "result" => "ok"
    })
  end

  # The primary's part once the pod has ended: take every `stdout` frame and the `exit`
  # the controller pushes, and give the Worker its exit grace.
  defp finish_run(controller, run, table) do
    assert_receive {:run_push, ^run, "exit", _} = push, 5_000
    send(self(), push)
    table = pump(table, controller, run)
    Process.sleep(200)
    table
  end

  describe "a k8s run's final lines" do
    test "lines written after the pod ended, before the exit goes out, still reach the Worker: done",
         env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      %{pid: pid, handle: handle} = start_worker()
      table = RunStreams.open(%RunStreams{}, run, handle, pid, nil)

      FakeK8sApi.push_log(env.api, pod_name(1), assistant("working"))

      # the worker container has ended, its snapshotter is still uploading: the exit is
      # held, and the agent's last lines are only in the log's tail now
      set_status(env, 1, exited_status(:running))
      observed(run, :exit)
      FakeK8sApi.push_log(env.api, pod_name(1), assistant("All finished.\n\narb done"))
      FakeK8sApi.push_log(env.api, pod_name(1), result_event())
      refute_receive {:run_push, ^run, "exit", _}, 200

      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      _ = finish_run(controller, run, table)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(pid)
      assert Worker.state(pid).meta.done_seen == true
    end

    test "a final line over the runtime's record size, stamped per record by the kubelet: done",
         env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      %{pid: pid, handle: handle} = start_worker()
      table = RunStreams.open(%RunStreams{}, run, handle, pid, nil)

      # containerd cuts a line over 16 KiB into partial records; a kubelet that stamps every
      # record writes `<timestamp> ` where the first one ended. Here that is inside the
      # closing `arb done`, which is what the agent's message ends with
      text = "\n\narb done"
      {at, _} = :binary.match(assistant(text), "arb done")
      final = assistant(String.duplicate("x", 16_384 - at - 5) <> text)
      assert byte_size(final) > 16_384 + 10
      <<first::binary-size(16_384), rest::binary>> = final
      assert String.ends_with?(first, "arb d")
      spliced = first <> "2026-10-10T12:00:00.999999999Z " <> rest

      FakeK8sApi.push_log(env.api, pod_name(1), spliced)
      FakeK8sApi.push_log(env.api, pod_name(1), result_event())
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      _ = finish_run(controller, run, table)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(pid)
      assert Worker.state(pid).meta.done_seen == true
    end

    test "a kubelet stamping with a local offset (-04:00) still completes the run: done",
         env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      %{pid: pid, handle: handle} = start_worker()
      table = RunStreams.open(%RunStreams{}, run, handle, pid, nil)

      FakeK8sApi.push_log_offset(env.api, pod_name(1), assistant("working"))
      FakeK8sApi.push_log_offset(env.api, pod_name(1), assistant("All finished.\n\narb done"))
      FakeK8sApi.push_log_offset(env.api, pod_name(1), result_event())
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      _ = finish_run(controller, run, table)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(pid)
      assert Worker.state(pid).meta.done_seen == true
    end

    test "a run with no `arb done` anywhere is still exited_without_done", env do
      controller = start_controller(env)
      run = running!(env, controller, 1)
      %{pid: pid, handle: handle} = start_worker()
      table = RunStreams.open(%RunStreams{}, run, handle, pid, nil)

      FakeK8sApi.push_log(env.api, pod_name(1), assistant("All finished."))
      FakeK8sApi.push_log(env.api, pod_name(1), result_event())
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      _ = finish_run(controller, run, table)

      snap = Worker.state(pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
      refute Map.get(snap.meta, :done_seen)
    end
  end

  # -- the event feed is the source of truth (bd-1nl506) --------------------------------------
  #
  # The pod ships the agent's stdio as NDJSON (`POST /events`, which hands each chunk to the
  # run's `LogFollower` in event mode: `Controller.event_feed/2`). The kubelet's log is then
  # only for a human: nothing in it is read, so what it drops, reorders or garbles changes
  # nothing about the run's done signal and outcome.
  describe "a k8s run's done signal and outcome come from the event feed" do
    alias Arbiter.NodeAgent.K8s.LogFollower

    defp events_run(env) do
      controller = start_controller(env, 1, event_feed: true)
      run = running!(env, controller, 1)
      %{pid: pid, handle: handle} = start_worker()
      table = RunStreams.open(%RunStreams{}, run, handle, pid, nil)
      {:ok, feed} = Controller.event_feed(controller, run)
      %{controller: controller, run: run, table: table, pid: pid, feed: feed}
    end

    defp ship(feed, offset, text, final? \\ false) do
      assert {:ok, next} = LogFollower.push_events(feed, offset, text, final?)
      assert next == offset + byte_size(text)
      next
    end

    defp ndjson(lines), do: Enum.map_join(lines, &(&1 <> "\n"))

    defp end_run(env, %{controller: controller, run: run, table: table}) do
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      finish_run(controller, run, table)
    end

    test "the pod's pod is annotated for the feed and its follower is the event one", env do
      %{run: run} = events_run(env)
      pod = FakeK8sApi.handle(env.api, {:get, pod_name(1)})
      assert pod["metadata"]["annotations"]["arbiter.dev/events"] == "1"
      assert run == run_id(1)
    end

    test "done and the result are taken from the feed while the kubelet log says nothing",
         env do
      ctx = events_run(env)
      FakeK8sApi.push_log(env.api, pod_name(1), "kubelet noise only")

      text =
        ndjson([assistant("working"), assistant("All finished.\n\narb done"), result_event()])

      ship(ctx.feed, 0, text, true)
      _ = end_run(env, ctx)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(ctx.pid)
      assert Worker.state(ctx.pid).meta.done_seen == true
    end

    test "a done in the kubelet log that the feed lacks is not a done", env do
      ctx = events_run(env)
      FakeK8sApi.push_log(env.api, pod_name(1), assistant("All finished.\n\narb done"))
      FakeK8sApi.push_log(env.api, pod_name(1), result_event())

      ship(ctx.feed, 0, ndjson([assistant("working")]), true)
      _ = end_run(env, ctx)

      snap = Worker.state(ctx.pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
    end

    test "kubelet lines dropped, reordered and garbled do not lose the done signal", env do
      ctx = events_run(env)

      # the log has the closing lines first, the done line mangled, and the rest missing
      FakeK8sApi.push_log(env.api, pod_name(1), result_event())
      FakeK8sApi.push_log(env.api, pod_name(1), "arb d")
      FakeK8sApi.push_log_offset(env.api, pod_name(1), assistant("working"))

      text =
        ndjson([assistant("working"), assistant("All finished.\n\narb done"), result_event()])

      # delivered in chunks, one of them retried
      {a, rest} = String.split_at(text, 20)
      {b, c} = String.split_at(rest, 30)
      next = ship(ctx.feed, 0, a)
      _ = ship(ctx.feed, 0, a)
      next = ship(ctx.feed, next, b)
      ship(ctx.feed, next, c, true)
      _ = end_run(env, ctx)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(ctx.pid)
      assert Worker.state(ctx.pid).meta.done_seen == true
    end

    test "a done line cut mid-way is not taken as success and does not crash", env do
      ctx = events_run(env)
      done = assistant("All finished.\n\narb done")
      cut = binary_part(done, 0, byte_size(done) - 9)
      ship(ctx.feed, 0, ndjson([assistant("working")]) <> cut, true)
      _ = end_run(env, ctx)

      snap = Worker.state(ctx.pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
      refute Map.get(snap.meta, :done_seen)
    end

    test "a result event cut mid-way is dropped; the complete done before it stands", env do
      ctx = events_run(env)
      cut = binary_part(result_event(), 0, byte_size(result_event()) - 9)
      ship(ctx.feed, 0, ndjson([assistant("All finished.\n\narb done")]) <> cut, true)
      _ = end_run(env, ctx)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(ctx.pid)
    end

    test "the done line itself cut before its newline is not a done", env do
      ctx = events_run(env)
      # complete JSON, but the file ended before the newline: a truncated line
      ship(ctx.feed, 0, assistant("All finished.\n\narb done"), true)
      _ = end_run(env, ctx)

      snap = Worker.state(ctx.pid)
      assert %{state: :finished, outcome: :failed} = snap
      assert snap.meta.stop_reason.category == :exited_without_done
      refute Map.get(snap.meta, :done_seen)
    end

    test "the exit says the stream was truncated", env do
      ctx = events_run(env)
      ship(ctx.feed, 0, ndjson([assistant("working")]) <> "{\"type\":\"res", true)
      set_status(env, 1, exited_status(:complete))
      observed(ctx.run, :exit)
      assert_receive {:run_push, run, "exit", payload}, 5_000
      assert run == ctx.run
      assert payload["stdout_truncated"] == 12
      assert is_binary(payload["cursor"])
    end

    test "a feed that delivers nothing from a live worker falls back to the log, and the run still succeeds",
         env do
      controller = start_controller(env, 1, event_feed: true, event_silent_ms: 50)
      run = running!(env, controller, 1)
      %{pid: pid, handle: handle} = start_worker()
      table = RunStreams.open(%RunStreams{}, run, handle, pid, nil)
      {:ok, _feed} = Controller.event_feed(controller, run)

      # the wrapper never ships; the kubelet's log has the whole stream
      FakeK8sApi.push_log(env.api, pod_name(1), assistant("working"))
      FakeK8sApi.push_log(env.api, pod_name(1), assistant("All finished.\n\narb done"))
      FakeK8sApi.push_log(env.api, pod_name(1), result_event())

      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      _ = finish_run(controller, run, table)

      assert %{state: :finished, outcome: :succeeded} = Worker.state(pid)
      assert Worker.state(pid).meta.done_seen == true
    end

    test "the exit of a run whose feed was silent says so", env do
      controller = start_controller(env, 1, event_feed: true, event_silent_ms: 50)
      run = running!(env, controller, 1)
      {:ok, _feed} = Controller.event_feed(controller, run)
      FakeK8sApi.push_log(env.api, pod_name(1), assistant("working"))

      assert_receive {:run_push, ^run, "stdout", {:binary, _}}, 5_000
      set_status(env, 1, exited_status(:complete))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", payload}, 5_000
      assert payload["stdout_feed"] == "silent_log_fallback"
    end

    test "a pod that never sends its final chunk still ends the run, from what arrived", env do
      ctx = events_run(env)
      ship(ctx.feed, 0, ndjson([assistant("All finished.\n\narb done"), result_event()]))
      _ = end_run(env, ctx)

      # the feed is the truth even without its last word: what was complete was kept
      assert %{state: :finished, outcome: :succeeded} = Worker.state(ctx.pid)
    end
  end
end
