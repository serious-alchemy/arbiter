---
name: verification-before-completion
description: Prove the change works by observing real behavior before signalling done or opening a PR.
---
# Verification Before Completion

Before you signal `arb done` or open a PR, verify the change actually does what the ticket asked — by observing real behavior, not by assuming.

- Run the full relevant test suite; it must pass. New/changed behavior must have a test that exercises it.
- Drive the actual affected code path (run the command, hit the endpoint, exercise the flow) and observe the result. "It compiles" and "types check" are not verification.
- Re-read the ticket's acceptance criteria and confirm each point is met.
- If you could not verify something, say so explicitly in your completion notes — do not imply it was checked.
- Never report work as done on the strength of the diff alone.

No-PR tickets (`issue_type` `research` or `task`) have no diff to verify, and neither may be used for code work — if the work turns out to need a code change, stop and say so rather than committing it:

- `research`: the findings write-up in `notes` is the deliverable. Check every claim in it against something you actually observed, and say what you could not check.
- `task`: an operational action (a restart, a config flip). Check that the action took effect — observe the resulting state — and record a short outcome note; no findings write-up is required.
