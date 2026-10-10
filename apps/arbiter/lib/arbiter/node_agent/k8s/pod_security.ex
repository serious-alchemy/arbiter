defmodule Arbiter.NodeAgent.K8s.PodSecurity do
  @moduledoc """
  A table-driven conformance checker for the pods
  `Arbiter.NodeAgent.K8s.PodSpec` builds (K4, `docs/design/remote-workers.md` §7,
  §8). It re-derives, from the manifest alone, what the cluster would enforce and
  what the builder promises:

    * `:baseline` and `:restricted`: the Kubernetes Pod Security Standards
      (v1.30+) rule by rule, so a built pod is checked against the profile the
      namespace is labelled with (`pod-security.kubernetes.io/enforce: restricted`).
    * `:arbiter`: what the namespace label does **not** give us. *(K1-A1)* With
      `hostUsers: false` Pod Security stops enforcing non-root, so this group
      asserts it itself (a pod-level non-zero uid with `runAsNonRoot`, and no
      container overriding either); it also pins the §8 fields that are the
      builder's alone: `hostUsers: false`, a read-only root everywhere, **no
      `appArmorProfile` and no `seLinuxOptions` at all** (K1-A2, §8.1), exactly
      `drop: [ALL]` with no `add`, the service account and no token, only
      `emptyDir` and the `arbiter-ca` ConfigMap as volumes, no network (DNS
      `None`, no ports, no service links), the default seccomp profile, and
      digest-pinned images under the registry.

  The restricted rules are deliberately *tighter* than the standard where the
  standard is silent (`:volume_types` admits Secrets and PVCs; the arbiter
  `:volumes` rule does not), because the namespace label is the floor and the
  builder's promise is the ceiling.

  `rules/0` is the table; `check/2` runs it over a string-keyed pod map (the
  builder's output, or `kubectl get pod -o json` decoded) and tolerates malformed
  input, reporting violations instead of crashing.
  """

  @type level :: :baseline | :restricted | :arbiter
  @type violation :: %{rule: atom(), level: level(), path: String.t()}
  @type rule :: %{
          id: atom(),
          level: level(),
          description: String.t(),
          check: (map(), keyword() -> [String.t()])
        }

  @allowed_selinux_types [
    "",
    "container_t",
    "container_init_t",
    "container_kvm_t",
    "container_engine_t"
  ]
  @baseline_caps ~w(AUDIT_WRITE CHOWN DAC_OVERRIDE FOWNER FSETID KILL MKNOD NET_BIND_SERVICE SETFCAP SETGID SETPCAP SETUID SYS_CHROOT)
  @safe_sysctls ~w(kernel.shm_rmid_forced net.ipv4.ip_local_port_range net.ipv4.ip_unprivileged_port_start
                   net.ipv4.tcp_syncookies net.ipv4.ping_group_range net.ipv4.ip_local_reserved_ports
                   net.ipv4.tcp_keepalive_time net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_intvl
                   net.ipv4.tcp_keepalive_probes)
  @restricted_volumes ~w(configMap csi downwardAPI emptyDir ephemeral persistentVolumeClaim projected secret)
  @apparmor_annotation "container.apparmor.security.beta.kubernetes.io/"
  @service_account "arbiter-worker"
  @ca_configmap "arbiter-ca"
  @own_images ~w(seed snapshotter worker)

  @doc "The rule table: `%{id, level, description, check}`."
  @spec rules() :: [rule()]
  def rules do
    [
      # -- Pod Security Standards: baseline ---------------------------------------------
      rule(:host_process, :baseline, "no Windows HostProcess containers", &host_process/2),
      rule(
        :host_namespaces,
        :baseline,
        "hostNetwork, hostPID, hostIPC are not true",
        &host_namespaces/2
      ),
      rule(:privileged, :baseline, "no privileged container", &privileged/2),
      rule(
        :baseline_capabilities,
        :baseline,
        "capabilities.add stays inside the baseline list",
        &baseline_capabilities/2
      ),
      rule(:host_path_volumes, :baseline, "no hostPath volume", &host_path_volumes/2),
      rule(:host_ports, :baseline, "no hostPort", &host_ports/2),
      rule(:host_probes, :baseline, "probes and hooks name no host", &host_probes/2),
      rule(
        :apparmor,
        :baseline,
        "AppArmor is RuntimeDefault or Localhost, when set",
        &apparmor/2
      ),
      rule(:selinux, :baseline, "SELinux type is a container type; no user or role", &selinux/2),
      rule(:proc_mount, :baseline, "procMount is Default", &proc_mount/2),
      rule(:seccomp_baseline, :baseline, "seccomp is not Unconfined", &seccomp_baseline/2),
      rule(:sysctls, :baseline, "only safe sysctls", &sysctls/2),
      # -- restricted -----------------------------------------------------------------------
      rule(:volume_types, :restricted, "only the restricted volume types", &volume_types/2),
      rule(
        :privilege_escalation,
        :restricted,
        "allowPrivilegeEscalation is false on every container",
        &privilege_escalation/2
      ),
      rule(:run_as_non_root, :restricted, "every container is runAsNonRoot", &run_as_non_root/2),
      rule(:run_as_user, :restricted, "no uid 0", &run_as_user/2),
      rule(
        :seccomp_restricted,
        :restricted,
        "RuntimeDefault or Localhost seccomp on every container",
        &seccomp_restricted/2
      ),
      rule(
        :capabilities_restricted,
        :restricted,
        "drop ALL, add at most NET_BIND_SERVICE",
        &capabilities_restricted/2
      ),
      # -- what the builder promises beyond the label ---------------------------------------------
      rule(
        :non_root,
        :arbiter,
        "K1-A1: non-root asserted here, PSA relaxes it under hostUsers: false",
        &non_root/2
      ),
      rule(:host_users, :arbiter, "hostUsers is false", &host_users/2),
      rule(
        :read_only_root,
        :arbiter,
        "read-only root filesystem on every container",
        &read_only_root/2
      ),
      rule(
        :no_apparmor,
        :arbiter,
        "K1-A2: no appArmorProfile or annotation anywhere",
        &no_apparmor/2
      ),
      rule(:no_selinux, :arbiter, "§8.1: no seLinuxOptions anywhere", &no_selinux/2),
      rule(
        :strict_capabilities,
        :arbiter,
        "drop is exactly [ALL], no add, privileged false, procMount Default",
        &strict_capabilities/2
      ),
      rule(:service_account, :arbiter, "arbiter-worker with no token", &service_account/2),
      rule(:volumes, :arbiter, "only emptyDir and the arbiter-ca ConfigMap", &volumes/2),
      rule(
        :network,
        :arbiter,
        "DNS None, no service links, no ports, no shared process namespace",
        &network/2
      ),
      rule(:seccomp, :arbiter, "the pod's seccomp profile is RuntimeDefault", &seccomp/2),
      rule(
        :image,
        :arbiter,
        "IfNotPresent; digest-pinned under the registry; services on an allowed prefix",
        &image/2
      )
    ]
  end

  @doc """
  Every violation of the selected levels (default all three), as
  `%{rule, level, path}`.

  Options: `levels:` (a subset of `[:baseline, :restricted, :arbiter]`), `registry:`
  (the image prefix; without it `:image` is skipped) and `image_prefixes:` (extra
  allowed prefixes for service images; `docker.io/library/` is always allowed).
  """
  @spec violations(map(), keyword()) :: [violation()]
  def violations(pod, opts \\ []) do
    levels = Keyword.get(opts, :levels, [:baseline, :restricted, :arbiter])

    for %{level: level} = rule <- rules(), level in levels, path <- safe_check(rule, pod, opts) do
      %{rule: rule.id, level: level, path: path}
    end
  end

  @doc "`:ok`, or `{:error, violations}`."
  @spec check(map(), keyword()) :: :ok | {:error, [violation()]}
  def check(pod, opts \\ []) do
    case violations(pod, opts) do
      [] -> :ok
      violations -> {:error, violations}
    end
  end

  defp rule(id, level, description, check),
    do: %{id: id, level: level, description: description, check: check}

  defp safe_check(rule, pod, opts) do
    rule.check.(pod, opts)
  rescue
    # A rule that cannot read a malformed manifest has found a problem with it.
    _ -> ["spec"]
  end

  # -- navigation ---------------------------------------------------------------------------

  defp dig(term, []), do: term
  defp dig(%{} = map, [key | rest]), do: dig(Map.get(map, key), rest)
  defp dig(_other, [_ | _]), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_), do: []

  defp spec(pod), do: dig(pod, ["spec"]) || %{}
  defp pod_sc(pod), do: dig(pod, ["spec", "securityContext"]) || %{}

  # [{path_prefix, container}] across containers, initContainers and ephemeralContainers.
  defp containers(pod) do
    for kind <- ~w(containers initContainers ephemeralContainers),
        %{} = c <- list(dig(pod, ["spec", kind])) do
      {"spec.#{kind}[#{c["name"]}]", c}
    end
  end

  defp sc(container), do: dig(container, ["securityContext"]) || %{}

  defp caps(container, key), do: list(dig(container, ["securityContext", "capabilities", key]))

  # -- baseline ---------------------------------------------------------------------------------

  defp host_process(pod, _) do
    pod_paths =
      if dig(pod_sc(pod), ["windowsOptions", "hostProcess"]) == true,
        do: ["spec.securityContext.windowsOptions.hostProcess"],
        else: []

    pod_paths ++
      for {path, c} <- containers(pod),
          dig(sc(c), ["windowsOptions", "hostProcess"]) == true,
          do: path <> ".securityContext.windowsOptions.hostProcess"
  end

  defp host_namespaces(pod, _),
    do:
      for(
        key <- ~w(hostNetwork hostPID hostIPC),
        dig(spec(pod), [key]) == true,
        do: "spec." <> key
      )

  defp privileged(pod, _),
    do:
      for(
        {path, c} <- containers(pod),
        sc(c)["privileged"] == true,
        do: path <> ".securityContext.privileged"
      )

  defp baseline_capabilities(pod, _),
    do:
      for(
        {path, c} <- containers(pod),
        Enum.any?(caps(c, "add"), &(&1 not in @baseline_caps)),
        do: path <> ".securityContext.capabilities.add"
      )

  defp host_path_volumes(pod, _),
    do:
      for(
        %{"hostPath" => _} = v <- list(dig(pod, ["spec", "volumes"])),
        do: "spec.volumes[#{v["name"]}].hostPath"
      )

  defp host_ports(pod, _) do
    for {path, c} <- containers(pod),
        %{} = port <- list(c["ports"]),
        port["hostPort"] not in [nil, 0],
        do: path <> ".ports.hostPort"
  end

  defp host_probes(pod, _) do
    for {path, c} <- containers(pod),
        {key, handler} <- probe_handlers(c),
        host?(handler),
        do: "#{path}.#{key}"
  end

  defp probe_handlers(c) do
    probes = for k <- ~w(livenessProbe readinessProbe startupProbe), is_map(c[k]), do: {k, c[k]}

    hooks =
      for k <- ~w(postStart preStop),
          is_map(dig(c, ["lifecycle", k])),
          do: {"lifecycle." <> k, dig(c, ["lifecycle", k])}

    probes ++ hooks
  end

  defp host?(handler),
    do: Enum.any?(["httpGet", "tcpSocket"], &(dig(handler, [&1, "host"]) not in [nil, ""]))

  defp apparmor(pod, _) do
    profiles =
      [{"spec.securityContext.appArmorProfile", dig(pod_sc(pod), ["appArmorProfile", "type"])}] ++
        for {path, c} <- containers(pod),
            do:
              {path <> ".securityContext.appArmorProfile",
               dig(sc(c), ["appArmorProfile", "type"])}

    annotations =
      for {key, value} <- dig(pod, ["metadata", "annotations"]) |> as_map(),
          String.starts_with?(to_string(key), @apparmor_annotation),
          value != "runtime/default" and not String.starts_with?(to_string(value), "localhost/"),
          do: "metadata.annotations[#{key}]"

    for({path, type} <- profiles, type not in [nil, "RuntimeDefault", "Localhost"], do: path) ++
      annotations
  end

  defp as_map(%{} = m), do: m
  defp as_map(_), do: %{}

  defp selinux(pod, _) do
    levels =
      [{"spec.securityContext.seLinuxOptions", pod_sc(pod)["seLinuxOptions"]}] ++
        for {path, c} <- containers(pod),
            do: {path <> ".securityContext.seLinuxOptions", sc(c)["seLinuxOptions"]}

    for {path, %{} = options} <- levels,
        options["type"] not in @allowed_selinux_types or options["user"] not in [nil, ""] or
          options["role"] not in [nil, ""],
        do: path
  end

  defp proc_mount(pod, _),
    do:
      for(
        {path, c} <- containers(pod),
        sc(c)["procMount"] not in [nil, "Default"],
        do: path <> ".securityContext.procMount"
      )

  defp seccomp_baseline(pod, _) do
    pod_level =
      if dig(pod_sc(pod), ["seccompProfile", "type"]) == "Unconfined",
        do: ["spec.securityContext.seccompProfile"],
        else: []

    pod_level ++
      for {path, c} <- containers(pod),
          dig(sc(c), ["seccompProfile", "type"]) == "Unconfined",
          do: path <> ".securityContext.seccompProfile"
  end

  defp sysctls(pod, _) do
    for %{} = s <- list(pod_sc(pod)["sysctls"]),
        s["name"] not in @safe_sysctls,
        do: "spec.securityContext.sysctls[#{s["name"]}]"
  end

  # -- restricted ---------------------------------------------------------------------------------

  defp volume_types(pod, _) do
    for %{} = v <- list(dig(pod, ["spec", "volumes"])),
        not Enum.any?(@restricted_volumes, &Map.has_key?(v, &1)),
        do: "spec.volumes[#{v["name"]}]"
  end

  defp privilege_escalation(pod, _),
    do:
      for(
        {path, c} <- containers(pod),
        sc(c)["allowPrivilegeEscalation"] != false,
        do: path <> ".securityContext.allowPrivilegeEscalation"
      )

  # A container is non-root if it says so, or says nothing and the pod does.
  defp run_as_non_root(pod, _) do
    pod_value = pod_sc(pod)["runAsNonRoot"]
    pod_paths = if pod_value == false, do: ["spec.securityContext.runAsNonRoot"], else: []

    pod_paths ++
      for {path, c} <- containers(pod),
          Map.get(sc(c), "runAsNonRoot", pod_value) != true,
          do: path <> ".securityContext.runAsNonRoot"
  end

  defp run_as_user(pod, _) do
    pod_paths = if pod_sc(pod)["runAsUser"] == 0, do: ["spec.securityContext.runAsUser"], else: []

    pod_paths ++
      for {path, c} <- containers(pod),
          sc(c)["runAsUser"] == 0,
          do: path <> ".securityContext.runAsUser"
  end

  defp seccomp_restricted(pod, _) do
    pod_type = dig(pod_sc(pod), ["seccompProfile", "type"])

    for {path, c} <- containers(pod),
        (dig(sc(c), ["seccompProfile", "type"]) || pod_type) not in [
          "RuntimeDefault",
          "Localhost"
        ],
        do: path <> ".securityContext.seccompProfile"
  end

  defp capabilities_restricted(pod, _) do
    for {path, c} <- containers(pod),
        "ALL" not in caps(c, "drop") or Enum.any?(caps(c, "add"), &(&1 != "NET_BIND_SERVICE")),
        do: path <> ".securityContext.capabilities"
  end

  # -- arbiter ---------------------------------------------------------------------------------------

  defp non_root(pod, _) do
    sc = pod_sc(pod)
    pod_ok? = sc["runAsNonRoot"] == true and is_integer(sc["runAsUser"]) and sc["runAsUser"] != 0
    pod_paths = if pod_ok?, do: [], else: ["spec.securityContext"]

    pod_paths ++
      for {path, c} <- containers(pod),
          sc(c)["runAsUser"] == 0 or sc(c)["runAsNonRoot"] == false,
          do: path <> ".securityContext"
  end

  defp host_users(pod, _),
    do: if(dig(spec(pod), ["hostUsers"]) == false, do: [], else: ["spec.hostUsers"])

  defp read_only_root(pod, _),
    do:
      for(
        {path, c} <- containers(pod),
        sc(c)["readOnlyRootFilesystem"] != true,
        do: path <> ".securityContext.readOnlyRootFilesystem"
      )

  defp no_apparmor(pod, _) do
    pod_paths =
      if Map.has_key?(pod_sc(pod), "appArmorProfile"),
        do: ["spec.securityContext.appArmorProfile"],
        else: []

    annotations =
      for {key, _} <- as_map(dig(pod, ["metadata", "annotations"])),
          String.starts_with?(to_string(key), @apparmor_annotation),
          do: "metadata.annotations[#{key}]"

    pod_paths ++
      annotations ++
      for {path, c} <- containers(pod),
          Map.has_key?(sc(c), "appArmorProfile"),
          do: path <> ".securityContext.appArmorProfile"
  end

  defp no_selinux(pod, _) do
    pod_paths =
      if Map.has_key?(pod_sc(pod), "seLinuxOptions"),
        do: ["spec.securityContext.seLinuxOptions"],
        else: []

    pod_paths ++
      for {path, c} <- containers(pod),
          Map.has_key?(sc(c), "seLinuxOptions"),
          do: path <> ".securityContext.seLinuxOptions"
  end

  defp strict_capabilities(pod, _) do
    for {path, c} <- containers(pod),
        caps(c, "drop") != ["ALL"] or caps(c, "add") != [] or sc(c)["privileged"] != false or
          sc(c)["procMount"] != "Default",
        do: path <> ".securityContext"
  end

  defp service_account(pod, _) do
    for {key, want} <- [
          {"serviceAccountName", @service_account},
          {"automountServiceAccountToken", false}
        ],
        dig(spec(pod), [key]) != want,
        do: "spec." <> key
  end

  defp volumes(pod, _) do
    for %{} = v <- list(dig(pod, ["spec", "volumes"])),
        not (Map.has_key?(v, "emptyDir") or dig(v, ["configMap", "name"]) == @ca_configmap),
        do: "spec.volumes[#{v["name"]}]"
  end

  defp network(pod, _) do
    spec_paths =
      for {key, ok?} <- [
            {"dnsPolicy", dig(spec(pod), ["dnsPolicy"]) == "None"},
            {"enableServiceLinks", dig(spec(pod), ["enableServiceLinks"]) == false},
            {"shareProcessNamespace", dig(spec(pod), ["shareProcessNamespace"]) != true}
          ],
          not ok?,
          do: "spec." <> key

    spec_paths ++ for {path, c} <- containers(pod), list(c["ports"]) != [], do: path <> ".ports"
  end

  defp seccomp(pod, _),
    do:
      if(dig(pod_sc(pod), ["seccompProfile", "type"]) == "RuntimeDefault",
        do: [],
        else: ["spec.securityContext.seccompProfile"]
      )

  defp image(pod, opts) do
    case Keyword.get(opts, :registry) do
      nil ->
        []

      registry ->
        image_paths(pod, registry, ["docker.io/library/" | Keyword.get(opts, :image_prefixes, [])])
    end
  end

  defp image_paths(pod, registry, service_prefixes) do
    for {path, c} <- containers(pod),
        c["imagePullPolicy"] != "IfNotPresent" or not image_ok?(c, registry, service_prefixes),
        do: path <> ".image"
  end

  defp image_ok?(%{"name" => name, "image" => image}, registry, service_prefixes)
       when is_binary(image) do
    if name in @own_images do
      String.starts_with?(image, registry <> "/") and
        Regex.match?(~r/@sha256:[0-9a-f]{64}\z/, image)
    else
      Enum.any?([registry <> "/" | service_prefixes], &String.starts_with?(image, &1))
    end
  end

  defp image_ok?(_container, _registry, _prefixes), do: false
end
