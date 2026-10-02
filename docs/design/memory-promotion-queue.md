# Memory Promotion Queue and Staleness Checker

## 1. Promotion Queue Flow
Candidate memories are written by sessions into `<sessions_root>/<session-id>/memory/candidates/*.md`. They are proposed for the shared layer but never reach it implicitly.
To handle these candidates, we will introduce a promotion queue modeled after the Loop UI:

- **`memory_pending_list`**: Lists all candidate memories across all sessions.
- **`memory_pending_diff`**: Shows the content of the candidate memory (or a diff if it modifies an existing shared memory).
- **`memory_pending_apply` (Promote)**: Moves the candidate from the session's candidate directory to the `memory_root` (the shared layer).
- **`memory_pending_reject`**: Deletes or marks the candidate as rejected.

These can be exposed as MCP tools (e.g. `memory_pending_list` etc.) analogous to `loop_pending_*`.

## 2. Staleness Checker and Verification Rules

Memories, especially of type `project` and `reference`, can rot quickly when they cite specific file lines, modules, or infrastructure.

**Verification Rules per Memory Type:**
- `user` / `feedback`: Behavioural and stable. Not subject to staleness checks (they do not rot).
- `project`: Verified against the bound workspace's current commit SHA.
  - When promoted, the memory's frontmatter is updated with `verified_sha: <current-commit-sha>`.
  - **file:line citations**: Verified by checking if the file exists and if the line number is within the file's bounds (or by checking if the cited symbol/context still exists in the file).
  - **Module names**: Verified by checking if the module is still defined in the project.
- `reference`: Verified by checking if the cited external URLs or infra pointers are reachable/resolve.

**Checking Mechanism:**
- The staleness checker runs asynchronously (or during `Memory.mount/2`) and verifies memories of type `project` against the workspace.
- If a citation no longer resolves (e.g., file deleted, line out of bounds, module renamed), the memory is deemed stale.

## 3. Quarantine UX

When a memory fails verification (is unresolvable), it is **quarantined, not served**:
- It will not be mounted into any session's `memory/shared/` directory.
- It will be moved to a `quarantined/` directory within `memory_root` (or marked with `status: quarantined` in its frontmatter).
- **Operator UX**:
  - The operator can view quarantined memories via a `memory_quarantine_list` tool.
  - The operator can review why it was quarantined (e.g., "File `lib/foo.ex` not found").
  - They can then either update the memory to match the new codebase state and unquarantine it (`memory_quarantine_restore`), or permanently delete it.
