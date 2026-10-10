#!/bin/sh
# Fixture: a ReviewGate reviewer that REQUEST_CHANGES on its first pass and APPROVEs
# on its second iff the head it is reading is the forge's head of `<branch>` (asked of the remote itself: a private review clone has no `origin/<branch>` tracking ref) (bd-bg87oz).
#
# `review_push_check.sh`'s ROUND2 mode keeps its round marker in the checkout's common
# git dir, which is shared between rounds only when each round's checkout is a linked
# worktree. When the author's tree is a private clone (the layout a container fix round
# runs in) every round's checkout is its own clone, so the marker here lives outside
# every checkout.
#
#   $1 — the round marker (absolute path, outside every checkout).
#   $2 — the branch to compare `origin/<branch>` against.
#
# Stands in for a real `claude --print` reviewer; never invokes the paid CLI.
marker="$1"
branch="${2:-main}"

if [ ! -f "$marker" ]; then
  : > "$marker"
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **Medium**: the over-match guard is missing (guard.txt:1)."
  echo "  Suggested fix: anchor the match instead of using a bare contains check."
  echo "VERIFICATION: FULL"
  echo "arb done"
  exit 0
fi

local_head="$(git rev-parse HEAD 2>/dev/null)"
remote_head="$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)"

if [ -n "$remote_head" ] && [ "$local_head" = "$remote_head" ]; then
  echo "VERDICT: APPROVE"
  echo "DISPOSITIONS:"
  echo "- [ADDRESSED] F1.1 — the guard now lands in guard.txt:1"
else
  echo "VERDICT: REQUEST_CHANGES"
  echo "- **High**: UNPUSHED-HEAD — this pass read $local_head, which is not on origin/$branch ($remote_head)."
fi
echo "VERIFICATION: FULL"
echo "arb done"
exit 0
