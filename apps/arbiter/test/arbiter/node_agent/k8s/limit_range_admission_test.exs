defmodule Arbiter.NodeAgent.K8s.LimitRangeAdmissionTest do
  @moduledoc """
  KH2 (bd-3rdz1h, `docs/design/remote-workers.md` §20.2, H14): the `LimitRange` the
  install renders must *admit* the pod `PodSpec` builds, and that pod must fit the
  rendered `ResourceQuota` at `max_concurrent`. The API server's `LimitRanger` is
  re-implemented here in miniature (defaults, then `Container` `max` / `min` /
  `maxLimitRequestRatio`, then the `Pod` `max` over the effective pod) so a number
  moved in one place and not the other fails this test and not a live `POST pods`.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures, only: [build!: 2, run_spec: 1]

  alias Arbiter.Test.K8sPodFixtures, as: Fx

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.ControllerConfig
  alias Arbiter.NodeAgent.K8s.InstallManifest
  alias Arbiter.NodeAgent.K8s.Quota
  alias Arbiter.NodeAgent.K8s.Readiness

  @server [image: "img:1", primary_url: "https://arbiter.example.test", registry: "r.test/a"]

  defp install(params) do
    {:ok, spec} =
      InstallManifest.parse(
        Map.merge(%{"name" => "n1", "primary_cidrs" => "100.64.0.10/32"}, params)
      )

    %{bootstrap: bootstrap, node: node} = InstallManifest.documents(spec, @server)
    config_map = Enum.find(node, &(&1["kind"] == "ConfigMap" and has_config?(&1)))
    {:ok, controller_config} = ControllerConfig.parse(config_map["data"]["controller.yaml"])

    %{
      limit_range: Enum.find(bootstrap, &(&1["kind"] == "LimitRange")),
      quota: Enum.find(bootstrap, &(&1["kind"] == "ResourceQuota")),
      deployment: Enum.find(node, &(&1["kind"] == "Deployment")),
      max_concurrent: controller_config.max_concurrent,
      pod_config: ControllerConfig.pod_config(controller_config, %{})
    }
  end

  defp has_config?(%{"data" => %{"controller.yaml" => _}}), do: true
  defp has_config?(_), do: false

  # -- a miniature LimitRanger -----------------------------------------------------------

  defp limits_of(%{"limits" => limits}, type), do: Enum.find(limits, &(&1["type"] == type))

  defp parse!(name, value) do
    n = Quota.parse_quantity(name, value)
    true = is_integer(n)
    n
  end

  # Defaulting, in the API server's order: a request defaults to an explicit limit,
  # then the LimitRange fills what is still missing.
  defp defaulted(container, %{} = container_range) do
    resources = container["resources"] || %{}
    limits = resources["limits"] || %{}
    requests = resources["requests"] || %{}
    default_limit = container_range["default"] || %{}
    default_request = container_range["defaultRequest"] || %{}

    requests = Map.merge(Map.take(limits, Map.keys(default_request)), requests)
    requests = Map.merge(default_request, requests)
    limits = Map.merge(default_limit, limits)
    %{limits: limits, requests: requests}
  end

  defp container_violations(name, %{limits: limits, requests: requests}, range) do
    max = range["max"] || %{}
    ratio = range["maxLimitRequestRatio"] || %{}

    over =
      for {res, cap} <- max,
          value = limits[res] || requests[res],
          parse!(res, value) > parse!(res, cap),
          do: "#{name}: #{res} #{value} > max #{cap}"

    ratios =
      for {res, r} <- ratio,
          limit = limits[res],
          request = requests[res],
          parse!(res, limit) > parse!(res, request) * parse_ratio(r),
          do: "#{name}: #{res} limit #{limit} / request #{request} > #{r}"

    missing =
      for {res, _} <- ratio,
          is_nil(limits[res]) or is_nil(requests[res]),
          do: "#{name}: #{res} unset"

    over ++ ratios ++ missing
  end

  defp parse_ratio(r) when is_binary(r), do: r |> Integer.parse() |> elem(0)
  defp parse_ratio(r) when is_integer(r), do: r

  defp pod_containers(pod),
    do: (pod["spec"]["initContainers"] || []) ++ pod["spec"]["containers"]

  # Refusals for `pod` under `limit_range`; [] means admitted.
  defp admit(pod, limit_range) do
    container_range = limits_of(limit_range["spec"], "Container")
    pod_range = limits_of(limit_range["spec"], "Pod")

    container_problems =
      Enum.flat_map(pod_containers(pod), fn c ->
        container_violations(c["name"], defaulted(c, container_range), container_range)
      end)

    effective = Quota.effective_pod(pod)

    pod_problems =
      for {res, cap} <- pod_range["max"] || %{},
          used = effective["limits." <> res],
          used > parse!(res, cap),
          do: "pod: limits.#{res} #{used} > max #{cap}"

    container_problems ++ pod_problems
  end

  defp assert_admitted(pod, limit_range) do
    assert admit(pod, limit_range) == [], "LimitRange refuses the worker pod"
  end

  # ---------------------------------------------------------------------------------------

  for {label, params} <- [
        {"defaults", %{}},
        {"tailscale reach", %{"reach" => "tailscale"}},
        {"bigger workers", %{"cpu" => "2", "memory" => "4Gi", "max" => "5"}}
      ] do
    describe "install with #{label}" do
      setup do
        {:ok, install: install(unquote(Macro.escape(params)))}
      end

      test "the worker pod PodSpec builds is admitted: container max and ratio, Pod max", %{
        install: i
      } do
        pod = build!(nil, i.pod_config)
        assert_admitted(pod, i.limit_range)
      end

      test "a pod with a run service sidecar is admitted too", %{install: i} do
        pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}), i.pod_config)
        assert_admitted(pod, i.limit_range)
      end

      test "the controller and tailscale pod is admitted (the ratio binds every container)", %{
        install: i
      } do
        assert_admitted(i.deployment["spec"]["template"], i.limit_range)
      end

      test "every other pod Arbiter creates is admitted: canary, sandbox probe, dry runs", %{
        install: i
      } do
        opts = [image: "#{Fx.registry()}/beam@sha256:#{Fx.digest()}", targets: %{}]
        config = Fx.config(i.pod_config)

        {:ok, canary} = Canary.pod(config, opts)
        {:ok, sandbox} = Canary.sandbox_probe_pod(config, opts)
        {:ok, dry} = Canary.dry_run_pod(config, opts)

        for {name, pod} <- [
              canary: canary,
              sandbox_probe: sandbox,
              dry_run: dry,
              psa_probe: Readiness.psa_probe_pod(dry)
            ] do
          assert admit(pod, i.limit_range) == [], "LimitRange refuses the #{name} pod"
        end

        # a probe pod takes at most a worker pod's slot in the quota (`pods` has a spare)
        worker = Quota.effective_pod(build!(nil, i.pod_config))

        for {name, pod} <- [canary: canary, sandbox_probe: sandbox],
            {res, used} <- Quota.effective_pod(pod) do
          assert used <= Map.get(worker, res, 0), "#{name}: #{res} #{used} > a worker pod's"
        end
      end

      test "the pod fits the quota at max_concurrent, controller included", %{install: i} do
        n = i.max_concurrent
        worker = Quota.effective_pod(build!(nil, i.pod_config))
        controller = Quota.effective_pod(i.deployment["spec"]["template"])

        for {name, limit} <- i.quota["spec"]["hard"] do
          total = n * Map.get(worker, name, 0) + Map.get(controller, name, 0)
          assert total <= Quota.parse_quantity(name, limit), "#{name}: #{total} > #{limit}"
        end
      end
    end
  end

  describe "the simulator itself" do
    test "refuses a pod the old defaults-only shape could not bound" do
      i = install(%{})

      pod = build!(nil, i.pod_config)
      huge = put_in(hd(pod["spec"]["containers"]), ["resources", "limits", "cpu"], "64")
      pod = put_in(pod, ["spec", "containers"], [huge])

      assert Enum.any?(admit(pod, i.limit_range), &String.contains?(&1, "cpu"))
    end

    test "refuses a Pod max equal to the worker limit (H14): sidecars push the pod over it" do
      i = install(%{})
      pod = build!(nil, i.pod_config)

      worker_limits = hd(pod["spec"]["containers"])["resources"]["limits"]

      tight =
        update_in(i.limit_range, ["spec", "limits"], fn limits ->
          Enum.map(limits, fn
            %{"type" => "Pod"} = l -> %{l | "max" => worker_limits}
            l -> l
          end)
        end)

      assert Enum.any?(admit(pod, tight), &String.starts_with?(&1, "pod:"))
    end
  end
end
