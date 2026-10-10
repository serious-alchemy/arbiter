defmodule Arbiter.NodeAgent.K8s.ControllerTest do
  # The controller core against a fake API server and the real informer: admission,
  # the pending-is-never-running rule, cancel, adoption after a restart, the
  # sweeper, and the Lease. The clock is a value the test moves; every wait is a
  # message (the sink's pushes, the observer's per-event notices).
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.ConfigLoader
  alias Arbiter.NodeAgent.K8s.Controller
  alias Arbiter.NodeAgent.K8s.Informer
  alias Arbiter.NodeAgent.K8s.Lease
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.FakePodChannel
  alias Arbiter.Test.K8sPodFixtures

  @moduletag :tmp_dir

  @t0 ~U[2026-10-10 12:00:00Z]
  @labels %{"arbiter.dev/install" => "inst-1", "arbiter.dev/node" => "node-1"}

  @config """
  max_concurrent: 2
  timeouts: {schedule_s: 30, grace_s: 120, retain_failed_s: 300}
  """

  setup %{tmp_dir: dir} do
    env = FakeK8sApi.start!(namespace: "arb")
    config_path = Path.join(dir, "controller.yaml")
    File.write!(config_path, @config)

    loader =
      start_supervised!(
        {ConfigLoader, path: config_path, interval_ms: nil, notify: nil},
        id: :loader
      )

    channel = start_supervised!(FakePodChannel)
    clock = start_supervised!({Agent, fn -> @t0 end}, id: :clock)

    {:ok,
     Map.merge(env, %{
       loader: loader,
       config_path: config_path,
       channel: channel,
       clock: clock,
       dir: dir
     })}
  end

  # -- harness ---------------------------------------------------------------------

  defp start_informer(env, id \\ :informer) do
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

  defp start_controller(env, opts \\ []) do
    informer = Keyword.get_lazy(opts, :informer, fn -> start_informer(env) end)
    clock = env.clock

    controller =
      start_supervised!(
        {Controller,
         Keyword.delete(opts, :informer) ++
           [
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
             name: nil
           ]},
        id: Keyword.get(opts, :id, :controller)
      )

    # `handle_continue` (subscribe, adopt, first quota read) has run once this returns.
    _ = Controller.run_ids(controller)
    controller
  end

  defp advance(env, seconds), do: Agent.update(env.clock, &DateTime.add(&1, seconds, :second))

  defp wire(n, overrides \\ %{}) do
    id = "run-" <> Base.encode16(<<n::64>>, case: :lower)

    K8sPodFixtures.wire_spec(
      Map.merge(
        %{
          "run" => id,
          "name" => "arb-run-" <> binary_part(Base.encode16(<<n::64>>, case: :lower), 4, 12),
          "image" => %{"tag" => "arbiter-dev/beam:abc", "plan" => nil, "ref" => image_ref()}
        },
        overrides
      )
    )
  end

  defp image_ref,
    do: "#{K8sPodFixtures.registry()}/beam@sha256:#{K8sPodFixtures.digest()}"

  defp run_id(n), do: wire(n)["run"]
  defp pod_name(n), do: wire(n)["name"]

  defp assign!(controller, n, overrides \\ %{}) do
    assert {:ok, run} = Controller.assign(controller, wire(n, overrides))
    assert run == run_id(n)
    run
  end

  defp stored_pod(env, name), do: FakeK8sApi.handle(env.api, {:get, name})

  # Puts the pod's new status in the cluster and remembers which resourceVersion
  # `observed/2` must see for that run: the informer is asynchronous, and the pod's
  # earlier events carry the same state words.
  defp set_status(env, name, status) do
    pod = stored_pod(env, name)
    updated = FakeK8sApi.put_pod(env.api, Map.put(pod, "status", status))

    Process.put(
      {:rv, updated["metadata"]["labels"]["arbiter.dev/run"]},
      updated["metadata"]["resourceVersion"]
    )

    updated
  end

  @scheduled %{"type" => "PodScheduled", "status" => "True"}

  defp unschedulable_status do
    %{
      "phase" => "Pending",
      "conditions" => [
        %{
          "type" => "PodScheduled",
          "status" => "False",
          "reason" => "Unschedulable",
          "message" => "0/1 nodes are available: 1 Insufficient cpu."
        }
      ]
    }
  end

  defp starting_status do
    %{
      "phase" => "Pending",
      "startTime" => "2026-10-10T12:00:05Z",
      "conditions" => [@scheduled],
      "initContainerStatuses" => [%{"name" => "seed", "state" => %{"running" => %{}}}]
    }
  end

  defp running_status do
    %{
      "phase" => "Running",
      "startTime" => "2026-10-10T12:00:05Z",
      "podIP" => "10.42.0.17",
      "conditions" => [@scheduled],
      "containerStatuses" => [
        %{"name" => "worker", "state" => %{"running" => %{"startedAt" => "2026-10-10T12:00:20Z"}}}
      ]
    }
  end

  defp terminated_status(code, extra \\ %{}) do
    %{
      "phase" => if(code == 0, do: "Succeeded", else: "Failed"),
      "startTime" => "2026-10-10T12:00:05Z",
      "conditions" => [@scheduled],
      "containerStatuses" => [
        %{
          "name" => "worker",
          "state" => %{
            "terminated" => Map.merge(%{"exitCode" => code, "reason" => "Completed"}, extra)
          }
        }
      ]
    }
  end

  defp observed(run, :deleted), do: assert_receive({:run_observed, ^run, :deleted, _}, 5_000)

  defp observed(run, tag) do
    case Process.get({:rv, run}) do
      nil -> assert_receive({:run_observed, ^run, ^tag, _}, 5_000)
      rv -> assert_receive({:run_observed, ^run, ^tag, ^rv}, 5_000)
    end
  end

  defp deletes(env),
    do: Enum.filter(FakeK8sApi.requests(env.api), &(&1.method == "DELETE"))

  defp creates(env),
    do:
      Enum.filter(
        FakeK8sApi.requests(env.api),
        &(&1.method == "POST" and String.ends_with?(&1.path, "/pods"))
      )

  defp delete_body(request), do: Jason.decode!(request.body)

  defp runs_by_state(controller) do
    controller
    |> Controller.report()
    |> Map.fetch!(:runs)
    |> Map.new(&{&1["run"], &1["state"]})
  end

  # -- the pod ------------------------------------------------------------------

  describe "assign/3" do
    test "creates the labelled, owned, deadline-bounded pod and answers {:ok, run}", env do
      controller = start_controller(env)
      run = assign!(controller, 1)

      assert [create] = creates(env)
      pod = Jason.decode!(create.body)

      assert pod["metadata"]["name"] == pod_name(1)
      assert pod["metadata"]["labels"]["arbiter.dev/install"] == "inst-1"
      assert pod["metadata"]["labels"]["arbiter.dev/node"] == "node-1"
      assert pod["metadata"]["labels"]["arbiter.dev/run"] == run

      assert [%{"kind" => "Deployment", "name" => "arbiter-controller"}] =
               pod["metadata"]["ownerReferences"]

      assert pod["spec"]["activeDeadlineSeconds"] == 3600 + 1800

      assert [{:register, ^run, deadline}] = FakePodChannel.calls(env.channel)
      assert DateTime.diff(deadline, @t0) == 3600 + 1800
    end

    test "the pod is pending, and nothing says it is running", env do
      controller = start_controller(env)
      run = assign!(controller, 1)

      assert %{^run => "pending"} = runs_by_state(controller)
      refute_received {:run_push, ^run, "run.ready", _}
    end

    test "a repeated assign for a live run is :already_running", env do
      controller = start_controller(env)
      assign!(controller, 1)
      assert {:error, :already_running} = Controller.assign(controller, wire(1))
      assert length(creates(env)) == 1
    end

    test "a spec the builder cannot represent is refused bad_spec, nothing created", env do
      controller = start_controller(env)

      assert {:error, {:refuse, :bad_spec, detail}} =
               Controller.assign(controller, wire(1, %{"network" => "pasta"}))

      assert is_binary(detail)
      assert creates(env) == []

      # Whatever was registered with the pod channel before the builder said no is given back.
      calls = FakePodChannel.calls(env.channel)

      assert Enum.count(calls, &match?({:register, _, _}, &1)) ==
               Enum.count(calls, &match?({:release, _}, &1))
    end

    test "an invalid spec is refused bad_spec", env do
      controller = start_controller(env)
      assert {:error, {:refuse, :bad_spec, _}} = Controller.assign(controller, %{"run" => "x"})
    end
  end

  # -- admission ------------------------------------------------------------------

  describe "admission" do
    test "running + pending at max_concurrent refuses no_capacity and creates nothing", env do
      controller = start_controller(env)
      assign!(controller, 1)
      assign!(controller, 2)

      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(3))
      assert detail =~ "max_concurrent"
      assert length(creates(env)) == 2
    end

    test "a slot frees when a run ends", env do
      controller = start_controller(env)
      assign!(controller, 1)
      assign!(controller, 2)
      observed_ready(env, controller, 1)
      set_status(env, pod_name(1), terminated_status(0))
      observed(run_id(1), :exit)

      assert {:ok, _} = Controller.assign(controller, wire(3))
    end

    test "ResourceQuota headroom of zero refuses no_capacity with ceiling room left", env do
      FakeK8sApi.put_quota(env.api, %{
        "metadata" => %{"name" => "q"},
        "status" => %{"hard" => %{"pods" => "4"}, "used" => %{"pods" => "4"}}
      })

      controller = start_controller(env)
      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(1))
      assert detail =~ "ResourceQuota"
      assert creates(env) == []
    end

    test "headroom of one admits exactly one more", env do
      FakeK8sApi.put_quota(env.api, %{
        "metadata" => %{"name" => "q"},
        "status" => %{"hard" => %{"pods" => "1"}, "used" => %{"pods" => "0"}}
      })

      controller = start_controller(env)
      assign!(controller, 1)
      # The pod we just made is counted by the quota the API reports (a real server
      # does it; the fake does not), so the stand-in raises `used`.
      FakeK8sApi.put_quota(env.api, %{
        "metadata" => %{"name" => "q"},
        "status" => %{"hard" => %{"pods" => "1"}, "used" => %{"pods" => "1"}}
      })

      assert {:error, {:refuse, :no_capacity, _}} = Controller.assign(controller, wire(2))
    end

    test "an unreadable quota refuses rather than guessing", env do
      controller = start_controller(env)
      FakeK8sApi.fail_next(env.api, :quota, 500)
      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(1))
      assert detail =~ "ResourceQuota"
    end

    test "the API server's own 403 exceeded-quota on create is the same refusal", env do
      controller = start_controller(env)

      FakeK8sApi.fail_next(
        env.api,
        :create,
        {403, "pods \"x\" is forbidden: exceeded quota: arbiter-workers"}
      )

      assert {:error, {:refuse, :no_capacity, _}} = Controller.assign(controller, wire(1))
      # Nothing is left registered with the pod channel.
      assert {:release, run_id(1)} in FakePodChannel.calls(env.channel)
      assert Controller.report(controller).runs == []
    end

    test "no config yet (a bad file at start) refuses rather than guessing a ceiling", env do
      File.write!(env.config_path, "max_concurrent: 0")

      loader =
        start_supervised!({ConfigLoader, path: env.config_path, interval_ms: nil, notify: nil},
          id: :bad_loader
        )

      controller = start_controller(%{env | loader: loader})
      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(1))
      assert detail =~ "config"
    end

    test "an informer that has not synced is not a basis for admission", env do
      # The fake refuses the first list, so the informer is up but not synced.
      FakeK8sApi.fail_next(env.api, :list, 500, 1_000)

      informer =
        start_supervised!(
          {Informer,
           client: env.client,
           label_selector: Client.label_selector(@labels),
           backoff_ms: {5, 20},
           name: nil},
          id: :unsynced
        )

      controller = start_controller(env, informer: informer)
      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(1))
      assert detail =~ "sync"
    end
  end

  # -- pending is never running -----------------------------------------------------

  describe "pending and unschedulable pods" do
    test "an unschedulable pod is pending: never ready, counted, constrained", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), unschedulable_status())
      observed(run, :pending)

      assert %{^run => "pending"} = runs_by_state(controller)
      refute_received {:run_push, ^run, "run.ready", _}

      assert %{
               "ceiling" => 2,
               "running" => 0,
               "pending" => 1,
               "constrained" => true
             } = Controller.report(controller).capacity
    end

    test "at schedule_s it is deleted and the assign refused unschedulable, message verbatim",
         env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), unschedulable_status())
      observed(run, :pending)

      advance(env, 29)
      Controller.tick(controller)
      refute_received {:run_push, ^run, "run.refused", _}
      assert deletes(env) == []

      advance(env, 1)
      Controller.tick(controller)

      assert_receive {:run_push, ^run, "run.refused",
                      %{"reason" => "unschedulable", "detail" => detail}}, 5_000

      assert detail =~ "Insufficient cpu"
      assert [delete] = deletes(env)
      assert delete.path =~ pod_name(1)
      assert {:release, run} in FakePodChannel.calls(env.channel)

      # Never reported ready, and the slot is free again.
      refute_received {:run_push, ^run, "run.ready", _}
      assert Controller.report(controller).capacity["pending"] == 0
    end

    test "a pod that never gets a status at all times out the same way", env do
      controller = start_controller(env)
      run = assign!(controller, 1)

      advance(env, 31)
      Controller.tick(controller)

      assert_receive {:run_push, ^run, "run.refused", %{"reason" => "unschedulable"}}, 5_000
    end

    test "a pod that schedules in time is not refused", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), unschedulable_status())
      observed(run, :pending)
      set_status(env, pod_name(1), starting_status())
      observed(run, :starting)

      advance(env, 600)
      Controller.tick(controller)
      refute_received {:run_push, ^run, "run.refused", _}
      assert %{^run => "starting"} = runs_by_state(controller)
    end

    test "starting is not running either", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), starting_status())
      observed(run, :starting)
      refute_received {:run_push, ^run, "run.ready", _}
      assert %{"pending" => 1, "running" => 0} = Controller.report(controller).capacity
    end

    test "a worker container that is running is ready, exactly once", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)

      assert_receive {:run_push, ^run, "run.ready", %{"run" => ^run}}, 5_000
      assert %{^run => "running"} = runs_by_state(controller)
      assert %{"running" => 1, "pending" => 0} = Controller.report(controller).capacity

      # A later event for the same state says nothing new.
      set_status(env, pod_name(1), Map.put(running_status(), "message", "again"))
      observed(run, :running)
      refute_received {:run_push, ^run, "run.ready", _}
    end

    test "the pod IP is handed to the pod channel once bound", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)
      assert {:bind, run, {10, 42, 0, 17}} in FakePodChannel.calls(env.channel)
      _ = controller
    end
  end

  # -- exit, cancel ----------------------------------------------------------------

  describe "exit" do
    test "a finished worker reports its exit; ack deletes a clean pod at once", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)
      set_status(env, pod_name(1), terminated_status(0))
      observed(run, :exit)

      assert_receive {:run_push, ^run, "exit", %{"status" => 0, "oom" => false} = exit}, 5_000
      assert exit["cancelled"] == false
      assert deletes(env) == []

      :ok = Controller.exit_ack(controller, run)
      assert [delete] = deletes(env)
      assert delete.path =~ pod_name(1)
      observed(run, :deleted)
      assert Controller.report(controller).runs == []
    end

    test "a failed pod is kept for retain_failed_s after its exit is acked", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), terminated_status(1))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", %{"status" => 1}}, 5_000

      :ok = Controller.exit_ack(controller, run)
      advance(env, 299)
      Controller.tick(controller)
      assert deletes(env) == []

      advance(env, 1)
      Controller.tick(controller)
      assert [_] = deletes(env)
    end

    test "OOMKilled is reported", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), terminated_status(137, %{"reason" => "OOMKilled"}))
      observed(run, :exit)
      assert_receive {:run_push, ^run, "exit", %{"status" => 137, "oom" => true}}, 5_000
    end

    test "a pod deleted by someone else is pod_disrupted, not a plain failure", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)
      FakeK8sApi.delete_pod(env.api, pod_name(1))
      observed(run, :deleted)

      assert_receive {:run_push, ^run, "exit", %{"pod_disrupted" => true}}, 5_000
      assert {:release, run} in FakePodChannel.calls(env.channel)
      _ = controller
    end
  end

  describe "cancel/4 and signal/3" do
    test "cancel deletes the pod with grace 0 and reports a cancelled exit", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)

      assert :ok = Controller.cancel(controller, run, "operator stop")
      assert [delete] = deletes(env)
      assert delete_body(delete)["gracePeriodSeconds"] == 0
      assert delete_body(delete)["preconditions"]["uid"] =~ "uid-"

      observed(run, :deleted)

      assert_receive {:run_push, ^run, "exit",
                      %{"cancelled" => true, "reason" => "operator stop"}}, 5_000
    end

    test "cancel with collect uses the pod's grace period so the snapshotter can finalise",
         env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)

      assert :ok = Controller.cancel(controller, run, "stop", collect: true)
      assert [delete] = deletes(env)
      assert delete_body(delete)["gracePeriodSeconds"] == 120
    end

    test "cancel of an unknown run is :not_found", env do
      controller = start_controller(env)
      assert {:error, :not_found} = Controller.cancel(controller, "run-nope", "x")
    end

    test "cancelling a pending run frees its slot", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      assert :ok = Controller.cancel(controller, run, "changed my mind")
      observed(run, :deleted)
      assert %{"pending" => 0} = Controller.report(controller).capacity
    end

    test "signal TERM is the pod's graceful delete; KILL is grace 0", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)

      assert :ok = Controller.signal(controller, run, "TERM")
      assert [term] = deletes(env)
      assert delete_body(term)["gracePeriodSeconds"] == 120
      _ = controller
    end

    test "signal KILL", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)

      assert :ok = Controller.signal(controller, run, "KILL")
      assert [kill] = deletes(env)
      assert delete_body(kill)["gracePeriodSeconds"] == 0
    end

    test "signal for an unknown run is :not_found", env do
      controller = start_controller(env)
      assert {:error, :not_found} = Controller.signal(controller, "run-nope", "TERM")
    end
  end

  # -- adoption --------------------------------------------------------------------

  describe "controller restart" do
    test "worker pods keep running and the new controller re-adopts them", env do
      first = start_controller(env, id: :first_controller)
      run1 = assign!(first, 1)
      run2 = assign!(first, 2)
      set_status(env, pod_name(1), running_status())
      observed(run1, :running)
      set_status(env, pod_name(2), starting_status())
      observed(run2, :starting)

      stop_supervised!(:first_controller)
      stop_supervised!(:informer)

      # The controller going away deleted nothing.
      assert deletes(env) == []
      assert stored_pod(env, pod_name(1))
      assert stored_pod(env, pod_name(2))

      informer = start_informer(env, :informer2)
      second = start_controller(env, informer: informer, id: :second_controller)
      observed(run1, :running)
      observed(run2, :starting)

      assert %{^run1 => "running", ^run2 => "starting"} = runs_by_state(second)

      # Still no delete: adoption is not a reap.
      assert deletes(env) == []

      # And the adopted pods hold their slots.
      assert %{"running" => 1, "pending" => 1} = Controller.report(second).capacity
      assert {:error, {:refuse, :no_capacity, _}} = Controller.assign(second, wire(3))
    end

    test "an adopted run can be cancelled and its exit reported", env do
      first = start_controller(env, id: :first_controller)
      run = assign!(first, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)
      stop_supervised!(:first_controller)
      stop_supervised!(:informer)

      informer = start_informer(env, :informer2)
      second = start_controller(env, informer: informer, id: :second_controller)
      observed(run, :running)

      assert :ok = Controller.cancel(second, run, "after restart")
      observed(run, :deleted)
      assert_receive {:run_push, ^run, "exit", %{"cancelled" => true}}, 5_000
    end

    test "attach_all re-announces what the primary may have missed", env do
      first = start_controller(env, id: :first_controller)
      run1 = assign!(first, 1)
      run2 = assign!(first, 2)
      set_status(env, pod_name(1), running_status())
      observed(run1, :running)
      set_status(env, pod_name(2), terminated_status(0))
      observed(run2, :exit)
      stop_supervised!(:first_controller)
      stop_supervised!(:informer)
      flush_pushes()

      informer = start_informer(env, :informer2)
      second = start_controller(env, informer: informer, id: :second_controller)
      observed(run1, :running)
      observed(run2, :exit)
      flush_pushes()

      assert :ok = Controller.attach_all(second)
      assert_receive {:run_push, ^run1, "run.ready", _}, 5_000
      assert_receive {:run_push, ^run2, "exit", %{"status" => 0}}, 5_000
    end

    test "attach_all leaves out the runs the primary does not know", env do
      first = start_controller(env, id: :first_controller)
      run = assign!(first, 1)
      set_status(env, pod_name(1), running_status())
      observed(run, :running)
      flush_pushes()

      assert :ok = Controller.attach_all(first, [run])
      refute_received {:run_push, ^run, _, _}
    end

    test "pods without the three labels are not adopted", env do
      FakeK8sApi.put_pod(env.api, %{
        "metadata" => %{"name" => "stray", "labels" => @labels},
        "status" => %{"phase" => "Running"}
      })

      controller = start_controller(env)
      assert Controller.report(controller).runs == []
    end
  end

  # -- the sweeper -------------------------------------------------------------------

  describe "reap/2" do
    defp put_labelled(env, name, labels, extra \\ %{}) do
      FakeK8sApi.put_pod(env.api, %{
        "metadata" => Map.merge(%{"name" => name, "labels" => labels}, extra),
        "status" => running_status()
      })
    end

    defp run_labels(run), do: Map.put(@labels, "arbiter.dev/run", run)

    test "deletes our pods outside the live set, with the pod's grace and its uid", env do
      put_labelled(env, "orphan-pod", run_labels("run-orphan"))
      put_labelled(env, "live-pod", run_labels("run-live"))
      controller = start_controller(env)
      observed("run-orphan", :running)
      observed("run-live", :running)

      assert %{pods: ["orphan-pod"]} =
               Controller.reap(controller, %{install: "inst-1", live_set: ["run-live"]})

      assert [delete] = deletes(env)
      assert delete.path =~ "orphan-pod"
      body = delete_body(delete)
      assert body["gracePeriodSeconds"] == 120
      assert body["preconditions"]["uid"] =~ "uid-orphan-pod"
      assert stored_pod(env, "live-pod")
    end

    test "never a pod missing any of the three labels, never its own pod", env do
      put_labelled(env, "no-run-label", @labels)
      put_labelled(env, "arbiter-controller-7d9f-abc", run_labels("run-own"))
      controller = start_controller(env)
      observed("run-own", :running)

      assert %{pods: []} = Controller.reap(controller, %{install: "inst-1", live_set: []})
      assert deletes(env) == []
      assert stored_pod(env, "no-run-label")
      assert stored_pod(env, "arbiter-controller-7d9f-abc")
    end

    test "another install's pods are out of reach even if the primary asks", env do
      put_labelled(env, "foreign", %{
        "arbiter.dev/install" => "inst-2",
        "arbiter.dev/node" => "node-1",
        "arbiter.dev/run" => "run-foreign"
      })

      controller = start_controller(env)

      assert {:error, :install_mismatch} =
               Controller.reap(controller, %{install: "inst-2", live_set: []})

      assert %{pods: []} = Controller.reap(controller, %{install: "inst-1", live_set: []})
      assert deletes(env) == []
    end

    test "a run assigned a moment ago is protected from a stale live set", env do
      controller = start_controller(env)
      run = assign!(controller, 1)
      observed_pending(env, run)

      assert %{pods: []} = Controller.reap(controller, %{install: "inst-1", live_set: []})
      assert deletes(env) == []

      advance(env, 61)
      assert %{pods: [name]} = Controller.reap(controller, %{install: "inst-1", live_set: []})
      assert name == pod_name(1)
    end

    test "a missing or empty install reaps nothing", env do
      put_labelled(env, "orphan-pod", run_labels("run-orphan"))
      controller = start_controller(env)
      observed("run-orphan", :running)

      assert {:error, :no_install} = Controller.reap(controller, %{install: "", live_set: []})
      assert {:error, :no_install} = Controller.reap(controller, %{install: nil, live_set: []})
      assert deletes(env) == []
    end

    test "a reaped pod is not adopted again while it terminates", env do
      put_labelled(env, "orphan-pod", run_labels("run-orphan"))
      informer = start_informer(env)
      controller = start_controller(env, informer: informer)
      observed("run-orphan", :running)

      # A real cluster keeps the pod, stamped with a deletionTimestamp (the MODIFIED a
      # graceful delete produces), until it has gone (the DELETED).
      FakeK8sApi.graceful_deletes(env.api)
      Controller.reap(controller, %{install: "inst-1", live_set: []})
      assert Controller.report(controller).runs == []

      # Wait for the informer to have seen it terminate, then for the controller to have
      # folded that event: only then does the assertion mean something.
      await_informer(informer, fn pods ->
        Enum.any?(pods, &(get_in(&1, ["metadata", "deletionTimestamp"]) != nil))
      end)

      _ = :sys.get_state(controller)
      assert Controller.report(controller).runs == []

      FakeK8sApi.delete_pod(env.api, "orphan-pod")
      await_informer(informer, &(&1 == []))
      _ = :sys.get_state(controller)
      assert Controller.report(controller).runs == []
    end

    defp await_informer(informer, done?, deadline_ms \\ 5_000) do
      deadline = System.monotonic_time(:millisecond) + deadline_ms
      do_await_informer(informer, done?, deadline)
    end

    defp do_await_informer(informer, done?, deadline) do
      cond do
        done?.(Informer.pods(informer)) ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("the informer never reached the expected pod state")

        true ->
          Process.sleep(5)
          do_await_informer(informer, done?, deadline)
      end
    end
  end

  # -- the Lease -------------------------------------------------------------------

  describe "the Lease" do
    setup env do
      FakeK8sApi.put_lease(env.api, %{
        "apiVersion" => "coordination.k8s.io/v1",
        "kind" => "Lease",
        "metadata" => %{"name" => "arbiter-controller", "namespace" => "arb"},
        "spec" => %{"leaseDurationSeconds" => 30}
      })

      lease =
        start_supervised!(
          {Lease,
           client: env.client,
           identity: "pod-a",
           name: nil,
           interval_ms: nil,
           notify: nil,
           lease_duration_ms: 60_000,
           renew_deadline_ms: 60_000},
          id: :lease
        )

      {:ok, lease: lease}
    end

    defp lose_lease(env, lease) do
      FakeK8sApi.put_lease(env.api, %{
        "apiVersion" => "coordination.k8s.io/v1",
        "kind" => "Lease",
        "metadata" => %{"name" => "arbiter-controller", "namespace" => "arb"},
        "spec" => %{
          "holderIdentity" => "pod-b",
          "renewTime" => "2026-10-10T12:30:00.000000Z",
          "leaseDurationSeconds" => 30
        }
      })

      assert :standby = Lease.tick(lease)
    end

    test "without the lease it assigns nothing", env do
      lease = env.lease
      controller = start_controller(env, lease: lease)

      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(1))
      assert detail =~ "lease"
      assert creates(env) == []
    end

    test "with the lease it assigns; losing it stops assigning", env do
      lease = env.lease
      assert :held = Lease.tick(lease)
      controller = start_controller(env, lease: lease)
      assign!(controller, 1)

      lose_lease(env, lease)
      assert {:error, {:refuse, :no_capacity, detail}} = Controller.assign(controller, wire(2))
      assert detail =~ "lease"
      assert length(creates(env)) == 1
    end

    test "losing the lease stops reaping", env do
      lease = env.lease
      assert :held = Lease.tick(lease)
      put_labelled(env, "orphan-pod", run_labels("run-orphan"))
      controller = start_controller(env, lease: lease)
      observed("run-orphan", :running)

      lose_lease(env, lease)

      assert {:error, :not_leader} =
               Controller.reap(controller, %{install: "inst-1", live_set: []})

      assert deletes(env) == []
    end

    test "losing the lease stops the retention sweep of finished pods", env do
      lease = env.lease
      assert :held = Lease.tick(lease)
      controller = start_controller(env, lease: lease)
      run = assign!(controller, 1)
      set_status(env, pod_name(1), terminated_status(1))
      observed(run, :exit)
      :ok = Controller.exit_ack(controller, run)

      lose_lease(env, lease)
      advance(env, 10_000)
      Controller.tick(controller)
      assert deletes(env) == []
    end

    test "a cancel still goes through: stopping a run is never unsafe", env do
      lease = env.lease
      assert :held = Lease.tick(lease)
      controller = start_controller(env, lease: lease)
      run = assign!(controller, 1)
      lose_lease(env, lease)

      assert :ok = Controller.cancel(controller, run, "stop")
    end
  end

  # -- configuration -------------------------------------------------------------

  describe "configuration" do
    test "a bad ConfigMap keeps the last good config and reports degraded: bad_config", env do
      controller = start_controller(env)
      assert Controller.report(controller).degraded == []

      File.write!(env.config_path, "max_concurrent: 1\nprivileged: true")
      assert {:error, _} = ConfigLoader.reload(env.loader)

      report = Controller.report(controller)
      assert report.degraded == ["bad_config"]
      # The last good ceiling (2) is still the one in force.
      assert report.capacity["ceiling"] == 2
      assign!(controller, 1)
      assign!(controller, 2)
    end

    test "the readiness monitor's verdict rides in report/1 and is pushed when it changes", env do
      monitor =
        start_supervised!(
          {Arbiter.NodeAgent.K8s.ReadinessMonitor,
           client: env.client,
           config_fun: fn -> {:error, :no_config} end,
           autostart: false,
           interval_ms: nil}
        )

      controller = start_controller(env, readiness: monitor)

      # Fail closed: no canary has proven enforcement yet.
      report = Controller.report(controller)
      assert report.degraded == ["netpol_unenforced"]
      assert %{"ready" => false, "checks" => [%{"id" => "netpol"} | _]} = report.readiness

      send(controller, {:k8s_readiness, monitor, %{degraded: [], checks: []}})

      assert_receive {:run_push, nil, "readiness",
                      %{"degraded" => [], "readiness" => %{"ready" => true}}}, 5_000
    end

    test "a good edit changes the ceiling and pushes a capacity event", env do
      loader =
        start_supervised!({ConfigLoader, path: env.config_path, interval_ms: nil, notify: nil},
          id: :loader2
        )

      controller = start_controller(%{env | loader: loader})
      File.write!(env.config_path, "max_concurrent: 1\ntimeouts: {schedule_s: 30}")
      assert :ok = ConfigLoader.reload(loader)

      assert_receive {:run_push, nil, "capacity", %{"ceiling" => 1}}, 5_000
      assign!(controller, 1)
      assert {:error, {:refuse, :no_capacity, _}} = Controller.assign(controller, wire(2))
    end
  end

  describe "report/1" do
    test "carries hb.capacity with ceiling, running, pending, headroom, constrained", env do
      controller = start_controller(env)

      assert %{
               "ceiling" => 2,
               "running" => 0,
               "pending" => 0,
               "headroom" => 2,
               "constrained" => false
             } = Controller.report(controller).capacity
    end

    test "headroom follows the quota", env do
      FakeK8sApi.put_quota(env.api, %{
        "metadata" => %{"name" => "q"},
        "status" => %{"hard" => %{"pods" => "5"}, "used" => %{"pods" => "4"}}
      })

      controller = start_controller(env)
      assert :ok = Controller.tick(controller)
      assert %{"headroom" => 1} = Controller.report(controller).capacity
    end
  end

  # -- more helpers (kept after the tests that use them read best) ---------------

  defp observed_ready(env, _controller, n) do
    set_status(env, pod_name(n), running_status())
    observed(run_id(n), :running)
  end

  defp observed_pending(_env, run) do
    # The ADDED event for the pod we just created.
    observed(run, :pending)
  end

  defp flush_pushes do
    receive do
      {:run_push, _, _, _} -> flush_pushes()
    after
      0 -> :ok
    end
  end
end
