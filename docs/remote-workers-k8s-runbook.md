# Remote workers on Kubernetes: readiness, canary and rollout runbook

How to tell whether a Kubernetes cluster can take Arbiter worker pods, what to do
when it says no, how the end-to-end suite is run, and the checklist for rolling the
operator's k3s out as a **test bed**. The design is
[`design/remote-workers.md`](design/remote-workers.md) §16 (section numbers below
"k8s §" refer to it); the machine-node procedure is
[`remote-workers-runbook.md`](remote-workers-runbook.md).

> **Never run anything in this document against the operator's k3s without the
> operator's explicit go-ahead.** That cluster is cluster-admin for whoever holds
> the kubeconfig and it hosts production workers and the CI runner. Every command
> under [The k3s test-bed rollout](#4-the-k3s-test-bed-rollout-checklist) is the
> operator's to run, or to say "go" to.

## 1. What "ready" means, and who says it

`--network=none` has no Kubernetes equal. A pod always has an `eth0`; the isolation a
podman worker gets from the kernel becomes "the CNI enforces the NetworkPolicies of
the bootstrap manifest", and a CNI that does not enforce them accepts the objects and
ignores them (k8s §9.4). So the controller does not assume. A
`ReadinessMonitor` (`Arbiter.NodeAgent.K8s.ReadinessMonitor`) **proves** it:

* **When:** at start, on every controller config change, and every 10 minutes.
* **How:** a short-lived **canary pod**, built by the worker's own pod builder (so it has
  the worker's labels and every policy selects it, the worker's service account,
  security context, owner reference, priority class and placement) runs the netpol gate
  and then six TCP connects with a 1-second timeout.

  | probe | target | must |
  |---|---|---|
  | `api` | the `kubernetes` Service address | fail |
  | `controller_port` | the controller pod on port 9445, which is not a bridge port | fail |
  | `foreign` | the cluster DNS Service (another namespace) | fail |
  | `internet` | `1.1.1.1:443` | fail |
  | `node` | the node's kubelet port, `<node IP>:10250` | fail |
  | `bridge` | the controller Service on 9443 | **connect** |

* **Verdict:** *any* connect among the five is `degraded: netpol_unenforced`. The node
  then takes no placements (`Placement` excludes it) unless the operator sets
  `allow_unenforced_network` on that node, an explicit, audited override.

### It fails closed

`netpol_unenforced` is the **default**. It is set before the first canary has finished,
after a canary that connected anywhere, and after one that could not complete (quota
full, image will not pull, nothing schedulable) *unless* an earlier run proved
enforcement less than 30 minutes ago, in which case that verdict is kept and shown as
a warning. A cluster that has never passed has nothing to keep. Independently of the
canary, **every worker pod runs the same gate before anything untrusted starts**: a CNI
that never enforces, or enforces late, makes the pod exit 70 and the run is refused
`netpol_unenforced`, per pod.

### The rest of the readiness block

| check | proves | how it is tested |
|---|---|---|
| `psa` | Pod Security `restricted` is enforced on the namespace **and** the builder's own pod passes it | two server-side dry-run creates: the builder's pod must be admitted, the same pod with a `privileged` container must be refused with `violates PodSecurity` |
| `priority_class` | the configured PriorityClass exists | the dry run's admission verdict (`no PriorityClass with name …`); the controller's Role cannot read cluster-scoped objects, and the dry run is what a real pod meets |
| `quota` | a ResourceQuota bounds the namespace and has room for one more worker pod | `resourcequotas` |
| `registry_pull` | the kubelet can pull the worker image | the canary pod runs the worker image |
| `clock` | the API server and the controller agree to within 30 s | `Date` header of `GET /version` |

A dry run stores nothing. Admission checks run in a fixed order, so the first rejection
hides the later ones; they are then reported "not evaluated", not ok.

## 2. Reading it

```sh
arb server doctor            # the "nodes" section: one row per readiness check
arb node show <name>         # the node row: degraded, k8s_version, capacity
```

