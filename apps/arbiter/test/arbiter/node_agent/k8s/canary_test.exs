defmodule Arbiter.NodeAgent.K8s.CanaryTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.PodSecurity
  alias Arbiter.Test.FakeK8sApi
  alias Arbiter.Test.K8sPodFixtures, as: Fx

  @targets %{
    api: "10.43.0.1:443",
    controller_port: "10.42.1.9:9445",
    foreign: "10.43.0.10:53",
    node: "192.168.1.169:10250"
  }

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        image: "#{Fx.registry()}/beam@sha256:#{Fx.digest()}",
        targets: @targets,
        id: "c0ffee1234",
        poll_ms: 5,
        timeout_ms: 2_000
      ],
      extra
    )
  end

  defp pod!(extra \\ []) do
    {:ok, pod} = Canary.pod(Fx.config(), opts(extra))
    pod
  end

  describe "pod/2" do
    test "carries the worker's own labels so the real policies select it, but no run label" do
      labels = pod!()["metadata"]["labels"]

      assert labels["app.kubernetes.io/component"] == "worker"
      assert labels["app.kubernetes.io/name"] == "arbiter-worker"
      assert labels["arbiter.dev/install"] == "inst-1"
      assert labels["arbiter.dev/node"] == "node-1"
      assert labels["arbiter.dev/canary"] == "c0ffee1234"
      # No run label: the controller's adoption and the sweeper key on it, so the canary
      # is never adopted as a run nor counted against capacity.
      refute Map.has_key?(labels, "arbiter.dev/run")
      refute Map.has_key?(labels, "arbiter.dev/task")
    end

    test "is built by the worker builder: same service account, security context, owner" do
      worker_pod = Fx.build!()
      pod = pod!()

      assert pod["spec"]["serviceAccountName"] == worker_pod["spec"]["serviceAccountName"]
      assert pod["spec"]["securityContext"] == worker_pod["spec"]["securityContext"]
      assert pod["spec"]["dnsPolicy"] == "None"
      assert pod["spec"]["hostUsers"] == false
      assert pod["spec"]["automountServiceAccountToken"] == false
      assert pod["metadata"]["ownerReferences"] == worker_pod["metadata"]["ownerReferences"]
      assert pod["spec"]["priorityClassName"] == worker_pod["spec"]["priorityClassName"]
    end

    test "passes the Pod Security restricted checker" do
      assert PodSecurity.violations(pod!()) == []
    end

    test "runs the netpol gate first, then only the probe script; no seed, no snapshotter" do
      pod = pod!()
      assert [seed] = pod["spec"]["initContainers"]
      assert seed["name"] == "seed"
      script = List.last(seed["command"])
      assert script =~ "ARB_GATE_ADDR"
      refute script =~ "/opt/arbiter/bin/seed"

      assert [worker] = pod["spec"]["containers"]
      assert worker["name"] == "worker"
      worker_script = List.last(worker["command"])
      assert worker_script =~ "probe "
      refute worker_script =~ "/run/arb/env"
    end

    test "hands the probe targets to the worker as env, and no secret" do
      env = pod!() |> Fx.worker() |> Map.fetch!("env") |> Map.new(&{&1["name"], &1["value"]})

      assert env["ARB_CANARY_API_ADDR"] == "10.43.0.1:443"
      assert env["ARB_CANARY_CONTROLLER_PORT_ADDR"] == "10.42.1.9:9445"
      assert env["ARB_CANARY_FOREIGN_ADDR"] == "10.43.0.10:53"
      assert env["ARB_CANARY_NODE_ADDR"] == "192.168.1.169:10250"
      assert env["ARB_CANARY_BRIDGE_ADDR"] == "10.43.98.199:9443"
      refute Enum.any?(Map.keys(env), &String.contains?(&1, "TOKEN"))
    end

    test "a target the cluster cannot name is left out, not guessed" do
      env =
        pod!(targets: Map.delete(@targets, :foreign))
        |> Fx.worker()
        |> Map.fetch!("env")
        |> Map.new(&{&1["name"], &1["value"]})

      assert env["ARB_CANARY_FOREIGN_ADDR"] == ""
    end

    test "asks for little: the quota sees small requests and a short deadline" do
      pod = pod!()
      worker = Fx.worker(pod)
      assert worker["resources"]["requests"]["cpu"] == "50m"
      assert pod["spec"]["activeDeadlineSeconds"] <= 300
    end

    test "refuses an image outside the configured registry (the builder's own rule)" do
      assert {:error, {:bad_spec, _}} =
               Canary.pod(Fx.config(), opts(image: "evil.example/beam@sha256:#{Fx.digest()}"))
    end
  end

  describe "parse/1 and verdict/1" do
    @all_closed """
    probe api closed
    probe controller_port closed
    probe foreign closed
    probe internet closed
    probe node closed
    probe bridge open
    canary done
    """

    test "everything closed and the bridge open is enforced" do
      assert {:enforced, %{bridge: :open, skipped: []}} =
               @all_closed |> Canary.parse() |> Canary.verdict()
    end

    for probe <- ~w(api controller_port foreign internet node) do
      test "an open #{probe} probe is unenforced" do
        log = String.replace(@all_closed, "probe #{unquote(probe)} closed", "probe #{unquote(probe)} open")

        assert {:unenforced, [unquote(probe)]} = log |> Canary.parse() |> Canary.verdict()
      end
    end

    test "an open probe is unenforced even when the log is cut short" do
      assert {:unenforced, ["internet"]} =
               "probe api closed\nprobe internet open\n" |> Canary.parse() |> Canary.verdict()
    end

    test "a closed bridge does not make the policy unenforced, it is reported" do
      log = String.replace(@all_closed, "probe bridge open", "probe bridge closed")

      assert {:enforced, %{bridge: :closed}} = log |> Canary.parse() |> Canary.verdict()
    end

    test "skipped optional probes are listed" do
      log = String.replace(@all_closed, "probe foreign closed", "probe foreign skipped")

      assert {:enforced, %{skipped: ["foreign"]}} = log |> Canary.parse() |> Canary.verdict()
    end

    test "without the always-known api and internet probes it proves nothing" do
      assert {:inconclusive, {:missing_probes, missing}} =
               "probe node closed\ncanary done\n" |> Canary.parse() |> Canary.verdict()

      assert "api" in missing and "internet" in missing
    end

    test "a log with no done marker proves nothing" do
      log = String.replace(@all_closed, "canary done\n", "")
      assert {:inconclusive, :log_truncated} = log |> Canary.parse() |> Canary.verdict()
    end

    test "garbage proves nothing" do
      assert {:inconclusive, _} = "segfault\n" |> Canary.parse() |> Canary.verdict()
      assert {:inconclusive, _} = "" |> Canary.parse() |> Canary.verdict()
    end
  end

  # -- run/3 against the fake API ---------------------------------------------------

  defp finished(phase, log, extra \\ %{}) do
    fn pod ->
      status = Map.merge(%{"phase" => phase}, extra)
      {Map.put(pod, "status", status), String.split(log, "\n", trim: true)}
    end
  end

  setup do
    {:ok, FakeK8sApi.start!(namespace: "arbiter-workers")}
  end

  describe "run/3" do
    test "an all-closed pod is enforced, and the canary pod is deleted afterwards", %{
      client: client,
      api: api
    } do
      FakeK8sApi.on_create(api, finished("Succeeded", @all_closed))

      assert %{outcome: :enforced, bridge: :open, pull: :ok} =
               Canary.run(client, Fx.config(), opts())

      assert {:ok, %{items: []}} = Arbiter.NodeAgent.K8s.Client.list_pods(client)
      assert [%{method: "POST"} | _] = FakeK8sApi.requests(api)
    end

    test "a probe that connected is unenforced", %{client: client, api: api} do
      log = String.replace(@all_closed, "probe internet closed", "probe internet open")
      FakeK8sApi.on_create(api, finished("Succeeded", log))

      assert %{outcome: :unenforced, open: ["internet"]} =
               Canary.run(client, Fx.config(), opts())
    end

    test "the gate failing (seed exit 70) is unenforced without any probe", %{
      client: client,
      api: api
    } do
      status = %{
        "initContainerStatuses" => [
          %{"name" => "seed", "state" => %{"terminated" => %{"exitCode" => 70}}}
        ]
      }

      FakeK8sApi.on_create(api, finished("Failed", "", status))

      assert %{outcome: :unenforced, open: ["gate"]} = Canary.run(client, Fx.config(), opts())
    end

    test "an image that cannot be pulled is inconclusive and reported as a pull failure", %{
      client: client,
      api: api
    } do
      status = %{
        "phase" => "Pending",
        "initContainerStatuses" => [
          %{
            "name" => "seed",
            "state" => %{
              "waiting" => %{"reason" => "ImagePullBackOff", "message" => "denied: requires auth"}
            }
          }
        ]
      }

      FakeK8sApi.on_create(api, fn pod -> {Map.put(pod, "status", status), []} end)

      assert %{outcome: :inconclusive, pull: {:failed, "denied: requires auth"}} =
               Canary.run(client, Fx.config(), opts())

      assert {:ok, %{items: []}} = Arbiter.NodeAgent.K8s.Client.list_pods(client)
    end

    test "a pod that never finishes times out inconclusive and is still deleted", %{
      client: client,
      api: api
    } do
      FakeK8sApi.on_create(api, fn pod -> {Map.put(pod, "status", %{"phase" => "Running"}), []} end)

      assert %{outcome: :inconclusive, reason: :timeout} =
               Canary.run(client, Fx.config(), opts(timeout_ms: 50))

      assert {:ok, %{items: []}} = Arbiter.NodeAgent.K8s.Client.list_pods(client)
    end

    test "an API refusal to create the pod is inconclusive with the message", %{
      client: client,
      api: api
    } do
      FakeK8sApi.fail_next(api, :create, {403, "exceeded quota: arbiter-workers"})

      assert %{outcome: :inconclusive, reason: {:create_failed, {:forbidden, msg}}} =
               Canary.run(client, Fx.config(), opts())

      assert msg =~ "exceeded quota"
    end

    test "a bad image is inconclusive without touching the API", %{client: client, api: api} do
      assert %{outcome: :inconclusive, reason: {:bad_canary, {:bad_spec, _}}} =
               Canary.run(client, Fx.config(), opts(image: "nope"))

      assert FakeK8sApi.requests(api) == []
    end
  end
end
