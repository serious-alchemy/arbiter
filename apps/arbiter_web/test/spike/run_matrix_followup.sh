#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv): follow-up sweeps after run_matrix.sh showed (a) SSE p99
# blowing up on lossy links and (b) heartbeat queueing at low uplink rates:
#   1. loss sweep (SSE + setup only) at three RTTs,
#   2. the per-node in-flight cap (design: 1 MiB) at 2 Mbit/s and 10 Mbit/s.
# Run from apps/arbiter_web with SPIKE_RESULTS_FILE set.
set -uo pipefail
: "${SPIKE_RESULTS_FILE:?set SPIKE_RESULTS_FILE}"
export MIX_ENV=test
here=$(cd "$(dirname "$0")" && pwd)
file=test/spike/bridge_mux_test.exs
line() { grep -n "$1" "$file" | head -1 | cut -d: -f1; }
sse_line=$(line 'test "U3: SSE replay')
u4_lines=$(grep -n 'test "U4:' "$file" | cut -d: -f1 | tr '\n' ' ')

sse_only() { # label rtt rate loss
  echo "=== $1 rtt=$2 rate=$3 loss=$4%" >&2
  SPIKE_LABEL="$1 rtt=$2ms rate=$3 loss=$4%" "$here/run_netem.sh" "$2" "$3" "$4" -- \
    mix test --include spike_rw "$file:$sse_line" 2>&1 | grep -E "tests,|\*\* \(" >&2
}

if [[ -z "${SKIP_LOSS_SWEEP:-}" ]]; then
  for rtt in 20 80 150; do
    for loss in 0 0.1 0.5; do
      sse_only "loss-sweep" "$rtt" 20mbit "$loss"
    done
  done
fi

for cap in ${CAPS:-1048576 262144 131072 65536}; do
  for rate in 2mbit 10mbit; do
    echo "=== cap=$cap rtt=150 rate=$rate" >&2
    SPIKE_NODE_CAP=$cap SPIKE_LABEL="cap=$cap rtt=150ms rate=$rate" "$here/run_netem.sh" 150 "$rate" 0 -- \
      mix test --include spike_rw $(for l in $u4_lines; do printf '%s:%s ' "$file" "$l"; done) 2>&1 | grep -E "tests,|\*\* \(" >&2
  done
done
echo "followup done" >&2