For each cluster node the doctor prints `node <name>` (state, heartbeat, versions) and
then `cluster <name>: <check>` rows: `NetworkPolicy enforcement`, `Pod Security
restricted`, `PriorityClass`, `ResourceQuota`, `Image pull`, `Clock`. A
`cluster <name>: placement` row appears while the node is `degraded: netpol_unenforced`
and says whether the operator override is on. Every problem is a `[warn]` like the rest
of the nodes section: it never fails the doctor or blocks a deploy, but a
`NetworkPolicy enforcement` warning means **no work is being placed on that node**.
A cluster node that has reported no readiness block says so
(`cluster <name>: readiness`); a controller older than the server does not send one,
`arb node upgrade <name>` fixes that.

The node's readiness block is also in `GET /api/nodes` as `readiness`, next to
`degraded`.

## 3. When a check is not ok

### The canary says `netpol_unenforced`

`NOT enforced: a worker-labelled pod reached …` means a worker-labelled pod connected
to something it must not. Find out which CNI you have and whether it enforces:

```sh
kubectl -n kube-system get pods -o name | grep -iE 'flannel|kube-router|cilium|calico|canal|weave|netpol'
```

* **k3s**: the bundled kube-router network-policy controller must not be disabled
  (`--disable-network-policy` off) and the node needs `iptables` and `ipset` modules.
  A Wi-Fi-latched flannel is exactly where this goes wrong; prove it, do not assume it.
* **kind**: current kind releases ship a kindnet that enforces NetworkPolicy; an older kind, or a cluster created with the default CNI disabled, does not.
* **Plain flannel, or any CNI without a policy engine**: it will never pass. Install a
  policy engine (Calico in policy-only mode, or switch CNI) or do not use that cluster.

If you only see `reached gate`, the seed gate (k8s §9.1) timed out: the API server
Service address stayed reachable for the whole gate timeout, which is the same finding.

After a fix the next canary run (at most 10 minutes, or edit the ConfigMap to trigger
one) clears the flag. **`allow_unenforced_network`** (`arb node set <name>
--allow-unenforced-network`) places work on a node anyway. It is a statement that
untrusted code on that node may reach the cluster network, and it is recorded in the
node's audit events. Use it only on a cluster you would trust with the code anyway.

`not proven: the canary could not complete (…)` is not a finding about the cluster; it
is the canary failing to run, and it is treated as unenforced until it runs. Typical
reasons: `timeout` (no node can schedule 50 m CPU / 32 Mi, or the image pull is slow;
the canary waits 2 minutes), `{:create_failed, {:forbidden, "exceeded quota …"}}` (the
quota is full), `image_pull`.

### `bridge port did not connect`

The policy is enforced but the canary cannot reach the controller Service on 9443: the
`worker-to-controller` / `controller-ingress-from-workers` policies are too strict for
this CNI (a ClusterIP is DNATed before the policy sees it on some), or the controller's
listener is down. Workers would start and never reach the primary. This is a warning,
not `netpol_unenforced`.

### `Pod Security restricted`

* *does not enforce*: label the namespace
  `kubectl label ns <ns> pod-security.kubernetes.io/enforce=restricted
  pod-security.kubernetes.io/enforce-version=latest`. A namespace that does not enforce
  `restricted` leaves the hardening to the admission policy alone.
* *rejects the builder's own pod*: a builder/controller version mismatch or a stricter
  profile. The message names the field. Workers cannot start.

### `PriorityClass`, `ResourceQuota`, `Image pull`, `Clock`

* PriorityClass: create the one in the install manifest (`value: -100`,
  `preemptionPolicy: Never`) or set `placement.priority_class` in
  `arbiter-controller-config` to one that exists.
* ResourceQuota: apply the install manifest's quota (sized for `max_concurrent`).
  "no room" means pods are running or pending against it; `assign` is refused
  `no_capacity` until one finishes.
* Image pull: the kubelet message is in the detail. Check `nodes.registry`, the
  `image_pull_secrets` in the controller ConfigMap, and that the primary has published
  the image (`arb server doctor`, `nodes.registry`).
* Clock: fix NTP on the cluster nodes. Lease renewals, token expiry and run deadlines
  depend on it.

## 4. The k3s test-bed rollout checklist

