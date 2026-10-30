#!/bin/sh
# Fixture: an IMPLEMENTER that commits guard.txt (like revise_commit.sh) and, while it
# works, a sibling ticket lands a conflicting guard.txt on origin's target branch.
#   $1 — target branch name on origin (default main)
# The next review round therefore starts on a head that conflicts with the target.
target="${1:-main}"
origin_url="$(git remote get-url origin)"
echo "implementer: addressing the reviewer's findings on this branch"
echo "branch version" > guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q -m "address reviewer finding F1.1" >/dev/null 2>&1
other="$(mktemp -d)"
git clone -q "$origin_url" "$other/c" >/dev/null 2>&1
echo "target version" > "$other/c/guard.txt"
git -C "$other/c" add guard.txt >/dev/null 2>&1
git -C "$other/c" -c user.email=o@example.com -c user.name=O commit -q -m "sibling lands guard.txt" >/dev/null 2>&1
git -C "$other/c" push -q origin "HEAD:$target" >/dev/null 2>&1
rm -rf "$other"
echo "FIXED: anchored the match in guard.txt:1"
echo "arb done"
exit 0
