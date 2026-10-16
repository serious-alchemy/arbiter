defmodule Arbiter.NodeAgent.K8s.HelmChartParityTest do
  @moduledoc """
  KH6 (bd-19mn3u, `docs/design/remote-workers.md` §20.14, OD9): the hand-written
  `charts/arbiter-node` chart and `InstallManifest.render/2` are two renderers of one
  install, and this test is what keeps them from drifting.

  For each equivalent configuration both are rendered and every document is compared,
  field for field, after a short, explicit normalisation (`@known_deltas`). Anything
  outside that list is a failure that names the object and the path, so a field added to
  one renderer and not the other is caught here rather than on a customer's cluster.

  `controller.yaml` is compared as the controller reads it: through `ControllerConfig`,
  because the chart spells out defaults (`placement.priority_class`, the spread) that the
  raw renderer leaves to the controller. The round-trip tests then feed the other
  direction: values in, `ControllerConfig` out.

  Tagged `:helm` and skipped where `helm` is not on PATH (CI's `helm-chart` job and
  the test shards have it).
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.{ControllerConfig, InstallManifest}

  @moduletag :helm
  @chart Path.expand("../../../../../../charts/arbiter-node", __DIR__)
  @helm System.find_executable("helm")
  @moduletag skip: is_nil(@helm) && "helm is not installed"

  @image_repository "ghcr.io/ryanrborn/arbiter-controller"
  @image_tag "9.9.9"
  @primary_url "https://arbiter.example.test"
  @primary_cidrs "100.64.0.10/32,100.64.0.11/32"
  @registry "registry.example.test/arbiter"

  # The only places the chart and the raw renderer are ALLOWED to differ. Each is a
  # property of Helm or of the install method, not of the install itself.
  @helm_labels ~w(helm.sh/chart app.kubernetes.io/managed-by app.kubernetes.io/part-of)
  # The controller reads these three to tell the primary how to upgrade it (KH8); a raw
  # install has no release and no chart to name.
  @helm_env ~w(ARB_INSTALL_METHOD ARB_HELM_RELEASE ARB_CHART_REF)

  # name | InstallManifest params | helm --set arguments that say the same thing
  @scenarios [
    {"default (direct, self-upgrade off)", %{"self_upgrade" => "off"}, []},
    {"tailscale", %{"reach" => "tailscale", "primary_cidrs" => "", "self_upgrade" => "off"},
     ["reach.mode=tailscale"]},
    {"proxy",
     %{
       "reach" => "proxy",
       "proxy_url" => "http://proxy.example.test:3128",
       "proxy_cidrs" => "10.9.0.5/32",
       "self_upgrade" => "off"
     },
     [
       "reach.mode=proxy",
       "reach.proxy.url=http://proxy.example.test:3128",
       "reach.proxy.cidrs={10.9.0.5/32}"
     ]},
    {"admission policy and a registry pull secret",
     %{"admission" => "policy", "pull_secret" => "arbiter-registry", "self_upgrade" => "off"},
     [
       "admissionPolicy.enabled=true",
       "registries[0].prefix=#{@registry}",
       "registries[0].pullSecret=arbiter-registry"
     ]},
    {"node selector, API server addresses and another namespace",
     %{
       "namespace" => "ci-workers",
       "node_selector" => "pool=ci,disk=ssd",
       "api_cidrs" => "192.0.2.10/32",
       "self_upgrade" => "off"
     },
     [
       "placement.nodeSelector.pool=ci",
       "placement.nodeSelector.disk=ssd",
       "networkPolicy.apiServerCIDRs={10.43.0.1/32,192.0.2.10/32}"
     ]}
  ]

  describe "the chart and InstallManifest.render/2" do
    for {name, params, sets} <- @scenarios do
      test "render the same objects for #{name}" do
        assert_parity(unquote(Macro.escape(params)), unquote(Macro.escape(sets)), :all)
      end
    end

    test "mode bootstrap is the raw bootstrap part, mode node the raw node part" do
      assert_parity(%{"self_upgrade" => "off"}, ["mode=bootstrap"], :bootstrap)
      assert_parity(%{"self_upgrade" => "off"}, ["mode=node"], :node)
    end

    test "the normalisation is not hiding a real difference" do
      {raw, chart} = both(%{"self_upgrade" => "off"}, [])
      {:ok, other_spec} = InstallManifest.parse(base_params(%{"max" => "3"}))
      {:ok, other_raw} = InstallManifest.render(other_spec, server())

      assert drift(other_raw, chart) != [], "a different max_concurrent went unnoticed"

      # And the unmodified pair really is the same, with the deltas taken out.
      assert drift(raw, chart) == []
      assert Enum.any?(chart, &helm_label?/1), "the chart no longer labels its objects"
    end

    test "the allowed deltas are real: the chart carries them and the raw manifests do not" do
      {raw, chart} = both(%{"self_upgrade" => "off"}, [])

      refute Enum.any?(raw, &helm_label?/1)
      refute Enum.any?(chart, &(&1["kind"] == "Namespace"))
      assert Enum.any?(raw, &(&1["kind"] == "Namespace"))

      env = chart |> find!("Deployment", "arbiter-controller") |> controller_env()
      for name <- @helm_env, do: assert(Map.has_key?(env, name), "chart lacks #{name}")

      raw_env = raw |> find!("Deployment", "arbiter-controller") |> controller_env()
      for name <- @helm_env, do: refute(Map.has_key?(raw_env, name))
    end
  end

  describe "ControllerConfig round-trips through values" do
    test "every controller.yaml key the chart exposes comes back out of the controller's parser" do
      docs =
        render!(
          direct() ++
            [
              "concurrency.max=3",
              "workers.requests.cpu=500m",
              "workers.requests.memory=1Gi",
              "workers.requests.ephemeral-storage=2Gi",
              "workers.limits.cpu=1",
              "workers.limits.memory=2Gi",
              "workers.workSizeLimit=6Gi",
              "workers.tmpSizeLimit=512Mi",
              "workers.timeouts.pull_s=900",
              "workers.timeouts.boot_s=60",
              "workers.snapshotIntervalS=120",
              "workers.servicesResources.requests.cpu=250m",
              "workers.servicesResources.requests.memory=256Mi",
              "workers.servicesResources.limits.cpu=500m",
              "workers.servicesResources.limits.memory=512Mi",
              "placement.nodeSelector.pool=ci",
              "placement.tolerations[0].key=dedicated",
              "placement.tolerations[0].operator=Exists",
              "placement.spread.maxSkew=2",
              "placement.spread.whenUnsatisfiable=DoNotSchedule",
              "placement.priorityClass.name=arbiter-ci",
              "registries[0].prefix=#{@registry}",
              "registries[0].pullSecret=arbiter-registry"
            ]
        )

      assert {:ok, config} = controller_config(docs)

      assert config.max_concurrent == 3
      assert config.namespace == "arbiter-workers"

      assert config.worker["requests"] == %{
               "cpu" => "500m",
               "memory" => "1Gi",
               "ephemeral-storage" => "2Gi"
             }

      assert %{"cpu" => "1", "memory" => "2Gi"} = config.worker["limits"]
      assert config.worker["work_size_limit"] == "6Gi"
      assert config.worker["tmp_size_limit"] == "512Mi"
      assert config.timeouts["pull_s"] == 900
      assert config.timeouts["boot_s"] == 60
      assert config.timeouts["schedule_s"] == 120, "an unset timeout must stay the controller's"
      assert config.snapshot_interval_s == 120

      assert %{
               "requests" => %{"cpu" => "250m", "memory" => "256Mi"},
               "limits" => %{"cpu" => "500m", "memory" => "512Mi"}
             } = config.services_resources

      assert config.placement["node_selector"] == %{"pool" => "ci"}
      assert [%{"key" => "dedicated", "operator" => "Exists"}] = config.placement["tolerations"]
      assert config.placement["priority_class"] == "arbiter-ci"
      assert config.placement["spread"]["max_skew"] == 2
      assert config.placement["spread"]["when_unsatisfiable"] == "DoNotSchedule"
      assert config.image_pull_secrets == ["arbiter-registry"]
    end

    test "the shipped defaults parse to the controller's own defaults" do
      assert {:ok, config} = controller_config(render!(direct()))
      assert {:ok, bare} = ControllerConfig.from_map(%{})

      assert config.max_concurrent == bare.max_concurrent
      assert config.timeouts == bare.timeouts
      assert config.placement["node_selector"] in [nil, %{}]
      assert config.image_pull_secrets in [nil, []]
    end

    test "the chart's controller.yaml equals the raw renderer's for the same shape" do
      shapes = [
        {%{"max" => "3", "cpu" => "500m", "memory" => "1Gi"},
         [
           "concurrency.max=3",
           "workers.requests.cpu=500m",
           "workers.requests.memory=1Gi",
           "workers.limits.cpu=1",
           "workers.limits.memory=2Gi"
         ]},
        {%{"node_selector" => "pool=ci", "pull_secret" => "regcred"},
         [
           "placement.nodeSelector.pool=ci",
           "registries[0].prefix=#{@registry}",
           "registries[0].pullSecret=regcred"
         ]}
      ]

      for {params, sets} <- shapes do
        {:ok, spec} = InstallManifest.parse(base_params(params))
        {:ok, raw} = InstallManifest.render(spec, server())
        assert {:ok, from_raw} = controller_config(raw)
        assert {:ok, from_chart} = controller_config(render!(direct() ++ sets))

        # The chart names the PriorityClass and spread explicitly; the raw renderer lets
        # the controller default them. Everything else must agree.
        assert Map.drop(from_chart, [:placement]) == Map.drop(from_raw, [:placement]),
               "shape #{inspect(params)}"

        assert from_chart.placement["node_selector"] == from_raw.placement["node_selector"]
      end
    end

    test "a key the controller's closed schema refuses is not reachable through values" do
      assert {:error, out} = helm_template(direct() ++ ["workers.serviceImageAllowlist={x}"])
      assert out =~ "serviceImageAllowlist"

      assert {:error, {:bad_config, {:unknown_key, "securityContext"}}} =
               ControllerConfig.from_map(%{"securityContext" => %{}})
    end
  end

  # ---- parity ---------------------------------------------------------------------

  defp assert_parity(params, sets, part) do
    {raw, chart} = both(params, sets, part)

    case drift(raw, chart) do
      [] -> :ok
      lines -> flunk("chart and InstallManifest disagree:\n" <> Enum.join(lines, "\n"))
    end
  end

  # Raw and chart documents for the same configuration.
  defp both(params, sets, part \\ :all) do
    {:ok, spec} = InstallManifest.parse(base_params(Map.put(params, "part", to_string(part))))
    {:ok, raw} = InstallManifest.render(spec, server())

    namespace = spec.namespace

    chart =
      render!(
        direct_for(params) ++ sets,
        release: spec.node_name,
        namespace: namespace
      )

    {raw, chart}
  end

  defp base_params(params) do
    Map.merge(
      %{"name" => "mesaana", "primary_cidrs" => @primary_cidrs},
      params
    )
  end

  defp server,
    do: [
      image: "#{@image_repository}:#{@image_tag}",
      primary_url: @primary_url,
      registry: @registry
    ]

  # `--set` for primary.url (always) and the primary CIDRs (only where the reach is direct).
  defp direct_for(params) do
    if Map.get(params, "reach", "direct") == "direct",
      do: direct(),
      else: ["primary.url=#{@primary_url}"]
  end

  defp direct do
    [
      "primary.url=#{@primary_url}",
      "networkPolicy.controllerEgress.primaryCIDRs={#{@primary_cidrs}}"
    ]
  end

  # The differences left after taking out `@known_deltas`, one line per path.
  defp drift(raw, chart) do
    raw =
      raw |> Enum.reject(&(&1["kind"] == "Namespace")) |> Map.new(&{identity(&1), normalise(&1)})

    chart = Map.new(chart, &{identity(&1), normalise(&1)})

    missing = for id <- Map.keys(raw) -- Map.keys(chart), do: "only in raw: #{inspect(id)}"
    extra = for id <- Map.keys(chart) -- Map.keys(raw), do: "only in chart: #{inspect(id)}"

    changed =
      for id <- Enum.sort(Map.keys(raw)),
          Map.has_key?(chart, id),
          line <- diff(raw[id], chart[id], ""),
          do: "#{inspect(id)}#{line}"

    missing ++ extra ++ changed
  end

  # Drops the allowed deltas (see `@helm_labels`, `@helm_env`) and compares
  # controller.yaml as the controller parses it.
  defp normalise(doc) do
    doc
    |> drop_helm_labels()
    |> normalise_controller_yaml()
    |> normalise_controller_container()
  end

  defp drop_helm_labels(doc) do
    case get_in(doc, ["metadata", "labels"]) do
      labels when is_map(labels) ->
        case Map.drop(labels, @helm_labels) do
          empty when map_size(empty) == 0 ->
            update_in(doc, ["metadata"], &Map.delete(&1, "labels"))

          kept ->
            put_in(doc, ["metadata", "labels"], kept)
        end

      _ ->
        doc
    end
  end

  defp normalise_controller_yaml(
         %{"kind" => "ConfigMap", "metadata" => %{"name" => "arbiter-controller-config"}} = doc
       ) do
    {:ok, config} = ControllerConfig.parse(doc["data"]["controller.yaml"])
    # The chart spells out the default placement; the raw renderer leaves it to the
    # controller. The placement keys the operator sets are compared in the round-trip tests.
    put_in(doc, ["data", "controller.yaml"], Map.delete(config, :placement))
  end

  defp normalise_controller_yaml(doc), do: doc

  defp normalise_controller_container(%{"kind" => "Deployment"} = doc) do
    update_in(doc, ["spec", "template", "spec", "containers"], fn containers ->
      Enum.map(containers, fn
        %{"name" => "controller"} = container ->
          container
          |> Map.delete("imagePullPolicy")
          |> Map.update!("env", fn env -> Enum.reject(env, &(&1["name"] in @helm_env)) end)

        other ->
          other
      end)
    end)
  end

  defp normalise_controller_container(doc), do: doc

  defp diff(x, y, path) when is_map(x) and is_map(y) do
    for key <- Enum.sort(Enum.uniq(Map.keys(x) ++ Map.keys(y))), reduce: [] do
      acc ->
        acc ++
          cond do
            not is_map_key(x, key) -> [" +chart #{path}/#{key}: #{short(y[key])}"]
            not is_map_key(y, key) -> [" -raw #{path}/#{key}: #{short(x[key])}"]
            true -> diff(x[key], y[key], "#{path}/#{key}")
          end
    end
  end

  defp diff(x, y, path) when is_list(x) and is_list(y) and length(x) == length(y) do
    x
    |> Enum.zip(y)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{a, b}, i} -> diff(a, b, "#{path}[#{i}]") end)
  end

  defp diff(x, x, _path), do: []
  defp diff(x, y, path), do: [" ~ #{path}: raw=#{short(x)} chart=#{short(y)}"]

  defp short(term), do: term |> inspect(limit: 12, printable_limit: 200) |> String.slice(0, 240)

  # ---- helm -----------------------------------------------------------------------

  defp helm_template(sets, opts \\ []) do
    release = Keyword.get(opts, :release, "mesaana")
    namespace = Keyword.get(opts, :namespace, "arbiter-workers")
    args = Enum.flat_map(["image.tag=#{@image_tag}" | sets], &["--set", &1])

    case System.cmd(
           @helm,
           ["template", release, @chart, "--namespace", namespace] ++ args,
           stderr_to_stdout: true
         ) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, out}
    end
  end

  defp render!(sets, opts \\ []) do
    {:ok, out} = helm_template(sets, opts)
    out |> YamlElixir.read_all_from_string!() |> Enum.reject(&(&1 in [nil, %{}]))
  end

  defp controller_config(docs) do
    docs
    |> find!("ConfigMap", "arbiter-controller-config")
    |> get_in(["data", "controller.yaml"])
    |> ControllerConfig.parse()
  end

  defp identity(%{"kind" => kind, "metadata" => %{"name" => name}}), do: {kind, name}

  defp helm_label?(doc),
    do: Enum.any?(@helm_labels, &is_map_key(get_in(doc, ["metadata", "labels"]) || %{}, &1))

  defp find!(docs, kind, name) do
    Enum.find(docs, &(identity(&1) == {kind, name})) ||
      flunk("no #{kind}/#{name} in #{inspect(Enum.map(docs, &identity/1))}")
  end

  defp controller_env(deployment) do
    deployment["spec"]["template"]["spec"]["containers"]
    |> Enum.find(&(&1["name"] == "controller"))
    |> Map.fetch!("env")
    |> Map.new(&{&1["name"], &1["value"]})
  end
end
