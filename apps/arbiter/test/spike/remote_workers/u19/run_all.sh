#!/usr/bin/env bash
# RW2 spike (bd-6tx1xv) U19: the scenario matrix, 3 at a time, each in its own netns.
here=$(cd "$(dirname "$0")" && pwd)
export U19_WORK=${U19_WORK:-${TMPDIR:-/tmp}/rw2-u19}
printf '%s\n' "refuse30 refuse 30" "refuse60 refuse 60" "refuse90 refuse 90" "reset30 reset 30" "reset60 reset 60" \
  "reset90 reset 90" "stall30 stall 30" "stall60 stall 60" "stall120 stall 120" \
  "stalldrop30 stall_then_drop 30" "stalldrop60 stall_then_drop 60" "cut5 cut 5 3" \
  | xargs -P "${U19_PARALLEL:-3}" -L 1 bash -c 'unshare --user --map-root-user --net bash -c "ip link set lo up; $0 $1 $2 $3 ${4:-0}"' "$here/scenario.sh"
