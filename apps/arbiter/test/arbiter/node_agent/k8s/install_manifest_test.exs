defmodule Arbiter.NodeAgent.K8s.InstallManifestTest do
  @moduledoc """
  K9 (bd-6ez9yn): the `/nodes/join/k8s.yaml` renderer (`docs/design/remote-workers.md`
  K§2.2). The rendered files are golden-pinned under `test/fixtures/k8s/install_*.yaml`
  (`ARB_UPDATE_GOLDEN=1 mix test` rewrites them after a deliberate change), and the
  "it contains no secret" property is asserted on every variant, not just the default.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures, only: [assert_golden: 2]

  alias Arbiter.NodeAgent.K8s.{AdmissionPolicy, ControllerConfig, InstallManifest}

  @server [
    image: "registry.example.test/arbiter/controller:0.2.43",
    primary_url: "https://arbiter.tail1234.ts.net",
    registry: "registry.example.test/arbiter"
  ]

  defp parse!(params) do
    {:ok, spec} = InstallManifest.parse(params)
    spec
  end

  defp render!(params) do
    {:ok, docs} = InstallManifest.render(parse!(params), @server)
    docs
  end

  defp yaml!(params, part \\ :all) do
    {:ok, text} = InstallManifest.yaml(parse!(Map.put(params, "part", to_string(part))), @server)
    text
  end

  defp find(docs, kind, name \\ nil) do
    Enum.find(docs, &(&1["kind"] == kind and (is_nil(name) or &1["metadata"]["name"] == name)))
  end

  describe "parse/1" do
    test "defaults, with the node name the only required value" do
      assert {:ok, spec} = InstallManifest.parse(%{"name" => "mesaana-k3s"})
      assert spec.node_name == "mesaana-k3s"
      assert spec.namespace == "arbiter-workers"
      assert spec.max_concurrent == 2
      assert spec.reach == :direct
      assert spec.admission == false
      assert spec.self_upgrade == true
      assert spec.part == :all
      assert spec.node_selector == %{}
      assert spec.pull_secret == nil
    end

    test "reads every form value" do
      spec =
        parse!(%{
          "name" => "k3s",
          "namespace" => "ci-workers",
          "max" => "3",
          "cpu" => "500m",
          "memory" => "1Gi",
          "node_selector" => "kubernetes.io/hostname=mesanna,pool=arb",
          "pull_secret" => "gitlab-registry",
          "reach" => "tailscale",
          "admission" => "policy",
          "self_upgrade" => "off",
          "part" => "node"
        })

      assert spec.namespace == "ci-workers"
      assert spec.max_concurrent == 3
      assert spec.cpu == "500m"
      assert spec.memory == "1Gi"
      assert spec.node_selector == %{"kubernetes.io/hostname" => "mesanna", "pool" => "arb"}
      assert spec.pull_secret == "gitlab-registry"
      assert spec.reach == :tailscale
      assert spec.admission == true
      assert spec.self_upgrade == false
      assert spec.part == :node
    end

    test "refuses values that are not what they claim, naming each" do
      assert {:error, errors} =
               InstallManifest.parse(%{
                 "name" => "has space",
                 "namespace" => "Bad_NS",
                 "max" => "0",
                 "cpu" => "lots",
                 "memory" => "1; rm -rf /",
                 "node_selector" => "novalue",
                 "pull_secret" => "UPPER",
                 "reach" => "wireguard",
                 "admission" => "maybe",
                 "self_upgrade" => "sometimes",
                 "part" => "everything"
               })

      for field <-
            ~w(name namespace max cpu memory node_selector pull_secret reach admission self_upgrade part) do
        assert Enum.any?(errors, &String.starts_with?(&1, field)), "no error for #{field}"
      end
    end

    test "a missing name is an error" do
      assert {:error, [error]} = InstallManifest.parse(%{})
      assert error =~ "name"
    end

    test "the reserved name `local` is refused" do
      assert {:error, [error]} = InstallManifest.parse(%{"name" => "local"})
      assert error =~ "name"
    end
  end

  describe "render/2 documents" do
    test "bootstrap is the cluster-admin half, node the namespaced half" do
      %{bootstrap: bootstrap, node: node} =
        InstallManifest.documents(parse!(%{"name" => "n"}), @server)

      assert Enum.map(bootstrap, & &1["kind"]) ==
               ~w(Namespace PriorityClass ResourceQuota LimitRange NetworkPolicy NetworkPolicy NetworkPolicy NetworkPolicy)

      assert Enum.map(node, & &1["kind"]) ==
               ~w(ServiceAccount ServiceAccount Role RoleBinding Secret Secret ConfigMap ConfigMap Lease Service Deployment)
    end

    test "the namespace enforces Pod Security restricted and the priority class never preempts" do
      docs = render!(%{"name" => "n"})
      ns = find(docs, "Namespace")
      labels = ns["metadata"]["labels"]
      assert labels["pod-security.kubernetes.io/enforce"] == "restricted"
      assert labels["pod-security.kubernetes.io/enforce-version"] == "latest"
      assert labels["pod-security.kubernetes.io/audit"] == "restricted"
      assert labels["pod-security.kubernetes.io/warn"] == "restricted"

      pc = find(docs, "PriorityClass")
      assert pc["value"] == -100
      assert pc["preemptionPolicy"] == "Never"
    end

    test "the quota is derived from max_concurrent and the per-pod figures" do
      small = find(render!(%{"name" => "n", "max" => "2"}), "ResourceQuota")["spec"]["hard"]
      large = find(render!(%{"name" => "n", "max" => "4"}), "ResourceQuota")["spec"]["hard"]
      assert small["pods"] == "4"
      assert large["pods"] == "6"
      assert small["requests.cpu"] != large["requests.cpu"]
    end

    test "workers can reach only the controller; the controller reaches API, DNS and 443" do
      docs = render!(%{"name" => "n"})
      policies = Enum.filter(docs, &(&1["kind"] == "NetworkPolicy"))

      assert Enum.map(policies, & &1["metadata"]["name"]) ==
               ~w(default-deny worker-to-controller controller-ingress-from-workers controller-egress)

      worker = Enum.find(policies, &(&1["metadata"]["name"] == "worker-to-controller"))
      [rule] = worker["spec"]["egress"]
      assert Enum.map(rule["ports"], & &1["port"]) == [9443, 9444]
    end

    test "the Role is namespaced, names its resources, and has no exec/attach/portforward" do
      role = find(render!(%{"name" => "n"}), "Role")
      assert role["metadata"]["namespace"] == "arbiter-workers"
      resources = role["rules"] |> Enum.flat_map(& &1["resources"])

      refute Enum.any?(
               resources,
               &(&1 in ~w(pods/exec pods/attach pods/portforward nodes namespaces))
             )

      refute Enum.any?(
               render!(%{"name" => "n"}),
               &(&1["kind"] in ~w(ClusterRole ClusterRoleBinding))
             )

      secrets = Enum.find(role["rules"], &("secrets" in &1["resources"]))
      assert secrets["resourceNames"] == ["arbiter-node-credential", "arbiter-controller-ca"]
      assert secrets["verbs"] == ["get", "update"]
    end

    test "the worker service account is powerless and token-less" do
      sa = find(render!(%{"name" => "n"}), "ServiceAccount", "arbiter-worker")
      assert sa["automountServiceAccountToken"] == false
      docs = render!(%{"name" => "n"})
      binding = find(docs, "RoleBinding")
      assert [%{"name" => "arbiter-controller"}] = binding["subjects"]
    end

    test "the controller ConfigMap round-trips through the controller's own loader" do
      cm =
        find(
          render!(%{
            "name" => "n",
            "max" => "3",
            "cpu" => "500m",
            "memory" => "1Gi",
            "node_selector" => "pool=arb",
            "pull_secret" => "regcred"
          }),
          "ConfigMap",
          "arbiter-controller-config"
        )

      assert {:ok, config} = ControllerConfig.parse(cm["data"]["controller.yaml"])
      assert config.max_concurrent == 3
      assert config.namespace == "arbiter-workers"
      assert config.image_pull_secrets == ["regcred"]
      assert config.worker["requests"]["cpu"] == "500m"
      assert config.worker["requests"]["memory"] == "1Gi"
      assert config.placement["node_selector"] == %{"pool" => "arb"}
    end

    test "the CA ConfigMap and the credential Secrets are empty placeholders" do
      docs = render!(%{"name" => "n"})

      for name <- ~w(arbiter-node-credential arbiter-controller-ca) do
        secret = find(docs, "Secret", name)
        refute Map.has_key?(secret, "data")
        refute Map.has_key?(secret, "stringData")
      end

      ca = find(docs, "ConfigMap", "arbiter-ca")
      refute Map.has_key?(ca, "data")
    end

    test "the Deployment pins the image and reads the join Secret as optional" do
      d = find(render!(%{"name" => "mesaana-k3s"}), "Deployment")
      spec = d["spec"]["template"]["spec"]
      [controller] = spec["containers"]
      assert controller["image"] == "registry.example.test/arbiter/controller:0.2.43"

      env = Map.new(controller["env"], &{&1["name"], &1["value"]})
      assert env["ARB_PRIMARY_URL"] == "https://arbiter.tail1234.ts.net"
      assert env["ARB_NODE_NAME"] == "mesaana-k3s"

      join = Enum.find(spec["volumes"], &(&1["name"] == "join"))
      assert join["secret"] == %{"secretName" => "arbiter-join", "optional" => true}
      assert Enum.any?(controller["volumeMounts"], &(&1["mountPath"] == "/etc/arb/join"))
      assert Enum.any?(controller["volumeMounts"], &(&1["mountPath"] == "/etc/arb/config"))
    end
  end

  describe "variants" do
    test "tailscale adds the sidecar and the Secret reference, but no Secret" do
      docs = render!(%{"name" => "n", "reach" => "tailscale"})
      d = find(docs, "Deployment")

      assert Enum.map(d["spec"]["template"]["spec"]["containers"], & &1["name"]) ==
               ["controller", "tailscale"]

      refute find(docs, "Secret", "arbiter-tailscale")
    end

    test "admission=policy adds the ValidatingAdmissionPolicy and its binding to bootstrap" do
      %{bootstrap: bootstrap} =
        InstallManifest.documents(parse!(%{"name" => "n", "admission" => "policy"}), @server)

      kinds = Enum.map(bootstrap, & &1["kind"])
      assert "ValidatingAdmissionPolicy" in kinds
      assert "ValidatingAdmissionPolicyBinding" in kinds

      [policy | _] = AdmissionPolicy.manifests(registry: @server[:registry])
      assert find(bootstrap, "ValidatingAdmissionPolicy") == policy

      none = render!(%{"name" => "n"})
      refute find(none, "ValidatingAdmissionPolicy")
    end

    test "a custom namespace is carried through every namespaced object and the policy user" do
      docs = render!(%{"name" => "n", "namespace" => "ci-workers", "admission" => "policy"})

      for doc <- docs,
          doc["kind"] not in ~w(Namespace PriorityClass ValidatingAdmissionPolicy ValidatingAdmissionPolicyBinding) do
        assert doc["metadata"]["namespace"] == "ci-workers", "#{doc["kind"]} not in ci-workers"
      end

      assert find(docs, "Namespace")["metadata"]["name"] == "ci-workers"
      policy = find(docs, "ValidatingAdmissionPolicy")

      assert hd(policy["spec"]["matchConditions"])["expression"] =~
               "system:serviceaccount:ci-workers:arbiter-controller"
    end
  end

  describe "self-upgrade (rbac.selfUpgrade)" do
    defp deployment_rules(docs) do
      docs
      |> find("Role")
      |> Map.fetch!("rules")
      |> Enum.filter(&("deployments" in &1["resources"]))
    end

    test "on (the default): patch on the controller's own Deployment, nothing wider" do
      docs = render!(%{"name" => "n"})
      assert [rule] = deployment_rules(docs)
      assert rule["apiGroups"] == ["apps"]
      assert rule["resourceNames"] == ["arbiter-controller"]
      assert rule["verbs"] == ["get", "patch"]

      env =
        find(docs, "Deployment")["spec"]["template"]["spec"]["containers"]
        |> hd()
        |> Map.fetch!("env")

      assert %{"name" => "ARB_K8S_SELF_UPGRADE", "value" => "true"} in env
    end

    test "off: the Role can only get the Deployment, and the controller is told it cannot patch" do
      docs = render!(%{"name" => "n", "self_upgrade" => "off"})
      assert [rule] = deployment_rules(docs)
      assert rule["verbs"] == ["get"]
      assert rule["resourceNames"] == ["arbiter-controller"]

      env =
        find(docs, "Deployment")["spec"]["template"]["spec"]["containers"]
        |> hd()
        |> Map.fetch!("env")

      assert %{"name" => "ARB_K8S_SELF_UPGRADE", "value" => "false"} in env
    end
  end

  describe "no secrets" do
    @variants [
      %{"name" => "plain"},
      %{"name" => "ts", "reach" => "tailscale"},
      %{"name" => "adm", "admission" => "policy"},
      %{"name" => "all", "reach" => "tailscale", "admission" => "policy", "self_upgrade" => "off"}
    ]

    test "no variant carries a token, credential, CA key or any Secret payload" do
      for variant <- @variants, part <- [:all, :bootstrap, :node] do
        text = yaml!(variant, part)
        json = text |> YamlElixir.read_all_from_string!() |> Jason.encode!()

        refute text =~ "arbj_", "join token prefix in #{inspect(variant)}/#{part}"
        refute text =~ "arbn_", "node credential prefix in #{inspect(variant)}/#{part}"
        refute text =~ ~r/PRIVATE KEY/i
        refute text =~ ~r/BEGIN CERTIFICATE/
        refute text =~ ~r/tskey-/
        refute json =~ ~s("stringData")
        refute json =~ ~s("kind":"Secret","metadata":{"name":"arbiter-join")
        # A Secret in the render is a placeholder: it has no payload of any kind.
        for doc <- YamlElixir.read_all_from_string!(text), doc["kind"] == "Secret" do
          assert Map.keys(doc) -- ~w(apiVersion kind metadata type) == [],
                 "Secret #{doc["metadata"]["name"]} has a payload"
        end
      end
    end

    test "the rendering never reads a token: it takes no token option at all" do
      assert {:ok, spec} =
               InstallManifest.parse(%{
                 "name" => "n",
                 "token" => "arbj_x",
                 "credential" => "arbn_x"
               })

      refute Map.has_key?(spec, :token)
      text = yaml!(%{"name" => "n", "token" => "arbj_secret", "credential" => "arbn_x.y"})
      refute text =~ "arbj_secret"
      refute text =~ "arbn_x"
    end
  end

  describe "yaml/2 parts" do
    test "all = bootstrap then node, one stream of `---` separated documents" do
      all = yaml!(%{"name" => "n"})
      docs = YamlElixir.read_all_from_string!(all)
      assert hd(docs)["kind"] == "Namespace"
      assert List.last(docs)["kind"] == "Deployment"

      bootstrap = yaml!(%{"name" => "n"}, :bootstrap)
      node = yaml!(%{"name" => "n"}, :node)

      assert YamlElixir.read_all_from_string!(bootstrap) ++ YamlElixir.read_all_from_string!(node) ==
               docs
    end
  end

  describe "golden files" do
    test "the default install (direct reach, self-upgrade on)" do
      assert_golden("install_default", yaml!(%{"name" => "mesaana-k3s"}))
    end

    test "the tailscale-sidecar install" do
      assert_golden(
        "install_tailscale",
        yaml!(%{"name" => "mesaana-k3s", "reach" => "tailscale"})
      )
    end

    test "the admission-policy install, self-upgrade off, custom sizing" do
      assert_golden(
        "install_admission",
        yaml!(%{
          "name" => "mesaana-k3s",
          "namespace" => "ci-workers",
          "max" => "3",
          "cpu" => "500m",
          "memory" => "1Gi",
          "node_selector" => "kubernetes.io/hostname=mesanna",
          "pull_secret" => "gitlab-registry",
          "admission" => "policy",
          "self_upgrade" => "off"
        })
      )
    end
  end
end
