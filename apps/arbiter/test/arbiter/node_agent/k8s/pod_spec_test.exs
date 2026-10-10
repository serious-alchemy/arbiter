defmodule Arbiter.NodeAgent.K8s.PodSpecTest do
  @moduledoc """
  K4 (bd-7m6quu): `docs/design/remote-workers.md` §16 §8, one test per row of the
  table "the pod-spec builder, one line per `Container.argv/2` guarantee", then
  the refusals (`bad_spec`) and the details the table does not spell out.

  Each row test also runs the matching `Container.argv/2` assertion where the
  podman flag exists, so the two builders cannot drift apart silently.
  """
  use ExUnit.Case, async: true

  import Arbiter.Test.K8sPodFixtures

  alias Arbiter.NodeAgent.K8s.PodSpec
  alias Arbiter.Worker.Container

  @wt "/home/arbiter/worktrees/bd-1nfuq5"
  @home "/var/lib/arb/run/home"
  @config_dir "/var/lib/arb/run/claude-config"

  defp all_containers(pod), do: containers(pod)

  defp mounts(pod, name \\ "worker"), do: container(pod, name)["volumeMounts"]

  defp mount_at(pod, path, name \\ "worker"),
    do: Enum.find(mounts(pod, name), &(&1["mountPath"] == path))

  defp podman_argv(extra \\ %{}) do
    spec =
      Map.merge(
        %{
          podman: "podman",
          image: "img",
          name: "arb-x",
          worktree: @wt,
          home: @home,
          objects: "/repo/.git/objects",
          git_dir: @wt <> "/.git",
          readonly_paths:
            Enum.map(~w(config hooks commondir objects/info/alternates), &(@wt <> "/.git/" <> &1))
        },
        extra
      )

    Container.argv(spec, ["claude"])
  end

  describe "§8 row 1: --read-only" do
    test "readOnlyRootFilesystem is true on every container: init, services, snapshotter, worker" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      assert "--read-only" in podman_argv()

      names = Enum.map(all_containers(pod), & &1["name"])
      assert names == ["seed", "svc-postgres", "snapshotter", "worker"]

      for c <- all_containers(pod) do
        assert c["securityContext"]["readOnlyRootFilesystem"] == true, c["name"]
      end
    end
  end

  describe "§8 row 2: --cap-drop=all" do
    test "capabilities.drop is [ALL] with no add, on every container" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      assert "--cap-drop=all" in podman_argv()

      for c <- all_containers(pod) do
        assert c["securityContext"]["capabilities"] == %{"drop" => ["ALL"]}, c["name"]
      end
    end
  end

  describe "§8 row 3: --security-opt no-new-privileges" do
    test "allowPrivilegeEscalation false, privileged false, procMount Default" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))

      assert Enum.chunk_every(podman_argv(), 2, 1)
             |> Enum.member?(["--security-opt", "no-new-privileges"])

      for c <- all_containers(pod) do
        sc = c["securityContext"]
        assert sc["allowPrivilegeEscalation"] == false, c["name"]
        assert sc["privileged"] == false, c["name"]
        assert sc["procMount"] == "Default", c["name"]
      end
    end
  end

  describe "§8 row 4: --userns=keep-id" do
    test "non-root uid/gid 10001, fsGroup, OnRootMismatch and a user namespace" do
      pod = build!()
      assert "--userns=keep-id" in podman_argv()

      sc = pod["spec"]["securityContext"]
      assert sc["runAsNonRoot"] == true
      assert sc["runAsUser"] == 10_001
      assert sc["runAsGroup"] == 10_001
      assert sc["fsGroup"] == 10_001
      assert sc["fsGroupChangePolicy"] == "OnRootMismatch"
      assert pod["spec"]["hostUsers"] == false
    end

    test "no container overrides the identity to uid 0 or runAsNonRoot false (K1-A1)" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))

      for c <- all_containers(pod) do
        sc = c["securityContext"]
        refute sc["runAsUser"] == 0, c["name"]
        refute sc["runAsNonRoot"] == false, c["name"]
      end
    end
  end

  describe "§8 row 5: podman's default seccomp" do
    test "seccompProfile RuntimeDefault on the pod and never an appArmorProfile (K1-A2)" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))

      assert pod["spec"]["securityContext"]["seccompProfile"] == %{"type" => "RuntimeDefault"}
      refute Map.has_key?(pod["spec"]["securityContext"], "appArmorProfile")

      for c <- all_containers(pod) do
        refute Map.has_key?(c["securityContext"], "appArmorProfile"), c["name"]
        refute Map.has_key?(c["securityContext"], "seccompProfile"), c["name"]
      end

      refute inspect(pod) =~ "apparmor"
      refute inspect(pod) =~ "appArmor"
    end
  end

  describe "§8 row 6: --network=none" do
    test "no host network; DNS that fails closed; no service links; no ports" do
      pod = build!(run_spec(wire_bridges()))
      assert "--network=none" in podman_argv()

      spec = pod["spec"]
      refute spec["hostNetwork"] == true
      assert spec["dnsPolicy"] == "None"
      assert spec["dnsConfig"] == %{"nameservers" => ["127.0.0.1"]}
      assert spec["enableServiceLinks"] == false

      for c <- all_containers(pod) do
        refute Map.has_key?(c, "ports"), c["name"]
      end
    end

    test "a spec asking for pasta is refused with bad_spec" do
      assert {:error, {:bad_spec, {:network_not_supported, :pasta}}} =
               PodSpec.build(%{run_spec() | network: :pasta}, config())

      assert {:error, {:bad_spec, {:network_not_supported, "pasta"}}} =
               PodSpec.build(%{run_spec() | network: "pasta"}, config())
    end

    test "the wire spec with network pasta validates upstream but the builder still refuses it" do
      {:ok, spec} = Arbiter.NodeAgent.RunSpec.validate(wire_spec(%{"network" => "pasta"}))
      assert spec.network == :pasta

      assert {:error, {:bad_spec, {:network_not_supported, :pasta}}} =
               PodSpec.build(put_ref(spec), config())
    end

    test "any other network value is refused" do
      for other <- ["host", "bridge", :host, 1] do
        assert {:error, {:bad_spec, {:network_not_supported, ^other}}} =
                 PodSpec.build(%{run_spec() | network: other}, config())
      end
    end
  end

  describe "§8 row 7: the worktree at the primary's own absolute path" do
    test "emptyDir work (sizeLimit) mounted at that path via subPath wt, working dir the same" do
      pod = build!()

      assert Enum.find(pod["spec"]["volumes"], &(&1["name"] == "work")) ==
               %{"name" => "work", "emptyDir" => %{"sizeLimit" => "8Gi"}}

      assert mount_at(pod, @wt) == %{"name" => "work", "mountPath" => @wt, "subPath" => "wt"}
      assert worker(pod)["workingDir"] == @wt
      assert Enum.any?(podman_argv(), &String.starts_with?(&1, "#{@wt}:#{@wt}:"))
    end

    test "no hostPath volume exists anywhere" do
      pod = build!()
      refute Enum.any?(pod["spec"]["volumes"], &Map.has_key?(&1, "hostPath"))
    end
  end

  describe "§8 row 8: the .git guards" do
    @guards ~w(config hooks commondir objects/info/alternates)

    test "the four guards are readOnly subPath mounts of the work volume over the writable one" do
      pod = build!()

      for g <- @guards do
        assert mount_at(pod, "#{@wt}/.git/#{g}") ==
                 %{
                   "name" => "work",
                   "mountPath" => "#{@wt}/.git/#{g}",
                   "subPath" => "wt/.git/#{g}",
                   "readOnly" => true
                 }
      end

      # the same set the podman layout binds read-only
      assert Enum.all?(@guards, fn g ->
               Enum.any?(podman_argv(), &String.starts_with?(&1, "#{@wt}/.git/#{g}:"))
             end)
    end

    test "K1-A8: .git itself is a subPath mount, listed before the guards, writable" do
      pod = build!()
      paths = Enum.map(mounts(pod), & &1["mountPath"])

      assert mount_at(pod, @wt <> "/.git") ==
               %{"name" => "work", "mountPath" => @wt <> "/.git", "subPath" => "wt/.git"}

      git_idx = Enum.find_index(paths, &(&1 == @wt <> "/.git"))
      wt_idx = Enum.find_index(paths, &(&1 == @wt))
      assert wt_idx < git_idx

      for g <- @guards do
        assert git_idx < Enum.find_index(paths, &(&1 == "#{@wt}/.git/#{g}"))
      end
    end

    test "the snapshotter has the same .git and guard mounts as the worker" do
      pod = build!()

      for p <- [@wt, @wt <> "/.git" | Enum.map(@guards, &"#{@wt}/.git/#{&1}")] do
        assert mount_at(pod, p, "snapshotter") == mount_at(pod, p, "worker"), p
      end
    end

    test "the seed container and the services do not carry the guard mounts" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      refute Enum.any?(mounts(pod, "svc-postgres"), &String.contains?(&1["mountPath"], ".git"))
    end
  end

  describe "§8 row 9: the objects overlay" do
    test "not applicable: nothing mounts a host object store; the clone is self-contained" do
      pod = build!()
      assert Enum.any?(podman_argv(), &String.ends_with?(&1, ":O"))
      refute Enum.any?(pod["spec"]["volumes"], &Map.has_key?(&1, "hostPath"))

      refute Enum.any?(
               mounts(pod),
               &(String.contains?(&1["mountPath"], "objects") and
                   not String.ends_with?(&1["mountPath"], "alternates"))
             )
    end
  end

  describe "§8 row 10: per-run HOME and CLAUDE_CONFIG_DIR" do
    test "emptyDir paths at the primary's paths, and HOME in the env" do
      pod = build!()

      assert mount_at(pod, @home) == %{
               "name" => "work",
               "mountPath" => @home,
               "subPath" => "home"
             }

      assert mount_at(pod, @config_dir) ==
               %{"name" => "work", "mountPath" => @config_dir, "subPath" => "claude-config"}

      assert {"HOME", @home} in env_pairs(worker(pod))
      assert Enum.any?(podman_argv(), &(&1 == "HOME=#{@home}"))
    end
  end

  describe "§8 row 11: /tmp and /dev/shm" do
    test "/tmp is a memory emptyDir with a sizeLimit; /dev/shm is left at the runtime default" do
      pod = build!()

      assert Enum.find(pod["spec"]["volumes"], &(&1["name"] == "tmp")) ==
               %{"name" => "tmp", "emptyDir" => %{"medium" => "Memory", "sizeLimit" => "1Gi"}}

      assert mount_at(pod, "/tmp") == %{"name" => "tmp", "mountPath" => "/tmp"}
      refute mount_at(pod, "/dev/shm")
      refute Enum.any?(pod["spec"]["volumes"], &(&1["name"] == "shm"))
      assert Enum.any?(podman_argv(), &String.starts_with?(&1, "/tmp:rw,nosuid,nodev"))
    end

    test "a `tmp` mount at /tmp does not create a second mount of /tmp" do
      pod = build!()
      assert Enum.count(mounts(pod), &(&1["mountPath"] == "/tmp")) == 1
    end
  end

  describe "§8 row 12: -e NAME (inherit; the value never on argv)" do
    test "secret values and names appear nowhere in the pod; the entry wrapper sources a memory file" do
      pod = build!()
      refute inspect(pod) =~ "sk-ant-oat-SECRET-VALUE"
      refute inspect(pod) =~ "CLAUDE_CODE_OAUTH_TOKEN"
      refute Enum.any?(pod["spec"]["volumes"], &Map.has_key?(&1, "secret"))

      assert Enum.find(pod["spec"]["volumes"], &(&1["name"] == "run")) ==
               %{"name" => "run", "emptyDir" => %{"medium" => "Memory", "sizeLimit" => "64Mi"}}

      assert mount_at(pod, "/run/arb") == %{"name" => "run", "mountPath" => "/run/arb"}
      assert Enum.at(worker(pod)["command"], 4) =~ ". /run/arb/env"
      assert Enum.at(worker(pod)["command"], 4) =~ "rm -f /run/arb/env"
    end

    test "prompt, config-file and worktree-file contents are delivered by seed, never rendered" do
      pod =
        build!(
          run_spec(%{
            "mounts" => [
              %{
                "kind" => "worktree",
                "path" => @wt,
                "files" => %{".mcp.json" => Base.encode64("MCP-BEARER-BODY")}
              },
              %{
                "kind" => "config_dir",
                "path" => @config_dir,
                "files" => %{"CLAUDE.md" => Base.encode64("MEMORY-BODY")}
              },
              %{
                "kind" => "prompt",
                "path" => "/var/lib/arb/run/prompt.md",
                "content" => Base.encode64("PROMPT-BODY")
              }
            ]
          })
        )

      for body <- ["MCP-BEARER-BODY", "MEMORY-BODY", "PROMPT-BODY", Base.encode64("PROMPT-BODY")] do
        refute inspect(pod) =~ body
      end

      assert mount_at(pod, "/var/lib/arb/run/prompt.md") ==
               %{
                 "name" => "run",
                 "mountPath" => "/var/lib/arb/run/prompt.md",
                 "subPath" => "prompt-0",
                 "readOnly" => true
               }
    end
  end

  describe "§8 row 13: -e NAME=value (literals)" do
    test "non-secret env entries become env:, sorted, with the service worker_env merged in" do
      pod =
        build!(run_spec(%{"services" => [%{"preset" => "postgres", "database" => "vstim_test"}]}))

      env = env_pairs(worker(pod))

      assert {"ARB_WORKER_BEAD_ID", "bd-1nfuq5"} in env
      assert {"LANG", "C.UTF-8"} in env
      assert {"DATABASE_URL", "postgres://postgres:postgres@127.0.0.1:5432/vstim_test"} in env
      assert env == Enum.sort(env)
      assert Enum.all?(worker(pod)["env"], &(Map.keys(&1) |> Enum.sort() == ["name", "value"]))
    end

    test "a spec env var cannot shadow the controller-owned boot variables" do
      for name <- ~w(ARB_BOOT_NONCE ARB_BRIDGE_ADDR ARB_GATE_ADDR) do
        {:ok, spec} = Arbiter.NodeAgent.RunSpec.validate(wire_spec(%{"env" => %{name => "x"}}))

        assert {:error, {:bad_spec, {:reserved_env, ^name}}} =
                 PodSpec.build(put_ref(spec), config())
      end
    end
  end

  describe "§8 row 14: the CLI mounts" do
    test "an image layer: no volume or mount for /opt/arbiter/cli; the root stays read-only" do
      pod = build!()
      refute Enum.any?(mounts(pod), &String.starts_with?(&1["mountPath"], "/opt/arbiter"))
      assert worker(pod)["securityContext"]["readOnlyRootFilesystem"] == true

      assert Enum.any?(
               podman_argv(extra_cli()),
               &String.ends_with?(&1, "/opt/arbiter/cli/claude:ro")
             )
    end

    defp extra_cli, do: %{cli_mounts: [{"/host/claude", "/opt/arbiter/cli/claude"}]}
  end

  describe "§8 row 15: --memory / --memory-swap / --cpus" do
    test "limits.memory and cpu, with requests; swap has no field" do
      pod = build!()
      res = worker(pod)["resources"]

      assert res["limits"] == %{"cpu" => "1500m", "memory" => "3Gi"}
      assert res["requests"] == %{"cpu" => "1", "memory" => "2Gi", "ephemeral-storage" => "4Gi"}
      refute inspect(res) =~ "swap"
    end

    test "the effective limit is min(spec, config): the in-cluster config is authoritative" do
      pod = build!(run_spec(%{"limits" => %{"memory" => "64g", "cpus" => "32"}}))
      assert worker(pod)["resources"]["limits"] == %{"cpu" => "2", "memory" => "4Gi"}
    end

    test "no spec limits: the config limits apply" do
      pod = build!(run_spec(%{"limits" => %{}}))
      assert worker(pod)["resources"]["limits"] == %{"cpu" => "2", "memory" => "4Gi"}
    end

    test "requests never exceed the effective limit" do
      pod = build!(run_spec(%{"limits" => %{"memory" => "1g", "cpus" => "0.5"}}))
      res = worker(pod)["resources"]
      assert res["limits"] == %{"cpu" => "500m", "memory" => "1Gi"}
      assert res["requests"]["memory"] == "1Gi"
      assert res["requests"]["cpu"] == "500m"
    end
  end

  describe "§8 row 16: --pull=never" do
    test "imagePullPolicy IfNotPresent with a digest-pinned reference" do
      pod = build!()
      assert "--pull=never" in podman_argv()

      for name <- ["seed", "snapshotter", "worker"] do
        c = container(pod, name)
        assert c["imagePullPolicy"] == "IfNotPresent"
        assert c["image"] == "#{registry()}/beam@sha256:#{digest()}"
      end
    end

    test "a tag-only or off-registry reference is bad_spec" do
      for ref <- [
            "#{registry()}/beam:latest",
            "#{registry()}/beam@sha256:abc",
            "evil.example/beam@sha256:#{digest()}",
            "-#{registry()}/beam@sha256:#{digest()}"
          ] do
        assert {:error, {:bad_spec, {:bad_image, _}}} =
                 PodSpec.build(put_ref(run_spec(), ref), config())
      end
    end

    test "a spec with no image reference is bad_spec" do
      {:ok, spec} = Arbiter.NodeAgent.RunSpec.validate(wire_spec())
      assert {:error, {:bad_spec, {:missing, "image.ref"}}} = PodSpec.build(spec, config())
    end
  end

  describe "§8 row 17: --init" do
    test "tini is the entrypoint of the worker and the snapshotter" do
      pod = build!()
      assert "--init" in podman_argv()
      assert ["tini", "--", "sh", "-c", _script, "sh", "claude" | _] = worker(pod)["command"]

      assert ["tini", "--", "/opt/arbiter/bin/snapshotter"] =
               container(pod, "snapshotter")["command"]
    end

    test "the spec command is passed as separate argv words, never interpolated into the script" do
      evil = "x; rm -rf / $(id) `id`"
      pod = build!(run_spec(%{"command" => ["claude", evil]}))
      [_, _, _, _, script, "sh", "claude", word] = worker(pod)["command"]
      refute script =~ "rm -rf"
      assert word == String.replace(evil, "$", "$$")
      assert kubelet_expand(word) == evil
    end

    test "$ is doubled so the kubelet's $(VAR) and $$ expansion cannot rewrite the command or env" do
      cmd = ["claude", "$(HOME)", "cost: $5 and $$", "trailing$"]
      pod = build!(run_spec(%{"command" => cmd, "env" => %{"PS1" => "$(date) $$"}}))
      [_, _, _, _, _, "sh" | argv] = worker(pod)["command"]

      assert Enum.map(argv, &kubelet_expand/1) == cmd

      assert Enum.find(worker(pod)["env"], &(&1["name"] == "PS1"))["value"] |> kubelet_expand() ==
               "$(date) $$"
    end
  end

  describe "§8 row 18: --security-opt label=disable" do
    test "never carried over: no seLinuxOptions anywhere, even with bridges" do
      pod = build!(run_spec(wire_bridges()))
      assert "label=disable" in podman_argv(%{bridges: ["/s/proxy.sock"]})

      refute inspect(pod) =~ "seLinux"
      refute inspect(pod) =~ "spc_t"
      refute inspect(pod) =~ "label=disable"
    end

    test "a spec naming seLinuxOptions or spc_t is bad_spec" do
      base = run_spec()

      for bad <- [
            Map.put(Map.from_struct(base), :se_linux_options, %{type: "spc_t"}),
            Map.put(Map.from_struct(base), "seLinuxOptions", %{"type" => "spc_t"}),
            Map.put(Map.from_struct(base), :selinux, "spc_t"),
            Map.put(Map.from_struct(base), :labels, %{"seLinuxOptions" => "x"}),
            %{
              base
              | mounts:
                  base.mounts ++ [%{kind: "tmp", path: "/x", seLinuxOptions: %{type: "spc_t"}}]
            },
            %{base | mounts: [%{kind: "worktree", path: @wt, selinux_type: "spc_t"}]}
          ] do
        assert {:error, {:bad_spec, {:selinux_not_allowed, _}}} = PodSpec.build(bad, config()),
               inspect(bad)
      end
    end

    test "spc_t as a value of a structural field is refused; as text in the command it is data" do
      base = run_spec()

      assert {:error, {:bad_spec, {:selinux_not_allowed, _}}} =
               PodSpec.build(%{base | labels: %{"type" => "spc_t"}}, config())

      assert {:ok, _} =
               PodSpec.build(
                 %{base | command: ["claude", "explain spc_t and seLinuxOptions"]},
                 config()
               )
    end

    test "a service asking for a security context of its own is bad_spec" do
      base = run_spec()

      svc = %{
        name: "evil",
        image: "docker.io/library/postgres:16",
        seLinuxOptions: %{type: "spc_t"}
      }

      assert {:error, {:bad_spec, {:selinux_not_allowed, _}}} =
               PodSpec.build(%{base | services: [svc]}, config())

      svc = %{
        name: "evil",
        image: "docker.io/library/postgres:16",
        security_context: %{privileged: true}
      }

      assert {:error, {:bad_spec, {:unknown_service_field, _}}} =
               PodSpec.build(%{base | services: [svc]}, config())
    end
  end

  describe "§8 row 19: the pod-level fields with no podman twin" do
    test "service account, token, links, host namespaces, deadlines, priority" do
      pod = build!()
      spec = pod["spec"]

      assert spec["serviceAccountName"] == "arbiter-worker"
      assert spec["automountServiceAccountToken"] == false
      assert spec["enableServiceLinks"] == false
      assert spec["restartPolicy"] == "Never"
      assert spec["priorityClassName"] == "arbiter-worker"
      assert spec["activeDeadlineSeconds"] == 3600 + 1800
      assert spec["terminationGracePeriodSeconds"] == 120
      for k <- ~w(hostNetwork hostPID hostIPC shareProcessNamespace), do: refute(spec[k] == true)
      refute Enum.any?(all_containers(pod), &Map.has_key?(&1, "ports"))
      refute inspect(pod) =~ "hostPort"
    end

    test "no volume other than emptyDir and the arbiter-ca ConfigMap" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))

      for v <- pod["spec"]["volumes"] do
        assert Map.has_key?(v, "emptyDir") or v["configMap"] == %{"name" => "arbiter-ca"},
               v["name"]
      end
    end

    test "no subPath comes from a Secret volume (there is none)" do
      pod = build!()
      secret_volumes = for v <- pod["spec"]["volumes"], Map.has_key?(v, "secret"), do: v["name"]
      assert secret_volumes == []
    end
  end

  describe "metadata" do
    test "name, namespace, labels the reaper keys on, owner reference" do
      pod = build!()
      meta = pod["metadata"]

      assert meta["name"] == "arb-run-0123456789ab"
      assert meta["namespace"] == "arbiter-workers"

      assert meta["labels"] == %{
               "app.kubernetes.io/name" => "arbiter-worker",
               "app.kubernetes.io/component" => "worker",
               "arbiter.dev/install" => "inst-1",
               "arbiter.dev/node" => "node-1",
               "arbiter.dev/run" => "run-0123456789abcdef",
               "arbiter.dev/task" => "bd-1nfuq5"
             }

      assert [
               %{
                 "apiVersion" => "apps/v1",
                 "kind" => "Deployment",
                 "name" => "arbiter-controller",
                 "uid" => uid
               }
             ] =
               meta["ownerReferences"]

      assert uid == config().owner_uid
    end

    test "an unsafe name or label value is bad_spec" do
      base = run_spec()

      for bad <- [
            %{base | name: "arb-UPPER"},
            %{base | name: "arb-" <> String.duplicate("a", 60)},
            %{base | name: "arb_x"}
          ] do
        assert {:error, {:bad_spec, {:bad_name, _}}} = PodSpec.build(bad, config())
      end

      assert {:error, {:bad_spec, {:bad_label, "arbiter.dev/run"}}} =
               PodSpec.build(%{base | run: String.duplicate("a", 64)}, config())
    end

    test "extra labels from the spec cannot overwrite the controller's" do
      pod = build!(%{run_spec() | labels: %{"arbiter.dev/run" => "other", "extra" => "1"}})
      assert pod["metadata"]["labels"]["arbiter.dev/run"] == "run-0123456789abcdef"
    end
  end

  describe "mounts" do
    test "an unknown mount kind is bad_spec" do
      base = run_spec()

      for kind <- [
            "hostPath",
            "secret",
            "device",
            "objects_overlay",
            "bridge:proxy",
            nil,
            :worktree2
          ] do
        bad = %{base | mounts: base.mounts ++ [%{kind: kind, path: "/x/y"}]}
        assert {:error, {:bad_spec, {:unknown_mount_kind, ^kind}}} = PodSpec.build(bad, config())
      end
    end

    test "a mount with a host path or a key the builder does not know is bad_spec" do
      base = run_spec()

      bad = %{base | mounts: base.mounts ++ [%{kind: "tmp", path: "/x/y", host_path: "/etc"}]}

      assert {:error, {:bad_spec, {:unknown_mount_field, :host_path}}} =
               PodSpec.build(bad, config())
    end

    test "the worktree mount is required" do
      base = run_spec()
      bad = %{base | mounts: Enum.reject(base.mounts, &(&1.kind == "worktree"))}
      assert {:error, {:bad_spec, {:missing_mount, "worktree"}}} = PodSpec.build(bad, config())
    end

    test "two mounts at one path, or a mount over a reserved path, are bad_spec" do
      base = run_spec()

      dup = %{base | mounts: base.mounts ++ [%{kind: "tmp", path: @home}]}
      assert {:error, {:bad_spec, {:duplicate_mount_path, @home}}} = PodSpec.build(dup, config())

      for path <- ["/run/arb", "/run/arb/tls", "/etc/arb/ca", "/etc/arb/ca/x"] do
        bad = %{base | mounts: [%{kind: "home", path: path} | base.mounts]}
        assert {:error, {:bad_spec, {:reserved_path, ^path}}} = PodSpec.build(bad, config()), path
      end
    end

    test "a tmp mount at another path is a subPath of the memory tmp volume" do
      base = run_spec()

      pod =
        build!(%{base | mounts: base.mounts ++ [%{kind: "tmp", path: "/var/lib/arb/scratch"}]})

      assert mount_at(pod, "/var/lib/arb/scratch") ==
               %{"name" => "tmp", "mountPath" => "/var/lib/arb/scratch", "subPath" => "tmp-0"}
    end

    test "path characters Kubernetes would treat specially are refused" do
      base = run_spec()

      for path <- ["relative/path", "/a/../b", "/a:b", "/a,b"] do
        bad = %{base | mounts: [%{kind: "home", path: path} | base.mounts]}
        assert {:error, {:bad_spec, {:bad_path, ^path}}} = PodSpec.build(bad, config()), path
      end
    end

    test "worktree mount order puts the parent before every child, whatever the spec order" do
      base = run_spec()
      pod = build!(%{base | mounts: Enum.reverse(base.mounts)})
      paths = Enum.map(mounts(pod), & &1["mountPath"])

      for p <- paths, parent <- paths, parent != p, String.starts_with?(p, parent <> "/") do
        assert Enum.find_index(paths, &(&1 == parent)) < Enum.find_index(paths, &(&1 == p)),
               "#{parent} before #{p}"
      end
    end
  end

  describe "bridges" do
    test "bridge sockets have no pod twin: the CA mount, the controller address and the names" do
      pod = build!(run_spec(wire_bridges()))

      assert mount_at(pod, "/etc/arb/ca") ==
               %{"name" => "ca", "mountPath" => "/etc/arb/ca", "readOnly" => true}

      env = env_pairs(worker(pod))
      assert {"ARB_BRIDGE_ADDR", "10.43.98.199"} in env
      assert {"ARB_BRIDGES", "proxy arb"} in env
      refute inspect(pod) =~ ".sock"
    end

    test "no bridges: ARB_BRIDGES is empty" do
      assert {"ARB_BRIDGES", ""} in env_pairs(worker(build!()))
    end
  end

  describe "seed and snapshotter" do
    test "seed gets the boot nonce, the controller and the gate address, and runs the gate first" do
      pod = build!()
      seed = container(pod, "seed")
      env = Map.new(env_pairs(seed))

      assert env["ARB_BOOT_NONCE"] == config().boot_nonce
      assert env["ARB_BRIDGE_ADDR"] == "10.43.98.199"
      assert env["ARB_GATE_ADDR"] == "10.43.0.1:443"
      refute Map.has_key?(seed, "restartPolicy")
      assert ["sh", "-c", script] = seed["command"]
      assert script =~ "ARB_GATE_ADDR"
      assert String.contains?(script, "step 0")
    end

    test "the boot nonce is only on seed" do
      pod = build!()
      refute inspect(worker(pod)) =~ config().boot_nonce
      refute inspect(container(pod, "snapshotter")) =~ config().boot_nonce
    end

    test "the snapshotter is a native sidecar with the worker's hardening" do
      pod = build!()
      snap = container(pod, "snapshotter")

      assert snap["restartPolicy"] == "Always"
      assert snap["securityContext"] == worker(pod)["securityContext"]
      assert {"ARB_SNAPSHOT_INTERVAL_S", "300"} in env_pairs(snap)
    end

    test "the checkout interval from the spec drives the snapshot interval" do
      pod = build!(run_spec(%{"checkout" => %{"branch" => "feature/x", "interval_s" => 60}}))
      assert {"ARB_SNAPSHOT_INTERVAL_S", "60"} in env_pairs(container(pod, "snapshotter"))
    end

    test "init containers run seed, then services, then the snapshotter" do
      pod =
        build!(
          run_spec(%{"services" => [%{"preset" => "postgres"}, %{"preset" => "s3"}]}),
          %{service_image_allowlist: ["docker.io/pgsty/"]}
        )

      assert Enum.map(pod["spec"]["initContainers"], & &1["name"]) ==
               ["seed", "svc-postgres", "svc-s3", "snapshotter"]
    end
  end

  describe "test services (§6)" do
    test "K1-A9: a preset's command is rendered as args, never as command" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      svc = container(pod, "svc-postgres")

      assert svc["args"] == ["postgres", "-c", "fsync=off", "-c", "listen_addresses=127.0.0.1"]
      refute Map.has_key?(svc, "command")
    end

    test "a service is a native sidecar with a startupProbe from ready" do
      pod =
        build!(run_spec(%{"services" => [%{"preset" => "postgres", "database" => "app_test"}]}))

      svc = container(pod, "svc-postgres")

      assert svc["restartPolicy"] == "Always"
      assert svc["image"] == "docker.io/library/postgres:16-alpine"
      assert svc["imagePullPolicy"] == "IfNotPresent"

      assert svc["startupProbe"] == %{
               "exec" => %{
                 "command" => [
                   "pg_isready",
                   "-h",
                   "127.0.0.1",
                   "-p",
                   "5432",
                   "-U",
                   "postgres",
                   "-d",
                   "app_test"
                 ]
               },
               "periodSeconds" => 1,
               "failureThreshold" => 120
             }
    end

    test "K1-A9: Postgres runs as uid 70 with the full hardening; the default uid applies elsewhere" do
      pod =
        build!(
          run_spec(%{"services" => [%{"preset" => "postgres"}, %{"preset" => "s3"}]}),
          %{service_image_allowlist: ["docker.io/pgsty/"]}
        )

      assert container(pod, "svc-postgres")["securityContext"] == %{
               "runAsUser" => 70,
               "runAsGroup" => 70,
               "allowPrivilegeEscalation" => false,
               "privileged" => false,
               "procMount" => "Default",
               "readOnlyRootFilesystem" => true,
               "capabilities" => %{"drop" => ["ALL"]}
             }

      s3 = container(pod, "svc-s3")["securityContext"]
      refute Map.has_key?(s3, "runAsUser")
    end

    test "tmpfs entries become memory emptyDirs with a sizeLimit, mounted at the path" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      mounts = mounts(pod, "svc-postgres")

      assert Enum.map(mounts, & &1["mountPath"]) == [
               "/var/lib/postgresql/data",
               "/var/run/postgresql"
             ]

      for m <- mounts do
        vol = Enum.find(pod["spec"]["volumes"], &(&1["name"] == m["name"]))
        assert vol["emptyDir"] == %{"medium" => "Memory", "sizeLimit" => "256Mi"}
      end
    end

    test "service env literals, resources from services_resources" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      svc = container(pod, "svc-postgres")

      assert {"POSTGRES_PASSWORD", "postgres"} in env_pairs(svc)

      assert svc["resources"] == %{
               "requests" => %{"cpu" => "100m", "memory" => "256Mi"},
               "limits" => %{"memory" => "512Mi"}
             }
    end

    test "an image outside docker.io/library/ and the registry needs an allowlist entry" do
      spec = run_spec(%{"services" => [%{"preset" => "s3"}]})

      assert {:error, {:bad_spec, {:service_image_not_allowed, "docker.io/pgsty/silo"}}} =
               PodSpec.build(spec, config())

      assert {:ok, _} =
               PodSpec.build(spec, config(%{service_image_allowlist: ["docker.io/pgsty/"]}))
    end

    test "a service uid of 0 or out of range is bad_spec" do
      base = run_spec()

      for uid <- [0, -1, 65_536, "70"] do
        svc = %{name: "pg", image: "docker.io/library/postgres:16", uid: uid}

        assert {:error, {:bad_spec, {:bad_service_uid, ^uid}}} =
                 PodSpec.build(%{base | services: [svc]}, config())
      end
    end

    test "services share the worker's pod: no ports, no hostPort, 127.0.0.1 in worker env" do
      pod = build!(run_spec(%{"services" => [%{"preset" => "postgres"}]}))
      refute Enum.any?(all_containers(pod), &Map.has_key?(&1, "ports"))
      assert {"PGHOST", "127.0.0.1"} in env_pairs(worker(pod))
    end
  end

  describe "placement and config" do
    test "node selector, tolerations, runtime class and pull secrets come from config" do
      pod =
        build!(nil, %{
          placement: %{
            node_selector: %{"kubernetes.io/hostname" => "mesanna"},
            tolerations: [
              %{key: "dedicated", operator: "Equal", value: "arbiter", effect: "NoSchedule"}
            ],
            priority_class: "arbiter-worker",
            runtime_class: "gvisor"
          },
          image_pull_secrets: ["gitlab-registry"]
        })

      spec = pod["spec"]
      assert spec["nodeSelector"] == %{"kubernetes.io/hostname" => "mesanna"}
      assert spec["runtimeClassName"] == "gvisor"
      assert spec["imagePullSecrets"] == [%{"name" => "gitlab-registry"}]

      assert [
               %{
                 "key" => "dedicated",
                 "operator" => "Equal",
                 "value" => "arbiter",
                 "effect" => "NoSchedule"
               }
             ] = spec["tolerations"]
    end

    test "an empty runtime class and empty selectors emit no field" do
      spec = build!()["spec"]

      for k <- ~w(runtimeClassName nodeSelector tolerations imagePullSecrets),
          do: refute(Map.has_key?(spec, k), k)
    end

    test "config is a closed schema: security fields are not settable, ever" do
      for key <- [
            :security_context,
            :volumes,
            :service_account,
            :host_network,
            :image,
            :network,
            :se_linux_options,
            :host_path
          ] do
        assert {:error, {:bad_config, {:unknown_key, ^key}}} =
                 PodSpec.build(run_spec(), Map.put(config(), key, "x")),
               inspect(key)
      end
    end

    test "required context is checked" do
      for key <- [
            :registry,
            :install_id,
            :node_id,
            :owner_uid,
            :bridge_addr,
            :gate_addr,
            :boot_nonce,
            :max_wall_s
          ] do
        assert {:error, {:bad_config, {:missing, ^key}}} =
                 PodSpec.build(run_spec(), Map.delete(config(), key)),
               inspect(key)
      end
    end

    test "malformed quantities and non-positive deadlines are bad_config" do
      assert {:error, {:bad_config, {:bad_quantity, _}}} =
               PodSpec.build(run_spec(), config(%{worker: %{limits: %{memory: "lots"}}}))

      assert {:error, {:bad_config, {:bad_value, :max_wall_s}}} =
               PodSpec.build(run_spec(), config(%{max_wall_s: 0}))
    end

    test "a boot nonce or bridge address that is not what the controller mints is bad_config" do
      assert {:error, {:bad_config, {:bad_value, :boot_nonce}}} =
               PodSpec.build(run_spec(), config(%{boot_nonce: ""}))

      assert {:error, {:bad_config, {:bad_value, :bridge_addr}}} =
               PodSpec.build(run_spec(), config(%{bridge_addr: "evil host"}))
    end
  end

  describe "purity and shape" do
    test "build/2 is deterministic and returns JSON-encodable string-keyed maps" do
      assert PodSpec.build(run_spec(), config()) == PodSpec.build(run_spec(), config())
      pod = build!()
      assert pod == pod |> Jason.encode!() |> Jason.decode!()
      assert pod["apiVersion"] == "v1" and pod["kind"] == "Pod"
    end

    test "a plain atom-keyed map is accepted the same as a RunSpec struct" do
      spec = run_spec()
      assert PodSpec.build(Map.from_struct(spec), config()) == PodSpec.build(spec, config())
    end

    test "a non-map spec is bad_spec" do
      assert {:error, {:bad_spec, :not_a_map}} = PodSpec.build("nope", config())
    end

    test "an unknown top-level key on a plain map is bad_spec" do
      spec = Map.put(Map.from_struct(run_spec()), :host_pid, true)
      assert {:error, {:bad_spec, {:unknown_field, :host_pid}}} = PodSpec.build(spec, config())
    end
  end

  # -- helpers ---------------------------------------------------------------------------

  defp wire_bridges, do: with_bridges()

  # The kubelet's expansion (`third_party/forked/golang/expansion`) with no
  # variables defined: `$$` is `$`; `$(X)` and `$x` stay as written.
  defp kubelet_expand(string), do: do_expand(string, "")

  defp do_expand("$$" <> rest, acc), do: do_expand(rest, acc <> "$")
  defp do_expand(<<c::utf8, rest::binary>>, acc), do: do_expand(rest, acc <> <<c::utf8>>)
  defp do_expand("", acc), do: acc

  defp env_pairs(container), do: Enum.map(container["env"] || [], &{&1["name"], &1["value"]})
end
