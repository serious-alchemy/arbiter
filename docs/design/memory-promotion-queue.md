# Memory promotion queue and staleness checker

Phase 13 of `docs/browser-hosted-coordinator-sessions.md` (§9.4, §13 row 13),
ticket bd-19qve3.

**Sign-off.** The coordinator's design review (direction 9acea48a,
2026-10-02 04:01Z) approved the shape with seven amendments. The operator
ruled on 2026-10-02 that this review is the operator sign-off. This document
describes the design as built. Each amendment is marked **[A1]**–**[A7]**
where it applies, and §8 maps each one to its code and tests.

The operator's ranking drives every choice below: **serving a stale memory is
the worst failure.** So when the system is unsure, it withholds a memory
rather than serving it, and it never quarantines a memory unless the evidence
is definite.

## 1. Pieces

| Module | Role |
|---|---|
| `Arbiter.Sessions.Memory.Promotion` | The queue: list, diff, promote, reject candidates |
| `Arbiter.Sessions.Memory.Staleness` | Verifies a memory's pointers and returns a verdict. Pure judgement: it moves nothing |
| `Arbiter.Sessions.Memory.Checker` | Background process that runs the checks off the mount path, stores verdicts and quarantines stale memories |
| `Arbiter.Sessions.Memory.Verdicts` | One persisted verdict per shared memory |
| `Arbiter.Sessions.Memory.Quarantine` | Quarantine by directory move; list; restore after re-verification |
| `Arbiter.Sessions.Memory` (phase 12) | `mount/2` serves only memories whose stored verdict allows it |
| `Arbiter.Sessions.Memory.Frontmatter`, `.Citations` | Frontmatter edits that keep string keys and the original layout; pointer extraction |
| `Arbiter.MCP.Tools.MemoryPending` | The six MCP tools (§6) |

On disk:

```
<sessions_root>/<session-id>/memory/candidates/*.md   a session's proposals (its only memory write space)
<sessions_root>/<session-id>/memory/rejected/*.md     rejected proposals, marked and kept
<memory_root>/*.md                                    the shared layer that sessions mount
<memory_root>/.verdicts/<name>.md.json                one stored verdict per shared memory
<memory_root>/quarantined/*.md                        quarantined memories (never mounted)
<memory_root>/.superseded/*.md                        shared memories replaced by an overwriting promotion
```

## 2. Promotion flow

A session writes candidates into its own `memory/candidates/`. A candidate
reaches the shared layer **only** through an explicit `memory_pending_apply`.
No timer, mount, session event or checker pass ever promotes anything.

1. **List** with `memory_pending_list`. It shows every candidate across
   sessions: its id (`<session-id>/<file>.md`), name, description, type,
   workspace, size, and whether it would replace an existing shared memory.
   `state: rejected` lists the audit trail instead.
2. **Diff** with `memory_pending_diff`. It returns the full content, a line
   diff against the shared memory the candidate would replace, and the
   verification promotion would run, so a refusal is visible before anyone
   applies.
3. **Apply** with `memory_pending_apply`. In order:
   - It refuses a candidate no mount could serve: a missing or unknown
     `metadata.type`, or a `project` memory with no `workspace_id`. It also
     refuses candidates over 64 KiB.
   - It strips every field promotion owns, at any nesting depth, from the
     candidate's own frontmatter. That covers provenance, `anchors`,
     `verified_sha`, and quarantine and rejection marks, so a session cannot
     vouch for itself.
   - It verifies the candidate against the current `HEAD` (§3), anchoring
     each `file:line` citation on the line it names now, and refuses the
     candidate if anything is stale.
   - **[A5]** It stamps provenance: `source_session`, `author_model`,
     `promoted_by`, `promoted_at`, plus `verified_sha` and `anchors`.
     `author_model` comes from what Arbiter recorded, not from the candidate:
     the newest model in the session's usage ledger, else the session's
     provider, else `unknown`.
   - It writes the memory atomically into `<memory_root>`, together with its
     verdict, so the next mount serves it without waiting for the checker. An
     existing memory of the same name is replaced only with
     `overwrite: true`, and the replaced copy is kept under `.superseded/`.
