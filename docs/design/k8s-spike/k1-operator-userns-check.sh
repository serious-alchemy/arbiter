#!/usr/bin/env bash
# K1 on a REAL cluster: does `hostUsers: false` work with the volume types the worker pod uses (disk emptyDir, memory emptyDir,
# subPath), under Pod Security `restricted`? Not run against the operator cluster by the K1 spike (bd-6zl538).
# Creates ONE namespace (arb-k1-check), one pod, removes the namespace on exit; no cluster-scoped objects.
#   K1_CONFIRM_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" ./k1-operator-userns-check.sh
set -uo pipefail
SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "context: $(kubectl config current-context)   server: $SRV"
[ "${K1_CONFIRM_SERVER:-}" = "$SRV" ] || { echo "refusing: set K1_CONFIRM_SERVER to the server URL above" >&2; exit 2; }
NS=arb-k1-check; IMG=docker.io/library/busybox:stable
kubectl get ns "$NS" >/dev/null 2>&1 && { echo "refusing: $NS exists" >&2; exit 5; }
trap 'kubectl delete ns "$NS" --wait=true --timeout=120s >/dev/null 2>&1' EXIT
kubectl create ns "$NS" >/dev/null && kubectl label ns "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null
echo "nodes:"; kubectl get nodes -o custom-columns=NAME:.metadata.name,KERNEL:.status.nodeInfo.kernelVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: userns}
spec:
  restartPolicy: Never
  hostUsers: false
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, fsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  initContainers:
  - name: seed
    image: $IMG
    command: [sh, -c, "mkdir -p /work/wt/.git /work/home && echo guard > /work/wt/.git/config && echo seeded-by-\$(id -u)"]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: work, mountPath: /work}]
  - name: sidecar
    image: $IMG
    restartPolicy: Always
    command: [sh, -c, "trap 'exit 0' TERM; while :; do sleep 1 & wait \$!; done"]
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
  containers:
  - name: worker
    image: $IMG
    command:
    - sh
    - -c
    - |
      echo "uid_map: \$(tr -s ' ' < /proc/self/uid_map)   (a host-user pod shows '0 0 4294967295')"
      echo "disk emptyDir + subPath: \$(ls -ln /wt/proj/.git/config)  content=\$(cat /wt/proj/.git/config)"
      echo "guard write: \$( (echo x > /wt/proj/.git/config) 2>&1 | head -1 )"
      echo "guard mv:    \$(mv /wt/proj/.git/config /wt/proj/.git/c2 2>&1 | head -1)"
      echo "memory emptyDir write: \$( (dd if=/dev/zero of=/tmp/m bs=1M count=8 2>&1 | tail -1) )"
    securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
    volumeMounts:
    - {name: work, mountPath: /wt/proj, subPath: wt}
    - {name: work, mountPath: /wt/proj/.git/config, subPath: wt/.git/config, readOnly: true}
    - {name: tmp, mountPath: /tmp}
  volumes:
  - {name: work, emptyDir: {sizeLimit: 256Mi}}
  - {name: tmp, emptyDir: {medium: Memory, sizeLimit: 64Mi}}
YAML
for i in $(seq 1 90); do ph=$(kubectl -n "$NS" get pod userns -o jsonpath='{.status.phase}'); [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 2; done
echo "phase=$ph"; kubectl -n "$NS" get pod userns -o jsonpath='{.status.containerStatuses[0].state}{"\n"}{.status.initContainerStatuses[*].state}{"\n"}' | cut -c1-300
kubectl -n "$NS" logs userns -c seed 2>&1 | head -3; kubectl -n "$NS" logs userns -c worker 2>&1 | head -10
[ "$ph" = Succeeded ] && echo "RESULT: PASS" || { echo "RESULT: FAIL: see events:"; kubectl -n "$NS" get events 2>&1 | tail -5; exit 1; }
