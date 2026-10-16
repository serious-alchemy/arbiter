defmodule Arbiter.NodeAgent.K8s.HelmChartTest do
  @moduledoc """
  KH5 (bd-2u4lpp): the hand-written `charts/arbiter-node` Helm chart
  (`docs/design/remote-workers.md` §20.5-§20.7, OD5 / OD9).

  The static tests read the chart's files and need nothing installed. The `:helm`
  tests render it with the `helm` binary and are skipped where it is absent (CI's
  `helm-chart` job installs it and runs `scripts/helm-chart-check.sh`, which is the
  lint + kubeconform half). The full chart-vs-`InstallManifest` document diff is KH6;
  here the two renderers are only held to the same kinds and names.
  """
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.K8s.{ControllerConfig, InstallManifest}

  @chart Path.expand("../../../../../../charts/arbiter-node", __DIR__)
  @helm System.find_executable("helm")

  @direct [
    "primary.url=https://arbiter.example.test",
    "networkPolicy.controllerEgress.primaryCIDRs={100.64.0.10/32,100.64.0.11/32}"
  ]

  describe "chart files" do
    test "Chart.yaml names the chart and pins a minimum Kubernetes version" do
      chart = YamlElixir.read_from_file!(Path.join(@chart, "Chart.yaml"))
      assert chart["name"] == "arbiter-node"
      assert chart["apiVersion"] == "v2"
      assert chart["kubeVersion"] =~ ">="
    end

    test "values.schema.json rejects unknown keys at every object level" do
      schema = @chart |> Path.join("values.schema.json") |> File.read!() |> Jason.decode!()
      assert open_objects(schema, "$") == []
    end

    test "mode is a closed enum of all, bootstrap, node and defaults to all" do
      schema = @chart |> Path.join("values.schema.json") |> File.read!() |> Jason.decode!()
      assert schema["properties"]["mode"]["enum"] == ["all", "bootstrap", "node"]

      values = YamlElixir.read_from_file!(Path.join(@chart, "values.yaml"))
      assert values["mode"] == "all"
    end

    test "no template renders a Namespace or grants the patch verb" do
      for file <- Path.wildcard(Path.join(@chart, "templates/**/*.{yaml,tpl,txt}")) do
        text = File.read!(file)
        refute text =~ ~r/^kind:\s*Namespace\b/m, "#{file} templates a Namespace"
        refute text =~ ~r/\bpatch\b/, "#{file} mentions the patch verb"
      end
    end
  end

  describe "rendered (needs helm)" do
    @describetag :helm
    @describetag skip: is_nil(@helm) && "helm is not installed"

    test "mode all renders the same kinds and names as the raw manifests" do
      {:ok, spec} =
        InstallManifest.parse(%{
          "name" => "mesaana",
          "primary_cidrs" => "100.64.0.10/32,100.64.0.11/32",
          "self_upgrade" => "off"
        })

      {:ok, raw} =
        InstallManifest.render(spec,
          image: "x/controller:1",
          primary_url: "https://p",
          registry: "x"
        )

      # The chart does not template the Namespace (§20.6), and the join Secret only
      # appears for `--set-file`.
      expected =
        raw |> Enum.map(&identity/1) |> Enum.reject(&match?({"Namespace", _}, &1)) |> Enum.sort()

      assert render!(@direct, release: "mesaana") |> Enum.map(&identity/1) |> Enum.sort() ==
               expected
    end

    test "mode node holds no guardrail and mode bootstrap no controller" do
      node_kinds = render!(@direct ++ ["mode=node"]) |> kinds()
      bootstrap_kinds = render!(@direct ++ ["mode=bootstrap"]) |> kinds()

      for kind <- ~w(PriorityClass ResourceQuota LimitRange NetworkPolicy) do
        refute kind in node_kinds
        assert kind in bootstrap_kinds
      end

      for kind <- ~w(Deployment Role RoleBinding Service Lease ServiceAccount) do
        assert kind in node_kinds
        refute kind in bootstrap_kinds
      end
    end

    test "the Role never grants patch and the Deployment says Helm owns the upgrade" do
      docs = render!(@direct, release: "mesaana")
      role = find!(docs, "Role", "arbiter-controller")
      verbs = role["rules"] |> Enum.flat_map(& &1["verbs"])
      refute "patch" in verbs

      env = controller_env(find!(docs, "Deployment", "arbiter-controller"))
      assert env["ARB_K8S_SELF_UPGRADE"] == "false"
      assert env["ARB_INSTALL_METHOD"] == "helm"
      assert env["ARB_HELM_RELEASE"] == "mesaana"
      assert env["ARB_NODE_NAME"] == "mesaana"
      assert env["ARB_PRIMARY_URL"] == "https://arbiter.example.test"
      assert env["ARB_CHART_REF"] =~ "arbiter-node"
    end

    test "the controller ConfigMap parses through the controller's own closed schema" do
      docs = render!(@direct ++ ["concurrency.max=3", "placement.nodeSelector.pool=ci"])
      config = find!(docs, "ConfigMap", "arbiter-controller-config")

      assert {:ok, parsed} = ControllerConfig.parse(config["data"]["controller.yaml"])
      assert parsed.max_concurrent == 3
      assert parsed.placement["node_selector"] == %{"pool" => "ci"}
    end

    test "registries[] render as the controller's per-prefix pull-secret list (KH13)" do
      docs =
        render!(
          @direct ++
            [
              "registries[0].prefix=registry.gitlab.com/vstim",
              "registries[0].pullSecret=gitlab-vstim",
              "registries[1].prefix=ghcr.io/ryan/",
              "registries[1].pullSecret=ghcr-arbiter"
            ]
        )

      config = find!(docs, "ConfigMap", "arbiter-controller-config")
      assert {:ok, parsed} = ControllerConfig.parse(config["data"]["controller.yaml"])

      assert parsed.registries == [
               %{"prefix" => "registry.gitlab.com/vstim/", "pull_secret" => "gitlab-vstim"},
               %{"prefix" => "ghcr.io/ryan/", "pull_secret" => "ghcr-arbiter"}
             ]

      assert parsed.image_pull_secrets == []
    end

    test "the join token is only rendered for --set-file, and no other Secret has data" do
      refute Enum.any?(render!(@direct), &(identity(&1) == {"Secret", "arbiter-join"}))

      docs = render!(@direct ++ ["join.token=abc123"])
      assert %{"stringData" => %{"token" => "abc123"}} = find!(docs, "Secret", "arbiter-join")

      for %{"kind" => "Secret", "metadata" => %{"name" => name}} = secret <- docs,
          name != "arbiter-join" do
        refute Map.has_key?(secret, "data") or Map.has_key?(secret, "stringData")
      end
    end

    test "tailscale adds the pinned sidecar and keeps the wide control-plane rule" do
      docs =
        render!([
          "primary.url=https://arbiter.example.test",
          "reach.mode=tailscale"
        ])

      deployment = find!(docs, "Deployment", "arbiter-controller")
      containers = deployment["spec"]["template"]["spec"]["containers"]
      assert Enum.map(containers, & &1["name"]) == ["controller", "tailscale"]
      assert Enum.at(containers, 1)["image"] =~ ~r/@sha256:[0-9a-f]{64}$/

      egress = find!(docs, "NetworkPolicy", "controller-egress")["spec"]["egress"]

      assert Enum.any?(
               egress,
               &(get_in(&1, ["to", Access.at(0), "ipBlock", "cidr"]) == "0.0.0.0/0")
             )
    end

    test "direct and proxy egress never contain a catch-all" do
      for sets <- [
            @direct,
            [
              "primary.url=https://arbiter.example.test",
              "reach.mode=proxy",
              "reach.proxy.url=http://proxy.example.test:3128",
              "reach.proxy.cidrs={10.9.0.5/32}"
            ]
          ] do
        egress = find!(render!(sets), "NetworkPolicy", "controller-egress")["spec"]["egress"]
        refute inspect(egress) =~ "/0\""
      end
    end

    test "the schema turns a typo, a missing primary and a catch-all CIDR into install errors" do
      assert {:error, out} = helm_template(@direct ++ ["concurency.max=3"])
      assert out =~ "concurency"

      assert {:error, _} =
               helm_template(["networkPolicy.controllerEgress.primaryCIDRs={1.2.3.4/32}"])

      assert {:error, _} = helm_template(["primary.url=https://p.example.test"])

      assert {:error, _} =
               helm_template([
                 "primary.url=https://p.example.test",
                 "networkPolicy.controllerEgress.primaryCIDRs={0.0.0.0/0}"
               ])
    end

    test "the optional admission policy and its binding render only when enabled" do
      refute "ValidatingAdmissionPolicy" in kinds(render!(@direct))

      docs =
        render!(
          @direct ++
            ["admissionPolicy.enabled=true", "registries[0].prefix=registry.example.test/arbiter"]
        )

      policy = find!(docs, "ValidatingAdmissionPolicy", "arbiter-worker-pods")
      assert length(policy["spec"]["validations"]) == 7
      assert inspect(policy) =~ "registry.example.test/arbiter/"
      assert "ValidatingAdmissionPolicyBinding" in kinds(docs)
    end
  end

  # ---- helpers ---------------------------------------------------------------------

  defp open_objects(%{"properties" => props} = schema, path) do
    here = if schema["additionalProperties"] == false, do: [], else: [path]
    here ++ Enum.flat_map(props, fn {key, sub} -> open_objects(sub, path <> "." <> key) end)
  end

  defp open_objects(%{"items" => items}, path), do: open_objects(items, path <> "[]")
  defp open_objects(_leaf, _path), do: []

  defp helm_template(sets, opts \\ []) do
    release = Keyword.get(opts, :release, "mesaana")
    args = Enum.flat_map(sets, &["--set", &1])

    case System.cmd(
           @helm,
           ["template", release, @chart, "--namespace", "arbiter-workers"] ++ args,
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

  defp identity(%{"kind" => kind, "metadata" => %{"name" => name}}), do: {kind, name}
  defp kinds(docs), do: Enum.map(docs, & &1["kind"])

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
