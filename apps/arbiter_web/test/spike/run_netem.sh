#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv): run a command inside a private user+net namespace whose
# loopback is shaped with `tc netem` (+ an optional `tbf` rate cap), so WebSocket
# traffic to a Bandit listener on 127.0.0.1 sees a configurable RTT and uplink.
# Nothing outside the namespace is touched; no sudo.
#
#   run_netem.sh <rtt_ms> <rate|none> [loss_pct] -- <command...>
#
# `rtt_ms` is the round trip (netem delay is applied per packet, so each
# direction gets rtt/2). `rate` is a tc rate such as 20mbit. Needs `unshare` and
# `tc` (iproute2).
set -euo pipefail
rtt=${1:?rtt_ms}
rate=${2:?rate|none}
shift 2
loss=0
if [[ "${1:-}" != "--" ]]; then
  loss=$1
  shift
fi
[[ "${1:-}" == "--" ]] && shift

half=$(awk -v r="$rtt" 'BEGIN{printf "%.1f", r/2}')
# tbf needs burst >= rate/HZ (HZ=250) to reach the rate, and never less than a few packets.
burst=15000
if [[ "$rate" != none ]]; then
  burst=$(awk -v r="$rate" 'BEGIN{
    n = r + 0; u = tolower(r); sub(/^[0-9.]+/, "", u)
    m = (u == "kbit") ? 1e3 : (u == "mbit") ? 1e6 : (u == "gbit") ? 1e9 : 1
    b = int(n * m / 8 / 100); if (b < 15000) b = 15000; print b }')
fi

export NETEM_HALF_MS=$half NETEM_LOSS=$loss NETEM_RATE=$rate NETEM_BURST=$burst
exec unshare --user --map-root-user --net bash -c '
set -euo pipefail
ip link set lo up
# lo defaults to MTU 65536: GSO super-packets exceed any tbf burst and are dropped,
# and no real path has a 64 KiB MTU. 1500 is what ethernet/tailnet looks like.
ip link set dev lo mtu 1500
args=(root handle 1: netem delay "${NETEM_HALF_MS}ms")
[[ "$NETEM_LOSS" != 0 ]] && args+=(loss "${NETEM_LOSS}%")
tc qdisc add dev lo "${args[@]}"
if [[ "$NETEM_RATE" != none ]]; then
  tc qdisc add dev lo parent 1:1 handle 10: tbf rate "$NETEM_RATE" burst "$NETEM_BURST" latency 500ms
fi
tc qdisc show dev lo >&2
exec "$@"
' bash "$@"
