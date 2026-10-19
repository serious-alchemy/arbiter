#!/bin/sh
# Fixture: the #925 shape — a reviewer that raises a Medium finding in round 1,
# then APPROVEs without a DISPOSITIONS block in round 2 AND in the verdict
# re-prompt (the budget is 1), so the gate's targeted disposition check is the
# fourth pass. Passes are told apart by a counter kept in `.git`.
#
#   $1 — what the fourth (targeted check) pass answers:
#        "ADDRESSED" — `F1.1: ADDRESSED guard.txt:1 …`
#        "OPEN"      — `F1.1: OPEN …`
#        "SILENT"    — no per-id answer at all
counter="$(git rev-parse --git-common-dir)/review_disposition_check_pass"
n=$(cat "$counter" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$counter"

case "$n" in
  1)
    echo "VERDICT: REQUEST_CHANGES"
    echo "- **Medium**: the over-match guard is missing (guard.txt:1)."
    echo "VERIFICATION: FULL"
    ;;
  2|3)
    echo "VERDICT: APPROVE"
    echo "The change looks good; no issues found."
    echo "VERIFICATION: FULL"
    ;;
  *)
    case "${1:-ADDRESSED}" in
      ADDRESSED) echo "F1.1: ADDRESSED guard.txt:1 now anchors the match" ;;
      OPEN) echo "F1.1: OPEN guard.txt:1 still uses a bare contains check" ;;
      *) echo "I looked at the diff and it seems fine." ;;
    esac
    ;;
esac
echo "arb done"
exit 0
