defmodule Arbiter.NodeAgent.K8s.PodSpec do
  @moduledoc """
  The pure pod-spec builder for the Kubernetes in-cluster agent
  (`docs/design/remote-workers.md` §16 §8, K4): a validated run spec plus the
  controller's config in, a Pod manifest (a JSON-ready, string-keyed map) out.
  Like `Arbiter.Worker.Container.argv/2` it does no I/O and takes nothing from
  the environment, and it is the **security boundary** of the cluster backend:
  the hardening is this module's, and no input field can change it.

  ## One line per `Container.argv/2` guarantee

  `test/arbiter/node_agent/k8s/pod_spec_test.exs` has one test per row, each
  asserting the pod field *and*, where the flag exists, the podman flag next to
  it.

  | `Container.argv/2` | pod field |
  |---|---|
  | `--read-only` | `readOnlyRootFilesystem: true` on every container |
  | `--cap-drop=all` | `capabilities.drop: [ALL]`, no `add` |
  | `--security-opt no-new-privileges` | `allowPrivilegeEscalation: false`, `privileged: false`, `procMount: Default` |
  | `--userns=keep-id` | `runAsNonRoot`, uid/gid/fsGroup 10001, `OnRootMismatch`, `hostUsers: false` |
  | podman's default seccomp | `seccompProfile: RuntimeDefault`; **never** an `appArmorProfile` (K1-A2) |
  | `--network=none` | no host network, `dnsPolicy: None`, no service links, no ports; a spec asking for `pasta` is `bad_spec` |
  | the worktree at its own path | `work` `emptyDir` via `subPath: wt` at that path |
  | the `.git` guards | `.git` itself (K1-A8) then the four guards, `readOnly` `subPath` mounts |
  | the objects overlay | not applicable: the clone is self-contained |
  | per-run `HOME`, config dir | `subPath`s of `work` at the primary's paths |
  | `/tmp`, `/dev/shm` | a memory `emptyDir` for `/tmp`; `/dev/shm` at the runtime default |
  | `-e NAME` | never in the spec: a memory file sourced and deleted by the entry wrapper |
  | `-e NAME=value` | `env:` literals |
  | `-v <cli>:…:ro` | an image layer: no mount |
  | `--memory`, `--cpus` | `resources.limits`, `min(spec, config)` |
  | `--pull=never` | `IfNotPresent` with a digest-pinned image |
  | `--init` | `tini` as the entrypoint |
  | `--security-opt label=disable` | not carried over: no `seLinuxOptions`; a spec asking for one is `bad_spec` |

  ## What is refused

  `{:error, {:bad_spec, reason}}` for anything the builder cannot represent or
  must not: `network: pasta` (the pasta network is only the primary's own
  deps-seed job), a `seLinuxOptions`/`spc_t` anywhere in the structure, an unknown
  mount kind or field, a mount over a path the pod owns, an image that is not a
  digest-pinned reference under the configured registry, a name or label value
  Kubernetes would reject, and a reserved environment variable.
  `{:error, {:bad_config, reason}}` for a config outside the closed schema
  (`Arbiter.NodeAgent.K8s.PodConfig`).

  ## Choices worth knowing

    * `hostNetwork`, `hostPID`, `hostIPC` and `shareProcessNamespace` are **omitted**,
      not written as `false`: they default to false, Pod Security `restricted`
      and the admission policy's `!has(object.spec.hostNetwork)` accept the pod either
      way, and absent can never be misread as a request.
    * Every string in `command`, `args` and `env` has `$` doubled: the kubelet
      expands `$(VAR)` and turns `$$` into `$` in those fields, which would
      corrupt a prompt or a shell word that podman passes byte for byte.
    * `memory_swap` has no field (swap is off on the cluster nodes, `[K22]`).
    * `RunSpec` has no image reference yet (design A2): the controller puts the
      digest-pinned `ref` the primary pushed in `spec.image.ref`.
    * `seed` and `snapshotter` take `services_resources`; a quota that counts
      requests needs every container to state some.
  """

  alias Arbiter.NodeAgent.K8s.PodConfig
  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.K8s.Quantity
  alias Arbiter.NodeAgent.RunSpec
  alias Arbiter.Worker.TestServices

  @uid 10_001
  @service_account "arbiter-worker"
  @owner_name "arbiter-controller"
  @ca_configmap "arbiter-ca"
  @seed_root "/arb/work"
  @run_dir "/run/arb"
  @ca_dir "/etc/arb/ca"
  @service_tmpfs_size "256Mi"
  @run_size "64Mi"
  @deadline_slack_s 1800
  @max_command_bytes 524_288

  @dns_re ~r/\A[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?\z/
  @label_value_re ~r/\A([A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?)?\z/
  @label_key_re ~r/\A([a-z0-9]([-a-z0-9.]*[a-z0-9])?\/)?[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?\z/
  @env_re ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/
  @bridge_re ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @digest_ref_re ~r/\A[a-z0-9][a-z0-9.:\/_-]*@sha256:[0-9a-f]{64}\z/
  @memory_re ~r/\A[1-9]\d*[bkmg]?\z/i
  @cpus_re ~r/\A\d+(\.\d+)?\z/

  @mount_kinds ~w(worktree home config_dir tmp cli prompt)
  @mount_fields %{
    "worktree" => [:kind, :path, :files],
    "home" => [:kind, :path],
    "config_dir" => [:kind, :path, :files],
    "tmp" => [:kind, :path],
    "cli" => [:kind, :path, :name, :sha256],
    "prompt" => [:kind, :path, :content]
  }
  @bridge_fields [:name, :path]
  @service_fields [:name, :image, :env, :command, :tmpfs, :ready, :worker_env, :uid]
  @limit_keys [:memory, :memory_swap, :cpus]
  @guards ~w(config hooks commondir objects/info/alternates)

  # Paths the pod owns, and the container-side roots RunSpec already forbids.
  @reserved ["/run/arb", "/etc/arb", "/arb", "/opt/arbiter", "/proc", "/sys", "/dev", "/etc", "/run/arbiter"]
  @reserved_env ~w(ARB_BOOT_NONCE ARB_BRIDGE_ADDR ARB_BRIDGES ARB_GATE_ADDR ARB_GATE_TIMEOUT_S ARB_SNAPSHOT_INTERVAL_S ARB_RUN ARB_WORKTREE)
  @preset_uids %{"postgres" => 70}
  # Fields whose *contents* are data (a prompt may discuss `spc_t`); their keys are still not scanned.
  @data_keys ~w(env secrets command worker_env files content ready)

  @type build_error :: {:bad_spec, term()} | {:bad_config, term()}

  @doc """
  Build the pod for `spec` (a `Arbiter.NodeAgent.RunSpec` or an atom-keyed map of
  the same shape) under `config` (see `Arbiter.NodeAgent.K8s.PodConfig`).
  """
  @spec build(RunSpec.t() | map(), map() | keyword()) :: {:ok, map()} | {:error, build_error()}
  def build(spec, config) do
    with {:ok, spec} <- spec(spec),
         {:ok, cfg} <- PodConfig.normalize(config),
         {:ok, run} <- plan(spec, cfg) do
      {:ok, pod(run, cfg)}
    end
  end

  # -- the spec ----------------------------------------------------------------------------

  defp spec(%RunSpec{} = spec), do: spec(Map.from_struct(spec))

  defp spec(spec) when is_map(spec) do
    spec = Map.drop(spec, [:__struct__])

    with :ok <- no_selinux(spec),
         :ok <- known_fields(spec) do
      {:ok, Map.merge(Map.from_struct(%RunSpec{}), spec)}
    end
  end

  defp spec(_), do: bad_spec(:not_a_map)

  defp known_fields(spec) do
    known = Map.keys(Map.from_struct(%RunSpec{}))

    case Enum.find(Map.keys(spec), &(&1 not in known)) do
      nil -> :ok
      key -> bad_spec({:unknown_field, key})
    end
  end

  # `label=disable` has no equal here (§8.1): the builder never emits SELinux
  # options, and a spec that names one (or `spc_t`) is refused, not ignored.
  defp no_selinux(term), do: scan_selinux(term)

  defp scan_selinux(%{} = map) do
    Enum.reduce_while(map, :ok, fn {key, value}, :ok ->
      name = key |> to_string()

      cond do
        selinux_name?(name) -> {:halt, bad_spec({:selinux_not_allowed, key})}
        name in @data_keys -> {:cont, :ok}
        true -> continue(scan_selinux(value))
      end
    end)
  end

  defp scan_selinux(list) when is_list(list),
    do: Enum.reduce_while(list, :ok, fn item, :ok -> continue(scan_selinux(item)) end)

  defp scan_selinux(tuple) when is_tuple(tuple), do: scan_selinux(Tuple.to_list(tuple))

  defp scan_selinux(value) when is_binary(value) or is_atom(value) do
    text = value |> to_string() |> String.downcase()

    if selinux_name?(text) or String.contains?(text, "spc_t"),
      do: bad_spec({:selinux_not_allowed, value}),
      else: :ok
  end

  defp scan_selinux(_), do: :ok

  defp continue(:ok), do: {:cont, :ok}
  defp continue(error), do: {:halt, error}

  defp selinux_name?(name) do
    name |> String.downcase() |> String.replace(["_", "-"], "") |> String.contains?("selinux")
  end

  # -- plan: validate every part, collect what the pod needs ------------------------------------

  defp plan(spec, cfg) do
    with {:ok, name} <- name(spec.name),
         {:ok, labels} <- labels(spec, cfg),
         {:ok, image} <- image(spec.image, cfg),
         :ok <- network(spec.network),
         {:ok, cwd} <- path(spec.cwd),
         {:ok, mounts} <- mounts(spec.mounts),
         {:ok, bridges} <- bridges(spec.bridges),
         {:ok, env} <- env(spec.env),
         {:ok, limits} <- limits(spec.limits),
         {:ok, services} <- services(spec.services, cfg),
         {:ok, command} <- command(spec.command),
         {:ok, interval} <- interval(spec.checkout, cfg) do
      {:ok,
       %{
         name: name,
         labels: labels,
         image: image,
         cwd: cwd,
         mounts: mounts,
         bridges: bridges,
         env: env,
         limits: limits,
         services: services,
         command: command,
         run: spec.run,
         interval: interval
       }}
    end
  end

  defp name(name) when is_binary(name) do
    if byte_size(name) <= 63 and Regex.match?(@dns_re, name),
      do: {:ok, name},
      else: bad_spec({:bad_name, name})
  end

  defp name(other), do: bad_spec({:bad_name, other})

  defp labels(spec, cfg) do
    with :ok <- install(spec.install, cfg),
         {:ok, run} <- label_value("arbiter.dev/run", spec.run),
         {:ok, task} <- optional_label("arbiter.dev/task", spec.task),
         {:ok, extra} <- extra_labels(spec.labels) do
      controller =
        %{
          "app.kubernetes.io/name" => "arbiter-worker",
          "app.kubernetes.io/component" => "worker",
          "arbiter.dev/install" => cfg.install_id,
          "arbiter.dev/node" => cfg.node_id,
          "arbiter.dev/run" => run
        }
        |> then(&if(task, do: Map.put(&1, "arbiter.dev/task", task), else: &1))

      {:ok, Map.merge(extra, controller)}
    end
  end

  # The run belongs to one install; a spec naming another is not ours to start.
  defp install(nil, _cfg), do: :ok
  defp install(id, %{install_id: id}), do: :ok
  defp install(id, _cfg), do: bad_spec({:install_mismatch, id})

  defp label_value(key, value) when is_binary(value) and byte_size(value) in 1..63 do
    if Regex.match?(@label_value_re, value), do: {:ok, value}, else: bad_spec({:bad_label, key})
  end

  defp label_value(key, _), do: bad_spec({:bad_label, key})

  defp optional_label(_key, nil), do: {:ok, nil}
  defp optional_label(key, value), do: label_value(key, value)

  defp extra_labels(labels) when is_map(labels) do
    Enum.reduce_while(labels, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      key = to_string(k)

      if is_binary(v) and byte_size(key) <= 253 and Regex.match?(@label_key_re, key) and
           byte_size(v) <= 63 and Regex.match?(@label_value_re, v),
         do: {:cont, {:ok, Map.put(acc, key, v)}},
         else: {:halt, bad_spec({:bad_label, key})}
    end)
  end

  defp extra_labels(_), do: bad_spec({:bad_value, :labels})

  defp image(%{ref: ref}, cfg) when is_binary(ref) do
    if Regex.match?(@digest_ref_re, ref) and String.starts_with?(ref, cfg.registry <> "/"),
      do: {:ok, ref},
      else: bad_spec({:bad_image, ref})
  end

  defp image(%{}, _cfg), do: bad_spec({:missing, "image.ref"})
  defp image(_, _cfg), do: bad_spec({:missing, "image"})

  defp network(nil), do: :ok
  defp network(:none), do: :ok
  defp network("none"), do: :ok
  defp network(other), do: bad_spec({:network_not_supported, other})

  # -- paths and mounts -------------------------------------------------------------------------

  defp path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") -> bad_spec({:bad_path, path})
      String.contains?(path, [":", ",", "\0", "\n", "\r"]) -> bad_spec({:bad_path, path})
      Path.expand(path) != path or path == "/" -> bad_spec({:bad_path, path})
      ".." in Path.split(path) -> bad_spec({:bad_path, path})
      true -> {:ok, path}
    end
  end

  defp path(other), do: bad_spec({:bad_path, other})

  defp reserved?(path), do: Enum.any?(@reserved, &under?(path, &1))
  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp mounts(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn mount, {:ok, acc} ->
      case mount(mount) do
        {:ok, m} -> {:cont, {:ok, [m | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> acc |> Enum.reverse() |> check_mounts()
      error -> error
    end
  end

  defp mounts(_), do: bad_spec({:bad_value, :mounts})

  defp mount(%{kind: kind} = mount) when kind in @mount_kinds do
    case Enum.find(Map.keys(mount), &(&1 not in Map.fetch!(@mount_fields, kind))) do
      nil ->
        with {:ok, path} <- path(mount[:path]), do: reserved(kind, %{kind: kind, path: path})

      key ->
        bad_spec({:unknown_mount_field, key})
    end
  end

  defp mount(%{kind: kind}), do: bad_spec({:unknown_mount_kind, kind})
  defp mount(%{} = mount), do: bad_spec({:unknown_mount_kind, Map.get(mount, :kind)})
  defp mount(_), do: bad_spec({:bad_value, :mounts})

  # The image's own CLI directory is not something a mount can land on.
  defp reserved("cli", mount), do: {:ok, mount}
  defp reserved(_kind, %{path: path} = mount), do: if(reserved?(path), do: bad_spec({:reserved_path, path}), else: {:ok, mount})

  defp check_mounts(mounts) do
    worktrees = for %{kind: "worktree"} = m <- mounts, do: m.path

    with {:ok, wt} <- one(worktrees, "worktree"),
         :ok <- at_most_one(mounts, "home"),
         :ok <- at_most_one(mounts, "config_dir"),
         :ok <- clear_of_git(mounts, wt),
         :ok <- unique_paths(mounts) do
      {:ok, mounts}
    end
  end

  defp one([], kind), do: bad_spec({:missing_mount, kind})
  defp one([path], _kind), do: {:ok, path}
  defp one(_many, kind), do: bad_spec({:duplicate_mount, kind})

  defp at_most_one(mounts, kind) do
    if Enum.count(mounts, &(&1.kind == kind)) <= 1, do: :ok, else: bad_spec({:duplicate_mount, kind})
  end

  # Nothing else may be mounted at or below `<worktree>/.git`: the builder owns that tree.
  defp clear_of_git(mounts, wt) do
    case Enum.find(mounts, &(&1.kind != "worktree" and &1.kind != "cli" and under?(&1.path, wt <> "/.git"))) do
      nil -> :ok
      %{path: path} -> bad_spec({:reserved_path, path})
    end
  end

  defp unique_paths(mounts) do
    paths = for %{kind: k, path: p} <- mounts, k != "cli", k != "tmp" or p != "/tmp", do: p

    case paths -- Enum.uniq(paths) do
      [] -> :ok
      [dup | _] -> bad_spec({:duplicate_mount_path, dup})
    end
  end

  # -- bridges, env, limits, services, command --------------------------------------------------

  defp bridges(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn
      %{name: name} = bridge, {:ok, acc} when is_binary(name) ->
        with :ok <- known_keys(bridge, @bridge_fields, :unknown_bridge_field),
             true <- Regex.match?(@bridge_re, name) or {:bad_value, "bridges.name"} do
          {:cont, {:ok, [name | acc]}}
        else
          {:bad_value, _} = reason -> {:halt, bad_spec(reason)}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, bad_spec({:bad_value, :bridges})}
    end)
    |> case do
      {:ok, names} -> unique_names(Enum.reverse(names))
      error -> error
    end
  end

  defp bridges(_), do: bad_spec({:bad_value, :bridges})

  defp unique_names(names) do
    case names -- Enum.uniq(names) do
      [] -> {:ok, names}
      [dup | _] -> bad_spec({:duplicate_bridge, dup})
    end
  end

  defp known_keys(map, allowed, tag) do
    case Enum.find(Map.keys(map), &(&1 not in allowed)) do
      nil -> :ok
      key -> bad_spec({tag, key})
    end
  end

  defp env(env) when is_map(env) do
    Enum.reduce_while(env, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      cond do
        not (is_binary(k) and Regex.match?(@env_re, k) and is_binary(v) and not String.contains?(v, "\0")) ->
          {:halt, bad_spec({:bad_env, k})}

        k in @reserved_env ->
          {:halt, bad_spec({:reserved_env, k})}

        true ->
          {:cont, {:ok, Map.put(acc, k, v)}}
      end
    end)
  end

  defp env(_), do: bad_spec({:bad_value, :env})

  defp limits(limits) when is_map(limits) do
    Enum.reduce_while(limits, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      value = to_string(value)

      cond do
        key not in @limit_keys -> {:halt, bad_spec({:unknown_limit, key})}
        valid_limit?(key, value) -> {:cont, {:ok, Map.put(acc, key, value)}}
        true -> {:halt, bad_spec({:bad_limit, key})}
      end
    end)
  end

  defp limits(_), do: bad_spec({:bad_value, :limits})

  defp valid_limit?(:cpus, value), do: Regex.match?(@cpus_re, value) and match?({:ok, _}, Quantity.cpu(value, :podman))
  defp valid_limit?(_memory, value), do: Regex.match?(@memory_re, value)

  defp command([exe | _] = argv) when is_binary(exe) do
    cond do
      not Enum.all?(argv, &(is_binary(&1) and not String.contains?(&1, "\0"))) -> bad_spec({:bad_value, :command})
      argv |> Enum.map(&byte_size/1) |> Enum.sum() > @max_command_bytes -> bad_spec({:too_large, :command})
      true -> {:ok, argv}
    end
  end

  defp command(_), do: bad_spec({:missing, "command"})

  defp interval(nil, cfg), do: {:ok, cfg.snapshot_interval_s}
  defp interval(%{interval_ms: ms}, _cfg) when is_integer(ms) and ms >= 10_000, do: {:ok, div(ms, 1000)}
  defp interval(_, _cfg), do: bad_spec({:bad_value, "checkout.interval_s"})

  defp services([], _cfg), do: {:ok, []}

  defp services(list, cfg) when is_list(list) do
    with :ok <- service_fields(list),
         {:ok, resolved} <- resolve(list),
         {:ok, resolved} <- service_uids(resolved),
         :ok <- service_images(resolved, cfg) do
      {:ok, resolved}
    end
  end

  defp services(_, _cfg), do: bad_spec({:bad_value, :services})

  defp service_fields(list) do
    Enum.reduce_while(list, :ok, fn
      %{} = service, :ok ->
        case known_keys(service, @service_fields, :unknown_service_field) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end

      _preset, :ok ->
        {:cont, :ok}
    end)
  end

  defp resolve(list) do
    case TestServices.resolve(list) do
      {:ok, services} -> {:ok, services}
      {:error, reason} -> bad_spec({:bad_services, reason})
    end
  end

  defp service_uids(services) do
    Enum.reduce_while(services, {:ok, []}, fn service, {:ok, acc} ->
      uid = Map.get(service, :uid) || Map.get(@preset_uids, service.name)

      cond do
        uid == nil -> {:cont, {:ok, acc ++ [Map.put(service, :uid, nil)]}}
        is_integer(uid) and uid in 1..65_535 -> {:cont, {:ok, acc ++ [Map.put(service, :uid, uid)]}}
        true -> {:halt, bad_spec({:bad_service_uid, uid})}
      end
    end)
  end

  defp service_images(services, cfg) do
    prefixes = ["docker.io/library/", cfg.registry <> "/" | cfg.service_image_allowlist]

    case Enum.find(services, fn s -> not Enum.any?(prefixes, &String.starts_with?(s.image, &1)) end) do
      nil -> :ok
      service -> bad_spec({:service_image_not_allowed, service.image})
    end
  end

  # -- the pod ----------------------------------------------------------------------------------------

  defp pod(run, cfg) do
    %{
      "apiVersion" => "v1",
      "kind" => "Pod",
      "metadata" => %{
        "name" => run.name,
        "namespace" => cfg.namespace,
        "labels" => run.labels,
        "ownerReferences" => [
          %{"apiVersion" => "apps/v1", "kind" => "Deployment", "name" => @owner_name, "uid" => cfg.owner_uid}
        ]
      },
      "spec" =>
        %{
          "restartPolicy" => "Never",
          "activeDeadlineSeconds" => cfg.max_wall_s + @deadline_slack_s,
          "terminationGracePeriodSeconds" => cfg.timeouts["grace_s"],
          "serviceAccountName" => @service_account,
          "automountServiceAccountToken" => false,
          "enableServiceLinks" => false,
          "hostUsers" => false,
          "dnsPolicy" => "None",
          "dnsConfig" => %{"nameservers" => ["127.0.0.1"]},
          "priorityClassName" => cfg.placement["priority_class"],
          "securityContext" => %{
            "runAsNonRoot" => true,
            "runAsUser" => @uid,
            "runAsGroup" => @uid,
            "fsGroup" => @uid,
            "fsGroupChangePolicy" => "OnRootMismatch",
            "seccompProfile" => %{"type" => "RuntimeDefault"}
          },
          "initContainers" => init_containers(run, cfg),
          "containers" => [worker(run, cfg)],
          "volumes" => volumes(run, cfg)
        }
        |> put_unless_empty("imagePullSecrets", Enum.map(cfg.image_pull_secrets, &%{"name" => &1}))
        |> put_unless_empty("nodeSelector", cfg.placement["node_selector"])
        |> put_unless_empty("tolerations", cfg.placement["tolerations"])
        |> put_unless_empty("runtimeClassName", cfg.placement["runtime_class"])
    }
  end

  defp put_unless_empty(map, _key, value) when value in [[], %{}, "", nil], do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  # The init pass is sequential (§8.2): seed → services → snapshotter, then the worker.
  defp init_containers(run, cfg) do
    [seed(run, cfg)] ++ Enum.map(run.services, &service(&1, run, cfg)) ++ [snapshotter(run, cfg)]
  end

  defp hardening(uid \\ nil) do
    %{
      "allowPrivilegeEscalation" => false,
      "privileged" => false,
      "procMount" => "Default",
      "readOnlyRootFilesystem" => true,
      "capabilities" => %{"drop" => ["ALL"]}
    }
    |> then(&if(uid, do: Map.merge(&1, %{"runAsUser" => uid, "runAsGroup" => uid}), else: &1))
  end

  defp seed(run, cfg) do
    %{
      "name" => "seed",
      "image" => run.image,
      "imagePullPolicy" => "IfNotPresent",
      "command" => ["sh", "-c", PodScripts.seed()] |> escape(),
      "env" =>
        env_list(
          %{
            "ARB_BOOT_NONCE" => cfg.boot_nonce,
            "ARB_BRIDGE_ADDR" => cfg.bridge_addr,
            "ARB_GATE_ADDR" => cfg.gate_addr,
            "ARB_GATE_TIMEOUT_S" => Integer.to_string(cfg.timeouts["gate_timeout_s"]),
            "ARB_RUN" => run.run,
            "ARB_WORKTREE" => worktree(run),
            "HOME" => "/tmp"
          }
          |> then(&if(path = mount_path(run, "home"), do: Map.put(&1, "ARB_HOME", path), else: &1))
          |> then(&if(path = mount_path(run, "config_dir"), do: Map.put(&1, "ARB_CONFIG_DIR", path), else: &1))
          |> Map.put("ARB_WORK_ROOT", @seed_root)
        ),
      "securityContext" => hardening(),
      "resources" => aux_resources(cfg),
      "volumeMounts" => [
        %{"name" => "work", "mountPath" => @seed_root},
        %{"name" => "tmp", "mountPath" => "/tmp"},
        %{"name" => "run", "mountPath" => @run_dir},
        %{"name" => "ca", "mountPath" => @ca_dir, "readOnly" => true}
      ]
    }
  end

  defp snapshotter(run, cfg) do
    %{
      "name" => "snapshotter",
      "image" => run.image,
      "imagePullPolicy" => "IfNotPresent",
      "restartPolicy" => "Always",
      "command" => escape(["tini", "--", "/opt/arbiter/bin/snapshotter"]),
      "env" =>
        env_list(%{
          "ARB_BRIDGE_ADDR" => cfg.bridge_addr,
          "ARB_RUN" => run.run,
          "ARB_WORKTREE" => worktree(run),
          "ARB_SNAPSHOT_INTERVAL_S" => Integer.to_string(run.interval),
          "HOME" => mount_path(run, "home") || "/tmp"
        }),
      "securityContext" => hardening(),
      "resources" => aux_resources(cfg),
      "volumeMounts" =>
        work_mounts(run, prompts?: false) ++
          [
            %{"name" => "tmp", "mountPath" => "/tmp"},
            %{"name" => "run", "mountPath" => @run_dir},
            %{"name" => "ca", "mountPath" => @ca_dir, "readOnly" => true}
          ]
    }
  end

  defp worker(run, cfg) do
    %{
      "name" => "worker",
      "image" => run.image,
      "imagePullPolicy" => "IfNotPresent",
      "command" => escape(["tini", "--", "sh", "-c", PodScripts.entry(), "sh" | run.command]),
      "workingDir" => run.cwd,
      "env" => env_list(worker_env(run, cfg)),
      "securityContext" => hardening(),
      "resources" => worker_resources(run, cfg),
      "volumeMounts" =>
        sort_mounts(
          work_mounts(run, prompts?: true) ++
            [
              %{"name" => "tmp", "mountPath" => "/tmp"},
              %{"name" => "run", "mountPath" => @run_dir},
              %{"name" => "ca", "mountPath" => @ca_dir, "readOnly" => true}
            ]
        )
    }
  end

  defp worker_env(run, cfg) do
    service_env = for s <- run.services, {k, v} <- s.worker_env, into: %{}, do: {k, v}

    run.env
    |> Map.merge(service_env)
    |> Map.put("ARB_BRIDGE_ADDR", cfg.bridge_addr)
    |> Map.put("ARB_BRIDGES", Enum.join(run.bridges, " "))
    |> then(&if(path = mount_path(run, "home"), do: Map.put(&1, "HOME", path), else: &1))
  end

  # Sorted by name: the same spec always renders the same bytes.
  defp env_list(env) do
    env |> Enum.sort() |> Enum.map(fn {k, v} -> %{"name" => k, "value" => escape(v)} end)
  end

  # The kubelet expands `$(VAR)` and `$$` in command, args and env values. Doubling
  # every `$` makes each string reach the process byte for byte, as podman's argv does.
  defp escape(strings) when is_list(strings), do: Enum.map(strings, &escape/1)
  defp escape(string) when is_binary(string), do: String.replace(string, "$", "$$")

  defp worktree(run), do: mount_path(run, "worktree")

  defp mount_path(run, kind) do
    case Enum.find(run.mounts, &(&1.kind == kind)) do
      nil -> nil
      %{path: path} -> path
    end
  end

  # The worktree, `.git` itself (K1-A8: a mount point cannot be renamed away, its
  # parent can), then the four guards read-only; HOME and the config dir; prompt
  # files seed wrote into `run`. The seed script creates every source first.
  defp work_mounts(run, prompts?: prompts?) do
    wt = worktree(run)

    tree =
      [
        %{"name" => "work", "mountPath" => wt, "subPath" => "wt"},
        %{"name" => "work", "mountPath" => wt <> "/.git", "subPath" => "wt/.git"}
      ] ++
        for guard <- @guards do
          %{"name" => "work", "mountPath" => "#{wt}/.git/#{guard}", "subPath" => "wt/.git/#{guard}", "readOnly" => true}
        end

    dirs =
      for %{kind: kind, path: path} <- run.mounts, kind in ["home", "config_dir"] do
        %{"name" => "work", "mountPath" => path, "subPath" => if(kind == "home", do: "home", else: "claude-config")}
      end

    extra_tmp =
      for {%{path: path}, i} <- run.mounts |> Enum.filter(&(&1.kind == "tmp" and &1.path != "/tmp")) |> Enum.with_index() do
        %{"name" => "tmp", "mountPath" => path, "subPath" => "tmp-#{i}"}
      end

    prompt =
      if prompts? do
        for {%{path: path}, i} <- run.mounts |> Enum.filter(&(&1.kind == "prompt")) |> Enum.with_index() do
          %{"name" => "run", "mountPath" => path, "subPath" => "prompt-#{i}", "readOnly" => true}
        end
      else
        []
      end

    tree ++ dirs ++ extra_tmp ++ prompt
  end

  # A parent is mounted before its children whatever the spec's order: depth first, stable.
  defp sort_mounts(mounts) do
    mounts
    |> Enum.with_index()
    |> Enum.sort_by(fn {m, i} -> {length(Path.split(m["mountPath"])), i} end)
    |> Enum.map(&elem(&1, 0))
  end

  # -- resources ---------------------------------------------------------------------------------------

  defp worker_resources(run, cfg) do
    limits = cfg.worker["limits"]
    requests = cfg.worker["requests"]

    memory = min_quantity(limits["memory"], run.limits[:memory], &Quantity.memory/2, &Quantity.format_memory/1)
    cpu = min_quantity(limits["cpu"], run.limits[:cpus], &Quantity.cpu/2, &Quantity.format_cpu/1)

    limits = limits |> put_unless_nil("memory", memory) |> put_unless_nil("cpu", cpu)

    %{
      "requests" =>
        requests
        |> clamp("memory", limits, &Quantity.memory/2, &Quantity.format_memory/1)
        |> clamp("cpu", limits, &Quantity.cpu/2, &Quantity.format_cpu/1),
      "limits" => limits
    }
  end

  defp aux_resources(cfg), do: cfg.services_resources

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  # `min(spec, config)`: the in-cluster config is authoritative. The config's own
  # string is kept when it wins, so an operator's `4Gi` stays `4Gi`.
  defp min_quantity(config, nil, _parse, _format), do: config
  defp min_quantity(nil, spec, parse, format), do: spec |> parse_podman(parse) |> format.()

  defp min_quantity(config, spec, parse, format) do
    {:ok, from_config} = parse.(config, :k8s)
    from_spec = parse_podman(spec, parse)
    if from_spec < from_config, do: format.(from_spec), else: config
  end

  defp parse_podman(value, parse) do
    {:ok, n} = parse.(value, :podman)
    n
  end

  # Kubernetes refuses a request above its limit.
  defp clamp(requests, key, limits, parse, format) do
    with %{^key => request} <- requests,
         %{^key => limit} <- limits,
         {:ok, r} <- parse.(request, :k8s),
         {:ok, l} <- parse.(limit, :k8s),
         true <- r > l do
      Map.put(requests, key, format.(l))
    else
      _ -> requests
    end
  end

  # -- services (§6) ---------------------------------------------------------------------------------------

  defp service(service, _run, cfg) do
    mounts = service_mounts(service)

    %{
      "name" => "svc-" <> service.name,
      "image" => service.image,
      "imagePullPolicy" => "IfNotPresent",
      "restartPolicy" => "Always",
      "securityContext" => hardening(service.uid),
      "resources" => cfg.services_resources
    }
    # K1-A9: a preset's `command` is what podman appends to the image's entrypoint,
    # so it is Kubernetes `args`; `command:` would replace the entrypoint.
    |> put_unless_empty("args", escape(service.command))
    |> put_unless_empty("env", Enum.map(service.env, fn {k, v} -> %{"name" => k, "value" => escape(v)} end))
    |> put_unless_empty("startupProbe", startup_probe(service.ready))
    |> put_unless_empty("volumeMounts", Enum.map(mounts, fn {vol, path} -> %{"name" => vol, "mountPath" => path} end))
  end

  defp startup_probe(nil), do: nil

  defp startup_probe(ready),
    do: %{"exec" => %{"command" => ready}, "periodSeconds" => 1, "failureThreshold" => 120}

  # Each tmpfs entry (`"/path:rw,nosuid…"`) is a memory `emptyDir` at that path.
  defp service_paths(service) do
    for entry <- service.tmpfs, do: entry |> String.split(":", parts: 2) |> hd()
  end

  defp service_mounts(service) do
    service
    |> service_paths()
    |> Enum.with_index()
    |> Enum.map(fn {path, i} -> {service_volume(service, i), path} end)
  end

  defp service_volume(service, i), do: "svc-#{service.name}-#{i}"

  # -- volumes -----------------------------------------------------------------------------------------------

  defp volumes(run, cfg) do
    [
      %{"name" => "work", "emptyDir" => %{"sizeLimit" => cfg.worker["work_size_limit"]}},
      %{"name" => "tmp", "emptyDir" => %{"medium" => "Memory", "sizeLimit" => cfg.worker["tmp_size_limit"]}},
      %{"name" => "run", "emptyDir" => %{"medium" => "Memory", "sizeLimit" => @run_size}},
      %{"name" => "ca", "configMap" => %{"name" => @ca_configmap}}
    ] ++
      for service <- run.services,
          {{volume, _path}, _i} <- Enum.with_index(service_mounts(service)) do
        %{"name" => volume, "emptyDir" => %{"medium" => "Memory", "sizeLimit" => @service_tmpfs_size}}
      end
  end

  defp bad_spec(reason), do: {:error, {:bad_spec, reason}}
end
