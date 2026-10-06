#!/usr/bin/env bash
# wait-pod.sh <pod> [timeout_s] -- wait until the pod phase is Succeeded/Failed, then dump status + logs
cd "$(dirname "$0")"; . ./lib.sh
P=$1; T=${2:-120}
for i in $(seq 1 $((T/2))); do ph=$(k get pod "$P" -o jsonpath='{.status.phase}' 2>/dev/null); [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break; sleep 2; done
echo "phase=$ph reason=$(k get pod "$P" -o jsonpath='{.status.reason}')"
k get pod "$P" -o json | jq -r '((.status.initContainerStatuses // []) + (.status.containerStatuses // []))[] | "\(.name): exit=\(.state.terminated.exitCode // "-") reason=\(.state.terminated.reason // "-") started=\(.state.terminated.startedAt // "-") finished=\(.state.terminated.finishedAt // "-")"' 2>/dev/null
for c in $(k get pod "$P" -o json | jq -r '[.spec.initContainers[]?.name, .spec.containers[].name][]'); do echo "=== $P/$c"; k logs "$P" -c "$c" 2>&1; done
