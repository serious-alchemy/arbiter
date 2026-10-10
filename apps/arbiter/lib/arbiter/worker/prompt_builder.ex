defmodule Arbiter.Worker.PromptBuilder do
  @moduledoc """
  Pure prompt-generation for dispatched workers.

  Extracted from `Arbiter.Worker.Dispatch` (bd-8u5uaw): this module has zero
  GenServer/dispatch-lifecycle coupling — every function here is a pure
  transform from an `Issue` (+ opts) to a `String.t()` prompt. `Dispatch`
  keeps thin public wrappers (`prompt_for/1`, `prompt_for_task/2`,
  `conflict_resolve_briefing/3`) that delegate here, since those are called
  externally (`ConflictResolver`, tests) as `Arbiter.Worker.Dispatch.*`.
  """

  require Ash.Query

  alias Arbiter.Agents.Gemini.ConfigDir, as: GeminiConfigDir
  alias Arbiter.MCP
  alias Arbiter.MCP.AgentConfig.Gemini, as: GeminiConfig
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.Issue
  alias Arbiter.Trackers
  alias Arbiter.Worker.EvidenceIntegrity
  alias Arbiter.Worker.PermissionsBlock
  alias Arbiter.Worker.ReviewVerification

  @doc false
  def prompt_for(%Issue{} = task), do: prompt_for_task(task, [])

  @doc false
  def prompt_for_task(%Issue{} = task, opts) do
    cond do
      Keyword.get(opts, :review, false) == true -> review_prompt(task, opts)
      # bd-9s9dqz: the two no-PR types share a briefing skeleton but not a
      # deliverable — `research` owes findings, `task` an action + outcome note.
      Issue.no_pr_type?(task.issue_type) -> directives_prefix(task) <> no_pr_prompt(task, opts)
      true -> directives_prefix(task) <> work_prompt(task, opts)
    end
  end

  # bd-kxzrk9: unread coordinator mail goes into every authoring prompt (fresh
  # dispatch and `resume/2` both land here) so a directive is never left for the
  # worker to find, and possibly fail to open, on its own.
  defp directives_prefix(%Issue{id: id}), do: Arbiter.Worker.CoordinatorDirectives.section(id)

  @doc """
  Briefing for a **conflict-resolve** worker (#354, Phase 2b).

  The Watchdog (`Arbiter.Worker.Watchdog`) dispatches a short-lived worker
  against the task's existing worktree when an *approved* PR is blocked as
  `:conflict` — mergeable in isolation but no longer applying cleanly on top of
  the current base. The worker's job is narrow: rebase the branch onto the
  current base, resolve the conflicts **honoring the task's original intent**,
  fix anything the rebase broke, and force-push so the Watchdog's next poll can
  re-attempt the merge.

  The original intent (title / description / acceptance) is embedded so a
  semantic conflict is resolved the way the task *meant*, not guessed. This
  supersedes and hardens the narrower #122 auto-conflict-resolver prompt: it
  adds the intent context and an explicit "run the tests, fix what the rebase
  broke" step the old mechanical-only prompt lacked.
  """
  @spec conflict_resolve_briefing(Issue.t(), String.t(), String.t(), keyword()) :: String.t()
  def conflict_resolve_briefing(%Issue{} = task, branch, target_branch, opts \\ [])
      when is_binary(branch) and is_binary(target_branch) do
    host_git? = Keyword.get(opts, :host_git, false)

    """
    You are a conflict-resolution worker for task #{task.id}.

    Your branch (#{branch}) is APPROVED but CONFLICTS with the current head of
    #{target_branch}: it was mergeable in isolation, but the base has moved and
    it no longer applies cleanly. Your ONLY job is to rebase it onto the current
    base, resolve the conflicts, and #{if host_git?, do: "commit the result", else: "force-push"} — NOT to re-implement the change
    or open a new PR.
    #{conflict_host_git_section(host_git?, target_branch)}
    ## Original intent — resolve conflicts so the result still satisfies THIS

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    ## Steps

    #{conflict_steps(host_git?, branch, target_branch)}

    DO NOT:
      * re-implement the change set or open a new PR,
      * touch files unrelated to the conflict,
      * abandon the rebase silently (`git rebase --abort` then exit).

    If a conflict is SEMANTIC — two changes both rewrote the same predicate or
    invariant such that no mechanical merge can honor both — STOP and escalate:

        arb message coordinator "Conflict on #{task.id} needs human review: <one-line why>"

    then print `arb done`. A loud escalation beats a silent miscompile in
    #{target_branch}.
    """
  end

  # bd-19skda: a podman conflict pass has no `git fetch`/`git push` (no forge
  # credential or GitHub host key, by design). The host fetches the target into
  # the clone before the pass starts and force-with-lease pushes the rebased
  # branch after `arb done`, so the briefing says so instead of sending the
  # worker at a fetch and push that dead-end in "Host key verification failed".
  defp conflict_host_git_section(false, _target_branch), do: ""

  defp conflict_host_git_section(true, target_branch) do
    """

    NO FETCH OR PUSH ACCESS — this container has no forge credential or GitHub
    host key, by design. The Arbiter host has already fetched the current
    #{target_branch} into your clone (`origin/#{target_branch}` is up to date)
    and force-pushes your rebased branch after `arb done`. Do not run `git
    fetch` or `git push`: a failure ("Host key verification failed", no
    credentials) is expected and is not a reason to withhold `arb done`.
    """
    |> indent_block()
    |> Kernel.<>("\n")
  end

  defp conflict_steps(true, _branch, target_branch) do
    """
      1. Rebase your branch onto the already-fetched base:
         `git rebase origin/#{target_branch}`
      2. Resolve every conflict so the result still honors the intent above.
         Most collisions are parallel edits to non-overlapping sections — keep
         both sides. Where two changes touch the same logic, keep the behaviour
         the acceptance criteria describe, then `git rebase --continue`.
      3. Run the test suite and fix anything the rebase broke — a clean rebase
         that fails tests is NOT done. Re-run until green. Commit any fix.
      4. Print `arb done` on a line by itself. The host pushes the branch.
    """
    |> indent_block()
  end

  defp conflict_steps(false, branch, target_branch) do
    """
      1. Fetch the latest base: `git fetch origin #{target_branch}`
      2. Rebase your branch onto it: `git rebase origin/#{target_branch}`
      3. Resolve every conflict so the result still honors the intent above.
         Most collisions are parallel edits to non-overlapping sections — keep
         both sides. Where two changes touch the same logic, keep the behaviour
         the acceptance criteria describe, then `git rebase --continue`.
      4. Run the test suite and fix anything the rebase broke — a clean rebase
         that fails tests is NOT done. Re-run until green.
      5. Force-push with lease to update the existing PR in place:
         `git push --force-with-lease origin #{branch}`
      6. Print `arb done` on a line by itself.
    """
    |> indent_block()
  end

  # Text interpolated into the briefing's heredoc is not re-indented past its
  # first line: indent every later line by the heredoc's four spaces, and drop
  # the trailing newline (the enclosing heredoc supplies its own).
  defp indent_block(text) do
    text |> String.trim_trailing() |> String.replace("\n", "\n    ")
  end

  # When resuming (bd-auma3z) the work prompt is prefixed with a git-derived
  # briefing of the prior worker's committed + uncommitted work, so the fresh
  # agent continues from the preserved worktree instead of redoing finished
  # steps. `:resume_context` is built by `Arbiter.Worker.ResumeContext`; it's
  # absent (empty prefix) on a normal fresh dispatch.
  @doc """
  The shared "ASYNC TOOLS" block, granting background execution *and* naming
  the only waiting primitive that works in a non-interactive session.

  `completion_signal` is the marker this prompt's completion protocol ends on
  (e.g. ``"`arb done`"`` or `"your VERDICT"`); `coda` is an optional extra
  clause appended to the final sentence.

  Public because `Arbiter.Agents.Claude.async_tool_instruction/0` — the review
  gate's copy — must stay byte-identical to the three prompts here. Four
  independently-worded copies is how the guidance drifted in the first place.

  ## Why this block says more than "you may background things" (bd-606zlr)

  It used to say only that: background what you like, but wait for every task
  before signalling done. A worker that correctly spots a command exceeding
  the tool-call timeout, backgrounds it, and arms a `Monitor` or
  `ScheduleWakeup` to await the result is, on that reading, *waiting properly*.
  It is not. `claude --print` ends the agent loop on the first turn that
  contains no tool call, so the process is gone before the notification fires
  and the notification is delivered to nothing. Observed three times in one day
  across two repos (runs 028759f4…, beeaac80…, 5b372d81…), twice discarding a
  correct but uncommitted fix. Permission to background is only safe when it
  arrives with the drain that actually works.
  """
  @spec async_tools_section(atom() | module(), String.t(), String.t() | nil, keyword()) ::
          String.t()
  def async_tools_section(completion_signal, coda, opts)
      when is_binary(completion_signal) and is_list(opts) do
    async_tools_section(Arbiter.Agents.Claude, completion_signal, coda, opts)
  end

  def async_tools_section(completion_signal, coda) when is_binary(completion_signal) do
    async_tools_section(Arbiter.Agents.Claude, completion_signal, coda, [])
  end

  def async_tools_section(completion_signal) when is_binary(completion_signal) do
    async_tools_section(Arbiter.Agents.Claude, completion_signal, nil, [])
  end

  def async_tools_section(adapter, completion_signal, coda \\ nil, opts \\ []) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :async_tool_instruction, 3) do
      adapter.async_tool_instruction(completion_signal, coda, opts)
    else
      Arbiter.Agents.Claude.async_tool_instruction(completion_signal, coda, opts)
    end
  end

  # The authoring prompts' coda, kept out of the interpolation line so the
  # sentence stays readable at source width.
  defp work_async_tools_section(adapter) do
    async_tools_section(
      adapter,
      "`arb done`",
      "the work is incomplete until every tool you launched has\nfinished and you have read its result"
    )
  end

  defp work_prompt(%Issue{} = task, opts) do
    resume_prefix = Keyword.get(opts, :resume_context) || ""
    resume_prefix <> base_work_prompt(task, opts)
  end

  # The resolved-skills advertisement block (DECISION C): always-on skills get
  # an imperative `/name` directive, situational skills are listed as available.
  # Empty string when no skills resolved (the common case today).
  defp skills_section(opts) do
    resolved = Keyword.get(opts, :resolved_skills, [])
    materialized? = Keyword.get(opts, :skills_materialized?, true)
    Arbiter.Skills.Materializer.prompt_section(resolved, materialized?)
  end

  # bd-ld8qde (G14): what the ticket's declared permissions were projected into.
  # Empty for an unguarded spawn, so the prompt is unchanged there.
  defp permissions_section(opts), do: PermissionsBlock.render(Keyword.get(opts, :projection))

  # bd-8cn795: whole-file reads of large modules (or a large PR body / API
  # dump piped straight into context) refill the window faster than
  # autocompact can shed it, tripping the CLI's own thrash detector
  # ("Autocompact is thrashing...") and aborting the session before any real
  # work happens. This is deterministic for a given file set, so the fix has
  # to be read discipline, not a retry. Shared between the work and review
  # prompts since both failure instances (bd-3cpcw2, lt-5jhqs8) were reads,
  # not writes.
  # Shared between `base_work_prompt/2` and `task_prompt/2` (bd-6v2my2): any
  # dispatch that provisions a worktree needs the same "don't write outside it"
  # warning, regardless of whether the directive is reviewable code or a
  # `:task`-type follow-up that also happens to get a checkout.
  defp isolation_section(worktree_path) when is_binary(worktree_path) do
    """

    FILESYSTEM ISOLATION — Your worktree is at:

        #{worktree_path}

    You MUST only write files inside this directory. Do NOT use absolute
    paths that point outside it — especially not to the main repo checkout
    (e.g. $HOME/dev/arbiter/...). Writing to the main repo corrupts
    Phoenix hot-reload and cascades to kill every other running worker.
    Always use relative paths or paths rooted at #{worktree_path}.

    TEMP FILES — Arbiter gave this run its own scratch directory, exported as
    $TMPDIR (also $TMP and $TEMP) and removed when the run ends. Put every
    temporary file or directory there (`mktemp` already honors it). Do NOT
    invent `/tmp/<name>` directories: /tmp is RAM-backed and nothing cleans
    them up.
    """
  end

  defp isolation_section(_), do: ""

  # bd-fjlx01: a worker verifying a UI/server change locally (e.g. booting
  # `mix phx.server`/`rails server`/`npm run dev` to check it in a browser)
  # sometimes tears that process down with a name- or pattern-matching kill
  # (`pkill -f "phx.server"`, `killall node`, `fuser -k <port>`). Process
  # command lines are visible host-wide, not scoped to the worker's own
  # worktree or session — a pattern broad enough to match your own instance is
  # also broad enough to match Arbiter's own server (dispatch is frequently
  # dogfooded: the coordinator that dispatched you may be running the exact
  # same command on this same host) or another concurrent worker's instance.
  # This has taken down the coordinator and every in-flight worker with it in
  # production use. Shared between the work and task prompts for the same
  # reason `isolation_section/1` is: any dispatch that might shell out to
  # start a long-running process carries the same hazard.
  defp process_kill_discipline_section do
    """

    PROCESS DISCIPLINE — if you start a local server or any other long-running
    process to verify your work (e.g. booting a dev server to check a page in
    a browser), you are responsible for stopping ONLY that exact process.
    NEVER use `pkill`, `killall`, `fuser -k`, or any other name/pattern-based
    kill — process command lines are visible across the whole host, not just
    your worktree, and a pattern that matches your own instance can just as
    easily match the coordinator's own server or another worker's, taking
    them down too. Capture the exact PID when you start the process (e.g.
    `some_server & SERVER_PID=$!`) and stop only that PID (`kill $SERVER_PID`).
    If you cannot reliably track that PID across your own tool calls, do not
    start the process at all — rely on the automated test suite instead of
    live/manual verification.
    """
  end

  defp read_discipline_section do
    """
    READ DISCIPLINE — avoid whole-file reads of large modules: they refill
    the context window faster than autocompact can shed it and can abort your
    session mid-task ("Autocompact is thrashing"). Prefer grep/symbol search
    to locate the relevant span first, then read a bounded offset+limit range
    rather than the entire file. For a large `gh`/API command's output, pipe
    it to a file and read bounded slices rather than dumping it whole into
    context.

    FORGE CLIs — a containerized (podman) worker has `arb` on PATH but
    deliberately no `gh`/`glab` and no forge token; if `command -v gh` finds
    nothing, use the arbiter MCP tools (`ticket_show`, `ci_*`, ...) instead of
    retrying the CLI.
    """
  end

  # bd-57nhsi: raw `mix test` output (compile chatter, passing dots, warnings)
  # is re-read on every later turn of the session; the `run_tests` MCP tool runs
  # the same tests in the run's own environment and returns only the counts and
  # each failure. Authoring prompts steer to it; a session with no MCP server
  # (`mcp_tools?: false`) is not told about a tool it lacks.
  @doc "The paragraph that steers an authoring worker to the `run_tests` tool."
  @spec test_tool_section() :: String.t()
  def test_tool_section do
    """
    RUNNING TESTS — use the `run_tests` MCP tool instead of `mix test` in the
    shell. It runs your tests in this run's own environment (same container,
    deps and `_build`) and returns only the pass/fail counts plus each failing
    test's header, assertion and a few stacktrace frames, so compile output and
    passing-test noise do not ride in your context for the rest of the session.
    Pass `paths` (test files, optionally `file.exs:LINE`, or directories) or
    `changed: true` for the tests mapped from what you changed. The result
    carries `full_log`, the path of the complete output; read that only if the
    summary is not enough. Fall back to a raw `mix test` only for a flag the tool
    lacks, and then pipe it through `tail` or `grep` rather than letting the
    whole run into context.
    """
  end

  @doc """
  `test_tool_section/0` for a review-gate fix round whose adapter is known, or
  `""` when the session has no arbiter MCP server: injection is off, or agy has
  no isolated `$HOME` (`GeminiConfig` refuses, as `Dispatch.inject_mcp_config/3`
  sees).
  """
  @spec test_tool_section_for(module()) :: String.t()
  def test_tool_section_for(adapter) do
    if MCP.inject_config?() and mcp_config_writable?(adapter),
      do: test_tool_section(),
      else: ""
  end

  defp mcp_config_writable?(adapter) do
    adapter.provider() != "gemini" or
      GeminiConfig.cli_flavour() != :agy or
      GeminiConfigDir.enabled?()
  end

  defp test_tool_section(opts),
    do: if(mcp_tools?(opts), do: test_tool_section() <> "\n", else: "")

  # bd-capkj9: a podman container has no forge credential or host key by design;
  # the host pushes after `arb done`. Without this a worker that tries
  # `git push`, fails, and treats the push as required never prints `arb done`.
  # The authoring work prompt gets it, and so does a ReviewGate fix round that
  # runs in a container (bd-49l0eo; `ReviewGate` pushes it at the next round's
  # push gate).
  defp podman_push_section(opts) do
    if Keyword.get(opts, :sandbox_backend) == :podman,
      do: "\n" <> no_push_access() <> "\n",
      else: ""
  end

  @doc """
  The briefing paragraph for a worker in a podman container: it holds no forge
  credential, so it commits and the host pushes.
  """
  @spec no_push_access() :: String.t()
  def no_push_access do
    """
    NO PUSH ACCESS — this container has no forge credential or GitHub host key,
    by design. Commit on your branch, but do not push: the Arbiter host pushes
    the branch and opens the PR after `arb done`. A failed `git push` or `gh`
    call ("Host key verification failed", no credentials) is expected and is
    not a reason to withhold `arb done`.
    """
  end

  defp push_clause(opts) do
    if Keyword.get(opts, :sandbox_backend) == :podman, do: "", else: ", and push it"
  end

  defp base_work_prompt(%Issue{} = task, opts) do
    mcp? = mcp_tools?(opts)
    worktree_path = Keyword.get(opts, :worktree_path)
    adapter = Keyword.get(opts, :adapter, Arbiter.Agents.Claude)
    isolation_section = isolation_section(worktree_path)

    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{verification_failure_section(task)}#{prior_review_findings_section(task)}
    Your current directory is a fresh git worktree on a per-task branch.
    #{isolation_section}
    #{process_kill_discipline_section()}
    #{read_discipline_section()}
    #{test_tool_section(opts)}#{commit_gate_section()}#{EvidenceIntegrity.worker_block()}#{podman_push_section(opts)}#{skills_section(opts)}#{permissions_section(opts)}
    Work the task to completion: load context, design, implement, test,
    commit on this branch#{push_clause(opts)}.

    Do NOT open a pull request yourself (no `gh pr create` / `glab mr
    create`). The MergeQueue opens the single canonical PR for this task, on
    the correct base branch, using the body you author in the next step.
    Opening your own PR creates a duplicate on the wrong base.
    #{pr_review_instruction(task, opts)}#{verify_after_deploy_step(task, mcp?)}#{pr_body_step(task, mcp?)}#{completion_notes_step(task, mcp?)}
    #{coordination_section(task, opts)}
    CRITICAL — continuation discipline: NEVER end a response with only a plan
    or a statement of the next step (for example, announcing that you will now
    write a test instead of writing it). After ANY check (mailbox /
    `.arbiter/INBOX` / git status), immediately continue with the next
    concrete tool call in the same turn. Your session is non-interactive: a
    turn that contains no tool call ENDS the session. The only correct way to
    finish is to print `arb done` once the work is complete — if you are about
    to stop without having printed `arb done`, keep working.

    #{work_async_tools_section(adapter)}
    #{file_reading_section(adapter)}\
    When you are completely done, print the line:

        arb done

    on a line by itself, exactly. The worker watches your stdout and
    will mark the task complete when it sees that marker.
    """
  end

  # bd-g926uj: the coordination block. Coordinator mail is also written to
  # `.arbiter/INBOX` in the worktree (Arbiter.Messages.WorktreeDelivery), so
  # with a worktree the per-step `arb inbox` round trip is redundant and only
  # the file is read. Without a worktree there is no file delivery: keep it.
  defp coordination_section(%Issue{id: id}, opts) do
    if is_binary(Keyword.get(opts, :worktree_path)) do
      """
      Coordination: direction from the coordinator and flags from sibling workers
      arrive as `.arbiter/INBOX` in your working directory; do not run `arb inbox`.
      Between major steps, check for it using `[ -f .arbiter/INBOX ] && cat .arbiter/INBOX`
      (this does NOT error when the file is absent — the normal case). If it exists, read
      it, act on any coordinator instructions it contains, then delete the file to
      acknowledge receipt. Treat it as a real-time message from the coordinator — it
      takes precedence over your current task if it redirects you. To leave a flag
      for another worker, use `arb message <their-task-id> <text>`.
      """
    else
      """
      Coordination: at the start of each step, check your mailbox by running

          arb inbox #{id}

      This shows any direction from the coordinator or flags from sibling workers
      (e.g. an upstream API shape changed) and marks them read. To leave a flag
      for another worker, use `arb message <their-task-id> <text>`.

      Between major steps, also check for `.arbiter/INBOX` in your working
      directory using `[ -f .arbiter/INBOX ] && cat .arbiter/INBOX` (this does
      NOT error when the file is absent — the normal case). If it exists, read
      it, act on any coordinator instructions it contains, then delete the file to
      acknowledge receipt. Treat it as a real-time message from the coordinator — it
      takes precedence over your current task if it redirects you.
      """
    end
  end

  # bd-g926uj: what the commit gate covers, so the worker neither re-runs it nor
  # waits on a backgrounded full precommit; and which tests are its job.
  @doc false
  @spec commit_gate_section() :: String.t()
  def commit_gate_section do
    """
    VERIFICATION — Arbiter runs `mix format --check-formatted`,
    `mix compile --warnings-as-errors` and `mix credo --strict` on your touched
    files at the commit gate (when you print `arb done`, before anything is
    pushed) and sends any failure back to this session. Do NOT run them
    yourself, and do NOT run the full `mix precommit` / `mix audit` or poll a
    backgrounded run. Run only the tests for your changed files, in the
    foreground: for each changed `lib/<path>.ex` that is `test/<path>_test.exs`
    in the same app (`cd apps/<app> && mix test test/<path>_test.exs`, or
    `scripts/pre-push-tests.sh <files>`). The gate's output lists these tests
    for your changed files.

    """
  end

  # bd-buefg4: agy-only. Claude's Read tool already tells the model about
  # offset/limit and its context handling does not exhibit the loop.
  defp file_reading_section(Arbiter.Agents.Gemini),
    do: "\n" <> Arbiter.Agents.Gemini.file_reading_instruction() <> "\n"

  defp file_reading_section(_adapter), do: "\n"

  # A session whose provider could not be handed the Arbiter MCP server (agy with
  # no isolated `$HOME`, a failed config write — `Dispatch.inject_mcp_config/3`
  # sets `mcp_tools?: false`) has no `ticket_update_progress` tool. Telling it to
  # use the tool while forbidding the `arb` CLI deadlocks the notes gate, so
  # such a session is told to use the CLI instead. Defaults to true: every
  # session that was not positively known to lack MCP keeps the MCP wording.
  defp mcp_tools?(opts), do: Keyword.get(opts, :mcp_tools?, true) != false

  # `arb ticket update` is the CLI twin of `ticket_update_progress`; the flag
  # names match the tool's arguments.
  defp cli_update(id, flags), do: "arb ticket update #{id} #{flags}"

  # bd-5lc99r / bd-9s9dqz: briefing for a no-PR issue type. `research`: the
  # non-reviewable investigation type. The deliverable is a findings/results summary written to the
  # directive's `notes` field via the `ticket_update_progress` MCP tool, NOT a code
  # change, commit, or PR. The notes gate (Arbiter.Worker) blocks `arb done`
  # until `notes` is non-blank, so this prompt frames the whole job around
  # producing those findings and deliberately omits the commit/push/PR-body
  # steps the standard work prompt carries.
  #
  # bd-6v2my2: a PRPatrol follow-up (`source_pr` set) is also dispatched as a
  # `:research` — it has no branch/PR of its own either — but unlike a pure
  # investigation it MAY legitimately need to push a code fix. That fix
  # belongs on the ORIGINAL PR's branch, never a fresh one, so `pr_follow_up_note/1`
  # swaps in that guidance (and the worktree it runs from, when one was
  # provisioned) in place of the generic "you are not expected to edit a repo"
  # line.
  #
  # bd-9s9dqz: an operational `task` (a restart, a config flip) gets the same
  # skeleton with an action-oriented job block instead: do the action, verify
  # it, leave a short outcome note. It owes no findings write-up and there is no
  # notes gate — `arb done` completes it. Both bodies forbid code work.
  defp no_pr_prompt(%Issue{} = task, opts) do
    mcp? = mcp_tools?(opts)
    adapter = Keyword.get(opts, :adapter, Arbiter.Agents.Claude)
    kind = task.issue_type

    """
    You are a worker working autonomously on task #{task.id}.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}

    This is a `#{kind}`-type directive: it has NO branch or pull request of its
    own, and none will be opened for it.
    #{pr_follow_up_note(task, opts)}#{isolation_section(Keyword.get(opts, :worktree_path))}
    #{process_kill_discipline_section()}
    #{read_discipline_section()}
    #{EvidenceIntegrity.worker_block()}#{permissions_section(opts)}
    #{no_pr_job(task, kind, mcp?)}
    #{completion_notes_step(task, mcp?)}
    Coordination: at the start of each step, check your mailbox by running

        arb inbox #{task.id}

    This shows any direction from the coordinator or flags from sibling workers and
    marks them read. To leave a flag for another worker, use
    `arb message <their-task-id> <text>`.

    Between major steps, also check for `.arbiter/INBOX` in your working
    directory. If it exists, read it, act on any coordinator instructions it
    contains, then delete the file to acknowledge receipt.

    #{async_tools_section(adapter, "`arb done`", nil)}

    When you are completely done — #{no_pr_done_clause(kind)} — print the line:

        arb done

    on a line by itself, exactly. The worker watches your stdout and will mark
    the task complete when it sees that marker.
    """
  end

  # bd-9s9dqz: the type-specific "Your job" block of a no-PR briefing.
  defp no_pr_job(%Issue{id: id}, :research, true) do
    """
    Your job:
      1. Do the investigation the directive describes.
      2. Write your findings to the directive's `notes` field by calling the
         `ticket_update_progress` MCP tool with its `notes` argument (Markdown is
         fine). Make it self-contained: what you investigated, what you found,
         and any recommendation or conclusion the coordinator needs — they read it
         via `arb show #{id}` and the dashboard.

    A notes gate enforces this: if you print `arb done` while `notes` is still
    blank, you will be reprompted to write your findings before the directive
    can close. Do NOT shell out to the `arb` CLI for the notes — use the
    `ticket_update_progress` MCP tool.\
    """
  end

  defp no_pr_job(%Issue{id: id}, :research, false) do
    """
    Your job:
      1. Do the investigation the directive describes.
      2. Write your findings to the directive's `notes` field by running
         `#{cli_update(id, "--append-notes \"<findings>\"")}` (Markdown is fine).
         Make it self-contained: what you investigated, what you found, and any
         recommendation or conclusion the coordinator needs — they read it via
         `arb show #{id}` and the dashboard.

    A notes gate enforces this: if you print `arb done` while `notes` is still
    blank, you will be reprompted to write your findings before the directive
    can close. This session has NO Arbiter MCP tools (no
    `ticket_update_progress`), so the `arb` CLI above is the way to record them.\
    """
  end

  defp no_pr_job(%Issue{id: id}, :task, mcp?) do
    """
    Your job:
      1. Carry out the operational action the directive describes (a restart, a
         config change, a one-off command) — that action and nothing beyond it.
         This is not code work: do NOT edit, commit or push code.
      2. Check that the action took effect.
      3. Record a short outcome note — what you did and the result, a line or
         two — #{if mcp?, do: "by calling the `ticket_update_progress` MCP tool with its `notes`\n     argument. Do NOT shell out to the `arb` CLI for it.", else: "by running `#{cli_update(id, "--append-notes \"<outcome>\"")}`\n     (this session has no Arbiter MCP tools)."}

    No findings write-up is required and there is no notes gate: printing
    `arb done` once the action is done completes the directive. If the action
    cannot be carried out, say why in the outcome note instead of printing
    `arb done`.\
    """
  end

  defp no_pr_done_clause(:task), do: "the action carried out and its outcome noted"
  defp no_pr_done_clause(_research), do: "findings written to `notes`"

  # bd-6v2my2: a PRPatrol follow-up carries `source_pr` — the PR it was auto-filed
  # against (unresolved review threads / CHANGES_REQUESTED / a failing required
  # check, see `Arbiter.Workflows.PRPatrol`). Unlike plain research/ops `:task`
  # work, it may need to push a real fix, but that fix must land on the
  # ORIGINAL PR's branch: pushing a new branch from this directive's own
  # (unintegrated) worktree previously became a byte-identical duplicate PR
  # against the original's entire diff (ac-divfvo -> apex_server#3682). Like
  # any `:task`, this directive gets no branch worktree — its current
  # directory (when one is provisioned) is a disposable, detached checkout
  # with no branch of its own, so `gh pr checkout` there is always safe: there
  # is nothing Arbiter-owned to collide with or lose.
  defp pr_follow_up_note(%Issue{id: id, source_pr: source_pr}, opts)
       when is_binary(source_pr) and source_pr != "" do
    """

    This directive is a PRPatrol follow-up against EXISTING pull request ##{source_pr}.
    If the reviewer's findings were already addressed — or your job here is only
    to reply / resolve / escalate on the review threads — completing with no
    code change at all is SUCCESS. Do not force a commit just to have one.

    Your current directory is already a checkout of the repository (read-only
    by convention, not a branch of its own) — good enough to inspect the code
    and run `gh`/`git`. If a fix genuinely is needed: check out the ORIGINAL
    PR's branch directly — `gh pr checkout #{source_pr}` — right there, and
    commit#{if Keyword.get(opts, :host_pushes?, false), do: " (Arbiter pushes it for you; do NOT `git push`)", else: " + push (`git push`)"}, which updates PR ##{source_pr} in place. Do
    NOT `git push -u origin <new-branch>` or `gh pr create` — that opens a
    duplicate PR against the original's entire diff.

    If the fix is too large or risky to fold in now, do not silently open a new
    PR either — that must never be a side effect of this dispatch. Push back on
    the thread explaining why (see the protocol above), or, only when a
    genuinely separate deliverable is warranted, file it as an explicit,
    recorded decision: `arb create <title> --parent #{id} --type feature` —
    a distinct task that gets its own branch/PR by design.
    """
  end

  defp pr_follow_up_note(_task, _opts) do
    """

    No worktree is provisioned by default — you are not expected to edit a repo.
    If the work genuinely requires inspecting code you may read files, but do
    not author a branch or open a PR.
    """
  end

  # The worker authors the PR/MR body and persists it on the task; the
  # MergeQueue (not the worker) opens the one canonical PR with it (bd-53xrmi).
  # Authoring it *after* implementing is what makes it worker-quality — the
  # Test plan reflects what actually passed, not what the spec hoped for. If
  # the repo ships a PR template we fill it rather than discard it (GitHub
  # injects the bare template only when the body is empty — the empty-body
  # incident #3606). Persisted via the `ticket_update_progress` MCP tool
  # (`pr_body` field), which the MergeQueue reads back as `pr_body`. We use the
  # MCP tool rather than the `arb` escript so completion never depends on
  # `~/.local/bin/arb` being present (it is transiently deleted by test runs).
  defp pr_body_step(
         %Issue{id: id, tracker_type: tracker_type, tracker_ref: tracker_ref},
         mcp?
       ) do
    closes_guidance =
      case {tracker_type, is_binary(tracker_ref) && Regex.match?(~r/^\d+$/, tracker_ref)} do
        {:github, true} ->
          "\n\n    For GitHub-tracked tasks, include a closing keyword `Closes ##{tracker_ref}`" <>
            " in the References section — GitHub will auto-close the issue on merge, " <>
            "acting as a backstop independent of Arbiter's own close mechanism."

        _ ->
          ""
      end

    """

    Author the PR description and persist it on the task — the MergeQueue opens
    the PR with this exact body, so write it as the PR writeup, not a restatement
    of the ticket. Do this AFTER the work is implemented and tested, so it
    reflects what actually changed:

      * **Summary** — what changed and why, in a few sentences.
      * **Test plan** — the checks you ran, with checked boxes for what passed.
      * **References** — the task id (#{id}) and any linked ticket/PRs.#{closes_guidance}

    If the repo has a PR template (`.github/pull_request_template.md`), FILL it
    rather than discard it. #{pr_body_persist(id, mcp?)}

    Do this before printing `arb done`.
    """
  end

  defp pr_body_persist(_id, true) do
    "Persist the finished body verbatim by calling the\n`ticket_update_progress` MCP tool with its `pr_body` argument set to the full\nPR body (Markdown). Use the MCP tool, which is available in this session —\ndo NOT shell out to the `arb` CLI for this."
  end

  defp pr_body_persist(id, false) do
    "This session has NO Arbiter MCP tools, so persist the finished body verbatim\nwith the `arb` CLI: write it to a scratch file OUTSIDE the worktree and run\n`#{cli_update(id, "--pr-body \"$(cat <file>)\"")}`."
  end

  # bd-9so315: the escaped-defect class this addresses is a change whose only
  # execution context is the long-lived server — merged green, auto-closed,
  # found broken hours later. Nobody upstream of the worker can see the diff, so
  # the worker is the only party in a position to raise the flag, and it has to
  # be told to.
  defp verify_after_deploy_step(%Issue{verify_after_deploy: true, id: id}, _mcp?) do
    """

    POST-MERGE VERIFICATION — this task is already flagged
    `verify_after_deploy`. When its PR merges it will NOT close: it parks at
    `awaiting verification` until the coordinator restarts the server, observes
    the new path, and records what they saw (`arb ticket verify #{id}
    --observed "<evidence>"`). Make that observation easy: say in your `notes`
    or PR body exactly what to look at, and what a working result looks like.
    """
  end

  defp verify_after_deploy_step(%Issue{id: id}, mcp?) do
    """

    POST-MERGE VERIFICATION — if your diff's only execution context is the
    long-lived server, flag it. That means anything a green test suite cannot
    prove is live: env/config plumbing that has to reach a spawned worker,
    a `doctor`/health probe, a capture or ingest path, code whose first real
    run is inside the running Phoenix process. Set the flag by #{if mcp?, do: "calling the\n`ticket_update_progress` MCP tool with `verify_after_deploy: true`", else: "running\n`#{cli_update(id, "--verify-after-deploy")}` (no Arbiter MCP tools here)"}, and say
    in your `notes` what to look at after a restart and what a working result
    looks like.

    The task then parks at `awaiting verification` on merge instead of closing,
    and the coordinator restarts and observes it once before it closes. If your
    change genuinely runs under test — a pure function, a LiveView with
    assertions, a migration — leave it alone; the flag costs a human round trip
    and is not free.
    """
  end

  # bd-dp7hiw: `task.notes` only carries a short per-round summary now (see
  # `Worker.format_review_gate_note/3`) — the actual findings text live in
  # `Arbiter.ReviewGate.Round`, one row per reviewer pass. Read the most
  # recent `role: :review` row directly (this worker tier can query the Ash
  # resource even though `review_gate_rounds_list` itself is coordinator-only)
  # and surface its findings here, so the re-dispatched worker sees them
  # immediately in its prompt without having to call ticket_show or gh pr view
  # first.
  # bd-8ssxap: `ticket_verify failed` reopens the task but leaves `pr_ref` cleared
  # and `verification_outcome`/`verification_evidence` in place (they only
  # reset on the *next* `:await_verification`, see Issue's moduledoc) — so this
  # stays true across the whole redispatch until a fresh merge is verified.
  # Without this section the redispatched worker has no way to learn its prior
  # (already-merged) attempt didn't actually fix the bug in production, and
  # nothing here stopped it from just re-submitting the same, already-landed
  # commits (the empty-PR incident this task fixes). Placed right after
  # Acceptance — before any other context — so it can't be missed.
  defp verification_failure_section(%Issue{
         verification_outcome: :failed,
         verification_evidence: evidence
       })
       when is_binary(evidence) and evidence != "" do
    """

    ⚠ MERGED FIX FAILED IN PRODUCTION — read this before doing anything else.

    A previous attempt at this task was merged and closed, but a post-merge
    verification check found it did NOT actually fix the problem. The merged
    commits are NOT the fix — do not re-submit them as-is. New work is
    required: understand why the merged change didn't work, then fix the
    actual defect.

    What was observed when verification failed:
    #{evidence}
    """
  end

  defp verification_failure_section(%Issue{}), do: ""

  defp prior_review_findings_section(%Issue{id: task_id}) when is_binary(task_id) do
    case latest_review_round_findings(task_id) do
      findings when is_binary(findings) and findings != "" ->
        """

        Prior review findings (address these before starting new work):
        #{findings}
        """

      _ ->
        ""
    end
  end

  defp prior_review_findings_section(_task), do: ""

  defp latest_review_round_findings(task_id) do
    Round
    |> Ash.Query.filter(task_id == ^task_id and role == :review)
    |> Ash.Query.sort(fix_round_attempt: :desc, round: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Round{findings: findings} -> findings
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # When a PR is already open for this task, the re-slunged worker must read
  # the PR review comments to find what changed. The `Round`-derived findings
  # (above) are the primary source, but the PR reviews are the canonical
  # record — fetching them explicitly guards against a `Round` row being
  # stale or missing.
  defp pr_review_instruction(%Issue{pr_ref: pr_ref}, opts)
       when is_binary(pr_ref) and pr_ref != "" do
    """

    This task has an existing PR (##{pr_ref}). Read the PR review comments
    before starting work — the review findings are there:

        gh pr view #{pr_ref} --json reviews,reviewComments

    Address every finding (fix the code or rebut with justification), then
    #{if Keyword.get(opts, :host_pushes?, false), do: "commit to the existing branch (Arbiter pushes it; do NOT push)", else: "push commits to the existing branch"}. Do NOT open a new PR.
    """
  end

  defp pr_review_instruction(_task, _opts), do: ""

  # For tracker-backed tasks (an upstream Jira/etc. ticket), completing the
  # work includes producing the gated completion notes the tracker requires
  # before it will transition the ticket forward. We make this an explicit,
  # non-optional step in the worker's prompt and tell it exactly how to
  # persist the notes on the task (the `ticket_update_progress` MCP tool), so the
  # downstream tracker-sync has the fields to push. We use the MCP tool rather
  # than the `arb` escript so completion never depends on `~/.local/bin/arb`
  # being present (it is transiently deleted by test runs — bd-53xrmi). Untracked
  # tasks get nothing extra.
  defp completion_notes_step(%Issue{tracker_type: :none}, _mcp?), do: ""

  defp completion_notes_step(%Issue{tracker_ref: ref}, _mcp?) when ref in [nil, ""], do: ""

  defp completion_notes_step(%Issue{} = issue, mcp?) do
    adapter = Trackers.for_task(issue)

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :gating_fields, 2) do
      """

      This task is backed by an external tracker ticket. Before you finish, you
      MUST produce its completion notes and persist them on the task — the
      tracker gates the ticket's forward transition until both are filled. Call
      #{if mcp?, do: "the `ticket_update_progress` MCP tool (available in this session) with these\narguments:", else: "`#{cli_update(issue.id, "--qa-notes \"...\" --deployment-notes \"...\"")}`\n(this session has no Arbiter MCP tools) with these values:"}

        * `qa_notes` — What QA should verify: the user-facing behaviour to
          exercise, edge cases, and how to confirm the fix.
        * `deployment_notes` — Rollout considerations: DB migrations, feature
          flags, config/env changes, ordering, and any backout steps. Write
          'None' only if there genuinely are none.

      #{if mcp?, do: "Use the MCP tool — do NOT shell out to the `arb` CLI for this.", else: "Use the `arb` CLI as shown — there is no MCP tool to call."} Base the
      notes on the change you actually made. This is part of "done": do it before
      printing `arb done`.
      """
    else
      ""
    end
  end

  # Pre-existing complexity 13 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp review_prompt(%Issue{} = task, opts) do
    checkout = review_checkout(opts)
    adapter = Keyword.get(opts, :adapter, Arbiter.Agents.Claude)

    tracker_line =
      case task.pr_ref do
        pr when is_binary(pr) and pr != "" ->
          "Tracker ref (PR/MR to review): #{task.tracker_type}:#{pr}\n\n"

        _ ->
          case task.tracker_ref do
            ref when is_binary(ref) and ref != "" ->
              "Tracker ref (PR/MR to review): #{task.tracker_type}:#{ref}\n\n"

            _ ->
              ""
          end
      end

    tracker_context_section =
      case Keyword.get(opts, :tracker_context) do
        %{ref: ref, type: type, title: title, description: desc}
        when is_binary(ref) and ref != "" ->
          context_body =
            [title && "Title: #{title}", desc] |> Enum.filter(& &1) |> Enum.join("\n\n")

          """

          --- Tracker context (read-only, #{type}:#{ref}) ---
          #{context_body}
          --- End tracker context ---

          """

        _ ->
          ""
      end

    """
    You are a reviewer worker. Review the pull/merge request linked to task
    #{task.id} and post a verdict. You are not the author; do not modify the
    branch.

    Title: #{task.title}

    Description:
    #{task.description || "(none)"}

    Acceptance:
    #{task.acceptance || "(none)"}
    #{tracker_context_section}
    #{tracker_line}#{review_location_section(checkout)}
    #{process_kill_discipline_section()}
    #{read_discipline_section()}
    Steps:
      1. #{review_diff_instruction(checkout)}
      2. Identify real correctness, security, or contract issues against the
         task's intent. Skip style nits.
      3. Post inline comments for each finding through the same tracker CLI.
      4. Post a single review-level verdict — `approve` or `request_changes`
         — with a one-paragraph summary.

    Forbidden:
      * Do NOT push code.
      * Do NOT merge or close the PR/MR.
      * Do NOT modify any branch, including the PR's head.

    #{EvidenceIntegrity.reviewer_block()}
    #{async_tools_section(adapter, "`arb done`", nil, commit_first: false)}

    #{ReviewVerification.anti_stale_reflag_block()}
    After you post the review to the tracker, print your conclusion on its
    own line, EXACTLY one of:

        VERDICT: APPROVE
        VERDICT: REQUEST_CHANGES

    If you REQUEST_CHANGES you MUST have posted an ENUMERATED list of concrete
    findings through the tracker CLI — each with a severity, a location, and a
    suggested fix. A REQUEST_CHANGES verdict that names no findings is invalid.

    #{ReviewVerification.disclosure_block()}
    Then print, on a line by itself:

        arb done
    """
  end

  # bd-199giy: the review checkout descriptor threaded in by
  # `Arbiter.Worker.Dispatch` when it managed to provision a throwaway worktree
  # at the reviewed branch's current `origin` head. `nil` — the pre-bd-199giy
  # shape, and the fallback whenever provisioning fails — keeps the diff-only
  # prompt byte-for-byte unchanged.
  defp review_checkout(opts) do
    case Keyword.get(opts, :review_checkout) do
      %{path: path} = checkout when is_binary(path) and path != "" -> checkout
      _ -> nil
    end
  end

  # Where the reviewer is standing, and what it may do there.
  #
  # Without a checkout this is the old text: the agent's cwd is the repo's
  # *shared* local checkout, which is a human contributor's working directory —
  # hence the "no worktree was provisioned" framing and the "do not check out
  # the branch" step below.
  #
  # With one, the reviewer gets the same deal the external Tier-2 reviewer has
  # had since bd-6onexk: a disposable, detached worktree at the exact commit
  # under review, with read-only tool access. The read-only half is enforced in
  # the spawn (`Dispatch` denies Edit/Write/NotebookEdit), not by this text —
  # this just tells the reviewer what it is holding.
  defp review_location_section(nil) do
    String.trim_trailing("""
    Your current directory is the repo's local checkout. There is
    no per-task branch and no worktree was provisioned — this is a review-only
    directive.
    """)
  end

  defp review_location_section(%{path: path} = checkout) do
    String.trim_trailing("""
    Your current directory (#{path}) is a
    throwaway git worktree checked out DETACHED at `#{checkout[:branch]}`
    head #{checkout[:head_sha]} — the exact commit under review. It is yours alone and is
    destroyed when this review ends. Read, Grep, Glob and Bash work here; Edit,
    Write and NotebookEdit are denied, so you cannot modify the code you are
    reviewing and cannot advance the branch.

    Use it: open the real files at the reviewed commit, grep for call sites the
    diff never shows, and run the tests against the actual tree. The diff is your
    entry point, not the limit of what you can check. Report findings only on
    code the diff actually touches — anything the checkout surfaces outside the
    diff belongs in your summary prose, not as an inline comment.
    """)
  end

  # Step 1 of the review, keyed to what the reviewer actually has in front of
  # it. Continuation lines carry the 5-space hanging indent the numbered list
  # uses, since this is interpolated verbatim into the prompt heredoc.
  defp review_diff_instruction(nil) do
    String.trim_trailing("""
    Read the PR/MR diff via the configured tracker's CLI (`gh pr diff
         <ref>` for GitHub, `glab mr diff <ref>` for GitLab, `git diff` for
         the Direct local strategy). Do not check out the branch.
    """)
  end

  defp review_diff_instruction(%{base_branch: base}) when is_binary(base) and base != "" do
    String.trim_trailing("""
    Read the diff under review with `git diff origin/#{base}...HEAD` in this
         worktree (the tracker CLI — `gh pr diff <ref>` for GitHub, `glab mr
         diff <ref>` for GitLab — is the fallback if that base ref is
         unavailable). The commit under review is ALREADY checked out here; do
         not check out or create any other branch.
    """)
  end

  # A checkout with no resolvable base branch: the worktree is still real and
  # worth exploring, but there is no local ref to diff against, so the tracker
  # CLI stays the source of the diff.
  defp review_diff_instruction(%{}) do
    String.trim_trailing("""
    Read the diff under review via the configured tracker's CLI (`gh pr
         diff <ref>` for GitHub, `glab mr diff <ref>` for GitLab). The commit
         under review is ALREADY checked out here; do not check out or create
         any other branch.
    """)
  end
end
