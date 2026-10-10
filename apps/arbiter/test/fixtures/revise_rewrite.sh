#!/bin/sh
# Fixture: an IMPLEMENTER worker that REWRITES history in the CWD (the
# ReviewGate worktree) instead of adding a commit on top — what a podman fix
# round does when it rebases its branch onto current main (bd-4axlg0). It
# amends the branch's tip with new content, so the new head is neither a
# descendant of the pushed head nor patch-equivalent to it. Never pushes (a
# container has no credential) and never invokes the paid CLI.
echo "implementer: rewriting the branch tip"
echo "rewritten while addressing F1.1" >> guard.txt
git add guard.txt >/dev/null 2>&1
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q --amend -m "feature work (rewritten)" >/dev/null 2>&1
echo "FIXED: anchored the match in guard.txt:1"
echo "arb done"
exit 0
