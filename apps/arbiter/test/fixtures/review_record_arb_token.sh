#!/bin/sh
# Fixture (bd-asawcq): a ReviewGate reviewer that records whether it was handed
# an ARB_TOKEN, then rejects its first pass and approves every later one.
# Paired with `revise_record_arb_token.sh`. State lives in `.git` so it never
# shows up in `git status --porcelain`. Never invokes the paid CLI.
git_dir="$(git rev-parse --git-common-dir)"
printf '%s' "${ARB_TOKEN:-<unset>}" > "$git_dir/reviewer_arb_token"
counter_file="$git_dir/review_record_arb_token_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

if [ "$pass" -le 1 ]; then
  echo "VERDICT: REQUEST_CHANGES"
  echo "findings: [high] guard.txt:1 needs another pass"
else
  echo "VERDICT: APPROVE"
  echo "DISPOSITIONS:"
  echo "- [ADDRESSED] F1.1 — anchored in guard.txt:1"
  echo "findings: none"
fi
echo "arb done"
exit 0
