#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U19: the CONNECT-relay scenario matrix, 3 at a time, each in its own netns.
here=$(cd "$(dirname "$0")" && pwd)
export U19_WORK=${U19_WORK:-${TMPDIR:-/tmp}/rw2-u19}
mkdir -p "$U19_WORK"
printf '%s\n' "c_refuse30 refuse 30" "c_reset30 reset 30" "c_stall30 stall 30" "c_stall60 stall 60" \
  "c_stalldrop30 stall_then_drop 30" "c_cut5 cut 5 3" "c_refuse90 refuse 90" "c_reset90 reset 90" "c_stall90 stall 90" \
  | xargs -P "${U19_PARALLEL:-3}" -L 1 bash -c 'unshare --user --map-root-user --net bash -c "ip link set lo up; $0 $1 $2 $3 ${4:-0}"' "$here/scenario_connect.sh"
