#!/bin/sh
# Fixture: an IMPLEMENTER worker that edits a file without committing it and then
# hangs, so the gate's per-pass timeout fires with uncommitted changes.
echo "implementer: addressing the reviewer's findings"
echo "uncommitted guard" > dirty.txt
sleep 30
echo "arb done"
exit 0
