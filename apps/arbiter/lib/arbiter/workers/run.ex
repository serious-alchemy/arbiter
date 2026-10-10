defmodule Arbiter.Workers.Run do
  @moduledoc """
  Durable record of a single worker run.

  Created when an `Arbiter.Worker` GenServer initialises (state `:starting`),
  kept in step with the worker's state, and stamped `:finished` with an
  `outcome` when the run ends (see `Arbiter.Workers.RunState`). The worker
  treats both writes as best-effort: a DB hiccup logs a warning but never
  crashes the workflow runner.

  `task_title` is denormalised so the dashboard's history list never needs to
  join against `issues` on every render. `kind` records what the run did for
  its ticket (`:implement` / `:review` / `:fix_pass` / `:conflict`) so a task's history
  shows *who* worked it at each step; `model` records the resolved agent model
  id once the session stream reports it.

  `output_lines` stores the captured Claude / subprocess stdout, capped at
  `@max_output_lines` (see `Arbiter.Worker`) to keep the row size sane. This
  is the bounded *tail* for the UI — the **full, uncapped** transcript is
  persisted append-only to an on-disk per-run file by
  `Arbiter.Worker.OutputLog` (path `<output_log_root>/<id>.log`) and is the
  audit source of record. Retrieve it with `arb worker log <task-id>` or
  `GET /api/workers/:task_id/log`.

  ## Provenance (bd-dzz6ly)

  `resolved_skills`, `standing_orders_digest`, `routing_policy`, `model_tier`,
  `thinking`, and `difficulty_at_dispatch` record *what governed* the run, not
  just what happened — so "which runs had skill X active, grouped by outcome"
  is answerable without reading a transcript. Provenance recording started
  2026-07-29; runs before that date have these fields `nil` (backfill is out
  of scope — nil means "predates provenance," not "nothing applied").
  """

  use Ash.Resource,
    otp_app: :arbiter,
    domain: Arbiter.Workers,
    data_layer: AshSqlite.DataLayer

  # bd-1uu19b (ticket lifecycle 5/13): the run vocabulary is shared with the
  # worker GenServer — see `Arbiter.Workers.RunState`. A run is one attempt at
  # a ticket: its `kind`, its `state`, and once finished its `outcome`.
  #
  # The old statuses fold in as the 5/13 migration did: a review park
  # (bd-9zuvbh) and a review that never started (bd-8tjcms) are `finished` /
  # `failed`, their cause in `failure_reason` (and on the ticket's
  # `attention_cause`). A run whose worker was shut down WITH the node
  # (bd-aje6fj) is `finished` / `interrupted`, "server shutdown"; one that
  # missed that path is swept to `finished` / `interrupted`, "server
  # restarted", by `Arbiter.Workers.Reconciler` on the next boot.
  #
  # `kind` folds the old `worker_type`: `:main` (the authoring worker) and
  # `:impl` (the ReviewGate's revise-round implementer) are both `:implement`.
  # `role` (bd-5fhyry) still tells them apart — "base" vs "impl".
  @kinds Arbiter.Workers.RunState.kinds()
  @states Arbiter.Workers.RunState.states()
  @outcomes Arbiter.Workers.RunState.outcomes()

  sqlite do
    table "worker_runs"
    repo Arbiter.Repo

    custom_indexes do
      # Powers "finished runs for workspace W, optionally filtered by
      # state, newest first" — the dashboard's primary query shape.
      index [:workspace_id, :state, :started_at]

      # Powers "all runs for task T, newest first" — the per-task history list
      # surfaced by `GET /api/workers/history?task_id=…` and `arb worker runs`.
      index [:task_id, :started_at]

      # Powers "all runs sorted by started_at, newest first" — the general list
      # reads behind GET /api/workers/history without task_id filter (bd-a8w4xb).
      index [:started_at]

      # Powers "how did runs die, grouped by typed category" without a scan
      # (bd-apwfmy).
      index [:stop_category]
    end
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      primary? true

      accept [
        :task_id,
        :task_title,
        :repo,
        :workspace_id,
        :kind,
        :model,
        :state,
        :outcome,
        :started_at,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :failure_summary,
        :resumed_from_run_id,
        :mr_ref,
        :merger_url,
        :session_id,
        :config_dir,
        :cgroup_scopes,
        :difficulty_at_dispatch,
        :resolved_skills,
        :standing_orders_digest,
        :routing_policy,
        :model_tier,
        :thinking,
        :floor_clamped,
        :stop_category,
        :base_task_id,
        :role,
        :provider,
        :provider_fallback,
        :provider_account_id,
        :node_id,
        :model_family,
        :routing_decision,
        :guardrail_decision,
        :harness_version
      ]
    end

    update :update do
      primary? true
      require_atomic? false

      accept [
        :state,
        :outcome,
        :model,
        :completed_at,
        :exit_code,
        :output_lines,
        :failure_reason,
        :failure_summary,
        :task_title,
        :mr_ref,
        :merger_url,
        :session_id,
        :config_dir,
        :cgroup_scopes,
        :resolved_skills,
        :standing_orders_digest,
        :routing_policy,
        :model_tier,
        :thinking,
        :floor_clamped,
        :prompt_sha256,
        :result_subtype,
        :result_is_error,
        :result_message,
        :stop_category,
        :base_task_id,
        :role,
        :provider,
        :provider_fallback,
        :provider_account_id,
        :node_id,
        :model_family,
        :routing_decision,
        :guardrail_decision,
        :harness_version
      ]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :task_id, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
      description "The task this worker worked."
    end

    attribute :task_title, :string do
      public? true
      constraints max_length: 1000
      description "Denormalised task title; nil if the task was already gone."
    end

    attribute :repo, :string do
      allow_nil? false
      public? true
      constraints max_length: 255, trim?: true
    end

    attribute :workspace_id, :string do
      public? true
      constraints max_length: 255, trim?: true
      description "Workspace scope. Nullable for ad-hoc runs with no workspace."
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :implement
      constraints one_of: @kinds

      description "What the run did for its ticket: :implement (authoring, or a " <>
                    "review-gate revise round), :review (review-gate or review-only " <>
                    "reviewer), :fix_pass (CI fix pass) or :conflict (conflict resolver)."
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      default :starting
      constraints one_of: @states
      description "Where the run is: :starting, :working, :waiting or :finished."
    end

    attribute :outcome, :atom do
      public? true
      constraints one_of: @outcomes

      description "How a finished run ended: :succeeded, :failed, :interrupted or " <>
                    ":handed_off (superseded by a follow-up run). Nil until finished."
    end

    attribute :model, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Resolved agent model id for the run (e.g. \"claude-opus-4-8\"); " <>
                    "nil for a no-agent run or before the stream reports one."
    end

    attribute :provider, :string do
      public? true
      constraints max_length: 64, trim?: true

      description ~s|Resolved agent provider for the run ("claude", "gemini", "codex"); | <>
                    "nil for a no-agent run or before the stream reports one."
    end

    attribute :provider_fallback, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Recorded fallback explanation when the original provider was unavailable; " <>
                    "nil when no fallback occurred."
    end

    attribute :harness_version, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The agent CLI's version for the run (e.g. \"2.1.296\"), as the session " <>
                    "reported it or the host binary answered; nil when neither said. A " <>
                    "change resets the subject's trust promotion clock (G18)."
    end

    attribute :provider_account_id, :uuid do
      public? true

      description "The provider account routing chose for this run (bd-40pzpj); " <>
                    "nil when the workspace does not route by quota."
    end

    attribute :node_id, :uuid do
      public? true

      description "The remote node the run was placed on (RW8, `Arbiter.Nodes.Placement`); " <>
                    "nil for a run on the primary."
    end

    attribute :model_family, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "Model family of the routed account and model (anthropic / google / " <>
                    "openai …, `Arbiter.Agents.ModelFamily`); nil when not routed."
    end

    attribute :routing_decision, :map do
      public? true

      description "The provider routing decision this run was spawned under (bd-40pzpj): " <>
                    "the chosen account, per-candidate headroom, dropped candidates with " <>
                    "their reasons, and any fallback or override. nil when not routed."
    end

    attribute :guardrail_decision, :map do
      public? true

      description "The guardrail decision this run was spawned under (bd-atll60, G13): the " <>
                    "subject, its tier, a digest of the effective profile, the permissions " <>
                    "projected or withheld and any optional permission dropped to dispatch. " <>
                    "nil when no subject rule is configured."
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
    end

    attribute :exit_code, :integer do
      public? true
      description "Subprocess exit status; nil if no subprocess (or still running)."
    end

    attribute :output_lines, {:array, :string} do
      public? true
      default []
      description "Captured stdout lines (capped — see worker write path)."
    end

    attribute :failure_reason, :string do
      public? true
      constraints max_length: 2000
    end

    # bd-2ddf2x: `failure_reason` is a short atom-as-string for the
    # ReviewGate-rejection path ("review_gate_rejected" / "review_gate_inconclusive"),
    # kept that way deliberately — `Loop.FailureClassifier`, `Loop.Corpus.rejected?/1`,
    # and `Loop.Analysis` all pattern-match its exact value. `failure_summary` is
    # the bounded human-readable twin (VERDICT line + top finding, ~280 chars) so
    # "why did this fail" is answerable from `worker_runs` alone, without a
    # separate `review_gate_rounds_list` call.
    #
    # bd-1eb6fc: also carries a non-failure note on a `:succeeded` run — `arb
    # done` fired while a background task the worker had last checked was
    # still RUNNING (`Worker.note_tasks_running_at_done/1`). Nothing in this
    # codebase branches on "non-nil ⇒ failed" (checked at bd-1eb6fc time —
    # every reader just surfaces the field alongside the outcome), so this
    # stays a single column rather than an outcome-keyed pair; a reader that
    # distinguishes "why did this fail" from "what should I know about this
    # run" must check `outcome` too, same as it already must for
    # `failure_reason` on an `:interrupted` run (see
    # `ArbiterCli.Cmd.Worker.reason_label/1`).
    attribute :failure_summary, :string do
      public? true
      constraints max_length: 300

      description "Bounded human-readable summary (truncated). On a run that failed via " <>
                    "ReviewGate rejection: the VERDICT line + top finding. On a completed " <>
                    "run: a non-failure completion note (e.g. arb done fired with a " <>
                    "background task still RUNNING). Nil otherwise — check `outcome` to " <>
                    "tell which case applies."
    end

    attribute :resumed_from_run_id, :uuid do
      public? true

      description "The prior run this run resumed from (bd-auma3z). Nullable; set only " <>
                    "when an worker was resumed via `arb resume` rather than slung fresh, " <>
                    "so the lineage of a stopped→resumed task is traceable and metrics " <>
                    "don't double-count a single task's work as two unrelated runs."
    end

    attribute :mr_ref, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The PR/MR ref this run opened or adopted (bd-6h4ia3). Nullable; a run " <>
                    "that never reached the merge step (or failed before opening one) has " <>
                    "no ref. Lets the task detail page show the full history of MRs a task " <>
                    "went through across its worker runs, not just the task's current " <>
                    "pr_ref (which is overwritten on each new MR)."
    end

    attribute :merger_url, :string do
      public? true
      constraints max_length: 2000, trim?: true
      description "Clickable link for mr_ref, resolved at record time (best-effort)."
    end

    # bd-au3xrq (Claude) / bd-6nupvc T9 (agy): identifying coordinates for this
    # run's on-disk session — Claude Code's session JSONL
    # (`<config_dir>/projects/<slug>/<session_id>.jsonl`) or agy's conversation
    # SQLite db (`<config_dir>/.gemini/antigravity-cli/conversations/<session_id>.db`)
    # — captured so `Arbiter.Usage.ClaudeSessionFile` / `Arbiter.Usage.GeminiSessionFile`
    # can reconcile from disk (Claude token usage when the primary stdout path
    # missed it; either provider's `Arbiter.Worker.SessionArchive`). Both
    # nullable: a run on neither provider, or one that died before its
    # session ever opened, has no coordinates to record.
    attribute :session_id, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "Session id: Claude Code's (== CLAUDE_CODE_SESSION_ID == the on-disk " <>
                    "session JSONL filename), or agy's conversation id (== the on-disk " <>
                    "<session_id>.db filename). Nullable; set once the session's init event " <>
                    "lands."
    end

    attribute :config_dir, :string do
      public? true
      constraints max_length: 2000, trim?: true

      description "Effective config root the worker spawned under: CLAUDE_CONFIG_DIR for " <>
                    "Claude, or the isolated $HOME for agy (workers use an isolated dir, not " <>
                    "~/.claude or the operator's own $HOME). Roots the on-disk session lookup."
    end

    # bd-6zuoo6: the systemd scope each spawn of this run ran in
    # (`Arbiter.Worker.MemoryScope`). A kernel OOM line names the victim's
    # cgroup, and this is how that name maps back to a task and a run.
    attribute :cgroup_scopes, {:array, :string} do
      public? true

      description "Transient systemd scope unit names (arb-run-<task>-<hex>.scope), one per " <>
                    "agent spawn of this run, in spawn order. A kernel OOM / journal line that " <>
                    "names one of these identifies the run. Nil when the run was not spawned " <>
                    "in a scope (memory cap disabled or unavailable) or predates the column."
    end

    # ---- Run provenance (bd-dzz6ly) ---------------------------------------
    #
    # What GOVERNED this run, not just what happened. Populated best-effort,
    # in two waves: `difficulty_at_dispatch` is known before the worker even
    # starts (stamped into `record_run_started/1`'s create attrs from meta);
    # the rest are resolved later in the dispatch/spawn path (routing choice,
    # materialized skills, workspace config) and backfilled via the same
    # `:report` -> DB-patch path `:model` already uses. Nil on any run that
    # predates this column (added 2026-07-29) — backfill is explicitly out of
    # scope; a nil provenance field simply means "before we started recording
    # it," not "nothing applied."
    attribute :resolved_skills, {:array, :map} do
      public? true
      default []

      description "Effective post-layering skill set (workspace -> repo -> task) active " <>
                    ~s(for this run: [{"name", "activation_mode", "skill_version"}, ...]. ) <>
                    "\"skill_version\" is the skill's updated_at at dispatch time, so a later " <>
                    "edit to the skill body doesn't retroactively relabel this run's provenance."
    end

    attribute :standing_orders_digest, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "SHA-256 hex digest of the workspace's effective standing_orders text at " <>
                    "dispatch time. Nil when the workspace has no standing_orders configured. " <>
                    "Provenance only: standing_orders is never injected into this run's prompt " <>
                    "(it's coordinator-facing config, surfaced in `arb prime`) — this digest " <>
                    "exists so outcomes can be correlated against config changes, not to record " <>
                    "something that shaped the run's behaviour."
    end

    attribute :routing_policy, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "Which routing policy decided the model/tier for this run " <>
                    ~s[("static" / "by_priority" / "by_difficulty" / "by_budget" / ] <>
                    ~s("round_robin" / "review_agent" — the last for a ReviewGate reviewer, ) <>
                    "which is configured directly rather than routed)."
    end

    attribute :floor_clamped, :boolean do
      public? true

      description "Whether a routing floor (`Arbiter.Agents.Floors`, bd-c675ny) raised the " <>
                    "tier this run was dispatched at. A clamped dispatch did not get the rule " <>
                    "its policy or canary arm assigned, so `Canary.Metrics` excludes it. " <>
                    "nil on a run that predates the column, which reads as not clamped."
    end

    attribute :model_tier, :string do
      public? true
      constraints max_length: 32, trim?: true

      description ~s[Resolved abstract tier ("economy" / "standard" / "premium"), not just ] <>
                    "the concrete model string already captured in :model."
    end

    attribute :thinking, :string do
      public? true
      constraints max_length: 32, trim?: true

      description ~s[Resolved abstract reasoning effort ("none" / "low" / "medium" / "high" / "xhigh" / "max").]
    end

    attribute :difficulty_at_dispatch, :integer do
      public? true
      # #1519: must track `Issue.difficulty`'s ceiling — a D5 dispatch that
      # could not record its own provenance would be invisible to exactly the
      # cost analysis that motivated the tier.
      constraints min: 0, max: 5

      description "The task's Issue.difficulty AT THE TIME this run was dispatched. A task's " <>
                    "difficulty can be edited later (bd-7rspia was corrected D1 -> D2 after the " <>
                    "fact) — reading the current issues.difficulty would silently attribute a " <>
                    "run to the corrected estimate rather than the one it actually ran under, " <>
                    "which would make difficulty-calibration analysis dishonest."
    end

    # ---- Prompt + result persistence (bd-9rdwe4) --------------------------
    #
    # What the agent was TOLD and how it actually ended, not just the
    # subprocess exit code. `prompt_sha256` anchors the redacted composed
    # prompt persisted alongside the transcript
    # (`Arbiter.Worker.PromptLog.path_for/1`); the `result_*` trio is the
    # structured terminal record pulled off the stream-json `result` event
    # (`Arbiter.Worker.ClaudeSession.absorb_usage/2`), so "what verdict did
    # runs under skill X reach" is answerable without an LLM re-reading a
    # transcript. Nil for a non-Claude / crashed / workflow-mode run — see
    # this migration's moduledoc for the graceful-degradation cases.
    attribute :prompt_sha256, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "SHA-256 hex of the redacted composed prompt persisted to " <>
                    "<output_log_root>/<run_id>.prompt, so identical prompts are cheaply " <>
                    "comparable without fetching the file."
    end

    attribute :result_subtype, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The terminal stream-json `result` event's `subtype` (e.g. \"success\", " <>
                    ~s["error_max_turns", "error_during_execution") — the CLI's own ] <>
                    "outcome/verdict, distinct from the subprocess exit_code."
    end

    attribute :result_is_error, :boolean do
      public? true
      description "The terminal event's `is_error` flag."
    end

    attribute :result_message, :string do
      public? true
      constraints max_length: 20_000

      description "The terminal event's final assistant-facing text, redacted the same as " <>
                    "transcript lines. Truncated at 20,000 chars to keep the row bounded — " <>
                    "the full, untruncated transcript remains the audit source of record."
    end

    # bd-apwfmy: `failure_reason` above is `StopReason.summary` — the English
    # sentence. `Arbiter.Worker.StopReason.classify/2` computed a typed
    # `category` alongside it, at the moment of death and with the whole
    # captured output in hand, and Arbiter then threw the type away and made
    # every later consumer (`Loop.FailureClassifier`, `Worker.Dispatch`'s
    # context-thrash resume guard) re-derive it with a regex over transcript
    # prose. Keep the type. Nil on runs that ended any other way (a clean
    # completion, a review-gate rejection) and on runs predating the column.
    attribute :stop_category, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The run's typed terminal cause, stored as an atom name: an " <>
                    ~s[Arbiter.Worker.StopReason category ("auth_expired", "context_thrash", ] <>
                    "\"exited_without_done\", ...) or, for a worker parked by the commit gate, " <>
                    "that gate's reason (\"uncommitted_at_completion\", ...). The structured " <>
                    "twin of failure_reason's prose; nil when the run ended in neither."
    end

    # ---- Parent/role hierarchy (bd-5fhyry) ----------------------------------
    #
    # Replace suffix-encoded task-id hierarchy (`<base>#review`, `<base>#review#impl1`)
    # with real columns: `base_task_id` (the root task) plus `role` (denoting the
    # run's purpose: base/review/impl/etc), so hierarchy stops being string surgery
    # that a `WHERE task_id = ...` silently drops.
    attribute :base_task_id, :string do
      public? true
      constraints max_length: 255, trim?: true

      description "The root task id this run is part of (for ReviewGate review/impl " <>
                    "passes, this is the base task; for base runs, it equals task_id). " <>
                    "Nullable for now; populated for new runs and backfills."
    end

    attribute :role, :string do
      public? true
      constraints max_length: 64, trim?: true

      description "The role this worker played in the task's lifecycle: 'base' for the " <>
                    "main authoring run, 'review' for review-gate reviewer, 'impl' for " <>
                    "review-gate implementer, etc. Replaces suffix-encoded task_id hierarchy."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  # ---- introspection -----------------------------------------------------

  @doc "All valid run kinds, in lifecycle order."
  def kinds, do: @kinds

  @doc """
  How many CI fix passes (`:fix_pass` runs) `task_id` has had on PR `mr_ref`.

  The Watchdog's per-task fix-pass cap reads this (bd-2l0hzm). Its own
  auto-resolve counter is per *episode*: every fix-pass push clears the block
  while the new head's CI runs, and a re-dispatched primary starts a fresh
  Watchdog. So a flake on each new head never reached the limit. This count
  survives both.

  Fix-pass rows carry no `mr_ref` of their own, so "on this PR" means started
  at or after the task's earliest run that does carry `mr_ref`. When no run
  carries it (or `mr_ref` is nil), every fix pass on the task counts. Returns 0
  when the read fails. The Watchdog also keeps an in-memory count, so a failed
  read does not disable the cap.
  """
  @spec fix_pass_count(String.t(), String.t() | nil) :: non_neg_integer()
  def fix_pass_count(task_id, mr_ref) when is_binary(task_id) do
    require Ash.Query

    query =
      Ash.Query.filter(
        __MODULE__,
        (task_id == ^task_id or base_task_id == ^task_id) and kind == :fix_pass
      )

    query =
      case pr_first_started_at(task_id, mr_ref) do
        %DateTime{} = since -> Ash.Query.filter(query, started_at >= ^since)
        nil -> query
      end

    Ash.count!(query)
  rescue
    _ -> 0
  end

  defp pr_first_started_at(_task_id, nil), do: nil

  defp pr_first_started_at(task_id, mr_ref) do
    require Ash.Query

    __MODULE__
    |> Ash.Query.filter((task_id == ^task_id or base_task_id == ^task_id) and mr_ref == ^mr_ref)
    |> Ash.Query.sort(started_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:started_at])
    |> Ash.read!()
    |> case do
      [%{started_at: started_at}] -> started_at
      [] -> nil
    end
  end

  @doc """
  Find the provider of the most recent authoring worker run for `task_id`.

  Strips synthetic suffixes (`#review`, `#impl<N>`, `:fixpass`, `:conflict`) to
  locate the root task. Considers only authoring kinds (`:implement`,
  `:fix_pass`, `:conflict`), explicitly excluding `:review` runs (which are
  governed by `review_agent.type`).

  bd-2exkl0 (finding 4): prefers the most recent row whose `provider_fallback`
  is nil — i.e. a run that actually got the originally-intended provider,
  not one that itself had to fall back. Without this, a single round where
  the intended provider was briefly unavailable (credentials flagged
  expired) would get silently "adopted" as the new original on every
  subsequent round: round 2 would read round 1's fallback provider as if it
  were the real original, report no fallback (because round 2 *did* get the
  provider it asked for — round 1's fallback provider), and never attempt to
  return to the real original once it recovered. Only when every authoring
  run on record is itself a fallback do we fall back to the latest of those.

  Falls back to `Arbiter.Usage.Event` when historical run rows predate the
  `provider` column. Returns `nil` when no prior authoring provider is found.
  """
  @spec latest_authoring_provider(String.t()) :: atom() | nil
  def latest_authoring_provider(task_id) when is_binary(task_id) do
    base_id =
      task_id
      |> String.split("#", parts: 2)
      |> List.first()
      |> String.replace(~r/:(fixpass|fix_pass|conflict)$/, "")

    case query_latest_run_provider(base_id) do
      p when is_atom(p) and not is_nil(p) ->
        p

      nil ->
        query_latest_usage_provider(base_id)
    end
  rescue
    _ -> nil
  end

  defp query_latest_run_provider(base_id) do
    case query_latest_run_provider(base_id, require_no_fallback: true) do
      p when is_atom(p) and not is_nil(p) -> p
      nil -> query_latest_run_provider(base_id, require_no_fallback: false)
    end
  end

  defp query_latest_run_provider(base_id, require_no_fallback: require_no_fallback?) do
    require Ash.Query

    base_filter =
      Ash.Query.filter(
        __MODULE__,
        (task_id == ^base_id or base_task_id == ^base_id) and
          kind in [:implement, :fix_pass, :conflict] and
          not is_nil(provider)
      )

    query =
      if require_no_fallback? do
        Ash.Query.filter(base_filter, is_nil(provider_fallback))
      else
        base_filter
      end

    query
    |> Ash.Query.sort(started_at: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %{provider: p} when is_binary(p) and p != "" -> safe_provider_atom(p)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp query_latest_usage_provider(base_id) do
    require Ash.Query

    Arbiter.Usage.Event
    |> Ash.Query.filter(
      (task_id == ^base_id or contains(task_id, ^base_id)) and
        not is_nil(provider)
    )
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> List.first()
    |> case do
      %Arbiter.Usage.Event{provider: p} when is_binary(p) and p != "" -> safe_provider_atom(p)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp safe_provider_atom(p) do
    String.to_existing_atom(p)
  rescue
    ArgumentError -> nil
  end
end
