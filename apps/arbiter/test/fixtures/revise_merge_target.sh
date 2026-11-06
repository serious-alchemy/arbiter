#!/bin/sh
# Fixture: a conflict-resolve IMPLEMENTER pass. Merges origin/main into the
# current branch, resolving every conflict in the branch's favour (-X ours),
# and commits the merge. Never invokes the paid CLI.
echo "implementer: merging origin/main into the branch"
git fetch -q origin >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  merge -q -X ours --no-edit origin/main >/dev/null 2>&1
echo "arb done"
exit 0
