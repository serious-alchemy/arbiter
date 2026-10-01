#!/bin/sh
# Fixture: a Codex reviewer whose CLI rejects its `-m` model before any work —
# the 400 a ChatGPT account returns for a model it cannot use (bd-2s755v).
# A re-prompt sends the same model and is rejected identically, so the
# ReviewGate must escalate with the real reason instead of re-prompting.
echo "⚠ codex turn failed: The 'gpt-5.4-mini' model is not supported when using Codex with a ChatGPT account."
exit 1
