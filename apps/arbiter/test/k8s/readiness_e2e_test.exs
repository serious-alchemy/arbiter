defmodule Arbiter.K8s.ReadinessE2ETest do
  @moduledoc """
  K13 end to end, on a **disposable** kind or k3d cluster (`Arbiter.Test.K8sE2E` says how
  it is guarded; `scripts/k8s-e2e.sh` runs it; `docs/remote-workers-k8s-runbook.md`
  explains it). Tagged `:k8s`: excluded from the default run and from CI.

  What it proves that the fake API server cannot:

    * the canary, built by the worker's own pod builder, is **admitted** by real Pod
      Security `restricted` and really runs;
    * on a cluster whose CNI enforces NetworkPolicy, with the bootstrap policies, the
      canary connects to the bridge port and to nothing else: `:enforced`;
    * the same canary in a namespace **without** the policies reaches the API, the
      internet and the node, and is reported `:unenforced` (`degraded: netpol_unenforced`);
    * the readiness checks (Pod Security, PriorityClass, quota, image pull, clock)
      are ok against a correctly prepared namespace;
    * the monitor drives all of it and fails closed.
  """
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.Readiness
  alias Arbiter.NodeAgent.K8s.ReadinessMonitor
  alias Arbiter.Test.K8sE2E

  @moduletag :k8s
  @moduletag timeout: 600_000

  @canary_opts [timeout_ms: 240_000, poll_ms: 1_000]

  setup_all do
    %{env: K8sE2E.connect!()}
  end

  defp canary_opts(env, ns),
    do: [image: K8sE2E.image(), targets: K8sE2E.targets(env, ns)] ++ @canary_opts

  describe "a namespace with the bootstrap NetworkPolicies" do
    setup %{env: env} do
      ns = K8sE2E.namespace!(env, policies: true)
      %{ns: ns, client: K8sE2E.client(env, ns.namespace), config: K8sE2E.pod_config(env, ns)}
    end

    test "the canary is admitted, runs, and proves enforcement", ctx do
      result = Canary.run(ctx.client, ctx.config, canary_opts(ctx.env, ctx.ns))

      assert %{outcome: :enforced, open: [], bridge: :open, pull: :ok, skipped: []} = result
      # The canary cleans up after itself.
      assert {:ok, %{items: []}} =
               Client.list_pods(ctx.client, label_selector: "app.kubernetes.io/component=worker")
    end

    test "every readiness check is ok", ctx do
      canary = Canary.run(ctx.client, ctx.config, canary_opts(ctx.env, ctx.ns))
      checks = Readiness.run(ctx.client, ctx.config, canary, image: K8sE2E.image())

      for check <- [Readiness.netpol(canary) | checks] do
        assert check["status"] == "ok", "#{check["id"]}: #{check["detail"]}"
      end
    end

    test "the monitor reports no degradation", ctx do
      monitor =
        start_supervised!(
          {ReadinessMonitor,
           client: ctx.client,
           config_fun: fn -> {:ok, ctx.config} end,
           image: K8sE2E.image(),
           targets: K8sE2E.targets(ctx.env, ctx.ns),
           interval_ms: nil,
           timeout_ms: 240_000,
           poll_ms: 1_000,
           autostart: false}
        )

      assert %{degraded: ["netpol_unenforced"]} =
               ReadinessMonitor.report(monitor)

      assert %{degraded: [], checks: [%{"id" => "netpol", "status" => "ok"} | _]} =
               ReadinessMonitor.refresh(monitor)
    end
  end

  describe "a namespace WITHOUT NetworkPolicies (what an unenforcing cluster looks like)" do
    setup %{env: env} do
      ns = K8sE2E.namespace!(env, policies: false)
      %{ns: ns, client: K8sE2E.client(env, ns.namespace), config: K8sE2E.pod_config(env, ns)}
    end

    test "the canary detects it: unenforced", ctx do
      result = Canary.run(ctx.client, ctx.config, canary_opts(ctx.env, ctx.ns))

      assert %{outcome: :unenforced, open: open} = result
      assert open != []
      assert %{"status" => "fail"} = Readiness.netpol(result)
    end

    test "the monitor marks the node netpol_unenforced", ctx do
      monitor =
        start_supervised!(
          {ReadinessMonitor,
           client: ctx.client,
           config_fun: fn -> {:ok, ctx.config} end,
           image: K8sE2E.image(),
           targets: K8sE2E.targets(ctx.env, ctx.ns),
           interval_ms: nil,
           timeout_ms: 240_000,
           poll_ms: 1_000,
           autostart: false}
        )

      assert %{degraded: ["netpol_unenforced"], canary: %{outcome: :unenforced}} =
               ReadinessMonitor.refresh(monitor)
    end
  end
end
