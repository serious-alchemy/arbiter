defmodule Arbiter.NodeAgent.K8s.Canary do
  @moduledoc """
  The NetworkPolicy canary (`docs/design/remote-workers.md` k8s §9.4, ticket K13).

  `--network=none` has no Kubernetes equal: a pod always has `eth0`, and the
  guarantee that a worker can reach only the controller's bridge ports is "the CNI
  enforces the NetworkPolicies of the bootstrap manifest". A CNI that does not
  enforce them (flannel without a policy controller, a kube-router that is off, a
  kernel without the modules) accepts the policies and silently ignores them. So
  the controller does not assume: it **proves** it with a short-lived pod.

  ## The pod

  `pod/2` builds it with `Arbiter.NodeAgent.K8s.PodSpec`, the worker's own builder,
  so the pod has the worker's labels (`app.kubernetes.io/component: worker`: the
  selector every real policy uses), service account, security context, owner
  reference, priority class and node placement, and passes the same Pod Security
  `restricted` checker. Then only what a canary must differ in is changed:

    * **no run label** (`arbiter.dev/canary: <id>` instead): the controller's
      adoption and the sweeper key on `arbiter.dev/run`, so the canary is never
      adopted as a run, never counted against capacity, never reaped by a `reap`;
    * the `seed` init container runs `PodScripts.gate/0` only (K1-A3): a fresh pod
      is unfiltered for a fraction of a second until the CNI programs it, so the
      probes that follow measure the steady state. A gate that never closes exits
      70, which is the verdict `unenforced` on its own;
    * the `worker` container runs `script/0` instead of the entry wrapper (there is
      no seed to write `/run/arb/env`) and without `tini`, so the image needs only `sh`
      and `socat`; it asks for small resources; the snapshotter is dropped and the
      `work`/`.git` mounts with it.

  ## The probes

  The script tries six TCP connects with a 1-s timeout each (denied traffic is
  answered with an immediate reject, not a timeout): five **must fail**, one **must
  connect**.

  | probe | target | expected |
  |---|---|---|
  | `api` | the `kubernetes` Service address (the gate's own) | closed |
  | `controller_port` | the controller pod on a port that is not a bridge port | closed |
  | `foreign` | a Service/pod in another namespace (the cluster DNS Service) | closed |
  | `internet` | `1.1.1.1:443` | closed |
  | `node` | the node's own address (the kubelet port) | closed |
  | `bridge` | the controller Service on `9443` | open |

  `controller_port` needs something to listen there, or "closed" would prove
  nothing: `Arbiter.NodeAgent.K8s.ReadinessMonitor` opens a listener on it.
  `foreign` and `node` depend on what the controller could learn about its cluster
  (`targets_from_env/1`); a target it could not name is `skipped`, listed in the
  result, and never guessed. `api` and `internet` are always known, so a log that
  lacks them proves nothing.

  ## The verdict (fail closed)

  `verdict/1` over the parsed log: any probe that **connected** among the five is
  `{:unenforced, [names]}`; all five closed with the done marker is `{:enforced,
  info}`; everything else (a truncated log, missing mandatory probes) is
  `{:inconclusive, reason}`, never "enforced". A closed `bridge` probe does not
  change the policy verdict but is reported (`bridge: :closed`): the policies are
  too strict, or the controller's listeners are not up.

  `run/3` creates the pod, waits (polling `get_pod`), reads the worker's log and
  **always** deletes the pod. Its result:

      %{outcome: :enforced | :unenforced | :inconclusive,
        open: [probe], skipped: [probe], bridge: :open | :closed | nil,
        reason: term | nil, pull: :ok | {:failed, message} | :unknown}

  `pull` is the registry-pull readiness check: the canary's image is the worker
  image, so a pod that reached `Succeeded`/`Failed` pulled it, and an
  `ImagePullBackOff` is the failure with the kubelet's message.
  """

  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.PodScripts
  alias Arbiter.NodeAgent.K8s.PodSpec
  alias Arbiter.NodeAgent.RunSpec

  @bridge_port 9443
  @gate_exit 70
  @mandatory ~w(api internet)
  @forbidden ~w(api controller_port foreign internet node)
  @pull_failures ~w(ErrImagePull ImagePullBackOff InvalidImageName ErrImageNeverPull)
  @default_timeout_ms 120_000
  @default_poll_ms 1_000
  @deadline_s 240

  @script ~S"""
  set -u
  probe() {
    if [ -z "$2" ]; then echo "probe $1 skipped"; return; fi
    host=${2%:*}
    port=${2##*:}
    if socat -T1 /dev/null "TCP:${host}:${port},connect-timeout=1" >/dev/null 2>&1; then
      echo "probe $1 open"
    else
      echo "probe $1 closed"
    fi
  }
  probe api "$ARB_CANARY_API_ADDR"
  probe controller_port "$ARB_CANARY_CONTROLLER_PORT_ADDR"
  probe foreign "$ARB_CANARY_FOREIGN_ADDR"
  probe internet 1.1.1.1:443
  probe node "$ARB_CANARY_NODE_ADDR"
  probe bridge "$ARB_CANARY_BRIDGE_ADDR"
  echo "canary done"
  """

  @type result :: %{
          outcome: :enforced | :unenforced | :inconclusive,
          open: [String.t()],
          skipped: [String.t()],
          bridge: :open | :closed | nil,
          reason: term() | nil,
          pull: :ok | {:failed, String.t()} | :unknown
        }

  @doc "The probe script the `worker` container runs (`sh -c`)."
  @spec script() :: String.t()
  def script, do: @script

  @doc """
  The probe targets this controller can learn from its own pod, as the controller
  manifest wires them (`ARB_POD_IP`, `ARB_NODE_IP` from the downward API,
  `KUBERNETES_SERVICE_HOST`/`PORT`) and `/etc/resolv.conf` (the cluster DNS Service
  is a Service in another namespace). `:canary_port` is the port the monitor
  listens on. Options: `:env`, `:resolv_conf` (a path), `:canary_port`, `:node_port`
  (the kubelet's, default 10250).
  """
  @spec targets_from_env(keyword()) :: map()
  def targets_from_env(opts \\ []) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    port = Keyword.get(opts, :canary_port, 9445)
    node_port = Keyword.get(opts, :node_port, 10_250)

    %{
      api: api_addr(env),
      controller_port: addr(env["ARB_POD_IP"], port),
      foreign: dns_addr(Keyword.get(opts, :resolv_conf, "/etc/resolv.conf")),
      node: addr(env["ARB_NODE_IP"], node_port)
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp api_addr(env) do
    addr(env["KUBERNETES_SERVICE_HOST"], env["KUBERNETES_SERVICE_PORT"] || "443")
  end

  defp addr(host, port) when is_binary(host) and host != "", do: "#{host}:#{port}"
  defp addr(_host, _port), do: nil

  defp dns_addr(path) do
    with {:ok, text} <- File.read(path),
         [_, ip] <- Regex.run(~r/^nameserver\s+(\d{1,3}(?:\.\d{1,3}){3})\s*$/m, text) do
      "#{ip}:53"
    else
      _ -> nil
    end
  end

  @doc """
  The canary pod for `config` (a `PodSpec` config). Options: `:image` (a digest-pinned
  reference under `config.registry`, required), `:targets` (see `targets_from_env/1`),
  `:id` (default random).
  """
  @spec pod(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def pod(config, opts) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)
    targets = Keyword.get(opts, :targets, %{})

    with {:ok, pod} <- PodSpec.build(spec(id, opts), config) do
      {:ok, shape(pod, id, targets, bridge_addr(config), config)}
    end
  end

  @doc """
  The worker pod exactly as the builder emits it (same options as `pod/2`), unshaped:
  what `Arbiter.NodeAgent.K8s.Readiness` sends in its server-side dry runs.
  """
  @spec dry_run_pod(map() | keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def dry_run_pod(config, opts) do
    PodSpec.build(spec(Keyword.get_lazy(opts, :id, &new_id/0), opts), config)
  end

  defp new_id, do: :crypto.strong_rand_bytes(5) |> Base.encode16(case: :lower)

  defp spec(id, opts) do
    %{
      run: "canary-" <> id,
      name: "arb-canary-" <> id,
      image: %{tag: "canary", plan: nil, ref: Keyword.get(opts, :image)},
      cwd: "/home/arbiter/worktrees/canary",
      mounts: [%{kind: "worktree", path: "/home/arbiter/worktrees/canary"}],
      command: ["sh", "-c", "true"],
      env: %{},
      limits: %{}
    }
    |> then(&Map.merge(Map.from_struct(%RunSpec{}), &1))
  end

  defp bridge_addr(config) do
    addr = config[:bridge_addr] || ""
    if String.contains?(addr, ":"), do: addr, else: "#{addr}:#{@bridge_port}"
  end

  defp shape(pod, id, targets, bridge, _config) do
    pod
    |> update_in(["metadata", "labels"], fn labels ->
      labels
      |> Map.drop(["arbiter.dev/run", "arbiter.dev/task"])
      |> Map.put("arbiter.dev/canary", id)
    end)
    |> update_in(["spec"], fn spec ->
      spec
      |> Map.put("activeDeadlineSeconds", @deadline_s)
      |> Map.put("initContainers", gate_only(spec["initContainers"]))
      |> Map.put(
        "containers",
        Enum.map(spec["containers"], &probe_container(&1, targets, bridge))
      )
    end)
  end

  defp gate_only(init_containers) do
    for %{"name" => "seed"} = seed <- init_containers do
      Map.put(seed, "command", escape(["sh", "-c", PodScripts.gate()]))
    end
  end

  defp probe_container(%{"name" => "worker"} = worker, targets, bridge) do
    env =
      [
        {"ARB_CANARY_API_ADDR", targets[:api]},
        {"ARB_CANARY_CONTROLLER_PORT_ADDR", targets[:controller_port]},
        {"ARB_CANARY_FOREIGN_ADDR", targets[:foreign]},
        {"ARB_CANARY_NODE_ADDR", targets[:node]},
        {"ARB_CANARY_BRIDGE_ADDR", bridge}
      ]
      |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value || ""} end)

    worker
    |> Map.put("command", escape(["sh", "-c", @script]))
    |> Map.put("env", env)
    |> Map.put("resources", %{
      "requests" => %{"cpu" => "50m", "memory" => "32Mi"},
      "limits" => %{"memory" => "64Mi"}
    })
    |> Map.update!("volumeMounts", fn mounts ->
      Enum.filter(
        mounts,
        &(&1["name"] in ["tmp", "run", "ca"] and not Map.has_key?(&1, "subPath"))
      )
    end)
    |> Map.delete("workingDir")
  end

  # The kubelet expands `$(VAR)` and turns `$$` into `$` in command and args.
  defp escape(strings), do: Enum.map(strings, &String.replace(&1, "$", "$$"))

  # -- reading the log --------------------------------------------------------------------

  @doc "The probe lines of a canary log: `%{probes: %{name => :open | :closed | :skipped}, done?: bool}`."
  @spec parse(String.t()) :: %{probes: map(), done?: boolean()}
  def parse(log) when is_binary(log) do
    lines = String.split(log, "\n", trim: true)

    probes =
      for line <- lines,
          [_, name, state] <- [Regex.run(~r/\Aprobe (\w+) (open|closed|skipped)\s*\z/, line)],
          into: %{},
          do: {name, String.to_existing_atom(state)}

    %{probes: probes, done?: Enum.any?(lines, &(String.trim(&1) == "canary done"))}
  end

  @doc """
  The verdict over `parse/1`: `{:unenforced, open}` as soon as any forbidden probe
  connected (also from a truncated log), `{:enforced, %{bridge:, skipped:}}` when all
  five stayed closed and the log is complete, else `{:inconclusive, reason}`.
  """
  @spec verdict(%{probes: map(), done?: boolean()}) ::
          {:enforced, %{bridge: :open | :closed | nil, skipped: [String.t()]}}
          | {:unenforced, [String.t()]}
          | {:inconclusive, term()}
  def verdict(%{probes: probes, done?: done?}) do
    open = Enum.filter(@forbidden, &(probes[&1] == :open))
    missing = Enum.reject(@mandatory, &(probes[&1] == :closed))

    cond do
      open != [] -> {:unenforced, open}
      not done? and probes == %{} -> {:inconclusive, :no_output}
      not done? -> {:inconclusive, :log_truncated}
      missing != [] -> {:inconclusive, {:missing_probes, missing}}
      true -> {:enforced, %{bridge: probes["bridge"], skipped: skipped(probes)}}
    end
  end

  defp skipped(probes), do: for(n <- @forbidden, probes[n] == :skipped, do: n)

  # -- running it -------------------------------------------------------------------------

  @doc """
  Create the canary, wait for it, judge it, delete it. Options as `pod/2` plus
  `:timeout_ms` (default 120 s) and `:poll_ms` (default 1 s). Never raises on an API
  failure; the pod is deleted whatever happens.
  """
  @spec run(Client.t(), map() | keyword(), keyword()) :: result()
  def run(client, config, opts) do
    case pod(config, opts) do
      {:ok, pod} -> create_and_judge(client, pod, opts)
      {:error, reason} -> result(:inconclusive, reason: {:bad_canary, reason})
    end
  end

  defp create_and_judge(client, pod, opts) do
    name = pod["metadata"]["name"]

    case Client.create_pod(client, pod) do
      {:ok, _} ->
        try do
          client |> wait(name, opts) |> judge(client, name)
        after
          Client.delete_pod(client, name, grace_period_seconds: 0)
        end

      {:error, reason} ->
        result(:inconclusive, reason: {:create_failed, reason})
    end
  end

  defp wait(client, name, opts) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    poll = Keyword.get(opts, :poll_ms, @default_poll_ms)
    poll_until(client, name, System.monotonic_time(:millisecond) + timeout, poll)
  end

  defp poll_until(client, name, deadline, poll) do
    state =
      case Client.get_pod(client, name) do
        {:ok, pod} -> classify(pod)
        {:error, reason} -> {:api_error, reason}
      end

    cond do
      match?({:pending, _}, state) or match?({:api_error, _}, state) ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:timeout, state}
        else
          Process.sleep(poll)
          poll_until(client, name, deadline, poll)
        end

      true ->
        state
    end
  end

  defp classify(pod) do
    status = pod["status"] || %{}

    cond do
      failure = pull_failure(status) -> {:pull_failed, failure}
      status["phase"] == "Succeeded" -> {:finished, :succeeded, status}
      status["phase"] == "Failed" -> {:finished, :failed, status}
      true -> {:pending, status["phase"]}
    end
  end

  defp pull_failure(status) do
    statuses = (status["initContainerStatuses"] || []) ++ (status["containerStatuses"] || [])

    Enum.find_value(statuses, fn cs ->
      waiting = get_in(cs, ["state", "waiting"]) || %{}

      if waiting["reason"] in @pull_failures,
        do: waiting["message"] || waiting["reason"]
    end)
  end

  defp judge({:pull_failed, message}, _client, _name),
    do: result(:inconclusive, reason: :image_pull, pull: {:failed, message})

  defp judge({:timeout, state}, _client, _name),
    do:
      result(:inconclusive,
        reason: if(match?({:api_error, _}, state), do: elem(state, 1), else: :timeout)
      )

  defp judge({:finished, outcome, status}, client, name) do
    cond do
      gate_failed?(status) ->
        result(:unenforced, open: ["gate"], pull: :ok)

      true ->
        case Client.read_log(client, name, container: "worker") do
          {:ok, log} -> judge_log(outcome, log, status)
          {:error, reason} -> result(:inconclusive, reason: {:log_unreadable, reason}, pull: :ok)
        end
    end
  end

  defp judge_log(outcome, log, status) do
    parsed = parse(log)

    case verdict(parsed) do
      {:enforced, info} when outcome == :succeeded ->
        result(:enforced, bridge: info.bridge, skipped: info.skipped, pull: :ok)

      {:enforced, _} ->
        result(:inconclusive, reason: {:pod_failed, summary(status)}, pull: :ok)

      {:unenforced, open} ->
        result(:unenforced, open: open, bridge: parsed.probes["bridge"], pull: :ok)

      {:inconclusive, reason} ->
        result(:inconclusive, reason: reason, pull: :ok)
    end
  end

  defp gate_failed?(status) do
    Enum.any?(status["initContainerStatuses"] || [], fn cs ->
      cs["name"] == "seed" and get_in(cs, ["state", "terminated", "exitCode"]) == @gate_exit
    end)
  end

  defp summary(status) do
    statuses = (status["initContainerStatuses"] || []) ++ (status["containerStatuses"] || [])

    Enum.find_value(statuses, status["reason"] || "pod failed", fn cs ->
      case get_in(cs, ["state", "terminated"]) do
        %{"exitCode" => code} when code != 0 -> "#{cs["name"]} exited #{code}"
        _ -> nil
      end
    end)
  end

  defp result(outcome, fields) do
    Map.merge(
      %{outcome: outcome, open: [], skipped: [], bridge: nil, reason: nil, pull: :unknown},
      Map.new(fields)
    )
  end
end
