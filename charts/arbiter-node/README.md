# arbiter-node

One Arbiter cluster node as a Helm chart (`docs/design/remote-workers.md` §20.5-§20.7). The raw
manifests (`GET /nodes/join/k8s.yaml`) remain the fallback for clusters without Helm.
`GET /nodes/join/values.yaml?name=...` on the primary returns this chart's values for a node
(quota and LimitRange sized for its `max`, the primary's URL, no secret); the dashboard's
"Add node" Helm tab and `arb node add --kind cluster --format helm|values` print the
commands that use it.

```sh
# 1. cluster-admin, once: the namespace and its Pod Security labels (the chart does not template it)
kubectl create namespace arbiter-workers
kubectl label namespace arbiter-workers \
  pod-security.kubernetes.io/enforce=restricted pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted pod-security.kubernetes.io/warn=restricted

# 2. the join token, read from your terminal (never argv, history or Helm's release record)
read -rs T && printf %s "$T" | kubectl -n arbiter-workers create secret generic arbiter-join --from-file=token=/dev/stdin

# 3. install; the release name is the node name
helm install mesaana ./charts/arbiter-node -n arbiter-workers \
  --set primary.url=https://arbiter.example.ts.net \
  --set 'networkPolicy.controllerEgress.primaryCIDRs={100.64.0.10/32}'
```

## `mode`

| mode | renders | who |
|---|---|---|
| `all` (default) | everything below | a cluster-admin, one release |
| `bootstrap` | `PriorityClass`, `ResourceQuota`, `LimitRange`, four `NetworkPolicy`, optional `RuntimeClass` and `ValidatingAdmissionPolicy` | a cluster-admin, once |
| `node` | two `ServiceAccount`s, `Role`, `RoleBinding`, placeholder `Secret`s, `ConfigMap`s, `Lease`, `Service`, `Deployment` | a namespace admin |

`bootstrap` and `node` are two releases (`helm install mesaana-bootstrap ... --set mode=bootstrap`,
`helm install mesaana ... --set mode=node`). This is the same split as `?part=` of the raw manifests.

## Rules the chart keeps

- **Object names are fixed** (`arbiter-controller`, `arbiter-worker`, ...): the Role's `resourceNames`, the
  Service, the Lease, every worker pod's ownerReference and the NetworkPolicy selectors name them. One
  release per namespace.
- **The controller has its own PriorityClass** (`controller.priorityClassName`, default
  `arbiter-controller`, `value: 1000`, `PreemptLowerPriority`), above the workers' `-100`
  (`placement.priorityClass`, `Never`). Losing the controller interrupts every run on the node, so a
  contended cluster must not evict it first. The chart refuses a controller value that does not exceed the
  workers'. Set `controller.priorityClassName=""` for no class, `controller.priorityClass.preemptionPolicy=Never`
  to stop it evicting others, `controller.priorityClass.create=false` on every install after the first on a
  cluster. In `mode=node` the class must already exist: upgrade the bootstrap release first.
- **No `Namespace`** is templated: Helm stores its release record in the namespace, so it must exist first.
- **Helm owns the controller image.** The Role has no write verb on the Deployment and
  `ARB_K8S_SELF_UPGRADE=false`; the Deployment carries `ARB_INSTALL_METHOD=helm`, `ARB_HELM_RELEASE` and
  `ARB_CHART_REF` so the node can report `helm upgrade <release> <chartRef> --version <v> -n <ns> --reset-then-reuse-values`.
- **No secret in values.** The join token is a pre-created Secret (`--set-file join.token=` is the
  automation fallback and lands in Helm's release record); the tailscale auth key and pull secrets are names.
- **`values.schema.json` rejects unknown keys** at every level, a `direct` install without `primaryCIDRs`,
  a `/0` allowlist entry, and an admission policy without `registries`.
- **No `checksum/config` annotation**: the controller re-reads `controller.yaml` every 30 s and a
  config-only `helm upgrade` must not roll the pod.
- The pod spec of a worker is not in the chart (the controller builds it at runtime), so nothing about its
  security context, volumes or `hostUsers` is a value.

## Checks

```sh
scripts/helm-chart-check.sh          # helm lint --strict + helm template | kubeconform for every mode/reach
cd apps/arbiter && mix test test/arbiter/node_agent/k8s/helm_chart_test.exs   # renders need helm on PATH
```

`quota.hard` and `limitRange` are explicit figures for `concurrency.max=2` and the default worker size:
Helm templates cannot parse Kubernetes quantities. For another shape take the numbers from the primary's
`InstallManifest` or edit them by hand.

## Published artefacts (release CI)

Every tagged release (`.github/workflows/release.yml`, job `publish-oci`) publishes, all `linux/amd64`:

| Artefact | Reference |
|---|---|
| controller image | `ghcr.io/<owner>/arbiter-controller:<version>` (also `:v<version>`) |
| this chart | `oci://ghcr.io/<owner>/charts/arbiter-node` at `--version <version>` (`appVersion` is the same) |
| worker base | `ghcr.io/<owner>/arbiter-worker-base:<hash>`, the content hash a primary tags the same base with |

The controller image and the worker base are built from the Containerfiles the primary generates
(`mix arbiter.containerfile controller|worker-base --pin`), so CI and the primary cannot drift.

**Signing** is optional: set the repository variable `RELEASE_COSIGN=true`, or run the workflow by hand
with `sign` ticked. Verify with

    cosign verify ghcr.io/<owner>/arbiter-controller@<digest> \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp '^https://github.com/<owner>/<repo>/\.github/workflows/release\.yml@'

and pin the verified digest with `--set image.digest=sha256:...`.

**After the first release (operator, one-time):** open each of the three packages on GitHub and confirm
visibility is *public* (Package settings, Change visibility), since a package a workflow creates is not
necessarily public even when the repository is (H7). The packages are linked to the repository by the
`org.opencontainers.image.source` label. An arm64 node needs an arm64 release build, which is not built (H4).
