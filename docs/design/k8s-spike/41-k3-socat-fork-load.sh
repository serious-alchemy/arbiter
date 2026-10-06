#!/usr/bin/env bash
# K3: socat fork-per-connection under load: the in-pod listener (TCP-LISTEN ... fork) -> OPENSSL: to the mTLS listener.
# Usage: 41-k3-socat-fork-load.sh <certdir> <image> <serverlog> [port]
set -uo pipefail
C=$1; IMG=$2; LOG=$3; P=${4:-19443}; L=15555
podman rm -f arb-k3-socat >/dev/null 2>&1
podman run -d --name arb-k3-socat --network=host --userns=keep-id -v "$C":/c:ro,Z "$IMG" socat TCP-LISTEN:$L,bind=127.0.0.1,fork,reuseaddr${BACKLOG:+,backlog=$BACKLOG} OPENSSL:127.0.0.1:$P,cafile=/c/ca.crt,commonname=arbiter-controller,cert=/c/leaf-proxy.crt,key=/c/leaf-proxy.key,verify=1 >/dev/null
sleep 1
n0=$(grep -c '^ACCEPT' "$LOG")
# 1) 300 sequential short connections
s=$(date +%s.%N); ok=0
for i in $(seq 1 300); do if (exec 3<>/dev/tcp/127.0.0.1/$L; read -t3 -u3 l; [ -n "$l" ]); then ok=$((ok+1)); fi; done
e=$(date +%s.%N); echo "sequential: 300 connections, $ok replied, $(echo "($e - $s) * 1000 / 300" | bc -l | cut -c1-5) ms each (full TLS handshake each)"
# 2) 100 concurrent x 5 waves
s=$(date +%s.%N); : > /tmp/arb-k3-ok.$$
for w in 1 2 3 4 5; do for i in $(seq 1 100); do ( (exec 3<>/dev/tcp/127.0.0.1/$L; read -t8 -u3 l; [ -n "$l" ] && echo y >> /tmp/arb-k3-ok.$$) ) & done; wait; done
e=$(date +%s.%N); echo "concurrent: 500 connections in waves of 100, $(wc -l < /tmp/arb-k3-ok.$$) replied, wall $(echo "$e - $s" | bc -l | cut -c1-5) s"; rm -f /tmp/arb-k3-ok.$$
# 3) bulk: 200 MiB through one connection
s=$(date +%s.%N); head -c 209715200 /dev/zero | socat -u - TCP:127.0.0.1:$L; sleep 2; e=$(date +%s.%N)
echo "bulk: 200 MiB in $(echo "$e - $s - 2" | bc -l | cut -c1-5) s => $(echo "200 / ($e - $s - 2)" | bc -l | cut -c1-6) MiB/s; server saw: $(grep '^BYTES' "$LOG" | sort -t' ' -k2 -n | tail -1)"
echo "socat container CPU/mem: $(podman stats --no-stream --format '{{.CPUPerc}} cpu {{.MemUsage}}' arb-k3-socat)"
echo "server ACCEPTs added: $(( $(grep -c '^ACCEPT' "$LOG") - n0 ))"
podman rm -f arb-k3-socat >/dev/null
