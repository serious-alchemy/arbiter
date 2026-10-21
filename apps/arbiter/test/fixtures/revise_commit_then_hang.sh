#!/bin/sh
# Fixture: an IMPLEMENTER worker whose FIRST pass commits a real fix and then
# hangs (as a worker stuck in a full `mix test` does), so the gate's per-pass
# timeout fires with a clean worktree and a commit ahead of the last reviewed
# head. Every later pass commits and exits immediately. A counter kept in `.git`
# tells the passes apart.
git_dir="$(git rev-parse --git-dir)"
counter_file="$git_dir/revise_commit_then_hang_pass"
pass=0
[ -f "$counter_file" ] && pass="$(cat "$counter_file")"
pass=$((pass + 1))
echo "$pass" > "$counter_file"

echo "implementer: addressing the reviewer's findings (pass $pass)"
echo "anchored guard (pass $pass)" >> guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1 (pass $pass)" >/dev/null 2>&1

if [ "$pass" -eq 1 ]; then
  sleep 30
fi
echo "arb done"
exit 0
