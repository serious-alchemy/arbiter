defmodule Arbiter.MCP.Tools do
  @moduledoc """
  The `Arbiter.MCP` tool handlers — the agent-native route back into the domain.
  Each handler calls Ash directly (the same actions the REST controllers and
  `arb` subcommands take) and returns plain, JSON-friendly maps.

  Phase 1 ships the read tools plus the one narrowed worker write
  (`ticket_update_progress`); Phase 2 adds the coordinator-only mutating tools —
  `ticket_create` / `ticket_update` / `ticket_close` / `ticket_reopen`, `dep_add` /
  `dep_remove` (grouping/epics use a `parent_of` edge), the `worker_*` lifecycle family
  (`worker_dispatch` / `worker_resume` / `worker_review` / `worker_stop` /
  `worker_list`), `message_send`, `notify_list`, the `tracker_*` bridge
  (`tracker_claim` / `tracker_sync`), `workspace_list`, and `usage_summarize`
  (see `docs/mcp-server-design.md` §8). The worker-dispatch tools
  (`worker_dispatch` / `worker_resume` / `worker_review`) carry the
  dispatch-recursion guardrail (`can_dispatch` + `depth`, §4.3).

  Handlers take `(scope, arguments)` where `scope` is an `Arbiter.MCP.Scope` and
  `arguments` is the decoded `tools/call` arguments object (string keys). They
  return:

    * `{:ok, map}` — structured result (serialized to `structuredContent`);
    * `{:error, {:unauthorized, msg}}` — a scope violation (the transport maps it
      to a JSON-RPC error, per `docs/mcp-server-design.md` §4.2);
    * `{:error, {:not_found | :invalid | :conflict | :busy | :internal, msg}}` — an operational failure
      (returned as an `isError: true` tool result so the agent gets a usable
      message).

  Tier-level visibility (which tier may call which tool) is enforced upstream in
  `Arbiter.MCP.Catalog`; these handlers enforce the *data-level* rules —
  own-task and workspace isolation — via `Arbiter.MCP.Scope`.

  Most handlers live directly on this module, but seven tool groups are split into
  submodules to keep this file a manageable size — this module `defdelegate`s
  their public functions so `Arbiter.MCP.Catalog`'s `&Tools.function/2` captures
  and every existing caller keep working unchanged:

    * `Arbiter.MCP.Tools.Skills` — `skill_*`
    * `Arbiter.MCP.Tools.LoopPending` — `loop_pending_*`
    * `Arbiter.MCP.Tools.MemoryPending` — `memory_pending_*` / `memory_quarantine_*`
    * `Arbiter.MCP.Tools.Task` — `ticket_show` / `ticket_ready` / `ticket_update_progress` /
      `ticket_create` / `ticket_update` / `ticket_close` / `ticket_reopen` /
      `ticket_sync_upstream_close` / `dep_add` / `dep_remove`
    * `Arbiter.MCP.Tools.Workspace` — `workspace_show` / `workspace_config_*` /
      `installation_config_*`
    * `Arbiter.MCP.Tools.Messaging` — `inbox_check` / `coordinator_inbox` /
      `message_send` / `notify_list`
    * `Arbiter.MCP.Tools.Worker` — the `worker_*` lifecycle family, `run_log_list`,
      `transcript_capture_stats`

  This module still owns the generic arg/serialization helpers those submodules
  call back into (`fetch_string`, `authorized_workspace`, `serialize_task_summary`,
  etc), plus every tool group not split out above.
  """

  alias Arbiter.Agents.SecurityPolicy
  alias Arbiter.MCP.Scope
  alias Arbiter.ReviewGate.Resolutions
  alias Arbiter.ReviewGate.RoundsReport
  alias Arbiter.Reviews.Listing
  alias Arbiter.Reviews.Params, as: ReviewParams
  alias Arbiter.Reviews.Serializer
  alias Arbiter.Tasks.Claim
  alias Arbiter.Tasks.Dependency
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.IssueSerializer
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Lifecycle.Projection
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Tasks.Workspaces
  alias Arbiter.Trackers
  alias Arbiter.Usage

  require Ash.Query
  require Logger

  # ---- quota_get ----------------------------------------------------------

  @doc """
  Current quota state for the scope's workspace. Resolution mirrors
  `workspace_show`.

  This is a pure DB read (bd-ajh7bd): every provider's figures are read from the
  persisted quota tables, kept fresh by the background `Arbiter.Quota.CloudProbe`
  polling (`/api/oauth/usage` for Anthropic, and similar endpoints for Codex /
  Antigravity). Nothing here fetches live, so there's no
  request-time latency or rate-limit exposure.

  `claude` is the latest polled snapshot, including per-model weekly breakdowns
  and `extra_usage` overage spend, and `gating_window` / `gating_reason` naming
  which window (if any) is currently holding dispatch (bd-1tuxv8) — both the 5h
  and the 7d figures are reported, but only one of them, or neither, is what the
  gate is acting on. `nil` until the first poll. `codex` is `nil` with a
  `codex_message` until the Codex probe has stored a snapshot (i.e. the `codex`
  CLI is authenticated on this host); once stored it also reports the pacing
  state (`elapsed_fraction`, `used_fraction`, `gating_reason`, `pacing`;
  bd-afvsnc). `antigravity` is the persisted agy
  `/usage` snapshot (`nil` until the probe has stored one);
  `gemini_credentials_expired` is the `Arbiter.Agents.Gemini` adapter's
  (agy's) held credential state. The upstream Gemini CLI's `gemini` snapshot
  is gone with its provider (bd-ac53wz).
  """
  @spec quota_get(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def quota_get(%Scope{} = scope, args) do
    case fetch_string(args, "account") do
      nil -> quota_for_workspace(scope, args)
      ref -> quota_for_account(scope, ref)
    end
  end

  # `account` goes straight to that account's quota, the way REST `?account=`
  # does (`Arbiter.Quota.Snapshot.for_account/1`, the REST `data` map). An account
  # is installation-wide, so only a coordinator may name one.
  defp quota_for_account(%Scope{tier: :coordinator}, ref) do
    case Arbiter.Accounts.get_account(ref) do
      {:ok, account} ->
        {:ok, Arbiter.Quota.Snapshot.for_account(account)}

      {:error, :not_found} ->
        {:error, {:not_found, "account #{inspect(ref)} not found"}}

      {:error, :ambiguous} ->
        {:error, {:invalid, "account #{inspect(ref)} is ambiguous; use \"provider:slug\""}}
    end
  end

  defp quota_for_account(%Scope{}, _ref),
    do:
      {:error,
       {:unauthorized, "quota_get `account` is coordinator-only; omit it to read your workspace"}}

  defp quota_for_workspace(%Scope{} = scope, args) do
    with {:ok, ws_id} <- Workspaces.resolve_default(scope, fetch_string(args, "workspace")) do
      # One builder shared with `GET /api/quota` (P-18, D-A-5).
      {:ok, Arbiter.Quota.Snapshot.for_workspace(ws_id, fetch_string(args, "workspace"))}
    end
  end

  # ---- external_review_list -----------------------------------------------

  @doc """
  List recent ExternalReview audit records for a workspace (bd-31fh9e, bd-bs5b12).
  Coordinator only. Returns records newest-first wrapped under the :external_reviews key
  (consistent with other MCP list tools: tasks, workers, skills). Note: the REST
  endpoint `GET /api/external_reviews` uses the :data key instead — this deliberate
  asymmetry is intentional (Option 3 in bd-bs5b12): each transport follows its own
  convention for consistency within that transport. Optional `limit` (default 20,
  max 200), `status` and `since` (ISO 8601) filters, and `workspace` (resolved the same way as
  `worker_list`/`ticket_ready` — explicit arg, else the bound workspace, else
  ALL workspaces; the response echoes `workspace_id`).
  """
  @spec external_review_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def external_review_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- authorized_workspace(scope, args),
         {:ok, limit} <- Listing.parse_limit(Map.get(args, "limit")),
         {:ok, status} <- Listing.parse_status(Map.get(args, "status")),
         {:ok, since} <- Listing.parse_since(Map.get(args, "since")) do
      records =
        [workspace_id: ws_id, status: status, since: since, limit: limit]
        |> Listing.list()
        |> Enum.map(&Serializer.record/1)

      {:ok, %{external_reviews: records, count: length(records), workspace_id: ws_id}}
    end
  rescue
    e -> {:error, {:internal, "external_review_list failed: #{Exception.message(e)}"}}
  end

  # ---- external_review_show ------------------------------------------------

  @doc """
  Fetch a single ExternalReview audit record by `record_id` (bd-dmy4pk), including
  its full `proposed_comments` — so a report_only review's findings can be read
  before `review_greenlight`. Coordinator only. Workspace-agnostic: looked up
  directly by id, with no workspace filter, since the caller already has the
  specific record id (e.g. from a dispatch response or `external_review_list`).

  Also reports this review's durable-corpus state (bd-7efini):
  `transcript_exists`, `prompt_exists`, `transcript_line_count`,
  `tool_use_count` and `tools_used` — the same "is it retrievable, and how
  big" signal `run_log_list` gives a regular worker run. Fetch the corpus
  itself with `external_review_transcript`. The list tool deliberately does
  NOT carry these: they cost a disk read per record.
  """
  @spec external_review_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def external_review_show(%Scope{} = _scope, args) do
    with {:ok, record_id} <- require_string(args, "record_id") do
      case Listing.fetch(record_id) do
        {:ok, record} ->
          {:ok, Serializer.record(record, proposed_comments: true, transcript: true)}

        {:error, :not_found} ->
          {:error, {:not_found, "no external review record found for #{record_id}"}}
      end
    end
  rescue
    e -> {:error, {:internal, "external_review_show failed: #{Exception.message(e)}"}}
  end

  # ---- external_review_transcript ------------------------------------------

  @doc """
  Full durable corpus of one external review (bd-7efini, #1425): the composed
  prompt it was given, the raw `stream-json` transcript its reviewer emitted,
  and every tool call in that transcript paired with the result it returned.

  This is `worker_log`'s counterpart for a review. An external review is not
  task-linked — it has no `Arbiter.Workers.Run` row — so it can't be reached
  through `run_log_list`/`worker_log`'s task-scoped lookup; it is keyed on its
  own `Arbiter.Reviews.Record` id instead (see `Arbiter.Reviews.Transcript`).

  Coordinator only. Workspace-agnostic, like `external_review_show`.

    * `record_id` (required) — the review to read.
    * `tail` — return only the last N transcript lines (`truncated: true` when
      lines were dropped). Omit for the whole transcript; a tool-heavy review
      runs to thousands of JSONL lines.
    * `include_prompt` — set false to skip the (large) prompt.

  `exists` distinguishes "never captured" (a review that predates capture, or
  whose reviewer produced nothing) from "captured but empty".
  """
  @spec external_review_transcript(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def external_review_transcript(%Scope{} = _scope, args) do
    alias Arbiter.Reviews.Record, as: ExternalReviewRecord
    alias Arbiter.Reviews.Transcript

    with {:ok, record_id} <- require_string(args, "record_id"),
         {:ok, tail} <- optional_positive_integer(args, "tail") do
      case Ash.get(ExternalReviewRecord, record_id) do
        {:ok, %ExternalReviewRecord{} = record} ->
          # One read + one decode pass for summary, lines and tool uses alike.
          corpus = Transcript.corpus(record.id, preview: Transcript.default_preview())
          summary = corpus.summary
          {lines, truncated} = Transcript.tail(corpus.lines, tail)

          prompt =
            if fetch_optional_bool!(args, "include_prompt") == false do
              nil
            else
              # Pre-existing nesting 4 — baselined when bd-4x2yhq first
              # wired Credo up. Thresholds stay at the tool's own default so new
              # code is held to it; see the note in .credo.exs.
              # credo:disable-for-next-line Credo.Check.Refactor.Nesting
              case Transcript.prompt(record.id) do
                {:ok, prompt} -> prompt
                {:error, _} -> nil
              end
            end

          {:ok,
           %{
             record_id: record.id,
             pr_ref: record.pr_ref,
             pr: record.pr,
             workspace_id: record.workspace_id,
             status: record.status,
             model: record.model,
             path: summary.path,
             prompt_path: summary.prompt_path,
             exists: summary.exists,
             prompt_exists: summary.prompt_exists,
             prompt: prompt,
             line_count: summary.line_count,
             lines: lines,
             truncated: truncated,
             tool_use_count: summary.tool_use_count,
             tools_used: summary.tools_used,
             tool_uses: corpus.tool_uses
           }}

        _ ->
          {:error, {:not_found, "no external review record found for #{record_id}"}}
      end
    end
  rescue
    e -> {:error, {:internal, "external_review_transcript failed: #{Exception.message(e)}"}}
  end

  # ---- review_gate_rounds_list ---------------------------------------------

  @doc """
  List `Arbiter.ReviewGate.Round` rows for a task (bd-aqyjuc): one row per
  ReviewGate reviewer or implementer pass, oldest-first, so a round-1 rejection
  and a round-2 approval surface as two distinct rows rather than being
  collapsed into the task's terminal outcome. Coordinator only. Requires
  `task_id`. Backfill is out of scope — rows only exist for ReviewGate runs
  from 2026-07-28 onward.

  Optional `limit` (bd-dp7hiw) caps the response to the most recent N rounds
  (still returned oldest-first) so a task with many rounds/resumes doesn't
  force pulling the entire history just to see the latest one or two.
  Omitting it preserves the original full-history behavior; `total_count`
  always reports how many rounds exist regardless of `limit`.

  bd-954ym8: a scoped review of a hand-resolved merge/rebase conflict is its
  own `role: "conflict_review"` row, and `conflict_review` counts, for this
  ticket and fleet-wide, the clean rebases auto-covered with no round, the
  scoped reviews, and the fallbacks to a full review.

  bd-4qjl0q: also returns the coordinator's recorded answer to a gate
  escalation — `resolution` (the latest, or nil) and `resolutions` (all,
  oldest-first) — plus `outcome`: `"converged"`, `"resolved"`,
  `"not_converged"` or `"none"` (see `Arbiter.ReviewGate.Resolutions.outcome/2`),
  so a run that escalated and was amended no longer reads like one that
  converged.
  """
  @spec review_gate_rounds_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def review_gate_rounds_list(%Scope{} = _scope, args) do
    with {:ok, task_id} <- require_string(args, "task_id"),
         {:ok, limit} <- optional_bounded_limit(args, "limit", RoundsReport.max_limit()) do
      {:ok, RoundsReport.build(task_id, limit)}
    end
  rescue
    e -> {:error, {:internal, "review_gate_rounds_list failed: #{Exception.message(e)}"}}
  end

  # ---- review_gate_resolve -------------------------------------------------

  @doc """
  Record the coordinator's answer to a gate escalation (bd-4qjl0q): `decision`
  (`accept_as_is` / `amend` / `send_back` / `reject`), `reasoning`, and
  optionally `gate` (`review_gate` default, `notes_gate`, `commit_gate`),
  `round` / `fix_round_attempt` / `head_sha`. Coordinator only. Not an action,
  but the merge path reads it (`Arbiter.ReviewGate.MergeAuthorization`): only
  `accept_as_is` / `amend` permit a merge without a fresh reviewer APPROVE;
  `send_back` means another review round follows the implementer's completion.
  See `Arbiter.ReviewGate.Resolution`.
  """
  @spec review_gate_resolve(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def review_gate_resolve(%Scope{} = scope, args) do
    with {:ok, _task_id} <- require_string(args, "task_id"),
         {:ok, _decision} <- require_string(args, "decision"),
         {:ok, _reasoning} <- require_string(args, "reasoning"),
         {:ok, resolution} <-
           args
           |> Map.take(~w(task_id decision reasoning gate round fix_round_attempt head_sha))
           |> Map.put("actor", Arbiter.Params.actor_label(scope) || "coordinator")
           |> Resolutions.record() do
      {:ok, %{resolution: Resolutions.serialize(resolution)}}
    end
  rescue
    e -> {:error, {:internal, "review_gate_resolve failed: #{Exception.message(e)}"}}
  end

  defp optional_positive_integer(args, key) do
    with {:ok, n} <- optional_integer(args, key) do
      cond do
        is_nil(n) -> {:ok, nil}
        n > 0 -> {:ok, n}
        true -> {:error, {:invalid, "`#{key}` must be a positive integer"}}
      end
    end
  end

  # ---- review_greenlight --------------------------------------------------

  @doc """
  Greenlight a report-only review (bd-36qzgx): post the coordinator-approved
  subset of a review's proposed comments to the PR — and nothing else.
  Coordinator only. Backs onto `Arbiter.Reviews.ExternalReview.greenlight/1`.
  """
  @spec review_greenlight(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def review_greenlight(%Scope{} = scope, args) do
    with :ok <- ensure_can_dispatch(scope),
         :ok <- Arbiter.Worker.Dispatch.Params.ensure_depth(scope),
         {:ok, record_id} <- require_string(args, "record_id"),
         {:ok, opts} <- ReviewParams.greenlight_opts(record_id, args) do
      case Arbiter.Reviews.ExternalReview.greenlight(opts) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          {:error, {:invalid, Arbiter.Reviews.ExternalReview.describe_error(reason)}}
      end
    end
  end

  defp fetch_optional_bool!(args, key) do
    case Arbiter.Params.fetch_optional_bool(args, key) do
      {:ok, b} -> b
      {:error, _} -> nil
    end
  end

  # internal — shared by Arbiter.MCP.Tools.Worker (also used by external_review_list)
  def parse_bounded_limit(args, key, default, max) do
    case Arbiter.Params.limit(Map.get(args, key), default, max) do
      {:ok, n} -> {:ok, n}
      {:error, _} -> {:error, {:invalid, "#{key} must be a positive integer (max #{max})"}}
    end
  end

  # internal — an optional `limit` with no default (nil = no cap requested),
  # clamped to `max` when given.
  def optional_bounded_limit(args, key, max) do
    case Map.get(args, key) do
      nil -> {:ok, nil}
      _ -> parse_bounded_limit(args, key, max, max)
    end
  end

  # ---- task_list ----------------------------------------------------------

  @engagement_modes [:all, :exclude, :only]

  @doc """
  List tasks in the scope's workspace with optional filters. Coordinator only.
  Accepts optional `state` and `column` (the lifecycle vocabulary, bd-6fkgvo),
  `priority` and `issue_type` filters, and `engagements` (`all` | `exclude` |
  `only`, default `all`) for ReviewPatrol review engagements
  (`Arbiter.Tasks.Issue.engagement?`). The default stays inclusive — this is an
  API other agents consume, so no existing caller silently loses rows; the
  operator-facing lists hide engagements unconditionally (bd-crk6tb). Always
  scoped to the coordinator's workspace. Each task carries its projection
  (`Arbiter.Tasks.Lifecycle.Projection`): `state`, `column`, `step`,
  `blocked_by` and `attention`.
  """
  @spec task_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def task_list(%Scope{} = scope, args) do
    with {:ok, ws_id} <- authorized_workspace(scope, args),
         {:ok, state} <- optional_enum(args, "state", Lifecycle.states()),
         {:ok, column} <- optional_enum(args, "column", Projection.columns()),
         {:ok, issue_type} <- optional_enum(args, "issue_type", Issue.issue_types()),
         {:ok, priority} <- optional_integer(args, "priority"),
         {:ok, difficulty} <- optional_integer(args, "difficulty"),
         {:ok, engagements} <- optional_enum(args, "engagements", @engagement_modes) do
      issues =
        Issue
        |> filter_workspace(ws_id)
        |> filter_engagements(engagements)
        |> maybe_filter_state(state)
        |> maybe_filter_column_states(column)
        |> maybe_filter_issue_type(issue_type)
        |> maybe_filter_priority(priority)
        |> maybe_filter_difficulty(difficulty)
        |> Ash.read!()

      views = Projection.views(issues)

      rows =
        for issue <- issues,
            view = Map.fetch!(views, issue.id),
            is_nil(column) or view.column == column,
            do: {issue, view}

      {:ok, %{tasks: ready_rows(rows, ws_id), count: length(rows), workspace_id: ws_id}}
    end
  end

  # The summary rows, a Ready card the scheduler is holding carrying its
  # `hold_reason` (P-13, D-T-16) — shared by `ticket_list` and `ticket_ready`.
  # The board is only read when a Ready card is in the page.
  @doc false
  def ready_rows(rows, ws_id) do
    holds =
      if Enum.any?(rows, fn {_issue, view} -> view.column == :ready end),
        do: Arbiter.Tasks.ReadyHolds.for_workspace(ws_id),
        else: %{}

    for {issue, view} <- rows,
        do: IssueSerializer.row(IssueSerializer.summary(issue), view, Map.get(holds, issue.id))
  end

  # `nil` is "all workspaces" (`Workspaces.resolve/3`, `:read`).
  defp filter_workspace(query, nil), do: query
  defp filter_workspace(query, ws_id), do: Ash.Query.filter(query, workspace_id == ^ws_id)

  defp maybe_filter_state(query, nil), do: query
  defp maybe_filter_state(query, state), do: Ash.Query.filter(query, state == ^state)

  defp filter_engagements(query, :exclude), do: Issue.exclude_engagements(query)
  defp filter_engagements(query, :only), do: Issue.only_engagements(query)
  defp filter_engagements(query, _all), do: query

  # The stored states the column can come from; the projection decides.
  defp maybe_filter_column_states(query, nil), do: query

  defp maybe_filter_column_states(query, column) do
    states = Projection.states_for_column(column)
    Ash.Query.filter(query, state in ^states)
  end

  defp maybe_filter_issue_type(query, nil), do: query

  defp maybe_filter_issue_type(query, issue_type),
    do: Ash.Query.filter(query, issue_type == ^issue_type)

  defp maybe_filter_priority(query, nil), do: query

  defp maybe_filter_priority(query, priority),
    do: Ash.Query.filter(query, priority == ^priority)

  defp maybe_filter_difficulty(query, nil), do: query

  defp maybe_filter_difficulty(query, difficulty),
    do: Ash.Query.filter(query, difficulty == ^difficulty)

  # ---- usage_summarize ----------------------------------------------------

  @doc """
  Roll up the token/cost usage ledger for the scope's workspace. Coordinator
  only. `by` is required (one of `Arbiter.Usage.valid_groupings/0`, or the
  deprecated `campaign` alias for `epic`); `since` (ISO-8601) and `limit` are
  optional. `workspace_id` is forced to the scope's workspace. Backs onto
  `Arbiter.Usage.summarize/1`.

  `by: "source"` is the grouping that shows the whole bill: spend with no task
  (quota probes, auth pre-flights, coordinator/terminal sessions) is excluded
  from `by: "task"` by design (bd-adyhvn).

  Also surfaces a `warnings` list (bd-2fzwlc) when a provider's rows are
  wholly zero-token over the same `since`/workspace window — the same
  blindness `Arbiter.Loop.Analysis` flags in the loop report, so a
  coordinator reading this tool directly gets the same signal.
  """
  @spec usage_summarize(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def usage_summarize(%Scope{} = scope, args) do
    with {:ok, ws_id} <- authorized_workspace(scope, args),
         {:ok, by} <- require_enum(args, "by", Usage.acceptable_groupings()),
         {:ok, since} <- optional_datetime(args, "since"),
         {:ok, limit} <- optional_bounded_limit(args, "limit", 1000),
         {:ok, account_id} <- Usage.Params.account_id(fetch_string(args, "account")) do
      opts =
        [by: by, workspace_id: ws_id]
        |> maybe_put_kw(:since, since)
        |> maybe_put_kw(:limit, limit)
        |> maybe_put_kw(:provider_account_id, account_id)

      zero_token_opts =
        [workspace_id: ws_id]
        |> maybe_put_kw(:since, since)
        |> maybe_put_kw(:provider_account_id, account_id)

      with {:ok, rollups} <- Usage.summarize(opts),
           {:ok, flagged} <- Usage.zero_token_providers(zero_token_opts) do
        {:ok,
         %{
           by: Atom.to_string(Usage.normalize_by(by)),
           rollups: Enum.map(rollups, &Arbiter.Usage.Serializer.rollup/1),
           count: length(rollups),
           workspace_id: ws_id,
           warnings: Arbiter.Usage.Serializer.warnings(flagged)
         }}
      else
        {:error, reason} -> {:error, {:invalid, "usage_summarize failed: #{inspect(reason)}"}}
      end
    end
  end

  # ---- tracker_claim ------------------------------------------------------

  @doc """
  Claim an external tracker issue into a task (`arb claim`). Coordinator only.
  Fetches the issue by `ref` via the workspace's tracker, verifies it is
  assigned to the workspace user (the claim signal; skip with `force: true`),
  and creates a linked task. Idempotent — returns the existing task if one
  already references the issue. `difficulty` and `repo`, when given, override
  whatever `Arbiter.Tasks.Claim.claim/3` would otherwise derive from the issue
  (difficulty from labels) or leave unset (repo) — the same optional
  parameters `arb claim` accepts over the CLI/HTTP surface, so a caller never
  has to fall back to the CLI to set them. Backs onto
  `Arbiter.Tasks.Claim.claim/3`.
  """
  @spec tracker_claim(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_claim(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, ref} <- require_string(args, "ref"),
         {:ok, force} <- fetch_bool(args, "force", false),
         {:ok, workspace} <- fetch_workspace(ws_id),
         # P-13 (D-T-24): the same 0..5 pre-check REST makes, before any tracker call.
         {:ok, opts} <- Claim.claim_opts(args) do
      case workspace |> Claim.claim(ref, Keyword.put(opts, :force, force)) |> Claim.typed() do
        {:ok, status, task} -> {:ok, Claim.serialize_claim(status, task)}
        {:error, reason} -> {:error, claim_error(reason)}
      end
    end
  end

  # ---- tracker_list_issues ------------------------------------------------

  @doc """
  List the open tracker issues assigned to the workspace user (`arb ticket list
  --tracker`, REST `GET /api/workspaces/:id/tracker/issues`) — the refs
  `tracker_claim` needs (P-15). Coordinator only; the workspace resolves by the
  same P-04 rule as `tracker_claim`. A tracker with no backlog notion replies
  `supported: false` with no rows, as REST does.
  """
  @spec tracker_list_issues(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_list_issues(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, workspace} <- fetch_workspace(ws_id) do
      case Trackers.list_open(workspace) do
        {:ok, summaries} ->
          {:ok, %{data: Enum.map(summaries, &tracker_issue_row/1), supported: true}}

        {:error, :not_supported} ->
          {:ok, %{data: [], supported: false}}

        {:error, reason} ->
          {:error, claim_error(reason)}
      end
    end
  end

  defp tracker_issue_row(%{
         ref: ref,
         title: title,
         url: url,
         status: status,
         assignees: assignees
       }),
       do: %{
         ref: ref,
         title: title,
         url: url,
         status: Atom.to_string(status),
         assignees: assignees
       }

  # ---- tracker_create_ticket ----------------------------------------------

  @doc """
  Create an unclaimed ticket in the workspace's external tracker with no local
  task (`arb ticket create --ticket-only`, REST `POST
  /api/workspaces/:id/tracker/tickets`; P-15). Coordinator only. Backs onto
  `Arbiter.Trackers.create_ticket_only/2`.
  """
  @spec tracker_create_ticket(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_create_ticket(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, title} <- require_string(args, "title"),
         {:ok, workspace} <- fetch_workspace(ws_id) do
      attrs =
        %{title: title, description: fetch_string(args, "description")}
        |> Map.put(:priority, args["priority"])
        |> Map.put(:issue_type, fetch_string(args, "issue_type"))

      case Trackers.create_ticket_only(workspace, attrs) do
        {:ok, created} -> {:ok, created}
        {:error, {:invalid_request, _} = refusal} -> {:error, refusal}
        {:error, reason} -> {:error, claim_error(reason)}
      end
    end
  end

  # ---- tracker_sync -------------------------------------------------------

  @doc """
  Reconcile the workspace's tasks against its external tracker (`arb sync`): open
  assigned issues with no task get a linked task; open tasks whose issue is
  closed upstream or reassigned away get closed (an issue that is merely
  unassigned is left alone — bd-83ojwi); closed tasks whose close was meant to
  propagate upstream — a recorded close intent (bd-bsco7f), or for rows closed
  before that was recorded a non-blank `pr_ref` (bd-83ojwi) — but whose tracker
  issue is still open are reported as `drift` (bd-2wilou — a close that never
  propagated upstream). `task`-type and `review_only` tasks are exempt: they
  are expected to close with their ticket still open.
  Drift entries are report-only and never mutate the local task.
  Coordinator only. With `dry: true` the plan is returned without acting.
  No-ops cleanly when the tracker does not support reconciliation. Backs onto
  `Arbiter.Tasks.Claim.plan/1` + `apply_plan/2`.
  """
  @spec tracker_sync(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def tracker_sync(%Scope{} = scope, args) do
    with {:ok, ws_id} <- resolve_workspace_id(scope, args),
         {:ok, dry} <- fetch_bool(args, "dry", false),
         {:ok, workspace} <- fetch_workspace(ws_id),
         {:ok, plan} <- claim_plan(workspace) do
      # The REST shape (`Claim.serialize_sync/2`: `data`, `applied`, `results`),
      # plus the `actions` / `count` this tool has always carried.
      payload =
        if dry do
          Claim.serialize_sync(plan, :dry)
        else
          {:ok, results} = Claim.apply_plan(workspace, plan)
          Claim.serialize_sync(plan, results)
        end

      {:ok, Map.merge(payload, %{actions: payload.data, count: length(plan)})}
    end
  end

  # ---- workspace_list -----------------------------------------------------

  @doc """
  List the configured workspaces (id, name, prefix, tracker type). Coordinator
  only. This is a deliberate exception to the per-call workspace isolation every
  other tool enforces: it is a read-only *enumeration* of non-sensitive summary
  fields (no config, no security posture — those stay behind `workspace_show`
  for the bound workspace), the discovery surface the operator/coordinator needs
  to know which workspaces exist. Backs onto `Ash.read(Workspace)`.
  """
  @spec workspace_list(Scope.t(), map()) :: {:ok, map()}
  def workspace_list(%Scope{}, _args) do
    workspaces =
      Workspace
      |> Ash.read!()
      |> Enum.map(&serialize_workspace_summary/1)

    {:ok, %{workspaces: workspaces, count: length(workspaces)}}
  end

  # ---- queue_retry_auto_resolve --------------------------------------------

  @doc """
  Re-arm one more auto-resolve attempt on a task's merge Watchdog after it
  has exhausted `max_auto_resolve_attempts` on a `:ci_failed` block and
  parked indefinitely (bd-bspakl), or spent its `max_conflict_attempts`
  conflict passes and escalated (bd-4olwyg).

  Without this, once exhausted there is no supported way to try again short
  of pushing a fix to the branch by hand, outside Arbiter's normal
  worker/review flow. Calls `Arbiter.Worker.Watchdog.retry_auto_resolve/1`,
  which bumps this episode's budget by exactly one attempt; the next
  watchdog poll (within its poll interval) picks it up. No cap on how many
  times a coordinator calls this — but the Watchdog itself never re-arms on
  its own.

  Returns `%{retried: true, task_id: task_id}` on success, or an error if no
  Watchdog is running for the task, it isn't parked on an exhausted
  `:ci_failed` block or an exhausted conflict, or the Watchdog is busy (e.g. mid-poll) and didn't
  reply in time — in the last case, wait and retry rather than repeating the
  call immediately, since the original request may still land.
  """
  @spec queue_retry_auto_resolve(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def queue_retry_auto_resolve(%Scope{} = _scope, args) do
    with {:ok, task_id} <- require_string(args, "task_id") do
      case Arbiter.Worker.Watchdog.retry_auto_resolve(task_id) do
        :ok ->
          {:ok, %{retried: true, task_id: task_id}}

        {:error, :not_found} ->
          {:error, {:not_found, "no merge watchdog is currently running for task #{task_id}"}}

        {:error, :not_parked_on_ci_failed} ->
          {:error,
           {:conflict,
            "task #{task_id} is not currently parked on an exhausted :ci_failed block " <>
              "or an exhausted conflict auto-resolve — there is nothing to re-arm"}}

        {:error, :busy} ->
          {:error,
           {:busy,
            "task #{task_id}'s watchdog is busy polling — try again in a moment rather " <>
              "than repeating the call, since the original request may still land"}}
      end
    end
  end

  # ---- queue_restart_watchdog ----------------------------------------------

  @doc """
  Mint a **fresh** merge Watchdog for a Merging ticket whose Watchdog has died,
  started from the ticket's row (bd-8jixav, bd-741sid).

  A Watchdog is a `:temporary` process: when it crashes it is gone for good,
  silently, and the ticket stays Merging with a genuinely-open MR that nothing
  is polling. `queue_retry_auto_resolve` cannot help — it messages an
  already-running Watchdog and answers "not found" once the process is gone.
  This is the recovery for that state, and it is far cheaper than
  `worker_resume`, which restarts the review gate from round 1.

  Returns `%{restarted: true, task_id: task_id}` on success. Refusals, phrased
  by `Arbiter.Worker.Watchdog.restart_refusal/2`: no such ticket; a Watchdog is
  already running (refused rather than stacked — two Watchdogs on one MR would
  race the merge); the ticket is not Merging or has no PR on record; its merger
  adapter cannot be resolved; or the Watchdog failed to start.

  An explicit restart: a ticket pulled out of the merge queue
  (`Arbiter.Tasks.PullRequest.pull/1`) goes back in it (`clear_pull: true`).
  """
  @spec queue_restart_watchdog(Scope.t(), map()) ::
          {:ok, map()} | {:error, {atom(), String.t()}}
  def queue_restart_watchdog(%Scope{} = _scope, args) do
    with {:ok, task_id} <- require_string(args, "task_id") do
      case Arbiter.Worker.Watchdog.restart(task_id, clear_pull: true) do
        :ok ->
          {:ok, %{restarted: true, task_id: task_id}}

        {:error, reason} ->
          # `restart_refusal/2` speaks the shared taxonomy
          # (`:not_found | :conflict | :invalid | :internal`): pass the kind through.
          {:error, Arbiter.Worker.Watchdog.restart_refusal(task_id, reason)}
      end
    end
  end

  # ---- ci_rerun / ci_mark_external (bd-5mzzww / #1448) ---------------------

  @rerun_modes %{
    "auto" => :auto,
    "failed_jobs" => :failed_jobs,
    "all_jobs" => :all_jobs,
    "workflow" => :workflow
  }

  @doc """
  Re-run CI for a task's PR, choosing the *granularity* of the re-run.

  Arbiter had no CI-retry verb at all: the only retries available were whatever
  a human clicked in the forge UI. Worse, the affordance a human reaches for
  first — GitHub's "re-run failed jobs" — reuses every job that already
  succeeded, so on a pipeline where the failing check tests an artifact an
  *earlier job in the same run* built (a review app, a container image), it
  re-tests the identical stale input and is deterministically guaranteed to fail
  again.

  Modes: `auto` (default — `Arbiter.Mergers.CIRerun.choose/1` picks the cheapest
  re-run that could actually tell you something new), `failed_jobs`, `all_jobs`,
  `workflow` (a fresh `workflow_dispatch`, the only mode that can carry
  `inputs`) — passing `inputs` alongside `failed_jobs`/`all_jobs` is rejected
  rather than silently dropping them.

  Prefers the task's running Watchdog (it already holds the adapter, the PR ref
  and the per-repo config); falls back to resolving the adapter from the task's
  workspace when no Watchdog is running, so a PR whose Watchdog has died is
  still retryable.
  """
  @spec ci_rerun(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def ci_rerun(%Scope{} = scope, args) do
    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         # Workspace isolation for every path (watchdog and fallback alike).
         {:ok, _issue} <- fetch_task(scope, args, task_id),
         {:ok, mode} <- parse_rerun_mode(args),
         {:ok, inputs} <- parse_rerun_inputs(args) do
      opts =
        %{mode: mode, inputs: inputs}
        |> maybe_put(:workflow, fetch_string(args, "workflow"))

      case Arbiter.Worker.CIRerun.rerun(task_id, opts) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> rerun_error(reason, task_id)
      end
    end
  end

  defp rerun_error(reason, task_id) do
    message = Arbiter.Worker.CIRerun.describe_error(reason, task_id)

    case reason do
      :not_found -> {:error, {:not_found, message}}
      :unsupported -> {:error, {:conflict, message}}
      :busy -> {:error, {:busy, message}}
      {:failed, _} -> {:error, {:internal, message}}
      _no_pr_or_workspace -> {:error, {:invalid, message}}
    end
  end

  @doc """
  Record a "this CI failure is infrastructure, not my diff" verdict on a task
  parked on a `:ci_failed` block, reclassifying the park as
  `:ci_failed_external`.

  A worker that works this out — "the last four runs of this workflow across
  four unrelated branches all failed the same way, and nothing in this diff
  touches that code" — previously had nowhere to put the conclusion but its own
  task notes, and the Watchdog went on parking the PR under a generic
  `:ci_failed`, indistinguishable from genuinely broken code. This gives the
  verdict somewhere to go: the coordinator escalation reads "CI is broken
  repo-wide, not on this branch" and carries `note` as the evidence.

  `note` is required — an unevidenced verdict is not actionable, and this is
  precisely the claim an operator will want to check before force-merging.
  """
  @spec ci_mark_external(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def ci_mark_external(%Scope{} = scope, args) do
    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, note} <- require_string(args, "note") do
      case Arbiter.Worker.Watchdog.mark_ci_external(task_id, note) do
        :ok ->
          {:ok, %{task_id: task_id, park_reason: "ci_failed_external", note: note}}

        {:error, :not_found} ->
          {:error, {:not_found, "no merge watchdog is currently running for task #{task_id}"}}

        {:error, :not_parked_on_ci_failed} ->
          {:error,
           {:conflict,
            "task #{task_id} is not parked on a :ci_failed block — there is no CI failure " <>
              "to reclassify as external"}}

        {:error, :busy} ->
          {:error, {:busy, "task #{task_id}'s watchdog is busy polling — try again in a moment"}}
      end
    end
  end

  @doc """
  Record a structured flake event for the current fix_pass (bd-6vullc): the
  worker concluded a CI failure was a flake or infra issue — it re-ran the
  job with no code change and it went green (or has evidence it's broken
  repo-wide) — and this is the durable record of that conclusion, so a
  recurring flake can be counted across fix_passes instead of living only in
  one run's closing prose.

  `ci_job`, `signature` are required. `test_file`/`test_line` are optional —
  many flakes (infra, a rerun that clears on its own) have no test to name.
  `repo` defaults to the calling task's repo when not given. `run_id` is
  resolved to the task's most recent `fix_pass` run when not given.

  This is a plain append-only record, not a verdict on the task or PR — it
  does not reclassify a park the way `ci_mark_external` does, and calling it
  doesn't require a live Watchdog.
  """
  @spec flake_record(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def flake_record(%Scope{} = scope, args) do
    with {:ok, task_id} <- resolve_task_id(scope, args, "task_id"),
         {:ok, ci_job} <- require_string(args, "ci_job"),
         {:ok, signature} <- require_string(args, "signature"),
         {:ok, test_line} <- optional_integer(args, "test_line"),
         {:ok, repo} <- resolve_flake_repo(scope, args, task_id) do
      attrs = %{
        task_id: task_id,
        repo: repo,
        ci_job: ci_job,
        signature: signature,
        test_file: fetch_string(args, "test_file"),
        test_line: test_line,
        note: fetch_string(args, "note"),
        run_id: fetch_string(args, "run_id")
      }

      case Arbiter.Loop.Flakes.record(attrs) do
        {:ok, event} ->
          {:ok,
           %{
             id: event.id,
             task_id: event.task_id,
             repo: event.repo,
             ci_job: event.ci_job,
             test_file: event.test_file,
             test_line: event.test_line,
             signature: event.signature,
             run_id: event.run_id
           }}

        {:error, error} ->
          {:error, {:invalid, "could not record flake event: #{inspect(error)}"}}
      end
    end
  end

  defp resolve_flake_repo(scope, args, task_id) do
    case fetch_string(args, "repo") || scope.repo do
      repo when is_binary(repo) and repo != "" ->
        {:ok, repo}

      _ ->
        case fetch_task(scope, args, task_id) do
          {:ok, %Issue{repo: repo}} when is_binary(repo) and repo != "" -> {:ok, repo}
          _ -> {:error, {:invalid, "`repo` is required and could not be inferred from the task"}}
        end
    end
  end

  defp parse_rerun_mode(args) do
    case fetch_string(args, "mode") do
      nil -> {:ok, :auto}
      raw -> Map.fetch(@rerun_modes, raw) |> mode_result(raw)
    end
  end

  defp mode_result({:ok, mode}, _raw), do: {:ok, mode}

  defp mode_result(:error, raw) do
    {:error,
     {:invalid,
      "unknown mode #{inspect(raw)} — expected one of " <>
        (@rerun_modes |> Map.keys() |> Enum.sort() |> Enum.join(", "))}}
  end

  defp parse_rerun_inputs(args) do
    case Map.get(args, "inputs") do
      nil ->
        {:ok, %{}}

      inputs when is_map(inputs) ->
        {:ok, Map.new(inputs, fn {k, v} -> {to_string(k), to_string(v)} end)}

      other ->
        {:error, {:invalid, "`inputs` must be an object of string values, got #{inspect(other)}"}}
    end
  end

  # ---- repo_list ----------------------------------------------------------

  @doc """
  List registered repos with their paths, sources, active worker counts, and git worktree counts.
  Coordinator only. Mirrors the data from `GET /api/repos` and `arb repo list`.
  """
  @spec repo_list(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def repo_list(%Scope{}, _args) do
    repos =
      Arbiter.Repos.list()
      |> Enum.map(&serialize_repo/1)

    {:ok, %{repos: repos, count: length(repos)}}
  rescue
    e -> {:error, {:internal, "repo_list failed: #{Exception.message(e)}"}}
  end

  # ---- repo_show ----------------------------------------------------------

  @doc """
  Show details for a single repo: path, source, active worker count, and git worktree count.
  Coordinator only. Returns not-found if the repo name does not exist.
  """
  @spec repo_show(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def repo_show(%Scope{} = scope, args) do
    with {:ok, name} <- require_string(args, "name"),
         {:ok, target_ws} <- authorized_workspace(scope, args) do
      opts = if(target_ws, do: [workspace_id: target_ws], else: [])

      case Arbiter.Repos.get(name, opts) do
        {:ok, repo} -> {:ok, serialize_repo(repo)}
        {:error, {:invalid_request, msg, _details}} -> {:error, {:invalid_request, msg}}
        {:error, other} -> {:error, other}
      end
    end
  rescue
    e -> {:error, {:internal, "repo_show failed: #{Exception.message(e)}"}}
  end

  defp serialize_repo(repo) when is_map(repo) do
    %{
      name: repo.name,
      path: repo.path,
      source: repo.source,
      workspace_id: repo.workspace_id,
      workers: repo.workers,
      worktrees: repo.worktrees
    }
  end

  # ---- scheduler (autopilot) pause/resume --------------------------------

  @doc """
  Pause the board autopilot: stop promoting Ready cards to Running.
  Workers already dispatched continue to completion. Resume with `scheduler_resume`.
  Persisted, so it survives a server restart. Coordinator only.
  """
  @spec scheduler_pause(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def scheduler_pause(%Scope{} = scope, _args) do
    case Arbiter.Board.Autopilot.pause(Arbiter.Board.Autopilot, mcp_actor(scope)) do
      :ok ->
        Logger.info("[scheduler_pause] autopilot paused")
        {:ok, scheduler_status_data()}

      {:error, reason} ->
        {:error, {:internal, "pause failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:internal, "pause failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error,
       {:busy,
        "pause failed: the scheduler is not responding (#{inspect(reason)}); retry shortly"}}
  end

  @doc """
  Resume the board autopilot: start promoting Ready cards to Running again.
  The autopilot must be in paused state. Persisted, so it survives a server
  restart. Coordinator only.
  """
  @spec scheduler_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def scheduler_resume(%Scope{} = scope, _args) do
    case Arbiter.Board.Autopilot.resume(Arbiter.Board.Autopilot, mcp_actor(scope)) do
      :ok ->
        Logger.info("[scheduler_resume] autopilot resumed")
        {:ok, scheduler_status_data()}

      {:error, reason} ->
        {:error, {:internal, "resume failed: #{inspect(reason)}"}}
    end
  rescue
    e ->
      {:error, {:internal, "resume failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error,
       {:busy,
        "resume failed: the scheduler is not responding (#{inspect(reason)}); retry shortly"}}
  end

  @doc """
  Return the scheduler's drain state (`Arbiter.Board.Drain`): `state` is
  `running`, `draining` or `quiescent`, `safe_to_restart` is true only when
  quiescent, and `in_flight` lists every piece of live work — including the
  fix passes, conflict resolvers and review rounds a pause does not stop.
  Also the pause flag and when/by-what it was last changed (`nil` when
  unknown, e.g. still on the boot-time config default). Coordinator only.
  """
  @spec scheduler_status(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def scheduler_status(%Scope{} = _scope, _args) do
    {:ok, scheduler_status_data()}
  rescue
    e ->
      {:error, {:internal, "status check failed: #{inspect(e)}"}}
  catch
    :exit, reason ->
      {:error, {:busy, "status check failed: process error #{inspect(reason)}"}}
  end

  @doc """
  Return the server's version stamp, git sha, build and boot times, the
  update-check block and pending-migration status (`Arbiter.Server.Status`,
  the same read as `GET /api/version` and `GET /api/server/migrations`).
  Read-only; carries no host paths. Coordinator only.
  """
  @spec server_status(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def server_status(%Scope{} = _scope, _args), do: {:ok, Arbiter.Server.Status.snapshot()}

  defp mcp_actor(scope), do: {Arbiter.PaperTrail.actor_label(scope), "mcp"}

  # bd-9fgg04: the one drain-state definition, shared with the REST endpoint.
  defp scheduler_status_data do
    Arbiter.Board.Drain.status() |> Arbiter.Board.Drain.to_json()
  end

  # ---- provider pause/resume (bd-5ef587) ---------------------------------

  @doc """
  Pause a provider or one provider account (`ref`: `claude`, `codex`,
  `antigravity`, an account id, `provider:slug` or a bare slug): it is dropped
  from every routing decision with reason `paused`. Running workers keep
  running unless `stop_running` is true. Persisted. Coordinator only.
  """
  @spec provider_pause(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def provider_pause(%Scope{} = scope, args) do
    alias Arbiter.Providers.Pause

    with {:ok, ref} <- require_string(args, "ref"),
         {:ok, stop_running?} <- fetch_bool(args, "stop_running", false),
         {:ok, reason} <- Arbiter.Params.fetch_string(args, "reason"),
         {:ok, stopped} <-
           ref
           |> Pause.pause_and_stop(
             reason: reason,
             by: pause_by(scope),
             stop_running: stop_running?
           )
           |> pause_failure(ref) do
      Logger.info("[provider_pause] #{ref} paused")
      {:ok, %{paused: Pause.to_json(), stopped: stopped}}
    end
  end

  @doc "Resume a paused provider or account. Coordinator only."
  @spec provider_resume(Scope.t(), map()) :: {:ok, map()} | {:error, {atom(), String.t()}}
  def provider_resume(%Scope{} = scope, args) do
    alias Arbiter.Providers.Pause

    with {:ok, ref} <- require_string(args, "ref"),
         {:ok, entry} <- ref |> Pause.resume(by: pause_by(scope)) |> pause_failure(ref) do
      Logger.info("[provider_resume] #{entry.target} resumed")
      {:ok, %{paused: Pause.to_json()}}
    end
  end

  defp pause_by(scope),
    do: Arbiter.Providers.Pause.attribution(Arbiter.PaperTrail.actor_label(scope), "mcp")

  defp pause_failure({:error, reason}, ref),
    do: {:error, Arbiter.Providers.Pause.error_message(reason, ref)}

  defp pause_failure(ok, _ref), do: ok

  # ---- shared resolution / fetch -----------------------------------------

  # Resolve + authorize the target task id for this scope from the named arg
  # (default "id"). Worker: own task only; coordinator: id required.
  def resolve_task_id(scope, args, key \\ "id") do
    case Scope.own_task(scope, fetch_string(args, key)) do
      {:ok, id} ->
        {:ok, id}

      {:error, :unauthorized} ->
        {:error, {:unauthorized, "this scope may only act on its own task"}}

      {:error, :missing} ->
        {:error, {:invalid, "`#{key}` is required"}}
    end
  end

  @doc """
  Authorize a **write** against a `:refine` scope's subtree: the bound issue, or
  a descendant reachable from it by `parent_of` edges.

  A no-op (`:ok`) for every other tier — `:worker` and `:coordinator` have no
  subtree concept and are gated by `own_task/2` and workspace isolation instead.
  Handlers call this *after* `fetch_task/3`, so a cross-workspace id is still
  reported not-found rather than unauthorized (existence must not leak).
  """
  @spec authorize_subtree(Scope.t(), String.t() | nil) ::
          :ok | {:error, {:unauthorized, String.t()}}
  def authorize_subtree(%Scope{tier: :refine} = scope, id) do
    if Scope.subtree_member?(scope, id) do
      :ok
    else
      {:error, {:unauthorized, subtree_denial(scope, "#{id} is outside it")}}
    end
  end

  def authorize_subtree(%Scope{}, _id), do: :ok

  @doc """
  Authorize an **edge** write for a `:refine` scope.

  Two rules, because one edge type is not like the others:

    * **`:parent_of` — both endpoints must be in the subtree.** `parent_of` is
      the very relation `Scope.subtree_member?/2` walks, so a one-endpoint rule
      would be self-extending: `dep_add(bound_issue, any_issue, :parent_of)`
      adopts `any_issue` into the subtree, and the next `ticket_update` /
      `ticket_promote` on it then passes `authorize_subtree/2`. Repeat and a
      refine token reaches every issue in the workspace — including promoting
      it to Ready, where Autopilot can claim it, which is exactly what
      `can_dispatch: false` exists to prevent. Requiring both endpoints keeps
      re-parenting *within* the subtree available and makes adoption of an
      outsider impossible. The same rule applies to a `parent_of` **removal**
      (and to a `dep_remove` with no `type`, which would take `parent_of` edges
      with it): the shape of the tree outside the subtree is not a refine
      session's to edit.

    * **Every other type — at least one endpoint in the subtree.** None of
      `relates_to` / `depends_on` / `blocks` / `discovered_from` /
      `conflicts_with` confers authority over its endpoints, and refinement is
      largely about wiring the subtree to the work around it (`depends_on` a
      sibling's API change, `relates_to` the epic's other half).

  The edge still cannot reach across workspaces either way: both endpoints are
  fetched workspace-scoped first.

  `type` is the cast `Dependency` type, or `nil` for "every edge between the
  pair" (`dep_remove` with no type), which is treated as `:parent_of` because it
  may remove one.
  """
  @spec authorize_subtree_edge(Scope.t(), String.t(), String.t(), atom() | nil) ::
          :ok | {:error, {:unauthorized, String.t()}}
  def authorize_subtree_edge(scope, from_id, to_id, type)

  def authorize_subtree_edge(%Scope{tier: :refine} = scope, from_id, to_id, type)
      when type in [:parent_of, nil] do
    case Enum.reject([from_id, to_id], &Scope.subtree_member?(scope, &1)) do
      [] ->
        :ok

      outside ->
        {:error,
         {:unauthorized,
          subtree_denial(
            scope,
            "#{Enum.join(outside, " and ")} #{verb(outside)} outside it — a parent_of edge " <>
              "needs BOTH endpoints inside the subtree, so a refine session cannot adopt " <>
              "an outside task into its subtree (or re-parent one out of it)"
          )}}
    end
  end

  def authorize_subtree_edge(%Scope{tier: :refine} = scope, from_id, to_id, _type) do
    if Scope.subtree_member?(scope, from_id) or Scope.subtree_member?(scope, to_id) do
      :ok
    else
      {:error,
       {:unauthorized,
        subtree_denial(
          scope,
          "neither #{from_id} nor #{to_id} is in it — an edge needs at " <>
            "least one endpoint inside the subtree"
        )}}
    end
  end

  def authorize_subtree_edge(%Scope{}, _from_id, _to_id, _type), do: :ok

  defp verb([_one]), do: "is"
  defp verb(_many), do: "are"

  defp subtree_denial(%Scope{issue_id: bound}, detail) do
    "a refine session may only write inside the parent_of subtree of #{bound}: #{detail}"
  end

  # Fetch a task and enforce workspace isolation. Honors an optional `workspace`
  # arg (name or id): a workspace-bound scope may only ever reach its own
  # workspace; a workspace-agnostic coordinator either targets the named
  # workspace or, with no arg, infers it from the task itself (entity inference).
  # A task outside the resolved workspace is reported not-found so existence does
  # not leak across workspaces.
  def fetch_task(scope, args, id) do
    with {:ok, target_ws} <- authorized_workspace(scope, args) do
      case Ash.get(Issue, id) do
        {:ok, %Issue{} = issue} ->
          if workspace_match?(issue.workspace_id, target_ws),
            do: {:ok, issue},
            else: {:error, {:not_found, "task #{id} not found"}}

        _ ->
          {:error, {:not_found, "task #{id} not found"}}
      end
    end
  end

  # Fetch a task and require it to live in `ws_id` exactly — the second-endpoint
  # check for dependency tools, so both endpoints of an edge stay in one
  # workspace even for a workspace-agnostic coordinator inferring from the first.
  def fetch_task_in_workspace(ws_id, id) do
    case Ash.get(Issue, id) do
      {:ok, %Issue{workspace_id: ^ws_id} = issue} -> {:ok, issue}
      _ -> {:error, {:not_found, "task #{id} not found"}}
    end
  end

  # A `nil` target means "any workspace" (a workspace-agnostic coordinator that
  # named no workspace — the task's own workspace stands).
  def workspace_match?(_ws, nil), do: true
  def workspace_match?(ws, ws), do: true
  def workspace_match?(_ws, _target), do: false

  # The workspace this call is authorized to operate in, honoring an optional
  # `workspace` arg (name or id) — `Arbiter.Tasks.Workspaces.resolve/3` in
  # `:read` mode, the one rule shared with REST. `{:ok, nil}` means ALL
  # workspaces (a workspace-agnostic coordinator that named none), so reads
  # list everything and entity-inferring tools take the entity's own workspace.
  #
  # A scope bound to one workspace (every worker; a legacy workspace-bound
  # coordinator) may only ever resolve to its own workspace — naming a different
  # one is `{:error, {:unauthorized, …}}` (-32003).
  def authorized_workspace(%Scope{} = scope, args),
    do: Workspaces.resolve(scope, fetch_string(args, "workspace"), mode: :read)

  # A *concrete* workspace id for tools that write into / operate inside one
  # workspace: explicit `workspace` arg → the scope's bound workspace → the sole
  # workspace → `{:error, {:invalid, "multiple workspaces; pass workspace …"}}`.
  # Never the workspace that merely happens to be named `default`.
  def resolve_workspace_id(%Scope{} = scope, args),
    do: Workspaces.resolve(scope, fetch_string(args, "workspace"), mode: :write)

  # ---- Phase 2 arg coercion + validation ---------------------------------

  # Build a string-keyed attrs map from `args`, taking only the keys in `spec`
  # and coercing each to its declared type. Returns `{:ok, map}` or
  # `{:error, {:invalid, msg}}` on the first bad value. Absent keys are skipped.
  def collect_attrs(args, spec) when is_map(args) do
    Enum.reduce_while(spec, {:ok, %{}}, fn {key, type}, {:ok, acc} ->
      case Map.fetch(args, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, raw} ->
          case coerce_field(type, raw) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
            {:error, why} -> {:halt, {:error, {:invalid, "`#{key}` #{why}"}}}
          end
      end
    end)
  end

  def collect_attrs(_args, _spec), do: {:ok, %{}}

  def coerce_field(:string, v) when is_binary(v), do: {:ok, v}
  def coerce_field(:string, _), do: {:error, "must be a string"}

  def coerce_field(:integer, v) when is_integer(v), do: {:ok, v}

  def coerce_field(:integer, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be an integer"}
    end
  end

  def coerce_field(:integer, _), do: {:error, "must be an integer"}

  def coerce_field(:boolean, v) when is_boolean(v), do: {:ok, v}
  def coerce_field(:boolean, "true"), do: {:ok, true}
  def coerce_field(:boolean, "false"), do: {:ok, false}
  def coerce_field(:boolean, _), do: {:error, "must be a boolean"}

  # bd-13pqcp: a JSON object (`provider_constraint`); `null` clears it. The
  # resource's `NormalizeProviderConstraint` validates the keys and providers.
  def coerce_field(:map, nil), do: {:ok, nil}
  def coerce_field(:map, v) when is_map(v), do: {:ok, v}
  def coerce_field(:map, _), do: {:error, "must be an object"}

  def coerce_field({:enum, allowed}, v) do
    case to_allowed_atom(v, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, "must be one of: #{allowed_list(allowed)}"}
    end
  end

  # A required non-empty string argument.
  # internal — shared: a required non-empty string argument
  def require_string(args, key) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      s -> {:ok, s}
    end
  end

  # A required enum argument coerced against `allowed`.
  def require_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:error, {:invalid, "`#{key}` is required"}}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  # An optional enum argument; `{:ok, nil}` when absent.
  def optional_enum(args, key, allowed) do
    case fetch_string(args, key) do
      nil -> {:ok, nil}
      raw -> enum_or_error(raw, key, allowed)
    end
  end

  # internal — shared
  def enum_or_error(raw, key, allowed) do
    case to_allowed_atom(raw, allowed) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid, "`#{key}` must be one of: #{allowed_list(allowed)}"}}
    end
  end

  # internal — shared
  def optional_integer(args, key) do
    case Map.get(args, key) do
      nil ->
        {:ok, nil}

      v ->
        case Arbiter.Params.integer(v) do
          {:ok, n} -> {:ok, n}
          :error -> {:error, {:invalid, "`#{key}` must be an integer"}}
        end
    end
  end

  def optional_datetime(args, key) do
    case fetch_string(args, key) do
      nil ->
        {:ok, nil}

      raw ->
        case DateTime.from_iso8601(raw) do
          {:ok, dt, _offset} -> {:ok, dt}
          _ -> {:error, {:invalid, "`#{key}` must be an ISO-8601 datetime"}}
        end
    end
  end

  # internal — shared; coercion lives in Arbiter.Params
  defdelegate fetch_bool(args, key, default), to: Arbiter.Params

  # Tri-state bool: `{:ok, nil}` when the key is absent (so the callee can apply
  # its own default), `{:ok, true|false}` when present, error on a bad value.
  defdelegate fetch_optional_bool(args, key), to: Arbiter.Params

  # internal — shared
  def require_some(attrs, msg) do
    if map_size(attrs) == 0, do: {:error, {:invalid, msg}}, else: :ok
  end

  # internal — shared
  def to_allowed_atom(v, allowed) when is_binary(v) do
    atom = String.to_existing_atom(v)
    if atom in allowed, do: {:ok, atom}, else: :error
  rescue
    ArgumentError -> :error
  end

  def to_allowed_atom(_v, _allowed), do: :error

  # internal — shared
  def allowed_list(allowed), do: Enum.map_join(allowed, ", ", &Atom.to_string/1)

  # internal — shared
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  # internal — shared
  def maybe_put_kw(kw, _key, nil), do: kw
  def maybe_put_kw(kw, key, value), do: Keyword.put(kw, key, value)

  # ---- Phase 2 dispatch guardrail + opts (docs/mcp-server-design.md §4.3) ----

  # internal — shared by Arbiter.MCP.Tools.Worker
  def ensure_can_dispatch(%Scope{can_dispatch: true}), do: :ok

  def ensure_can_dispatch(%Scope{}),
    do: {:error, {:unauthorized, "this scope may not dispatch (can_dispatch is not set)"}}

  # ---- Phase 2 fetch helpers ---------------------------------------------

  # The scope's own workspace, loaded for the tracker bridge tools.
  def fetch_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %Workspace{} = ws} -> {:ok, ws}
      _ -> {:error, {:not_found, "workspace #{ws_id} not found"}}
    end
  end

  # Wrap `Claim.plan/1` so an adapter/tracker error surfaces as a tool error
  # rather than crashing the handler.
  defp claim_plan(workspace) do
    case workspace |> Claim.plan() |> Claim.typed() do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, claim_error(reason)}
    end
  end

  # A typed refusal (`Claim.refusal/1`: already_claimed, not_assigned,
  # invalid_request) keeps its kind, so the MCP error `type` matches REST's; any
  # other failure is the tracker's/Ash's own message.
  defp claim_error({kind, message, _details}) when is_atom(kind) and is_binary(message),
    do: {kind, message}

  defp claim_error(%{__struct__: _} = err) do
    if is_exception(err), do: {:invalid, Exception.message(err)}, else: {:invalid, inspect(err)}
  end

  defp claim_error(other), do: {:invalid, inspect(other)}

  # internal — shared
  def fetch_string(args, key) when is_map(args) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  def fetch_string(_args, _key), do: nil

  # An optional map argument; nil when absent or not a map.
  def fetch_map(args, key) when is_map(args) do
    case Map.get(args, key) do
      m when is_map(m) -> m
      _ -> nil
    end
  end

  def fetch_map(_args, _key), do: nil
  # Some MCP tool-calling clients serialize arguments into JSON-encoded strings
  # before sending them (bd-1dtufq) rather than native JSON values, even though
  # the tool's input_schema advertises the correct types. Detect that shape and
  # decode it, so `"[\"claude\", \"gemini\"]"` is treated as a real list.
  # Only unambiguous structural types (list/map) are unwrapped — scalars are left
  # as-is to preserve legitimate string values. workspace_config_set's schema
  # explicitly allows strings, so a client sending "5" as a config value should
  # not have it reinterpreted as the integer 5.
  # Pre-existing complexity 11 — baselined when bd-4x2yhq first
  # wired Credo up. Thresholds stay at the tool's own default so new
  # code is held to it; see the note in .credo.exs.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def unwrap_stringified_json(v, allowed_types) when is_binary(v) do
    trimmed = String.trim(v)

    # Only attempt JSON decode if this looks like a JSON value (starts with
    # structural char, digit, true/false/null, or quote).
    starts_with_json = String.match?(trimmed, ~r/^[\[\{0-9"tfn]/)

    if starts_with_json do
      case Jason.decode(trimmed) do
        {:ok, decoded} ->
          decoded_type =
            cond do
              is_list(decoded) -> :list
              is_map(decoded) -> :map
              is_integer(decoded) -> :integer
              is_boolean(decoded) -> :boolean
              decoded === nil -> :null
              true -> :other
            end

          if decoded_type in allowed_types, do: decoded, else: v

        _ ->
          v
      end
    else
      v
    end
  end

  def unwrap_stringified_json(v, _allowed_types), do: v
  # ---- serializers (JSON-friendly, mirroring the REST shapes) -------------

  def serialize_task_summary(%Issue{} = i), do: IssueSerializer.summary(i)

  @doc """
  A task summary with its lifecycle projection (`Lifecycle.Projection.payload/1`):
  `state`, `column`, `step`, `blocked_by` and `attention` (bd-6fkgvo).
  """
  def serialize_task_summary(%Issue{} = i, %{} = view) do
    i |> serialize_task_summary() |> Map.merge(Projection.payload(view))
  end

  # internal — shared by Arbiter.MCP.Tools.Task (task_show's full view) and
  # tracker_claim below
  def serialize_task(%Issue{} = i), do: i |> IssueSerializer.data() |> put_progress(i)

  @doc """
  What a `ticket_*` write tool returns: the full record REST returns
  (`Arbiter.Tasks.IssueSerializer.data/1`), or — with `summary: true` — the
  ten-field slim row (P-13, D-T-14).
  """
  @spec serialize_ticket(Issue.t(), map()) :: map()
  def serialize_ticket(%Issue{} = i, args) do
    case fetch_bool(args, "summary", false) do
      {:ok, true} -> IssueSerializer.summary(i)
      _ -> IssueSerializer.data(i)
    end
  end

  # internal — shared: the child-progress rollup, appended by both
  # serialize_task and Arbiter.MCP.Tools.Task's serialize_task_slim
  def put_progress(map, %Issue{child_total: t, child_closed: c})
      when is_integer(t) and is_integer(c) do
    Map.merge(map, %{child_total: t, child_closed: c, child_open: max(t - c, 0)})
  end

  def put_progress(map, _i), do: map

  def serialize_dependency(%Dependency{} = d) do
    %{
      id: d.id,
      from_issue_id: d.from_issue_id,
      to_issue_id: d.to_issue_id,
      type: to_str(d.type),
      notes: d.notes,
      created_by: d.created_by,
      created_at: iso(d.created_at)
    }
  end

  @doc """
  Render one `Arbiter.Tasks.Dependencies.list/1` row — `%{edge:, from:, to:}`
  — as the MCP `dep_list` / CLI-mirroring shape: the edge fields plus each
  endpoint's id/title/state/priority, so a live edge is distinguishable
  from a closed↔closed one without a second lookup (bd-1defgu).
  """
  def serialize_dependency_edge(%{edge: %Dependency{} = dep, from: from, to: to}) do
    dep
    |> serialize_dependency()
    |> Map.put(:from, serialize_dependency_endpoint(from))
    |> Map.put(:to, serialize_dependency_endpoint(to))
  end

  defp serialize_dependency_endpoint(%Issue{} = i) do
    %{id: i.id, title: i.title, state: to_str(i.state), priority: i.priority}
  end

  def serialize_workspace(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      description: ws.description,
      prefix: ws.prefix,
      config: ws.config || %{},
      # Names / flags ONLY (D-C-20): a coordinator or worker needs to know which
      # env vars and secrets exist; a value never crosses a machine surface.
      secret_keys: Workspace.secret_key_names(ws),
      worker_env: Workspace.worker_env_listing(ws),
      security:
        ws
        |> SecurityPolicy.resolve()
        |> SecurityPolicy.summary()
        |> Map.put(
          "repos",
          Map.new(SecurityPolicy.repo_egress(ws), fn {r, e} -> {r, %{"egress" => e}} end)
        )
        |> Map.put("guardrails", Arbiter.Guardrails.Report.posture(ws))
    }
  end

  # The non-sensitive summary `workspace_list` returns — id/name/prefix/tracker
  # only, never config or security posture.
  defp serialize_workspace_summary(%Workspace{} = ws) do
    %{
      id: ws.id,
      name: ws.name,
      prefix: ws.prefix,
      tracker_type: to_str(Trackers.workspace_type(ws))
    }
  end

  # internal — shared
  @doc """
  A ticket's computed attention (`Arbiter.Tasks.Lifecycle.Attention.t/0`) as
  JSON — nil stays nil (bd-8nlez1).
  """
  def serialize_attention(nil), do: nil

  def serialize_attention(%{} = a), do: Projection.attention_payload(a)

  @doc "One `Arbiter.Tasks.Attention.items/1` entry, flattened for the coordinator's queue."
  def serialize_attention_item(%{ticket_id: id, attention: attention} = item) do
    attention
    |> serialize_attention()
    |> Map.merge(%{
      ticket_id: id,
      title: item.title,
      state: to_str(item.state),
      workspace_id: item.workspace_id
    })
  end

  def to_str(nil), do: nil
  def to_str(a) when is_atom(a), do: Atom.to_string(a)
  def to_str(s) when is_binary(s), do: s

  # internal — shared
  def iso(nil), do: nil
  def iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)

  # internal — shared
  def ash_error_message(%{__struct__: _} = err) do
    if is_exception(err), do: Exception.message(err), else: inspect(err)
  rescue
    _ -> "update failed"
  end

  def ash_error_message(err), do: inspect(err)

  @doc """
  Render an `Arbiter.Tasks.Dependencies` failure as an MCP error tuple.

  The facade's own guards come back as `{reason, message}` with a message
  already written for a human (the named cycle, the two workspaces); a
  resource-level rejection comes back as an `Ash` error. `:not_found` keeps its
  own reason so an agent can tell "no such task" from "that edge is illegal".
  """
  @spec dependency_error(term()) :: {:error, {atom(), String.t()}}
  def dependency_error({:not_found, message}) when is_binary(message),
    do: {:error, {:not_found, message}}

  def dependency_error({reason, message}) when is_atom(reason) and is_binary(message),
    do: {:error, {:invalid, message}}

  def dependency_error(err), do: {:error, {:invalid, ash_error_message(err)}}

  # ---- delegation to split-out submodules ---------------------------------
  #
  # Implementation for these tool groups lives in the submodules below (see
  # the moduledoc); delegating keeps `&Tools.function/2` captures in
  # `Arbiter.MCP.Catalog` and every existing `Tools.function(...)` call site
  # working unchanged.

  defdelegate skill_create(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_update(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_delete(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_list(scope, args), to: Arbiter.MCP.Tools.Skills
  defdelegate skill_get(scope, args), to: Arbiter.MCP.Tools.Skills

  defdelegate loop_pending_list(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_pending_diff(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_pending_apply(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_pending_reject(scope, args), to: Arbiter.MCP.Tools.LoopPending

  defdelegate loop_propose_routing(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_analyze(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_propose(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_propose_repo_doc_patch(scope, args), to: Arbiter.MCP.Tools.LoopPending
  defdelegate loop_canary_status(scope, args), to: Arbiter.MCP.Tools.LoopPending

  defdelegate memory_pending_list(scope, args), to: Arbiter.MCP.Tools.MemoryPending
  defdelegate memory_pending_diff(scope, args), to: Arbiter.MCP.Tools.MemoryPending
  defdelegate memory_pending_apply(scope, args), to: Arbiter.MCP.Tools.MemoryPending
  defdelegate memory_pending_reject(scope, args), to: Arbiter.MCP.Tools.MemoryPending
  defdelegate memory_quarantine_list(scope, args), to: Arbiter.MCP.Tools.MemoryPending
  defdelegate memory_quarantine_restore(scope, args), to: Arbiter.MCP.Tools.MemoryPending
  defdelegate memory_distill(scope, args), to: Arbiter.MCP.Tools.MemoryPending

  defdelegate task_show(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_ready(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_update_progress(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_create(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_update(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_close(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_reopen(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_verify(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_promote(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_demote(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_rank(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate ticket_resume_review(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate epic_floor(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate ticket_handoff(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate ticket_handback(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate task_sync_upstream_close(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate dep_add(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate dep_remove(scope, args), to: Arbiter.MCP.Tools.Task
  defdelegate dep_list(scope, args), to: Arbiter.MCP.Tools.Task

  defdelegate workspace_show(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_get(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_overview(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_set(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_unset(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_config_schema(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_standing_order_add(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate workspace_standing_order_remove(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate installation_config_get(scope, args), to: Arbiter.MCP.Tools.Workspace
  defdelegate installation_config_set(scope, args), to: Arbiter.MCP.Tools.Workspace

  defdelegate inbox_check(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate coordinator_inbox(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate coordinator_inbox_clear(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate message_send(scope, args), to: Arbiter.MCP.Tools.Messaging
  defdelegate notify_list(scope, args), to: Arbiter.MCP.Tools.Messaging

  defdelegate alert_list(scope, args), to: Arbiter.MCP.Tools.Alerts

  defdelegate account_list(scope, args), to: Arbiter.MCP.Tools.Accounts
  defdelegate account_show(scope, args), to: Arbiter.MCP.Tools.Accounts
  defdelegate provider_list(scope, args), to: Arbiter.MCP.Tools.Accounts

  defdelegate usage_events_list(scope, args), to: Arbiter.MCP.Tools.Usage
  defdelegate usage_calibration(scope, args), to: Arbiter.MCP.Tools.Usage

  defdelegate account_set(scope, args), to: Arbiter.MCP.Tools.Account

  defdelegate breaker_list(scope, args), to: Arbiter.MCP.Tools.Breaker
  defdelegate breaker_reset(scope, args), to: Arbiter.MCP.Tools.Breaker

  defdelegate worker_dispatch(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_resume(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_review(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_stop(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_list(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_show(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_runs(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_log(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate worker_prompt(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate run_log_list(scope, args), to: Arbiter.MCP.Tools.Worker
  defdelegate transcript_capture_stats(scope, args), to: Arbiter.MCP.Tools.Worker
end
