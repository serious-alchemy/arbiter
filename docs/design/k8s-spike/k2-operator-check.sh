#!/usr/bin/env bash
# K2 on a REAL cluster (the operator's k3s with the bundled kube-router): does deny-all NetworkPolicy actually enforce,
# including ClusterIPs and pod IPs, and is there a fail-open window when a pod starts?
#
# NOT RUN by the K1 spike (bd-6zl538): the operator's kubeconfig is cluster-admin and the cluster hosts prod and CI.
# Run it yourself, with the context you intend, after reading it. It touches ONE throwaway namespace pair
# (arb-k2-check, arb-k2-other), changes nothing else, and removes both on exit. It needs: kubectl, bash, and image pulls of
# docker.io/library/busybox:stable. It creates no ClusterRole, no webhook, no CRD, and does not touch kube-system.
#
#   K2_CONFIRM_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" ./k2-operator-check.sh
#
# Read the printed server URL first; the script refuses unless K2_CONFIRM_SERVER equals the current context's server.
set -uo pipefail
SRV=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "context: $(kubectl config current-context)   server: $SRV"
[ "${K2_CONFIRM_SERVER:-}" = "$SRV" ] || { echo "refusing: set K2_CONFIRM_SERVER to the server URL above to confirm this is the cluster you mean" >&2; exit 2; }
NS=arb-k2-check; OTHER=arb-k2-other; IMG=docker.io/library/busybox:stable
K="kubectl -n $NS"; KO="kubectl -n $OTHER"
cleanup() { kubectl delete ns "$NS" "$OTHER" --wait=true --timeout=180s >/dev/null 2>&1; }
trap cleanup EXIT
fail=0

# ---- discover the cluster (nothing hard-coded) ----
APIIP=$(kubectl get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
DNSIP=$(kubectl get svc kube-dns -n kube-system -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
PODCIDR=$(kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}')
SVCCIDR=$(printf '%s' "$APIIP" | awk -F. '{print $1"."$2".0.0/16"}')
echo "discovered: api ClusterIP=$APIIP node=$NODEIP dns=$DNSIP podCIDR=$PODCIDR svcCIDR(assumed /16)=$SVCCIDR"
echo "CNI/netpol hints: $(kubectl -n kube-system get pods -o name 2>/dev/null | grep -iE 'flannel|kube-router|cilium|calico|canal|weave' | tr '\n' ' ')"
echo "kernel/iptables per node: $(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.kernelVersion}{" "}{.status.nodeInfo.osImage}{"; "}{end}')"

# ---- fixtures ----
if kubectl get ns "$NS" "$OTHER" >/dev/null 2>&1; then echo "refusing: namespace $NS or $OTHER already exists (a previous run still terminating?)" >&2; trap - EXIT; exit 5; fi
kubectl create ns "$NS" >/dev/null && kubectl label ns "$NS" pod-security.kubernetes.io/enforce=restricted >/dev/null
kubectl create ns "$OTHER" >/dev/null
pod() { # <ns> <name> <component|-> <listen-ports...>
  local ns=$1 name=$2 comp=$3; shift 3
  local cmd="" p; for p in "$@"; do cmd="$cmd nc -lk -p $p -e echo HELLO-$p &"; done
  kubectl -n "$ns" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $name, labels: {app.kubernetes.io/component: $comp}}
spec:
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: $IMG
    command: [sh, -c, "${cmd} sleep 100000"]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
}
pod "$NS" controller controller 9443 9444 8080
pod "$NS" worker worker 7000
pod "$NS" worker2 worker 7000
pod "$OTHER" bystander other 8080
kubectl -n "$NS" wait --for=condition=Ready pod/controller pod/worker pod/worker2 --timeout=180s >/dev/null || { echo "pods not ready"; exit 3; }
kubectl -n "$OTHER" wait --for=condition=Ready pod/bystander --timeout=180s >/dev/null || { echo "pods not ready"; exit 3; }
kubectl -n "$NS" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Service
metadata: {name: arbiter-controller}
spec: {selector: {app.kubernetes.io/component: controller}, ports: [{name: boot, port: 9444}, {name: bridge, port: 9443}, {name: other, port: 8080}]}
YAML
CTRL_SVC=$($K get svc arbiter-controller -o jsonpath='{.spec.clusterIP}')
CTRL_POD=$($K get pod controller -o jsonpath='{.status.podIP}'); W1=$($K get pod worker -o jsonpath='{.status.podIP}')
W2=$($K get pod worker2 -o jsonpath='{.status.podIP}'); BYS=$($KO get pod bystander -o jsonpath='{.status.podIP}')

reach() { # <ns> <pod> <host> <port> -> echoes CONNECTED | BLOCKED
  if kubectl -n "$1" exec "$2" -c c -- nc -z -w 3 "$3" "$4" >/dev/null 2>&1; then echo CONNECTED; else echo BLOCKED; fi; }
expect() { # <label> <ns> <pod> <host> <port> <want>
  local got; got=$(reach "$2" "$3" "$4" "$5")
  if [ "$got" = "$6" ]; then printf 'PASS  %-46s %s:%s -> %s\n' "$1" "$4" "$5" "$got"; else printf 'FAIL  %-46s %s:%s -> %s (wanted %s)\n' "$1" "$4" "$5" "$got" "$6"; fail=1; fi; }

echo; echo "== 1. baseline, no policies: every target must be reachable (otherwise the probes prove nothing)"
for t in "controller svc 9443:$CTRL_SVC:9443" "controller pod 8080:$CTRL_POD:8080" "pod in other ns:$BYS:8080" "other worker pod:$W2:7000"; do
  IFS=: read -r l h p <<<"$t"; expect "baseline $l" "$NS" worker "$h" "$p" CONNECTED; done
[ "$fail" = 0 ] || { echo "baseline failed: the test harness itself is not working; stopping"; exit 4; }

echo; echo "== 2. apply the K§9.1 policies (default-deny + worker->controller 9443/9444 + controller egress)"
$K apply -f - >/dev/null <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny}
spec: {podSelector: {}, policyTypes: [Ingress, Egress]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: worker-to-controller}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: worker}}
  policyTypes: [Egress]
  egress:
  - to: [{podSelector: {matchLabels: {app.kubernetes.io/component: controller}}}]
    ports: [{protocol: TCP, port: 9443}, {protocol: TCP, port: 9444}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: controller-ingress-from-workers}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: controller}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {matchLabels: {app.kubernetes.io/component: worker}}}]
    ports: [{protocol: TCP, port: 9443}, {protocol: TCP, port: 9444}]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: controller-egress}
