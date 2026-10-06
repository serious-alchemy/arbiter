#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv): does sharding runs over K WebSockets (instead of one) fix
# the loss-induced p99 on the SSE replay? One socket vs 5 vs 10 at the lossy points
# from run_matrix_followup.sh. Run from apps/arbiter_web with SPIKE_RESULTS_FILE set.
set -uo pipefail
: "${SPIKE_RESULTS_FILE:?set SPIKE_RESULTS_FILE}"
export MIX_ENV=test
here=$(cd "$(dirname "$0")" && pwd)
file=test/spike/bridge_mux_test.exs
sse_line=$(grep -n 'test "U3: SSE replay' "$file" | head -1 | cut -d: -f1)

for point in "150 0.5" "150 0.1" "80 0.5"; do
  set -- $point
  for k in 1 5 10; do
    echo "=== sockets=$k rtt=$1 loss=$2%" >&2
    SPIKE_SOCKETS=$k SPIKE_LABEL="sockets=$k rtt=$1ms rate=20mbit loss=$2%" "$here/run_netem.sh" "$1" 20mbit "$2" -- \
      mix test --include spike_rw "$file:$sse_line" 2>&1 | grep -E "tests,|\*\* \(" >&2
  done
done
echo "shard done" >&2
