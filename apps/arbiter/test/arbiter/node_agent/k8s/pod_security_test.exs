defmodule Arbiter.NodeAgent.K8s.PodSecurityTest do
  @moduledoc """
  K4 (bd-7m6quu): the Pod Security `restricted` conformance checker, table
  driven. Every rule has a built-pod pass and a negative control (a mutation of a
  built pod that the rule must catch), and a meta-test fails if a rule has no
  control, so a new rule cannot land untested.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures

  alias Arbiter.NodeAgent.K8s.PodSecurity

  defp pods do
    %{
      "minimal" => build!(),
      "bridges" => build!(run_spec(with_bridges())),
      "services" =>
        build!(run_spec(%{"services" => [%{"preset" => "postgres"}, %{"preset" => "s3"}]}), %{
          service_image_allowlist: ["docker.io/pgsty/"]
        }),
      "no mounts but the worktree" =>
        build!(
          run_spec(%{"mounts" => [%{"kind" => "worktree", "path" => "/w/t"}], "cwd" => "/w/t"})
        )
    }
  end

  defp opts, do: [registry: registry(), image_prefixes: ["docker.io/pgsty/"]]

  describe "built pods" do
    for name <- ["minimal", "bridges", "services", "no mounts but the worktree"] do
      test "#{name} passes baseline, restricted and the arbiter rules" do
        pod = Map.fetch!(pods(), unquote(name))
        assert PodSecurity.check(pod, opts()) == :ok
      end
    end

    test "the checker asserts non-root itself: PSA does not under hostUsers: false (K1-A1)" do
      pod = build!()

      pod =
        put_in(pod, ["spec", "securityContext"], %{
          "runAsUser" => 0,
          "runAsNonRoot" => false,
          "seccompProfile" => %{"type" => "RuntimeDefault"}
        })

      assert {:error, violations} = PodSecurity.check(pod, opts())
      rules = Enum.map(violations, & &1.rule)
      assert :run_as_user in rules
      assert :run_as_non_root in rules
      assert :non_root in rules
    end
  end

  # {rule, description, mutation}
  defp container_map(pod, name, fun) do
    update_in(pod, ["spec"], fn spec ->
      spec
      |> Map.update!("initContainers", &map_named(&1, name, fun))
      |> Map.update!("containers", &map_named(&1, name, fun))
    end)
  end

  defp map_named(list, name, fun),
    do: Enum.map(list, &if(&1["name"] == name, do: fun.(&1), else: &1))

  defp sc(pod, name, key, value),
    do: container_map(pod, name, &put_in(&1, ["securityContext", key], value))

  defp pod_sc(pod, key, value), do: put_in(pod, ["spec", "securityContext", key], value)
  defp spec(pod, key, value), do: put_in(pod, ["spec", key], value)

  defp add_volume(pod, volume), do: update_in(pod, ["spec", "volumes"], &(&1 ++ [volume]))

  defp table do
    [
      # baseline
      {:host_process, "windows hostProcess",
       &pod_sc(&1, "windowsOptions", %{"hostProcess" => true})},
      {:host_namespaces, "hostNetwork", &spec(&1, "hostNetwork", true)},
      {:host_namespaces, "hostPID", &spec(&1, "hostPID", true)},
      {:host_namespaces, "hostIPC", &spec(&1, "hostIPC", true)},
      {:privileged, "privileged worker", &sc(&1, "worker", "privileged", true)},
      {:baseline_capabilities, "add SYS_ADMIN",
       &sc(&1, "worker", "capabilities", %{"drop" => ["ALL"], "add" => ["SYS_ADMIN"]})},
      {:host_path_volumes, "hostPath volume",
       &add_volume(&1, %{"name" => "h", "hostPath" => %{"path" => "/"}})},
      {:host_ports, "hostPort",
       &container_map(&1, "worker", fn c ->
         Map.put(c, "ports", [%{"containerPort" => 80, "hostPort" => 80}])
       end)},
      {:host_probes, "probe host",
       &container_map(&1, "worker", fn c ->
         Map.put(c, "livenessProbe", %{"httpGet" => %{"host" => "10.0.0.1", "port" => 80}})
       end)},
      {:host_probes, "lifecycle host",
       &container_map(&1, "worker", fn c ->
         Map.put(c, "lifecycle", %{
           "preStop" => %{"tcpSocket" => %{"host" => "10.0.0.1", "port" => 80}}
         })
       end)},
      {:apparmor, "unconfined profile",
       &pod_sc(&1, "appArmorProfile", %{"type" => "Unconfined"})},
      {:apparmor, "annotation",
       &put_in(&1, ["metadata", "annotations"], %{
         "container.apparmor.security.beta.kubernetes.io/worker" => "unconfined"
       })},
      {:selinux, "spc_t", &sc(&1, "worker", "seLinuxOptions", %{"type" => "spc_t"})},
      {:selinux, "user set", &pod_sc(&1, "seLinuxOptions", %{"user" => "system_u"})},
      {:selinux, "role set", &pod_sc(&1, "seLinuxOptions", %{"role" => "system_r"})},
      {:proc_mount, "Unmasked", &sc(&1, "worker", "procMount", "Unmasked")},
      {:seccomp_baseline, "Unconfined pod",
       &pod_sc(&1, "seccompProfile", %{"type" => "Unconfined"})},
      {:seccomp_baseline, "Unconfined container",
       &sc(&1, "worker", "seccompProfile", %{"type" => "Unconfined"})},
      {:sysctls, "unsafe sysctl",
       &pod_sc(&1, "sysctls", [
         %{"name" => "kernel.shm_rmid_forced", "value" => "1"},
         %{"name" => "vm.swappiness", "value" => "1"}
       ])},
      # restricted
      {:volume_types, "gcePersistentDisk",
       &add_volume(&1, %{"name" => "g", "gcePersistentDisk" => %{"pdName" => "x"}})},
      {:volume_types, "nfs",
       &add_volume(&1, %{"name" => "n", "nfs" => %{"server" => "s", "path" => "/"}})},
      {:privilege_escalation, "worker true", &sc(&1, "worker", "allowPrivilegeEscalation", true)},
      {:privilege_escalation, "init container unset",
       fn pod ->
         container_map(pod, "seed", fn c ->
           update_in(c, ["securityContext"], &Map.delete(&1, "allowPrivilegeEscalation"))
         end)
       end},
      {:run_as_non_root, "pod false", &pod_sc(&1, "runAsNonRoot", false)},
      {:run_as_non_root, "container false", &sc(&1, "worker", "runAsNonRoot", false)},
      {:run_as_non_root, "nothing says true",
       fn pod ->
         pod |> update_in(["spec", "securityContext"], &Map.delete(&1, "runAsNonRoot"))
       end},
      {:run_as_user, "pod uid 0", &pod_sc(&1, "runAsUser", 0)},
      {:run_as_user, "container uid 0", &sc(&1, "worker", "runAsUser", 0)},
      {:seccomp_restricted, "pod unset",
       fn pod ->
         update_in(pod, ["spec", "securityContext"], &Map.delete(&1, "seccompProfile"))
       end},
      {:capabilities_restricted, "no drop ALL",
       &sc(&1, "worker", "capabilities", %{"drop" => ["NET_RAW"]})},
      {:capabilities_restricted, "add CHOWN",
       &sc(&1, "worker", "capabilities", %{"drop" => ["ALL"], "add" => ["CHOWN"]})},
      # arbiter
      {:non_root, "pod uid 0", &pod_sc(&1, "runAsUser", 0)},
      {:non_root, "no pod uid",
       fn pod -> update_in(pod, ["spec", "securityContext"], &Map.delete(&1, "runAsUser")) end},
      {:non_root, "container runAsNonRoot false", &sc(&1, "worker", "runAsNonRoot", false)},
      {:host_users, "hostUsers true", &spec(&1, "hostUsers", true)},
      {:host_users, "hostUsers absent",
       fn pod -> update_in(pod, ["spec"], &Map.delete(&1, "hostUsers")) end},
      {:read_only_root, "writable worker", &sc(&1, "worker", "readOnlyRootFilesystem", false)},
      {:read_only_root, "writable snapshotter",
       &sc(&1, "snapshotter", "readOnlyRootFilesystem", false)},
      {:read_only_root, "writable seed", &sc(&1, "seed", "readOnlyRootFilesystem", false)},
      {:no_apparmor, "RuntimeDefault is still refused (K1-A2)",
       &pod_sc(&1, "appArmorProfile", %{"type" => "RuntimeDefault"})},
      {:no_apparmor, "container RuntimeDefault",
       &sc(&1, "worker", "appArmorProfile", %{"type" => "RuntimeDefault"})},
      {:no_selinux, "container_t is still refused",
       &sc(&1, "worker", "seLinuxOptions", %{"type" => "container_t"})},
      {:strict_capabilities, "extra drop entry",
       &sc(&1, "worker", "capabilities", %{"drop" => ["ALL", "NET_RAW"]})},
      {:strict_capabilities, "NET_BIND_SERVICE add",
       &sc(&1, "worker", "capabilities", %{"drop" => ["ALL"], "add" => ["NET_BIND_SERVICE"]})},
      {:strict_capabilities, "privileged false missing",
       fn pod ->
         container_map(pod, "worker", fn c ->
           update_in(c, ["securityContext"], &Map.delete(&1, "privileged"))
         end)
       end},
      {:service_account, "other account", &spec(&1, "serviceAccountName", "default")},
      {:service_account, "token automount", &spec(&1, "automountServiceAccountToken", true)},
      {:service_account, "token field absent",
       fn pod -> update_in(pod, ["spec"], &Map.delete(&1, "automountServiceAccountToken")) end},
      {:volumes, "secret volume",
       &add_volume(&1, %{"name" => "s", "secret" => %{"secretName" => "arbiter-node-credential"}})},
      {:volumes, "other configMap",
       &add_volume(&1, %{"name" => "c", "configMap" => %{"name" => "other"}})},
      {:volumes, "pvc",
       &add_volume(&1, %{"name" => "p", "persistentVolumeClaim" => %{"claimName" => "x"}})},
      {:volumes, "projected token",
       &add_volume(&1, %{"name" => "t", "projected" => %{"sources" => []}})},
      {:network, "service links on", &spec(&1, "enableServiceLinks", true)},
      {:network, "dnsPolicy ClusterFirst", &spec(&1, "dnsPolicy", "ClusterFirst")},
      {:network, "a container port",
       &container_map(&1, "worker", fn c -> Map.put(c, "ports", [%{"containerPort" => 80}]) end)},
      {:network, "shareProcessNamespace", &spec(&1, "shareProcessNamespace", true)},
      {:seccomp, "Localhost is not the default profile",
       &pod_sc(&1, "seccompProfile", %{"type" => "Localhost", "localhostProfile" => "x.json"})},
      {:image, "off-registry worker image",
       &container_map(&1, "worker", fn c ->
         Map.put(c, "image", "evil.example/x@sha256:" <> digest())
       end)},
      {:image, "off-registry service image",
       &container_map(&1, "svc-postgres", fn c -> Map.put(c, "image", "evil.example/pg:16") end)},
      {:image, "tag only",
       &container_map(&1, "worker", fn c -> Map.put(c, "image", registry() <> "/beam:latest") end)},
      {:image, "pull always",
       &container_map(&1, "worker", fn c -> Map.put(c, "imagePullPolicy", "Always") end)}
    ]
  end

  describe "negative controls (one row per rule and mutation)" do
    test "every control is caught by its rule on a fully-featured pod" do
      base = pods()["services"]

      for {rule, description, mutate} <- table() do
        pod = mutate.(base)
        assert pod != base, "#{rule}/#{description}: the mutation changed nothing"

        assert {:error, violations} = PodSecurity.check(pod, opts()),
               "#{rule}/#{description}: not caught at all"

        assert rule in Enum.map(violations, & &1.rule),
               "#{rule}/#{description}: caught only as #{inspect(Enum.map(violations, & &1.rule))}"
      end
    end

    test "every rule in the table has at least one control" do
      covered = table() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      all = PodSecurity.rules() |> Enum.map(& &1.id)
      assert all -- covered == []
      assert covered -- all == []
    end

    test "rule ids are unique and each has a level and a description" do
      rules = PodSecurity.rules()
      assert length(Enum.uniq_by(rules, & &1.id)) == length(rules)

      for rule <- rules do
        assert rule.level in [:baseline, :restricted, :arbiter]
        assert is_binary(rule.description) and rule.description != ""
      end
    end

    test "a violation names the rule, its level and the path" do
      pod = sc(build!(), "worker", "privileged", true)
      assert {:error, violations} = PodSecurity.check(pod, opts())

      assert %{
               rule: :privileged,
               level: :baseline,
               path: "spec.containers[worker].securityContext.privileged"
             } =
               Enum.find(violations, &(&1.rule == :privileged))
    end
  end

  describe "levels and options" do
    test "levels: selects which rule groups run" do
      pod = spec(build!(), "hostUsers", true)
      assert PodSecurity.check(pod, [{:levels, [:baseline, :restricted]} | opts()]) == :ok

      assert {:error, [%{rule: :host_users}]} =
               PodSecurity.check(pod, [{:levels, [:arbiter]} | opts()])
    end

    test "the image rule is skipped without a registry" do
      pod = container_map(build!(), "worker", &Map.put(&1, "image", "evil.example/x:1"))
      assert PodSecurity.check(pod, []) == :ok
    end

    test "a pod with no spec at all reports violations instead of crashing" do
      assert {:error, violations} = PodSecurity.check(%{}, opts())
      assert [_ | _] = violations
      assert {:error, _} = PodSecurity.check(%{"spec" => %{"containers" => "nope"}}, opts())
    end
  end
end
