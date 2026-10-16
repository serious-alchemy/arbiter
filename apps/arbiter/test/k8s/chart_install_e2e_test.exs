defmodule Arbiter.K8s.ChartInstallE2ETest do
  @moduledoc """
  KH6 (bd-19mn3u, `docs/design/remote-workers.md` §20.14): the `charts/arbiter-node` Helm
  chart installed on a **disposable** kind or k3d cluster, and the readiness canary run
  against what that install made. Guarded exactly like `Arbiter.K8s.ReadinessE2ETest`
  (`Arbiter.Test.K8sE2E`; `scripts/k8s-e2e.sh`; `docs/remote-workers-k8s-runbook.md`) and
  additionally needs `helm` on `PATH`.

  What it proves that rendering the chart cannot:

    * a real API server **accepts** every object the chart renders (`helm install`, with
      Pod Security `restricted` enforced on the namespace);
    * the chart's ResourceQuota, LimitRange and PriorityClass admit the canary pod the
      worker pod builder produces;
    * on a cluster whose CNI enforces NetworkPolicy, the chart's four NetworkPolicies
      leave the canary able to reach the bridge port and nothing else: `:enforced`;
    * every readiness check is `ok` against the chart's install;

  The controller itself is the `socat` stand-in `K8sE2E.namespace!/2` uses (the real image
  is not on a throwaway cluster); see `K8sE2E.chart_namespace!/2`.
  """
  use ExUnit.Case, async: false

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.Readiness
  alias Arbiter.Test.K8sE2E

  @moduletag :k8s
  @moduletag timeout: 900_000

  @canary_opts [timeout_ms: 240_000, poll_ms: 1_000]

  setup_all do
    %{env: K8sE2E.connect!()}
  end

  setup %{env: env} do
    ns = K8sE2E.chart_namespace!(env)
    %{ns: ns, client: K8sE2E.client(env, ns.namespace), config: K8sE2E.pod_config(env, ns)}
  end

  defp canary_opts(env, ns),
    do: [image: K8sE2E.image(), targets: K8sE2E.targets(env, ns)] ++ @canary_opts

  test "helm reports the release deployed and the cluster holds the chart's guardrails", ctx do
    status =
      ctx.env
      |> K8sE2E.helm!(["status", ctx.ns.release, "-n", ctx.ns.namespace, "-o", "json"])
      |> Jason.decode!()

    assert status["info"]["status"] == "deployed"

    {out, 0} =
      K8sE2E.kubectl(ctx.env, ["-n", ctx.ns.namespace, "get", "networkpolicy", "-o", "name"])

    assert out |> String.split("\n", trim: true) |> Enum.sort() ==
             Enum.sort(~w(
               networkpolicy.networking.k8s.io/controller-egress
               networkpolicy.networking.k8s.io/controller-ingress-from-workers
               networkpolicy.networking.k8s.io/default-deny
               networkpolicy.networking.k8s.io/worker-to-controller
             ))

    for kind <- ~w(resourcequota limitrange),
        do: K8sE2E.kubectl!(ctx.env, ["-n", ctx.ns.namespace, "get", kind, "arbiter-workers"])

    K8sE2E.kubectl!(ctx.env, ["get", "priorityclass", ctx.ns.priority_class])
  end

  test "the canary is admitted, runs, and proves enforcement", ctx do
    result = Canary.run(ctx.client, ctx.config, canary_opts(ctx.env, ctx.ns))

    assert %{outcome: :enforced, open: [], bridge: :open, pull: :ok, skipped: []} = result

    assert {:ok, %{items: []}} =
             Client.list_pods(ctx.client, label_selector: "app.kubernetes.io/component=worker")
  end

  test "every readiness check is ok against the chart's install", ctx do
    canary = Canary.run(ctx.client, ctx.config, canary_opts(ctx.env, ctx.ns))
    checks = Readiness.run(ctx.client, ctx.config, canary, image: K8sE2E.image())

    for check <- [Readiness.netpol(canary) | checks] do
      assert check["status"] == "ok", "#{check["id"]}: #{check["detail"]}"
    end
  end
end
