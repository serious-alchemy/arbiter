#!/bin/sh
# Fixture: an IMPLEMENTER worker whose fix round only AMENDS the tip commit's
# message (same tree, new SHA) in the CWD and never pushes — the bd-9ahwai
# incident shape: "I did not push, because the host pushes after arb done".
# Never invokes the paid CLI.
echo "implementer: amending the commit message"
git -c user.email=fixture@example.com -c user.name=Fixture \
  commit -q --amend -m "feature work (amended message)" >/dev/null 2>&1
echo "FIXED: documented the release notes in the commit message"
echo "arb done"
exit 0
