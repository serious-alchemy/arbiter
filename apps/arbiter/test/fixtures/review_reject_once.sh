#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker for the server-restart tests
# (bd-2yt0d2). REQUEST_CHANGES on its first pass, APPROVE on every later one.
# The pass counter lives in the COMMON git dir (a reviewer runs in its round's
# own linked checkout), so it survives the reviewer being killed and re-run.
# Never invokes the paid CLI.
common="$(git rev-parse --path-format=absolute --git-common-dir)"
counter_file="$common/review_reject_once_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

if [ "$pass" -le 1 ]; then
  echo "reviewing pass $pass: rejecting"
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] guard.txt:1 needs a guard"
  echo "arb done"
else
  echo "reviewing pass $pass: approving"
  echo "VERDICT: APPROVE"
  echo "DISPOSITIONS:"
  echo "- [ADDRESSED] F1.1 — guard added in guard.txt:1"
  echo "findings: none"
  echo "arb done"
fi
exit 0
