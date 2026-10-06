#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv): the U3/U4 measurement matrix. Appends one JSON line per
# scenario to $SPIKE_RESULTS_FILE. Run from apps/arbiter_web:
#   SPIKE_RESULTS_FILE=/path/results.jsonl test/spike/run_matrix.sh
set -uo pipefail
: "${SPIKE_RESULTS_FILE:?set SPIKE_RESULTS_FILE}"
export MIX_ENV=test
test_cmd=(mix test --include spike_rw test/spike/bridge_mux_test.exs)
here=$(cd "$(dirname "$0")" && pwd)

run() { # label rtt rate [loss]
  local label=$1 rtt=$2 rate=$3 loss=${4:-0}
  echo "=== $label rtt=${rtt}ms rate=$rate loss=${loss}%" >&2
  SPIKE_LABEL="$label rtt=${rtt}ms rate=$rate loss=${loss}%" \
    "$here/run_netem.sh" "$rtt" "$rate" "$loss" -- "${test_cmd[@]}" 2>&1 | grep -E "tests,|failure|\*\* \(" >&2
}

# no shaping at all (plain loopback), then the shaped links
SPIKE_LABEL="loopback" "${test_cmd[@]}" 2>&1 | grep -E "tests," >&2
run lan 2 none
run tailnet-direct 20 100mbit
run tailnet-wan 80 20mbit
run derp-relay 150 10mbit 0.5
run weak-uplink 150 2mbit
run cellular 250 1mbit 1
echo "matrix done" >&2
