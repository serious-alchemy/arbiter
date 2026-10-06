#!/usr/bin/env bash
# k2-ingress.sh -- ingress and worker-to-worker checks. Prints "<name> <CONNECTED|REJECTED>"; REJECTED = kube-router
# answered with an ICMP reject (immediate "Connection refused" with a live listener, proven by the baseline run).
cd "$(dirname "$0")"; . ./lib.sh
CTRL_POD=$(k get pod controller -o jsonpath='{.status.podIP}'); CTRL_SVC=$(k get svc arbiter-controller -o jsonpath='{.spec.clusterIP}')
W1=$(k get pod prober -o jsonpath='{.status.podIP}')
chk() { local name=$1; shift; out=$("$@" 2>&1 | tail -1); case "$out" in CONNECTED*) echo "$name CONNECTED";; *) echo "$name REJECTED ($out)" | cut -c1-120;; esac; }
tcp() { echo "timeout 4 bash -c 'exec 3<>/dev/tcp/$1/$2 && { read -t2 -u3 l; echo CONNECTED \$l; }'"; }
chk "other-namespace pod -> controller pod :9443  (want REJECTED)" kubectl -n other-ns exec bystander -- sh -c "$(tcp $CTRL_POD 9443)"
chk "other-namespace pod -> controller svc :9443  (want REJECTED)" kubectl -n other-ns exec bystander -- sh -c "$(tcp $CTRL_SVC 9443)"
chk "other-namespace pod -> worker pod :7000      (want REJECTED)" kubectl -n other-ns exec bystander -- sh -c "$(tcp $W1 7000)"
chk "worker2 -> worker pod :7000                  (want REJECTED)" k exec prober2 -c c -- sh -c "$(tcp $W1 7000)"
chk "worker -> controller pod :9443 (allowed)     (want CONNECTED)" k exec prober -c c -- sh -c "$(tcp $CTRL_POD 9443)"
echo "node host netns -> controller pod :9443: $(vssh "timeout 4 bash -c 'exec 3<>/dev/tcp/$CTRL_POD/9443 && { read -t2 -u3 l; echo CONNECTED \$l; }' 2>&1 | tail -1")  (kubelet-originated traffic is always admitted by the NetworkPolicy API contract)"
