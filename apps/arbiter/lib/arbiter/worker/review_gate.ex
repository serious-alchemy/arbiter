defmodule Arbiter.Worker.ReviewGate do
  @moduledoc """
  The review gate ("ReviewGate") that sits between an worker's `arb done` and the
  merger. A standing order: an worker must not merge its own work — a separate
  reviewer mind code-reviews the diff first.

  ## Where it fits

  When an worker signals done (`arb done`), the author `Arbiter.Worker` checks
  whether its workspace requires review (`Workspace.review_required?/1`). If so it
  waits on the review gate and spawns a ReviewGate **instead of** calling the
  merger. The ReviewGate then runs the review — and, on a request-changes verdict,
  the **revise-and-rediscuss loop** — and reports a single, terminal verdict back
  to the author (`Arbiter.Worker.review_gate_verdict/2`):

    * APPROVE → the author proceeds to the merger (`do_open_mr`).
    * REQUEST_CHANGES (after the loop is exhausted) / inconclusive / timed-out →
      the author parks the task with the findings and escalates to the coordinator;
      the branch is **not** merged.

  The verdict is terminal but the *author's* terminal state is not the last word:
  a gate whose later round converges to APPROVE after an earlier round already
  parked the author reports that approval to a worker sitting at `:failed`, and
  `Arbiter.Worker` reconciles the run forward rather than refusing it (bd-3wumco).
  A verdict that still lands nowhere is logged loudly by `report/2` — an orphaned
  review outcome must never be silent.

  ## The reviewer

  Each review pass spawns a **distinct** reviewer worker — a second
  `Arbiter.Worker` with a `#review`-suffixed task id and its own
  `Arbiter.Worker.ClaudeSession`. It does NOT run in the implementer's worktree:
  each review round provisions its own detached, throwaway checkout at the head
  `origin` carries after the push gate, and the reviewer runs there with
  Edit/Write/NotebookEdit denied (bd-a22hib — see `provision_review_checkout/1`).
  That SHA is what an APPROVE stamps as reviewed. A different
  process = a different Claude invocation = a different mind (no self-grading).
  It is handed the task's acceptance criteria + description and asked to review
  the branch diff for correctness / regressions, **without booting the app** (the
  second-instance hazard, bd-9rouwh — the reviewer only reads the diff). Its
  stdout is captured (via the worker output PubSub topic); from it the ReviewGate
  parses a structured verdict — a sentinel line `VERDICT: APPROVE` or
  `VERDICT: REQUEST_CHANGES` plus findings.

  ## Stage 2 — the revise-and-rediscuss loop (bd-3jm700)

  Stage 1 ran a single review pass and escalated immediately on a non-approve
  verdict. Stage 2 turns a REQUEST_CHANGES into a bounded conversation:

    1. The reviewer's structured findings are posted to the implementer **via the
       mailbox** (`Arbiter.Messages`, kind `:flag`, reviewer id → author task id)
       — a durable row, so the thread survives the workers that wrote it.
    2. A **fresh implementer** worker (a new mind, same branch/worktree)
       addresses each finding: fix it (and commit) or rebut it with
       justification. Its transcript is captured and posted back over the mailbox
       (author task id → reviewer id).
    3. The reviewer re-reviews the updated diff (its prompt carries the prior
       thread so it can accept each rebuttal or hold the line).

  The loop is **hard-capped** at `config["review"]["rounds"]` rounds (default 2;
  one round = one reviewer pass). If it has not converged on APPROVE after the
  cap, the ReviewGate **escalates to Darth Gnosis** — reporting a REQUEST_CHANGES
  whose findings are the FULL implementer↔reviewer transcript (every message,
  both directions, all rounds, in order), the unresolved findings, and the
  current diff. He judges with the complete argument in hand, not a summary.

  The reviewer must be a DIFFERENT mind than the author at every round, and each
  implementer revision is a fresh mind too.

  ## Reviewer commit gate and HEAD-SHA anchoring (bd-1mksks)

  Before spawning the reviewer (both on first review and on each re-review after a
  revise round), the ReviewGate verifies that the branch has at least one commit
  ahead of the target branch. If it does not, the ReviewGate escalates immediately as
  `REQUEST_CHANGES` rather than spawning a reviewer that would see an empty diff and
  conclude "no work was done." This is a second layer of defence on top of the
  worker commit gate (bd-ofql8k): the worker gate fires for the initial
  implementer, but the revise-round implementer worker has no `worktree_path` in
  its meta and therefore bypasses the worker gate.

  The current HEAD SHA is captured at reviewer-spawn time and embedded in the
  review prompt so the reviewer can verify it is on the correct commit before
  diffing. After each revise round, the ReviewGate checks whether HEAD advanced (new
  commits → reviewer sees an updated diff) or stayed the same (implementer only
  rebutted → reviewer evaluates the rebuttal). The observation is recorded in the
  in-memory thread (and therefore in the escalation payload and the re-review
  prompt) but is NOT persisted to the durable mailbox — it is ReviewGate
  bookkeeping, not part of the implementer↔reviewer conversation.

  ## Stage 3 — same-mind continuity (bd-1na62i)

  Literal session resume (`claude --resume <id>`) was dropped: session ids are
  transient, are invalidated by a billing pause or crash, and have no
  Gemini/agy equivalent — it violates the provider-agnostic constraint. Stage 3
  instead **approximates** continuity the way the `arb resume` path does
  (bd-auma3z): each revise-round implementer is briefed with the worktree's git
  state — commits since the branch cut plus uncommitted work-in-progress
  (`Arbiter.Worker.ResumeContext.work_so_far/2`) — prepended to its revise
  prompt. Combined with the reviewer findings and the original directive (both
  already in that prompt), the fresh mind continues the prior round's thread
  with full context rather than re-deriving it from a raw diff. The reviewer's
  own continuity is the prior implementer↔reviewer thread carried in
  `rereview_prompt/1`.

  ## Conflict-resolution review (bd-954ym8 / #134)

  Main moving under an approved PR forces a rebase or merge, and that head is
  not a new piece of work to judge. Before paying for a reviewer the gate asks
  `Arbiter.Reviews.ConflictResolution` what the head adds over a commit the PR
  already has coverage for, once the target branch's own changes are accounted
  for:

    * **clean integration** — covered by that approval with a `:mechanical`
      coverage row and the reviewed-SHA stamp, no round, reported as an APPROVE
      that names why;
    * **hand-resolved conflicts only** — a *scoped* round, recorded as
      `role: :conflict_review`, at the standard tier on a short timeout, shown
      just the conflicted regions (both sides and the resolution). The reviewer
      is chosen by the same cross-family routing as any pass, so it differs
      from the family that resolved. Its APPROVE covers the head like any other;
      a REQUEST_CHANGES goes through the ordinary revise loop and the fixed head
      is reviewed in full;
    * **anything else** (a hunk that is neither the target's nor inside a
      conflicted region, a fix commit, git unable to say) — the ordinary review.

  `Arbiter.Reviews.ConflictReview` counts all of it (`review_gate_rounds_list`
  reports the counts); `review_gate.conflict_review: false` turns the path off
  for a workspace.

  ## CI-gated review (bd-cut6uv / #228)

  With `review.require_ci_green` on — the default for a repo that merges through
  GitHub or GitLab (`Arbiter.Worker.ReviewCi`) — the gate does not pay for a
  reviewer until CI is green on the **exact head SHA** the reviewer is about to
  read, and the reviewer is told not to run the full suite. Every door to a
  reviewer goes through `ci_gate/2`:

    * `launch_first_reviewer/1` — the opening review, a scoped conflict review,
      and the first review of a fresh gate after a Worker fix round or a resume;
    * `dispatch_next_review/2` — every later round of this gate's revise loop and
      the restart on a head a third party pushed (`restart_on_remote_head/3`).

  A clean integration covered by an earlier approval dispatches no reviewer, so
  there is nothing for CI to gate. While it waits the gate is in phase
  `:awaiting_ci`: no agent is spawned (the author's own session is over), a poll is
  scheduled at the Watchdog's interval and bounded by the repo's
  `merge.watchdog_max_polls`, and the ticket carries a `ci_wait` marker the board,
  `arb ticket show` and the slot count read (`waiting on CI <sha>`, no slot).

    * green on the head — the reviewer is dispatched, its prompt carries the CI
      result, and a `VERIFICATION: PARTIAL` that is only about the full suite no
      longer triggers the `:partial_verification` re-prompt;
    * red — the failed jobs are re-run once; green on the re-run is a flake
      (recorded, no fix pass), red again opens the same implementer round a
      reviewer's REQUEST_CHANGES does, with the failing checks as findings, and
      the fix's new head waits for CI before the next review;
    * the branch gained a commit while waiting — the wait moves to the new head;
      a green on any other commit is never green;
    * CI never reports within the poll budget (or there is no PR, no CI, an
      unreadable forge) — the review runs as it did before, the reviewer runs the
      tests, and the reason is recorded on the thread and in the reviewer prompt.

  ## Verdict protocol

  The reviewer emits, on its own line:

      VERDICT: APPROVE
      VERDICT: REQUEST_CHANGES

  Case-insensitive; surrounding whitespace tolerated. Everything from the verdict
  line onward is captured as the findings.

  ## Verdict re-prompt (bd-8v8ays)

  A reviewer that produces a substantive review but simply *forgets* the sentinel
  line is a common, costly failure: the work is good but `:no_verdict` escalates
  it as inconclusive, wasting the whole pass. Before giving up, the ReviewGate
  **re-prompts for a verdict** within the same round: on a `:no_verdict` result
  it spawns one more minimal follow-up pass (a fresh reviewer + session — there
  is no live Claude session resume yet — that re-supplies the diff context but
  demands the sentinel). Only if that pass *also* yields no parseable verdict
  does the ReviewGate report `:no_verdict` and let the author escalate as
  inconclusive. The number of re-prompts is capped (default 1) via the
  `:verdict_retries` opt and is a **per-round budget** — it resets at the start
  of each new revise round so that a reprompt used in round N does not prevent a
  reprompt in round N+1.

  A timed-out or unspawnable reviewer is a different failure (a hung/crashed
  mind, not a forgotten sentinel) and still escalates directly without a
  re-prompt.

  The same re-prompt path also covers a **content-free REQUEST_CHANGES**
  (bd-3y2mda): a verdict that requests changes but lists no concrete findings is
  useless — the implementer has nothing to act on — so it is treated as malformed
  and re-prompted (the follow-up names exactly what was missing) rather than
  entering the revise loop empty-handed. If the re-prompt still yields no findings
  it escalates as inconclusive; it is never silently merged.

  ## Clean worker context (bd-3y2mda)

  Reviewer (and revise-implementer) workers are spawned with an isolated
  `CLAUDE_CONFIG_DIR` (`Arbiter.Agents.Claude.ConfigDir`) so the host operator's
  personal `~/.claude/CLAUDE.md` — which may carry a roleplay persona — cannot
  bleed into the review and crowd out structured findings.

  ## Testing

  `start/1` accepts a `:command` argv (the reviewer) and a `:revise_command` argv
  (the implementer), forwarded to `ClaudeSession`, so tests can spawn echo
  scripts that print canned verdicts / revisions instead of invoking real Claude.
  `parse_verdict/1` is a pure function and is unit-tested directly.
  """

  use GenServer
  require Logger

  alias Arbiter.Agents
  alias Arbiter.Agents.ProviderConstraint
  alias Arbiter.Agents.ProviderPool
  alias Arbiter.Agents.ProviderRouting
  alias Arbiter.Agents.ReviewerRouting
  alias Arbiter.Agents.Routing
  alias Arbiter.Agents.Routing.ByDifficulty
  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.CircuitBreaker
  alias Arbiter.Mergers.NetDiff
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Reviews.Checkout
  alias Arbiter.Reviews.ConflictResolution
  alias Arbiter.Reviews.ConflictReview
  alias Arbiter.Reviews.Coverage
  alias Arbiter.Reviews.PushState
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event, as: UsageEvent
  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.CoordinatorOnlyFindings
  alias Arbiter.Worker.Dispatch
  alias Arbiter.Worker.EvidenceIntegrity
  alias Arbiter.Worker.OutputLog
  alias Arbiter.Worker.PromptBuilder
  alias Arbiter.Worker.ResumeContext
  alias Arbiter.Worker.ReviewCi
  alias Arbiter.Worker.ReviewFindings
  alias Arbiter.Worker.ReviewPass
  alias Arbiter.Worker.ReviewVerification
  alias Arbiter.Worker.RunProvenance
  alias Arbiter.Worker.SeedPaths
  alias Arbiter.Worker.StopReason
  alias Arbiter.Worker.Worktree
  alias Arbiter.Workers.Run

  # Default ceiling on how long we wait for a reviewer / implementer pass before
  # escalating as timed out. Real Claude work can take a while; tests override.
  @default_timeout_ms 20 * 60 * 1000

  # How many times we re-prompt for a verdict when a reviewer finishes without
  # one before escalating as inconclusive. Capped; default 1. See bd-8v8ays.
  @default_verdict_retries 1

  # How many times a reviewing pass that hits the timeout ceiling is retried with
  # a FRESH reviewer mind before escalating as timed-out. A hung / overloaded
  # model session is usually transient API variance (rate limiting, model
  # overload) rather than a code problem, so a clean second attempt often
  # converges where the first stalled (bd-78vg4v, investigate #2/#3). Per-
  # ReviewGate budget; default 1. Only the reviewing phase is retried — a
  # revising (implementer) pass still escalates directly on timeout.
  @default_timeout_retries 1

  # Cap on the implementer transcript recorded into the thread and re-embedded
  # into every round-2+ re-review prompt (`rereview_prompt/1`). Left uncapped, a
  # real implementer's full stdout — every file read, tool-call narration, and
  # test run — ballooned the round-2 reviewer prompt far past round-1's (which
  # carries no thread at all), which was the dominant cause of round-2 timeouts
  # and no-parseable-verdict failures (bd-78vg4v, investigate #1). Every other
  # value fed into a prompt/payload is already capped (diff, worktree status,
  # subject); this transcript was the lone exception. The implementer's
  # actionable FIX/REBUT conclusions land at the END of its output, so
  # `cap_transcript/2` keeps the head AND the tail and elides only the middle.
  @transcript_cap_bytes 16_000

  # Default revise-and-rediscuss round cap when no difficulty is available and
  # no workspace override is set — matches D2 (moderate). See bd-3jm700.
  @default_rounds 3

  # Difficulty → default round cap. D0/D1 are straightforward; D3/D4/D5 are
  # architecturally significant and may need more back-and-forth to converge.
  # #1519: D5 needs its own entry — an unmapped difficulty falls back to
  # @default_rounds (3), which would have given the top of the scale FEWER
  # rounds than D3.
  @rounds_by_difficulty %{0 => 2, 1 => 2, 2 => 3, 3 => 4, 4 => 4, 5 => 4}

  # bd-3xultf: how many tiers above the task's own tier the reviewer is
  # routed by default (capped at "premium" by `ByDifficulty.bump_tier/2`).
  # Overridable per-workspace via `review_agent.config.tier_offset`; 0
  # restores a fixed (same-tier) reviewer — the rollback knob if a moving
  # judge invalidates the before/after convergence comparison (#1011).
  @default_reviewer_tier_offset 1

  # Defensive cap on the escalation diff so a huge branch can't bloat the
  # coordinator's mailbox row beyond reason.
  @diff_cap_bytes 50_000

  # bd-2eyf9y: the revise-round commit gate. Both escalation messages below
  # start with one of these exact sentences so `Worker.escalate_review_gate/3`
  # can give each a mailbox subject distinct from the generic "review
  # inconclusive" wording, without adding a new verdict shape (both still
  # report as `{:no_verdict, message}` — see `escalate_commit_gate/2`).
  @commit_gate_uncommitted_marker "ReviewGate fix round: implementer left uncommitted work"
  @commit_gate_no_changes_marker "ReviewGate fix round: fix round produced no changes"

  # bd-cb7wpq: the literal line an implementer prints (see `revise_prompt/2`)
  # to declare a finding resolved through something other than a file change
  # on this branch — a PR title/description edit, a label, a comment reply.
  # HEAD not moving is otherwise indistinguishable from a worker that did
  # nothing; this marker is the one thing `commit_gate_outcome/3` trusts to
  # tell the two apart, and even then only for ONE round in a row (see
  # `non_file_fix_used`) — a false claim is still caught because the very next
  # reviewer round re-checks the live PR for real, exactly as it would any
  # other REQUEST_CHANGES disposition.
  @non_file_fix_marker "NO-FILE-CHANGE:"

  # StopReason categories that mean the reviewer/implementer subprocess died for
  # an infrastructure reason (expired credentials, exhausted credits/quota, rate
  # limiting, a gateway blip, an exec failure, or an unrecognized stream schema)
  # rather than genuinely finishing without printing a verdict (bd-b2glhm). A
  # verdict re-prompt against the SAME broken environment fails identically — it
  # just burns the re-prompt budget and reports a generic "no parseable VERDICT
  # line" that masks the real cause. Deliberately excludes `:crashed` and
  # `:exited_without_done`: those have no specific signature, so a re-prompt may
  # still be worth trying (a near-miss on the reviewer's part, not a known
  # infra failure).
  #
  # bd-3hr6g2: `:quota_exhausted` (the CLI's own 5h plan usage limit, distinct
  # from `:credit_exhausted`) belongs here for the same reason — a reviewer
  # that just hit the account's usage ceiling cannot produce a verdict no
  # matter how many times it's re-prompted within the same window.
  @infra_failure_categories [
    :auth_expired,
    :quota_exhausted,
    :credit_exhausted,
    :rate_limited,
    :gateway_error,
    :spawn_exec_failed,
    :stream_schema_drift,
    :agent_print_timeout,
    :killed,
    # bd-6zuoo6: a re-prompted reviewer re-runs the same workload into the
    # same memory cap.
    :memory_cap_exceeded,
    # bd-2s755v: a re-prompt sends the same rejected `-m` model.
    :model_unavailable
  ]

  # bd-2yt0d2: what a fix round restarted after a server stop is told, ahead of the
  # ordinary revise prompt.
  @restart_revise_note """
  NOTE: the server restarted while an earlier attempt at this round was running.
  That attempt was cut off, and this worktree may hold its uncommitted work. Run
  `git status` and `git diff` first, keep what is right, finish the rest, then
  commit and push as usual.

  """

  @verdict_approve ~r/^\s*VERDICT:\s*APPROVE(?:[*_]+|\b)/i
  @verdict_request_changes ~r/^\s*VERDICT:\s*(?:REQUEST_CHANGES|REJECT)(?:[*_]+|\b)/i

  @type verdict ::
          {:approve, String.t()}
          | {:request_changes, String.t()}
          | {:parked, park_reason(), String.t()}
          | :no_verdict

  @typedoc """
  bd-9zuvbh: why a class-C terminal parked rather than failed the run. Mirrors
  `Arbiter.Tasks.ReviewPark.reason/0`; the author maps each onto the park it
  stamps on the task.
  """
  @type park_reason ::
          :inconclusive
          | :reviewer_failed
          | :reviewer_timeout
          | :verdict_guard_exhausted
          | :commit_gate_no_changes
          | :commit_gate_no_changes_after_non_file_fix
          | :commit_gate_uncommitted
          | :empty_diff
          | :head_not_pushed

  @type opt ::
          {:author, pid()}
          | {:task_id, String.t()}
          | {:workspace_id, String.t() | nil}
          | {:repo, String.t()}
          | {:worktree_path, String.t() | nil}
          | {:branch, String.t()}
          | {:target_branch, String.t()}
          | {:command, [String.t()] | nil}
          | {:command_provider, String.t() | nil}
          | {:revise_command, [String.t()] | nil}
          | {:timeout_ms, non_neg_integer()}
          | {:verdict_retries, non_neg_integer()}
          | {:timeout_retries, non_neg_integer()}
          | {:rounds, pos_integer()}
          | {:pr_ref, String.t() | nil}
          | {:ci_gate, boolean() | nil}
          | {:ci_adapter, module() | nil}
          | {:ci_poll_ms, pos_integer() | nil}
          | {:ci_max_polls, pos_integer() | nil}
          | {:round, pos_integer()}
          | {:rearmed, boolean()}

  @doc """
  Start a ReviewGate under `Arbiter.Worker.Supervisor`.

  Required opts: `:author` (the author worker pid to report back to),
  `:task_id`, `:repo`, `:branch`. Optional: `:workspace_id`, `:worktree_path`,
  `:target_branch` (default `"main"`), `:command` (test override for the reviewer
  argv), `:revise_command` (test override for the implementer argv), `:rounds`
  (the revise-loop cap), `:timeout_ms`.
  """
  @spec start([opt()]) :: DynamicSupervisor.on_start_child()
  def start(opts) when is_list(opts) do
    DynamicSupervisor.start_child(Arbiter.Worker.Supervisor, {__MODULE__, opts})
  end

  @doc """
  Re-arm a CI wait the server restart cut off (bd-2gc809).

  The wait lives in a gate's memory and holds no slot and no agent; what
  outlives a restart is the ticket's `ci_wait` marker (`ReviewCi.put_marker/2`)
  and the round state beside it (branch, worktree, PR, target). This starts a
  fresh gate on that state with **no author** — none survives a restart, and the
  verdict is delivered to the ticket (`deliver_verdict/4`) — so the ticket comes
  back waiting on CI, holding no slot, instead of as a slot-needing resume of
  its implementer. The gate then reads CI on the head origin carries: green
  dispatches the round's reviewer, red takes the rerun/fix path, a head that
  moved is waited on in its own right.

  `opts` are extra `start/1` options (tests: the stub forge, reviewer argv).
  Returns `{:ok, pid}`, or `{:error, :no_ci_wait | :no_worktree | term}` when
  the ticket cannot be re-armed (the caller falls back to the ordinary resume).
  """
  @spec rearm_ci_wait(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def rearm_ci_wait(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, issue} <- Ash.get(Arbiter.Tasks.Issue, task_id),
         %{} = round <- ci_wait_round(issue),
         branch when is_binary(branch) <- round["branch"],
         worktree when is_binary(worktree) <- round["worktree_path"],
         true <- File.dir?(worktree) || {:error, :no_worktree} do
      marker = round["ci_wait"]

      base =
        [
          task_id: task_id,
          workspace_id: issue.workspace_id,
          repo: round["repo"] || "unknown",
          worktree_path: worktree,
          branch: branch,
          target_branch: round["target_branch"] || "main",
          pr_ref: round["pr_ref"] || issue.pr_ref,
          rounds: Worker.review_rounds_for(task_id, issue.workspace_id),
          round:
            if(is_integer(marker["round"]) and marker["round"] > 0, do: marker["round"], else: 1),
          fix_round_attempt: round["fix_round_attempts"] || 0,
          rearmed: true
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      start(Keyword.merge(base, opts))
    else
      {:error, _} = error -> error
      _ -> {:error, :no_ci_wait}
    end
  end

  @doc """
  Re-arm the ReviewGate pass the server restart cut off (bd-2yt0d2 / #291).

  A reviewer pass or an implementer fix round (`<task>#review#impl<N>`) dies
  with the node, and so does the gate that was waiting on it. What outlives
  them is the ticket's `pass` marker (`Arbiter.Worker.ReviewPass`) and the round
  state beside it. This starts a fresh gate on that state with **no author** —
  none survives a restart, and the verdict is delivered to the ticket
  (`deliver_verdict/4`) — and has it run the same round again on the same
  branch and head: a reviewer pass is launched afresh (a clean re-review of the
  round); a fix round gets a new implementer on the same worktree, told that an
  earlier attempt was cut off and may have left uncommitted work. The gate's
  memory of the earlier rounds — thread, open findings — comes back from the
  marker, so a round 2+ reviewer reads the same re-review prompt it would have.

  No agent session is resumed: the cut-off pass is re-run, not continued, which
  keeps this independent of whether the provider can resume at all.

  `opts` are extra `start/1` options (tests: the reviewer and implementer argv).
  Returns `{:ok, pid}`, or `{:error, :not_active | :no_review_pass |
  :no_worktree | term}` when the ticket cannot be re-armed (the caller clears
  the marker and falls back to the ordinary resume).
  """
  @spec rearm_pass(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def rearm_pass(task_id, opts \\ []) when is_binary(task_id) do
    with {:ok, %Issue{} = issue} <- Ash.get(Issue, task_id),
         :ok <- if(issue.state == :active, do: :ok, else: {:error, :not_active}),
         %{} = marker <- ReviewPass.stored(issue) || {:error, :no_review_pass},
         %{} = round <- issue.review_gate_state,
         branch when is_binary(branch) <- round["branch"] || {:error, :no_branch},
         worktree when is_binary(worktree) <- round["worktree_path"] || {:error, :no_worktree},
         true <- File.dir?(worktree) || {:error, :no_worktree} do
      pass = ReviewPass.restore(marker)

      base =
        [
          task_id: task_id,
          workspace_id: issue.workspace_id,
          repo: round["repo"] || "unknown",
          worktree_path: worktree,
          branch: branch,
          target_branch: round["target_branch"] || "main",
          pr_ref: round["pr_ref"] || issue.pr_ref,
          rounds: Worker.review_rounds_for(task_id, issue.workspace_id),
          round: pass.round,
          fix_round_attempt: pass.fix_round_attempt,
          resume_pass: pass
        ]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      start(Keyword.merge(base, opts))
    else
      {:error, _} = error -> error
      _ -> {:error, :no_review_pass}
    end
  end

  defp ci_wait_round(%{state: :active, review_gate_state: %{"ci_wait" => %{"sha" => _}} = round}),
    do: round

  defp ci_wait_round(_issue), do: nil

  @spec start_link([opt()]) :: GenServer.on_start()
  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  The task id used for the reviewer worker — the author task id with a
  `#review` suffix so it registers as a distinct worker and records its own run
  row without colliding with the author.
  """
  @spec reviewer_task_id(String.t()) :: String.t()
  def reviewer_task_id(task_id) when is_binary(task_id), do: task_id <> "#review"

  @doc """
  The exact leading sentence of a bd-2eyf9y commit-gate escalation reporting
  uncommitted work left behind after a resumed revise round. Exposed so
  `Arbiter.Worker.escalate_review_gate/3` can give it a distinct mailbox
  subject without hardcoding (and risking drift from) the literal text.
  """
  @spec commit_gate_uncommitted_marker() :: String.t()
  def commit_gate_uncommitted_marker, do: @commit_gate_uncommitted_marker

  @doc """
  The exact leading sentence of a bd-2eyf9y commit-gate escalation reporting a
  revise round that left HEAD unchanged on a clean worktree (no code change).
  """
  @spec commit_gate_no_changes_marker() :: String.t()
  def commit_gate_no_changes_marker, do: @commit_gate_no_changes_marker

  @doc """
  Strip any synthetic-id suffix (`#review`, `#r<N>`, `#impl<N>`, `#v<N>`,
  `#t<N>`, or a chain of these e.g. `#review#t2`) back to the authoring task
  id. Every synthetic id built by this module (`reviewer_task_id/1`,
  `reprompt_task_id/2`, `reviewer_round_id/2`, `implementer_task_id/2`,
  `timeout_retry_id/2`) is `<base> <> "#" <> suffix`, so splitting on the
  first `#` recovers the base regardless of which suffix was appended. A
  plain task id (no `#`) is returned unchanged.
  """
  @spec base_task_id(String.t()) :: String.t()
  def base_task_id(task_id) when is_binary(task_id) do
    task_id |> String.split("#", parts: 2) |> List.first()
  end

  @doc """
  Resolve the per-pass reviewer/implementer timeout in milliseconds.

  Resolution order:

    1. `override` — an explicit `:timeout_ms` opt (tests / advanced callers),
       held for the gate's lifetime.
    2. The workspace's `config["review_gate"]["timeout_ms"]`, read **live**.
    3. `#{@default_timeout_ms}` ms (#{div(@default_timeout_ms, 60_000)} minutes).

  Called once per pass from `launch_worker/5` rather than once at gate init
  (bd-216r3e). A gate outlives many passes — a timeout retry, a verdict
  re-prompt, every revise round — and resolving the budget once meant a
  `review_gate.timeout_ms` raised mid-run could not reach the running gate: the
  only way to apply it was `worker stop` + `worker resume`. An operator who
  raised the value, saw the next round still time out on the old budget, and
  concluded the config key does not work was reading a real trap, not a
  mistake of their own.
  """
  @spec resolve_timeout_ms(String.t() | nil, pos_integer() | nil) :: pos_integer()
  def resolve_timeout_ms(workspace_id, override \\ nil)

  def resolve_timeout_ms(_workspace_id, override) when is_integer(override) and override > 0,
    do: override

  def resolve_timeout_ms(workspace_id, _override) do
    case load_workspace(workspace_id) do
      %Workspace{} = ws -> Workspace.review_gate_timeout_ms(ws) || @default_timeout_ms
      _ -> @default_timeout_ms
    end
  end

  @doc """
  The default revise-and-rediscuss round cap for a task's difficulty level.

  | Difficulty | Label    | Default rounds |
  |------------|----------|---------------|
  | 0          | trivial  | 2             |
  | 1          | simple   | 2             |
  | 2          | moderate | 3             |
  | 3          | hard     | 4             |
  | 4          | extreme  | 4             |
  | 5          | flagship | 4             |
  | nil        | unknown  | 3 (D2)        |

  Used by `Arbiter.Worker.resolve_review_rounds/1` to derive the default cap
  from the task's difficulty when no workspace `config["review_gate"]["max_rounds"]`
  override is set.
  """
  @spec rounds_for_difficulty(0..5 | nil) :: pos_integer()
  def rounds_for_difficulty(difficulty) do
    Map.get(@rounds_by_difficulty, difficulty, @default_rounds)
  end

  # ---- verdict parsing (pure) --------------------------------------------

  @doc """
  Normalize a candidate verdict line before matching.

  Strips leading/trailing markdown emphasis (`*`, `_`), headings (`#`),
  blockquotes (`>`), list markers (ordered `1.`, `1)` or unordered `-`, `+`, `*`),
  and whitespace.
  """
  @spec normalize_verdict_line(String.t() | term()) :: String.t() | term()
  def normalize_verdict_line(line) when is_binary(line) do
    line
    |> strip_leading_markdown()
    |> strip_trailing_markdown()
  end

  def normalize_verdict_line(other), do: other

  defp strip_leading_markdown(str) do
    trimmed = String.trim_leading(str)

    cond do
      String.starts_with?(trimmed, ">") ->
        trimmed |> String.trim_leading(">") |> strip_leading_markdown()

      String.starts_with?(trimmed, "#") ->
        trimmed |> String.trim_leading("#") |> strip_leading_markdown()

      Regex.match?(~r/^\d+[\.\)]\s+/, trimmed) ->
        trimmed
        |> String.replace(~r/^\d+[\.\)]\s+/, "", global: false)
        |> strip_leading_markdown()

      Regex.match?(~r/^[-+]\s+/, trimmed) ->
        trimmed |> String.replace(~r/^[-+]\s+/, "", global: false) |> strip_leading_markdown()

      String.starts_with?(trimmed, "*") ->
        trimmed |> String.trim_leading("*") |> strip_leading_markdown()

      String.starts_with?(trimmed, "_") ->
        trimmed |> String.trim_leading("_") |> strip_leading_markdown()

      true ->
        trimmed
    end
  end

  defp strip_trailing_markdown(str) do
    trimmed = String.trim_trailing(str)

    cond do
      String.ends_with?(trimmed, "*") ->
        trimmed |> String.trim_trailing("*") |> strip_trailing_markdown()

      String.ends_with?(trimmed, "_") ->
        trimmed |> String.trim_trailing("_") |> strip_trailing_markdown()

      String.ends_with?(trimmed, "#") ->
        trimmed |> String.trim_trailing("#") |> strip_trailing_markdown()

      true ->
        trimmed
    end
  end

  @doc """
  Parse a reviewer's output lines into a verdict.

  Returns `{:approve, findings}`, `{:request_changes, findings}`, or
  `:no_verdict` when no recognizable sentinel is present. `findings` is the
  transcript from the verdict line onward (trimmed), so the author can persist /
  escalate the reviewer's reasoning verbatim.
  """
  @spec parse_verdict([String.t()]) :: verdict()
  def parse_verdict(lines) when is_list(lines) do
    lines
    |> Enum.join("\n")
    |> String.split("\n")
    |> scan_verdict()
  end

  defp scan_verdict([]), do: :no_verdict

  defp scan_verdict([line | rest] = remaining) do
    normalized = normalize_verdict_line(line)

    cond do
      Regex.match?(@verdict_approve, normalized) ->
        findings = remaining |> Enum.join("\n") |> String.trim()
        {:approve, findings}

      Regex.match?(@verdict_request_changes, normalized) ->
        findings = remaining |> Enum.join("\n") |> String.trim()
        {:request_changes, findings}

      true ->
        scan_verdict(rest)
    end
  end

  @typedoc """
  Which line source produced the verdict — `:memory` for the caller's own
  (bounded) buffer, `:transcript` for the durable per-run log, `:none` when
  neither had one.
  """
  @type verdict_source :: :memory | :transcript | :none

  @doc """
  Parse a reviewer's verdict, falling back to the run's **durable transcript**
  before conceding `:no_verdict` — and logging which source saw what either way.

  Three different line buffers feed verdict parsing, and each can be missing the
  sentinel for a different reason:

    * `meta[:output_lines]` — `Arbiter.Worker.ClaudeSession` keeps only the most
      recent 1000 emitted lines, and `Arbiter.Worker` persists only the last 500
      of those. A cap drops the OLDEST lines, so a reviewer that prints
      `VERDICT:` and then produces more than 1000 lines of findings evicts its
      own sentinel.
    * `ReviewGate.state.lines` — the gate's own live PubSub capture. It is not
      capped, but it is assembled from broadcasts: a line emitted before this
      pass subscribed, or still in flight when the pass is finished, is simply
      absent. This buffer loses its NEWEST lines — the opposite end from a cap.
    * `Arbiter.Worker.OutputLog` — the durable per-run transcript. Uncapped,
      keyed by `run_id`, written straight through on every emitted line.

  The first two are lossy in opposite directions, so the recovery must not care
  which end went missing: on any miss, re-parse the durable transcript.

  bd-6dxit2 measured which of these actually bit. Of the 72 recorded
  `:review_gate_inconclusive` failures, 18 have a durable transcript for the
  decisive pass and 5 of those transcripts contain a parseable `VERDICT:` line —
  real false negatives, a completed review discarded. In all 5 the sentinel sat
  10–43 lines from the end and was present even in the 500-line persisted tail,
  so **cap eviction was not the cause in any observed case**; the gate's live
  capture was. The caps remain a genuine hazard for a verdict followed by >1000
  lines, and are covered too — but they were not this bug.

  The log line is the point as much as the recovery: `:no_verdict` on its own
  cannot distinguish "the reviewer genuinely emitted no verdict" from "the
  parser was handed the wrong text", and for weeks the fleet could not tell
  which it had. Now the two cases read differently in the log, and a disagreement
  between the sources names itself.

  `context` is a short caller-supplied label (e.g. `"task=bd-xxxx"`) echoed into
  the log. Returns `{verdict, source}`.
  """
  @spec parse_verdict([String.t()], String.t() | nil, String.t()) ::
          {verdict(), verdict_source()}
  def parse_verdict(lines, run_id, context) when is_list(lines) and is_binary(context) do
    case parse_verdict(lines) do
      :no_verdict -> verdict_from_transcript(length(lines), run_id, context)
      verdict -> {verdict, :memory}
    end
  end

  defp verdict_from_transcript(scanned, run_id, context) do
    case durable_lines(run_id) do
      {:ok, durable} ->
        case parse_verdict(durable) do
          :no_verdict ->
            Logger.warning(
              "ReviewGate: no VERDICT for #{context}: scanned #{scanned} in-memory line(s) and " <>
                "#{length(durable)} durable transcript line(s); neither contains a parseable " <>
                "VERDICT line — the reviewer emitted no verdict"
            )

            {:no_verdict, :none}

          verdict ->
            Logger.warning(
              "ReviewGate: VERDICT recovered from the durable transcript for #{context}: the " <>
                "in-memory buffer (#{scanned} line(s)) had none, the transcript " <>
                "(#{length(durable)} line(s)) does — the parser was reading a truncated tail, " <>
                "not a reviewer that stayed silent"
            )

            {verdict, :transcript}
        end

      {:error, reason} ->
        Logger.warning(
          "ReviewGate: no VERDICT for #{context}: scanned #{scanned} in-memory line(s); the " <>
            "durable transcript could not be read (#{inspect(reason)}), so whether the reviewer " <>
            "emitted one is unknown"
        )

        {:no_verdict, :none}
    end
  end

  defp durable_lines(run_id) when is_binary(run_id) and run_id != "" do
    Arbiter.Worker.OutputLog.read_lines(run_id)
  rescue
    e -> {:error, e}
  end

  defp durable_lines(_), do: {:error, :no_run_id}

  @typedoc "One pass's scan record: the run id it resolved and the line counts it saw."
  @type verdict_scan :: %{
          run_id: String.t() | nil,
          memory: non_neg_integer(),
          durable: non_neg_integer() | nil
        }

  @doc """
  bd-869mmg round 3: before a genuine `:no_verdict` escalation, re-read every
  scanned pass's durable transcript **fresh** — not the counts recorded at the
  time of that pass's own scan — and see whether any of them holds a
  parseable verdict now.

  This exists because a pass's own scan conceding `:no_verdict` for reasons
  the surviving artifacts can't fully explain (bd-atyrrq / run 72947341: the
  first pass's own durable transcript holds an intact `VERDICT:
  REQUEST_CHANGES` today, yet that pass's own scan at the time reported
  nothing) must not be the last word — the gate's own re-prompt-and-escalate
  flow previously discarded that pass's transcript entirely once a LATER
  pass's scan also came back empty. `scans` is every pass's `verdict_scan/0`
  record, most recent first; the most recent pass with a real verdict on disk
  right now wins (the newest pass reviewed the newest code). Returns
  `{:ok, verdict, run_id}` on recovery, `:none` otherwise.
  """
  @spec recover_verdict_from_scans([verdict_scan()]) ::
          {:ok, verdict(), String.t()} | :none
  def recover_verdict_from_scans(scans) when is_list(scans) do
    Enum.find_value(scans, :none, fn
      %{run_id: run_id} when is_binary(run_id) and run_id != "" ->
        case durable_lines(run_id) do
          {:ok, durable} ->
            case parse_verdict(durable) do
              :no_verdict -> nil
              verdict -> {:ok, verdict, run_id}
            end

          {:error, _} ->
            nil
        end

      _ ->
        nil
    end)
  end

  # bd-869mmg round 2: the counts a `:no_verdict` outcome saw, captured once at
  # the point of the failed scan so the eventual escalation message (built
  # later, possibly after a re-prompt) can report exactly what was checked
  # instead of re-deriving it (and possibly a different run's counts, or an
  # unconditional "output was received" that is false when nothing was
  # captured at all).
  defp verdict_scan_info(lines, run_id) do
    durable =
      case durable_lines(run_id) do
        {:ok, durable} -> length(durable)
        {:error, _} -> nil
      end

    %{run_id: run_id, memory: length(lines), durable: durable}
  end

  # The run row id of the reviewer pass we are finishing — the key the durable
  # transcript is filed under. The reviewer runs as its own worker under a
  # synthetic task id (`<task>#review`, `#r2`, `#v2`), and its Run row is
  # persisted when the pass is spawned. Best-effort: without it the transcript
  # cross-check simply reports "unknown" rather than failing the pass.
  defp reviewer_run_id(%{current_id: id}) when is_binary(id) and id != "" do
    require Ash.Query

    Arbiter.Workers.Run
    |> Ash.Query.filter(task_id == ^id)
    # bd-869mmg round 2: `started_at` alone can tie (two Run rows for
    # DIFFERENT task_ids inserted in the same millisecond does not matter
    # here since the filter already narrows to `id`'s own rows, but a
    # deterministic secondary key means re-running this query never flips
    # which of two SAME-task_id rows — e.g. a duplicate spawn — is picked).
    |> Ash.Query.sort(started_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Arbiter.Workers.Run{id: run_id} | _] -> run_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp reviewer_run_id(_), do: nil

  # ---- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    # bd-2gc809: nil for a gate re-armed at boot (`rearm_ci_wait/2`) — no author
    # survives a restart, and the verdict goes to the ticket (`deliver_verdict/4`).
    author = Keyword.get(opts, :author)
    task_id = Keyword.fetch!(opts, :task_id)

    state = %{
      author: author,
      task_id: task_id,
      review_id: reviewer_task_id(task_id),
      workspace_id: Keyword.get(opts, :workspace_id),
      repo: Keyword.get(opts, :repo, "unknown"),
      worktree_path: Keyword.get(opts, :worktree_path),
      branch: Keyword.fetch!(opts, :branch),
      target_branch: Keyword.get(opts, :target_branch, "main"),
      # bd-129xh4: the open PR/MR ref (e.g. "owner/repo#42" or "#42") when the
      # author opened the PR before the gate ran. nil when no hosted merger is
      # configured — the reviewer then falls back to the local branch diff.
      pr_ref: Keyword.get(opts, :pr_ref),
      command: Keyword.get(opts, :command),
      # bd-869mmg: test-only escape hatch alongside `:command` — tags the
      # fixture reviewer argv's output as a specific provider's wire format
      # (e.g. "gemini") so a fixture emitting real gemini stream-json can
      # exercise `ClaudeSession`'s provider-specific decode/buffer path
      # end-to-end, the same way a real workspace-routed reviewer would.
      command_provider: Keyword.get(opts, :command_provider),
      revise_command: Keyword.get(opts, :revise_command),
      # bd-216r3e: `:timeout_ms` is an explicit OVERRIDE (tests / advanced
      # callers) and is held for the gate's lifetime. With no override the
      # per-pass timeout is re-resolved from live workspace config every time a
      # pass is armed (`launch_worker/5`), so raising `review_gate.timeout_ms`
      # reaches a gate that is already running instead of requiring a `worker
      # stop` + `worker resume`. `timeout_ms` below is the value the MOST
      # RECENTLY armed pass is running under — it is what the timeout escalation
      # reports, so the message can never name a budget the pass did not use.
      timeout_override_ms: Keyword.get(opts, :timeout_ms),
      timeout_ms:
        resolve_timeout_ms(Keyword.get(opts, :workspace_id), Keyword.get(opts, :timeout_ms)),
      # Reviewing-pass timeout retry budget (bd-78vg4v). Consumed by the
      # reviewing-phase timeout handler; not reset per round — it guards against
      # a whole ReviewGate stalling on transient API hangs, not per-round noise.
      timeout_retries_left: Keyword.get(opts, :timeout_retries, @default_timeout_retries),
      retries_left: Keyword.get(opts, :verdict_retries, @default_verdict_retries),
      # Stored so finish_revise/1 can reset retries_left at the start of each
      # new round — the retry budget is per-round, not ReviewGate-lifetime.
      initial_retries: Keyword.get(opts, :verdict_retries, @default_verdict_retries),
      max_rounds: max(Keyword.get(opts, :rounds, @default_rounds), 1),
      # phase: :reviewing while a reviewer pass is in flight, :revising while an
      # implementer addresses findings between rounds.
      phase: :reviewing,
      round: Keyword.get(opts, :round, 1),
      # bd-6d3h8m: 0 for the original pass, N when this gate was spawned by the
      # Nth automatic implementer fix round (`Worker.maybe_dispatch_fix_round/3`
      # forwards `meta[:review_gate_fix_round_attempts]` through
      # `spawn_review_gate/2`). `round` restarts at 1 on every fresh gate, so
      # this is what keeps `record_round/5`'s rows distinguishable across a fix
      # round instead of reading as a duplicate round 1..N.
      fix_round_attempt: Keyword.get(opts, :fix_round_attempt, 0),
      # The implementer<->reviewer thread, oldest-first. Each entry:
      # %{round:, role: :reviewer | :implementer | :system, subject:, body:}.
      # Mirrors the durable mailbox rows; the source for the escalation payload.
      thread: [],
      attempt: 0,
      # The id of the worker whose output/exit we are currently waiting on, so a
      # stale message from a prior (stopped) reviewer/implementer is ignored.
      current_id: nil,
      # The prompt handed to the current reviewer pass, retained so a timeout
      # retry can re-launch the SAME pass (same review context) with a fresh
      # mind rather than reconstructing it. Set by launch_worker/5 (bd-78vg4v).
      current_prompt: nil,
      reviewer_pid: nil,
      lines: [],
      reported?: false,
      # bd-869mmg round 2: the run id + line counts a `:no_verdict` scan saw,
      # set only when a pass actually concedes no parseable verdict — see
      # `verdict_scan_info/2` and `attempt_finish/2`.
      verdict_scan: nil,
      # bd-869mmg round 3: every pass's `verdict_scan` (most recent first),
      # accumulated across re-prompts. `maybe_reprompt/2`'s final concession
      # re-reads each of these passes' durable transcripts fresh before giving
      # up — see `recover_verdict_from_scans/1`.
      verdict_scans: [],
      # bd-cwe9n2: agy commands a headless soft-deny refused across this gate's
      # reviewer passes (named in a no-verdict escalation), whether the pass
      # that just exited was ended by one, and how many times the gate has
      # waited for the reviewer Worker to resume the conversation instead of
      # scoring the cut-short turn.
      denied_commands: [],
      denial_pending: false,
      denial_defers: 0,
      # The short HEAD SHA of the branch at the time the current reviewer was
      # spawned. Set by handle_continue(:spawn_reviewer) and updated by
      # finish_revise/1 after each revise round. Used to:
      #   1. prove which commit the reviewer saw (surfaces in the prompt and thread)
      #   2. detect whether the revise implementer actually committed new changes
      head_sha: nil,
      # bd-ased52: the merge-base (fork point) between the branch and its target,
      # resolved once at reviewer spawn time after the branch is brought current.
      # The reviewer (and the escalation diff) diff `base_sha..HEAD` so commits
      # that landed on the target AFTER the branch was cut are never attributed
      # to the branch. nil when no worktree / git is unavailable.
      base_sha: nil,
      # P7 (bd-60r6wp / #1738, §4.5): the covered commit this gate's review is
      # scoped FROM, when the head descends from one — the post-approval
      # fix-pass shape. Resolved once, at reviewer spawn, by
      # `with_delta_scope/1`; nil means an ordinary whole-branch review. Only
      # the reviewer prompt reads it: the coverage row an APPROVE writes still
      # fingerprints the whole `diff_range/1`, because that row has to describe
      # everything the PR would merge.
      delta_base_sha: nil,
      # bd-954ym8 / #134: the `Arbiter.Reviews.ConflictResolution` info (the
      # approved commit, the target commits and every hand-resolved conflict
      # region) while this round is a SCOPED conflict-resolution review —
      # nil for every ordinary round. Set once at reviewer spawn by
      # `conflict_path/1`, read by `review_prompt/1`, the reviewer tier and
      # timeout, the verdict guards and the round row's `role`, and cleared
      # when the next round starts: a head the resolution review sent back is
      # reviewed in full after the fix.
      conflict_review: nil,
      # bd-6r8caj: the findings still open against this work, carried across
      # rounds with stable `F<round>.<n>` ids. A round that rejects appends its
      # own findings and drops the ones the round dispositioned as addressed or
      # obsolete; an APPROVE must account for every Medium-or-higher entry here
      # or it is not honored.
      open_findings: [],
      # The set of repo-relative paths the implementer actually changed,
      # accumulated only from each revise round's own diff (bd-7urncn: NOT
      # seeded from the initial base_sha..head_sha commit — a finding citing a
      # file from the PR's initial commit, never revisited by a revise round,
      # must stay open, not count as "touched"). nil until a diff is actually
      # computed (and stays nil without a worktree / git), which keeps the
      # untouched-file backstop silent rather than guessing.
      revise_touched_files: nil,
      # bd-c6tdbu: set only when the round just rejected was an APPROVE turned
      # down solely by the `:unaddressed_findings` guard (bd-6r8caj's approval
      # gap) — `%{gap: gap}`. Cleared on every other reject path. If the fix
      # round this triggers produces NO code change, `finish_revise/1` reads
      # this back to escalate with a message naming exactly which open
      # findings blocked the approval, instead of the generic (and
      # misleading, since there was nothing to fix) commit-gate-no-changes
      # failure.
      approval_gap_pending: nil,
      # bd-9zuvbh: which verdict guard (G9-G12) turned this round's verdict
      # down, when the reject currently being routed came from `fail_closed/3`
      # rather than from a reviewer that really said REQUEST_CHANGES. Only
      # `do_route_after_reject/2`'s round-cap arm reads it, and only to decide
      # which terminal it reports: a guard-rejected APPROVE at the cap parks
      # (class C — the reviewer approved, a guard did not agree, and a human
      # decides), while a genuine REQUEST_CHANGES at the cap still fails the run
      # exactly as before. Cleared on every path that is not a guard reject.
      guard_rejected: nil,
      # bd-2eyf9y: whether the CURRENT round's implementer has already been
      # resumed once to commit uncommitted work. Reset to false whenever a
      # round genuinely advances (finish_revise/1's dispatch_next_review/1) so
      # each new round gets its own one-shot nudge budget.
      commit_nudge_used: false,
      # bd-cb7wpq: whether the PRIOR revise round already advanced on a
      # no-commit resolution (see `non_file_fix_declared?/1`) rather than a
      # real commit. A single such round is honored — the next reviewer
      # re-checks the live PR for real, so a false claim is still caught —
      # but two in a row with nothing to show for either is indistinguishable
      # from an idle worker and escalates. Reset to false the moment a round
      # produces a genuine commit (`finish_revise/1`'s `:advanced` branch).
      non_file_fix_used: false,
      # bd-bq8c8a: the sha this round is re-reviewing BECAUSE a third party
      # pushed it, not because an implementer addressed anything
      # (`restart_on_remote_head/3`). nil on every ordinary round. Read only by
      # `rereview_prompt/1`, to state what actually happened instead of the
      # default "the implementer has addressed your prior findings" — which on
      # this path is false, and would bias the reviewer into dispositioning its
      # own open findings `[ADDRESSED]` against a diff that never targeted them
      # (the bd-6r8caj property).
      restarted_on_remote_head: nil,
      # bd-3hb4ih: the provider this round's reviewer passes are PINNED to,
      # once a print-timeout has rotated off the workspace's own first choice.
      # nil on every ordinary pass, which leaves provider resolution exactly
      # where it was (`Agents.reviewer_for_workspace/1`, health-aware via
      # `ProviderPool.pick/1`) — the rotation is the only thing that pins.
      reviewer_provider: nil,
      # bd-3hb4ih: every provider that has hit its own hard print-timeout wall
      # in the CURRENT round, oldest-first:
      # `%{provider:, round:, pass_id:, summary:}`. This is the "remaining
      # provider list" the acceptance criteria ask for, carried by subtraction:
      # the next pass takes the first pool entry NOT in here, so a provider that
      # timed out is never retried inside the round. Reset per round by
      # `dispatch_next_review/2` — a fresh diff is a fresh chance for a provider
      # that timed out on the previous one.
      reviewer_timeouts: [],
      # bd-a1ke2c: under `review_agent.cross_family`, the current reviewer
      # pass's `ReviewerRouting` selection — the provider, family, model and
      # tier it runs and the audit fields its round row records. Re-chosen at
      # every reviewer launch the print-timeout rotation has not pinned; nil
      # whenever cross-family review is off, which leaves every path below
      # exactly as it was.
      reviewer_selection: nil,
      # bd-a22hib: the CURRENT review round's own detached checkout,
      # `%{path:, head_sha:}` — provisioned by `provision_review_checkout/1`
      # at the pushed head right before the round's first reviewer pass, shared
      # by every pass of that round (re-prompts, timeout retries, provider
      # rotations), and removed by `release_review_checkout/1` the moment the
      # round ends. nil between rounds (the fix pass runs in `worktree_path`)
      # and for a gate with no branch worktree to check out from.
      review_checkout: nil,
      # bd-cut6uv: CI-gated review. `ci_gate_override` / `ci_adapter` /
      # `ci_poll_ms` / `ci_max_polls` are the test escape hatches over the
      # workspace's `review.require_ci_green`, the repo's merger adapter and its
      # poll budget (`Arbiter.Worker.ReviewCi`); nil leaves each to the config.
      ci_gate_override: Keyword.get(opts, :ci_gate),
      ci_adapter: Keyword.get(opts, :ci_adapter),
      ci_poll_ms: Keyword.get(opts, :ci_poll_ms),
      ci_max_polls: Keyword.get(opts, :ci_max_polls),
      # The wait in progress (phase `:awaiting_ci`): `ReviewCi.wait/0` plus the
      # token that identifies its poll timer. nil whenever no reviewer is being
      # held back.
      ci_wait: nil,
      # Where the wait resumes when CI clears: `:first` (the gate's opening
      # review) or `{:next, review_id}` (a later round). Set on every gate pass.
      ci_entry: nil,
      # What the wait resolved the forge, adapter and budget to, kept for its polls.
      ci_ctx: nil,
      # bd-2gc809: a gate re-armed at boot inherits its dead predecessor's `ci_wait`
      # marker. It stays until this gate waits (and rewrites it) or ends the wait
      # without having waited (`ci_end_wait/1`), so the ticket never reads as not
      # waiting while the reconciler's resume sweep is still looking at it.
      ci_rearmed: Keyword.get(opts, :rearmed, false),
      # `%{sha:, url:}` once CI was read green on the head being reviewed. Set
      # for the round that follows and cleared at the next one; it is what lets
      # the reviewer skip the suite and what lets a suite-only PARTIAL pass.
      ci_green: nil,
      # Why the gate waited for CI and did not get a green result (so the
      # reviewer runs the tests). nil when CI gated the round or the gate is off.
      ci_fallback: nil,
      # Times the wait moved to a newer head the branch had gained meanwhile.
      ci_retargets: 0,
      # bd-2yt0d2: the cut-off pass this gate was re-armed to run again
      # (`rearm_pass/2`), as `ReviewPass.restore/1` reads it back. nil for every
      # gate that starts from the top.
      resume_pass: nil,
      # Whether the ticket carries this gate's `pass` marker (`ReviewPass`), so
      # a gate that never launched a pass writes nothing to clear.
      pass_marked?: false
    }

    state = restore_pass_state(state, Keyword.get(opts, :resume_pass))

    if is_pid(author), do: Process.monitor(author)
    {:ok, state, {:continue, :spawn_reviewer}}
  end

  defp continue_reply({tag, state}) when tag in [:continue, :revise], do: {:noreply, state}
  defp continue_reply({:done, state}), do: {:stop, :normal, state}

  # A fix round cut off by the stop: a new implementer on the same worktree,
  # handed the findings the round was opened with (the thread's last entry for
  # it) and told what it may find there.
  defp resume_revise_pass(state) do
    Logger.info(
      "ReviewGate: task=#{state.task_id} round #{state.round} fix round was cut off by a " <>
        "server restart; re-running it"
    )

    findings = revise_findings(state)

    state =
      record_thread(
        %{state | resume_pass: nil},
        :system,
        "Round #{state.round} fix round restarted",
        "The server restarted while the implementer was addressing this round's findings."
      )

    launch_implementer(state, findings, @restart_revise_note)
  end

  defp revise_findings(%{thread: thread, round: round}) do
    thread
    |> Enum.reverse()
    |> Enum.find(&(&1.round == round and &1.role in [:reviewer, :system]))
    |> case do
      %{body: body} -> body
      nil -> ""
    end
  end

  # A re-review (round 2+) cut off by the stop: the round's reviewer is launched
  # again exactly as `finish_revise/1` would have launched it.
  defp resume_rereview_pass(%{resume_pass: %{round: round}} = state) do
    Logger.info(
      "ReviewGate: task=#{state.task_id} round #{round} review was cut off by a server " <>
        "restart; re-running it"
    )

    dispatch_next_review(%{state | round: round - 1, resume_pass: nil, phase: :reviewing})
  end

  # bd-2yt0d2: the `pass` marker. Written when a pass is launched, cleared when it
  # ends (`clear_pass/1`); what is left on the ticket at boot is the pass the stop
  # cut off.
  defp mark_pass(state, role, id) do
    phase = if role == :implementer, do: :revising, else: :reviewing
    marker = ReviewPass.marker(state, phase, id, state.timeout_ms)
    safe(fn -> ReviewPass.put(state.task_id, marker) end)
    %{state | pass_marked?: true}
  end

  defp clear_pass(%{pass_marked?: true} = state) do
    safe(fn -> ReviewPass.put(state.task_id, nil) end)
    %{state | pass_marked?: false}
  end

  defp clear_pass(state), do: state

  # bd-2yt0d2: a re-armed gate carries the memory of the rounds before the cut-off
  # pass — the thread, the findings still open, the files the fixes touched, the
  # head and merge-base the round started on — which the dead gate held only in
  # its process.
  defp restore_pass_state(state, nil), do: state

  defp restore_pass_state(state, %{} = pass) do
    %{
      state
      | resume_pass: pass,
        pass_marked?: true,
        phase: pass.phase,
        round: pass.round,
        thread: pass.thread,
        open_findings: pass.open_findings,
        revise_touched_files: pass.revise_touched_files,
        head_sha: pass.head_sha,
        base_sha: pass.base_sha
    }
  end

  @impl true
  def handle_continue(:spawn_reviewer, %{resume_pass: %{phase: :revising}} = state),
    do: state |> resume_revise_pass() |> continue_reply()

  def handle_continue(:spawn_reviewer, %{resume_pass: %{phase: :reviewing, round: round}} = state)
      when round > 1,
      do: state |> resume_rereview_pass() |> continue_reply()

  def handle_continue(:spawn_reviewer, state) do
    # bd-ased52: bring the branch up to date with its target BEFORE anything
    # else, so the reviewer diffs against the current target tip rather than the
    # stale base it was cut from. A branch that conflicts with the advanced
    # target escalates instead of being reviewed stale.
    case prepare_branch_for_review(state) do
      {:error, {:conflict, escalation}} ->
        Logger.warning(
          "ReviewGate: branch `#{state.branch}` conflicts with `#{state.target_branch}` " <>
            "for task=#{state.task_id}; escalating instead of reviewing a stale base"
        )

        escalate_pre_review(state, escalation)

      {:ok, state} ->
        spawn_reviewer_after_update(state)
    end
  end

  defp spawn_reviewer_after_update(state) do
    # bd-1mksks: verify that commits exist on the branch BEFORE spawning the
    # reviewer. The worker commit gate (bd-ofql8k) already guards the initial
    # dispatch, but this check is a second layer of defence that also covers the
    # revise-loop case (the revise implementer's worker has no worktree_path in
    # meta, so its commit gate does not fire). If we spawned a reviewer over a
    # zero-commit branch it would see an empty diff and report "no work" — the
    # bug this task fixes.
    case reviewer_commit_check(state) do
      {:error, reason} ->
        Logger.warning("ReviewGate: branch has no commits for task=#{state.task_id}: #{reason}")

        escalate_pre_review(state, reason)

      {:ok, head_sha} ->
        state = %{state | head_sha: head_sha}

        # bd-2jkrqu: the head about to be reviewed must be ON the remote branch
        # the PR points at, or the verdict describes a commit the PR does not
        # carry. Push it if it isn't; refuse to review if it can't be pushed.
        case push_gate(state) do
          {:error, reason} ->
            escalate_pre_review(state, reason, :head_not_pushed)

          :ok ->
            spawn_reviewer_after_push(state)
        end
    end
  end

  # bd-31bh37: guard against an unexpectedly-empty diff range. If
  # base_sha == head_sha the reviewer would diff a commit against itself
  # (empty output) and bogusly conclude "no work". This can happen when
  # origin/<target> has already incorporated the branch's commits (e.g. the
  # branch was merged into target before the review gate ran), making the
  # merge-base equal to the branch HEAD. Treat this as an escalation rather
  # than spawning a reviewer that will falsely reject. This is a safety net
  # on top of sync_from_origin; the primary fix is fetching the pushed tip.
  defp spawn_reviewer_after_push(state) do
    case empty_diff_guard(state) do
      {:error, reason} ->
        Logger.warning(
          "ReviewGate: empty diff range detected for task=#{state.task_id}: #{reason}"
        )

        escalate_pre_review(state, reason, :empty_diff)

      :ok ->
        case conflict_path(state) do
          {:covered, state} -> {:stop, :normal, state}
          {:scoped, state} -> launch_first_reviewer(state)
          {:full, state} -> state |> with_delta_scope() |> launch_first_reviewer()
        end
    end
  end

  # bd-cut6uv: every reviewer this gate dispatches first waits for CI on the
  # head it is about to review (`ci_gate/2`) — when `review.require_ci_green`
  # applies. The gate has exactly two doors to a reviewer: this one (the opening
  # review, a scoped conflict review, a re-run gate after a fix round) and
  # `dispatch_next_review/2` (every later round, including the restart on a
  # head a third party pushed). Both go through `ci_gate/2`.
  defp launch_first_reviewer(state) do
    state |> ci_gate(:first) |> ci_reply()
  end

  defp launch_first_reviewer_after_ci(state) do
    case provision_review_checkout(state) do
      {:ok, state} ->
        state |> ci_verify_checkout(:first) |> launch_first_or_retarget()

      {:error, reason} ->
        escalate_pre_review(state, checkout_failure_message(state, reason), :reviewer_failed)
    end
  end

  defp launch_first_or_retarget({:retarget, state}), do: state |> ci_gate(:first) |> ci_reply()
  defp launch_first_or_retarget({:ok, state}), do: launch_first_reviewer_in_checkout(state)

  defp launch_first_reviewer_in_checkout(state) do
    case launch_worker(state, state.review_id, :reviewer, review_prompt(state), state.command) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "ReviewGate: failed to spawn reviewer for task=#{state.task_id}: #{inspect(reason)}"
        )

        # bd-9zuvbh: a reviewer that could not be spawned (quota gate
        # refusal, no outpost, an adapter error out of
        # `start_worker_session/4`) is the SAME liveness failure as one
        # whose session dies a step later — no verdict was produced and
        # nobody has found a problem with the work. It parks as
        # `:reviewer_failed` rather than failing the run, which also
        # matters on a revise round: a round-2 spawn failure must not
        # fail a run whose round-1 work was fine.
        escalate_pre_review(
          state,
          "ReviewGate could not spawn a reviewer: #{inspect(reason)}",
          :reviewer_failed
        )
    end
  end

  # ---- CI-gated review (bd-cut6uv) ------------------------------------------
  #
  # Reviewers spent much of their time and quota running `mix test` and often
  # could not finish inside their budget; the partial-verification guard then
  # re-ran the whole review. CI minutes are close to free next to model quota, so
  # when `review.require_ci_green` applies (`Arbiter.Worker.ReviewCi`) the gate
  # waits for CI on the exact head SHA before it dispatches a reviewer, and tells
  # the reviewer not to run the suite.
  #
  # Every way into a reviewer passes through here:
  #
  #   * the opening review, a scoped conflict review (`conflict_path/1`), and a
  #     fresh gate after a Worker fix round / resume —
  #     `launch_first_reviewer/1`, entry `:first`;
  #   * every later round of this gate's revise loop, and the restart on a head a
  #     third party pushed (`restart_on_remote_head/3`) —
  #     `dispatch_next_review/2`, entry `{:next, review_id}`.
  #
  # (A clean integration covered by an earlier approval, `cover_clean_integration/2`,
  # dispatches no reviewer at all, so there is nothing for CI to gate; the merge is
  # still held by the forge's own checks and the Watchdog.) Re-prompts, timeout
  # retries and provider rotations re-run a pass of a round whose CI was already
  # read, on the same head, and do not wait again.
  #
  # While it waits the gate holds no agent: no reviewer is spawned, the author's own
  # session is already over, and the ticket is marked `ci_wait` so the board names
  # it and the slot count releases it.
  @ci_max_retargets 3

  # Returns
  #   {:proceed, state}  dispatch the reviewer now (CI green, the gate off, or fallen back)
  #   {:wait, state}     phase `:awaiting_ci`, a poll is scheduled
  #   {:revise, state}   CI is red: the fix path launched an implementer
  #   {:done, state}     CI is red with no round left: reported to the author
  defp ci_gate(state, entry) do
    state = %{state | ci_entry: entry, ci_green: nil, ci_fallback: nil, ci_wait: nil}

    case ci_plan(state) do
      :off -> {:proceed, ci_end_wait(state)}
      {:fallback, reason} -> {:proceed, state |> ci_end_wait() |> ci_fall_back(reason)}
      {:ok, ctx, sha} -> ci_poll(%{state | ci_ctx: ctx}, ReviewCi.new_wait(sha, ctx.budget))
    end
  end

  defp ci_plan(state) do
    workspace = load_workspace(state.workspace_id)

    if ci_required?(state, workspace) do
      with {:ok, sha} <- ci_target_sha(state),
           {:ok, pr_ref} <- ci_pr_ref(state),
           {:ok, adapter} <- ReviewCi.adapter(workspace, state.repo, state.ci_adapter) do
        budget = ReviewCi.budget(workspace, state.repo)

        budget = %{
          interval_ms: state.ci_poll_ms || budget.interval_ms,
          max_polls: state.ci_max_polls || budget.max_polls
        }

        {:ok, %{workspace: workspace, adapter: adapter, pr_ref: pr_ref, budget: budget}, sha}
      else
        {:error, why} -> {:fallback, why}
      end
    else
      :off
    end
  end

  defp ci_required?(%{ci_gate_override: override}, _workspace) when is_boolean(override),
    do: override

  defp ci_required?(state, workspace), do: ReviewCi.required?(workspace, state.repo)

  defp ci_pr_ref(%{pr_ref: ref}) when is_binary(ref) and ref != "", do: {:ok, ref}

  defp ci_pr_ref(_state),
    do: {:error, "no PR to read CI from (the gate is reviewing the branch diff)."}

  # The head the reviewer is about to read. That is the tip of the branch on
  # origin — the review checkout is cut from it (`Checkout.provision_branch/3`) —
  # so it is asked of origin, not taken from the worktree: a commit someone else
  # pushed since our push is part of what would be reviewed, and CI has to vouch
  # for it. Falls back to the pushed head when origin cannot be asked.
  defp ci_target_sha(%{worktree_path: wt, branch: branch} = state) when is_binary(wt) do
    with {:ok, out} <- git_out(wt, ["ls-remote", "origin", "refs/heads/" <> branch]),
         [sha | _] <- String.split(out, ~r/\s+/, trim: true),
         true <- String.length(sha) >= 40 do
      {:ok, sha}
    else
      _ -> ci_pushed_sha(state)
    end
  end

  defp ci_target_sha(state), do: ci_pushed_sha(state)

  defp ci_pushed_sha(state) do
    case pushed_head(state) do
      {:ok, sha} -> {:ok, sha}
      _ -> {:error, "the head to wait on could not be determined."}
    end
  end

  # One reading of CI for the wait's head, and what to do about it.
  defp ci_poll(state, wait) do
    ctx = state.ci_ctx

    {reading, result} =
      ReviewCi.read(ctx.adapter, ctx.workspace, state.repo, ctx.pr_ref, wait.sha)

    {state, wait, reading} = ci_retarget(state, wait, reading, result)
    {action, wait} = ReviewCi.advance(wait, reading)
    ci_act(state, wait, action, result)
  end

  # The forge reports a head other than the one waited on. If the branch on
  # origin really did move on, wait on THAT head — the reviewer will read it —
  # and judge this same reading against it. A forge that merely lags keeps the
  # old target (and stays a mismatch, never green).
  defp ci_retarget(state, wait, {:head_mismatch, _} = reading, result) do
    with true <- state.ci_retargets < @ci_max_retargets,
         {:ok, sha} <- ci_target_sha(state),
         false <- ReviewCi.same_sha?(sha, wait.sha) do
      Logger.info(
        "ReviewGate: task=#{state.task_id} branch `#{state.branch}` moved from #{wait.sha} to " <>
          "#{sha} while waiting on CI; waiting on the new head"
      )

      state =
        record_thread(
          %{state | ci_retargets: state.ci_retargets + 1},
          :system,
          "Round #{state.round}: waiting on CI for a newer head",
          "The branch moved from #{wait.sha} to #{sha} while the gate waited on CI. The " <>
            "reviewer will read the new head, so CI has to pass on it."
        )

      {state, ReviewCi.retarget(wait, sha), ReviewCi.classify(result, sha)}
    else
      _ -> {state, wait, reading}
    end
  end

  defp ci_retarget(state, wait, reading, _result), do: {state, wait, reading}

  defp ci_act(state, wait, :green, result) do
    state = ci_end_wait(state)
    {:proceed, %{state | ci_green: %{sha: wait.sha, url: Map.get(result, :url)}}}
  end

  # Red, re-run, green: nothing was wrong with the diff. Recorded as a flake, no
  # fix pass, and the reviewer goes ahead on the green head.
  defp ci_act(state, wait, {:flake, checks}, result) do
    ReviewCi.record_flake(state.task_id, state.repo, checks, wait.sha)

    Logger.info(
      "ReviewGate: CI on #{wait.sha} for task=#{state.task_id} was red and went green on a " <>
        "re-run with no code change; recorded as a flake, no fix pass"
    )

    state =
      state
      |> ci_end_wait()
      |> record_thread(
        :system,
        "Round #{state.round}: CI flake",
        "CI on #{wait.sha} was red. Its failed jobs were re-run once with no code change and " <>
          "the head went green: recorded as a flake, no fix pass dispatched."
      )

    {:proceed, %{state | ci_green: %{sha: wait.sha, url: Map.get(result, :url)}}}
  end

  defp ci_act(state, wait, :wait, _result), do: {:wait, ci_schedule(state, wait)}

  # First red on this head: re-run the failed jobs once before anyone is sent to
  # fix anything. If that cannot be done, the failure is taken as real.
  defp ci_act(state, wait, :rerun, _result) do
    checks = ci_failing_checks(state)

    case ci_rerun(state) do
      :ok ->
        Logger.info(
          "ReviewGate: CI on #{wait.sha} for task=#{state.task_id} is red; " <>
            "re-running the failed jobs once"
        )

        {:wait, ci_schedule(state, ReviewCi.rerun_started(wait, checks))}

      {:error, why} ->
        Logger.warning(
          "ReviewGate: CI on #{wait.sha} for task=#{state.task_id} is red and could not be " <>
            "re-run (#{why}); treating it as a real failure"
        )

        ci_fix(state, wait, checks, false)
    end
  end

  defp ci_act(state, wait, :fix, _result) do
    stored = if wait.rerun, do: wait.rerun.checks, else: []

    checks =
      case ci_failing_checks(state) do
        [] -> stored
        fresh -> fresh
      end

    ci_fix(state, wait, checks, not is_nil(wait.rerun))
  end

  defp ci_act(state, _wait, {:fallback, reason}, _result),
    do: {:proceed, state |> ci_end_wait() |> ci_fall_back(reason)}

  # Red CI the gate cannot clear by itself goes down the revise loop that already
  # exists: the same implementer round a reviewer's REQUEST_CHANGES opens, with the
  # failing checks as its findings. The new head then waits for CI again before
  # the next review round. With no round left it is escalated like any
  # non-convergence — and the Worker's own fix round takes it from there.
  defp ci_fix(state, wait, checks, rerun?) do
    state = state |> ci_end_wait() |> Map.put(:approval_gap_pending, nil)
    findings = ReviewCi.failure_findings(wait.sha, state.ci_ctx.pr_ref, checks, rerun?)

    Logger.warning(
      "ReviewGate: CI is red on #{wait.sha} for task=#{state.task_id} " <>
        "(round #{state.round}/#{state.max_rounds}); sending it down the fix path"
    )

    if state.round >= state.max_rounds do
      state = record_enter_revise_thread(state, findings, :ci)
      record_round(state, :review, :request_changes, findings, converged: false)
      {:done, finish(state, terminal_reject_verdict(state))}
    else
      enter_revise(state, findings, :ci)
    end
  end

  defp ci_fall_back(state, reason) do
    note = ReviewCi.fallback_note(reason)

    Logger.warning(
      "ReviewGate: #{note} (task=#{state.task_id}, round #{state.round}); the reviewer runs the tests"
    )

    state =
      record_thread(state, :system, "Round #{state.round}: CI did not gate this review", note)

    %{state | ci_fallback: reason}
  end

  # Hold the reviewer back and poll again. Nothing is spawned and no timer but
  # the poll is armed: this is the one place the gate sits between rounds with
  # no agent, and it says so on the ticket (`ci_wait`) so the slot count and the
  # board see it. The marker is rewritten only when what it says changes.
  defp ci_schedule(state, wait) do
    token = make_ref()
    Process.send_after(self(), {:ci_poll, token}, state.ci_ctx.budget.interval_ms)
    marked = {wait.sha, not is_nil(wait.rerun)}

    already =
      case state.ci_wait do
        %{marked: ^marked} -> true
        _ -> false
      end

    # The author's own provider account is free while no agent is live for the
    # ticket (`Arbiter.Accounts.Concurrency`); it is told once, when the wait starts.
    if is_nil(state.ci_wait), do: tell_author(state, {:__review_gate_ci_wait__, true})

    unless already do
      extra = if wait.rerun, do: %{"rerun" => true}, else: %{}
      marker = ReviewCi.marker(wait.sha, state.round, state.ci_ctx.budget, extra)
      ReviewCi.put_marker(state.task_id, marker)
    end

    %{
      state
      | phase: :awaiting_ci,
        current_id: nil,
        ci_rearmed: false,
        ci_wait: %{wait: wait, token: token, marked: marked}
    }
  end

  defp tell_author(%{author: author}, msg) when is_pid(author), do: send(author, msg)
  defp tell_author(_state, _msg), do: :ok

  defp ci_end_wait(%{ci_wait: nil, ci_rearmed: true} = state) do
    ReviewCi.put_marker(state.task_id, nil)
    %{state | ci_rearmed: false, phase: :reviewing}
  end

  defp ci_end_wait(%{ci_wait: nil} = state), do: %{state | phase: :reviewing}

  defp ci_end_wait(state) do
    ReviewCi.put_marker(state.task_id, nil)
    tell_author(state, {:__review_gate_ci_wait__, false})
    %{state | ci_wait: nil, phase: :reviewing}
  end

  # The review checkout is cut from origin AFTER CI was read. If the branch moved
  # in between, CI did not vouch for what the reviewer is about to read: wait on
  # the head that is actually there (bounded), or, past the bound, review without
  # claiming CI.
  defp ci_verify_checkout(
         %{ci_green: %{sha: green}, review_checkout: %{head_sha: head}} = state,
         _
       ) do
    cond do
      ReviewCi.same_sha?(green, head) ->
        {:ok, state}

      state.ci_retargets < @ci_max_retargets ->
        Logger.info(
          "ReviewGate: task=#{state.task_id} review checkout is #{head} but CI was read on " <>
            "#{green}; waiting on CI for the new head"
        )

        {:retarget, %{release_review_checkout(state) | ci_retargets: state.ci_retargets + 1}}

      true ->
        state = %{state | ci_green: nil}

        {:ok,
         ci_fall_back(
           state,
           "the branch kept moving: the review checkout is #{head} but CI was read on #{green}."
         )}
    end
  end

  defp ci_verify_checkout(state, _entry), do: {:ok, state}

  # Where a finished wait goes next. `ci_entry` says which door it came in by.
  defp ci_reply({:proceed, %{ci_entry: {:next, review_id}} = state}) do
    case launch_next_reviewer(state, review_id) do
      {:continue, state} -> {:noreply, state}
      {:done, state} -> {:stop, :normal, state}
    end
  end

  defp ci_reply({:proceed, state}), do: launch_first_reviewer_after_ci(state)
  defp ci_reply({tag, state}) when tag in [:wait, :revise], do: {:noreply, state}
  defp ci_reply({:done, state}), do: {:stop, :normal, state}

  defp ci_next_reply({:proceed, state}, review_id), do: launch_next_reviewer(state, review_id)

  defp ci_next_reply({tag, state}, _review_id) when tag in [:wait, :revise],
    do: {:continue, state}

  defp ci_next_reply({:done, state}, _review_id), do: {:done, state}

  defp ci_failing_checks(%{ci_ctx: ctx} = state) do
    fetch = fn ->
      if Code.ensure_loaded?(ctx.adapter) and
           function_exported?(ctx.adapter, :failing_check_logs, 1),
         do: ctx.adapter.failing_check_logs(ctx.pr_ref),
         else: {:ok, []}
    end

    case ReviewCi.call(ctx.workspace, state.repo, fetch) do
      {:ok, {:ok, checks}} when is_list(checks) -> checks
      _ -> []
    end
  end

  defp ci_rerun(%{ci_ctx: ctx} = state) do
    rerun = fn ->
      if Code.ensure_loaded?(ctx.adapter) and function_exported?(ctx.adapter, :rerun_ci, 2),
        do: ctx.adapter.rerun_ci(ctx.pr_ref, %{}),
        else: {:error, "the adapter has no CI re-run"}
    end

    case ReviewCi.call(ctx.workspace, state.repo, rerun) do
      {:ok, {:ok, _info}} -> :ok
      {:ok, {:error, reason}} -> {:error, inspect(reason)}
      {:error, why} -> {:error, why}
    end
  end

  # What the reviewer is told about CI. Only a head CI was read on says so.
  defp ci_prompt_block(state) do
    green = Map.get(state, :ci_green)

    cond do
      is_map(green) and ci_green_matches_checkout?(state, green) ->
        ReviewCi.green_block(green)

      is_binary(Map.get(state, :ci_fallback)) ->
        ReviewCi.fallback_block(state.ci_fallback)

      true ->
        ""
    end
  end

  defp ci_green_matches_checkout?(%{review_checkout: %{head_sha: head}}, %{sha: sha}),
    do: ReviewCi.same_sha?(sha, head)

  defp ci_green_matches_checkout?(_state, _green), do: true

  # ---- bring the branch current with its target (bd-ased52) ---------------

  # Before reviewing, bring the branch up to date with its target so the
  # reviewer diffs against the CURRENT target tip, not the stale base it was cut
  # from. When the target advances mid-run, an un-updated branch makes the
  # target's unrelated commits look like the branch's own work — a phantom
  # "out-of-scope" / "empty branch" finding that false-rejects correct work.
  #
  #   * clean update (merged / already up to date) → proceed; record the
  #     merge-base so the reviewer diff isolates the branch's own changes.
  #   * conflict → do NOT review a stale/conflicted branch. Return a conflict
  #     escalation so the gate escalates for resolution (mirrors the #97
  #     abort-on-conflict posture; the merge is aborted by update_from_target/2,
  #     leaving the worktree clean).
  #   * any other git error (no origin, fetch failed) → fail open and proceed;
  #     the merge-base diff still isolates the branch's own changes.
  #
  # Skipped when there is no worktree, or the worktree is not checked out on the
  # branch under review (mirrors reviewer_commit_check/1's branch guard) — an
  # ad-hoc / test rig pointed at a repo on `main` must not try to merge.
  defp prepare_branch_for_review(
         %{worktree_path: wt, branch: branch, target_branch: target} = state
       )
       when is_binary(wt) do
    case Arbiter.Worker.Worktree.current_branch(wt) do
      {:ok, ^branch} ->
        # Fetch the task branch from origin FIRST so the local worktree reflects
        # the commits the implementer pushed (bd-31bh37). Without this step, a
        # commit pushed from a different git context (e.g. the main repo checkout
        # rather than the per-task worktree) would not be visible locally, making
        # the diff appear empty even though origin has the work.
        case Arbiter.Worker.Worktree.sync_from_origin(wt, branch) do
          {:ok, result} when result in [:up_to_date, :synced] ->
            Logger.info(
              "ReviewGate: branch `#{branch}` sync_from_origin=#{result} for task=#{state.task_id}"
            )

          {:error, sync_reason} ->
            Logger.warning(
              "ReviewGate: could not sync branch `#{branch}` from origin for " <>
                "task=#{state.task_id} (proceeding): #{inspect(sync_reason)}"
            )
        end

        case Arbiter.Worker.Worktree.update_from_target(wt, target) do
          {:ok, result} ->
            Logger.info(
              "ReviewGate: branch `#{branch}` #{result} with `#{target}` for task=#{state.task_id}"
            )

            {:ok, with_base_sha(state)}

          {:error, {:conflict, info}} ->
            {:error, {:conflict, conflict_escalation(state, info)}}

          {:error, reason} ->
            Logger.warning(
              "ReviewGate: could not update branch `#{branch}` from `#{target}` for " <>
                "task=#{state.task_id} (proceeding with merge-base diff): #{inspect(reason)}"
            )

            {:ok, with_base_sha(state)}
        end

      _ ->
        # Worktree is on a different branch (or current_branch failed) — don't
        # merge into something we don't own; still resolve the merge-base for
        # the reviewer diff.
        {:ok, with_base_sha(state)}
    end
  end

  defp prepare_branch_for_review(state), do: {:ok, with_base_sha(state)}

  defp with_base_sha(%{worktree_path: wt, target_branch: target} = state) when is_binary(wt) do
    %{state | base_sha: Arbiter.Worker.Worktree.merge_base(wt, target)}
  end

  defp with_base_sha(state), do: state

  # ---- the head under review must be the pushed PR head (bd-2jkrqu) --------
  #
  # Everything downstream of here reads the LOCAL worktree: the reviewer agent
  # opens files in it, `empty_diff_guard/1` diffs `base_sha..HEAD` in it, and
  # an APPROVE stamps `git rev-parse HEAD`. That is only sound while local HEAD
  # is a commit `origin/<branch>` carries. On vs-5l45oz it was not: the fix
  # round committed `edadf22c` locally and never pushed, so round 2 reviewed —
  # and approved — code the MR did not have.
  #
  # So before any round is paid for, make the head reachable on the remote:
  #
  #   * already there (or an ancestor of the remote tip) → proceed;
  #   * ahead / never pushed → ONE push, then proceed on the same SHA;
  #   * diverged, or the push was rejected → refuse. `origin/<branch>` may
  #     carry another actor's commits (a ReviewGate implementer round pushes
  #     straight to origin), so this never force-pushes; a human resolves it.
  #   * push state undeterminable (no worktree, no `origin`, git unavailable,
  #     or the worktree is not checked out on `branch`) → fail open and review
  #     exactly as before this guard existed. A local ad-hoc checkout is not an
  #     incident.
  #
  # The last of those is the sibling guard `prepare_branch_for_review/1` and
  # `reviewer_commit_check/1` spell out inline (`current_branch(wt) == branch`;
  # see also `Arbiter.Worker` around the reviewer-commit check): ad-hoc runs and
  # test rigs reuse a repo as the worktree with HEAD on `main`. Here it is not
  # spelled out again because `PushState.inspect_branch/3` enforces it as a
  # module precondition — `:not_on_branch` → `:unknown` — so `ensure_pushed/3`,
  # `reviewable_head/3` and the park text all get it, and no later caller can
  # reintroduce the hole by forgetting it. Without it this guard would push
  # `main`'s tip to `refs/heads/<branch>`: a merge-safety guard writing the
  # wrong commit to the very branch it protects.
  #
  # One evaluation and at most one push per round — `GuardRegistry` row G18.
  defp push_gate(%{worktree_path: wt, branch: branch} = state)
       when is_binary(wt) and is_binary(branch) do
    case PushState.ensure_pushed(wt, branch) do
      {:ok, :already_pushed, _push_state} ->
        :ok

      {:ok, :pushed, push_state} ->
        Logger.info(
          "ReviewGate: pushed `#{branch}` to #{push_state.remote} before round " <>
            "#{state.round} for task=#{state.task_id} (head #{push_state.local_head})"
        )

        :ok

      {:ok, :unknown, push_state} ->
        Logger.info(
          "ReviewGate: push state of `#{branch}` undeterminable for task=#{state.task_id} " <>
            "(#{push_state.status}); reviewing the local head"
        )

        :ok

      {:error, reason, push_state} ->
        escalate_unpushed_head(state, push_state, reason)
    end
  end

  defp push_gate(_state), do: :ok

  # ---- the reviewer's own checkout at the pushed head (bd-a22hib) ----------
  #
  # The in-gate reviewer used to run in the implementer's own worktree, under
  # the plain workspace policy. It read the implementer's LOCAL state rather
  # than what was pushed (the cause `push_gate/1` only guards against), nothing
  # but the prompt kept it from writing to the branch it was reviewing, and its
  # test runs shared the implementer's `_build` and `deps`.
  #
  # So every review round now gets what a dispatched reviewer (`review: true`,
  # bd-199giy) already gets: `Checkout.provision_branch/3` — fetch the branch
  # from `origin`, resolve the fetched tip, check THAT commit out detached into
  # a throwaway worktree — and `Dispatch.review_security_policy/2`'s
  # Edit/Write/NotebookEdit denial. It runs after `push_gate/1`, so the tip
  # `origin` hands back is the head the round just pushed or confirmed. The
  # checked-out SHA is what an APPROVE stamps and records coverage for
  # (`reviewed_head/1`): what was reviewed is exactly what the merge guard
  # compares against.
  #
  # One checkout per round, shared by every pass of that round (a re-prompt, a
  # timeout retry and a provider rotation all read the same diff). Released
  # when the round ends — `enter_revise/2` on a reject, `terminate/2` on every
  # terminal path — and swept on boot (`Checkout.sweep_orphans/1`) for a gate
  # that never reached `terminate/2`.
  #
  # Skipped only when there is nothing to check out from: no worktree, or a
  # worktree positively checked out on some OTHER branch — the ad-hoc / test-rig
  # shape `prepare_branch_for_review/1`, `reviewer_commit_check/1` and
  # `PushState` all already treat as "not the task's branch worktree". Every
  # other failure is returned, and the round parks naming it: falling back to
  # the implementer's worktree would silently reintroduce the thing this fixes.

  @review_checkout_prefix "gate-review"

  @doc """
  The leaf prefix of an in-gate reviewer checkout under the worktree root —
  what `Arbiter.Reviews.Checkout.sweep_orphans/1` reclaims on boot.
  """
  @spec review_checkout_prefix() :: String.t()
  def review_checkout_prefix, do: @review_checkout_prefix

  @doc """
  Boot sweep for in-gate reviewer checkouts whose gate died without reaching
  `terminate/2` (a server restart, a brutal kill). Removes every
  `review_checkout_prefix/0` leaf under the worktree root that predates this
  VM; returns the removed paths. A non-primary instance (`primary?: false`)
  sweeps nothing — the live instance's gates own those checkouts.

  Extra opts are passed through to `Arbiter.Reviews.Checkout.sweep_orphans/1`
  (`:root`, `:before`).
  """
  @spec sweep_orphaned_review_checkouts(keyword()) :: [String.t()]
  def sweep_orphaned_review_checkouts(opts \\ []) do
    {primary?, opts} = Keyword.pop(opts, :primary?, true)

    if primary? do
      Checkout.sweep_orphans([prefix: @review_checkout_prefix] ++ opts)
    else
      []
    end
  end

  @doc """
  Provision the current review round's detached checkout at the head `origin`
  carries for `state.branch`, and record it on `state.review_checkout`
  (`%{path:, head_sha:}`). Any checkout the state still held is released first,
  so a gate never holds two.

  Returns `{:ok, state}` unchanged (no checkout) when there is nothing to check
  out from — no `worktree_path`, or a worktree checked out on a different branch
  than `state.branch`. Returns `{:error, reason}` for every other failure; the
  caller parks the round rather than reviewing in the implementer's worktree.

  Public so the remote-head property can be exercised directly against a real
  worktree with unpushed commits; the gate reaches it at the start of every
  review round.
  """
  @spec provision_review_checkout(map()) :: {:ok, map()} | {:error, term()}
  def provision_review_checkout(state) do
    state = release_review_checkout(state)

    case review_checkout_source(state) do
      :none ->
        {:ok, state}

      {:ok, wt, branch} ->
        case Checkout.provision_branch(wt, branch, prefix: @review_checkout_prefix) do
          {:ok, %{path: path, head_sha: sha}} ->
            # The reviewer may run tests here. Seed the implementer's fetched
            # and compiled deps (never the umbrella apps themselves — those
            # compile fresh from the checked-out source) so a test run does not
            # start from a cold `deps.get` + full dep compile. Copies, not
            # symlinks: nothing the reviewer builds reaches the implementer's
            # tree. Best-effort, and a no-op for a repo with no `deps`/`_build`.
            #
            # bd-2jerqw: `worker.repos.<repo>.seed_paths` applies here too, read
            # from the implementer's tree `wt`, which was seeded by the same list.
            seed_paths =
              SeedPaths.resolve(
                load_workspace(Map.get(state, :workspace_id)),
                Map.get(state, :repo)
              )

            :ok = Worktree.seed_compiled_deps(wt, path, seed_paths)

            Logger.info(
              "ReviewGate: round #{Map.get(state, :round)} for task=#{Map.get(state, :task_id)} " <>
                "reviews #{String.slice(sha, 0, 12)} in its own checkout #{path}"
            )

            {:ok, Map.put(state, :review_checkout, %{path: path, head_sha: sha})}

          {:error, reason} ->
            Logger.warning(
              "ReviewGate: could not provision a review checkout of `#{branch}` for " <>
                "task=#{Map.get(state, :task_id)}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  @doc """
  Remove the current round's review checkout, if any, and clear
  `state.review_checkout`. Idempotent; never fails (`Checkout.teardown/1`).
  """
  @spec release_review_checkout(map()) :: map()
  def release_review_checkout(%{review_checkout: %{path: path}} = state) do
    :ok = Checkout.teardown(path)
    %{state | review_checkout: nil}
  end

  def release_review_checkout(state), do: state

  defp review_checkout_source(%{worktree_path: wt, branch: branch})
       when is_binary(wt) and is_binary(branch) do
    case Worktree.current_branch(wt) do
      {:ok, ^branch} -> {:ok, wt, branch}
      {:ok, _other_branch} -> :none
      {:error, _} -> {:ok, wt, branch}
    end
  end

  defp review_checkout_source(_state), do: :none

  defp checkout_failure_message(state, reason) do
    """
    ReviewGate could not provision the review checkout for round #{state.round}:
    a detached, write-denied checkout of `#{state.branch}` at the head `origin`
    carries, which is where the reviewer runs (bd-a22hib).

    Reason: #{inspect(reason)}

    No reviewer was run. It was deliberately NOT run in the implementer's
    worktree instead: that tree can hold unpushed or uncommitted work, and the
    reviewer could write to the branch it is reviewing. Nothing about the work
    itself has been faulted — fix the cause (worktree root writable, `origin`
    reachable, the branch fetchable) and re-run the review.
    """
    |> String.trim()
  end

  # Where a pass runs. Only a reviewer moves into the round's checkout; the fix
  # pass (and a reviewer with no checkout — see `review_checkout_source/1`)
  # stays in the implementer's worktree.
  defp session_cwd(%{review_checkout: %{path: path}}, :reviewer), do: path
  defp session_cwd(state, _role), do: state.worktree_path

  # The tree the reviewer actually read: the round's checkout when there is one.
  defp review_tree(%{review_checkout: %{path: path}}), do: path
  defp review_tree(state), do: Map.get(state, :worktree_path)

  @doc """
  The security policy a ReviewGate pass spawns under.

  The workspace posture scoped to `state.repo` for every pass — the same
  resolution the dispatch spawn path uses (bd-9u10op, bd-3gc18m). A reviewer
  standing in its round's checkout additionally goes through
  `Arbiter.Worker.Dispatch.review_security_policy/2`, the one hardening every
  worktree-backed reviewer shares: Edit/Write/NotebookEdit denied. The
  implementer keeps the plain posture — it is the one pass meant to write.

  Both roles spawn under `sandbox.review_backend`, not `sandbox.backend`
  (`SecurityPolicy.for_review_spawn/1`, bd-4rvf98): a podman repo still gets a
  jailed, un-parked review, and a `review_backend` that cannot run is refused.
  """
  @spec session_security_policy(Workspace.t() | map() | nil, map(), :reviewer | :implementer) ::
          SecurityPolicy.t()
  def session_security_policy(ws, state, role) do
    checkout =
      case {role, Map.get(state, :review_checkout)} do
        {:reviewer, %{path: _} = checkout} -> checkout
        _ -> nil
      end

    policy = SecurityPolicy.resolve(ws, %{}, Map.get(state, :repo))

    case role do
      :reviewer ->
        Dispatch.review_security_policy(policy, review_checkout: checkout, review: true)

      # The revise pass writes in the implementer's tree, so it keeps the plain
      # posture, but not the implement backend: `sandbox.backend: podman` wraps
      # the task worker only, so a gate pass under it was refused (bd-4rvf98).
      :implementer ->
        SecurityPolicy.for_review_spawn(policy)
    end
  end

  # The head an APPROVE stamps and records coverage for. With a round checkout
  # it is the SHA the reviewer was actually handed — fetched from `origin` after
  # the push gate — so the reviewed SHA the merge guard compares against is
  # exactly what was reviewed, even if the implementer's local HEAD has since
  # moved. Without one, the bd-2jkrqu `pushed_head/1` answer as before.
  defp reviewed_head(%{review_checkout: %{head_sha: sha}}) when is_binary(sha) and sha != "",
    do: {:ok, sha}

  defp reviewed_head(state), do: pushed_head(state)

  # The findings text for a head that could not be put on the remote branch.
  # Returned (not sent) so the caller decides which terminal it belongs to —
  # a pre-review park on round 1, a park on the fix round's re-review.
  defp escalate_unpushed_head(state, push_state, reason) do
    Logger.warning(
      "ReviewGate: refusing to review an unpushed head for task=#{state.task_id} " <>
        "(#{push_state.status}, #{inspect(reason)})"
    )

    {:error,
     """
     ReviewGate refused to review `#{state.branch}`: the head it would review is
     not on the remote branch the merge request points at, and could not be
     pushed there.

     #{PushState.describe(push_state)}
     Push attempt: #{inspect(reason)}.

     Reviewing this head would produce a verdict about code the MR does not
     carry — the bd-2jkrqu failure, where an unpushed fix round was approved
     while the MR still held the unfixed commit. **Do not merge this branch by
     hand on the strength of a review it has not had.**

     To clear it: reconcile `#{state.branch}` with `#{push_state.remote}/#{state.branch}`
     (rebase or merge — never force-push, the remote may carry another worker's
     commits), push, and re-run the review.
     """
     |> String.trim()}
  end

  # The fix round's re-review terminal for an unpushed head. `dispatch_next_review/1`
  # runs inside the revise loop, so it takes the loop's own `finish/2` terminal
  # rather than `escalate_pre_review/3`'s `{:stop, …}` handle_continue shape.
  # Parks (class B/C posture): nothing merges, the run is not failed, and one
  # escalation names the real push state.
  defp escalate_pre_review_park(state, reason) do
    record_round(state, :review, :request_changes, reason, converged: false)
    finish(state, {:parked, :head_not_pushed, reason})
  end

  # The local head, used only to name a SHA in a coverage-write failure page —
  # never to write a coverage row (see `pushed_head/1`).
  defp local_head_for_report(state), do: full_head_sha_in(Map.get(state, :worktree_path))

  @doc """
  The head SHA a reviewed-SHA stamp or a `review_coverage` row may name, or a
  refusal (bd-2jkrqu, acceptance 2).

  `{:error, {:head_not_pushed, push_state}}` means the local head is positively
  not on `origin/<branch>`: recording it would assert that the PR's head has
  been reviewed when the PR carries a different commit. That write is exactly
  what made the vs-5l45oz approval look legitimate, so it is refused and paged
  rather than made.

  An undeterminable push state falls back to the local head — the behaviour
  before this guard existed. That includes a worktree that is not checked out
  on `branch`: its HEAD is some other branch's commit, so it is neither
  accused of being unpushed nor blessed as the PR head.

  Public so the refusal can be exercised directly against a real worktree; the
  gate's own path reaches it through `stamp_reviewed_head/1` and
  `record_review_coverage/1`.
  """
  @spec pushed_head(map()) :: {:ok, String.t()} | {:error, {:head_not_pushed, map()} | :no_head}
  def pushed_head(state) do
    wt = Map.get(state, :worktree_path)
    branch = Map.get(state, :branch)

    case PushState.reviewable_head(wt, branch, fetch?: false) do
      {:ok, sha} -> {:ok, sha}
      {:error, {:head_not_pushed, _} = err} -> {:error, err}
      {:error, :no_head} -> fallback_head(wt)
    end
  end

  # `PushState` reads `git rev-parse HEAD`; when there is no git at all the
  # gate still has `full_head_sha_in/1`'s answer (nil for a missing worktree),
  # which the callers already handle.
  defp fallback_head(wt) do
    case full_head_sha_in(wt) do
      sha when is_binary(sha) and sha != "" -> {:ok, sha}
      _ -> {:error, :no_head}
    end
  end

  # The escalation findings for a branch that conflicts with its target: name
  # the conflicting files and instruct resolution. A request_changes verdict, so
  # the author parks + escalates to the coordinator rather than merging stale work.
  defp conflict_escalation(state, %{files: files}) do
    files_block =
      case files do
        [] -> "  (conflicting paths could not be determined)"
        _ -> Enum.map_join(files, "\n", &("  - " <> &1))
      end

    """
    Branch `#{state.branch}` conflicts with its target `#{state.target_branch}`
    and cannot be reviewed in a stale/conflicted state. The review gate fetched
    `origin/#{state.target_branch}` and tried to merge it into the branch to bring
    the diff current, but the merge hit textual conflicts. The merge was ABORTED,
    so the worktree is left clean on the branch's own HEAD.

    Resolve the conflict before review: merge or rebase `origin/#{state.target_branch}`
    into `#{state.branch}`, resolve the conflicting files, commit, and re-run the
    gate. Surfacing the conflict here is intentional — reviewing a stale base would
    mis-attribute the target's commits to this branch (bd-ased52).

    Conflicting files:
    #{files_block}
    """
    |> String.trim()
  end

  # A ReviewGate is NOT a worker, but it lives under Arbiter.Worker.Supervisor —
  # so a stray enumeration (dashboard / list_children) could probe it with the
  # worker `:snapshot` call. Answer gracefully instead of crashing the gate and
  # stranding the author waiting on the review gate. See bd-2y0gd5.
  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot(state), state}
  end

  # Capture output only from the worker we're currently waiting on; a late line
  # from a prior (stopped) reviewer/implementer must not contaminate this pass.
  # bd-cwe9n2: how many times a denial-ended reviewer turn is waited out (the
  # reviewer Worker resumes the same agy conversation, capped by its own
  # `resume_cap`) before the pass is scored as it stands.
  @max_denial_defers 3

  @impl true
  def handle_info({:worker_output, id, line}, %{current_id: id} = state) do
    {:noreply, %{state | lines: [line | state.lines]}}
  end

  def handle_info({:worker_output, _other, _line}, state), do: {:noreply, state}

  # bd-cwe9n2: the reviewer's turn was ended by a headless permission soft-deny.
  # Sent just ahead of that pass's `:worker_exited`.
  def handle_info({:worker_denied, id, command}, %{current_id: id} = state) do
    denied =
      if is_binary(command) and command != "",
        do: Enum.uniq(state.denied_commands ++ [command]),
        else: state.denied_commands

    {:noreply, %{state | denied_commands: denied, denial_pending: true}}
  end

  def handle_info({:worker_denied, _other, _command}, state), do: {:noreply, state}

  # The reviewer Worker could not resume the denied conversation: stop waiting
  # for it and score what the pass produced.
  def handle_info({:worker_resume_abandoned, id}, %{current_id: id, phase: :reviewing} = state) do
    handle_info(
      {:worker_exited, id, 0},
      %{state | denial_pending: true, denial_defers: @max_denial_defers}
    )
  end

  def handle_info({:worker_resume_abandoned, _other}, state), do: {:noreply, state}

  # The current worker's subprocess exited — its transcript is complete. Dispatch
  # by phase: a finished reviewer yields a verdict (or a re-prompt / a revise); a
  # finished implementer closes the round and triggers the next reviewer pass.
  # (Each worker worker also self-completes on its own `arb done`; either way
  # the exit is our reliable "transcript done" signal.)
  def handle_info({:worker_exited, id, status}, %{current_id: id, phase: :reviewing} = state) do
    case state |> clear_pass() |> attempt_finish(status) do
      {:done, state} -> {:stop, :normal, state}
      {:reprompt, state} -> {:noreply, state}
      {:revise, state} -> {:noreply, state}
    end
  end

  def handle_info({:worker_exited, id, _status}, %{current_id: id, phase: :revising} = state) do
    case state |> clear_pass() |> finish_revise() do
      {:done, state} -> {:stop, :normal, state}
      {:continue, state} -> {:noreply, state}
    end
  end

  # A stale exit from an worker we've moved on from.
  def handle_info({:worker_exited, _other, _status}, state), do: {:noreply, state}

  # bd-cut6uv: a poll of the CI wait. The token says which wait armed it: a
  # poll for a wait that has since resolved (or been replaced) is ignored.
  def handle_info(
        {:ci_poll, token},
        %{ci_wait: %{token: token, wait: wait}, reported?: false} = state
      ) do
    state |> ci_poll(wait) |> ci_reply()
  end

  def handle_info({:ci_poll, _stale}, state), do: {:noreply, state}

  # Timeouts are tagged with the {round, attempt} pair that scheduled them so
  # a stale timer from a prior pass can't escalate a pass that has already
  # advanced. `attempt` alone is not enough (bd-28u8v4): it resets to 0 at the
  # start of every round (bd-bgeo6i, so reprompt budgets start fresh), so
  # round N's implementer and round N+1's implementer are both launched as the
  # same attempt number and a timer armed for the former would otherwise be
  # accepted as belonging to the latter. `round` never repeats within a gate's
  # lifetime, so the pair is unique for as long as the gate runs.
  def handle_info({:timeout, _round, _attempt}, %{reported?: true} = state),
    do: {:noreply, state}

  # A reviewing pass hit the ceiling. Before escalating as timed-out, retry the
  # pass once with a fresh reviewer mind (bd-78vg4v): a hung / overloaded session
  # is usually transient API variance, not a code problem, and a clean second
  # attempt converges where the first stalled. Only the reviewing phase is
  # retried — a revising (implementer) pass still escalates on timeout below.
  def handle_info(
        {:timeout, round, attempt},
        %{round: round, attempt: attempt, phase: :reviewing, timeout_retries_left: budget} =
          state
      )
      when budget > 0 and is_binary(state.current_prompt) do
    Logger.warning(
      "ReviewGate: reviewing pass timed out for task=#{state.task_id} (round #{state.round}); " <>
        "retrying with a fresh reviewer (#{budget} left)"
    )

    stop_worker(state)
    retry_id = timeout_retry_id(state.current_id, state.attempt)

    case launch_worker(
           %{state | timeout_retries_left: budget - 1},
           retry_id,
           :reviewer,
           state.current_prompt,
           state.command
         ) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning(
          "ReviewGate: timeout retry failed to spawn for task=#{state.task_id}: #{inspect(reason)}"
        )

        escalate_timeout(state)
    end
  end

  def handle_info({:timeout, round, attempt}, %{round: round, attempt: attempt} = state) do
    Logger.warning(
      "ReviewGate: #{state.phase} pass timed out for task=#{state.task_id} (round #{state.round})"
    )

    escalate_timeout(state)
  end

  def handle_info({:timeout, _stale_round, _stale_attempt}, state), do: {:noreply, state}

  # Author died before we could report — nothing to do.
  #
  # bd-2yt0d2: unless the author went because the node is stopping. Then the
  # pass this gate had in flight is the one the next boot restarts, and the
  # `pass` marker it left on the ticket is what says so — a `:normal` stop
  # would have `terminate/2` clear it.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{author: pid} = state) do
    if server_shutdown?(reason),
      do: {:stop, :shutdown, state},
      else: {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # An author stopped on purpose (`{:shutdown, :operator_stop}`) took its review
  # with it; one the supervisor shut down did not.
  defp server_shutdown?(:shutdown), do: true
  defp server_shutdown?({:shutdown, :operator_stop}), do: false
  defp server_shutdown?({:shutdown, _}), do: true
  defp server_shutdown?(_), do: false

  @impl true
  def terminate(reason, state) do
    # Stop the current worker worker if it's still alive (e.g. on timeout).
    #
    # bd-2yt0d2: with the reason the gate itself stops for when that is the node
    # stopping. A `:normal` stop stamps the pass's run `:succeeded`; the pass did
    # not succeed, the server stopped under it — its run is `:interrupted`,
    # "server shutdown", as it is when the supervisor stops the worker itself.
    if is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid) do
      stop_reason = if server_shutdown?(reason), do: :shutdown, else: :normal
      safe(fn -> Worker.stop(state.reviewer_pid, stop_reason) end)
    end

    # bd-a22hib: every terminal path — APPROVE, a reject at the cap, a park, a
    # timeout, a reviewer that died, the author going away, a crash in a
    # callback — ends in `{:stop, …}` and so lands here. Releasing the round's
    # checkout AFTER stopping the reviewer means nothing is still standing in
    # it. A gate killed outright (no `terminate/2`) is covered by the boot
    # sweep, `Arbiter.Reviews.Checkout.sweep_orphans/1`.
    _ = release_review_checkout(state)

    # bd-2yt0d2: a gate that ends on its own terms leaves no pass to restart. One
    # that is stopped because the node is — and one killed outright, which gets
    # no `terminate/2` at all — leaves its marker for the boot sweep.
    if reason == :normal, do: clear_pass(state)

    # bd-cut6uv: a gate that ends mid-wait (the author went away, a crash) must
    # not leave its ticket marked as waiting on CI.
    if is_map(Map.get(state, :ci_wait)) do
      tell_author(state, {:__review_gate_ci_wait__, false})
      safe(fn -> ReviewCi.put_marker(state.task_id, nil) end)
    end

    :ok
  end

  # ---- review pass outcome -----------------------------------------------

  # Parse the captured reviewer transcript. On APPROVE, report and stop. On
  # REQUEST_CHANGES, enter the revise loop (rounds remaining) or escalate with the
  # full transcript (exhausted). On a missing verdict, re-prompt (capped) before
  # escalating as inconclusive. Returns `{:done, state}` to stop, `{:reprompt,
  # state}` to wait on a verdict follow-up, or `{:revise, state}` to wait on an
  # implementer.
  defp attempt_finish(%{reported?: true} = state, _status), do: {:done, state}

  # Pre-existing complexity 15 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp attempt_finish(state, status) do
    # bd-6dxit2: `state.lines` is the reviewer's PubSub-captured transcript and
    # is not itself capped, but it is a *live* buffer — a line broadcast before
    # this pass subscribed, or dropped anywhere on the way, is simply absent, and
    # `:no_verdict` cannot tell that apart from a reviewer that stayed silent.
    # `parse_verdict/3` cross-checks the uncapped durable transcript before
    # conceding and logs the disagreement when there is one, so the escalation
    # blames the right party.
    lines = Enum.reverse(state.lines)
    run_id = reviewer_run_id(state)

    {verdict, _source} = parse_verdict(lines, run_id, "reviewer task=#{state.current_id}")

    case verdict do
      # bd-cwe9n2: agy ended the reviewer's turn on a denied command, so the
      # missing verdict is not the reviewer's conclusion. The reviewer Worker
      # resumes the same conversation with a "carry on without it" prompt; its
      # output keeps arriving on this topic and the resumed session's exit
      # lands back here.
      :no_verdict when state.denial_pending and state.denial_defers < @max_denial_defers ->
        Logger.info(
          "ReviewGate: reviewer for task=#{state.task_id} ended on a denied command " <>
            "(#{inspect(List.last(state.denied_commands))}); waiting for the resumed session"
        )

        {:reprompt, %{state | denial_pending: false, denial_defers: state.denial_defers + 1}}

      :no_verdict ->
        case classify_stop(status, state.lines) do
          # bd-3hb4ih: a print-timeout is the one infra failure a DIFFERENT
          # provider can still answer — the wall belongs to the CLI, not to the
          # account or the gateway. Rotate through `review_agent.type` before
          # conceding. Must precede the generic infra arm below, which parks.
          %StopReason{category: :agent_print_timeout} = reason ->
            handle_reviewer_print_timeout(state, reason)

          %StopReason{category: category} = reason when category in @infra_failure_categories ->
            Logger.warning(
              "ReviewGate: reviewer for task=#{state.task_id} died of an infrastructure " <>
                "failure (#{category}); escalating without a re-prompt"
            )

            {:done,
             finish(
               state,
               {:parked, infra_park_reason(category), infra_failure_message(reason)}
             )}

          _ ->
            # bd-869mmg round 2/3: carry the run id and scanned line counts this
            # pass already resolved forward onto state (both as the "latest scan"
            # and appended to the running history of every pass's scan), so a
            # final `:no_verdict` escalation (after the re-prompt budget is spent)
            # can both report the counts it saw and re-check every EARLIER pass's
            # durable transcript before conceding (see `recover_verdict_from_scans/1`).
            scan = verdict_scan_info(lines, run_id)

            maybe_reprompt(
              %{state | verdict_scan: scan, verdict_scans: [scan | state.verdict_scans]},
              :no_verdict
            )
        end

      verdict ->
        dispatch_verdict(state, verdict)
    end
  end

  # The APPROVE / REQUEST_CHANGES dispatch shared by a pass's own live verdict
  # (`attempt_finish/2`) and a verdict recovered from an earlier pass's durable
  # transcript after the current pass itself came back `:no_verdict`
  # (`maybe_reprompt/2`'s final concession, via `recover_verdict_from_scans/1`) —
  # both cases need the same criteria/partial-verification/empty-findings
  # guards applied before the outcome is final.
  defp dispatch_verdict(state, {:approve, findings} = verdict) do
    # bd-4yhv4x: an APPROVE on a criteria-bearing task must NOT clean-merge
    # unless the reviewer actually accounted for every acceptance criterion —
    # the same fail-closed treatment `partial_verification?` gets. Only gate
    # when the task HAS acceptance criteria (Option B): a task with no stated
    # criteria has nothing to break down, so its APPROVE finalizes as before.
    # Two failure modes are caught, both routed away from a clean merge:
    #   * the breakdown admits a `[NOT MET]` criterion  → the :unmet_criteria guard
    #   * NO CRITERIA breakdown at all (a bare holistic APPROVE that judges
    #     code quality, not criteria satisfaction — the original bug's exact
    #     shape) → the :missing_criteria guard
    # Enforcing the breakdown only via prompt text left the gate itself open:
    # a reviewer that ignored the instruction reproduced occurrences #1/#2.
    # bd-6r8caj: FIRST, before any criteria question, ask whether this round
    # even accounted for the findings already open against the work. A
    # revision round could previously return APPROVE / VERIFICATION: FULL
    # having never revisited the finding it raised itself one round earlier
    # (observed on bd-8mtb0q): findings were free prose, so "was F1.1
    # addressed?" was not a question the gate could ask. Now it is, and an
    # APPROVE that leaves a Medium-or-higher finding with no disposition —
    # or marks one [NOT ADDRESSED], or claims [ADDRESSED] against a file no
    # revision touched — is treated as malformed, exactly like a missing
    # `VERDICT:` line. Round 1 has nothing open, so the common path is
    # untouched.
    gap = approval_gap(state, findings)

    cond do
      # bd-954ym8: a scoped conflict review has no acceptance criteria to
      # break down and no earlier findings to disposition — it judges only
      # the resolved hunks, so the criteria and gap guards (which exist for
      # a whole-branch review) do not apply to its APPROVE.
      conflict_round?(state) ->
        finalize_approval(state, verdict, findings)

      ReviewFindings.gap?(gap) ->
        run_verdict_guard(:unaddressed_findings, state, findings, gap)

      has_acceptance_criteria?(state) and ReviewVerification.unmet_criteria?(findings) ->
        run_verdict_guard(:unmet_criteria, state, findings)

      has_acceptance_criteria?(state) and not ReviewVerification.criteria_present?(findings) ->
        run_verdict_guard(:missing_criteria, state, findings)

      true ->
        finalize_approval(state, verdict, findings)
    end
  end

  defp dispatch_verdict(state, {:request_changes, findings}) do
    # A REQUEST_CHANGES verdict that names no concrete findings is useless: the
    # implementer has nothing to act on, the gate stalls, and a full review is
    # wasted (bd-3y2mda). Treat it as malformed and re-prompt for findings
    # (capped, shares the verdict-retry budget) rather than entering the revise
    # loop with empty hands.
    cond do
      not findings_present?(findings) ->
        maybe_reprompt(state, :empty_findings)

      partial_verification?(state, findings) ->
        run_verdict_guard(:partial_verification, state, findings)

      true ->
        handle_reject(state, findings)
    end
  end

  # bd-aq81qz / G20: an APPROVE whose net diff against the target branch is
  # empty must not proceed to merge. This is the shape `empty_diff_guard/1`
  # (G2) does NOT catch: the branch has real commits ahead of the target
  # (`head_sha != base_sha`), most often because those commits were already
  # squashed onto the target independently and this branch then merged the
  # target back in — `base_sha..HEAD` nets to nothing even though HEAD moved.
  #
  # `NetDiff.local_diff_blank?/2` runs the same `git diff` the coverage write
  # would fingerprint, but answers `{:ok, blank?}` only when git actually ran
  # — unlike `coverage_net_diff_id/1` (built on `fingerprint_local/2`), whose
  # `nil`/`{:error, :no_net_diff}` also covers a git failure (a `base_sha` not
  # present in the worktree, a lock or index error). Reusing that broader
  # signal here would misread a transient git failure as proof of emptiness
  # and park a legitimate APPROVE; only a confirmed `{:ok, true}` parks.
  #
  # Gated on `worktree_on_expected_branch?/1` for the same reason
  # `reviewer_commit_check/1` and `commit_gate/1` already are: some test
  # setups (notably ReviewGateTest) reuse the repo itself as the "worktree"
  # with HEAD left on `target_branch`, not on the task branch. There the
  # local diff is *always* empty regardless of the branch's real content — a
  # fixture artifact, not evidence of nothing to merge — so treating it as
  # G20 would misfire on every such test. Production worktrees provisioned
  # via `Worktree.create/3` are always checked out on the per-task branch, so
  # the guard is fully live there.
  defp finalize_approval(state, verdict, findings) do
    {:done, finalize_approval_state(state, verdict, findings)}
  end

  # The bare-state core of `finalize_approval/3`, for callers that already own
  # their own `{:done, _}` wrapping (bd-93cnn9: `escalate_no_changes/1`, whose
  # caller wraps it the same way `escalate_commit_gate/2`'s bare-state return
  # does — double-wrapping here would hand a `{:done, state}` tuple where a
  # plain state map is expected).
  defp finalize_approval_state(state, verdict, findings) do
    # bd-a22hib: a round checkout IS the branch's pushed head by construction
    # (detached, so the on-branch test would always say no) — ask it directly.
    empty_net_diff? =
      (is_map(Map.get(state, :review_checkout)) or worktree_on_expected_branch?(state)) and
        match?({:ok, true}, NetDiff.local_diff_blank?(review_tree(state), diff_range(state)))

    if empty_net_diff? do
      Logger.warning(
        "ReviewGate: task=#{state.task_id} APPROVE nets to an empty diff against " <>
          "the target branch (commits exist but contribute nothing); parking " <>
          "`:empty_net_diff` instead of merging"
      )

      record_round(state, :review, :request_changes, findings, converged: false)
      finish(state, {:parked, :empty_net_diff, findings})
    else
      record_round(state, :review, :approve, findings, converged: true)
      stamp_reviewed_head(state)
      record_review_coverage(state)
      finish(state, verdict)
    end
  end

  # Mirrors `reviewer_commit_check/1`'s and `Worker.commit_gate/1`'s branch
  # guard: only trust the local diff when the worktree is actually checked out
  # on the task's own branch. Some test setups reuse the repo itself as the
  # "worktree" with HEAD left on `target_branch`, where the local diff is
  # empty regardless of the branch's real content.
  defp worktree_on_expected_branch?(%{worktree_path: wt, branch: branch})
       when is_binary(wt) and is_binary(branch) do
    match?({:ok, ^branch}, Arbiter.Worker.Worktree.current_branch(wt))
  end

  defp worktree_on_expected_branch?(_state), do: false

  # bd-4te55l: whether the reviewer's own findings disclose that it abandoned
  # verification (e.g. gave up waiting on a test run) before finalizing. A
  # reviewer that pattern-matches/recalls a prior round's findings rather than
  # re-confirming them against the CURRENT diff produces a verdict that LOOKS
  # legitimate (real findings text, real severities) but may be substantively
  # wrong — the harder case `docs/reviewgate.md` didn't yet cover (unlike the
  # obviously-broken empty/no-verdict cases). `review_prompt/1` requires the
  # reviewer to mark this explicitly rather than silently flushing candidate
  # findings drafted before verification completed.
  # bd-cut6uv: a PARTIAL disclosure that is only about the full suite is not a
  # verification gap when CI was read green on the very commit the reviewer
  # reviewed — the reviewer was told not to run it. Anything else it left
  # unconfirmed, or a head CI did not vouch for, is still partial.
  defp partial_verification?(state, findings) do
    ReviewVerification.partial?(findings) and not ci_covers_partial?(state, findings)
  end

  defp ci_covers_partial?(state, findings) do
    with %{sha: green} <- Map.get(state, :ci_green),
         {:ok, reviewed} <- reviewed_head(state) do
      ReviewCi.same_sha?(green, reviewed) and
        ReviewVerification.partial_only_full_suite?(findings)
    else
      _ -> false
    end
  end

  # Whether a REQUEST_CHANGES verdict carries actionable findings. `findings`
  # spans from the `VERDICT:` line onward (see `findings_from/2`); strip that
  # sentinel line and any `arb done` marker / blank lines, and require something
  # substantive to remain. Deliberately conservative — this catches the truly
  # content-free case (verdict + nothing, or verdict + a bare flourish line) while
  # not second-guessing a terse-but-real finding; persona removal upstream is the
  # primary defense against flourishes.
  @min_findings_chars 16

  defp findings_present?(findings) when is_binary(findings) do
    body =
      findings
      |> String.split("\n")
      # Drop the matched `VERDICT:` line itself (always first in `findings`).
      |> Enum.drop(1)
      |> Enum.reject(fn line ->
        # Strip synthesized session-stats footers appended by the harness
        # (e.g. "⚙ claude session success · 183.5s · $1.1489") — both the
        # Claude and Gemini agent variants use the ⚙ glyph as a prefix.
        # Also strip CRITERIA breakdown lines (`- [MET]` / `- [NOT MET]` /
        # `- [N/A]`): they are verdict payload, not enumerated findings, and
        # would otherwise let a bare APPROVE+breakdown read as "findings present"
        # (bd-4yhv4x).
        String.trim(line) == "" or
          Regex.match?(~r/\barb done\b/, line) or
          Regex.match?(~r/^\s*⚙/, line) or
          ReviewVerification.criteria_line?(line)
      end)
      |> Enum.join("\n")
      |> String.trim()

    String.length(body) >= @min_findings_chars
  end

  # Strip the `VERDICT: REQUEST_CHANGES` sentinel line (always the first line in
  # `findings`, per `findings_from/2`) and any `arb done` markers from the
  # reviewer's findings before embedding them in the implementer's revise prompt.
  # The raw findings (including sentinels) are preserved in the durable thread and
  # re-review prompt for the reviewer's continuity; the implementer only needs the
  # actionable content. Leaving `arb done` in the prompt risks the model treating
  # it as an instruction to stop rather than as reviewer output (bd-79goxj).
  defp clean_findings(findings) when is_binary(findings) do
    findings
    |> String.split("\n")
    # The first line is always `VERDICT: REQUEST_CHANGES` — drop it; the
    # implementer prompt already states the reviewer requested changes.
    |> Enum.drop(1)
    |> Enum.reject(fn line -> Regex.match?(~r/^\s*arb done\s*$/i, line) end)
    |> Enum.join("\n")
    |> String.trim()
  end

  # A REQUEST_CHANGES verdict: record the honest `:request_changes` round, then
  # route on the remaining round budget (escalate if exhausted, else revise).
  defp handle_reject(state, findings) do
    record_round(state, :review, :request_changes, findings, converged: false)
    route_after_reject(%{state | approval_gap_pending: nil, guard_rejected: nil}, findings)
  end

  # bd-c6tdbu: only the `:unaddressed_findings` guard's reject carries the gap
  # forward — a plain REQUEST_CHANGES or any other guard's reject is not "an
  # approval this fix round is standing in for", so it clears the flag instead.
  # bd-93cnn9: the reviewer's own (untouched) APPROVE findings travel with the
  # gap, not just the gap itself — `escalate_no_changes/1` needs them to honor
  # the original APPROVE if the fix round that follows turns out to have
  # nothing to change.
  defp approval_gap_pending_for(%{reason: :unaddressed_findings, gap: gap}, findings),
    do: %{gap: gap, findings: findings}

  defp approval_gap_pending_for(_spec, _findings), do: nil

  # The post-reject routing, shared by a plain REQUEST_CHANGES and the
  # unmet-criteria reject (bd-4yhv4x). With the round budget exhausted, record
  # the final findings into the thread and escalate to Darth Gnosis with the
  # FULL transcript + unresolved findings + current diff; otherwise post the
  # findings to the implementer and spawn a fresh implementer mind to address
  # them on the same branch. The caller owns the `record_round` write so each
  # entry point can log its own honest verdict — a `:request_changes` reject vs.
  # an `:approve` that admits an unmet criterion.
  #
  # bd-80talz: a reviewer that says the work fabricated or falsified evidence
  # ends the loop here, whatever the round budget. Another revise round hands
  # the question back to the same provider: on bd-aro53b the fix round swapped
  # a true citation for an unverified one and uploaded mockup "screenshots" to
  # catbox.moe to satisfy the reviewer.
  #
  # bd-6d3h8m: likewise, a round whose EVERY `[NOT MET]` criterion the reviewer
  # tagged as needing coordinator/operator action ends the loop here too —
  # another revise round cannot make progress on something the reviewer
  # already said an implementer can't fix (bd-28t80i's AC3, verifiable only
  # post-deploy, repeated across 6 review rounds before this rule existed).
  defp route_after_reject(state, findings) do
    state = accumulate_open_findings(state, findings)

    cond do
      EvidenceIntegrity.flagged?(findings) ->
        escalate_fabricated_evidence(state, findings)

      CoordinatorOnlyFindings.only_coordinator_blocked_unmet?(findings) ->
        escalate_coordinator_only(state, findings)

      true ->
        do_route_after_reject(state, findings)
    end
  end

  # Reported as a plain `:request_changes` (the reviewer really rejected the
  # work, so this is a failed run, not a class-C park) with
  # `EvidenceIntegrity.marker/0` leading the findings. That marker is what makes
  # `Arbiter.Worker` escalate to the coordinator instead of dispatching its own
  # automatic fix round.
  defp escalate_fabricated_evidence(state, findings) do
    state = record_thread(state, :reviewer, round_subject(state, "REQUEST_CHANGES"), findings)

    Logger.warning(
      "ReviewGate: task=#{state.task_id} round #{state.round} reviewer flagged fabricated " <>
        "evidence; escalating to the coordinator instead of a revise round"
    )

    payload = EvidenceIntegrity.escalation_findings(findings, escalation_payload(state))
    {:done, finish(state, {:request_changes, payload})}
  end

  # Reported as a plain `:request_changes` with `CoordinatorOnlyFindings.marker/0`
  # leading the findings, mirroring `escalate_fabricated_evidence/2` above. That
  # marker is what makes `Arbiter.Worker` skip its own automatic fix round too.
  defp escalate_coordinator_only(state, findings) do
    state = record_thread(state, :reviewer, round_subject(state, "REQUEST_CHANGES"), findings)

    Logger.info(
      "ReviewGate: task=#{state.task_id} round #{state.round} every unmet criterion needs " <>
        "coordinator/operator action; escalating instead of a revise round"
    )

    payload = CoordinatorOnlyFindings.escalation_findings(findings, escalation_payload(state))
    {:done, finish(state, {:request_changes, payload})}
  end

  # bd-6r8caj: roll the open-finding set forward across the round boundary. The
  # findings this round dispositioned as `[ADDRESSED]` or `[OBSOLETE]` are closed
  # and drop out; everything else stays open and is joined by whatever this round
  # newly raised, each with a fresh round-namespaced id. This is the state the
  # next round's APPROVE is measured against — and the reason the set converges
  # instead of growing without bound.
  defp accumulate_open_findings(state, findings) do
    carried = ReviewFindings.carry_over(Map.get(state, :open_findings, []), findings)
    %{state | open_findings: carried ++ ReviewFindings.extract(findings, state.round)}
  end

  defp do_route_after_reject(%{round: round, max_rounds: max} = state, findings)
       when round >= max do
    state = record_thread(state, :reviewer, round_subject(state, "REQUEST_CHANGES"), findings)

    Logger.info(
      "ReviewGate: task=#{state.task_id} not converged after #{max} round(s); escalating with transcript"
    )

    # bd-4qjl0q: count the cap hit. Observation only — the cap and the
    # convergence routing above/below are unchanged.
    Arbiter.ReviewGate.Resolutions.cap_hit(%{
      workspace_id: state.workspace_id,
      task_id: state.task_id,
      gate: :review_gate,
      rounds: round,
      cap: max
    })

    {:done, finish(state, terminal_reject_verdict(state))}
  end

  defp do_route_after_reject(state, findings) do
    enter_revise(state, findings)
  end

  # What the round cap reports. bd-9zuvbh splits the two things that reach it:
  #
  #   * a reviewer that really said REQUEST_CHANGES for `max_rounds` rounds —
  #     the work did not converge, the run failed, and that is honest. Unchanged.
  #   * a verdict guard (G9–G12) that refused the reviewer's APPROVE and ran out
  #     of re-prompts — bd-c6tdbu's shape, where an honest APPROVE was rejected
  #     over a non-blocking observation and the run died on work that was fine.
  #     Class C parks that: the APPROVE is still NOT accepted (content stays
  #     fail-closed) but the run is not failed either.
  defp terminal_reject_verdict(%{guard_rejected: guard} = state) when not is_nil(guard) do
    {:parked, :verdict_guard_exhausted, escalation_payload(state)}
  end

  defp terminal_reject_verdict(state), do: {:request_changes, escalation_payload(state)}

  # Stage 2: post the reviewer's findings to the implementer over the mailbox,
  # then spawn a fresh implementer worker (same branch/worktree) to fix or rebut
  # each one. Returns `{:revise, state}` so the loop waits on the implementer, or
  # `{:done, state}` (escalated) if the implementer couldn't be spawned.
  defp enter_revise(state, findings, source \\ :reviewer) do
    state = record_enter_revise_thread(state, findings, source)

    # The reviewer's subprocess has exited; stop its worker so it can't linger
    # (it may not have self-completed if it never printed `arb done`).
    stop_worker(state)

    # bd-a22hib: the review round is over — its checkout goes with it. The fix
    # pass runs in the implementer's worktree, and the next round provisions a
    # fresh checkout at whatever head the fix pass pushes.
    state = release_review_checkout(state)

    # bd-bq8c8a: fetch before handing the branch to an implementer. If the
    # remote moved while this round was reviewing, a fix commit on top of the
    # head the reviewer read can only be an orphan.
    case remote_advance(state) do
      {:advanced, remote_head} -> restart_on_remote_head(state, findings, remote_head)
      :none -> launch_implementer(state, findings)
    end
  end

  # The thread entry for the findings that open a revise round: a reviewer's
  # own, or (bd-cut6uv) the ReviewGate's report that CI is red.
  defp record_enter_revise_thread(state, findings, :reviewer),
    do: record_thread(state, :reviewer, round_subject(state, "REQUEST_CHANGES"), findings)

  defp record_enter_revise_thread(state, findings, :ci),
    do: record_thread(state, :system, "Round #{state.round}: CI is red", findings)

  defp launch_implementer(state, findings, prompt_prefix \\ "") do
    impl_id = implementer_task_id(state.review_id, state.round)

    case launch_worker(
           %{state | phase: :revising},
           impl_id,
           :implementer,
           prompt_prefix <> revise_prompt(state, findings),
           state.revise_command
         ) do
      {:ok, state} ->
        Logger.info(
          "ReviewGate: task=#{state.task_id} round #{state.round} requested changes; revising"
        )

        # The round is genuinely under way now, so the guard provenance has done
        # its job: only the terminal arms read it, and from here the next
        # terminal belongs to the round that follows, not to this reject.
        {:revise, %{state | guard_rejected: nil}}

      {:error, reason} ->
        state =
          record_thread(
            state,
            :system,
            "Round #{state.round} revise could not start",
            "The implementer worker could not be spawned: #{inspect(reason)}"
          )

        # bd-9zuvbh: an implementer that could not be spawned is a liveness
        # failure, and when the reject it was standing in for came from a
        # verdict guard the PR still has a reviewer's APPROVE on it. Same split
        # as the round cap: park that, fail a genuine REQUEST_CHANGES.
        {:done, finish(state, terminal_reject_verdict(state))}
    end
  end

  # ---- the remote must not move under a fix round (bd-bq8c8a) --------------
  #
  # G18's companion, one step earlier in the round. `push_gate/1` asks "is the
  # head I am about to review on the remote?" at the START of a round; this
  # asks "has the remote moved past the head I just reviewed?" before a fix
  # round is allowed to build on it.
  #
  # lt-20r7zu (admin_server PR #424, 2026-09-17): round 1 said REQUEST_CHANGES
  # and dispatched an implementer; eighteen seconds later PRPatrol's fix worker
  # pushed `aed4457` to `origin/<branch>`; twenty seconds after THAT the gate's
  # implementer committed `19665a3` on the worktree — a sibling of the patrol
  # commit, containing none of its work. The gate never fetched between the
  # verdict and the commit, so the round could not notice, and `push_gate/1` at
  # the end of the round could only report `:diverged` and park
  # `head_not_pushed`. The round's whole cost was spent producing a commit that
  # had to be thrown away by hand.
  #
  # The answer is not to reconcile the two lines of work — the gate cannot know
  # whose commit is right — but to stop building on a head that is no longer
  # the branch. A remote that STRICTLY ADVANCED (our head is an ancestor of it)
  # is a fast-forward: sync onto it and open a fresh review round, which reads
  # the new diff with this round's findings still on the thread, so nothing the
  # reviewer said is lost.
  #
  # Every other shape is deliberately `:none` — off-branch worktree, no
  # `origin`, git unavailable, a fetch that failed, or a branch that had
  # ALREADY diverged before the round began. None of those is "the remote moved
  # under us", and `push_gate/1` still owns them at the end of the round. This
  # guard only ever *avoids* work; it never creates a new refusal.
  @spec remote_advance(map()) :: {:advanced, String.t()} | :none
  defp remote_advance(%{worktree_path: wt, branch: branch})
       when is_binary(wt) and is_binary(branch) do
    with {:ok, ^branch} <- Worktree.current_branch(wt),
         {:ok, local} <- git_out(wt, ["rev-parse", "HEAD"]),
         {:ok, _} <- git_out(wt, ["fetch", "--quiet", "origin", branch]),
         {:ok, remote} <-
           git_out(wt, ["rev-parse", "--verify", "--quiet", "origin/#{branch}^{commit}"]) do
      if remote != local and ancestor?(wt, local, remote),
        do: {:advanced, remote},
        else: :none
    else
      _ -> :none
    end
  end

  defp remote_advance(_state), do: :none

  # The remote strictly advanced: fast-forward onto it and re-review, instead of
  # dispatching a fix round that could only produce an orphan commit.
  defp restart_on_remote_head(state, findings, remote_head) do
    case Worktree.sync_from_origin(state.worktree_path, state.branch) do
      {:ok, result} when result in [:up_to_date, :synced] ->
        Logger.info(
          "ReviewGate: task=#{state.task_id} round #{state.round} fix pass skipped — " <>
            "`#{state.branch}` advanced to #{String.slice(remote_head, 0, 12)} on origin; " <>
            "re-reviewing the new head instead"
        )

        # bd-7urncn: this fast-forward is a real diff (another actor's commit),
        # but it lands OUTSIDE `note_head_change/1`'s revise-round bookkeeping —
        # without recording it here, a finding this commit actually fixed would
        # still show up "NOT TOUCHED" to a later revise round's backstop check
        # (bd-6r8caj), because `revise_touched_files` would never have seen it.
        # Pinned directly against `record_touched_files/3` (via
        # `note_head_change/1`) in `ReviewGateTest`'s
        # "record_touched_files/3 turns a first diff into a real touched set".
        new_head = current_head_sha(state)

        state
        |> record_thread(
          :system,
          "Round #{state.round} fix pass skipped — the branch moved on origin",
          """
          Another actor pushed to `origin/#{state.branch}` while this round was
          reviewing: the branch is now #{String.slice(remote_head, 0, 12)}, and the head this
          round read (#{state.head_sha}) is its ancestor.

          A fix commit on top of the reviewed head would be a sibling of that push,
          not a child — it could not be pushed, and the round's work would be
          thrown away. No implementer was dispatched. The worktree has been
          fast-forwarded onto the new head and the findings above are carried into
          a fresh review round, which reads the pushed code.
          """
        )
        |> record_touched_files(state.head_sha, new_head)
        |> Map.put(:commit_nudge_used, false)
        |> Map.put(:head_sha, new_head)
        |> dispatch_next_review(restarted_on_remote_head: remote_head)
        |> keep_waiting()

      other ->
        # The fast-forward did not land (a race with yet another push, a git
        # error). Fail open into the ordinary fix round — `push_gate/1` at the
        # end of the round is still the backstop, exactly as before this guard.
        Logger.warning(
          "ReviewGate: task=#{state.task_id} could not fast-forward `#{state.branch}` onto " <>
            "origin (#{inspect(other)}); proceeding with the fix round"
        )

        launch_implementer(state, findings)
    end
  end

  # `dispatch_next_review/1` answers in the `:revising` loop's vocabulary
  # (`:continue`); this call site is in the `:reviewing` loop, whose "keep
  # waiting" token is `:revise`. Both mean `{:noreply, state}`.
  defp keep_waiting({:continue, state}), do: {:revise, state}
  defp keep_waiting({:done, state}), do: {:done, state}

  # The implementer finished addressing the round's findings. Capture its
  # transcript, post it back to the reviewer over the mailbox, and open the next
  # reviewer round (its prompt carries the prior thread). Returns `{:continue,
  # state}` to keep looping or `{:done, state}` (escalated) if the next reviewer
  # couldn't be spawned.
  defp finish_revise(%{reported?: true} = state), do: {:done, state}

  defp finish_revise(state) do
    response =
      state.lines
      |> Enum.reverse()
      |> Enum.join("\n")
      |> String.trim()

    response =
      if response == "",
        do: "(implementer produced no output)",
        else: cap_transcript(response)

    # bd-1mksks: detect whether the revise implementer committed new changes.
    # If HEAD is unchanged from when the reviewer last ran, the implementer's
    # round was a rebuttal only (no code change). Record this in the thread so
    # the re-reviewer knows it is evaluating a rebuttal, not new code. If HEAD
    # advanced, record the new commit so the re-reviewer can verify it too.
    {state, new_head_sha} = note_head_change(state)

    # bd-2eyf9y: the commit gate. A round that leaves HEAD unchanged must not
    # go straight to re-review of the same diff — distinguish "the implementer
    # left real work uncommitted" (resume it once, then escalate if it's still
    # dirty) from "nothing changed at all" (escalate immediately; there is no
    # new diff to re-review).
    {outcome, commit_gate} = commit_gate_outcome(state, new_head_sha, response)

    # bd-cb7wpq: `note_head_change/1` just appended a "rebuttal only, no new
    # commits" system entry (HEAD didn't move). On the path that advances to a
    # real re-review that entry is wrong AND actively harmful — the implementer
    # did not rebut anything, it declared the finding(s) resolved through a
    # non-file channel, and the whole safety case for trusting that claim is
    # that the next reviewer re-checks the live PR for real. Swap in an entry
    # that says so and tells the reviewer to verify before accepting it.
    state =
      if outcome == :advance_non_file_fix,
        do: replace_non_file_fix_thread_entry(state, response),
        else: state

    record_round(state, :impl, nil, response, converged: false, commit_gate: commit_gate)
    state = record_thread(state, :implementer, "Round #{state.round} response", response)

    # The implementer's subprocess has exited; stop its worker so it can't linger.
    stop_worker(state)

    case outcome do
      :advanced ->
        dispatch_next_review(%{
          state
          | head_sha: new_head_sha,
            commit_nudge_used: false,
            non_file_fix_used: false
        })

      :advance_non_file_fix ->
        dispatch_next_review(%{
          state
          | head_sha: new_head_sha,
            commit_nudge_used: false,
            non_file_fix_used: true
        })

      :reprompt ->
        nudge_uncommitted_implementer(%{state | head_sha: new_head_sha})

      :escalate_uncommitted ->
        {:done, escalate_commit_gate(%{state | head_sha: new_head_sha}, :uncommitted)}

      :escalate_no_changes ->
        {:done, escalate_no_changes(%{state | head_sha: new_head_sha})}

      :escalate_no_changes_after_non_file_fix ->
        {:done,
         escalate_commit_gate(%{state | head_sha: new_head_sha}, :no_changes_after_non_file_fix)}
    end
  end

  # bd-c6tdbu: a no-op fix round is ambiguous in general (commit_gate_outcome's
  # existing :no_changes case) UNLESS it was launched only to stand in for an
  # APPROVE the `:unaddressed_findings` guard rejected (bd-6r8caj). In that
  # specific case "no changes" does not mean the implementer failed to act —
  # it means there was nothing to act ON.
  #
  # bd-93cnn9: that used to escalate to a park either way, on the theory that a
  # human should judge whether the open finding(s) genuinely still need a fix.
  # Observed twice in production (bd-6d3h8m / PR #2074, bd-9inpfa / PR #2084):
  # both times the fix round correctly found nothing to change, and the park
  # cost a slot and a coordinator hand-ruling on work the reviewer had already
  # approved. The gate's OWN verdict for this round is `:approve` (fail_closed
  # records it honestly, `converged: false`, precisely so this is queryable) —
  # a fix round that verifies there is nothing left to act on is evidence FOR
  # that approval, not grounds to override it. Honor it: finalize the same
  # APPROVE the reviewer actually gave, the same way any other converging round
  # does, rather than parking behind a human decision that a no-op round cannot
  # supply new information for.
  defp escalate_no_changes(%{approval_gap_pending: %{gap: gap, findings: findings}} = state)
       when not is_nil(gap) do
    Logger.info(
      "ReviewGate: task=#{state.task_id} round #{state.round} fix round produced no changes " <>
        "after an approval-gap rejection (open finding(s): " <>
        Enum.map_join(ReviewFindings.gap_findings(gap), ", ", & &1.id) <>
        "); the reviewer's own verdict was APPROVE and there is nothing left to act on, so " <>
        "merging instead of parking"
    )

    finalize_approval_state(state, {:approve, findings}, findings)
  end

  defp escalate_no_changes(state), do: escalate_commit_gate(state, :no_changes)

  defp approval_gap_pending?(%{approval_gap_pending: %{gap: gap}}), do: not is_nil(gap)
  defp approval_gap_pending?(_state), do: false

  # Decide what the commit gate does with this revise round, and what to
  # record on its `Arbiter.ReviewGate.Round` row. HEAD advancing (or being
  # unknowable — no worktree/git) always proceeds exactly as before this
  # fix; only an UNCHANGED head is gated. `state.head_sha` here is still the
  # SHA from BEFORE this round (note_head_change/1 returns it separately).
  defp commit_gate_outcome(%{head_sha: old_sha}, new_sha, _response)
       when is_nil(old_sha) or is_nil(new_sha) or old_sha != new_sha do
    {:advanced, nil}
  end

  defp commit_gate_outcome(%{worktree_path: wt} = state, _new_sha, response)
       when is_binary(wt) do
    if uncommitted_worktree_changes?(wt) do
      if state.commit_nudge_used,
        do: {:escalate_uncommitted, :escalated_uncommitted},
        else: {:reprompt, :reprompted}
    else
      cond do
        # bd-cb7wpq: a guard-rejected APPROVE (`approval_gap_pending`) has its
        # own escalation that names the open findings for a human to judge
        # (`escalate_no_changes/1`'s `approval_gap_pending` clause,
        # `ReviewFindings.gap_findings/1`). That must win over a bare
        # `NO-FILE-CHANGE:` claim — otherwise this round short-circuits
        # straight to a re-review (or the generic non-file-fix escalation),
        # and the gap-specific finding list a human is supposed to judge is
        # never produced.
        approval_gap_pending?(state) ->
          {:escalate_no_changes, :escalated_no_changes}

        not non_file_fix_declared?(response) ->
          {:escalate_no_changes, :escalated_no_changes}

        state.non_file_fix_used ->
          {:escalate_no_changes_after_non_file_fix, :escalated_no_changes_after_non_file_fix}

        true ->
          {:advance_non_file_fix, :advanced_non_file_fix}
      end
    end
  end

  # No worktree to inspect — can't tell dirty from clean, so fall back to the
  # pre-bd-2eyf9y behavior (proceed) rather than escalate on a guess.
  defp commit_gate_outcome(_state, _new_sha, _response), do: {:advanced, nil}

  # bd-cb7wpq: called only on the `:advance_non_file_fix` outcome, where
  # `commit_gate_outcome/3` has already established HEAD is unchanged and the
  # worktree is clean — so `note_head_change/1`'s last thread entry is always
  # the "rebuttal only, no new commits" one (`head_unchanged_entry/2`'s clean
  # branch). Replace it: this was not a rebuttal, and telling the re-reviewer
  # "the diff is the same as the previous round, evaluate the argument" is
  # exactly wrong when what actually needs checking is the live PR.
  @spec replace_non_file_fix_thread_entry(map(), String.t()) :: map()
  defp replace_non_file_fix_thread_entry(state, response) do
    entry = %{
      round: state.round,
      role: :system,
      subject: "Round #{state.round} — resolved without a file change (declared)",
      body:
        "HEAD did not move this round, but the implementer declared the finding(s) resolved " <>
          "through something other than a file change on this branch (a PR title/description " <>
          "edit, a label, a comment reply) — not a rebuttal. It declared:\n\n" <>
          non_file_fix_declaration_lines(response) <>
          "\nVerify this claim against the LIVE PR (title, description, labels, comments — " <>
          "e.g. `gh pr view`) before accepting it; do not assume it from this text alone. " <>
          "If the claimed change is not actually there, REQUEST_CHANGES."
    }

    %{state | thread: List.replace_at(state.thread, -1, entry)}
  end

  defp non_file_fix_declaration_lines(response) do
    response
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, @non_file_fix_marker))
    |> Enum.join("\n")
  end

  # bd-cb7wpq: has the implementer explicitly declared that every finding this
  # round was resolved through something other than a file change on this
  # branch (a PR title/description edit, a label, a comment reply)? A bare
  # "FIXED" claim is NOT enough — the reviewer re-prompt guidance elsewhere in
  # this module (`verdict_reprompt_prompt/2`, `:unaddressed_findings`) already
  # treats that as unverifiable prose. The explicit marker line is what
  # `revise_prompt/2` asks for precisely so this check has something concrete
  # to grep, and a false claim still gets caught: the next reviewer round reads
  # the live PR for real, exactly as it would any other disposition.
  @spec non_file_fix_declared?(String.t()) :: boolean()
  defp non_file_fix_declared?(response) when is_binary(response) do
    String.contains?(response, @non_file_fix_marker)
  end

  # `opts[:restarted_on_remote_head]` is the new remote sha when this round
  # exists because the branch moved under us rather than because an implementer
  # ran (bd-bq8c8a). It is set per-round — every ordinary caller leaves it nil,
  # so the flag can never leak into a later round's prompt.
  defp dispatch_next_review(state, opts \\ []) do
    # Reset the per-round retry budget so a reprompt used in this round does not
    # prevent a reprompt in the next round (bug bd-79goxj).
    # Also reset attempt counter so reprompts in the new round start fresh (bd-bgeo6i).
    next = %{
      state
      | round: state.round + 1,
        phase: :reviewing,
        retries_left: state.initial_retries,
        attempt: 0,
        verdict_scan: nil,
        verdict_scans: [],
        # bd-3hb4ih: the reviewer provider pin and the round's timed-out
        # providers are per-ROUND state. A new round reviews a different diff,
        # so a provider that timed out on the previous one starts even again.
        reviewer_provider: nil,
        reviewer_timeouts: [],
        # bd-954ym8: only the first round of a head is the scoped conflict
        # review; whatever it sent back is reviewed in full after the fix.
        conflict_review: nil,
        restarted_on_remote_head: Keyword.get(opts, :restarted_on_remote_head),
        # bd-cut6uv: CI is per head, and a new round has a new head.
        ci_green: nil,
        ci_fallback: nil,
        ci_wait: nil,
        ci_retargets: 0
    }

    review_id = reviewer_round_id(next.review_id, next.round)

    # bd-2jkrqu: the fix round commits in the worktree and (historically) never
    # pushed. `handle_continue(:spawn_reviewer, …)` — which runs the push gate
    # for round 1 — is NOT on this path, so round 2+ would read a local-only
    # head. This is the exact commit the vs-5l45oz reviewer approved.
    case push_gate(next) do
      {:error, reason} ->
        {:done, escalate_pre_review_park(next, reason)}

      :ok ->
        next |> ci_gate({:next, review_id}) |> ci_next_reply(review_id)
    end
  end

  defp launch_next_reviewer(next, review_id) do
    case provision_review_checkout(next) do
      {:ok, next} ->
        case ci_verify_checkout(next, {:next, review_id}) do
          {:ok, next} -> launch_next_reviewer_in_checkout(next, review_id)
          {:retarget, next} -> next |> ci_gate({:next, review_id}) |> ci_next_reply(review_id)
        end

      {:error, reason} ->
        message = checkout_failure_message(next, reason)
        record_round(next, :review, :request_changes, message, converged: false)
        {:done, finish(next, {:parked, :reviewer_failed, message})}
    end
  end

  defp launch_next_reviewer_in_checkout(next, review_id) do
    case launch_worker(next, review_id, :reviewer, rereview_prompt(next), next.command) do
      {:ok, state} ->
        {:continue, state}

      {:error, reason} ->
        # bd-9zuvbh / bd-7xtz6w: a reviewer that could not be spawned is a
        # liveness failure of the review, not a finding against the work —
        # the same `:reviewer_failed` park the first round and a checkout
        # failure (above) already report. Reporting REQUEST_CHANGES here sent
        # an implementer to "fix" a branch nobody had found anything wrong
        # with.
        message =
          "ReviewGate could not spawn the round #{next.round} reviewer: #{inspect(reason)}"

        next =
          record_thread(next, :system, "Round #{next.round} re-review could not start", message)

        record_round(next, :review, :request_changes, message, converged: false)
        {:done, finish(next, {:parked, :reviewer_failed, message})}
    end
  end

  # bd-2eyf9y: resume the SAME round's implementer exactly once with an
  # explicit "commit and push" instruction instead of dispatching a re-review
  # of an unchanged diff. `phase` stays `:revising` and `round` is untouched —
  # the relaunch is just another pass of this round, so its exit routes back
  # into finish_revise/1 above via the normal :revising dispatch, where
  # `commit_nudge_used: true` means a still-dirty tree now escalates instead
  # of nudging again.
  defp nudge_uncommitted_implementer(state) do
    state = %{state | commit_nudge_used: true}
    id = commit_nudge_task_id(state.review_id, state.round)

    case launch_worker(state, id, :implementer, commit_nudge_prompt(state), state.revise_command) do
      {:ok, state} ->
        {:continue, state}

      {:error, reason} ->
        state =
          record_thread(
            state,
            :system,
            "Round #{state.round} commit-gate resume could not start",
            "The implementer could not be resumed to commit its work: #{inspect(reason)}"
          )

        {:done, escalate_commit_gate(state, :uncommitted)}
    end
  end

  defp commit_nudge_prompt(state) do
    """
    bd-2eyf9y commit gate: your round #{state.round} revise pass for task #{state.task_id} \
    ended with the worktree on branch `#{state.branch}` left DIRTY (`git status --porcelain` \
    is non-empty) and HEAD unchanged. The re-reviewer diffs committed history only, so this \
    work is invisible until it is committed.

    Do EXACTLY this, then print `arb done` again on its own line:

      1. `git status` to see what is uncommitted.
      2. `git add -A`
      3. `git commit -m "<a short message describing the work>"`
      4. `git push -u origin #{state.branch}` — REQUIRED. The re-review and the
         merge request both read the PUSHED head; a commit that stays local is
         reviewed but never merged (bd-2jkrqu).

    Do not redo the work — just commit what is already on disk. If a hunk looks
    half-finished or wrong, finish it first, then commit it.
    """
  end

  # bd-2eyf9y: all three escalations report the same shape as
  # `escalate_timeout/1`, so `park_rejected/4` files them as
  # `:review_gate_inconclusive` and `maybe_dispatch_fix_round/3` does NOT
  # auto-redispatch a fresh fix round against them (that dispatcher only acts
  # on `:request_changes`).
  #
  # bd-9zuvbh: that shape is now `{:parked, reason, message}` rather than
  # `{:no_verdict, message}`. The reason is what gives each one its own mail
  # subject — the distinction bd-2eyf9y originally carried in the message's
  # leading marker sentence, which the author had to string-match to recover.
  # The markers stay (the escalation body still opens with them, and
  # `Worker.review_gate_escalation_subject/3` still reads them on the
  # pre-P9 `:no_verdict` path) but nothing has to infer the reason any more.
  defp escalate_commit_gate(state, :uncommitted) do
    msg =
      "#{@commit_gate_uncommitted_marker} (task #{state.task_id}, round #{state.round}). " <>
        "The implementer was resumed once with an explicit instruction to commit and push, " <>
        "but the worktree still has uncommitted changes and HEAD has not moved. The " <>
        "re-reviewer would see the same diff as last round, so no further review round " <>
        "was dispatched.\n\n" <> escalation_payload(state)

    finish(state, {:parked, :commit_gate_uncommitted, msg})
  end

  defp escalate_commit_gate(state, :no_changes) do
    msg =
      "#{@commit_gate_no_changes_marker} (task #{state.task_id}, round #{state.round}). " <>
        "HEAD did not move and the worktree is clean — the revise round produced no code " <>
        "change. No further review round was dispatched against an identical diff.\n\n" <>
        escalation_payload(state)

    finish(state, {:parked, :commit_gate_no_changes, msg})
  end

  # bd-cb7wpq: this round (and the one before it) both left HEAD unmoved on a
  # clean tree, and both times the implementer declared every finding resolved
  # through a non-file channel (`non_file_fix_declared?/1`). One such round is
  # honored — it advances to a real re-review, see `:advance_non_file_fix`
  # above — but two in a row with nothing new for the reviewer to check is the
  # same liveness question the plain no-changes gate asks, so it parks too.
  # Distinct reason from `:commit_gate_no_changes` so a human reading `arb
  # prime` / the escalation does not read this as an idle worker: the
  # implementer DID act, just not on a file.
  defp escalate_commit_gate(state, :no_changes_after_non_file_fix) do
    msg =
      "#{@commit_gate_no_changes_marker} (task #{state.task_id}, round #{state.round}). " <>
        "HEAD did not move and the worktree is clean, and this is the SECOND round in a row " <>
        "where the implementer declared every finding resolved through something other than " <>
        "a file change (a PR title/description edit, a label, a comment) rather than a code " <>
        "change. The first such round was honored and re-reviewed; this one was not, since " <>
        "the reviewer still has nothing new to check. No further review round was " <>
        "dispatched.\n\n" <> escalation_payload(state)

    finish(state, {:parked, :commit_gate_no_changes_after_non_file_fix, msg})
  end

  @doc """
  Compare HEAD SHA before and after a revise round to detect whether the
  implementer committed new changes. Appends a system entry to the in-memory
  thread (for the escalation payload / re-review prompt context) but does NOT
  persist it to the durable mailbox — HEAD-change notes are internal ReviewGate
  bookkeeping, not part of the implementer↔reviewer conversation. Returns
  {updated_state, new_head_sha}.

  bd-d534xo: an implementer that backgrounded a long verification command and
  then abandoned its turn to "wait for the notification" (`claude --print`
  ends the process the instant a turn has no tool call, so the notification
  never arrives) exits with HEAD unchanged — the exact same git state a
  genuine "REBUTTED, no code change" round leaves. Left alone, a real,
  finished fix sitting unstaged in the worktree gets mislabeled as a
  rebuttal and silently carried forward; the next round or the no-progress
  resume guard can then discard it. When HEAD is unchanged, also check the
  worktree for uncommitted changes and say so explicitly instead — this is
  the "the run's failure summary shouldn't hide it" half of the fix; the
  guidance to commit before backgrounding is the prevention half
  (`PromptBuilder.async_tools_section/3`, threaded into `revise_prompt/2`).
  Public for inspection in tests.
  """
  @spec note_head_change(map()) :: {map(), String.t() | nil}
  def note_head_change(state) do
    new_sha = current_head_sha(state)
    old_sha = state.head_sha
    state = record_touched_files(state, old_sha, new_sha)

    cond do
      is_nil(new_sha) or is_nil(old_sha) ->
        # No worktree or git unavailable — pass through without a note.
        {state, new_sha}

      new_sha == old_sha ->
        entry = head_unchanged_entry(state, new_sha)
        {%{state | thread: state.thread ++ [entry]}, new_sha}

      true ->
        entry = %{
          round: state.round,
          role: :system,
          subject: "Round #{state.round} — implementer committed new changes",
          body:
            "HEAD advanced from #{old_sha} to #{new_sha} during the revise round. " <>
              "The re-reviewer sees the updated diff."
        }

        {%{state | thread: state.thread ++ [entry]}, new_sha}
    end
  end

  defp head_unchanged_entry(%{worktree_path: wt} = state, sha) when is_binary(wt) do
    if uncommitted_worktree_changes?(wt) do
      %{
        round: state.round,
        role: :system,
        subject:
          "Round #{state.round} — HEAD unchanged but UNCOMMITTED changes remain in the worktree",
        body:
          "HEAD remained at #{sha} after the revise round, but the worktree has uncommitted " <>
            "changes (`git status --porcelain` is non-empty). This is NOT a rebuttal — the " <>
            "implementer likely wrote a real fix and then abandoned its turn (e.g. backgrounded " <>
            "a long verification command and yielded the turn to 'wait for the notification', " <>
            "which never arrives in a non-interactive session) before committing it. The " <>
            "re-reviewer will see the SAME diff as last round and cannot evaluate this work; " <>
            "escalate or resume the implementer to commit before re-reviewing."
      }
    else
      %{
        round: state.round,
        role: :system,
        subject:
          "Round #{state.round} — HEAD unchanged after revise (rebuttal only, no new commits)",
        body:
          "HEAD remained at #{sha} after the revise round. " <>
            "The implementer's response was a rebuttal, not a code change. " <>
            "The re-reviewer evaluates the rebuttal argument; the diff is the same as the previous round."
      }
    end
  end

  defp head_unchanged_entry(state, sha) do
    %{
      round: state.round,
      role: :system,
      subject:
        "Round #{state.round} — HEAD unchanged after revise (rebuttal only, no new commits)",
      body:
        "HEAD remained at #{sha} after the revise round. " <>
          "The implementer's response was a rebuttal, not a code change. " <>
          "The re-reviewer evaluates the rebuttal argument; the diff is the same as the previous round."
    }
  end

  # Best-effort: a git failure (or a worktree the round already tore down)
  # must never crash the round — it just falls back to the rebuttal-only
  # wording above, which was the entire behavior pre-bd-d534xo.
  defp uncommitted_worktree_changes?(wt) when is_binary(wt) do
    case Arbiter.Worker.Worktree.has_uncommitted?(wt) do
      {:ok, dirty?} -> dirty?
      {:error, _} -> false
    end
  rescue
    _ -> false
  end

  # bd-6r8caj: the mechanical backstop's raw material — which files were
  # actually changed, accumulated only from each revise round's own diff
  # (bd-7urncn: deliberately NOT seeded from the PR's initial commit — a
  # finding citing a file from before round 1 ever ran must stay open until a
  # revise round actually revisits it). `git diff --name-only old..new`
  # between the SHA the reviewer last saw and the SHA after; an empty diff for
  # a file a finding cited is the exact bd-8mtb0q signal ("the implementer
  # only ran `mix format`"). Stays nil without a worktree or when either SHA is
  # unknown, and an unchanged HEAD contributes nothing — both leave the
  # backstop silent rather than guessing. Best-effort: a git failure is not
  # allowed to break the round.
  defp record_touched_files(%{worktree_path: wt} = state, old_sha, new_sha)
       when is_binary(wt) and is_binary(old_sha) and is_binary(new_sha) do
    changed =
      case System.cmd("git", ["-C", wt, "diff", "--name-only", "#{old_sha}..#{new_sha}"],
             stderr_to_stdout: true
           ) do
        {out, 0} -> out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
        _ -> []
      end

    prior = Map.get(state, :revise_touched_files) || MapSet.new()
    %{state | revise_touched_files: MapSet.union(prior, MapSet.new(changed))}
  rescue
    _ -> state
  end

  defp record_touched_files(state, _old_sha, _new_sha), do: state

  # ---- infrastructure-failure classification (bd-b2glhm) ------------------

  # Classify why the reviewer's subprocess exited, using the same signature
  # matching the main Worker uses to detect auth expiry / credit exhaustion /
  # rate limiting / etc (`Arbiter.Worker.StopReason`). `classify/2` scans the
  # *last* 80 entries (see its `@doc` and `signature_haystack/1`), so it must
  # be handed oldest-first; `state.lines` is newest-first, hence the reverse.
  #
  # On a clean exit (status 0) the reviewer's own review prose is on the wire,
  # and the infra signatures (`/login`, `401`, `unauthorized`, `rate limit`,
  # `expired`, ...) are broad enough to appear in ordinary review text about
  # auth/quota code — including this very module's fixtures. Misclassifying
  # that as an infra failure would skip the verdict re-prompt and fabricate a
  # "re-authenticate" diagnosis for a reviewer that simply omitted its VERDICT
  # line. So on exit 0 we only trust categories whose marker is
  # harness/CLI-emitted rather than model prose, and so can't collide with
  # review text: `:stream_schema_drift` (unparseable stream schema) and
  # `:agent_print_timeout` (bd-1xss5z — agy's own fixed print-timeout
  # wording, which agy reports alongside a clean exit and a "SUCCESS" result
  # event). A non-zero exit means the subprocess genuinely failed, so the
  # full classification applies there.
  defp classify_stop(0, lines) do
    case StopReason.classify(0, Enum.reverse(lines)) do
      %StopReason{category: category} = reason
      when category in [:stream_schema_drift, :agent_print_timeout] ->
        reason

      _ ->
        nil
    end
  end

  defp classify_stop(status, lines) when is_integer(status) do
    StopReason.classify(status, Enum.reverse(lines))
  end

  defp classify_stop(_status, _lines), do: nil

  # Human-actionable inconclusive message for a reviewer that died of a known
  # infrastructure failure rather than genuinely finishing without a verdict —
  # names the real cause and remediation instead of the generic "no parseable
  # VERDICT line" message, which gave no signal that re-authenticating (or
  # waiting out a rate limit) would fix it.
  # bd-9zuvbh: which park an infra failure stamps. The distinction is not
  # cosmetic — bd-1xss5z was agy's own `--print-timeout` firing mid-review, and
  # "the reviewer ran out of time" is a different operator action (raise the
  # budget, shrink the review) from "the reviewer's session broke" (credentials,
  # quota, a dead gateway).
  defp infra_park_reason(:agent_print_timeout), do: :reviewer_timeout
  defp infra_park_reason(_category), do: :reviewer_failed

  defp infra_failure_message(%StopReason{} = reason) do
    "Reviewer subprocess failed: #{reason.summary}. #{reason.remediation}"
  end

  # ---- reviewer print-timeout rotation (bd-3hb4ih) -----------------------

  # A reviewer pass ended as `:agent_print_timeout` — the reviewer CLI's OWN
  # internal print-mode wall fired mid-review (bd-1xss5z: agy hard-codes one,
  # and reports the cut-short turn alongside a clean exit and a terminal
  # "SUCCESS" event). Unlike every other entry in
  # `@infra_failure_categories`, this failure belongs to the *CLI*, not to the
  # account, the credentials or the gateway — so a DIFFERENT provider can still
  # answer the same question about the same diff, where re-prompting the one
  # that just timed out hits the identical wall deterministically.
  #
  # Three outcomes, in order:
  #
  #   1. Fewer than two providers configured for the reviewer role (the
  #      overwhelmingly common case, and every workspace-less ad-hoc gate):
  #      there is nothing to rotate to, so this keeps TODAY'S behaviour exactly
  #      — park `:reviewer_timeout` with the real reason, no re-prompt, no
  #      extra round row, nothing recorded about a pool that doesn't exist.
  #   2. A provider in the pool has not been tried this round: rotate to it and
  #      re-run the SAME pass (same prompt, same diff, same round).
  #   3. Every provider in the pool has now timed out: stop rotating and
  #      escalate ONCE, with each provider's timeout named.
  defp handle_reviewer_print_timeout(state, %StopReason{} = reason) do
    pool = reviewer_pool(state)

    if length(pool) < 2 do
      Logger.warning(
        "ReviewGate: reviewer for task=#{state.task_id} hit its own print-timeout " <>
          "(#{reason.category}); no multi-provider reviewer pool to rotate into, escalating"
      )

      {:done, finish(state, {:parked, :reviewer_timeout, infra_failure_message(reason)})}
    else
      state = record_reviewer_timeout(state, reason)

      case next_reviewer(state, pool) do
        {nil, _selection} -> {:done, escalate_pool_exhausted(state, pool)}
        {next, selection} -> rotate_reviewer(state, next, pool, selection)
      end
    end
  end

  # bd-a1ke2c: under cross-family review the rotation asks `ReviewerRouting`
  # again with this round's timed-out providers excluded, so it can only land
  # in an eligible family — a timeout is never a same-family fallback trigger.
  # Off, it is bd-3hb4ih's configured-order walk, untouched.
  defp next_reviewer(%{reviewer_selection: %{}} = state, _pool) do
    tried = state.reviewer_timeouts |> Enum.map(& &1.provider) |> Enum.reject(&is_nil/1)

    case select_reviewer(state, tried) do
      {:ok, selection} -> {selection.provider, selection}
      _ -> {nil, nil}
    end
  end

  defp next_reviewer(state, pool), do: {next_reviewer_provider(state, pool), nil}

  # ---- cross-family reviewer routing (bd-a1ke2c) --------------------------

  # Every reviewer pass the print-timeout rotation has not pinned asks
  # `ReviewerRouting` for its reviewer: a family other than the implementer's,
  # the task's pinned one while it is available, most quota left, with a
  # recorded same-family fallback. `:off` (the workspace has not opted in, or
  # there is no workspace) and a fixture-argv gate leave `reviewer_selection`
  # nil, which is today's resolution exactly.
  defp route_reviewer_pass(%{reviewer_provider: nil} = state, :reviewer, nil) do
    case select_reviewer(state, []) do
      {:ok, selection} -> %{state | reviewer_selection: selection}
      _ -> %{state | reviewer_selection: nil}
    end
  end

  defp route_reviewer_pass(state, _role, _command), do: state

  defp select_reviewer(state, exclude) do
    with %Workspace{} = ws <- load_workspace(state.workspace_id),
         true <- ReviewerRouting.enabled?(ws) do
      ReviewerRouting.select(ws, state.task_id,
        tier: round_reviewer_tier(state, ws.config),
        exclude: exclude,
        security: session_security_policy(ws, state, :reviewer)
      )
    else
      _ -> :off
    end
  rescue
    e ->
      Logger.warning(
        "ReviewGate: cross-family reviewer routing crashed for task=#{state.task_id}: " <>
          Exception.message(e)
      )

      :off
  end

  # The reviewer role's configured provider pool for this workspace, in
  # configured order. `[]` without a workspace (an ad-hoc gate) or when the
  # workspace can't be read — both of which fall through to today's park.
  #
  # bd-1abj7u finding 1: filtered through `Agents.strict_eligible_provider/4`
  # so the print-timeout rotation (`next_reviewer_provider/2`, below) can never
  # land on a provider that can't confine writes under this workspace's
  # resolved `:strict` scope — the only place `state.reviewer_provider` (the
  # pin `adapter_for/4`'s reviewer clause trusts outright) is ever set draws
  # from this pool.
  defp reviewer_pool(state) do
    case load_workspace(state.workspace_id) do
      %Workspace{} = ws ->
        policy = session_security_policy(ws, state, :reviewer)

        ws
        |> Agents.reviewer_pool()
        |> Enum.reject(&reviewer_paused?(&1, state))
        |> Enum.filter(&strict_eligible_reviewer?(&1, policy))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp strict_eligible_reviewer?(type, policy) do
    case Agents.strict_eligible_provider(type, policy, [], explicit: true) do
      {:ok, _} -> true
      {:error, :ineligible} -> false
    end
  end

  # Append the timed-out provider to this round's list. Recorded under the
  # provider that ACTUALLY ran the pass (`reviewer_provider_for/1`), not under
  # the pool head — with a provider in circuit-breaker cooldown the workspace's
  # own resolution may have started somewhere else entirely, and subtracting the
  # wrong entry would retry the provider that just timed out.
  defp record_reviewer_timeout(state, %StopReason{} = reason) do
    entry = %{
      provider: reviewer_provider_for(state),
      round: state.round,
      pass_id: state.current_id,
      summary: reason.summary
    }

    %{state | reviewer_timeouts: state.reviewer_timeouts ++ [entry]}
  end

  # The next provider to try: the first pool entry that has not already timed
  # out this round, preferring a healthy one exactly as ordinary resolution does
  # (`ProviderPool.pick/1` falls back to the first candidate when none is
  # healthy, so a pool in cooldown still gets tried rather than stalling).
  #
  # The `length/1` comparison is a hard bound, not a nicety: it guarantees at
  # most one pass per pool entry per round even if `reviewer_provider_for/1`
  # could not name the provider that ran (it returns nil on a fixture-argv gate)
  # and so nothing could be subtracted.
  defp next_reviewer_provider(state, pool) do
    if length(state.reviewer_timeouts) >= length(pool) do
      nil
    else
      tried = Enum.map(state.reviewer_timeouts, & &1.provider)

      pool
      |> Enum.reject(&(&1 in tried))
      |> ProviderPool.pick()
    end
  end

  # Re-run the current round's reviewer pass against the next provider. This is
  # NOT a revision and NOT a verdict re-prompt: the round, the round cap and the
  # verdict re-prompt budget are all untouched, and the pass is handed the
  # IDENTICAL prompt (`state.current_prompt`) so the rotated reviewer judges the
  # same diff the timed-out one was asked about.
  defp rotate_reviewer(state, next, pool, selection) when is_binary(state.current_prompt) do
    stop_worker(state)

    prior = reviewer_provider_for(state)
    note = rotation_note(state, prior, next, pool)

    # Queryable evidence of the rotation, attributed to the provider that timed
    # out — recorded BEFORE the pin moves, so `record_round/5` reads `prior`.
    record_round(state, :review, :timed_out, note, converged: false)

    state =
      record_thread(
        state,
        :system,
        "Round #{state.round} reviewer (#{provider_label(prior)}) timed out — " <>
          "rotating to #{provider_label(next)}",
        note
      )

    rotated = %{
      state
      | reviewer_provider: next,
        reviewer_selection: selection || state.reviewer_selection
    }

    id = provider_rotation_id(rotated, next)

    case launch_worker(rotated, id, :reviewer, state.current_prompt, state.command) do
      {:ok, rotated} ->
        Logger.warning(
          "ReviewGate: reviewer #{provider_label(prior)} for task=#{state.task_id} hit its own " <>
            "print-timeout on round #{state.round}; rotating to #{provider_label(next)} " <>
            "(pool #{Enum.map_join(pool, ",", &provider_label/1)})"
        )

        {:reprompt, rotated}

      {:error, spawn_reason} ->
        Logger.warning(
          "ReviewGate: rotated reviewer (#{provider_label(next)}) failed to spawn for " <>
            "task=#{state.task_id}: #{inspect(spawn_reason)}"
        )

        {:done, escalate_pool_exhausted(state, pool)}
    end
  end

  # No prompt to replay (nothing has been launched yet) — there is no "same
  # diff" to hand a second provider, so concede rather than invent one.
  defp rotate_reviewer(state, _next, pool, _selection),
    do: {:done, escalate_pool_exhausted(state, pool)}

  # Every provider in the pool has hit its own print-timeout on this round.
  # Stop rotating and page the coordinator ONCE (class C: a liveness failure of
  # the review, never of the work — see `escalate_timeout/1`), naming each
  # provider's timeout so the remediation is obvious. Deliberately NOT an
  # inconclusive/no-verdict verdict: no reviewer said anything, so there is
  # nothing for an implementer to fix and a re-dispatch would time out again.
  defp escalate_pool_exhausted(state, pool) do
    msg = pool_exhausted_message(state, pool)
    payload = if state.thread == [], do: msg, else: msg <> "\n\n" <> escalation_payload(state)

    record_round(state, :review, :timed_out, payload, converged: false)
    report(state, {:parked, :reviewer_timeout, payload})
    %{state | reported?: true}
  end

  defp rotation_note(state, prior, next, pool) do
    """
    The round #{state.round} reviewer pass on `#{provider_label(prior)}` hit that CLI's own
    internal print-mode timeout and returned partial output with no VERDICT line.

    This is a property of the reviewer CLI, not of the diff or the account, so
    re-prompting `#{provider_label(prior)}` would hit the same wall deterministically. The
    gate is rotating to the next provider in this workspace's `review_agent.type`
    pool instead: `#{provider_label(next)}`.

    Reviewer pool (configured order): #{Enum.map_join(pool, ", ", &provider_label/1)}
    Already timed out this round: #{tried_label(state)}

    No round was consumed and no verdict re-prompt was spent: the rotated pass
    reviews the SAME diff, in the SAME round.
    """
    |> String.trim()
  end

  defp pool_exhausted_message(state, pool) do
    """
    ReviewGate: every provider in this workspace's reviewer pool hit its own internal
    print-mode timeout on round #{state.round}. The gate stopped rotating rather than
    looping over providers that have each already failed the same way.

    Providers tried, in configured order:
    #{timeout_roster(state)}

    This is an INFRASTRUCTURE/BUDGET failure, not a review finding: no reviewer verdict
    was produced, so there is nothing for an implementer to fix and re-dispatching the
    task unchanged will simply time out again.

    Remediation: raise `review_gate.timeout_ms` for this workspace (the last pass ran
    under #{state.timeout_ms}ms, which is also what each provider's CLI was given as its
    own print-timeout), reduce what the review has to do (a smaller diff, fewer rounds
    of context), or add a provider to `review_agent.type` whose CLI has no fixed
    print-mode wall. The reviewer pool as configured is: #{Enum.map_join(pool, ", ", &provider_label/1)}.
    #{cross_family_rotation_note(state)}
    """
    |> String.trim()
  end

  # bd-a1ke2c: with cross-family review on, "every provider" means every one in
  # an eligible family — say why the implementer's own family was not tried.
  defp cross_family_rotation_note(%{reviewer_selection: %{} = sel}) do
    """

    `review_agent.cross_family` is on: providers in the implementer's model family
    (#{sel.implementer_family || "unknown"}) are not rotated into on a timeout — a
    timeout is not a same-family fallback trigger — so the rotation stopped once
    every eligible family had timed out.
    """
  end

  defp cross_family_rotation_note(_state), do: ""

  defp timeout_roster(%{reviewer_timeouts: []}), do: "  (none recorded)"

  defp timeout_roster(%{reviewer_timeouts: timeouts}) do
    Enum.map_join(timeouts, "\n", fn entry ->
      "  - #{provider_label(entry.provider)}: #{entry.summary} (pass #{entry.pass_id || "unknown"})"
    end)
  end

  defp tried_label(%{reviewer_timeouts: []}), do: "(none)"

  defp tried_label(%{reviewer_timeouts: timeouts}),
    do: Enum.map_join(timeouts, ", ", &provider_label(&1.provider))

  defp provider_label(nil), do: "unknown"
  defp provider_label(provider) when is_atom(provider), do: Atom.to_string(provider)

  # Which provider actually ran (or is about to run) the current reviewer pass.
  # The rotation pin wins; otherwise this re-derives the same answer the spawn
  # path itself resolved, so a `:review` round row can name the provider behind
  # its verdict without threading it through every launch. A fixture-argv gate
  # (`command:` — tests only) reports its declared `command_provider`, or nil:
  # claiming the workspace's configured reviewer for an argv that bypassed the
  # adapter entirely would be a lie.
  defp reviewer_provider_for(%{reviewer_provider: provider})
       when is_atom(provider) and not is_nil(provider),
       do: provider

  defp reviewer_provider_for(%{reviewer_selection: %{provider: provider}})
       when is_atom(provider) and not is_nil(provider),
       do: provider

  defp reviewer_provider_for(%{command: command} = state) when is_list(command),
    do: provider_atom(Map.get(state, :command_provider))

  defp reviewer_provider_for(state) do
    case load_workspace(state.workspace_id) do
      %Workspace{} = ws -> adapter_provider(Agents.reviewer_for_workspace(ws))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Reverse-map an adapter module to its pool atom via the registry, so no new
  # atom is ever created from a provider string.
  defp adapter_provider(adapter) do
    Enum.find_value(Agents.adapters(), fn {type, mod} -> if mod == adapter, do: type end)
  end

  defp provider_atom(provider) when is_binary(provider) do
    Enum.find(Map.keys(Agents.adapters()), &(Atom.to_string(&1) == provider))
  end

  defp provider_atom(_provider), do: nil

  # ---- verdict re-prompt (bd-8v8ays) -------------------------------------

  # A reviewer pass produced a malformed result: either no parseable VERDICT line
  # (`:no_verdict`) or a REQUEST_CHANGES with no actionable findings
  # (`:empty_findings`). If we have a re-prompt budget left, spawn one more minimal
  # follow-up pass (a fresh reviewer mind — there is no Claude session resume yet —
  # that re-reads the diff but is told exactly what it got wrong). Otherwise
  # escalate as inconclusive. This stays in the current round: a malformed verdict
  # is not a revision.
  defp maybe_reprompt(%{retries_left: budget} = state, reason) when budget > 0 do
    stop_worker(state)

    retry_id = reprompt_retry_id(state)

    # A content-free REQUEST_CHANGES is a malformed verdict — the reviewer did
    # not produce a legitimate review result for this round. Extend the round cap
    # by 1 so the re-prompt's real findings can still reach the implementer: the
    # empty verdict must not rob the task of a revision opportunity (bd-79goxj).
    # Only extend when the ReviewGate has a revise loop (max_rounds > 1): a
    # single-pass setup (max_rounds == 1) has no revise loop by design and the
    # extension would incorrectly trigger enter_revise for that configuration.
    max_ext = if reason == :empty_findings and state.max_rounds > 1, do: 1, else: 0

    case launch_worker(
           %{state | retries_left: budget - 1, max_rounds: state.max_rounds + max_ext},
           retry_id,
           :reviewer,
           verdict_reprompt_prompt(state, reason),
           state.command
         ) do
      {:ok, state} ->
        Logger.info(
          "ReviewGate: reviewer for task=#{state.task_id} returned #{reason}; re-prompting (attempt #{state.attempt})"
        )

        {:reprompt, state}

      {:error, spawn_error} ->
        Logger.warning(
          "ReviewGate: verdict re-prompt failed to spawn for task=#{state.task_id}: #{inspect(spawn_error)}"
        )

        {:done,
         finish(
           state,
           {:no_verdict,
            "Reviewer produced no usable verdict; re-prompt could not be spawned. " <>
              transcript_location_note(state)}
         )}
    end
  end

  defp maybe_reprompt(state, :empty_findings) do
    {:done,
     finish(
       state,
       {:no_verdict,
        "Reviewer returned REQUEST_CHANGES with no concrete findings, even after a re-prompt."}
     )}
  end

  # bd-869mmg round 3: the last-ditch check before conceding `:no_verdict` for
  # good. Every prior pass in this round (each pass's `verdict_scan_info/2`
  # accumulated onto `state.verdict_scans` by `attempt_finish/2`) already
  # concluded, at the time of ITS OWN scan, that it had no parseable verdict.
  # That conclusion is not re-trusted here — `recover_verdict_from_scans/1`
  # re-reads each pass's durable transcript FRESH, because a pass's own scan
  # can miss a verdict for reasons the surviving artifacts don't explain
  # (bd-atyrrq / run 72947341: the first pass's own on-disk transcript holds
  # an intact `VERDICT: REQUEST_CHANGES` today, yet that pass's own scan
  # found nothing at the time), and the OLD behaviour then discarded that
  # pass's transcript entirely once the re-prompt pass ALSO came back empty —
  # the real review was there on disk the whole time. If any pass's
  # transcript parses now, treat it as the round's verdict rather than
  # escalating past it.
  defp maybe_reprompt(state, _reason) do
    case recover_verdict_from_scans(state.verdict_scans) do
      {:ok, verdict, run_id} ->
        Logger.warning(
          "ReviewGate: VERDICT recovered for task=#{state.task_id} from an earlier pass's " <>
            "durable transcript (#{OutputLog.path_for(run_id)}) — that pass's own scan (and " <>
            "the verdict re-prompt's) both reported no parseable verdict, but the transcript " <>
            "on disk holds one; a real review was nearly discarded as inconclusive"
        )

        dispatch_verdict(state, verdict)

      :none ->
        {:done, finish(state, {:no_verdict, no_verdict_scan_message(state)})}
    end
  end

  # bd-869mmg round 2: "output was received" is only true when the scan
  # actually captured something. Report the real counts either way instead of
  # asserting receipt unconditionally (finding: several existing paths reach
  # this with 0 live and 0 durable lines, where the old fixed wording claimed
  # the opposite of the truth).
  # bd-cwe9n2: the final no-verdict escalation names the commands the policy
  # refused, so the operator is not left with a bare "inconclusive".
  defp denied_commands_note(%{denied_commands: [_ | _] = cmds}) do
    " Denied by the permission policy during the review: " <>
      Enum.map_join(cmds, ", ", &"`#{&1}`") <> "."
  end

  defp denied_commands_note(_state), do: ""

  defp no_verdict_scan_message(state), do: scan_message(state) <> denied_commands_note(state)

  defp scan_message(%{verdict_scan: %{memory: 0, durable: durable}} = state)
       when durable in [0, nil] do
    "Reviewer produced no captured output at all (0 live line(s), " <>
      durable_count_desc(durable) <>
      "), even after a verdict re-prompt. " <> transcript_location_note(state)
  end

  defp scan_message(%{verdict_scan: %{memory: memory, durable: durable}} = state) do
    "Reviewer output was received (#{memory} live line(s), " <>
      durable_count_desc(durable) <>
      ") but no parseable VERDICT line was found in it, even after a verdict re-prompt. " <>
      transcript_location_note(state)
  end

  defp scan_message(state) do
    "Reviewer output was received but no parseable VERDICT line was found in it (checked " <>
      "both the live capture and the durable transcript), even after a verdict re-prompt. " <>
      transcript_location_note(state)
  end

  defp durable_count_desc(nil), do: "durable transcript could not be read"
  defp durable_count_desc(n), do: "#{n} durable line(s)"

  # Best-effort pointer to the durable per-run transcript(s), so a genuine
  # `:no_verdict` names where to look rather than leaving the reader to assume
  # the reviewer produced nothing at all. Prefers the run id(s) already
  # resolved (and stashed in `verdict_scan(s)`) by the scan(s) that produced
  # this escalation, so the path(s) named are provably what was checked
  # rather than whatever `reviewer_run_id/1` resolves to NOW (which can differ
  # if another pass's Run row landed in between). bd-869mmg round 3: when
  # MULTIPLE passes ran (a re-prompt fired), name every one of them with its
  # own line count — naming only the LAST pass's transcript (typically the
  # re-prompt's, which genuinely has nothing) points the reader straight at
  # the wrong evidence and confirms the false "the reviewer is broken"
  # conclusion this message exists to prevent.
  defp transcript_location_note(%{verdict_scans: [_, _ | _] = scans}) do
    "Durable transcripts checked: " <> Enum.map_join(scans, ", ", &scan_note/1)
  end

  defp transcript_location_note(%{verdict_scans: [scan]}), do: single_transcript_note(scan)

  defp transcript_location_note(%{verdict_scan: scan}) when is_map(scan),
    do: single_transcript_note(scan)

  defp transcript_location_note(state) do
    case reviewer_run_id(state) do
      run_id when is_binary(run_id) and run_id != "" ->
        "Durable transcript: #{OutputLog.path_for(run_id)}"

      _ ->
        "No run id could be resolved for this pass, so the durable transcript could not be located."
    end
  end

  defp single_transcript_note(%{run_id: run_id}) when is_binary(run_id) and run_id != "" do
    "Durable transcript: #{OutputLog.path_for(run_id)}"
  end

  defp single_transcript_note(_) do
    "No run id could be resolved for this pass, so the durable transcript could not be located."
  end

  defp scan_note(%{run_id: run_id, durable: durable}) when is_binary(run_id) and run_id != "" do
    "#{OutputLog.path_for(run_id)} (#{durable_count_desc(durable)})"
  end

  defp scan_note(_), do: "an unresolved pass (no run id)"

  # ---- verdict guards (bd-4te55l / bd-6r8caj / bd-4yhv4x) ------------------

  # Four distinct malformed-APPROVE/REQUEST_CHANGES shapes reach this gate, and
  # all four are handled the same way: spend one retry from the SHARED
  # verdict-retry budget on a fresh reviewer mind, and if that budget is spent
  # (or the retry can't be spawned) fail closed — record the honest round and
  # route the findings down the reject path behind a loud banner, rather than
  # accepting the verdict at face value.
  #
  # They used to be four hand-copied `retries_left > 0` triads. Each one traces
  # back to a real production bug, so the shape must not drift between them when
  # retry-budget semantics change; it now lives once, in `run_verdict_guard/4`,
  # and only the per-guard differences live in `verdict_guard_spec/2`:
  #
  #   guard                  reason                verdict          records
  #   ---------------------- --------------------- ---------------- --------
  #   :partial_verification  :unverified           :request_changes  banner
  #   :unaddressed_findings  :unaddressed_findings :approve          raw
  #   :unmet_criteria        :unmet_criteria       :approve          raw
  #   :missing_criteria      :missing_criteria     :approve          raw
  #
  # `records` is load-bearing, not cosmetic: `record_round/5` re-parses the
  # findings text for criteria counts, finding ids and dispositions. The
  # partial-verification guard is a REQUEST_CHANGES being carried forward, so it
  # records the bannered payload (what `handle_reject/2` did); the three APPROVE
  # guards record the reviewer's UNTOUCHED findings so those parsed columns still
  # describe what the reviewer actually said, and only the routed payload carries
  # the banner.
  @verdict_guards [
    :partial_verification,
    :unaddressed_findings,
    :unmet_criteria,
    :missing_criteria
  ]

  @doc false
  # Exposed for the parity harness in `review_gate_verdict_guards_test.exs`.
  @spec verdict_guard_names() :: [atom()]
  def verdict_guard_names, do: @verdict_guards

  # The shared retry-vs-fail-closed dispatcher. `ctx` is the guard's extra
  # payload (the approval gap, for `:unaddressed_findings`); the spec's closures
  # capture it so the dispatcher itself stays guard-agnostic.
  defp run_verdict_guard(name, state, findings, ctx \\ nil)

  defp run_verdict_guard(name, %{retries_left: budget} = state, findings, ctx)
       when budget > 0 do
    spec = verdict_guard_spec(name, ctx)
    stop_worker(state)

    case launch_worker(
           %{state | retries_left: budget - 1},
           reprompt_retry_id(state),
           :reviewer,
           verdict_reprompt_prompt(state, spec.reason),
           state.command
         ) do
      {:ok, state} ->
        Logger.info(spec.logs.retry.(state))
        {:reprompt, state}

      {:error, spawn_error} ->
        # NOTE: `state` here is the pre-launch state — a retry that never
        # spawned does not consume the budget.
        Logger.warning(spec.logs.spawn_error.(state, spawn_error))
        fail_closed(spec, state, findings)
    end
  end

  defp run_verdict_guard(name, state, findings, ctx) do
    spec = verdict_guard_spec(name, ctx)
    Logger.warning(spec.logs.exhausted.(state))
    fail_closed(spec, state, findings)
  end

  # Terminal handling shared by all four guards: record the HONEST round —
  # `converged: false`, with the guard's own verdict — so "approved without
  # accounting for finding X" / "APPROVE with N criteria unmet" is literally
  # queryable in `review_gate_rounds`, then route the banner-prefixed payload
  # down the shared reject path (escalate if the round budget is spent, else back
  # to the implementer).
  defp fail_closed(spec, state, findings) do
    bannered = spec.banner.(findings)
    recorded = if spec.record == :banner, do: bannered, else: findings

    record_round(state, :review, spec.verdict, recorded, converged: false)

    state = %{
      state
      | approval_gap_pending: approval_gap_pending_for(spec, findings),
        # bd-9zuvbh: remember that THIS reject came from a guard, not from a
        # reviewer. `do_route_after_reject/2` needs it to tell an exhausted
        # verdict guard (class C: park) from a genuine REQUEST_CHANGES at the
        # round cap (still a failed run, per P9's AC1).
        guard_rejected: spec.reason
    }

    route_after_reject(state, bannered)
  end

  # The re-prompt's task id. For round > 1 it must be based on the round-specific
  # review_id (bd-bgeo6i); round 1 uses the base review_id. Shared with
  # `maybe_reprompt/2`, which spends the same budget.
  defp reprompt_retry_id(state) do
    review_id =
      if state.round > 1 do
        reviewer_round_id(state.review_id, state.round)
      else
        state.review_id
      end

    reprompt_task_id(review_id, state.attempt)
  end

  @doc false
  # The per-guard table. Public only so the parity harness can assert each
  # guard's row directly; a missing name raises rather than defaulting, so a new
  # guard cannot half-exist.
  @spec verdict_guard_spec(atom(), term()) :: map()

  # bd-4te55l: a REQUEST_CHANGES verdict disclosed `VERIFICATION: PARTIAL` — the
  # reviewer itself says it did not finish confirming its findings against the
  # current diff/tests before finalizing. One more chance with a fresh mind and
  # fresh context; failing that, do NOT silently accept the unverified findings
  # at face value — proceed into the normal accept/escalate path, but with a loud
  # warning banner prepended so the thread, the revise prompt, and any escalation
  # payload all surface that this verdict was issued without full verification.
  def verdict_guard_spec(:partial_verification, _ctx) do
    guard_spec(
      reason: :unverified,
      verdict: :request_changes,
      record: :banner,
      banner: &ReviewVerification.prepend_banner/1,
      label: "partial-verification",
      situation: "disclosed partial verification",
      detail: " for a fully-verified pass",
      consequence: "proceeding with the unverified findings, clearly marked"
    )
  end

  # bd-6r8caj: an APPROVE that did not account for every Medium-or-higher open
  # finding. A fresh reviewer mind is handed the open findings, their ids, and
  # the diff the implementer actually produced, and told to disposition each one.
  # If the budget is spent the approval is NOT accepted at face value: the honest
  # `:approve` round is recorded and the payload is routed down the reject path
  # behind a banner naming the findings it skipped.
  def verdict_guard_spec(:unaddressed_findings, gap) do
    skipped = ReviewFindings.gap_findings(gap)

    guard_spec(
      reason: :unaddressed_findings,
      verdict: :approve,
      record: :raw,
      banner: &ReviewFindings.prepend_disposition_banner(&1, gap),
      gap: gap,
      label: "unaddressed-findings",
      # The only guard whose two `reviewer for task=...` lines differ: the retry
      # line reports how many findings were skipped, the terminal line names them.
      situation: "approved without dispositioning #{length(skipped)} open finding(s)",
      final_situation:
        "approved without dispositioning open finding(s) " <>
          Enum.map_join(skipped, ", ", & &1.id),
      consequence: "rejecting the approval, clearly marked"
    )
  end

  # bd-4yhv4x: an APPROVE whose own CRITERIA breakdown marks a stated acceptance
  # criterion `[NOT MET]` — the reviewer judged code quality but the work does
  # not satisfy the task as stated. One more chance to re-review each criterion
  # against the current diff with a fresh mind; failing that, record the honest
  # outcome and route it down the reject path with a loud banner carrying the
  # unmet-criteria reason and count.
  def verdict_guard_spec(:unmet_criteria, _ctx) do
    guard_spec(
      reason: :unmet_criteria,
      verdict: :approve,
      record: :raw,
      banner: &unmet_criteria_banner/1,
      label: "unmet-criteria",
      situation: "approved with unmet acceptance criteria",
      detail: " for a per-criterion re-review",
      consequence: "rejecting the approval, clearly marked"
    )
  end

  # bd-4yhv4x: an APPROVE on a criteria-bearing task that carries NO CRITERIA
  # breakdown at all — a bare holistic verdict that judged the diff without
  # accounting for a single acceptance criterion. This is the original bug's
  # exact shape (occurrences #1/#2), so it gets the same fail-closed treatment as
  # an admitted `[NOT MET]`: one more chance to re-review WITH the per-criterion
  # breakdown, then reject the approval rather than clean-merge it.
  #
  # Its fail-closed round is distinguishable from both a clean approve and an
  # admitted-unmet approve: `converged: false` with nil criteria counts — i.e.
  # "approved without a breakdown" (bd-4yhv4x AC7). That only holds because
  # `record: :raw` keeps the banner out of the recorded text.
  def verdict_guard_spec(:missing_criteria, _ctx) do
    guard_spec(
      reason: :missing_criteria,
      verdict: :approve,
      record: :raw,
      banner: &ReviewVerification.prepend_missing_criteria_banner/1,
      label: "missing-criteria",
      situation: "approved a criteria-bearing task with no CRITERIA breakdown",
      detail: " for a per-criterion review",
      consequence: "rejecting the approval, clearly marked"
    )
  end

  # Build one row. The three log lines a guard emits are one sentence with four
  # holes, so the rows below supply the holes instead of hand-writing twelve
  # near-identical strings that can drift apart:
  #
  #   retry        ReviewGate: reviewer for task=ID <situation>; re-prompting<detail> (attempt N)
  #   spawn_error  ReviewGate: <label> re-prompt failed to spawn for task=ID: <error>; <consequence>
  #   exhausted    ReviewGate: reviewer for task=ID <final_situation> and the re-prompt budget
  #                is exhausted; <consequence>
  #
  # `final_situation` defaults to `situation`; `detail` defaults to empty.
  defp guard_spec(row) do
    label = Keyword.fetch!(row, :label)
    situation = Keyword.fetch!(row, :situation)
    consequence = Keyword.fetch!(row, :consequence)
    detail = Keyword.get(row, :detail, "")
    final_situation = Keyword.get(row, :final_situation, situation)

    %{
      reason: Keyword.fetch!(row, :reason),
      verdict: Keyword.fetch!(row, :verdict),
      record: Keyword.fetch!(row, :record),
      banner: Keyword.fetch!(row, :banner),
      gap: Keyword.get(row, :gap),
      logs: %{
        retry: fn state ->
          "ReviewGate: reviewer for task=#{state.task_id} #{situation}; " <>
            "re-prompting#{detail} (attempt #{state.attempt})"
        end,
        spawn_error: fn state, error ->
          "ReviewGate: #{label} re-prompt failed to spawn for task=#{state.task_id}: " <>
            "#{inspect(error)}; #{consequence}"
        end,
        exhausted: fn state ->
          "ReviewGate: reviewer for task=#{state.task_id} #{final_situation} and the re-prompt " <>
            "budget is exhausted; #{consequence}"
        end
      }
    }
  end

  # Prepend the unmet-criteria warning banner (with the [NOT MET] count) right
  # after the `VERDICT:` line. Only reached once `unmet_criteria?/1` is true, so
  # the breakdown is present and `criteria_counts/1` returns integer counts.
  defp unmet_criteria_banner(findings) when is_binary(findings) do
    {total, unmet} = ReviewVerification.criteria_counts(findings)
    ReviewVerification.prepend_criteria_banner(findings, unmet, total)
  end

  # ---- verdict-guard predicates -------------------------------------------

  # What this approving round failed to establish about the findings still open
  # against the work. Pure — reads the carried-forward findings, the round's own
  # DISPOSITIONS block, and the files the revise round(s) really changed.
  defp approval_gap(state, findings) do
    ReviewFindings.approval_gap(
      Map.get(state, :open_findings, []),
      findings,
      Map.get(state, :revise_touched_files)
    )
  end

  # Whether the task under review actually carries stated acceptance criteria.
  # `state` does not cache the task's acceptance text, so load it on demand.
  # Option B: the unmet-criteria guard only fires for a task that HAS criteria —
  # a task with none has nothing to break down, and its APPROVE finalizes
  # unchanged. `load_task/1` never returns a nil acceptance (it falls back to
  # "(none)"), so a plain string compare is enough.
  defp has_acceptance_criteria?(state) do
    acceptance_present?(load_task(state.task_id).acceptance)
  end

  # Shared predicate: does this acceptance text state real criteria? `load_task/1`
  # falls back to "(none)" rather than nil, so treat that (and the empty string)
  # as "no criteria". Reused by `review_prompt/1` to decide whether to emit the
  # CRITERIA breakdown instruction, so the prompt and the guard agree on what
  # counts as having criteria.
  defp acceptance_present?(acceptance) do
    is_binary(acceptance) and String.trim(acceptance) not in ["", "(none)"]
  end

  # ---- reporting ----------------------------------------------------------

  # Report the given verdict to the author exactly once and mark reported.
  defp finish(%{reported?: true} = state, _verdict), do: state

  defp finish(state, verdict) do
    state = clear_pass(state)
    report(state, verdict)
    %{state | reported?: true}
  end

  # Report the verdict exactly once — to the author, or, when it is gone, to the
  # ticket (`deliver_verdict/4`). An inconclusive review (`:no_verdict`) is
  # forwarded as such; its safe default is to escalate without merging.
  defp report(state, verdict) do
    normalized = normalize_verdict(verdict)
    safe(fn -> Worker.report(state.author, :review_gate_rounds, state.round) end)
    delivered = deliver_verdict(state.task_id, state.author, normalized, gate_context(state))
    warn_undelivered(state, normalized, delivered)
    :ok
  end

  @doc """
  Deliver a ReviewGate verdict for ticket `task_id` (bd-741sid): the ReviewGate
  reports to the ticket.

  The `author` run gets it while it is resident — `:waiting` on the review
  gate, or finished `:failed` on an earlier round's rejection that a later APPROVE overturns
  (bd-3wumco). When the author is gone — its run ended between rounds, or it
  crashed — the verdict is applied to the ticket itself
  (`Arbiter.Worker.apply_review_gate_verdict_to_ticket/3`): an APPROVE still
  opens the PR and hands it to the ticket's Watchdog, and any other verdict is
  recorded on the ticket and escalated. `ctx` is what the gate knows about the
  round (`:branch`, `:worktree_path`, `:target_branch`, `:repo`,
  `:workspace_id`, `:pr_ref`), over the round state the ticket recorded.

  A verdict for a round some *newer* run has superseded — another run is
  working the ticket — is refused (`{:error, {:superseded_by_run, pid}}`)
  rather than applied over that run's work.
  """
  @spec deliver_verdict(String.t(), pid() | nil, verdict() | {:no_verdict, String.t()}, map()) ::
          :ok | {:error, term()}
  def deliver_verdict(task_id, author, verdict, ctx \\ %{}) when is_binary(task_id) do
    case deliver_to_author(author, verdict) do
      {:error, {:exit, _}} -> deliver_to_ticket(task_id, verdict, ctx)
      {:error, :no_author} -> deliver_to_ticket(task_id, verdict, ctx)
      other -> other
    end
  end

  defp deliver_to_author(author, verdict) when is_pid(author),
    do: safe_delivery(fn -> Worker.review_gate_verdict(author, verdict) end)

  defp deliver_to_author(_author, _verdict), do: {:error, :no_author}

  defp deliver_to_ticket(task_id, verdict, ctx) do
    case Worker.whereis(task_id) do
      nil ->
        safe_delivery(fn -> Worker.apply_review_gate_verdict_to_ticket(task_id, verdict, ctx) end)

      pid ->
        {:error, {:superseded_by_run, pid}}
    end
  end

  defp gate_context(state) do
    Map.take(state, [:branch, :worktree_path, :target_branch, :repo, :workspace_id, :pr_ref])
  end

  # `safe/1` for the verdict hand-off, except a raise/exit is REPORTED rather
  # than flattened to `:ok`. `Worker.review_gate_verdict/2` ends in a
  # `GenServer.call` on a raw pid, so an author that died or a node that
  # restarted between the round finishing and the report exits here — which is
  # the single most likely way a verdict lands nowhere in production. Under
  # plain `safe/1` that case looked identical to a successful delivery and was
  # silently swallowed; it now reaches `warn_undelivered/3` like any other
  # failure. Still never raises out of `report/2`: reporting is best-effort and
  # must not take the gate down.
  defp safe_delivery(fun) do
    fun.()
  rescue
    e -> {:error, {:raised, e}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # bd-3wumco: `safe/1` only shields against a raise/exit — an author that
  # *answers* `{:error, {:invalid_transition, ...}}` (it has already parked
  # terminal, e.g. on an earlier round's rejection) used to pass through here
  # unexamined, so a review that converged to APPROVE could vanish with no trace
  # at all beyond the merge that never happened. The Worker now reconciles a late
  # APPROVE forward, but any verdict that still lands nowhere must be loud —
  # including the raise/exit cases `safe_delivery/1` above now surfaces.
  defp warn_undelivered(_state, _verdict, :ok), do: :ok

  defp warn_undelivered(state, verdict, reason) do
    Logger.warning(
      "ReviewGate: could not deliver #{verdict_label(verdict)} verdict for " <>
        "task=#{state.task_id} (round #{state.round}) to its author or its ticket: " <>
        "#{inspect(reason)}. The review outcome is orphaned — nothing downstream " <>
        "will act on it."
    )
  end

  defp verdict_label({:parked, reason, _findings}), do: "PARKED(#{reason})"
  defp verdict_label({label, _findings}), do: label |> Atom.to_string() |> String.upcase()
  defp verdict_label(label) when is_atom(label), do: label |> Atom.to_string() |> String.upcase()

  defp normalize_verdict({:approve, _} = v), do: v
  defp normalize_verdict({:request_changes, _} = v), do: v
  defp normalize_verdict({:parked, _reason, _findings} = v), do: v

  defp normalize_verdict(:no_verdict),
    do: {:no_verdict, "Reviewer produced no parseable VERDICT line."}

  defp normalize_verdict({:no_verdict, _findings} = v), do: v

  # bd-dp7hiw: shared by the four pre-review escalation paths (branch conflict,
  # no commits, empty diff, reviewer spawn failure) that never reach a reviewer
  # pass, and so never go through handle_reject/2's record_round call. Without
  # a row here, worker.ex's note-writer points `review_gate_rounds_list` at
  # an empty history and dispatch.ex's prior_review_findings_section/1 (which
  # sources findings only from `Round`, not `notes`) sees nothing on a
  # re-dispatched fix-pass — a real data-loss regression, not just a dangling
  # pointer.
  # bd-9zuvbh: `park_reason` says which half of §5.3 the escalation falls under.
  #
  #   * nil — deliberately still a `:request_changes` run failure, because the
  #     pre-review condition is ACTIONABLE BY THE IMPLEMENTER and the honest
  #     answer is "this branch is not reviewable as it stands": a branch that
  #     conflicts with its target (someone must resolve it) and a branch with no
  #     commits on it (there is nothing to review). Neither is a liveness
  #     failure of the review — the work itself is what is missing or broken —
  #     so class C does not apply and these keep failing the run on purpose.
  #   * `:empty_diff` — G2, where the target has simply already absorbed the
  #     commits. The work is fine by definition, so §5.3's class-B rule applies:
  #     complete with one escalation rather than a run failure.
  #   * `:reviewer_failed` — the reviewer could not be spawned at all. No
  #     verdict, nothing for an implementer to fix, work nobody has faulted:
  #     class C parks it, exactly as a reviewer session that dies one step later
  #     is parked.
  defp escalate_pre_review(state, reason, park_reason \\ nil)

  defp escalate_pre_review(state, reason, nil) do
    record_round(state, :review, :request_changes, reason, converged: false)
    report(state, {:request_changes, reason})
    {:stop, :normal, %{state | reported?: true}}
  end

  defp escalate_pre_review(state, reason, park_reason) do
    record_round(state, :review, :request_changes, reason, converged: false)
    report(state, {:parked, park_reason, reason})
    {:stop, :normal, %{state | reported?: true}}
  end

  # Escalate the current pass as timed-out: report an INCONCLUSIVE verdict
  # carrying the timeout note plus (when a thread exists) the full escalation
  # payload, and stop. Shared by the reviewing-retry-exhausted path and the
  # revising path.
  #
  # bd-216r3e: this used to report `:request_changes` with the timeout note as
  # its single "finding", which is a self-sustaining re-dispatch loop.
  # REQUEST_CHANGES means "a reviewer found problems, send it back to an
  # implementer" — so the implementer re-verifies an unchanged branch, finds
  # nothing to fix (there are zero code findings, only the synthetic timeout
  # text), signals `arb done`, and the gate runs and times out again. Observed
  # on vs-2d0xxa: three rounds, all labelled "round 1", all with the identical
  # synthetic finding. No amount of worker iteration can clear a verdict no
  # reviewer ever produced.
  #
  # A timeout is an infrastructure/budget failure, not a review outcome, so it
  # reports `:no_verdict` — which the author parks as
  # `:review_gate_inconclusive` and escalates to the coordinator, where a human
  # decision (raise the budget, shrink the review, re-run) can actually break
  # the cycle.
  defp escalate_timeout(state) do
    msg = timeout_message(state)
    payload = if state.thread == [], do: msg, else: msg <> "\n\n" <> escalation_payload(state)

    # `/api/review_gate_rounds` is the only readable surface for a gate's
    # rounds, so a timeout must still leave a row — but an honest one:
    # `verdict: :timed_out` with `finding_count: 0`, which makes the loop
    # signature (repeated timed-out rounds on the same task) queryable instead
    # of indistinguishable from a reviewer that really did request changes.
    record_round(state, :review, :timed_out, payload, converged: false)

    # bd-9zuvbh: a timeout is a liveness failure of the REVIEW, never of the
    # work. Class C parks it: the author stamps the ticket's park reason, pages
    # the coordinator once naming the budget that ran out, and leaves the branch
    # exactly where it is for a human to re-run, merge or reject.
    report(state, {:parked, :reviewer_timeout, payload})
    {:stop, :normal, %{state | reported?: true}}
  end

  # The timeout note. States the budget that was actually in force for the pass
  # (`state.timeout_ms` is re-resolved per pass — see `resolve_timeout_ms/2`),
  # that there are NO findings to act on, and the remediation — so neither the
  # coordinator nor a re-dispatched implementer reads it as review feedback.
  defp timeout_message(state) do
    seconds = div(state.timeout_ms, 1000)

    "ReviewGate #{state.phase} pass timed out after #{seconds}s with no verdict " <>
      "(round #{state.round}).\n\n" <>
      "This is an INFRASTRUCTURE/BUDGET failure, not a review finding: no reviewer " <>
      "verdict was produced, so there is nothing for an implementer to fix and " <>
      "re-dispatching the task unchanged will simply time out again.\n\n" <>
      "Remediation: raise `review_gate.timeout_ms` for this workspace (the pass ran " <>
      "under #{state.timeout_ms}ms) or reduce what the review has to do — a cold " <>
      "build plus a full test suite can exceed the default budget on a large repo — " <>
      "then re-run the review. The new value applies to the next pass of a running " <>
      "gate; no worker restart is needed."
  end

  # ---- structured round outcomes (bd-aqyjuc) -------------------------------

  # Persist one row to `Arbiter.ReviewGate.Round` for a reviewer or implementer
  # pass that reached a genuine, actionable outcome. Best-effort: a DB hiccup
  # never breaks the loop (mirrors `persist_message/4`). `role: :review` rows
  # get `verdict` + `finding_count`; `role: :impl` rows always have `verdict:
  # nil` and `finding_count: nil` (implementers don't issue verdicts).
  defp record_round(state, role, verdict, findings, opts) do
    converged = Keyword.fetch!(opts, :converged)
    # bd-2eyf9y: which commit-gate outcome (if any) this :impl round hit —
    # nil for a normal round (HEAD advanced, or no worktree to check) and for
    # every :review row.
    commit_gate = Keyword.get(opts, :commit_gate)
    {run_id, reviewer_model, cost_usd} = pass_usage(state.current_id)

    # bd-3xultf: the resolved tier that governed this pass — recorded only
    # for :review rows, alongside `reviewer_model`, so analysis can control
    # for the judge instead of a routed-by-difficulty reviewer reading as a
    # quality change.
    reviewer_tier = if role == :review, do: reviewer_tier_for(state), else: nil

    # bd-3hb4ih: which provider ran this pass. Only for `:review` rows, and only
    # once a pass has actually been launched (`current_id` is nil on the
    # pre-review escalation paths, where no provider was ever reached and naming
    # one would be a guess).
    reviewer_provider =
      if role == :review and is_binary(state.current_id) do
        state |> reviewer_provider_for() |> provider_string()
      end

    # bd-a1ke2c: the cross-family audit trail, on the same rows.
    family_attrs =
      if role == :review and is_binary(state.current_id),
        do: reviewer_family_attrs(Map.get(state, :reviewer_selection)),
        else: %{}

    attrs =
      %{
        task_id: state.task_id,
        run_id: run_id,
        round: state.round,
        fix_round_attempt: Map.get(state, :fix_round_attempt, 0),
        role: row_role(state, role),
        verdict: verdict,
        findings: findings,
        reviewer_model: reviewer_model,
        reviewer_tier: reviewer_tier,
        reviewer_provider: reviewer_provider,
        cost_usd: cost_usd,
        converged: converged,
        commit_gate: commit_gate
      }
      |> Map.merge(review_outcome_attrs(role, verdict, findings, state))
      |> Map.merge(family_attrs)

    case Ash.create(Round, attrs) do
      {:ok, _row} ->
        note_conflict_round_outcome(state, role, verdict)
        :ok

      {:error, reason} ->
        Logger.warning(
          "ReviewGate: record_round/5 swallowed for task=#{state.task_id}: #{inspect(reason)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning(
        "ReviewGate: record_round/5 raised for task=#{state.task_id}: #{Exception.message(e)}"
      )

      :error
  end

  # Record the reviewer's per-criterion CRITERIA breakdown, and per-finding
  # identity/dispositions, structurally — but only for a `:review` row that
  # carries a genuine reviewer verdict.
  # bd-4yhv4x: {total, unmet} for a :review row that carried a breakdown,
  # {nil, nil} otherwise. :impl rows never carry a breakdown. Makes "APPROVE
  # with N criteria unmet" queryable without re-reading the transcript.
  # bd-6r8caj: give the round's findings identity, and record what this round
  # said about every finding carried INTO it. `undispositioned_count` is the
  # queryable form of the defect: an APPROVE row with a non-zero count is a
  # round that approved without accounting for an open Medium+ finding.
  # bd-216r3e: a `:timed_out` row carries an operator note, not reviewer
  # output — it has no findings, no criteria breakdown and no dispositions.
  # Scoring it like a real verdict is what made a timeout read as
  # "REQUEST_CHANGES, 1 finding" in the first place.
  defp review_outcome_attrs(role, verdict, findings, state) do
    review_outcome? = role == :review and verdict != :timed_out

    {criteria_total, criteria_unmet} =
      if review_outcome?, do: ReviewVerification.criteria_counts(findings), else: {nil, nil}

    {finding_ids, dispositions, undispositioned} =
      if review_outcome? do
        open = Map.get(state, :open_findings, [])

        {ReviewFindings.encode_ids(ReviewFindings.extract(findings, state.round)),
         ReviewFindings.encode_dispositions(open, findings),
         length(ReviewFindings.approval_gap(open, findings, nil).missing)}
      else
        {nil, nil, nil}
      end

    %{
      finding_count: finding_count(role, verdict, findings),
      criteria_total: criteria_total,
      criteria_unmet: criteria_unmet,
      finding_ids: finding_ids,
      dispositions: dispositions,
      undispositioned_count: undispositioned
    }
  end

  defp finding_count(role, verdict, findings) do
    cond do
      role != :review -> nil
      verdict == :timed_out -> 0
      true -> count_findings(findings)
    end
  end

  # Recompute the same tier `reviewer_model_tier/2` resolved for this pass's
  # spawn — deterministic given workspace config + `difficulty_at_dispatch`,
  # so re-deriving it here (rather than threading it through `state`) can't
  # drift from what actually spawned. Best-effort: nil on a missing/unloadable
  # workspace (e.g. a workspace-less ad-hoc ReviewGate run).
  defp provider_string(nil), do: nil
  defp provider_string(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp reviewer_family_attrs(%{} = sel) do
    %{
      reviewer_family: family_string(sel.family),
      implementer_family: family_string(sel.implementer_family),
      same_family_fallback: sel.same_family_fallback,
      same_family_fallback_reason: if(sel.same_family_fallback, do: sel.fallback_reason)
    }
  end

  defp reviewer_family_attrs(_selection), do: %{}

  defp family_string(nil), do: nil
  defp family_string(family) when is_atom(family), do: Atom.to_string(family)

  defp reviewer_tier_for(%{reviewer_selection: %{tier: tier}}) when is_binary(tier), do: tier

  defp reviewer_tier_for(state) do
    case load_workspace(state.workspace_id) do
      %Workspace{config: config} -> round_reviewer_tier(state, config)
      _ -> nil
    end
  end

  # Best-effort lookup of the run id / model / cost for the pass that just
  # exited, keyed by its synthetic worker id (`state.current_id` — e.g.
  # "<task>#review" or "<task>#review#impl1"). The Workers.Run row is created
  # at spawn time (no race). The Usage.Event row is written by `Arbiter.Worker`
  # in the same handler that broadcasts the exit we're reacting to, so it can
  # occasionally not be visible yet; a couple of short retries cover the common
  # case while keeping this a bounded, best-effort read (nil is an accepted
  # outcome elsewhere in the codebase — see `Arbiter.Usage.Event`).
  defp pass_usage(nil), do: {nil, nil, nil}

  defp pass_usage(pass_id) when is_binary(pass_id) do
    run_id = latest_run_id(pass_id)
    {model, cost_usd} = latest_usage(pass_id, 3)
    {run_id, model, cost_usd}
  end

  defp latest_run_id(task_id) do
    require Ash.Query

    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Run{id: id} -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp latest_usage(_task_id, 0), do: {nil, nil}

  defp latest_usage(task_id, attempts_left) do
    require Ash.Query

    UsageEvent
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %UsageEvent{model: model, cost_usd: cost_usd} ->
        {model, cost_usd}

      _ ->
        Process.sleep(20)
        latest_usage(task_id, attempts_left - 1)
    end
  rescue
    _ -> {nil, nil}
  end

  # Best-effort count of enumerated findings (numbered or bulleted list-item
  # lines) in a reviewer's findings text. Falls back to 1 for a non-empty,
  # unstructured findings body and 0 for a blank one — mirrors the
  # `findings_present?/1` heuristic used to decide whether a REQUEST_CHANGES
  # verdict is actionable at all.
  @finding_item ~r/^\s*(?:[-*]|\d+[.)])\s+\S/
  defp count_findings(nil), do: nil

  defp count_findings(findings) when is_binary(findings) do
    items =
      findings
      |> String.split("\n")
      # A CRITERIA breakdown line (`- [NOT MET] …`) is a list item to
      # `@finding_item`, but it is verdict payload, not an enumerated finding —
      # exclude it so the count reflects real findings only (bd-4yhv4x).
      |> Enum.reject(&ReviewVerification.criteria_line?/1)
      |> Enum.count(&Regex.match?(@finding_item, &1))

    cond do
      items > 0 -> items
      String.trim(findings) == "" -> 0
      true -> 1
    end
  end

  # ---- the persisted thread ----------------------------------------------

  # Append an entry to the in-memory thread AND persist it as a durable mailbox
  # row, so the implementer<->reviewer back-and-forth survives the workers that
  # wrote it and the escalation can present the full, ordered argument.
  defp record_thread(state, role, subject, body) do
    persist_message(state, role, subject, body)
    entry = %{round: state.round, role: role, subject: subject, body: body}
    %{state | thread: state.thread ++ [entry]}
  end

  # Persist one thread entry as an inter-agent `:flag` message scoped to the
  # task's workspace. task_ref = the author task id, so `Messages.thread/2`
  # reconstructs the ordered conversation for the task. Best-effort: a workspace-
  # less ReviewGate (ad-hoc run) or a DB hiccup never breaks the loop.
  defp persist_message(%{workspace_id: ws} = state, role, subject, body) when is_binary(ws) do
    {from_ref, to_ref} = thread_refs(state, role)

    safe(fn ->
      Arbiter.Messages.Message.send_mail(%{
        kind: :flag,
        from_ref: from_ref,
        to_ref: to_ref,
        workspace_id: ws,
        task_ref: state.task_id,
        subject: cap(subject, 500),
        body: body
      })
    end)

    :ok
  end

  defp persist_message(_state, _role, _subject, _body), do: :ok

  # reviewer findings travel review_id -> task (the implementer); the
  # implementer's response travels task -> review_id; system notes are attributed
  # to the ReviewGate (review_id) and addressed at the task.
  defp thread_refs(state, :reviewer), do: {state.review_id, state.task_id}
  defp thread_refs(state, :implementer), do: {state.task_id, state.review_id}
  defp thread_refs(state, :system), do: {state.review_id, state.task_id}

  # Compose the escalation payload Darth Gnosis judges with: the FULL ordered
  # transcript, plus the current diff of the branch under review.
  defp escalation_payload(state) do
    """
    ReviewGate escalation — not converged after #{state.round} round(s) of review
    (cap #{state.max_rounds}). The implementer and reviewer did not reach
    agreement; the full argument follows for your judgement.

    ## Full implementer↔reviewer transcript

    #{render_thread(state.thread)}

    ## Current diff (#{state.branch} since #{diff_range(state)})

    ```
    #{current_diff(state)}
    ```

    ## Worktree status (uncommitted changes, if any)

    ```
    #{worktree_status(state)}
    ```
    """
    |> String.trim()
  end

  defp render_thread([]), do: "(no messages were exchanged)"

  defp render_thread(thread) do
    thread
    |> Enum.map_join("\n\n---\n\n", fn %{round: round, role: role, subject: subject, body: body} ->
      "### Round #{round} — #{role_label(role)}: #{subject}\n\n#{String.trim(body)}"
    end)
  end

  defp role_label(:reviewer), do: "Reviewer → Implementer"
  defp role_label(:implementer), do: "Implementer → Reviewer"
  defp role_label(:system), do: "ReviewGate"

  # The current diff of the branch under review, capped. Best-effort: the
  # escalation is still useful without it. Diffs against the merge-base
  # (`diff_range/1`) so the target's later commits never appear in the payload.
  defp current_diff(%{worktree_path: wt} = state) when is_binary(wt) do
    case System.cmd("git", ["-C", wt, "diff", diff_range(state)], stderr_to_stdout: true) do
      {out, 0} -> cap(out, @diff_cap_bytes)
      {out, _} -> "(could not compute diff)\n" <> cap(out, 2_000)
    end
  rescue
    _ -> "(diff unavailable)"
  catch
    :exit, _ -> "(diff unavailable)"
  end

  defp current_diff(_state), do: "(diff unavailable — no worktree)"

  # The git range the reviewer (and the escalation diff) should use: the
  # merge-base when known (`base_sha..HEAD` isolates the branch's own changes
  # even after the target advanced), else the three-dot form against the target
  # (which also reaches the merge-base). bd-ased52.
  defp diff_range(%{base_sha: base}) when is_binary(base), do: "#{base}..HEAD"
  defp diff_range(%{target_branch: target}), do: "#{target}...HEAD"

  # bd-ofql8k defense-in-depth: an empty `base..HEAD` diff is NOT the same as
  # "no work" — the worker may have edited files and forgotten to commit. Pair
  # the diff with `git status --porcelain` so the escalation payload makes the
  # uncommitted state visible and the recipient (the reviewer prompt, Darth
  # Gnosis, the operator) can recognize it as "work present but uncommitted"
  # rather than the misdiagnosis the Worker's commit gate already guards
  # against. The gate is the primary defense; this is the backstop.
  defp worktree_status(%{worktree_path: wt}) when is_binary(wt) do
    case System.cmd("git", ["-C", wt, "status", "--porcelain"], stderr_to_stdout: true) do
      {"", 0} -> "(clean — no uncommitted changes)"
      {out, 0} -> cap(out, 4_000)
      {out, _} -> "(could not run git status)\n" <> cap(out, 2_000)
    end
  rescue
    _ -> "(status unavailable)"
  catch
    :exit, _ -> "(status unavailable)"
  end

  defp worktree_status(_state), do: "(status unavailable — no worktree)"

  # ---- pre-spawn commit check (bd-1mksks) ---------------------------------

  # Verify that the branch under review has commits ahead of target_branch
  # before spawning the reviewer. Returns {:ok, head_sha_or_nil} when safe
  # to proceed, {:error, human_message} when the reviewer would see an empty
  # diff.
  #
  # This is a second layer of defence on top of the worker commit gate
  # (bd-ofql8k). It covers two cases the worker gate misses:
  #   (B) the revise-round implementer worker has no worktree_path in meta,
  #       so the worker commit gate does not fire for revise rounds; and
  #   (C) the ReviewGate is started in an ad-hoc configuration without going
  #       through the normal worker dispatch path.
  #
  # When worktree_path is nil or git fails, the check is skipped (fail-open):
  # a transient git hiccup must not strand a legitimate review.
  defp reviewer_commit_check(%{worktree_path: wt, branch: branch, target_branch: target})
       when is_binary(wt) do
    # Mirror the worker commit gate's branch guard (bd-ofql8k): only check
    # for commits when the worktree is actually checked out on the per-task
    # branch. Some test setups and ad-hoc runs reuse the repo as the
    # "worktree" with HEAD on `main`; in that case `rev-list main..HEAD` is
    # meaningless (always 0) and the check would manufacture a false positive.
    # Production worktrees provisioned via Worktree.create/3 are always on the
    # per-task branch, so the gate fires correctly in production.
    case Arbiter.Worker.Worktree.current_branch(wt) do
      {:ok, ^branch} ->
        # Worktree IS on the expected branch — verify commits exist.
        # has_commits_ahead?/2 is fail-open: git errors resolve to {:ok, true},
        # so {:ok, false} is the only genuine "no commits" result.
        case Arbiter.Worker.Worktree.has_commits_ahead?(wt, target) do
          {:ok, true} ->
            {:ok, current_head_sha_in(wt)}

          {:ok, false} ->
            {:error,
             "Branch `#{branch}` has no commits ahead of `#{target}`. " <>
               "The reviewer would see an empty diff and report 'no work'. " <>
               "The implementer must commit before the review gate can proceed. " <>
               "Run `git log --oneline #{target}..HEAD` in the worktree to diagnose."}
        end

      _ ->
        # Worktree is on a different branch (or current_branch failed). Skip
        # the commit check — a HEAD mismatch is not "no work done".
        {:ok, current_head_sha_in(wt)}
    end
  end

  defp reviewer_commit_check(_state), do: {:ok, nil}

  # bd-31bh37: guard against spawning a reviewer over an empty diff range.
  # If base_sha == head_sha then `git diff base_sha..HEAD` is empty — the
  # reviewer would see no changes and falsely conclude "no work was done". This
  # happens when origin/<target> has already incorporated the task's commits
  # (making the merge-base equal to HEAD) and sync_from_origin didn't advance
  # the branch beyond that merge-base. Escalate loudly rather than letting a
  # reviewer produce a bogus REQUEST_CHANGES.
  # Skipped when either SHA is nil (no worktree, or git unavailable) — those
  # cases have no diff at all and are handled upstream by reviewer_commit_check.
  defp empty_diff_guard(%{head_sha: head, base_sha: base})
       when is_binary(head) and is_binary(base) and head == base do
    {:error,
     "ReviewGate: diff range `#{base}..HEAD` is empty — HEAD and merge-base are the same " <>
       "commit (`#{head}`). The branch's commits may have already been incorporated into the " <>
       "target branch. The reviewer would see an empty diff and bogusly conclude 'no work'. " <>
       "Escalating for coordinator review rather than running a reviewer over an empty diff."}
  end

  defp empty_diff_guard(_state), do: :ok

  # Return the short HEAD SHA for the worktree at `path`, or nil on any error.
  defp current_head_sha_in(path) when is_binary(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Resolve the current HEAD SHA from state.worktree_path. Used by
  # note_head_change/1 to detect whether the revise implementer committed.
  defp current_head_sha(%{worktree_path: wt}) when is_binary(wt),
    do: current_head_sha_in(wt)

  defp current_head_sha(_state), do: nil

  # `{:ok, trimmed_stdout}` for a git command that succeeded in `path`, `:error`
  # otherwise. Never raises: a missing worktree, a git that isn't there and a
  # non-zero exit are all the same "cannot answer" to `remote_advance/1`.
  defp git_out(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  defp ancestor?(path, a, b),
    do: match?({:ok, _}, git_out(path, ["merge-base", "--is-ancestor", a, b]))

  # Return the FULL HEAD SHA for the worktree at `path`, or nil on any error.
  # Deliberately not the abbreviated form `current_head_sha_in/1` returns: this
  # one is compared against what the forge reports, and forges report 40 hex
  # characters — and it is the same value the Watchdog is handed as
  # `local_head_sha`, so both must come from one implementation (bd-ch9pmk).
  defp full_head_sha_in(path) when is_binary(path), do: Worktree.head_sha(path)

  defp full_head_sha_in(_path), do: nil

  # bd-6bg54c / #1573 (Cause B): stamp the reviewed SHA on the AUTHORING task,
  # every time a review round approves.
  #
  # Before this, `last_reviewed_sha` was only ever written on a ReviewPatrol /
  # ExternalReview *engagement* issue (`review_only: true`), never on the task
  # whose PR the merge guard actually protects. The Watchdog's guard therefore
  # fell back to the head it happened to latch on the first approved poll and —
  # because `effective_outcome/2` pins `via_review_gate` lanes to `:approved`
  # forever, so the latch never drops — could never learn that a later round
  # approved a NEWER head. A fix round that pushed SHA2 after a REQUEST_CHANGES
  # on SHA1 left the guard holding SHA1 and refusing the merge ~1/min forever.
  #
  # Re-stamping on every APPROVE is the fix: the stamp always names the head the
  # reviewer actually reviewed. Best-effort — a failure here must never take the
  # gate down, it only means the guard keeps the previous (conservative) value.
  defp stamp_reviewed_head(state) do
    # bd-2jkrqu: never stamp a head the PR does not carry. A refusal here leaves
    # `last_reviewed_sha` at its older, more conservative value, which keeps the
    # merge guard CLOSED — the safe direction.
    with task_id when is_binary(task_id) <- Map.get(state, :task_id),
         {:ok, sha} <- reviewed_head(state),
         {:ok, task} <- Ash.get(Issue, task_id) do
      case Ash.update(task, %{last_reviewed_sha: sha, last_reviewed_at: DateTime.utc_now()}) do
        {:ok, _} ->
          Logger.debug("ReviewGate: stamped reviewed SHA #{sha} on task=#{task_id}")
          :ok

        {:error, reason} ->
          Logger.warning(
            "ReviewGate: could not stamp reviewed SHA on task=#{task_id}: #{inspect(reason)}"
          )

          :ok
      end
    else
      _ -> :ok
    end
  rescue
    e ->
      Logger.warning("ReviewGate: reviewed-SHA stamp raised: #{inspect(e)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("ReviewGate: reviewed-SHA stamp exited: #{inspect(reason)}")
      :ok
  end

  # bd-203cl5 / #1648 (design #1635 §3.3, the ReviewGate row of the stamping
  # table): alongside the `last_reviewed_sha` stamp above, record an append-only
  # `review_coverage` row naming the exact head this round approved.
  #
  # `last_reviewed_sha` stays authoritative — nothing reads coverage yet (that
  # is P3/P4's `Coverage.decide/3`). What this buys today is the audit trail
  # §3.3 argues the scalar stamp cannot be: one row per approving round, with
  # the round number and the net-diff fingerprint of what was approved, so a
  # later head can be compared for content equality instead of SHA equality.
  #
  # **This write is deliberately NOT best-effort.** The stamp above swallows its
  # failures because a missing stamp only makes the guard more conservative; a
  # missing coverage row is the opposite — §3.3: "a silently-missing row *is*
  # the #1585 stall". So every way this can fail (no ids, an unfingerprintable
  # diff, a rejected insert, a raise, an exit) pages the coordinator once
  # through the shared bd-5jr49o breaker. It still never crashes the gate: the
  # approval has already been recorded and stamped by the time we get here.
  defp record_review_coverage(state) do
    task_id = Map.get(state, :task_id)
    mr_ref = coverage_mr_ref(state)
    head_sha = local_head_for_report(state)
    base_ref = Map.get(state, :target_branch)

    with {:ok, task_id} <- present(task_id, :no_task_id),
         {:ok, mr_ref} <- present(mr_ref, :no_mr_ref),
         # bd-2jkrqu: the row must name the head the PR carries, not the local
         # one. `{:error, {:head_not_pushed, _}}` routes into coverage_failed/4
         # below: no row, and one page — the silently-missing row §3.3 warns
         # about is exactly what an unpushed approval would leave behind.
         {:ok, head_sha} <- reviewed_head(state),
         {:ok, base_ref} <- present(base_ref, :no_base_ref),
         {:ok, net_diff_id} <- coverage_net_diff_id(state) do
      coverage_writer().(%{
        task_id: task_id,
        mr_ref: mr_ref,
        head_sha: head_sha,
        base_ref: base_ref,
        net_diff_id: net_diff_id,
        kind: :reviewed,
        source: :review_gate,
        round: Map.get(state, :round)
      })
      |> case do
        {:ok, _entry} ->
          Logger.debug(
            "ReviewGate: recorded review coverage for task=#{task_id} head=#{head_sha}"
          )

          :ok

        {:error, reason} ->
          coverage_failed(state, mr_ref, head_sha, reason)
      end
    else
      {:error, reason} -> coverage_failed(state, mr_ref, head_sha, reason)
    end
  rescue
    e -> coverage_failed(state, coverage_mr_ref(state), nil, e)
  catch
    :exit, reason -> coverage_failed(state, coverage_mr_ref(state), nil, {:exit, reason})
  end

  defp coverage_failed(state, mr_ref, head_sha, reason) do
    Logger.warning(
      "ReviewGate: review-coverage write failed for task=#{Map.get(state, :task_id)}: " <>
        inspect(reason)
    )

    _ =
      escalate_coverage_write_failure(
        %{task_id: Map.get(state, :task_id), workspace_id: Map.get(state, :workspace_id)},
        mr_ref,
        head_sha,
        reason
      )

    :ok
  end

  @doc """
  Page the coordinator once because a clean APPROVE could not record its
  review-coverage row (design #1635 §3.3).

  Public so the bd-5jr49o breaker adoption can be exercised directly — the
  gate's own path reaches it through `record_review_coverage/1`. Returns `:ok`
  when the page was sent and `:suppressed` when the breaker held it back.
  """
  @spec escalate_coverage_write_failure(map(), String.t() | nil, String.t() | nil, term()) ::
          :ok | :suppressed
  def escalate_coverage_write_failure(snapshot, mr_ref, head_sha, reason) do
    result =
      CircuitBreaker.guard(
        :review_coverage_write_failed,
        [Map.get(snapshot, :task_id), mr_ref],
        [
          workspace_id: Map.get(snapshot, :workspace_id),
          task_ref: Map.get(snapshot, :task_id),
          detail:
            "Review-coverage writes keep failing for this task's PR. This is almost " <>
              "certainly systemic (migration not run, table missing) rather than " <>
              "per-approval — check `review_coverage` before clearing."
        ],
        fn ->
          CoordinatorNotifier.review_coverage_write_failed(snapshot, mr_ref, head_sha, reason)
        end
      )

    case result do
      {:ok, _} -> :ok
      {:suppressed, _info} -> :suppressed
    end
  end

  # The PR this coverage is about. The gate's `pr_ref` is the same opaque ref
  # the Watchdog and MergeQueue key their merge guards on, so a row recorded
  # here is findable by the reader P3/P4 adds. A gate that ran before the PR was
  # opened has no such ref; the branch is then the only stable handle on the
  # work, and is used rather than dropping the row.
  defp coverage_mr_ref(state) do
    case Map.get(state, :pr_ref) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> Map.get(state, :branch)
    end
  end

  # `NetDiff.fingerprint(base_ref...head_sha)` for what the reviewer was shown:
  # the gate already diffs `diff_range/1` (the merge-base when known) for the
  # reviewer prompt, so fingerprinting the same range means the row describes
  # exactly the content that was approved. `nil` is a failure, never a value —
  # see `NetDiff.fingerprint/1` on why an empty diff must not compare equal.
  defp coverage_net_diff_id(state) do
    case review_tree(state) do
      tree when is_binary(tree) ->
        case NetDiff.fingerprint_local(tree, diff_range(state)) do
          id when is_binary(id) -> {:ok, id}
          nil -> {:error, :no_net_diff}
        end

      _ ->
        {:error, :no_worktree}
    end
  end

  defp present(value, _tag) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, tag), do: {:error, tag}

  # The coverage writer, overridable for tests that need `record/1` to fail on
  # demand (there is no other way to exercise the escalation path, and §3.3
  # makes that path load-bearing). Production always resolves to
  # `Coverage.record/1`.
  defp coverage_writer do
    case Application.get_env(:arbiter, :review_coverage_writer) do
      fun when is_function(fun, 1) -> fun
      _ -> &Coverage.record/1
    end
  end

  # ---- worker spawning ---------------------------------------------------

  # Subscribe to the worker's output topic, spawn it, arm a fresh (attempt-
  # tagged) timeout, and reset the line buffer for this pass. Used for every
  # reviewer pass (first review, re-review, verdict re-prompt) and every
  # implementer revision; returns the updated state on success. Subscribe BEFORE
  # spawning so we can't miss the worker's first output lines or its exit signal
  # (the subprocess may finish almost immediately — a fast worker or a test
  # fixture). The topic is known from the id alone, so subscribing ahead of the
  # port open is safe.
  defp launch_worker(state, id, role, prompt, command) do
    Phoenix.PubSub.subscribe(Arbiter.PubSub, "worker:" <> id)
    attempt = state.attempt + 1

    # bd-216r3e: resolve the budget for THIS pass now, not once at gate init.
    # A gate can outlive several passes (timeout retry, verdict re-prompt,
    # every revise round), and an operator who raises `review_gate.timeout_ms`
    # mid-run must see it applied on the next pass. Resolved BEFORE spawning
    # (not after) so `build_session_opts/5` — invoked from inside
    # `spawn_worker/5` — hands the adapter this pass's value instead of the
    # previous pass's `state.timeout_ms`.
    timeout_ms =
      state.workspace_id
      |> resolve_timeout_ms(state.timeout_override_ms)
      |> round_timeout_ms(state, role)

    state = %{state | timeout_ms: timeout_ms} |> route_reviewer_pass(role, command)
    prompt = retarget_async_block(prompt, state, role)

    case guarded_spawn_worker(state, id, role, prompt, command) do
      {:ok, pid} ->
        Process.send_after(self(), {:timeout, state.round, attempt}, timeout_ms)

        launched = %{
          state
          | reviewer_pid: pid,
            current_id: id,
            attempt: attempt,
            lines: [],
            denial_pending: false,
            current_prompt: prompt,
            timeout_ms: timeout_ms
        }

        {:ok, mark_pass(launched, role, id)}

      {:error, _reason} = err ->
        err
    end
  end

  # bd-7xtz6w: a spawn that RAISES (or exits) must come back as the same
  # `{:error, _}` an ordinary spawn refusal does. Every caller of
  # `launch_worker/5` already turns that into a recorded round and a verdict;
  # a raise instead killed the gate between passes — after one pass's timer was
  # spent and before the next one's was armed, so nothing was left to time out.
  # That is bd-45tkhq: `Arbiter.Worker.start/1` was momentarily undefined during
  # a code reload as round 3's reviewer launched, the gate died with no round
  # row and no verdict, and the author sat waiting on the review gate for 3+
  # hours.
  defp guarded_spawn_worker(state, id, role, prompt, command) do
    spawn_worker(state, id, role, prompt, command)
  rescue
    error ->
      Logger.error(
        "ReviewGate: spawning #{role} #{id} for task=#{state.task_id} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:error, {:spawn_crashed, Exception.format_banner(:error, error)}}
  catch
    kind, reason ->
      Logger.error(
        "ReviewGate: spawning #{role} #{id} for task=#{state.task_id} failed: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      {:error, {:spawn_crashed, Exception.format_banner(kind, reason)}}
  end

  # Start an worker as a distinct worker + claude session under `id`. The
  # worker gets workspace_id: nil so its completion stays silent — no coordinator
  # notification, no MergeQueue pickup for the synthetic id — while still recording
  # its own run row.
  defp spawn_worker(state, id, role, prompt, command) do
    # bd-2exkl0 (finding 6): resolve the implementer's provider ONCE per spawn
    # and thread the same {provider, fallback_reason, decision} tuple through
    # worker_meta/3, adapter_for/4 and build_session_opts/6 — re-resolving at
    # each call site risked the adapter actually spawned diverging from the
    # provider recorded in the run's meta if availability flipped mid-spawn
    # (e.g. the CredentialWatchdog flagging a provider between calls).
    revision = resolve_revision(state, role)

    with :ok <- ensure_revision_unpaused(state, revision),
         {:ok, pid} <- start_worker_process(state, id, role, revision),
         :ok <- start_worker_session(state, pid, role, prompt, command, revision) do
      _ = Worker.advance(pid, step_for(role))
      {:ok, pid}
    end
  end

  # bd-40pzpj: under `most_quota` routing the task's implementer pin decides
  # (with a recorded fallback); otherwise exactly
  # `Agents.resolve_revision_provider/2`. The decision rides in the tuple's
  # third element to `worker_meta/3`, which records it on the round's run.
  defp resolve_revision(state, :implementer) do
    ws = load_workspace(state.workspace_id)

    {provider, fallback_reason, decision} =
      ProviderRouting.implementer_provider(state.task_id, ws, :review_gate_implementer)

    if fallback_reason && ProviderRouting.escalate_fallback?(decision) do
      CoordinatorNotifier.provider_fallback(
        %{workspace_id: state.workspace_id, task_id: state.task_id},
        Run.latest_authoring_provider(state.task_id),
        provider,
        fallback_reason
      )
    end

    {provider, ProviderRouting.truncate_fallback(fallback_reason), decision}
  end

  defp resolve_revision(_state, :reviewer), do: nil

  # bd-13pqcp: an implementer round also refuses a provider the ticket's own
  # constraint excludes (`resolve_revision/2` already steers away from it; this
  # is the last word). The reviewer (`resolve_revision/2`'s `nil`) is not
  # constrained.
  defp ensure_revision_unpaused(state, {provider, _reason, _decision}) do
    with :ok <- ProviderRouting.ensure_unpaused(provider, state.workspace_id) do
      ProviderConstraint.check(state.task_id, provider)
    end
  end

  defp ensure_revision_unpaused(_state, _), do: :ok

  defp start_worker_process(state, id, role, revision) do
    case Worker.start(
           task_id: id,
           repo: state.repo,
           workspace_id: nil,
           meta: worker_meta(state, role, revision)
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:worker_start_failed, reason}}
    end
  end

  defp worker_meta(state, :reviewer, revision) do
    ws = load_workspace(state.workspace_id)

    # bd-1abj7u: this only stamps *display* metadata on the worker row, ahead
    # of the real write-confinement gate in `build_session_opts/6` — an
    # ineligible provider here does not skip that gate, it just means the
    # meta names the workspace's intended reviewer type rather than an
    # adapter that will actually be refused a moment later.
    provider =
      case adapter_for(state, ws, :reviewer, revision) do
        {:ok, {rev_adapter, _}} -> rev_adapter.provider()
        {:error, _reason} -> Atom.to_string(Agents.reviewer_type(ws))
      end

    %{
      role: :reviewer,
      reviews: state.task_id,
      difficulty_at_dispatch: difficulty_at_dispatch_for(state.task_id),
      provider: provider
    }
  end

  defp worker_meta(state, :implementer, {provider, fallback_reason, decision}) do
    %{
      role: :implementer,
      revises: state.task_id,
      difficulty_at_dispatch: difficulty_at_dispatch_for(state.task_id),
      provider: Atom.to_string(provider),
      provider_fallback: fallback_reason
    }
    |> Map.merge(ProviderRouting.run_meta(decision))
  end

  # bd-3xultf: `state.task_id` is the BASE task id (not a synthetic ReviewGate
  # id) — read the *author's own run* `difficulty_at_dispatch` (stamped once,
  # immutably, when that run was dispatched — see
  # `Arbiter.Worker.Dispatch.build_worker_meta/3`), not a live re-read of
  # `Issue.difficulty`. A difficulty edited after dispatch (bd-7rspia) must
  # not retroactively relabel which tier a past reviewer/implementer pass ran
  # under. Falls back to the task's current difficulty when no author Run row
  # exists (e.g. an ad-hoc ReviewGate started without going through Dispatch)
  # — best-effort, nil on any lookup failure rather than blocking the spawn.
  defp difficulty_at_dispatch_for(task_id) do
    require Ash.Query

    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Run{difficulty_at_dispatch: d} when is_integer(d) -> d
      _ -> difficulty_for(task_id)
    end
  rescue
    _ -> difficulty_for(task_id)
  end

  defp difficulty_for(task_id) do
    case load_issue(task_id) do
      %Issue{difficulty: difficulty} -> difficulty
      _ -> nil
    end
  end

  defp step_for(:reviewer), do: :reviewing
  defp step_for(:implementer), do: :revising

  defp start_worker_session(state, pid, role, prompt, command, revision) do
    case build_session_opts(state, pid, role, prompt, command, revision) do
      {:ok, session_opts} ->
        case ClaudeSession.start(session_opts ++ arb_token_opts(state, role)) do
          {:ok, _port} -> :ok
          {:error, reason} -> {:error, {:worker_session_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:worker_session_failed, reason}}
    end
  end

  # Assemble `ClaudeSession.start/1` opts for an worker. The fixture-friendly
  # `command:` escape hatch (test path) bypasses the adapter — when set we spawn
  # the provided argv verbatim. Otherwise we route through `Arbiter.Agents` so
  # the reviewer role honors `workspace.config["review_agent"]["config"]`
  # (model + api keys), and the implementer role honors the worker `agent`
  # block. A workspace-less ReviewGate (ad-hoc run) falls back to today's
  # behaviour — `ClaudeSession`'s built-in default argv, no model flag.
  # bd-asawcq: `/api` needs a bearer token. A revise-round implementer works
  # the task like its first-round worker (`arb ticket update`, `arb message`),
  # so it gets the same narrow worker-tier token as its ARB_TOKEN — never a
  # coordinator one. The reviewer only reads the diff and prints a verdict; it
  # gets none. A missing signing secret never blocks the spawn.
  defp arb_token_opts(%{task_id: task_id, workspace_id: ws_id} = state, :implementer)
       when is_binary(task_id) and is_binary(ws_id) do
    [
      arb_token:
        Arbiter.MCP.Scope.mint_worker(%{id: task_id, workspace_id: ws_id}, Map.get(state, :repo))
    ]
  rescue
    e ->
      Logger.warning("ReviewGate: minting the implementer's worker token failed: #{inspect(e)}")
      []
  end

  defp arb_token_opts(_state, _role), do: []

  defp build_session_opts(state, pid, role, prompt, command, revision) when is_list(command) do
    # bd-9rdwe4: `command:` wins argv resolution, but `prompt:` is still carried
    # so the pass records what the agent was actually told
    # (`ClaudeSession.start/1` forwards it as `:composed_prompt` →
    # `Arbiter.Worker.PromptLog`). Without it a custom-argv pass leaves no
    # record of its prompt at all.
    base = [owner: pid, worktree_path: session_cwd(state, role), command: command, prompt: prompt]

    prov_str =
      case Map.get(state, :command_provider) do
        provider when is_binary(provider) ->
          provider

        _ ->
          case role do
            :implementer ->
              {provider, _fallback_reason, _decision} = revision
              Atom.to_string(provider)

            :reviewer ->
              ws = load_workspace(state.workspace_id)

              case adapter_for(state, ws, :reviewer, revision) do
                {:ok, {adapter, _}} -> adapter.provider()
                {:error, _reason} -> Atom.to_string(Agents.reviewer_type(ws))
              end
          end
      end

    {:ok, base ++ [provider: prov_str]}
  end

  defp build_session_opts(state, pid, role, prompt, nil, revision) do
    base = [owner: pid, worktree_path: session_cwd(state, role)]

    case load_workspace(state.workspace_id) do
      nil ->
        prov_str =
          case role do
            :implementer ->
              {provider, _fallback_reason, _decision} = revision
              Atom.to_string(provider)

            :reviewer ->
              "claude"
          end

        {:ok, base ++ [prompt: prompt, provider: prov_str]}

      %Workspace{} = ws ->
        # bd-1abj7u findings 2 & 3: this is the one place that actually spawns
        # a reviewer/implementer session (`adapter.default_argv/2` below) — the
        # `is_list(command)` clause above is the test-fixture escape hatch, and
        # `worker_meta/3` only stamps display metadata ahead of this. A
        # `:strict` scope no configured provider for this role can keep must
        # refuse HERE, before argv is ever built, same as
        # `Dispatch.build_agent_session_opts/4`'s gate.
        case adapter_for(state, ws, role, revision) do
          {:error, reason} ->
            {:error, reason}

          {:ok, {adapter, role_atom}} ->
            build_gated_session_opts(state, pid, role, prompt, ws, adapter, role_atom, base)
        end
    end
  end

  defp build_gated_session_opts(state, pid, role, prompt, ws, adapter, role_atom, base) do
    :ok = Agents.prepare(ws, role_atom)

    # The reviewer/implementer worker gets the same per-domain security
    # posture as a worker spawn — resolved from the workspace, never the
    # operator's ~/.claude (bd-9u10op). Scope it to `state.repo` so a
    # per-repo override (config["agent"]["security"]["repos"][repo]) reaches
    # the review/revise workers spawned into that repo's worktree, matching
    # the dispatch spawn path (bd-3gc18m). `state.repo` defaults to
    # "unknown", a safe no-op when no override exists. A reviewer standing
    # in its round's checkout is also write-denied (bd-a22hib) — see
    # `session_security_policy/3`.
    # `workspace:` is carried for the adapter's `spawn_env/1` — it resolves
    # the worker OAuth token from this workspace's `worker_env` before
    # falling back to the server env (bd-bw3466).
    # bd-1xss5z: thread this pass's resolved timeout budget (re-resolved
    # live per pass by `launch_worker/5`, before it calls `spawn_worker/5`
    # — see `resolve_timeout_ms/2`) onto `agent_opts` so an adapter whose
    # CLI
    # has its own shorter internal turn timeout (agy's 5-minute
    # `--print-timeout`) can raise it to match. Adapters that don't
    # recognize `:timeout_ms` just ignore it.
    # `worktree_path:` keys the agy spawn's isolated `$HOME`
    # (`Arbiter.Agents.Gemini.ConfigDir`, bd-7s29yq) so a reviewer /
    # revise-round implementer gets the same generated permission posture
    # and Arbiter-owned `GEMINI.md` as a first-round worker, rather than
    # the operator's `~/.gemini`. Adapters that don't recognise it ignore
    # it.
    agent_opts =
      (ws
       |> agent_opts_for_role(role_atom, state.task_id, adapter)
       |> apply_conflict_tier(state, role)
       |> apply_reviewer_selection(state, role)) ++
        [
          security: session_security_policy(ws, state, role),
          workspace: ws,
          worktree_path: session_cwd(state, role),
          timeout_ms: state.timeout_ms,
          owner: pid,
          task_id: state.task_id
        ] ++ arb_token_opts(state, role)

    session_model = resolved_model_for(adapter, agent_opts)

    # bd-dzz6ly: same provenance backfill the main dispatch path reports
    # (Arbiter.Worker.Dispatch.build_agent_session_opts/4), so a reviewer
    # or revise-round implementer run answers "what governed it" too.
    # No `resolved_skills` here — these reviewer/implementer roles don't carry a
    # materialized skill set today, unlike the main worker.
    Worker.report(pid, :run_provenance, %{
      resolved_skills: [],
      standing_orders_digest: RunProvenance.standing_orders_digest(ws),
      routing_policy: routing_policy_for_role(role_atom, ws),
      model_tier: Keyword.get(agent_opts, :model_tier),
      thinking: Keyword.get(agent_opts, :thinking)
    })

    if role == :implementer do
      Worker.report(pid, :routing_config, %{
        provider: adapter.provider(),
        model: session_model || Keyword.get(agent_opts, :model),
        model_tier: Keyword.get(agent_opts, :model_tier),
        thinking: Keyword.get(agent_opts, :thinking)
      })
    end

    case adapter.default_argv(prompt, agent_opts) do
      {:ok, argv} ->
        env = safe_spawn_env(adapter, agent_opts)

        # bd-9rdwe4: `prompt:` alongside `command:` plays no role in argv
        # resolution — it's carried purely so `Arbiter.Worker` can persist
        # what this reviewer/implementer was actually told.
        {:ok,
         base ++
           [
             command: argv,
             prompt: prompt,
             env: env,
             provider: adapter.provider(),
             model: session_model
           ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # bd-3hb4ih / bd-1abj7u finding 1: a reviewer pass that the print-timeout
  # rotation has pinned to a specific provider uses THAT adapter, bypassing
  # the workspace's own first-choice resolution — which would hand back the
  # provider that just timed out. This pin can never itself be an ineligible
  # provider: `reviewer_provider` is only ever set from `next_reviewer_provider/2`,
  # which draws from `reviewer_pool/1`, and that pool is pre-filtered through
  # `Agents.strict_eligible_provider/4` before rotation ever sees it. Wrapped
  # in `{:ok, ...}` purely to match this function's other clauses, not because
  # this arm can fail. Every unpinned pass (`reviewer_provider: nil`, the
  # default and the only state a single-provider workspace ever reaches)
  # resolves exactly as before.
  defp adapter_for(%{reviewer_provider: provider}, _ws, :reviewer, _revision)
       when is_atom(provider) and not is_nil(provider),
       do: {:ok, {Agents.for_type(provider), :review_agent}}

  # bd-a1ke2c: a cross-family pass runs the adapter `ReviewerRouting` chose.
  # Its candidates are already filtered for `:strict` write confinement, and
  # its pre-routing fallback goes through `Agents.strict_eligible_provider/4`
  # exactly like the clause below.
  defp adapter_for(%{reviewer_selection: %{provider: provider}}, _ws, :reviewer, _revision)
       when is_atom(provider) and not is_nil(provider),
       do: {:ok, {Agents.for_type(provider), :review_agent}}

  # bd-1abj7u finding 3: mirror Dispatch's fail-closed write-confinement gate
  # (`Arbiter.Agents.strict_eligible_provider/4`) for automatic reviewer
  # selection. Unlike the worker dispatch path, the reviewer slot has no "the
  # caller explicitly named this provider" case here — resolution always
  # falls through the configured `review_agent`/`agent` pool — so on a
  # `:strict` scope where none of the workspace's configured reviewers can
  # confine writes, this refuses (the same fail-closed error Dispatch returns)
  # instead of silently substituting an unconfigured `:claude`.
  defp adapter_for(state, %Workspace{} = ws, :reviewer, _revision) do
    policy = session_security_policy(ws, state, :reviewer)
    configured = Agents.reviewer_type(ws)

    # bd-5ef587: a paused reviewer provider/account is dropped from the pool;
    # the pass re-routes to the next unpaused reviewer, or is refused with the
    # pause's hold phrase when none is left.
    pool = ws |> Agents.reviewer_pool() |> Enum.reject(&reviewer_paused?(&1, state))
    preferred = if configured in pool, do: configured, else: List.first(pool)

    if is_nil(preferred) do
      {:error, reviewer_paused_error(configured, state)}
    else
      case Agents.strict_eligible_provider(preferred, policy, pool) do
        {:ok, eligible} ->
          {:ok, {Agents.for_type(eligible), :review_agent}}

        {:error, :ineligible} ->
          {:error,
           Dispatch.strict_write_confinement_error(preferred, policy, ws, repo: state.repo)}
      end
    end
  end

  defp adapter_for(_state, nil, :reviewer, _revision),
    do: {:ok, {Agents.for_type(:claude), :review_agent}}

  # bd-1abj7u finding 2: the revision implementer spawn goes through this same
  # gate. `resolve_revision/2` already picked the provider (the task's
  # bd-40pzpj implementer pin under `most_quota`, else the original authoring
  # provider or `Agents.resolve_revision_provider/2`'s fallback) —
  # treated as an explicit pin, same as `arb dispatch --provider`, since there
  # is no pool to fall back into here (the implementer role isn't drawn from a
  # pool the way the reviewer role is).
  defp adapter_for(
         state,
         %Workspace{} = ws,
         :implementer,
         {provider, _fallback_reason, _decision}
       ) do
    policy = session_security_policy(ws, state, :implementer)

    case Agents.strict_eligible_provider(provider, policy, [], explicit: true) do
      {:ok, _eligible} ->
        {:ok, {Agents.for_type(provider), :agent}}

      {:error, :ineligible} ->
        {:error, Dispatch.strict_write_confinement_error(provider, policy, ws, repo: state.repo)}
    end
  end

  defp reviewer_paused?(type, state),
    do: Arbiter.Providers.Pause.blocking(type, state.workspace_id) != nil

  defp reviewer_paused_error(type, state) do
    case ProviderRouting.ensure_unpaused(type, state.workspace_id) do
      {:error, _} = error -> elem(error, 1)
      :ok -> {:provider_paused, type, "held — #{type} paused"}
    end
  end

  # bd-dzz6ly: the reviewer slot is configured directly (`review_agent.config`)
  # and never goes through `Arbiter.Agents.Routing` — record that plainly
  # rather than claiming a routing policy that didn't actually decide
  # anything. The implementer slot DOES route through `Routing.choose`
  # (`agent_opts_for_role/3` below), so its provenance reflects the
  # workspace's configured policy.
  defp routing_policy_for_role(:review_agent, _ws), do: "review_agent"
  defp routing_policy_for_role(:agent, ws), do: RunProvenance.routing_policy_string(ws)

  # The reviewer slot has its own config under `review_agent.config.*`
  # (falls back to the worker `agent` block so a workspace that names only
  # `agent` still spawns a reviewer). `model`/`thinking` are read directly
  # from the configured block; `model_tier` defaults to the task's own tier
  # bumped one step (bd-3xultf, `reviewer_model_tier/2`) unless the block
  # pins one explicitly.
  defp agent_opts_for_role(%Workspace{config: config}, :review_agent, task_id, _adapter) do
    block =
      get_in(config || %{}, ["review_agent", "config"]) ||
        get_in(config || %{}, ["agent", "config"]) || %{}

    [
      model: Map.get(block, "model"),
      model_tier: reviewer_model_tier(config, task_id),
      thinking: Map.get(block, "thinking"),
      config: block
    ]
  end

  # The implementer slot is a worker session on the same task — route it
  # through the configured policy (`:static` / `:by_priority` /
  # `:by_difficulty` / ...) so a revise round picks the same model the
  # initial dispatch would have, not a flat workspace default. Best-effort:
  # a missing task falls back to the workspace's `agent.config`.
  defp agent_opts_for_role(%Workspace{} = ws, :agent, task_id, adapter) do
    choice =
      case load_issue(task_id) do
        nil ->
          block = get_in(ws.config || %{}, ["agent", "config"]) || %{}
          %{type: Agents.agent_type(ws, :agent) || :claude, config: block}

        %Issue{} = task ->
          Routing.choose(task, ws)
      end

    provider_atom =
      Enum.find_value(Agents.adapters(), fn {type, mod} ->
        if mod == adapter, do: type
      end) || :claude

    choice = apply_agent_type_override(choice, provider_atom)
    config = choice.config || %{}

    [
      model: Map.get(config, "model"),
      model_tier: Map.get(config, "model_tier"),
      thinking: Map.get(config, "thinking"),
      config: config
    ]
  end

  # bd-a1ke2c: a cross-family reviewer runs its family's reviewer tier and
  # model (`ReviewerRouting`, `ModelFamily.reviewer_tier/2`) — the model is
  # passed explicitly so what spawns is exactly what the family was judged on.
  defp apply_reviewer_selection(opts, %{reviewer_selection: %{} = sel}, :reviewer) do
    Keyword.merge(opts,
      model: sel.model || Keyword.get(opts, :model),
      model_tier: sel.tier || Keyword.get(opts, :model_tier),
      thinking: sel.thinking || Keyword.get(opts, :thinking)
    )
  end

  defp apply_reviewer_selection(opts, _state, _role), do: opts

  defp apply_agent_type_override(%{type: type} = choice, type), do: choice

  defp apply_agent_type_override(choice, type) when is_atom(type) and not is_nil(type) do
    config = Map.drop(choice.config || %{}, ["model"])
    %{choice | type: type, config: config}
  end

  defp apply_agent_type_override(choice, _), do: choice

  defp resolved_model_for(adapter, agent_opts) do
    if function_exported?(adapter, :resolved_model, 1) do
      adapter.resolved_model(agent_opts)
    end
  end

  # bd-3xultf: resolve the reviewer's `model_tier`. An explicit
  # `review_agent.config.model_tier` (or `agent.config.model_tier` fallback)
  # always wins — a workspace that wants a hard-pinned reviewer keeps that
  # today. Otherwise the reviewer is routed one tier above the task's own
  # nominal tier (`ByDifficulty.tier_for_difficulty/1`), bumped by
  # `review_agent.config.tier_offset` (default 1, capped at "premium" by
  # `bump_tier/2`), so it's never weaker than the author. `tier_offset: 0`
  # restores a fixed (same-tier) reviewer — the rollback knob for #1011's
  # measurement-validity concern.
  defp reviewer_model_tier(config, task_id) do
    block =
      get_in(config || %{}, ["review_agent", "config"]) ||
        get_in(config || %{}, ["agent", "config"]) || %{}

    case Map.get(block, "model_tier") do
      tier when is_binary(tier) and tier != "" ->
        tier

      _ ->
        task_id
        |> difficulty_at_dispatch_for()
        |> ByDifficulty.tier_for_difficulty()
        |> ByDifficulty.bump_tier(reviewer_tier_offset(block))
    end
  end

  defp reviewer_tier_offset(block) do
    case Map.get(block, "tier_offset") do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_reviewer_tier_offset
    end
  end

  defp load_issue(task_id) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = task} -> task
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp load_issue(_), do: nil

  defp safe_spawn_env(adapter, agent_opts) do
    if function_exported?(adapter, :spawn_env, 1) do
      adapter.spawn_env(agent_opts)
    else
      []
    end
  end

  defp load_workspace(nil), do: nil

  defp load_workspace(ws_id) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Stop the current worker worker if it's still alive. Best-effort — used
  # before spawning the next worker so one that finished without printing `arb
  # done` (and so never self-completed) can't linger.
  defp stop_worker(state) do
    if is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid) do
      safe(fn -> Worker.stop(state.reviewer_pid, :normal) end)
    end

    :ok
  end

  # ---- synthetic worker ids ----------------------------------------------

  # The synthetic task id for a re-prompt reviewer: a fresh, distinct id per
  # attempt so it registers as its own worker / run row and never collides with
  # the original (possibly still-terminating) reviewer.
  defp reprompt_task_id(review_id, attempt), do: review_id <> "#v#{attempt + 1}"

  # The reviewer id for a later round (round >= 2): distinct per round.
  defp reviewer_round_id(review_id, round), do: review_id <> "#r#{round}"

  # The implementer id for a given round's revision: distinct per round.
  defp implementer_task_id(review_id, round), do: review_id <> "#impl#{round}"

  # The synthetic id for a reviewer pass respawned after a timeout: distinct per
  # attempt so it registers its own worker / run row and never collides with the
  # (now-stopped) hung pass. bd-78vg4v.
  defp timeout_retry_id(current_id, attempt), do: "#{current_id}#t#{attempt + 1}"

  # bd-3hb4ih: the synthetic id for a reviewer pass respawned against the NEXT
  # provider in the pool after a print-timeout. Keyed off the round's own review
  # id (not the pass that just died) so rotating twice in one round can't chain
  # an ever-growing id, and tagged with the provider so the run row says at a
  # glance which pool entry it was.
  defp provider_rotation_id(state, provider) do
    review_id =
      if state.round > 1 do
        reviewer_round_id(state.review_id, state.round)
      else
        state.review_id
      end

    "#{review_id}#p#{state.attempt + 1}-#{provider}"
  end

  # bd-2eyf9y: the id for the one-shot commit-gate resume of a round's
  # implementer — distinct from `implementer_task_id/2`'s original pass so it
  # registers its own worker / run row.
  defp commit_nudge_task_id(review_id, round),
    do: implementer_task_id(review_id, round) <> "-commit"

  # ---- misc ---------------------------------------------------------------

  defp round_subject(state, verdict), do: "Round #{state.round} findings (#{verdict})"

  # Public only so the UTF-8-boundary behaviour can be unit-tested directly
  # (mirrors parse_verdict/1); not part of the documented API.
  @doc false
  def cap(text, max) when is_binary(text) do
    if byte_size(text) > max do
      valid_prefix(binary_part(text, 0, max)) <> "\n… (truncated)"
    else
      text
    end
  end

  # binary_part/3 slices on a raw byte offset, which can sever a multibyte UTF-8
  # codepoint mid-sequence and yield an invalid-UTF-8 binary. Downstream String
  # ops (String.trim/1 in escalation_payload/1) and the Postgres UTF8 column both
  # choke on such bytes — and escalation diffs routinely carry em-dashes/arrows.
  # Shave at most 3 trailing bytes back to a valid codepoint boundary.
  defp valid_prefix(bin) when byte_size(bin) == 0, do: bin

  defp valid_prefix(bin) do
    if String.valid?(bin), do: bin, else: valid_prefix(binary_part(bin, 0, byte_size(bin) - 1))
  end

  # Cap a transcript to at most `max` bytes, preserving BOTH the head and the
  # tail and eliding the middle — unlike `cap/2`, which keeps only the prefix.
  # Used for the implementer transcript recorded into the thread (bd-78vg4v): its
  # actionable FIX/REBUT conclusions land at the END of the output, so a
  # prefix-only cap would discard exactly what the re-reviewer needs while
  # keeping the file-reading noise. Keeps ~1/3 head (opening context) + ~2/3 tail
  # (the conclusions). Public only so the head+tail behaviour can be unit-tested.
  @doc false
  def cap_transcript(text, max \\ @transcript_cap_bytes) when is_binary(text) and max > 0 do
    if byte_size(text) <= max do
      text
    else
      head_bytes = div(max, 3)
      tail_bytes = max - head_bytes
      head = text |> binary_part(0, head_bytes) |> valid_prefix()
      tail = text |> binary_part(byte_size(text) - tail_bytes, tail_bytes) |> valid_suffix()
      elided = byte_size(text) - byte_size(head) - byte_size(tail)

      head <>
        "\n\n… (#{elided} bytes of the implementer transcript elided to bound the " <>
        "re-review prompt — head and tail kept) …\n\n" <> tail
    end
  end

  # Mirror of valid_prefix/1 for a tail slice: shave LEADING bytes forward to a
  # valid UTF-8 boundary so a tail can't begin mid-codepoint (which would choke
  # String ops and the Postgres UTF8 column downstream).
  defp valid_suffix(bin) when byte_size(bin) == 0, do: bin

  defp valid_suffix(bin) do
    if String.valid?(bin), do: bin, else: valid_suffix(binary_part(bin, 1, byte_size(bin) - 1))
  end

  # Minimal snapshot for a ReviewGate probed as if it were a worker. The ReviewGate
  # is a review gate, not an worker; this exists only so an accidental
  # :snapshot call gets a sane reply rather than crashing it. See bd-2y0gd5.
  defp snapshot(state) do
    %{
      task_id: state.task_id,
      review_id: state.review_id,
      status: :reviewing,
      current_step: "review_gate",
      repo: state.repo,
      role: :review_gate,
      phase: state.phase,
      round: state.round,
      max_rounds: state.max_rounds,
      reviewer_alive: is_pid(state.reviewer_pid) and Process.alive?(state.reviewer_pid),
      # bd-cut6uv: the head a reviewer is being held back for, while it is.
      awaiting_ci: match?(%{wait: %{sha: _}}, state.ci_wait) && state.ci_wait.wait.sha,
      # bd-3hb4ih: the reviewer provider this round is pinned to (nil = the
      # workspace's own first choice) and the providers that have already timed
      # out in it, so a rotation in progress is visible without reading logs.
      reviewer_provider: state.reviewer_provider,
      reviewer_timed_out: Enum.map(state.reviewer_timeouts, & &1.provider)
    }
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  # ---- prompts ------------------------------------------------------------

  @doc """
  Build the reviewer's prompt: the task's acceptance criteria + description, the
  branch under review, the verdict protocol, and the hard no-boot constraint.
  Public so it can be inspected in tests.
  """
  @spec review_prompt(map()) :: String.t()
  def review_prompt(%{conflict_review: %{} = info} = state),
    do: conflict_review_prompt(state, info)

  def review_prompt(state) do
    task = load_task(state.task_id)

    """
    You are a REVIEWER worker — a ReviewGate. You did NOT write this code; a
    different worker did. Your job is to code-review its work before it merges.
    You must reach an independent verdict — do not rubber-stamp.

    Task under review: #{state.task_id}
    Title: #{task.title}

    Description:
    #{task.description}

    Acceptance criteria:
    #{task.acceptance}

    The work is on branch `#{state.branch}`, cut from `#{state.target_branch}`.
    #{head_sha_instruction(state)}#{review_checkout_block(state)}
    #{scope_guidance(state)}
    Judge the change against the acceptance criteria AND for correctness,
    regressions, and obvious defects.

    NOTE (bd-ofql8k): if the diff above looks empty, also run `git status` BEFORE
    concluding "no code exists". An empty diff plus a non-empty `git status` means
    the implementer edited files but forgot to commit — the work is in the
    worktree, just not in history. In that case REQUEST_CHANGES with a finding
    that names the uncommitted files and asks for a commit, rather than reporting
    "no work."

    *** ABSOLUTE RULE: DO NOT boot the app. No `mix phx.server`, no `iex -S mix`,
    no `mix run`. Running a second app instance is hazardous. You review the diff
    by reading it — you do not run the application. (Reading files and running
    `git` is fine.)

    #{async_tool_block(state)}

    #{ci_prompt_block(state)}NOTE: If you run tests or any build command, wrap it with a hard timeout so
    a cold compilation pass cannot exhaust the reviewer session — e.g.
    `timeout 120 mix test`. If the command times out or fails to compile, issue
    your VERDICT based on the diff alone and note that live test verification
    was unavailable — do not wait indefinitely for output that will not arrive.

    #{EvidenceIntegrity.reviewer_block()}
    #{ReviewVerification.anti_stale_reflag_block()}
    When you have decided, print your verdict on its own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    #{criteria_prompt_block(task)}If you REQUEST_CHANGES you MUST follow the verdict with an ENUMERATED list of
    concrete findings — each with a severity, a `file:line` location, and a
    suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid and
    will be rejected: the implementer would have nothing to act on. Output only
    structured review content — no roleplay persona, character, or theatrical
    flourish.

    #{ReviewVerification.disclosure_block()}
    Then print, on a line by itself:

        arb done
    """
  end

  # Emit the per-criterion CRITERIA breakdown instruction only when the task has
  # stated acceptance criteria (Option B, bd-4yhv4x): tasks with no criteria (the
  # bulk of existing work) keep the leaner prompt and merge unchanged, while a
  # task that DOES state criteria forces the reviewer to address each one as
  # verdict payload — which is what the unmet-criteria guard reads back. The
  # trailing newline keeps the surrounding prompt spacing intact when empty.
  defp criteria_prompt_block(task) do
    if acceptance_present?(task.acceptance) do
      ReviewVerification.criteria_block() <>
        "\n" <> CoordinatorOnlyFindings.coordinator_only_block() <> "\n"
    else
      ""
    end
  end

  @doc """
  Build the verdict re-prompt used when a prior pass produced a malformed result:
  a missing sentinel (`:no_verdict`) or a REQUEST_CHANGES with no findings
  (`:empty_findings`). Since there is no live Claude session resume yet, the
  follow-up pass is a fresh reviewer mind with no memory of the prior pass — so it
  re-supplies the full review context, prefixed with an instruction naming exactly
  what went wrong so it isn't repeated. Public for inspection in tests.
  """
  @spec verdict_reprompt_prompt(
          map(),
          :no_verdict
          | :empty_findings
          | :unverified
          | :unmet_criteria
          | :missing_criteria
          | :unaddressed_findings
        ) :: String.t()
  def verdict_reprompt_prompt(state, reason \\ :no_verdict)

  def verdict_reprompt_prompt(state, :unaddressed_findings) do
    """
    A prior review pass of this diff returned `VERDICT: APPROVE`, but it never
    established that the findings already open against this work were actually
    addressed — it left at least one Medium-or-higher finding with no
    disposition, marked one `[NOT ADDRESSED]`, or claimed one was `[ADDRESSED]`
    while no revision touched any file it cited.

    That is the failure this gate exists to catch, and it is the reason a
    `VERIFICATION: FULL` line is not taken on trust: approving a revision round
    without re-checking the round's own prior finding has merged real defects
    behind a green verdict. An approval is a claim about every open finding, not
    an impression of how the diff reads.

    Re-review the CURRENT diff from scratch and this time:

      * Account for EVERY open finding id listed below, one per line, in a
        `DISPOSITIONS:` block right after your `VERDICT:` line.
      * `[ADDRESSED]` requires that you re-opened the CURRENT file and saw the
        problem gone — and that you name the `file:line` where the fix landed.
        The implementer saying "FIXED" is not evidence; a file the revision never
        touched cannot contain the fix.
      * `[NOT ADDRESSED]` is the honest answer when the finding still stands. Use
        it — and do not pair it with APPROVE, which will be rejected again.
      * `[OBSOLETE]` is available when a different change genuinely invalidated
        the finding (the code it cited is gone, or the concern can no longer
        arise). Say why.

    """ <> rereview_prompt(state)
  end

  def verdict_reprompt_prompt(state, :missing_criteria) do
    """
    A prior review pass of this diff returned `VERDICT: APPROVE`, but it did NOT
    include a CRITERIA breakdown at all — it produced a holistic judgement of the
    code without accounting for a single one of the task's stated acceptance
    criteria. That is exactly the failure this gate exists to catch: approving
    work because the diff looks reasonable, not because it delivers what was
    asked. An APPROVE on a task that HAS acceptance criteria is not honored
    unless every criterion is addressed individually.

    Re-review the CURRENT diff against the acceptance criteria from scratch and
    this time:

      * Address EACH acceptance criterion on its own `CRITERIA:` line, using
        exactly one of `[MET]`, `[NOT MET]`, `[N/A]` — this is the verdict
        payload, not a formality. Omitting the breakdown will get this approval
        rejected again.
      * "Met" means the criterion is actually SATISFIED by the diff you can see
        RIGHT NOW, traced to the real behaviour that delivers it — NOT that a
        test is green (a test can assert against a test-local helper or stub, or
        exercise an inert feature) and NOT that the code merely looks clean. If
        the implementer declared a limitation, deferral, or "out of scope" that
        touches a criterion, that criterion is `[NOT MET]`.
      * Only finish with `VERDICT: APPROVE` if EVERY criterion is `[MET]` or
        `[N/A]`. If any criterion is genuinely `[NOT MET]`, finish with
        `VERDICT: REQUEST_CHANGES` followed by an ENUMERATED list of concrete
        findings — each with a severity, a `file:line` location, and a suggested
        fix — so the implementer can close the gap.

    """ <> review_prompt(state)
  end

  def verdict_reprompt_prompt(state, :unmet_criteria) do
    """
    A prior review pass of this diff returned `VERDICT: APPROVE`, but its own
    CRITERIA breakdown marked one or more stated acceptance criteria `[NOT MET]`.
    An APPROVE that admits an unmet criterion is a contradiction — "the code
    looks fine" is not "the task is done". This is exactly the failure this gate
    exists to catch: shipping work that does not satisfy the task as stated.

    Re-review the CURRENT diff against the acceptance criteria from scratch and
    this time:

      * Address EACH acceptance criterion on its own `CRITERIA:` line, using
        exactly one of `[MET]`, `[NOT MET]`, `[N/A]` — this is the verdict
        payload, not a formality.
      * "Met" means the criterion is actually SATISFIED by the diff you can see
        RIGHT NOW, traced to the real behaviour that delivers it — NOT that a
        test is green (a test can assert against a test-local helper or stub, or
        exercise an inert feature) and NOT that the code merely looks clean. If
        the implementer declared a limitation, deferral, or "out of scope" that
        touches a criterion, that criterion is `[NOT MET]`.
      * Only finish with `VERDICT: APPROVE` if EVERY criterion is `[MET]` or
        `[N/A]`. If any criterion is genuinely `[NOT MET]`, finish with
        `VERDICT: REQUEST_CHANGES` followed by an ENUMERATED list of concrete
        findings — each with a severity, a `file:line` location, and a suggested
        fix — so the implementer can close the gap. An APPROVE whose breakdown
        still contains a `[NOT MET]` line will not be accepted.

    """ <> review_prompt(state)
  end

  def verdict_reprompt_prompt(state, :unverified) do
    """
    A prior review pass of this diff returned `VERDICT: REQUEST_CHANGES` but
    disclosed `VERIFICATION: PARTIAL` — it gave up on verification (e.g.
    abandoned waiting on a test run) before finalizing, so its findings may
    restate stale observations rather than problems confirmed in the CURRENT
    diff. This is a common, costly failure: findings drafted early get flushed
    unchanged once a wait is abandoned, including findings from an EARLIER
    review round that the code has since fixed.

    This time:

      * Either wait for any verification you start to actually finish, or use a
        bounded `timeout N ...` wrapper and read its real output — do not draft
        findings while a check is still pending and finalize them regardless of
        whether it completes.
      * For EACH finding you are about to make, re-open the CURRENT file at the
        cited line and confirm the problem is still present in THIS diff RIGHT
        NOW. Do not carry forward a finding from a prior round's text (or from
        memory) without this fresh check — if the code has already been fixed,
        DROP that finding; re-flagging already-fixed code is invalid.
      * Finish with `VERDICT: APPROVE` or `VERDICT: REQUEST_CHANGES` followed by
        the enumerated findings, then end with `VERIFICATION: FULL` once you
        have done this. Only write `VERIFICATION: PARTIAL` again if you are
        honestly still unable to complete verification — and if so, say exactly
        what could not be confirmed.

    """ <> review_prompt(state)
  end

  def verdict_reprompt_prompt(state, :empty_findings) do
    """
    A prior review pass of this diff returned `VERDICT: REQUEST_CHANGES` but listed
    NO concrete findings — only a verdict (or a content-free flourish). That is
    useless: the implementer has nothing to act on. Review the diff again and:

      * if the change is acceptable, finish with `VERDICT: APPROVE`; or
      * if it genuinely needs changes, finish with `VERDICT: REQUEST_CHANGES`
        followed by an ENUMERATED list of findings — each with a severity, a
        `file:line` location, and a concrete suggested fix.

    A REQUEST_CHANGES with no enumerated findings will be rejected again. Do not
    include any roleplay or persona text — structured findings only.

    """ <> review_prompt(state)
  end

  def verdict_reprompt_prompt(state, _no_verdict) do
    """
    A prior review pass of this diff finished WITHOUT emitting the required
    verdict line, so its conclusion was lost. Review the diff again and this time
    you MUST finish with EXACTLY one line, one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    Do not skip the verdict line — without it your review cannot be honored.

    """ <> review_prompt(state)
  end

  @doc """
  Build the implementer's revise prompt for a round of the revise-and-rediscuss
  loop: the reviewer's findings, and the instruction to address EACH one (fix or
  rebut) on the same branch, committing any code changes so the next review can
  see them.

  Stage 3 (bd-1na62i) prepends a git-derived "work so far" briefing
  (`ResumeContext.work_so_far/2`) so this fresh implementer mind continues the
  prior round's thread with full context — the same provider-agnostic
  continuity the `arb resume` path uses — instead of re-deriving what was done
  from a raw diff. Combined with the reviewer findings and the task directive
  below, that approximates the original implementer resuming its own session.
  Public for inspection in tests.
  """
  @spec revise_prompt(map(), String.t()) :: String.t()
  def revise_prompt(state, findings) do
    task = load_task(state.task_id)

    adapter =
      state
      |> Map.get(:workspace_id)
      |> load_workspace()
      |> Arbiter.Agents.for_workspace()

    """
    You are an IMPLEMENTER worker. A reviewer (a ReviewGate) has reviewed the work
    on branch `#{state.branch}` and REQUESTED CHANGES. Your job is to address each
    finding so the work can pass review.

    Task: #{state.task_id}
    Title: #{task.title}

    Description:
    #{task.description}

    Acceptance criteria:
    #{task.acceptance}
    #{work_so_far_briefing(state)}
    Reviewer findings (round #{state.round}):
    #{clean_findings(findings)}

    For EACH finding, do ONE of:
      * FIX it — edit the code on branch `#{state.branch}` and COMMIT the change
        (`git add -A && git commit -m "..."`), so the reviewer can see it in the
        diff on re-review; or
      * REBUT it — if you believe the finding is mistaken, leave the code as-is
        and explain, concretely, why it is not a problem; or
      * RESOLVE IT WITHOUT A FILE CHANGE — some findings are legitimately fixed
        through something other than an edit to this branch (a PR title or
        description via `gh pr edit`, a label, a comment reply). If that is
        genuinely how you addressed a finding, say so and include, on its own
        line, `NO-FILE-CHANGE: <finding> — <exactly what you changed and how>`.
        Do not use this for anything you actually edited a file for, and do not
        use it as a way to avoid a fix a finding actually calls for — the next
        review round re-checks the live PR for real, so a false claim here will
        be caught, not accepted.

    State clearly, for each finding, whether you FIXED, REBUTTED, or resolved it
    without a file change, and why — your reply here is forwarded back to the
    reviewer as your side of the record.

    #{EvidenceIntegrity.worker_block()}
    The work is on branch `#{state.branch}`, cut from `#{state.target_branch}`:

        git diff #{state.target_branch}...HEAD
        git log --oneline #{state.target_branch}..HEAD

    *** ABSOLUTE RULE: DO NOT boot the app. No `mix phx.server`, no `iex -S mix`,
    no `mix run`. (Reading files, editing, and running `git` is fine.)

    #{PromptBuilder.async_tools_section(adapter, "`arb done`", nil)}

    When you have addressed every finding, print, on a line by itself:

        arb done
    """
  end

  # Stage 3 (bd-1na62i): the same-mind-continuity briefing prepended to a
  # revise-round implementer. Each revision is a FRESH mind (literal Claude/Gemini
  # session resume was dropped — provider-specific and fragile across billing
  # pauses/crashes), so we hand it the git-derived picture of what the prior
  # round(s) actually did — commits since the branch cut + any uncommitted work —
  # exactly as the `arb resume` path (bd-auma3z) briefs a resumed worker. Skipped
  # (empty string) for a worktree-less ReviewGate: an ad-hoc / test run with nothing
  # on disk to summarize falls back to today's directive-only prompt.
  defp work_so_far_briefing(%{worktree_path: wt, target_branch: tb})
       when is_binary(wt) and is_binary(tb) do
    """

    Work done so far on this branch by the prior round(s) — continue from here,
    do NOT restart; build on what is already committed:

    #{ResumeContext.work_so_far(wt, tb)}

    This briefing is authoritative for what happened in prior rounds: trust it
    and act on the reviewer findings below directly, rather than re-reading
    files just to re-establish context it already gives you. Do not re-read a
    file, or narrate "let me check the current code," solely to confirm
    something already summarized above — that re-derives what you've already
    been told and wastes a round trip. Do read files for context genuinely
    outside this briefing: code the summary doesn't mention, or anything you
    need to see in full before editing it.
    """
  end

  defp work_so_far_briefing(_state), do: ""

  # What the reviewer is told to read: the delta since the covered commit when
  # this gate is scoped to one (P7), otherwise the whole branch — through the
  # PR when one is open (bd-129xh4), and against the merge-base (bd-ased52).
  defp scope_guidance(%{delta_base_sha: covered} = state) when is_binary(covered),
    do: delta_guidance(state, covered)

  defp scope_guidance(state), do: pr_review_block(state) <> diff_guidance(state)

  # ---- conflict-resolution review (bd-954ym8 / #134) ------------------------
  #
  # Main moving under an approved PR forces a rebase or a merge, and that head
  # used to cost a whole review round although nothing the reviewer judged had
  # changed. `Arbiter.Reviews.ConflictResolution` says what the head adds over
  # the approved commit once the target's own changes are accounted for, and
  # the gate acts on the three answers *before* a reviewer is paid for:
  #
  #   * clean       — the head IS the mechanical integration. Cover it with a
  #                   `:mechanical` coverage row and the reviewed-SHA stamp
  #                   (the same two writes an APPROVE makes) and report the
  #                   approval with no round at all.
  #   * resolution  — only collided regions were hand-resolved. Review just
  #                   those: a `:conflict_review` round at the standard tier
  #                   with a short timeout, shown the regions and nothing else.
  #   * otherwise   — authored content (or git could not say): the ordinary
  #                   review, exactly as before. Every doubt lands here.
  #
  # Skipped — silently, the ordinary review — whenever there is nothing to
  # classify against: no worktree on the task branch, no covered head for the
  # PR (a first review), or the head is already covered.
  @conflict_review_tier "standard"
  @conflict_review_timeout_ms 5 * 60 * 1000

  defp conflict_path(state) do
    with true <- conflict_review_enabled?(state),
         wt when is_binary(wt) <- Map.get(state, :worktree_path),
         true <- worktree_on_expected_branch?(state),
         [_ | _] = covered <- Coverage.covered_heads(coverage_mr_ref(state)),
         {:ok, head} <- reviewed_head(state),
         false <- head in covered do
      target = conflict_target_ref(wt, state.target_branch)

      case ConflictResolution.classify(wt, covered, head, target) do
        {:clean, info} -> cover_clean_integration(state, info)
        {:resolution, info} -> start_conflict_review(state, info)
        {_authored_or_unknown, reason} -> conflict_fallback(state, head, reason)
      end
    else
      _ -> {:full, state}
    end
  rescue
    e ->
      Logger.warning(
        "ReviewGate: conflict classification crashed for task=#{state.task_id} " <>
          "(reviewing in full): #{Exception.message(e)}"
      )

      {:full, state}
  end

  # On by default; `review_gate.conflict_review: false` returns a workspace to
  # a full review of every head that follows an approval.
  defp conflict_review_enabled?(state) do
    case load_workspace(state.workspace_id) do
      %Workspace{config: config} ->
        get_in(config || %{}, ["review_gate", "conflict_review"]) != false

      _ ->
        true
    end
  end

  # The gate merges `origin/<target>` into the branch before it gets here
  # (`prepare_branch_for_review/1`), so that is the tip the head integrates.
  defp conflict_target_ref(wt, target) do
    remote = "origin/" <> target

    case git_out(wt, ["rev-parse", "--verify", "--quiet", remote]) do
      {:ok, _} -> remote
      :error -> target
    end
  end

  defp conflict_review_attrs(state, head) do
    %{
      task_id: state.task_id,
      workspace_id: state.workspace_id,
      mr_ref: coverage_mr_ref(state),
      head: head,
      site: "review_gate"
    }
  end

  defp conflict_fallback(state, head, reason) do
    label = ConflictResolution.reason_label(reason)

    Logger.info(
      "ReviewGate: task=#{state.task_id} head #{head} carries content beyond integrating " <>
        "`#{state.target_branch}` into the approved commit (#{label}); reviewing in full"
    )

    ConflictReview.record("fallback", Map.put(conflict_review_attrs(state, head), :reason, label))
    {:full, state}
  end

  defp start_conflict_review(state, info) do
    regions = info.files |> Enum.map(&length(&1.regions)) |> Enum.sum()

    Logger.info(
      "ReviewGate: task=#{state.task_id} head #{info.head} is the approved commit " <>
        "#{info.approved} plus `#{state.target_branch}` with #{regions} hand-resolved conflict " <>
        "region(s) in #{length(info.files)} file(s); running a scoped conflict review"
    )

    ConflictReview.record(
      "scoped_review",
      state
      |> conflict_review_attrs(info.head)
      |> Map.merge(%{approved: info.approved, files: Enum.map(info.files, & &1.path)})
    )

    {:scoped, %{state | conflict_review: info}}
  end

  defp cover_clean_integration(state, info) do
    case record_mechanical_coverage(state, info) do
      :ok ->
        stamp_reviewed_head(state)

        reason =
          "head #{info.head} is exactly the approved commit #{info.approved} with " <>
            "`#{state.target_branch}` integrated (no conflicted region, no other change): " <>
            "covered by that approval, no review round"

        Logger.info("ReviewGate: task=#{state.task_id} auto-covered — #{reason}")

        ConflictReview.record(
          "auto_cover",
          state
          |> conflict_review_attrs(info.head)
          |> Map.merge(%{approved: info.approved, reason: reason})
        )

        {:covered, finish(state, {:approve, "VERDICT: APPROVE\n#{reason}"})}

      {:error, why} ->
        conflict_fallback(state, info.head, {:coverage_unrecordable, why})
    end
  end

  # The `:mechanical` row derived from the approval's own row. Every way this
  # can fail answers `{:error, _}` and the head is reviewed in full: a cover
  # that could not be recorded would leave the merge guard refusing a head the
  # gate had just told the author was approved.
  defp record_mechanical_coverage(state, info) do
    mr_ref = coverage_mr_ref(state)

    with {:ok, task_id} <- present(Map.get(state, :task_id), :no_task_id),
         {:ok, mr_ref} <- present(mr_ref, :no_mr_ref),
         {:ok, base_ref} <- present(Map.get(state, :target_branch), :no_base_ref),
         {:ok, head} <- reviewed_head(state),
         true <- head == info.head or {:error, :head_moved},
         {:ok, net_diff_id} <- coverage_net_diff_id(state),
         %{id: parent} <-
           Enum.find(Coverage.for_mr(mr_ref), &(&1.head_sha == info.approved)) ||
             {:error, :no_approved_row},
         {:ok, _entry} <-
           coverage_writer().(%{
             task_id: task_id,
             mr_ref: mr_ref,
             head_sha: head,
             base_ref: base_ref,
             net_diff_id: net_diff_id,
             kind: :mechanical,
             source: :review_gate,
             derived_from: parent
           }) do
      :ok
    else
      {:error, why} -> {:error, why}
      other -> {:error, other}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp conflict_round?(state), do: is_map(Map.get(state, :conflict_review))

  # A conflict round's rows carry their own role so the rounds list and cost
  # reports can tell the cheap pass from a full review. Only reviewer rows move;
  # the implementer's revise passes stay `:impl`.
  defp row_role(state, :review),
    do: if(conflict_round?(state), do: :conflict_review, else: :review)

  defp row_role(_state, role), do: role

  defp note_conflict_round_outcome(state, :review, verdict)
       when verdict in [:approve, :request_changes] do
    if conflict_round?(state) do
      outcome = if verdict == :approve, do: "scoped_approved", else: "scoped_rejected"
      ConflictReview.record(outcome, conflict_review_attrs(state, state.conflict_review.head))
    end

    :ok
  end

  defp note_conflict_round_outcome(_state, _role, _verdict), do: :ok

  defp round_reviewer_tier(state, config) do
    if conflict_round?(state),
      do: @conflict_review_tier,
      else: reviewer_model_tier(config, state.task_id)
  end

  # The short budget applies to the reviewer's passes of a conflict round only,
  # never the revise implementer's, and never over an explicit override.
  defp round_timeout_ms(ms, %{timeout_override_ms: nil} = state, :reviewer) do
    if conflict_round?(state), do: min(ms, @conflict_review_timeout_ms), else: ms
  end

  defp round_timeout_ms(ms, _state, _role), do: ms

  defp apply_conflict_tier(opts, state, :reviewer) do
    if conflict_round?(state),
      do: Keyword.put(opts, :model_tier, @conflict_review_tier),
      else: opts
  end

  defp apply_conflict_tier(opts, _state, _role), do: opts

  defp conflict_review_prompt(state, info) do
    task = load_task(state.task_id)

    """
    You are a REVIEWER worker — a ReviewGate running a SCOPED CONFLICT-RESOLUTION
    REVIEW. You did NOT write this code and you did NOT resolve these conflicts.

    Task: #{state.task_id}
    Title: #{task.title}

    Branch `#{state.branch}` was reviewed and APPROVED at commit `#{info.approved}`.
    Since then `#{state.target_branch}` moved, and integrating it collided with the
    approved change in the regions below. Someone resolved those collisions by hand;
    the result is head `#{info.head}`.

    Everything OUTSIDE these regions has been machine-verified: it is exactly the
    approved change plus `#{state.target_branch}`'s own commits, byte for byte. Do
    NOT review it, and do NOT raise findings about code outside the regions below.
    #{head_sha_instruction(state)}#{review_checkout_block(state)}
    The conflicted regions — the TARGET side, the BRANCH side (the approved change)
    and the RESOLUTION chosen — are:

    #{ConflictResolution.render(info)}
    Judge ONLY whether each RESOLUTION preserves the intent of BOTH sides, or breaks
    something: does it drop a change either side made, apply one twice, keep a
    name/signature/call the other side removed or renamed, or leave code that no
    longer compiles or type-checks? You may read the surrounding code in your
    checkout (`git show #{info.head}:<path>`) to judge, and the approved change with
    `git diff #{info.base_old}..#{info.approved}`.

    *** ABSOLUTE RULE: DO NOT boot the app. No `mix phx.server`, no `iex -S mix`,
    no `mix run`. (Reading files and running `git` is fine.)

    #{async_tool_block(state)}

    #{ci_prompt_block(state)}#{EvidenceIntegrity.reviewer_block()}
    When you have decided, print your verdict on its own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    APPROVE means every resolution preserves both sides' intent. If you
    REQUEST_CHANGES you MUST follow the verdict with an ENUMERATED list of concrete
    findings — each with a severity, a `file:line` location, and a suggested fix. No
    CRITERIA breakdown is needed for this scoped review. Output only structured
    review content — no roleplay persona, character, or theatrical flourish.

    Then print, on a line by itself:

        arb done
    """
  end

  # ---- P7: delta-scoped re-review (bd-60r6wp / #1738, §4.5) ----------------
  #
  # A head that DESCENDS from a commit the PR already has coverage for — the
  # approved commit, then a CI fix pass's credo/dialyzer/test commit on top —
  # was reviewed up to that commit. What no review has seen is the delta, so
  # that is what this round reviews: the same new-diff-only compare ReviewPatrol
  # re-reviews use, and a small round rather than a full re-review. §4.5 is
  # explicit that the round is the right cost to pay: the alternative is fleet-
  # authored content merging unreviewed (#1702, #1723, #1725).
  #
  # Scoped only when it is provably a delta, and every doubt resolves to the
  # whole-branch review this gate always did (more review, never less):
  #
  #   * no coverage on the PR — a first review, or a fix round before any
  #     approval (only an APPROVE writes coverage);
  #   * the head is itself covered — nothing new to scope to;
  #   * no covered commit is an ancestor of the head — a conflict resolver's
  #     rebase rewrote history, so there is no commit range that is "the
  #     delta", and a two-dot diff across it would show the target's changes;
  #   * the range holds no commit of the branch's own (only merges from the
  #     target, which carry no authored content — the Watchdog merges those on
  #     a `:mechanical` row and never routes them here).
  defp with_delta_scope(%{worktree_path: wt} = state) when is_binary(wt) do
    case delta_base(state, wt) do
      covered when is_binary(covered) ->
        Logger.info(
          "ReviewGate: task=#{state.task_id} head descends from covered commit " <>
            "#{covered}; scoping this review to the delta #{covered}..HEAD"
        )

        %{state | delta_base_sha: covered}

      nil ->
        state
    end
  end

  defp with_delta_scope(state), do: state

  defp delta_base(state, wt) do
    with [_ | _] = covered <- Coverage.covered_heads(coverage_mr_ref(state)),
         {:ok, head} <- git_out(wt, ["rev-parse", "HEAD"]),
         false <- head in covered,
         base when is_binary(base) <- Enum.find(covered, &ancestor?(wt, &1, "HEAD")),
         [_ | _] <- delta_commits(wt, base) do
      base
    else
      _ -> nil
    end
  end

  # The branch's own commits since `covered`: `--first-parent` keeps the
  # target's commits that a merge brought in (the gate's own
  # `update_from_target/2`, or an update-branch) out of the list, and
  # `--no-merges` drops those merge commits themselves.
  defp delta_commits(wt, covered) do
    case git_out(wt, [
           "log",
           "--first-parent",
           "--no-merges",
           "--format=%h %s",
           delta_range(covered)
         ]) do
      {:ok, out} -> String.split(out, "\n", trim: true)
      :error -> []
    end
  end

  defp delta_patch(wt, covered) do
    case git_out(wt, [
           "log",
           "--first-parent",
           "--no-merges",
           "-p",
           "--format=commit %h %s",
           delta_range(covered)
         ]) do
      {:ok, patch} -> patch
      :error -> ""
    end
  end

  defp delta_range(covered), do: "#{covered}..HEAD"

  # Larger than any lint/dialyzer/test fix; a delta past it is listed but not
  # inlined, and the reviewer reads it with the command instead.
  @delta_inline_limit 60_000

  defp delta_guidance(state, covered) do
    wt = Map.get(state, :worktree_path)
    commits = if is_binary(wt), do: delta_commits(wt, covered), else: []
    patch = if is_binary(wt), do: delta_patch(wt, covered), else: ""

    commit_list =
      case commits do
        [] -> "    (could not list them — use the command below)"
        list -> Enum.map_join(list, "\n", &("    " <> &1))
      end

    """
    SCOPE — DELTA REVIEW. This branch was already reviewed and APPROVED at commit
    `#{covered}`, and that approval is on record. After it, the branch advanced
    with new commits — typically a CI fix pass (a credo, dialyzer or test fix) or
    another change made after the approval. No review has seen those commits yet,
    and they are the ONLY thing under review here. Do not re-review the work up to
    `#{covered}` and do not raise findings against it unless the new commits
    break it.

    The commits under review (this branch's own since `#{covered}`; merges from
    `#{state.target_branch}` excluded):

    #{commit_list}

    Read them with:

        git log --first-parent --no-merges -p #{delta_range(covered)}

    #{inline_delta(patch)}
    Judge whether the delta is correct, whether it regresses or undermines the
    approved work, and whether it is only what it claims to be — a lint or type
    fix that changes behaviour is a finding. For any CRITERIA breakdown, a
    criterion these commits do not touch stands as approved at `#{covered}`: mark
    it [MET] unless the delta breaks it.
    """
  end

  defp inline_delta(""), do: ""

  defp inline_delta(patch) when byte_size(patch) > @delta_inline_limit do
    "(The delta is #{byte_size(patch)} bytes — too large to inline; read it with the command above.)\n"
  end

  defp inline_delta(patch) do
    """
    The delta, as of this review's dispatch:

    ```diff
    #{patch}
    ```
    """
  end

  # bd-ased52: tell the reviewer to diff against the merge-base (the fork point),
  # NOT the moving target tip. When `base_sha` is known (the normal path, after
  # the branch is brought current), the prompt names the exact commit so the
  # reviewer cannot accidentally run `git diff <target>..HEAD` (two-dot) — which,
  # if the target advanced during the run, shows the target's unrelated commits
  # as if THIS branch made them and produces phantom out-of-scope findings.
  # Without a worktree (`base_sha` nil) it falls back to the three-dot form,
  # which also reaches the merge-base.
  defp diff_guidance(%{base_sha: base, target_branch: target}) when is_binary(base) do
    """
    This branch may have been cut from an OLDER `#{target}` than the current tip,
    and `#{target}` can advance DURING the run. Review ONLY this branch's own
    changes by diffing against the merge-base (the fork point) — commit `#{base}` —
    NOT the moving `#{target}` tip:

        git diff #{base}..HEAD
        git log --oneline #{base}..HEAD

    Do NOT use `git diff #{target}..HEAD` (two-dot against the tip): if `#{target}`
    advanced after this branch was cut, that command shows the target's unrelated
    commits as if THIS branch made them — phantom "out-of-scope" / "empty branch"
    findings against code the implementer never wrote. (`git diff #{target}...HEAD`,
    three-dot, reaches the same merge-base and is also safe.)
    """
  end

  defp diff_guidance(%{target_branch: target}) do
    """
    Review ONLY the diff. Diff against the merge-base so commits that landed on
    `#{target}` after this branch was cut are not mis-attributed to the branch:

        git diff #{target}...HEAD
        git log --oneline #{target}..HEAD

    Use the three-dot form (`#{target}...HEAD`); avoid two-dot `#{target}..HEAD`
    for the diff — if the target advanced during the run it shows unrelated
    `#{target}` commits as this branch's work.
    """
  end

  # bd-1mksks: embed the verified HEAD SHA into the review prompt so the
  # reviewer can confirm it is on the correct commit before running `git diff`.
  # When no SHA is available (no worktree, or git failed at spawn time), the
  # instruction is omitted — the review proceeds without the explicit anchor.
  defp head_sha_instruction(%{head_sha: sha, branch: branch, target_branch: target})
       when is_binary(sha) do
    """
    The ReviewGate verified before dispatching this review that branch `#{branch}`
    has commits ahead of `#{target}`. The implementer's HEAD at dispatch time was
    commit `#{sha}`. Before running `git diff`, confirm you are on the correct
    commit:

        git log --oneline -1
        # Expected: #{sha} <commit message>

    If `git log --oneline -1` shows a different commit than `#{sha}`, stop and
    report REQUEST_CHANGES noting the HEAD mismatch — do not review the wrong diff.

    """
  end

  defp head_sha_instruction(_state), do: ""

  # bd-a22hib: tell the reviewer where it is standing. Without this, a detached
  # HEAD (`git branch --show-current` prints nothing) and denied Edit/Write read
  # like a broken environment rather than the intended posture.
  defp review_checkout_block(%{review_checkout: %{path: path, head_sha: sha}} = state) do
    """
    You are working in a DETACHED, READ-ONLY checkout made for this review round
    only: `#{path}`, at commit `#{sha}` — the head of `origin/#{state.branch}` as
    it stood after the ReviewGate pushed it. It is not the implementer's
    worktree. Edit/Write are denied here; do not commit or push from it. You may
    run tests in it (same timeout rule as below). It is deleted when this round
    ends.

    """
  end

  defp review_checkout_block(_state), do: ""

  # bd-129xh4: when the author opened the PR before the gate ran, point the
  # reviewer at the real PR so it can `gh pr diff <n>` / record an inline review
  # with `gh pr review <n>` instead of only diffing the local branch. Emits
  # nothing when no PR was opened (no hosted merger configured) — the reviewer
  # then falls back to the `git diff` instructions that follow.
  defp pr_review_block(state) do
    case pr_number(Map.get(state, :pr_ref)) do
      nil ->
        ""

      number ->
        """
        A GitHub pull request is already open for this branch: PR ##{number}. Prefer
        reviewing it through the PR so your verdict lands against the real diff:

            gh pr diff #{number}
            gh pr view #{number}

        You may leave inline review comments with `gh pr review #{number}`. The local
        `git diff` below is equivalent if `gh` is unavailable.

        """
    end
  end

  # Extract the numeric PR/MR id from a merger ref. Handles both the bare
  # ("#42") and embedded ("owner/repo#42") forms; returns nil for anything
  # without a trailing number.
  defp pr_number(ref) when is_binary(ref) do
    case ref |> String.split("#") |> List.last() do
      n when is_binary(n) ->
        case Integer.parse(n) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp pr_number(_), do: nil

  @doc """
  Build the reviewer's re-review prompt for round >= 2: the base review prompt,
  prefixed with the prior implementer↔reviewer thread so the reviewer can accept
  each fix/rebuttal or hold the line on the UPDATED diff. Public for inspection.
  """
  @spec rereview_prompt(map()) :: String.t()
  def rereview_prompt(state) do
    """
    This is review round #{state.round} of a revise-and-rediscuss loop.
    #{why_rereviewing(state)}
    For each prior finding, decide whether to ACCEPT the fix/rebuttal or HOLD THE
    LINE, then issue a fresh verdict on the current state of the branch.

    *** For EACH prior finding you are tempted to HOLD THE LINE on, re-open the
    CURRENT file at the cited location first — do not hold the line from memory
    of the prior round's text. If the implementer's diff already addresses it,
    ACCEPT it and say so; restating a prior finding verbatim against code that
    has since changed is a false re-flag, not a legitimate hold.
    #{open_findings_briefing(state)}#{revision_diff_briefing(state)}
    Prior discussion (oldest first):

    #{render_thread(state.thread)}

    ----------------------------------------------------------------------

    """ <> review_prompt(state)
  end

  # Why there is a new diff to read. bd-bq8c8a: on `restart_on_remote_head/3`'s
  # path there is no implementer round behind this one — the head changed
  # because a third party pushed to the branch, and that commit was not aimed
  # at this reviewer's findings. Telling the reviewer otherwise invites it to
  # disposition its own open findings `[ADDRESSED]` against a diff that never
  # targeted them, which is the exact bd-6r8caj failure the open-findings
  # briefing exists to prevent.
  defp why_rereviewing(state) do
    case Map.get(state, :restarted_on_remote_head) do
      nil ->
        """
        The implementer has addressed your prior findings. Re-review the UPDATED
        diff.
        """

      sha ->
        """
        NO implementer ran for your prior findings. Instead the branch moved on
        origin: another actor pushed #{String.slice(sha, 0, 12)}, which is now the head, and
        the fix round was skipped rather than build a commit that could not be
        pushed. NOTHING in this diff was written in response to your findings —
        re-check each one against the new code on its own terms, and do not
        treat a finding as addressed unless the new head actually addresses it.
        """
    end
  end

  # bd-6r8caj: the open findings, by id, plus the DISPOSITIONS instruction that
  # makes an APPROVE checkable. Empty (and the round behaves exactly as before)
  # when nothing is carried forward.
  defp open_findings_briefing(state) do
    case Map.get(state, :open_findings, []) do
      [] ->
        ""

      open ->
        "\n" <>
          ReviewFindings.open_findings_block(open, Map.get(state, :revise_touched_files)) <>
          "\n" <> ReviewFindings.disposition_block(open)
    end
  end

  # bd-6r8caj: the diff the implementer ACTUALLY produced, named file by file.
  # The bd-8mtb0q round approved a revision whose diff for the cited file was
  # empty — it had no way to notice, because nothing put the real change set in
  # front of it.
  defp revision_diff_briefing(state) do
    case Map.get(state, :revise_touched_files) do
      nil ->
        ""

      touched ->
        files =
          case Enum.sort(touched) do
            [] -> "  (NOTHING — no revision has changed a single file so far)"
            list -> Enum.map_join(list, "\n", &("  " <> &1))
          end

        """

        FILES THE REVISION(S) ACTUALLY CHANGED — this is `git diff --name-only`
        across every revise round so far, not the implementer's own account of
        its work:

        #{files}

        A finding whose file does not appear above was NOT fixed where it was
        cited. Either the fix landed somewhere else (say where) or it did not
        happen — an implementer claiming "FIXED" is not evidence.
        """
    end
  end

  # Returns the async-tool instruction block appropriate for the adapter that
  # actually runs this reviewer pass: the rotation's pin, else the
  # cross-family selection (bd-5sfn7v), else the workspace's configured
  # reviewer. Falls back to the Claude block when the workspace is absent or
  # the adapter does not implement the callback — preserving existing
  # behaviour for Claude-only workspaces.
  defp async_tool_block(state) do
    state |> block_adapter() |> render_async_block()
  end

  defp block_adapter(%{reviewer_provider: provider})
       when is_atom(provider) and not is_nil(provider),
       do: Agents.for_type(provider)

  defp block_adapter(%{reviewer_selection: %{provider: provider}})
       when is_atom(provider) and not is_nil(provider),
       do: Agents.for_type(provider)

  defp block_adapter(state) do
    state
    |> Map.get(:workspace_id)
    |> load_workspace()
    |> then(&Agents.reviewer_for_workspace/1)
  end

  defp render_async_block(adapter) do
    # `function_exported?/3` does not autoload the target module — an adapter
    # module that hasn't been referenced yet in this VM (e.g. Gemini, when no
    # earlier test/code path has called it) reports `false` even though the
    # callback is implemented, silently falling back to Claude's async block.
    # Whether that's true depends on what else has run before this call, so
    # without `Code.ensure_loaded?/1` first this was an order-dependent bug.
    adapter =
      if Code.ensure_loaded?(adapter) and function_exported?(adapter, :async_tool_instruction, 3),
        do: adapter,
        else: Arbiter.Agents.Claude

    adapter.async_tool_instruction(
      "your VERDICT",
      "a VERDICT issued while a background task is still running is invalid,\n" <>
        "you would be judging on incomplete evidence",
      commit_first: false
    )
    |> String.trim_trailing()
  end

  # bd-5sfn7v: a prompt is rendered before `route_reviewer_pass/3` /
  # the timeout rotation pick the adapter, so it carries the workspace
  # default's async-tool block. Swap in the block of the adapter that will
  # really run, so a rotated Codex reviewer is not told about Claude's tools.
  defp retarget_async_block(prompt, state, :reviewer) when is_binary(prompt) do
    wanted = async_tool_block(state)

    Agents.adapters()
    |> Map.values()
    |> Enum.map(&render_async_block/1)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == wanted))
    |> Enum.reduce(prompt, fn other, acc ->
      if String.contains?(acc, other), do: String.replace(acc, other, wanted), else: acc
    end)
  end

  defp retarget_async_block(prompt, _state, _role), do: prompt

  defp load_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = task} ->
        %{
          title: task.title || "(untitled)",
          description: task.description || "(none)",
          acceptance: task.acceptance || "(none)"
        }

      _ ->
        %{title: "(unknown)", description: "(none)", acceptance: "(none)"}
    end
  rescue
    _ -> %{title: "(unknown)", description: "(none)", acceptance: "(none)"}
  end
end
