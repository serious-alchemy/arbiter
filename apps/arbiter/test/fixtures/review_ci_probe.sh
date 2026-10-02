#!/bin/sh
# Fixture: a reviewer (ReviewGate) worker for the CI-gated review tests
# (bd-cut6uv). It counts its own passes in the COMMON git dir (a reviewer runs in
# its round's own linked checkout, so that is the one place a test can read) and
# answers by mode:
#
#   $1 — APPROVE (default): approve.
#        RC_SUITE: REQUEST_CHANGES with a finding, disclosing
#                  `VERIFICATION: PARTIAL` only because the full suite was not run.
#        RC_OTHER: REQUEST_CHANGES with a finding, disclosing PARTIAL for
#                  something else it could not confirm (while also skipping the suite).
#        HOLD:     record the pass, then stay alive without a verdict, so a test can
#                  read the gate's state (the prompt it dispatched) mid-round.
#
# Stands in for a real `claude --print` reviewer; never invokes the paid CLI.
mode="${1:-APPROVE}"
common="$(git rev-parse --path-format=absolute --git-common-dir)"
n=0
[ -f "$common/review_ci_passes" ] && n="$(cat "$common/review_ci_passes")"
echo $((n + 1)) > "$common/review_ci_passes"
git rev-parse HEAD > "$common/review_ci_reviewed_head"

echo "reviewing the diff (pass $((n + 1)))"
case "$mode" in
  HOLD)
    sleep 120
    ;;
  RC_SUITE)
    echo "VERDICT: REQUEST_CHANGES"
    echo "- **Medium**: feature.txt:1 is missing a guard."
    echo "  Suggested fix: add the guard."
    echo "VERIFICATION: PARTIAL — did not run the full test suite (CI is green on this SHA)"
    ;;
  RC_OTHER)
    echo "VERDICT: REQUEST_CHANGES"
    echo "- **Medium**: feature.txt:1 is missing a guard."
    echo "  Suggested fix: add the guard."
    echo "VERIFICATION: PARTIAL — did not run the full test suite and could not confirm the migration"
    ;;
  *)
    echo "VERDICT: APPROVE"
    echo "VERIFICATION: FULL"
    ;;
esac
echo "arb done"
exit 0