Design k8s §13 calls the operator's k3s a sensible **test bed** and not yet a
production target for sensitive workspaces: one server (`mesanna`) and one worker
(`aginor`, on Wi-Fi), runc only, no PSA enforcement, **zero NetworkPolicies so far**,
and the cluster also hosts the vstim production workers and the CI runner. Room for
about two 2-CPU pods.

Work through the list **in order**. Do not skip a step because a later one "covers
it". Each step has a pass criterion; stop at the first that fails.

0. **Go-ahead.** The operator says, in this ticket or to the coordinator, that the k3s
   may be touched and by whom. Without it, stop here. Use a dedicated namespace
   (`arbiter-workers`) and the kubeconfig context the operator names; never `kubectl
   --all-namespaces` anything.
1. **Prove NetworkPolicy enforcement on the real cluster, standalone.** Run
   `docs/design/k8s-spike/k2-operator-check.sh` (read it first: it touches two
   throwaway namespaces `arb-k2-check` and `arb-k2-other`, removes them, and refuses
   unless you confirm the server URL). **Pass:** every case in its output is as the
   script's own summary expects, including the start-up window finding. This is the
   rollout's first step precisely because enforcement has never been exercised there.
2. **Namespace with Pod Security `restricted`.** Apply the install manifest's namespace
   with `pod-security.kubernetes.io/enforce: restricted`. **Pass:** `kubectl get ns
   arbiter-workers --show-labels` shows it, and a deliberately privileged test pod is
   refused (the doctor's `Pod Security restricted` row does this for you later).
3. **ResourceQuota.** Apply the quota for `max_concurrent: 2` (the install manifest's
   §4.3 block: pods 4, requests 3 CPU / 6 GiB, limits 6 CPU / 10 GiB). **Pass:**
   `kubectl -n arbiter-workers describe resourcequota` lists it. This is what keeps
   workers from starving vstim prod and CI.
4. **Low priority.** Create the PriorityClass `arbiter-worker` with `value: -100` and
   `preemptionPolicy: Never`. **Pass:** `kubectl get priorityclass arbiter-worker`
   shows `-100`. Workers must never preempt anything else.
5. **NetworkPolicies.** Apply `default-deny`, `worker-to-controller`,
   `controller-ingress-from-workers` and `controller-egress` from the install manifest
   (fill the `controller-egress` addresses: the API node IP, the `kubernetes` ClusterIP).
6. **Pin to `mesanna`.** Set `placement.node_selector: {kubernetes.io/hostname:
   mesanna}` in `arbiter-controller-config`, and pre-pull the worker image there
   (843 MB over `aginor`'s Wi-Fi is a non-starter). **Pass:** the ConfigMap loads
   (no `bad_config` degradation) and `crictl images` on `mesanna` lists the image.
7. **Install the controller** from the primary ("Add node", kind `cluster`, or
   `arb node add --kind cluster`), with `max_concurrent: 2`. The cluster is not on the
   tailnet, so use the install's reachability path A (a tagged tailscale auth key).
   **Pass:** the node shows `online` in `arb node list`.
8. **The canary passes.** `arb server doctor`. **Pass, all of:**
   `cluster <name>: NetworkPolicy enforcement` is `ok` (not `kept`, not `bridge … did
   not connect`), `Pod Security restricted` ok (enforced), `PriorityClass` ok,
   `ResourceQuota` ok with room, `Image pull` ok, `Clock` ok, and there is **no**
   `placement` row. If the canary fails, go to §3; do not set
   `allow_unenforced_network` on this cluster.
9. **The operator accepts shared tenancy, in writing.** Untrusted LLM-driven code runs
   in pods that share a kernel (runc, no gVisor/Kata) with vstim prod and the CI runner;
   the PriorityClass, quota and namespace ring-fence them but do not remove that. The
   operator records the acceptance (in the ticket) before any real run goes there. A
   dedicated spare machine with a tainted `arbiter-workers` pool removes this step and is
   the better first *production* cluster.
10. **Placement stays `local_only` for sensitive workspaces.** The `worker.placement`
    default is `local_only`; opt a workspace in deliberately, and only non-sensitive
    ones, for the test bed. Start with one workspace and `max_concurrent: 2`.
11. **Watch the first runs.** `arb node show <name>`, the doctor, and `kubectl -n
    arbiter-workers get pods`. Check the canary again after the first run finishes and
    again after 10 minutes.

**Back-out:** `arb node drain <name>` then `arb node revoke <name>`, then delete the
namespace `arbiter-workers` (this removes the controller, its Secrets and any worker
pod) and the `arbiter-worker` PriorityClass. Nothing else in the cluster was changed by
this checklist.

## 5. Running the end-to-end suite on a disposable cluster

The `:k8s` suite (`apps/arbiter/test/k8s/`) runs the canary, the readiness checks and
the monitor against a **real** API server, on a kind or k3d cluster created for the
run. It is excluded from `mix test`, from CI and from the pre-push gate by the `:k8s`
tag (`apps/arbiter/test/test_helper.exs`).

```sh
scripts/k8s-e2e.sh            # kind (needs kind, kubectl, podman or docker)
scripts/k8s-e2e.sh k3d        # k3d
```

The script creates `arb-e2e-<random>` with a kubeconfig of its own under `$TMPDIR`,
runs `mix test --include k8s test/k8s` in `apps/arbiter`, and deletes the cluster by its
exact name on exit. To use a cluster you created yourself:

```sh
ARB_K8S_E2E=1 ARB_K8S_E2E_KUBECONFIG=/path/to/kubeconfig \
  mix test --include k8s test/k8s          # from apps/arbiter
```

**What stops it reaching a real cluster** (`Arbiter.Test.K8sE2E.connect!/0`, itself
tested in the default suite by `e2e_guard_test.exs`): it needs both variables; it never
reads `~/.kube/config` or `$KUBECONFIG`; it refuses any context not named `kind-*` or
`k3d-*` and any API server not on loopback; every namespace is `arb-e2e-<random>` and is
deleted by exact name, as is its one `PriorityClass`.

**What it needs:** a CNI that enforces NetworkPolicy (kind's kindnet and k3d's kube-router
both do), a kernel and container runtime that support user namespaces for pods (`hostUsers: false`,
which the builder always sets), and access to Docker Hub for
`alpine/socat@sha256:beb4a68d…` (tag 1.8.0.3; override with `ARB_K8S_E2E_IMAGE`). The
canary needs only `sh` and `socat` in its image, so the suite does not need the real worker
image.

**What it proves:** the canary pod is admitted by real Pod Security `restricted` and runs;
in a namespace with the bootstrap policies it connects to the bridge port and nothing else
(`enforced`); in a namespace without them it reaches the API, the internet and the node
(`unenforced`, `degraded: netpol_unenforced`); every readiness check is ok against a
correctly prepared namespace; the monitor fails closed until a canary has run.

**What it does not:** the real worker image, a real run, the tailnet path, k3s's
kube-router specifically (use the rollout's step 1 for that), or the agent-to-primary
connection.

## 6. What is and is not wired (as of K13)

In the tree: the canary, the readiness checks, `ReadinessMonitor`, the controller
carrying the monitor's `degraded` and readiness block in `Controller.report/1` (and
pushing `"readiness"` after each run), the primary storing a cluster node's readiness
from `hello` and `hb`, `GET /api/nodes` serving it, and the doctor section.

Not in the tree: the agent boot that starts `ReadinessMonitor` and `Controller` under
the node supervisor and maps `Controller.report/1` onto the cluster `hello`/`hb`
(`readiness`, `degraded`). The controller manifest already gives the controller what
the canary needs (`ARB_POD_IP`, `ARB_NODE_IP` from the downward API;
`Canary.targets_from_env/1`). Until that boot exists a real cluster node reports no
readiness block, and the doctor prints `cluster <name>: readiness … no readiness
report yet`.

Two probes depend on what the controller can learn: `foreign` uses the cluster DNS
Service from `/etc/resolv.conf` (a Service in another namespace, backed by pods there)
because the controller's Role cannot list pods outside its namespace; `node` uses the
kubelet port. A target that cannot be named is `skipped`, shown in the detail
(`not probed: foreign`), and never guessed.
