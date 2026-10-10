defmodule Arbiter.NodeAgent.K8s.Readiness do
  @moduledoc """
  The cluster readiness block (`docs/design/remote-workers.md` k8s §9.4, ticket K13):
  what the controller reports in `hello`/`hb` so `arb server doctor` and the nodes
  page can say whether this cluster can take worker pods, and why not.

  Every check is a map with string keys, the shape the podman readiness report uses
  (`"id"`, `"name"`, `"status"` of `ok | warn | fail`, `"detail"`, `"hint"`), so the
  primary stores and renders them the same way.

  | id | proves | how |
  |---|---|---|
  | `netpol` | the CNI enforces the deny-all policies | `Canary` (see `netpol/2`) |
  | `psa` | Pod Security `restricted` is enforced on the namespace **and** the builder's own pod passes it | two server-side dry-run creates: the worker pod as the builder emits it must be admitted, the same pod with a `privileged` container must be refused with `violates PodSecurity` |
  | `priority_class` | the configured `priority_class` exists | the dry-run's admission verdict (`no PriorityClass with name …`); the controller's Role cannot read cluster-scoped `PriorityClass` objects, and the dry-run is the check that matches what a real pod meets |
  | `quota` | a `ResourceQuota` bounds the namespace and has room for a pod | `resourcequotas` (`Quota.headroom/2`) |
  | `registry_pull` | the kubelet can pull the worker image | the canary pod's own pull (it runs the worker image) |
  | `clock` | the API server and this controller agree on the time to within 30 s | `Date` of `GET /version` |

  A dry run stores nothing. Admission runs in a fixed order (the mutating
  `Priority` plugin, then the validating `PodSecurity`, `ValidatingAdmissionPolicy`
  and `ResourceQuota`), so the first rejection hides the later checks; they are then
  reported as not evaluated rather than ok.
  """

  alias Arbiter.NodeAgent.K8s.Canary
  alias Arbiter.NodeAgent.K8s.Client
  alias Arbiter.NodeAgent.K8s.PodConfig
  alias Arbiter.NodeAgent.K8s.Quota

  @max_skew_s 30

  @type check :: %{required(String.t()) => String.t() | nil}

  @doc """
  The five cluster checks for `config` (a `PodSpec` config) given the latest canary
  `result` (`nil` before the first run). Options: `:image` (the worker image, a
  digest-pinned reference under `config.registry`) and `:now_fun`.
  """
  @spec run(Client.t(), map() | keyword(), Canary.result() | nil, keyword()) :: [check()]
  def run(client, config, canary, opts) do
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0)
    {psa, priority, quota_msg} = admission(client, config, opts)

    [psa, priority, quota(client, config, quota_msg), registry_pull(canary), clock(client, now)]
  end

  @doc """
  The `netpol` check from the canary `result` (`nil`: it has not run yet). `note` is
  appended to the detail (the monitor says when a verdict is a kept earlier one).
  Fail closed: only `:enforced` is ok, and an `:inconclusive` run is a failure that
  says nothing was proven.
  """
  @spec netpol(Canary.result() | nil, String.t() | nil) :: check()
  def netpol(result, note \\ nil)

  def netpol(nil, note) do
    check(
      "netpol",
      "NetworkPolicy enforcement",
      "fail",
      join("the canary has not run yet; enforcement is not proven", note),
      "The controller runs the canary at start, on every config change and every 10 minutes."
    )
  end

  def netpol(%{outcome: :enforced} = result, note) do
    skipped =
      case result.skipped do
        [] -> nil
        names -> "not probed: #{Enum.join(names, ", ")}"
      end

    if result.bridge == :closed do
      check(
        "netpol",
        "NetworkPolicy enforcement",
        "warn",
        join("enforced, but the bridge port did not connect from the canary", skipped, note),
        "The worker-to-controller policy is too strict or the controller's 9443 listener is down: " <>
          "workers would start and never reach the primary."
      )
    else
      check(
        "netpol",
        "NetworkPolicy enforcement",
        "ok",
        join("enforced: only the bridge port connects from a worker-labelled pod", skipped, note),
        nil
      )
    end
  end

  def netpol(%{outcome: :unenforced, open: open}, note) do
    check(
      "netpol",
      "NetworkPolicy enforcement",
      "fail",
      join("NOT enforced: a worker-labelled pod reached #{Enum.join(open, ", ")}", note),
      "The cluster's CNI accepts NetworkPolicy objects but does not enforce them. This node takes no " <>
        "placements (degraded: netpol_unenforced) until the CNI enforces them or the operator sets " <>
        "allow_unenforced_network for the node. See docs/remote-workers-k8s-runbook.md."
    )
  end

  def netpol(%{outcome: :inconclusive, reason: reason}, note) do
    check(
      "netpol",
      "NetworkPolicy enforcement",
      "fail",
      join("not proven: the canary could not complete (#{describe(reason)})", note),
      "An unproven policy is treated as an unenforced one. Fix the cause (quota, image pull, " <>
        "scheduling) and the next canary run clears it."
    )
  end

  # -- Pod Security, PriorityClass, admission ---------------------------------------------------

  defp admission(client, config, opts) do
    case Canary.dry_run_pod(config, opts) do
      {:ok, pod} ->
        case classify(Client.create_pod(client, pod, dry_run: true)) do
          :accepted ->
            {psa_negative(client, pod), priority_ok(config), nil}

          {:quota, msg} ->
            {psa_negative(client, pod), priority_ok(config), msg}

          {:pod_security, msg} ->
            {psa_violated(msg), not_evaluated("priority_class", "PriorityClass"), nil}

          {:priority, msg} ->
            {not_evaluated("psa", "Pod Security"), priority_missing(msg), nil}

          {:other, msg} ->
            {psa_unproven(msg), not_evaluated("priority_class", "PriorityClass"), nil}
        end

      {:error, reason} ->
        {check(
           "psa",
           "Pod Security restricted",
           "fail",
           "the builder refused its own pod: #{inspect(reason)}",
           nil
         ), not_evaluated("priority_class", "PriorityClass"), nil}
    end
  end

  defp classify({:ok, _}), do: :accepted

  defp classify({:error, {kind, msg}}) when kind in [:forbidden, :invalid], do: by_message(msg)
  defp classify({:error, {:http, _status, msg}}), do: by_message(msg)
  defp classify({:error, other}), do: {:other, inspect(other)}

  defp by_message(msg) do
    cond do
      msg =~ "violates PodSecurity" -> {:pod_security, msg}
      msg =~ ~r/PriorityClass/i -> {:priority, msg}
      msg =~ "exceeded quota" -> {:quota, msg}
      true -> {:other, msg}
    end
  end

  defp psa_negative(client, pod) do
    probe =
      update_in(pod, ["spec", "containers"], fn [worker | rest] ->
        [put_in(worker, ["securityContext", "privileged"], true) | rest]
      end)

    case classify(Client.create_pod(client, probe, dry_run: true)) do
      {:pod_security, _msg} ->
        check(
          "psa",
          "Pod Security restricted",
          "ok",
          "enforced: the builder's pod is admitted and a privileged pod is refused",
          nil
        )

      :accepted ->
        psa_not_enforced()

      {:quota, _} ->
        psa_not_enforced()

      {:priority, msg} ->
        psa_unproven(msg)

      {:other, msg} ->
        psa_unproven("the privileged probe pod was refused by something else: #{msg}")
    end
  end

  defp psa_not_enforced do
    check(
      "psa",
      "Pod Security restricted",
      "warn",
      "the namespace does not enforce Pod Security restricted: a privileged pod was admitted by the dry run",
      "kubectl label namespace <ns> pod-security.kubernetes.io/enforce=restricted " <>
        "pod-security.kubernetes.io/enforce-version=latest (the builder's pods are written to pass it)."
    )
  end

  defp psa_violated(msg) do
    check(
      "psa",
      "Pod Security restricted",
      "fail",
      "the namespace's Pod Security rejects the builder's own pod: #{trim(msg)}",
      "A controller/builder version mismatch or a stricter profile than restricted: workers cannot start."
    )
  end

  defp psa_unproven(msg) do
    check(
      "psa",
      "Pod Security restricted",
      "warn",
      "could not tell: the dry run was refused by #{trim(msg)}",
      "Fix the rejection (see the message); until then Pod Security enforcement is unproven."
    )
  end

  defp priority_ok(config) do
    class = priority_class(config)

    check(
      "priority_class",
      "PriorityClass",
      "ok",
      "#{class || "(none configured)"} accepted by the dry run",
      nil
    )
  end

  defp priority_missing(msg) do
    check(
      "priority_class",
      "PriorityClass",
      "fail",
      "the configured PriorityClass does not exist: #{trim(msg)}",
      "Create the PriorityClass of the install manifest (low value, preemptionPolicy: Never) " <>
        "or set worker placement.priority_class to one that exists."
    )
  end

  defp not_evaluated(id, name) do
    check(
      id,
      name,
      "warn",
      "not evaluated: the dry-run pod was rejected before this check ran",
      "Fix the other admission failure first."
    )
  end

  defp priority_class(config) do
    case PodConfig.normalize(config) do
      {:ok, cfg} -> get_in(cfg, [:placement, "priority_class"])
      _ -> nil
    end
  end

  # -- quota -------------------------------------------------------------------------------

  defp quota(client, config, dry_run_msg) do
    with {:ok, cfg} <- PodConfig.normalize(config),
         {:ok, quotas} <- Client.list_resource_quotas(client) do
      quota_check(Quota.headroom(quotas, Quota.demand(cfg)), quotas, dry_run_msg)
    else
      {:error, {:bad_config, reason}} ->
        check("quota", "ResourceQuota", "fail", "bad controller config: #{inspect(reason)}", nil)

      {:error, reason} ->
        check(
          "quota",
          "ResourceQuota",
          "warn",
          "could not read resourcequotas: #{inspect(reason)}",
          "The controller's Role grants get/list on resourcequotas; capacity is reported as unknown."
        )
    end
  end

  defp quota_check(_room, [], _msg) do
    check(
      "quota",
      "ResourceQuota",
      "warn",
      "no ResourceQuota in the namespace: nothing bounds what worker pods can request",
      "Apply the install manifest's quota (sized for max_concurrent) before taking real runs."
    )
  end

  defp quota_check(room, _quotas, msg) do
    cond do
      msg != nil or room == 0 ->
        check(
          "quota",
          "ResourceQuota",
          "warn",
          "no room for another worker pod right now#{if msg, do: ": " <> trim(msg), else: ""}",
          "Raise the quota or wait for runs to finish; the controller refuses assigns as no_capacity."
        )

      room == :unbounded ->
        check(
          "quota",
          "ResourceQuota",
          "warn",
          "ResourceQuota objects exist but none bounds pods, CPU or memory requests",
          "A quota on pods and requests.cpu/memory is what ring-fences a shared cluster."
        )

      true ->
        check("quota", "ResourceQuota", "ok", "room for #{room} more worker pod(s)", nil)
    end
  end

  # -- registry pull and clock ---------------------------------------------------------------

  defp registry_pull(nil) do
    check(
      "registry_pull",
      "Image pull",
      "warn",
      "the canary has not run yet; the pull is untested",
      nil
    )
  end

  defp registry_pull(%{pull: :ok}) do
    check("registry_pull", "Image pull", "ok", "the kubelet pulled the worker image", nil)
  end

  defp registry_pull(%{pull: {:failed, message}}) do
    check(
      "registry_pull",
      "Image pull",
      "fail",
      "the kubelet could not pull the worker image: #{trim(message)}",
      "Check the registry address, the image_pull_secrets in the controller config and that the " <>
        "primary has published the image (`arb server doctor` nodes.registry)."
    )
  end

  defp registry_pull(%{pull: :unknown}) do
    check(
      "registry_pull",
      "Image pull",
      "warn",
      "the pull was not observed: the canary pod did not get far enough",
      nil
    )
  end

  defp clock(client, now) do
    case Client.server_time(client) do
      {:ok, server} ->
        skew = DateTime.diff(server, now.(), :second)

        if abs(skew) <= @max_skew_s do
          check(
            "clock",
            "Clock",
            "ok",
            "API server and controller within #{@max_skew_s}s (#{skew}s)",
            nil
          )
        else
          check(
            "clock",
            "Clock",
            "warn",
            "the API server's clock differs from the controller's by #{skew}s",
            "Fix NTP on the cluster nodes: Lease renewals, token expiry and run deadlines depend on it."
          )
        end

      {:error, reason} ->
        check(
          "clock",
          "Clock",
          "warn",
          "could not read the API server's clock: #{inspect(reason)}",
          nil
        )
    end
  end

  # -- plumbing ------------------------------------------------------------------------------

  defp check(id, name, status, detail, hint),
    do: %{"id" => id, "name" => name, "status" => status, "detail" => detail, "hint" => hint}

  defp join(first, second, third \\ nil),
    do: [first, second, third] |> Enum.reject(&is_nil/1) |> Enum.join("; ")

  defp trim(msg) when is_binary(msg), do: String.slice(msg, 0, 300)
  defp trim(other), do: inspect(other)

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason, limit: 5, printable_limit: 120)
end
