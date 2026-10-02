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
- `user` / `feedback` / `reference`: Behavioural and stable, or not subject to automated repo-level staleness checks.
- `project`: Verified against the bound workspace's current commit SHA.
  - When promoted, the memory's frontmatter is updated with `verified_sha: <current-commit-sha>`.
  - **file:line citations**: Verified by checking if the file exists and if the line number is within the file's bounds.
  - **Module names**: Verified by checking if the module is still defined in the project.

**Checking Mechanism:**
- The staleness checker runs during `Memory.mount/2` and filters out memories of type `project` that fail verification against the workspace. They are simply not served to the session.
- An explicit checker sweep can be run to permanently quarantine stale memories.

## 3. Quarantine UX

When a memory fails verification (is unresolvable), it is filtered out of `mount/2` and **not served**. 
When an explicit sweep is run:
- It is moved to a `quarantined/` directory within `memory_root`.
- The quarantine reason and the SHA at which it was quarantined are recorded directly in the file's frontmatter.
- **Operator UX**:
  - The operator can manually view quarantined memories in the `quarantined/` directory to review the recorded reason (e.g., "Stale citations found during sweep").
  - They can then manually update the memory to match the new codebase state and move it back to the shared layer to unquarantine it, or permanently delete it.