4. **Reject** with `memory_pending_reject`. A `reason` is required.
   **[A6] Rejecting marks the candidate and never deletes it.** The candidate
   moves to the session's `memory/rejected/`, stamped `rejected_at`,
   `rejected_by` and `rejection_reason`. A second rejection of the same file
   name is kept beside the first. There is no purge, because nothing needs
   one yet.

Candidates are addressed by id, never by path. Ids are matched against a
strict pattern and resolved under the sessions root, so `..`, extra path
segments, hidden files and non-`.md` names are refused. Only regular files
count as candidates. A symlink planted in a candidate directory is never
listed, read, diffed or promoted, because it could point at any file this user
can read.

**[A5] Who may write.** apply, reject and restore are privileged writes into
what every future session reads. All six tools are coordinator-tier in the
catalog, and the three writes additionally require a **plain** coordinator
token: one used by the coordinator itself or by the operator's tooling. A
browser-hosted session's token is coordinator-tier too
(`Arbiter.MCP.Scope.mint_session/2`) but carries a `session_id`, and the writes
refuse it, as they refuse worker and refine tokens (`RefinePolicy` denies all
six tools). Session tokens may still use the three read tools.

## 3. Verification rules

`Arbiter.Sessions.Memory.Staleness` extracts pointers from a memory's body and
`description`, then checks them according to the memory's type:

| Type | `file:line` | modules | ticket ids | URLs |
|---|---|---|---|---|
| `project`, `reference` (and untyped) | checked | checked | checked | listed as `unchecked` |
| `user`, `feedback` | checked | checked | not checked | not checked |

**[A7]** `user` and `feedback` are behavioural, so the rules that exist
because code rots do not apply to them: their verdicts never expire with age
(§4), and their ticket ids and URLs are not checked. A `file:line` or module
citation inside one is still a claim about code, so it is checked exactly like
any other.

**[A1] `file:line`: content anchors, not line bounds.** A check that "line N
exists" still passes after the code has moved. Instead, each citation gets an
**anchor**: the first 16 hex characters of the SHA-256 of the cited line, after
trimming. Promotion records anchors in the memory's frontmatter
(`anchors: "lib/foo.ex:12=3f2a9c1b7d4e8f60 …"`). A memory nobody promoted, such
as one the operator wrote by hand, gets anchored on its first successful check,
and the anchor is kept in its verdict (trust on first use).

The window is **the whole file**. The check passes if a line with the anchored
text appears anywhere in the file, and the verdict reports where the text is
now (`found_at`). Code that moved within a file therefore still supports the
memory's claim. A memory is quarantined only when the file is gone or the
anchored text is gone. A citation with no anchor yet is bounds-checked once,
when its anchor is established.

Files are read from the committed tree at the checkout's `HEAD`
(`git cat-file`), never from the working tree. A verdict therefore holds for
exactly the SHA it records, and an uncommitted file does not resolve.
Citations must be repo-relative paths with a directory component and an
extension. `host:port` forms, bare file names, URLs, absolute paths and `..`
paths are never treated as citations.

**Modules.** A dotted name counts as a citation only when the workspace owns
its namespace: either its root module is defined there (`defmodule Arbiter`),
or the cited name's parent is. Anything else, such as `Ecto.Changeset` or
`Mix.Project`, is a mention of a dependency. A repo that defines `Mix.Tasks.*`
does not thereby own `Mix`, and an indented, nested `defmodule Config` does
not make `Config` a namespace. An owned name must still be defined by
`defmodule` or `defprotocol` at `HEAD`. A nested definition resolves through
its parent, so `Short.Inner` resolves when `Short` defines `Inner`.

**[A2] Internal pointers only.** Ticket ids (`<workspace prefix>-<id>`, where
the id contains a digit) are checked against the ledger. URLs are listed as
`unchecked` and never fetched: the server makes no network call on a memory's
behalf, so a network failure can never quarantine a memory. A digitless id
(`bd-cyxzvq`) looks the same as a hyphenated word (`vs-code`), so it is not
treated as a ticket.

