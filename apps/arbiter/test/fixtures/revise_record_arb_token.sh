#!/bin/sh
# Fixture (bd-asawcq): a ReviewGate implementer that records the ARB_TOKEN it
# was handed — its own `arb` must authenticate as the task it revises — then
# commits a fix like `revise_commit.sh`. Never invokes the paid CLI.
git_dir="$(git rev-parse --git-common-dir)"
printf '%s' "${ARB_TOKEN:-<unset>}" > "$git_dir/implementer_arb_token"
echo "anchored guard" >> guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1" >/dev/null 2>&1
echo "FIXED: anchored the match in guard.txt:1"
echo "arb done"
exit 0