spec:
  podSelector: {matchLabels: {app.kubernetes.io/component: controller}}
  policyTypes: [Egress]
  egress:
  - to: [{ipBlock: {cidr: $NODEIP/32}}, {ipBlock: {cidr: $APIIP/32}}]
    ports: [{protocol: TCP, port: 6443}, {protocol: TCP, port: 443}]
  - to: [{ipBlock: {cidr: 0.0.0.0/0, except: [$PODCIDR, $SVCCIDR]}}]
    ports: [{protocol: TCP, port: 443}]
YAML
sleep 10
echo "-- worker egress (want: only the controller on 9443/9444)"
expect "worker -> controller svc 9443 (bridge)"      "$NS" worker "$CTRL_SVC" 9443 CONNECTED
expect "worker -> controller svc 9444 (boot)"        "$NS" worker "$CTRL_SVC" 9444 CONNECTED
expect "worker -> controller POD IP 9443"            "$NS" worker "$CTRL_POD" 9443 CONNECTED
expect "worker -> controller svc 8080 (non-bridge)"  "$NS" worker "$CTRL_SVC" 8080 BLOCKED
expect "worker -> controller POD IP 8080"            "$NS" worker "$CTRL_POD" 8080 BLOCKED
expect "worker -> pod in another namespace"          "$NS" worker "$BYS" 8080 BLOCKED
expect "worker -> other worker pod"                  "$NS" worker "$W2" 7000 BLOCKED
expect "worker -> kube-dns ClusterIP tcp/53"         "$NS" worker "$DNSIP" 53 BLOCKED
expect "worker -> API server ClusterIP :443"         "$NS" worker "$APIIP" 443 BLOCKED
expect "worker -> node IP :6443 (API server)"        "$NS" worker "$NODEIP" 6443 BLOCKED
expect "worker -> node IP :10250 (kubelet)"          "$NS" worker "$NODEIP" 10250 BLOCKED
expect "worker -> 1.1.1.1:443"                       "$NS" worker 1.1.1.1 443 BLOCKED
echo "-- ingress (want: only workers reach the controller, nothing reaches a worker)"
expect "other-ns pod -> controller pod 9443"         "$OTHER" bystander "$CTRL_POD" 9443 BLOCKED
expect "other-ns pod -> controller svc 9443"         "$OTHER" bystander "$CTRL_SVC" 9443 BLOCKED
expect "other-ns pod -> worker pod 7000"             "$OTHER" bystander "$W1" 7000 BLOCKED
expect "worker2 -> worker pod 7000"                  "$NS" worker2 "$W1" 7000 BLOCKED
echo "-- controller egress (want: API via node IP and ClusterIP, DNS, internet 443; not the pod network)"
expect "controller -> API ClusterIP :443"            "$NS" controller "$APIIP" 443 CONNECTED
expect "controller -> node IP :6443"                 "$NS" controller "$NODEIP" 6443 CONNECTED
expect "controller -> pod in another namespace"      "$NS" controller "$BYS" 8080 BLOCKED
expect "controller -> worker pod"                    "$NS" controller "$W1" 7000 BLOCKED

echo; echo "== 3. fail-open window: 5 fresh worker pods probe the API ClusterIP from their first instruction for 4 s"
open=0
for n in 1 2 3 4 5; do
  $K apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: startup-$n, labels: {app.kubernetes.io/component: worker}}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 10001, runAsGroup: 10001, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: c
    image: $IMG
    command: [sh, -c, 'end=\$((\$(date +%s)+4)); o=0; while [ \$(date +%s) -lt \$end ]; do nc -z -w 1 $APIIP 443 >/dev/null 2>&1 && o=\$((o+1)); done; echo open_connections=\$o']
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
done
for n in 1 2 3 4 5; do
  for i in $(seq 1 90); do ph=$($K get pod startup-$n -o jsonpath='{.status.phase}'); [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 1; done
  o=$($K logs startup-$n 2>/dev/null | sed -n 's/open_connections=//p'); echo "startup-$n: connections that succeeded before/while the policy engaged: ${o:-?}"; [ "${o:-0}" != 0 ] && open=$((open+1))
done
[ "$open" = 0 ] && echo "NOTE  no fail-open window observed" || echo "NOTE  $open/5 fresh pods reached the API server while starting: a fail-open window exists on this CNI; the seed gate (K§16.15 K2) is REQUIRED"
echo; [ "$fail" = 0 ] && echo "RESULT: PASS (NetworkPolicy deny-all enforced as designed)" || echo "RESULT: FAIL (see FAIL lines)"
exit $fail