**Verdicts.** Each verdict records:

- `status`;
- every citation with its own status;
- the anchors;
- `checked_against`, a map of each checkout path to the `HEAD` SHA it was
  checked against (this is the "recorded SHA");
- `content_sha256`, the exact bytes judged;
- `checked_at`.

The status is one of:

- `stale`: a pointer definitively no longer resolves. That means the file is
  missing, the anchor text is gone, the line is out of range on first use, an
  owned module is undefined, or the ticket is missing.
- `unverified`: nothing resolved stale, but something could not be checked.
  Either no checkout could be resolved, for example because the workspace has
  no `repo_paths`, or a ledger lookup failed. This is not evidence of rot, so
  the memory is served and never quarantined.
- `ok`: every checked pointer resolved.

Checkouts come from the memory's `workspace_id` (that workspace's
`repo_paths`), or from every workspace's `repo_paths` when the memory has no
`workspace_id`. A citation resolves if it resolves in any of those checkouts.

## 4. When verification runs [A3]

**Verification never runs on the mount path.** `Memory.mount/2` reads the
stored verdict, `<memory_root>/.verdicts/<name>.md.json`, and serves a memory
only if that verdict was made for the memory's exact current bytes and is not
`stale`. A launch never runs git, never queries the ledger and never waits on
the checker. The cost is a window: if code changes, a memory stays served until
the checker's next pass.

`Arbiter.Sessions.Memory.Checker` runs a pass 30 s after boot and then every
15 minutes (`config :arbiter, :memory_checker`). A pass skips a memory whose
verdict is still **current**. A verdict is current while all of these hold:

- it is `ok`;
- it was made for the same bytes;
- every checkout it was made against is still at the same `HEAD`;
- for `project` and `reference` only, it is less than `max_age_ms` (24 h) old.

That last rule is how decay tracks type. `project` and `reference` memories
rot fast, so they are re-checked at least daily even when no checkout moved,
because a ticket or a workspace's repo list can change without a commit.
`user` and `feedback` verdicts last until their text, or the code their
citations name, changes. `unverified` verdicts are retried on every pass.

Without a current verdict, a memory is **withheld**, not served. That covers a
new memory, an edited one, and one that was never checked. When a mount meets
one, it sends the checker a debounced, non-blocking nudge, so the memory is
served from the next mount after its check, usually within seconds. A memory
whose verdict is `stale` is not served even before the checker moves it.

## 5. Quarantine [A4]

**There is one representation: a directory move.** The checker moves a stale
memory from `<memory_root>/<name>.md` to `<memory_root>/quarantined/<name>.md`.
It then inserts `quarantined_at`, `quarantined_from`, `quarantine_sha` and
`quarantine_reason` into the frontmatter, leaving every other line as it was
(nesting such as `metadata.type` is preserved). If the memory had only
first-use anchors, the checker also writes those anchors into the file, so a
restore is held to them. A name already in quarantine is never overwritten: a
second quarantine of the same name gets a suffix.

Why a move rather than a frontmatter `status:` flag:

- Sessions mount memories as symlinks. Moving the file breaks the link in
  every session that is already running, so the stale text becomes unreadable
  at once. A flag would keep serving it to those sessions until each one is
  re-provisioned.
- The mount reads only top-level `*.md` files, so a quarantined memory is
  excluded by its location. No parser or stored verdict has to get it right.
- The rename is atomic, so un-serving is one step. If writing the annotation
  fails afterwards, the memory is still not served.
- The checker moves only the bytes it judged. If an overwriting promotion
  replaced the file mid-pass, the move is skipped and the next pass checks the
  new bytes.

**Operator UX:**

- `memory_quarantine_list` shows each quarantined memory with its reason, the
  SHA it failed against, and when it was quarantined.
- `memory_quarantine_restore` **re-verifies the memory before it is served**.
  It removes the quarantine fields, runs the full check against the current
  `HEAD`, and refuses with the reasons while anything is still stale. On
  success it moves the memory back, stamps `restored_by` / `restored_at` /
  `verified_sha`, and writes a fresh verdict.
