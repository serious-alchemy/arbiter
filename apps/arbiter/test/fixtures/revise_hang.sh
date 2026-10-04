#!/bin/sh
# Fixture: an IMPLEMENTER worker for the revise-and-rediscuss loop that never
# finishes: it announces itself and sleeps, so a test can take the node down
# while a fix round is running (bd-2yt0d2). Never invokes the paid CLI.
echo "implementer: working on the reviewer's findings..."
sleep 120
exit 0