- When code changed under an anchored line, there are two ways to restore the
  memory. The operator can edit its citations (the file stays in
  `quarantined/` while they do). Or they can pass `reanchor: true`, which
  explicitly re-anchors every citation on the line it names now. Restore
  refuses to take a name that a live memory already holds.
- Moving a file back by hand is also safe: its bytes have no current verdict,
  so it is not served until the checker re-verifies it.

## 6. MCP tools

| Tool | Session token | Plain coordinator | Arguments |
|---|---|---|---|
| `memory_pending_list` | yes | yes | `state`: `pending` (default) or `rejected` |
| `memory_pending_diff` | yes | yes | `id` |
| `memory_pending_apply` | **refused** | yes | `id`, `overwrite` |
| `memory_pending_reject` | **refused** | yes | `id`, `reason` (required) |
| `memory_quarantine_list` | yes | yes | — |
| `memory_quarantine_restore` | **refused** | yes | `name`, `reanchor` |
| `memory_distill` (phase 14) | **refused** | yes | `session_id` (required), `max_bytes`, `from_turn`, `max_candidates`, `max_cost_usd` |

Worker and refine tokens can call none of them.

`memory_distill` (bd-avt4lt) fills the same queue from an ended session's
archived transcript (`Arbiter.Sessions.TranscriptDistillation`). It never
writes the shared layer, but it spends model budget and reads another session's
transcript, so a session token is refused. Its bounds can lower the configured
caps, never raise them.

## 7. Limitations (deliberate)

- **Weak anchors.** An anchor on a very common line, such as a blank line or
  `end`, still matches somewhere in almost any file. A duplicated line
  elsewhere in the file can likewise mask a deletion. The window is the whole
  file by design, so that moved code is not reported as stale.
- **Module ownership is a heuristic.** A nested definition with a dotted
  relative name, or a workspace whose root module is undefined and whose
  parent namespaces are undefined, gets less coverage. Missing coverage means
  `ok`, never a false quarantine.
- **Infrastructure claims are not verified.** Ports, hosts and services are
  not checked. Only internal pointers are verified (A2). A claim like "the
  server listens on 4848" relies on the age-based re-check and on human review
  at promotion time.
- **Windows.** If code changes, a memory can stay served until the next pass
  (at most the interval, 15 min). An overwritten memory is withheld until the
  next pass if a checker pass raced the promotion.
- **No web UI.** The precedent, `loop_pending_*`, is MCP-only, and so is this
  feature.

## 8. Amendments → implementation → tests

| | Amendment | Built in | Tested in |
|---|---|---|---|
| A1 | Content anchors; quarantine only when the file or anchor text is gone | `Staleness` (anchors, `found_at`), `Promotion` (records `anchors`) | `staleness_test.exs` "file:line citations are content-anchored", `quarantine_test.exs` re-anchor |
| A2 | Internal pointers only; URLs `unchecked`; no network | `Staleness.check_pointers/3`, `Citations` | `staleness_test.exs` "reference memories: internal pointers only", `citations_test.exs` |
| A3 | Async, periodic checker; persisted verdicts; mount reads only | `Checker`, `Verdicts`, `Memory.mount/2` | `checker_test.exs`, `verdicts_test.exs`, `memory_test.exs` "mount reads the stored verdict and never re-verifies" |
| A4 | One quarantine representation; never mounted; restore re-verifies | `Quarantine` | `quarantine_test.exs`, `checker_test.exs` |
| A5 | apply/reject/restore coordinator/operator only; provenance | `MemoryPending.authorize_write/1`, `RefinePolicy`, `Promotion.stamp/3` | `memory_tools_test.exs` "who may write the shared layer", `promotion_test.exs` provenance and author model |
| A6 | Reject marks, never deletes | `Promotion.reject/3` | `promotion_test.exs` "reject/3 (amendment 6)" |
| A7 | user/feedback exempt from decay, citations still checked | `Staleness` type table, `Checker` decay | `staleness_test.exs` "user and feedback memories", `checker_test.exs` decay |
