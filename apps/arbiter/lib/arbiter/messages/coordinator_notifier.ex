defmodule Arbiter.Messages.CoordinatorNotifier do
  @moduledoc """
  Auto-posts coordinator notifications on worker (worker) lifecycle events, so
  the coordinator is informed without workers having to send messages by hand.

  Wired into `Arbiter.Worker`'s terminal/await transitions. Each event maps to
  a durable `:notification` `Arbiter.Messages.Message` — the broadcast kind that
  feeds the coordinator's dashboard (`to_ref` nil, never "consumed"):

  | Event                | Body                                                       |
  |----------------------|------------------------------------------------------------|
  | completed            | `<title> completed in <duration>`                          |
  | failed               | `<title> failed after <duration> — exit code <N>`          |
  | waiting              | `<title> — awaiting review` (the run is waiting on you)    |
  | awaiting_review_stuck| `<title> stuck at awaiting_review (MR <mr_ref>) — escalated` |

  Directive-closed events are intentionally **not** posted — too noisy.

  ## ReviewGate non-convergence is not a crash (bd-3wgdie)

  A `:failed` worker whose `meta[:failure_reason]` is `:review_gate_rejected`
  or `:review_gate_inconclusive` gets distinct wording instead of the generic
  `failed after <duration> — exit code <N>` template: e.g. `<title> escalated
  — ReviewGate did not converge after 2 round(s) — …`. The worker completed
  its work and exited 0 — it lost a review argument, not a crash — and the
  generic template previously read as a dead worker, burying a real
  human-judgement-needed escalation for 66 hours (see the bd-3wgdie
  writeup). ReviewGate also mails an addressed `:escalation` (`to_ref:
  "coordinator"`) with the full transcript via `Arbiter.Worker`'s
  `escalate_review_gate/3` — this broadcast `:notification` is a second,
  lower-friction surface (dashboard feed) carrying the same distinction.

  ## Actionable escalations (`worker_stopped`, `preflight_failed`)

  A dead/stopped worker (token exhaustion, crash, external kill, auth expiry)
  or a failed pre-flight auth probe is not just dashboard noise — it needs the
  operator to *act* (re-authenticate, top up credits, re-dispatch). Those go out as
  addressed `:escalation` **mailbox** messages (`to_ref: "coordinator"`,
  `task_ref: <task>`) so they land in `arb inbox` rather than scrolling off
  the broadcast feed. The classified cause + remediation
  (`Arbiter.Worker.StopReason`) is baked into the subject/body. See bd-awi4nw.

  ## Reconciliation with the task spec

  The originating task (bd-25ftl0) imagined dedicated `:completion` / `:failure`
  kinds and a `to="coordinator"` / `task_ref=task_id` shape. The Message
  resource that actually shipped (bd-bduz2k) settled on a leaner taxonomy:
  broadcast `:notification`s (the coordinator feed) vs. addressed mailbox kinds.
  We honour the realised design — every lifecycle auto-post is a
  `:notification` with `from_ref` set to the directive's task id; the
  completed/failed/awaiting distinction lives in the subject + body.

  ## Configuration

  Gated per-workspace by `workspace.config["coordinator_notifications"]`
  (default `true`). Set it to `false` on high-volume workspaces to silence the
  auto-posts. Workspaces configured before the vernacular rename (bd-2bsahq)
  may still carry the legacy `"admiral_notifications"` key — it is read as a
  fallback when the new key is absent, so existing opt-outs keep working.

  ## Failure handling

  Every entry point is best-effort: a missing workspace, a DB hiccup, or a
  payload bug is swallowed (with a debug breadcrumb) so notification work never
  disrupts the worker lifecycle. Mirrors the contract of
  `Arbiter.Worker.broadcast_lifecycle/2`.
  """

  require Logger

  alias Arbiter.Alerts
  alias Arbiter.CircuitBreaker
  alias Arbiter.Messages.Escalation
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.StopReason

  @config_key "coordinator_notifications"
  @legacy_config_key "admiral_notifications"

  # The `/api/oauth/usage` poll is account-wide, so its failure is one alert
  # for the whole install (bd-7gt8rm).
  @quota_poll_alert_key "anthropic_oauth_usage"

  # How long a merge-block escalation stays "recent enough" to suppress a repeat
  # even after the coordinator has cleared it (bd-brwx7w). The primary dedupe is
  # "an identical page is still uncleared"; this is the second gate, so that a
  # `clear_all` on a block the fleet structurally cannot resolve
  # (`:needs_nonauthor_approval`) does not immediately re-open the once-a-minute
  # flood. Override with `config :arbiter, :merge_block_escalation_cooldown_ms`.
  @default_block_escalation_cooldown_ms :timer.hours(6)

  # Same idea as the merge-block cooldown above, applied to `preflight_failed/2`
  # (bd-8lnnnt). A pre-flight refusal — expired credentials or an exhausted
  # usage window — is something only an operator or the clock can clear, never
  # a retry, so it earns the same "uncleared, or within cooldown after clear"
  # treatment as an unresolvable merge block. Override with
  # `config :arbiter, :preflight_escalation_cooldown_ms`.
  @default_preflight_escalation_cooldown_ms :timer.hours(6)

  # The merge-block reasons that mean "a human reviewer has not approved yet".
  # The forge forbids the fleet approving its own PR, so these can only clear
  # out-of-band — they are one dedupe family and the only ones that earn the
  # post-clear cooldown. See `block_family/1` and `fleet_unresolvable?/1`.
  @approval_block_reasons [:needs_approval, :needs_nonauthor_approval]

  @typedoc """
  The subset of an `Arbiter.Worker` snapshot this module reads. Passing the
  full snapshot map is fine — extra keys are ignored.
  """
  @type snapshot :: %{
          required(:task_id) => String.t(),
          optional(:workspace_id) => String.t() | nil,
          optional(:repo) => String.t() | nil,
          optional(:started_at) => DateTime.t() | nil,
          optional(:meta) => map() | nil,
          # A map type built only from `required/1` + `optional/1` literal keys
          # is CLOSED: dialyzer rejects any map carrying a key not listed. Every
          # real caller passes `Arbiter.Worker.snapshot/1`'s full map (`:state`,
          # `:role`, `:current_step`, `:mr_ref`, `:registry_key`, ...), so
          # without this the doc above ("extra keys are ignored") is a lie the
          # type does not permit and every call site is a `:call` warning.
          optional(atom()) => any()
        }

  @doc "Post the `:completed` lifecycle notification. Best-effort, returns `:ok`."
  @spec completed(snapshot()) :: :ok
  def completed(snapshot), do: post(:completed, snapshot)

  @doc "Post the `:failed` lifecycle notification. Best-effort, returns `:ok`."
  @spec failed(snapshot()) :: :ok
  def failed(snapshot), do: post(:failed, snapshot)

  @doc """
  Post the `:waiting` lifecycle notification — the run is `:waiting` on a
  question for you (bd-1uu19b). Best-effort, returns `:ok`.
  """
  @spec waiting(snapshot()) :: :ok
  def waiting(snapshot), do: post(:waiting, snapshot)

  @doc """
  Post a `:pipeline_failed` notification. Best-effort, returns `:ok`. Fired by
  `Arbiter.Worker.Watchdog` when a CI pipeline fails and `watch_pipeline` is
  enabled. The task is NOT failed — a human may force-merge or rerun.
  """
  @spec pipeline_failed(snapshot(), String.t() | nil) :: :ok
  def pipeline_failed(snapshot, mr_ref \\ nil) do
    snapshot =
      case mr_ref do
        nil ->
          snapshot

        ref when is_binary(ref) ->
          meta = Map.put(Map.get(snapshot, :meta, %{}) || %{}, :mr_ref, ref)
          Map.put(snapshot, :meta, meta)
      end

    post(:pipeline_failed, snapshot)
  end

  @doc """
  Post the `:awaiting_review_stuck` watchdog notification. Best-effort, returns
  `:ok`. Fired by `Arbiter.Worker.Watchdog` when a ticket's PR has sat past its
  poll cap without a terminal MR outcome — so a
  silent hang surfaces to the operator instead of waiting forever (bd-66ey1o).
  """
  @spec awaiting_review_stuck(snapshot(), String.t() | nil) :: :ok
  def awaiting_review_stuck(snapshot, mr_ref \\ nil) do
    snapshot =
      case mr_ref do
        nil ->
          snapshot

        ref when is_binary(ref) ->
          meta = Map.put(Map.get(snapshot, :meta, %{}) || %{}, :mr_ref, ref)
          Map.put(snapshot, :meta, meta)
      end

    post(:awaiting_review_stuck, snapshot)
  end

  @doc """
  Escalate a stopped/dead worker to the coordinator (bd-awi4nw).

  Unlike the lifecycle `:notification`s above, this is an addressed
  `:escalation` **mailbox** message (`to_ref: "coordinator"`) so it surfaces in
  `arb inbox` as an actionable item. The `Arbiter.Worker.StopReason` carries
  the classified cause + remediation; the subject names the task + cause and
  the body spells out the repo, last activity, exit code, and fix. Best-effort,
  returns `:ok`.
  """
  @spec worker_stopped(snapshot(), StopReason.t()) :: :ok
  def worker_stopped(snapshot, %StopReason{} = reason),
    do: escalate(:worker_stopped, snapshot, reason)

  @doc """
  Escalate a failed pre-flight auth probe to the coordinator (bd-awi4nw).

  Fired by `Arbiter.Worker.Dispatch` when the agent CLI fails its cheap
  token-validity probe *before* any worker is dispatched — so a wave of spawns
  that would all 401 is refused up front and the operator is told to
  re-authenticate. Same addressed `:escalation` shape as `worker_stopped/2`.
  Best-effort, returns `:ok`.
  """
  @spec preflight_failed(snapshot(), StopReason.t()) :: :ok
  def preflight_failed(
        %{workspace_id: ws_id, task_id: task_id} = snapshot,
        %StopReason{} = reason
      )
      when is_binary(ws_id) and is_binary(task_id) do
    if duplicate_preflight_escalation?(ws_id, task_id, reason) do
      Logger.debug(
        "CoordinatorNotifier.preflight_failed/2 suppressed duplicate escalation " <>
          "task=#{task_id} category=#{reason.category} (bd-8lnnnt)"
      )

      :ok
    else
      escalate(:preflight_failed, snapshot, reason)
    end
  end

  def preflight_failed(snapshot, %StopReason{} = reason),
    do: escalate(:preflight_failed, snapshot, reason)

  @doc """
  Escalate a Claude dispatch refused because the workspace has no setup token
  of its own (bd-80ecol).

  Fired by `Arbiter.Worker.Dispatch`'s auth guard with the
  `Arbiter.Agents.Claude.CredentialCheck` answer. Arbiter used to paper over
  this case by copying the operator's `.credentials.json` into the worker
  (mode B), whose refresh-token rotation locked the operator out; now the
  dispatch is held and this page names the command that fixes it.

  **Once per workspace.** The subject names the workspace, not the task:
  every Ready task in it is held for the same reason, and Autopilot retries
  the head card every tick. While an identical page is uncleared — or was
  sent within `:preflight_escalation_cooldown_ms` (default 6h) — a repeat is
  dropped, and the dedupe lives in the message table, so a restart does not
  re-page. Best-effort, returns `:ok`.
  """
  @spec setup_token_missing(map(), map()) :: :ok
  def setup_token_missing(%{workspace_id: ws_id} = snapshot, missing) when is_binary(ws_id) do
    escalate_event(:setup_token_missing, snapshot, fn task_id ->
      subject = "Claude dispatch held: no setup token for workspace #{missing_label(missing)}"

      if duplicate_setup_token_escalation?(ws_id) do
        :skip
      else
        body =
          Enum.join(
            [
              "Refused to dispatch #{title_for(task_id)}: #{missing.summary}.",
              "Every Claude dispatch in this workspace is held until it has a credential of " <>
                "its own. Arbiter no longer falls back to copying the operator's " <>
                "~/.claude/.credentials.json into a worker: Claude rotates that grant's " <>
                "refresh token on every refresh, so two holders lock each other out (bd-80ecol).",
              "Fix: #{missing.fix}",
              "Held tasks stay Ready and dispatch on their own once a credential resolves. " <>
                "This page is not repeated for the workspace's other held tasks."
            ],
            "\n"
          )

        {subject, body}
      end
    end)
  end

  def setup_token_missing(_snapshot, _missing), do: :ok

  defp missing_label(%{workspace: name}) when is_binary(name) and name != "", do: name
  defp missing_label(%{workspace_id: id}), do: id

  # bd-8if9zt: the identity is the kind and the workspace, not the subject.
  defp duplicate_setup_token_escalation?(ws_id) do
    scope = [workspace_id: ws_id]

    if Message.last_escalation(:setup_token_missing, [open: true] ++ scope) do
      true
    else
      case Message.last_escalation(:setup_token_missing, scope) do
        nil -> false
        last -> within_preflight_cooldown?(last)
      end
    end
  rescue
    _ -> false
  end

  @doc """
  Escalate a post-`start_worker` dispatch failure to the coordinator (bd-bi5pn0).

  Fired by `Arbiter.Worker.Dispatch` when a step AFTER `start_worker/3` fails
  (e.g. a transient network/VPN outage during the agent subprocess spawn, or
  a workflow-machine attach failure) — the worker it just registered `:idle`
  is failed rather than left as a silent zombie registration. Same addressed
  `:escalation` shape as `worker_stopped/2` / `preflight_failed/2`.
  Best-effort, returns `:ok`.
  """
  @spec spawn_failed(snapshot(), StopReason.t()) :: :ok
  def spawn_failed(snapshot, %StopReason{} = reason),
    do: escalate(:spawn_failed, snapshot, reason)

  @doc """
  Raise a proactively-detected credential expiry as a system alert (bd-5wchp1,
  bd-7gt8rm).

  Fired by `Arbiter.Agents.CredentialWatchdog` when a periodic liveness probe
  detects that credentials are expired *before* any worker has been dispatched
  or failed. Unlike `worker_stopped/2` and `preflight_failed/2`, this has no
  associated task — it names the adapter that failed instead.

  `snapshot` must contain `:workspace_id` (where the alert is shown); `adapter`
  is the module whose probe failed. Best-effort, returns `:ok`.

  ## One alert per episode (bd-6jjgk0, bd-7gt8rm)

  `Arbiter.Agents.CredentialWatchdog`'s own in-memory latch is not durable: its
  periodic CLI probe can flip an adapter back to `:ok` on a signal this
  proactive probe never saw (#1875), re-arming the latch on every flip. One
  install saw 35 near-identical "N consecutive 401s" pages in ~15h that way.
  The latch is the alert record: while the `(adapter, source)` alert is active
  a repeat call refreshes its detail and `last_raised_at` instead of opening a
  second one. `credential_restored/3` clears it once the same `source`
  succeeds again; a later failure then opens a fresh episode.

  `source` (default `:worker_report`) is which signal detected the failure —
  `:periodic_probe` (the Watchdog's own CLI probe, which gates dispatch 1:1),
  `:worker_report` (N worker deaths via `AuthHold`, also dispatch-gating), or
  `:usage_poll` (`Arbiter.Quota.CloudProbe`'s `/api/oauth/usage`-family poll,
  a separately cached credential, #1875). It keys the alert (so a
  `:usage_poll` episode and a `:periodic_probe` episode for the same adapter
  are two alerts) and the source description in its detail.

  `gate_closed?` (default `true`, for callers that don't gate dispatch on
  anything and are only ever `:worker_report`/`:periodic_probe`) is the
  adapter's *actual* dispatch-gate state at the moment this call is made —
  `Arbiter.Agents.CredentialWatchdog.expired?/1` right after this same expiry
  was recorded. It, not `source`, decides whether the detail claims dispatches
  are suspended (bd-6jjgk0 finding 1): a `:usage_poll` expiry never closes the
  gate on its own (#1875 — that probe reads a token the worker CLI doesn't),
  so its alert says so and names the probe's own credential as the one that
  failed.
  """
  @spec credential_expired(%{workspace_id: String.t()}, module(), StopReason.t(), atom()) :: :ok
  def credential_expired(snapshot, adapter, reason),
    do: credential_expired(snapshot, adapter, reason, :worker_report, true)

  @spec credential_expired(
          %{workspace_id: String.t()},
          module(),
          StopReason.t(),
          atom(),
          boolean()
        ) :: :ok
  def credential_expired(snapshot, adapter, reason, source),
    do: credential_expired(snapshot, adapter, reason, source, true)

  def credential_expired(
        %{workspace_id: ws_id} = snapshot,
        adapter,
        %StopReason{} = reason,
        source,
        gate_closed?
      )
      when is_binary(ws_id) and is_atom(adapter) and is_atom(source) and is_boolean(gate_closed?) do
    snapshot_with_adapter =
      snapshot
      |> Map.put(:adapter, adapter)
      |> Map.put(:source, source)
      |> Map.put(:gate_closed?, gate_closed?)

    {subject, detail} = escalation_payload(:credential_expired, snapshot_with_adapter, reason)

    raise_alert(
      :credential_expired,
      credential_alert_key(adapter, source),
      ws_id,
      subject,
      detail
    )
  end

  def credential_expired(_snapshot, _adapter, _reason, _source, _gate_closed?), do: :ok

  @doc """
  Clear the credential alert once the probe succeeds again (bd-6jjgk0,
  bd-7gt8rm).

  Fired by `Arbiter.Agents.CredentialWatchdog` when an adapter it had marked
  expired recovers via the *same* `source` that raised it (its own periodic
  probe passing again, `mark_recovered/3` from `Arbiter.Quota.CloudProbe`, or
  an `AuthHold` reset) — `Arbiter.Agents.CredentialWatchdog.on_probe_ok/4`
  only calls this once the recovering and raising sources match. Clears the
  `(adapter, source)` alert, so a later failure opens a fresh episode; the
  clear is announced on the `inbox` topic. A no-op when nothing is active.
  Best-effort, returns `:ok`.
  """
  @spec credential_restored(%{workspace_id: String.t()}, module(), atom()) :: :ok
  def credential_restored(snapshot, adapter),
    do: credential_restored(snapshot, adapter, :worker_report)

  def credential_restored(_snapshot, adapter, source) when is_atom(adapter) and is_atom(source),
    do: clear_alert(:credential_expired, credential_alert_key(adapter, source))

  def credential_restored(_snapshot, _adapter, _source), do: :ok

  # A credential episode is finer than its kind — one per adapter and source.
  defp credential_alert_key(adapter, source), do: "#{inspect(adapter)}:#{source}"

  # System alerts (bd-7gt8rm) go through `Arbiter.Alerts`, which folds a repeat
  # into the active row — so no circuit breaker: a repeat cannot add a row.
  # Best-effort like every other producer here.
  defp raise_alert(kind, key, ws_id, subject, detail) do
    case Alerts.raise_alert(%{
           kind: kind,
           key: key,
           workspace_id: ws_id,
           subject: subject,
           detail: detail
         }) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("CoordinatorNotifier: could not raise #{kind} alert: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("CoordinatorNotifier: raising #{kind} alert raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp clear_alert(kind, key) do
    _ = Alerts.clear(kind, key)
    :ok
  rescue
    e ->
      Logger.warning(
        "CoordinatorNotifier: clearing #{kind} alert raised: #{Exception.message(e)}"
      )

      :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Escalate an unexpected provider fallback to the coordinator (bd-2exkl0).

  Fired when a worker spawn (revision pass, resume, fix pass, conflict resolver)
  cannot use its original provider (e.g. credentials flagged expired) and must
  fall back to an alternative provider.

  Posts an addressed `:escalation` message to the coordinator so provider
  switches are never silent. Best-effort, returns `:ok`.
  """
  @spec provider_fallback(map(), atom() | String.t(), atom() | String.t(), String.t()) :: :ok
  def provider_fallback(
        %{workspace_id: ws_id} = snapshot,
        orig_provider,
        fallback_provider,
        reason
      )
      when is_binary(ws_id) do
    task_id = Map.get(snapshot, :task_id, "system")
    orig_str = to_string(orig_provider)
    fb_str = to_string(fallback_provider)

    subject = "[provider fallback] #{task_id}: #{orig_str} -> #{fb_str}"

    body = """
    ## Provider Fallback on #{task_id}

    Original provider: #{orig_str}
    Fallback provider: #{fb_str}
    Reason: #{reason}

    The spawn could not use #{orig_str} and fell back to #{fb_str} to continue
    progress without stalling. Check the provider's credentials or configuration.
    """

    send_unless_broken(ws_id, task_id, subject, fn ->
      Escalation.post(%{
        kind: :provider_fallback,
        from_ref: task_id || "system",
        workspace_id: ws_id,
        task_ref: task_id,
        subject: subject,
        body: body
      })
    end)

    :ok
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.provider_fallback swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  def provider_fallback(_snapshot, _orig, _fb, _reason), do: :ok

  @doc """
  Escalate a failed external-tracker sync to the coordinator (bd-c4cfuv).

  Fired by `Arbiter.Trackers.Sync` / `Arbiter.Tasks.Issue.Changes.SyncTracker`
  when a lifecycle transition (dispatch → In Progress, PR-open → In Code Review,
  merge → Done, …) can't be resolved or fails on the wire. The original
  incident (AX-17911) was invisible precisely because such failures were
  swallowed; this surfaces a `status_map`/workflow mismatch as an actionable
  inbox item instead. Best-effort, returns `:ok`.

  `snapshot` carries `:task_id` + `:workspace_id` (and optionally
  `:tracker_type` / `:tracker_ref`); `event` is the lifecycle atom; `reason` is
  the adapter's error term.
  """
  @spec tracker_sync_failed(map(), atom(), term()) :: :ok
  def tracker_sync_failed(snapshot, event, reason) do
    escalate_event(:tracker_sync_failed, snapshot, fn task_id ->
      tracker = Map.get(snapshot, :tracker_type)
      ref = Map.get(snapshot, :tracker_ref)

      subject = "#{task_id} tracker sync failed — #{event}"

      body =
        [
          "Failed to sync #{title_for(task_id)} to its external tracker on the " <>
            "`#{event}` lifecycle event.",
          tracker && "Tracker: #{tracker}#{ref && " #{ref}"}",
          "Error: #{describe_reason(reason)}",
          sync_hint(reason)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate a failed **review-coverage write** to the coordinator (bd-203cl5 /
  #1648, design #1635 §3.3).

  Fired by `Arbiter.Worker.ReviewGate` when a clean APPROVE could not record its
  `review_coverage` row. Unlike the `last_reviewed_sha` stamp beside it, this
  write is deliberately NOT best-effort: §3.3 argues that a silently-missing
  coverage row *is* the #1585 stall, so the failure has to be visible while it
  is still cheap to fix. The gate itself is unaffected — the approval stands and
  `last_reviewed_sha` (still the authoritative merge-guard input) is stamped as
  before. Best-effort send, returns `:ok`.
  """
  @spec review_coverage_write_failed(map(), String.t() | nil, String.t() | nil, term()) :: :ok
  def review_coverage_write_failed(snapshot, mr_ref, head_sha, reason) do
    escalate_event(:review_coverage_write_failed, snapshot, fn task_id ->
      subject = "#{task_id} review coverage write failed"

      body =
        [
          "A ReviewGate APPROVE for #{title_for(task_id)} could not record its " <>
            "review-coverage row (design #1635 §3.3).",
          mr_ref && "PR: #{mr_ref}",
          head_sha && "Approved head: #{head_sha}",
          "Error: #{describe_reason(reason)}",
          "",
          "The approval itself stands and `last_reviewed_sha` was stamped, so the " <>
            "merge guard is unaffected today. What is missing is the audit row for " <>
            "this head. Re-record it by hand with `arb review cover` once the cause " <>
            "is understood, or the head will read as uncovered when the coverage " <>
            "predicate goes live."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate a stalled auto-merge to the coordinator (bd-6gxosc).

  Fired by `Arbiter.Worker.Watchdog` after N consecutive `safe_merge` failures on
  an approved PR — the merge keeps failing (race, transient forge error, unknown
  `mergeable_state`) but the Watchdog keeps retrying silently. After the threshold
  is hit, this surfaces the stall as an actionable `:escalation` mailbox item so
  the coordinator can intervene if needed. The Watchdog continues retrying; it does
  NOT stop. `attempts` is the total consecutive failure count; `reason` is the
  last error from the merger adapter. Best-effort, returns `:ok`.
  """
  @spec auto_merge_stalled(map(), String.t() | nil, non_neg_integer(), term()) :: :ok
  def auto_merge_stalled(snapshot, mr_ref, attempts, reason) do
    escalate_event(:auto_merge_stalled, snapshot, fn task_id ->
      subject = "#{task_id} auto-merge stalled (#{attempts} consecutive failures)"

      body =
        [
          "#{title_for(task_id)} is approved but auto-merge has failed #{attempts} consecutive time(s).",
          mr_ref && "PR/MR: #{mr_ref}",
          "Last error: #{describe_reason(reason)}",
          "The Watchdog is still retrying — you can wait for it to resolve (e.g. once " <>
            "the forge finishes computing `mergeable_state`) or merge manually. " <>
            "No action is required if the next poll succeeds."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate an orphaned approved merge the fleet has stopped retrying
  (bd-a370ak / #2002).

  Fired once by the worker-less merge retry (`Arbiter.Worker.Watchdog.start_retry/1`)
  when an approved PR whose worker has exited can no longer be merged
  automatically: the head moved past the reviewed commit, the net diff is
  empty, CI is red, the PR is blocked, or the merge keeps being refused. The
  retry has stopped and latched the task's pending-merge stamp, so this page
  is not repeated — it is the hand-off to a human. Best-effort, returns `:ok`.
  """
  @spec orphaned_merge_abandoned(map(), String.t() | nil, term()) :: :ok
  def orphaned_merge_abandoned(snapshot, mr_ref, reason) do
    escalate_event(:orphaned_merge_abandoned, snapshot, fn task_id ->
      subject = "#{task_id} approved merge abandoned (orphaned PR: #{orphan_reason_tag(reason)})"

      body =
        [
          "#{title_for(task_id)} was approved, but its worker exited before the merge " <>
            "landed, and the fleet's retry cannot merge it automatically.",
          mr_ref && "PR/MR: #{mr_ref}",
          "Reason: #{describe_reason(reason)}",
          "The retry has stopped and will not page again. Merge it by hand once the " <>
            "reason is resolved, re-dispatch the task (`arb worker resume #{task_id}`) " <>
            "for a fresh review round, or close it."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  defp orphan_reason_tag({tag, _}) when is_atom(tag), do: tag
  defp orphan_reason_tag({tag, _, _}) when is_atom(tag), do: tag
  defp orphan_reason_tag(tag) when is_atom(tag), do: tag
  defp orphan_reason_tag(_), do: :merge_failed

  @doc """
  Escalate a blocked merge to the coordinator (#354, Phase 1).

  Fired by `Arbiter.Worker.Watchdog` when an approved/parked PR can't merge and
  the merger adapter has classified *why* (`:conflict`, `:behind_base`,
  `:ci_failed`, `:needs_approval`, `:needs_nonauthor_approval`, `:draft`,
  `:blocked_other`). Unlike the
  broadcast lifecycle notifications, this is an addressed `:escalation` **mailbox**
  message (`to_ref: "coordinator"`) so it lands in `arb inbox` as an actionable item
  — the whole point of Phase 1 is that a blocked merge never parks silently.

  `snapshot` carries `:task_id` + `:workspace_id`; `mr_ref` is the PR/MR ref (may
  be `nil`); `reason` is the block-reason atom. Best-effort, returns `:ok`.

  ## Deduped and backed off (bd-brwx7w)

  A block reason the fleet cannot resolve on its own — `:needs_nonauthor_approval`
  above all, where the forge forbids the author approving their own PR — is
  re-detected on *every* poll, forever. Each poller used to hold its own
  in-memory latch, so two pollers watching one PR paged the coordinator roughly
  once a minute indefinitely, drowning the mailbox and tripping event-stream
  watchers' rate cutoffs.

  The latch now lives in the message table, which every poller and every restart
  shares. A page is suppressed when an identical escalation for this
  `(workspace, task, reason-family)` is **still uncleared**, or when one was
  raised inside the cooldown window (`@default_block_escalation_cooldown_ms`).
  `:needs_approval` and `:needs_nonauthor_approval` share one family — they are
  two spellings of "waiting on a human reviewer", and alternating between them
  is exactly what defeated the old per-reason latch. A genuinely *different*
  block (a conflict appearing on top of a missing approval) is a different
  family and still pages immediately.
  """
  @spec merge_blocked(map(), String.t() | nil, atom()) :: :ok
  def merge_blocked(snapshot, mr_ref, reason) do
    escalate_event(:merge_blocked, snapshot, fn task_id ->
      ws_id = snapshot.workspace_id

      if duplicate_block_escalation?(ws_id, task_id, reason) do
        Logger.debug(
          "CoordinatorNotifier.merge_blocked/3 suppressed duplicate escalation " <>
            "task=#{task_id} reason=#{reason} (bd-brwx7w)"
        )

        :skip
      else
        subject = block_subject(task_id, reason)

        body =
          [
            "#{title_for(task_id)} cannot merge: #{block_label(reason)}.",
            mr_ref && "PR/MR: #{mr_ref}",
            "Reason: #{reason}",
            "Remediation: #{block_remediation(reason, auto_merge?(ws_id, task_id))}",
            "The Watchdog detected this on its merge poll and parked the PR rather " <>
              "than failing it — resolve the block (or force-merge) and the next " <>
              "poll will pick it up.",
            "This escalation is raised once per block episode — it will not repeat " <>
              "while it is outstanding in the inbox."
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {subject, body}
      end
    end)
  end

  @doc """
  Raise a quota-overage spend crossing as a system alert (bd-7cd38f,
  bd-7gt8rm).

  Fired by `Arbiter.Workflows.DispatchQueue` in `:continue` mode when the
  workspace's windowed overage spend crosses a multiple of its
  `overage_alert_usd` threshold. Informational: dispatch does NOT stop, the
  operator decides whether to switch back to `:throttle` or top up. One alert
  per workspace and provider — a later crossing refreshes it — cleared by
  `overage_cleared/2` once the spend is back under the threshold, the
  threshold is raised or removed, or dispatch is no longer past the cap.

  `snapshot` carries `:workspace_id` and the gate's `:provider` (may be nil);
  `spend_usd` is the windowed overage
  spend; `threshold_usd` is the configured alert threshold. Best-effort,
  returns `:ok`.
  """
  @spec overage_alert(map(), number(), number()) :: :ok
  def overage_alert(%{workspace_id: ws_id} = snapshot, spend_usd, threshold_usd)
      when is_binary(ws_id) do
    subject =
      "quota overage spend crossed $#{fmt_usd(threshold_usd)} — #{fmt_usd(spend_usd)} so far"

    detail =
      Enum.join(
        [
          "This workspace is dispatching past the Anthropic plan cap in `:continue` " <>
            "mode and has now spent about $#{fmt_usd(spend_usd)} in paid overage this " <>
            "5h window — crossing the $#{fmt_usd(threshold_usd)} alert threshold.",
          "Dispatch has NOT stopped. This is an informational alert (cap + alert, " <>
            "not auto-stop): switch this workspace to `:throttle`, raise " <>
            "`quota.overage_alert_usd`, or let it ride — your call. It clears by " <>
            "itself once the spend is back under the threshold.",
          "Workspace: #{ws_id}"
        ],
        "\n"
      )

    key = overage_alert_key(ws_id, Map.get(snapshot, :provider))
    raise_alert(:overage_alert, key, ws_id, subject, detail)
  end

  def overage_alert(_snapshot, _spend_usd, _threshold_usd), do: :ok

  @doc """
  Clear `workspace_id`'s overage alert for `provider`: its windowed overage
  spend is back under the threshold, the threshold was raised or removed, or
  dispatch on that provider is no longer past its plan cap (bd-7gt8rm). A
  no-op when none is active.
  """
  @spec overage_cleared(String.t(), atom() | nil) :: :ok
  def overage_cleared(workspace_id, provider \\ nil)

  def overage_cleared(workspace_id, provider) when is_binary(workspace_id),
    do: clear_alert(:overage_alert, overage_alert_key(workspace_id, provider))

  def overage_cleared(_workspace_id, _provider), do: :ok

  # Overage is metered per provider account (P7), so one provider leaving
  # overage must not clear another's alert in the same workspace.
  defp overage_alert_key(ws_id, nil), do: ws_id
  defp overage_alert_key(ws_id, provider), do: "#{ws_id}:#{provider}"

  defp fmt_usd(n) when is_number(n), do: :erlang.float_to_binary(n * 1.0, decimals: 2)

  @doc """
  Raise a sustained `/api/oauth/usage` polling outage as a system alert
  (bd-4fbpto, bd-7gt8rm).

  Fired by `Arbiter.Quota.CloudProbe` the cycle its consecutive-failure count
  first reaches the configured threshold. The poll is account-wide, so this is
  one install-wide alert: a repeat refreshes it, and `quota_poll_recovered/0`
  clears it on the next successful poll, so a later outage opens a fresh one.

  This poll is the *only* thing that refreshes Claude's quota snapshot for an
  idle fleet (bd-atyrrq); a silent, sustained failure here means the dispatch
  gate is running on a snapshot that only gets staler, and a 7d hold — once
  engaged — cannot lift without a fresh polled row (bd-b7umwj). `arb quota`
  used to be the only way a human would notice (see the PR #1607 write-up);
  this is the automated backstop.

  `snapshot` carries `:workspace_id` — any workspace touched by the failed
  poll group is representative, since the poll itself is account-wide, not
  workspace-scoped. `failures` is the consecutive-failure count; `reason` is
  whatever `Arbiter.Quota.capture_oauth_usage_for_group/2` (or the rescue/catch
  around it) returned. Best-effort, returns `:ok`.
  """
  @spec quota_poll_failing(map(), pos_integer(), term()) :: :ok
  def quota_poll_failing(%{workspace_id: ws_id}, failures, reason) when is_binary(ws_id) do
    subject = "Anthropic quota poll failing — #{failures} consecutive cycles"

    detail =
      Enum.join(
        [
          "`Arbiter.Quota.CloudProbe`'s `/api/oauth/usage` poll has failed " <>
            "#{failures} consecutive cycles: #{describe_reason(reason)}.",
          "The dispatch gate is now running on an aging snapshot. The 5h rule fails " <>
            "open on age, but a 7d hold cannot lift without a fresh polled snapshot.",
          "Check `arb quota` for the last successful poll's source and timestamp, and " <>
            "confirm the account-wide OAuth token this install polls with (the operator's " <>
            "`~/.claude/.credentials.json`, not a workspace token) is still valid. " <>
            "This alert clears by itself on the next successful poll."
        ],
        "\n"
      )

    raise_alert(:quota_poll_failing, @quota_poll_alert_key, ws_id, subject, detail)
  end

  def quota_poll_failing(_snapshot, _failures, _reason), do: :ok

  @doc """
  Clear the quota-poll alert: `Arbiter.Quota.CloudProbe`'s poll succeeded
  again (bd-7gt8rm). A no-op when none is active.
  """
  @spec quota_poll_recovered() :: :ok
  def quota_poll_recovered, do: clear_alert(:quota_poll_failing, @quota_poll_alert_key)

  @doc """
  Escalate a `/api/oauth/usage` polling outage whose cause is the operator's
  interactive Claude login lapsing (bd-4ag0nj).

  The poll authenticates with the operator's `~/.claude/.credentials.json`
  whenever the account has no `cli_credentials_file` credential — including
  an account whose only credential is the `:oauth_token` setup token workers
  run on, because `/api/oauth/usage` rejects that token (429 with
  `Retry-After: 3600`; PR #1607, re-checked on bd-4ag0nj). That interactive
  access token lasts about 8h and only refreshes while an interactive `claude`
  session runs, so an idle night leaves the file expired (401) or gone
  (`:no_credentials`). `Arbiter.Quota` only tags a failure this way when
  workers run on their own token (the account's `:oauth_token` row, or a
  configured `CLAUDE_CODE_OAUTH_TOKEN`) rather than a seeded copy of that
  file, so workers are unaffected and this says so rather than reading like
  an account-credential failure.

  Fired by `Arbiter.Quota.CloudProbe` in place of `quota_poll_failing/3`, the
  cycle its consecutive-failure count first reaches the threshold — the same
  edge trigger, so one outage produces one mailbox item — chosen whenever
  any failure in the current streak was a lapsed login. `reason` is the
  threshold cycle's fetch error, unwrapped (usually `:no_credentials` or
  `{:http_error, 401}`; possibly an interleaved `:rate_limited`).
  Best-effort, returns `:ok`.
  """
  @spec operator_login_lapsed(map(), pos_integer(), term()) :: :ok
  def operator_login_lapsed(snapshot, failures, reason) do
    escalate_event(:operator_login_lapsed, snapshot, [task_ref: "system"], fn _task_id ->
      subject = "Anthropic quota poll blind — operator's interactive Claude login lapsed"

      body =
        [
          "`Arbiter.Quota.CloudProbe`'s `/api/oauth/usage` poll has failed " <>
            "#{failures} consecutive cycles: #{describe_reason(reason)}.",
          "Cause: the poll authenticates with the operator's interactive Claude login " <>
            "(`~/.claude/.credentials.json`), and that login has lapsed — its access token " <>
            "only refreshes while an interactive `claude` session is running. The account's " <>
            "setup token (`CLAUDE_CODE_OAUTH_TOKEN`) cannot authenticate this endpoint.",
          "Fix: run `claude` on the Arbiter host (log in if prompted) to refresh " <>
            "`~/.claude/.credentials.json`; the next poll recovers on its own.",
          "Workers are not affected — they run on their own setup token, not this file. " <>
            "Until then the " <>
            "dispatch gate runs on an aging snapshot: the 5h rule fails open on age, and a 7d " <>
            "hold cannot lift without a fresh polled snapshot."
        ]
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate a problem with the quota poller's **dedicated Claude grant**
  (bd-b632tz): the `.credentials.json` at `path`, kept by a `claude` login
  in its own `CLAUDE_CONFIG_DIR` and renewed by
  `Arbiter.Quota.GrantRefresher` running the CLI. Every cause names the one
  fix — log that config dir in again — as a command the operator can paste.

  `cause` is one of:

    * `{:poll_failing, failures, reason}` — `Arbiter.Quota.CloudProbe`'s
      `/api/oauth/usage` poll has failed `failures` cycles on this grant (a
      401, or the file gone / logged out).
    * `{:refresh_failed, reason}` — the refresher ran the CLI and the grant's
      `expiresAt` did not move, or the file became unreadable.
    * `{:refresh_token_expiring, %DateTime{}}` — the grant's
      `refreshTokenExpiresAt` is within the refresher's warning window; the
      CLI cannot renew past it.

  **One page per episode.** The subject carries the config dir but no
  numbers, and nothing is sent while an uncleared escalation with the same
  subject is already in the coordinator's inbox — so the refresher's page
  and CloudProbe's page for the same broken grant are one mailbox item, and
  neither repeats across a restart. The expiring-refresh-token warning has its
  own subject, since it is advance notice rather than an outage. Best-effort,
  returns `:ok`.
  """
  @spec quota_grant_failing(map(), String.t(), term()) :: :ok
  def quota_grant_failing(%{workspace_id: ws_id} = snapshot, path, cause)
      when is_binary(ws_id) and is_binary(path) do
    config_dir = Path.dirname(path)

    escalate_event(:quota_grant_failing, snapshot, [task_ref: "system"], fn _task_id ->
      subject = quota_grant_subject(cause, config_dir)

      # A grant's episode is finer than its kind — one per config dir and
      # cause — so the subject still narrows it (see `last_escalation/2`).
      if Message.last_escalation(:quota_grant_failing,
           workspace_id: ws_id,
           subject: subject,
           open: true
         ) do
        :skip
      else
        {subject, quota_grant_body(cause, path, config_dir)}
      end
    end)
  end

  def quota_grant_failing(_snapshot, _path, _cause), do: :ok

  defp quota_grant_subject({:refresh_token_expiring, _at}, config_dir),
    do: "Anthropic quota grant expires soon — re-login #{config_dir}"

  defp quota_grant_subject(_cause, config_dir),
    do: "Anthropic quota grant needs re-login — #{config_dir}"

  defp quota_grant_body(cause, path, config_dir) do
    [
      quota_grant_cause(cause, path),
      "Fix: on the Arbiter host, from a neutral directory (e.g. `cd /tmp` — never the " <>
        "admiral dir or a repo), run `CLAUDE_CONFIG_DIR=#{config_dir} claude auth login` " <>
        "and complete the browser login. Use this dedicated config dir only: logging in " <>
        "there does not touch the operator's own `~/.claude` session. The next poll " <>
        "picks the new grant up; nothing needs restarting.",
      quota_grant_impact(cause)
    ]
    |> Enum.join("\n")
  end

  defp quota_grant_cause({:poll_failing, failures, reason}, path),
    do:
      "`Arbiter.Quota.CloudProbe`'s `/api/oauth/usage` poll has failed #{failures} " <>
        "consecutive cycles on the dedicated quota grant `#{path}`: " <>
        "#{describe_reason(reason)}."

  defp quota_grant_cause({:refresh_failed, reason}, path),
    do:
      "`Arbiter.Quota.GrantRefresher` could not renew the dedicated quota grant " <>
        "`#{path}` with the `claude` CLI: #{describe_reason(reason)}."

  defp quota_grant_cause({:refresh_token_expiring, at}, path),
    do:
      "The dedicated quota grant `#{path}` has a refresh token that expires at " <>
        "#{DateTime.to_iso8601(at)}. The `claude` CLI cannot renew the grant past that, " <>
        "so the quota poll will go blind then unless it is logged in again first."

  defp quota_grant_cause(other, path),
    do: "The dedicated quota grant `#{path}` needs attention: #{describe_reason(other)}."

  defp quota_grant_impact({:refresh_token_expiring, _at}),
    do: "The poll is still healthy; this is advance notice, and it will not repeat."

  defp quota_grant_impact(_cause),
    do:
      "Until then the dispatch gate runs on an aging snapshot: the 5h rule fails open on " <>
        "age, and a 7d hold cannot lift without a fresh polled snapshot. Workers are not " <>
        "affected — they never use this grant."

  @doc """
  Escalate a card that Autopilot cannot get out of Ready (bd-a40f4q).

  Fired by `Arbiter.Board.Autopilot` when a promoted card's dispatch keeps
  returning the same error shape. `Arbiter.Worker.Dispatch.resolve_repo_for_dispatch/2`
  can fail with `:ambiguous_repo`, `:no_repo_configured` or `:repo_not_found` —
  none of those self-heal by retrying, so Autopilot escalates the first time
  it sees one. Any other dispatch error gets an Autopilot-owned retry budget
  first, in case it is transient (a quota gate, a network blip); the
  escalation only fires once that budget is exhausted. Same addressed
  `:escalation` **mailbox** shape as the other escalations here.

  Dedupe lives in `Arbiter.Board.Autopilot`'s own process state (an
  `escalated?` latch per card, cleared on the next successful dispatch or when
  the error shape changes) rather than the message table: a card either keeps
  failing the same way, in which case one page is enough, or the error
  changes, in which case a fresh page is exactly right.

  `snapshot` carries `:task_id` + `:workspace_id`; `reason` is the raw
  dispatch error term; `attempts` is the consecutive-failure count. Best-effort,
  returns `:ok`.
  """
  @spec dispatch_stuck(map(), term(), pos_integer()) :: :ok
  def dispatch_stuck(snapshot, reason, attempts) do
    escalate_event(:dispatch_stuck, snapshot, fn task_id ->
      subject = "#{task_id} dispatch stuck (#{attempts}× #{dispatch_stuck_label(reason)})"

      body =
        [
          "Autopilot has tried to dispatch #{title_for(task_id)} #{attempts} consecutive " <>
            "time(s) and gotten the same error every time: #{dispatch_stuck_label(reason)}.",
          "The card is still in Ready and Autopilot keeps reconsidering it every tick, but " <>
            "it will not succeed on its own: #{dispatch_stuck_action(reason)}",
          "This escalation is raised once per failure episode — it will not repeat while " <>
            "the same error keeps recurring."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Raise a system alert for an open task whose **worker spend** has passed its
  estimate group's p90 (bd-8j9i9p AC5; operator decision 2026-09-15;
  bd-7gt8rm).

  This one informs rather than intervenes: it does not stop the worker, pause
  anything or trip a breaker. An overrun is not evidence of a stuck worker the
  way a repeated review failure is — it is evidence that either the task was
  under-rated or something is looping. So the alert carries everything needed
  to judge that: the title, the spend, the range it blew through, the basis
  and sample size behind that range, the difficulty rating, and what the
  worker is doing right now.

  **One alert per task.** It is keyed by the task, so the patrol re-raising it
  every sweep only refreshes the figures in its detail.
  `budget_recovered/1` clears it once the task is back under its p90 — a
  re-rating or a thicker sample moved the threshold — or is no longer open.

  `snapshot` carries `:task_id` + `:workspace_id`; `info` carries `:spend`,
  `:estimate` (an `Arbiter.Usage.Estimate.t()`), `:difficulty` and
  `:worker_state`. Best-effort, returns `:ok`.
  """
  @spec budget_exceeded(map(), map()) :: :ok
  def budget_exceeded(%{workspace_id: ws_id, task_id: task_id}, info)
      when is_binary(ws_id) and is_binary(task_id) do
    raise_alert(
      :budget_exceeded,
      task_id,
      ws_id,
      budget_exceeded_subject(task_id),
      budget_exceeded_body(task_id, info)
    )
  end

  def budget_exceeded(_snapshot, _info), do: :ok

  @doc """
  Clear the budget alert of every task not in `still_over` — the task ids the
  patrol's sweep just found over budget (bd-7gt8rm). Best-effort, returns `:ok`.
  """
  @spec budget_recovered([String.t()]) :: :ok
  def budget_recovered(still_over) when is_list(still_over) do
    _ = Alerts.clear_except(:budget_exceeded, still_over)
    :ok
  rescue
    e ->
      Logger.warning("CoordinatorNotifier.budget_recovered/1 raised: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  The (number-free, so dedupe-stable) subject `budget_exceeded/2` pages under.
  """
  @spec budget_exceeded_subject(String.t()) :: String.t()
  def budget_exceeded_subject(task_id), do: "#{task_id} worker spend over budget"

  defp budget_exceeded_body(task_id, info) do
    est = Map.get(info, :estimate) || %{}

    [
      "#{title_for(task_id)} (#{task_id}) has spent #{money(Map.get(info, :spend))} in " <>
        "worker spend, past the p90 of what tasks like it cost." <> live_spend_note(info),
      "Estimate: #{money(Map.get(est, :p25))}–#{money(Map.get(est, :p75))} " <>
        "(median #{money(Map.get(est, :median))}, p90 #{money(Map.get(est, :p90))}) · " <>
        "#{Map.get(est, :basis, "unknown")}, n=#{Map.get(est, :n, 0)}",
      "Rated #{difficulty_label(Map.get(info, :difficulty))} · worker: " <>
        "#{Map.get(info, :worker_state) || "no live worker"}",
      "Worker spend only — coordinator session overhead is not counted, here or " <>
        "in the estimate.",
      "Nothing has been stopped or paused. This alert tracks the task's figures " <>
        "while it stays over, and clears once it is back under its p90 or closed. " <>
        "Judge whether the overrun is expected (under-rated task) or a worker going " <>
        "in circles, and act, or don't."
    ]
    |> Enum.join("\n")
  end

  # bd-8vnuy3: the patrol assesses live spend, so the figure can include a pass
  # that has not ended. Say how much of it is that pass's estimate, and whether
  # a session file could not be read (the figure is then short of the truth).
  defp live_spend_note(info) do
    live =
      case Map.get(info, :live_spend) do
        n when is_number(n) and n > 0 ->
          " ≈#{money(n)} of that is an in-flight estimate read off a session still " <>
            "running; the rest is settled."

        _ ->
          ""
      end

    degraded =
      if Map.get(info, :degraded?),
        do: " A running session's file could not be read, so the figure may be low.",
        else: ""

    live <> degraded
  end

  defp difficulty_label(d) when is_integer(d), do: "D#{d}"
  defp difficulty_label(_), do: "unrated"

  defp money(n) when is_number(n), do: "$" <> :erlang.float_to_binary(n / 1, decimals: 2)
  defp money(_), do: "$?"

  defp dispatch_stuck_label({:ambiguous_repo, repos}) when is_list(repos),
    do: "ambiguous repo — #{Enum.join(repos, ", ")} are all configured"

  defp dispatch_stuck_label(:no_repo_configured), do: "no repo configured for this workspace"

  defp dispatch_stuck_label({:repo_not_found, repo}),
    do: "configured repo #{inspect(repo)} not found"

  defp dispatch_stuck_label(reason), do: describe_reason(reason)

  defp dispatch_stuck_action({:ambiguous_repo, _repos}) do
    "set a default repo for this workspace, or the issue's own repo attribute, and the " <>
      "next tick will dispatch it."
  end

  defp dispatch_stuck_action(:no_repo_configured) do
    "configure at least one repo for this workspace and the next tick will dispatch it."
  end

  defp dispatch_stuck_action({:repo_not_found, _repo}) do
    "fix the workspace's repo config so it resolves and the next tick will dispatch it."
  end

  defp dispatch_stuck_action(_reason) do
    "this may be transient (quota, network) — inspect the error above; if it recurs it " <>
      "likely needs a config or account fix."
  end

  @doc """
  Escalate a blocked merge the Watchdog tried — and failed — to auto-resolve
  (#354, Phase 2a).

  Fired by `Arbiter.Worker.Watchdog` after it has attempted to mechanically
  resolve a `:behind_base` (update-branch) or `:ci_failed` (fix-pass worker)
  block `attempts` times without the PR becoming mergeable. Unlike
  `merge_blocked/3` — which fires immediately for a block the Watchdog does not
  auto-resolve — this names the auto-resolve attempt count so the operator knows
  the autonomous path was tried first. Same addressed `:escalation` **mailbox**
  shape. Best-effort, returns `:ok`.
  """
  @spec merge_block_unresolved(map(), String.t() | nil, atom(), non_neg_integer(), keyword()) ::
          :ok
  def merge_block_unresolved(snapshot, mr_ref, reason, attempts, opts \\ []) do
    escalate_event(:merge_block_unresolved, snapshot, fn task_id ->
      ws_id = snapshot.workspace_id
      note = Keyword.get(opts, :note)

      subject = "#{task_id} auto-resolve exhausted (#{attempts}×) — #{block_label(reason)}"

      body =
        [
          "#{title_for(task_id)} still cannot merge after #{attempts} auto-resolve " <>
            "attempt(s): #{block_label(reason)}.",
          mr_ref && "PR/MR: #{mr_ref}",
          "Reason: #{reason}",
          "Auto-resolve attempts: #{attempts}",
          note && "Worker's diagnosis: #{note}",
          "Remediation: #{block_remediation(reason, auto_merge?(ws_id, task_id))}",
          "The Watchdog auto-resolved this block #{attempts} time(s) without success " <>
            "and has stopped retrying. Resolve it manually (or force-merge) and the " <>
            "next poll will pick it up."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Re-raise a park that has seen no state change — the low-frequency heartbeat
  for an indefinitely-parked PR (bd-5mzzww / #1448 ask 4).

  `merge_blocked/3` fires **once per block episode** by design (#1226): a block
  the fleet cannot resolve on its own is re-detected on every poll, and paging
  every time drowned the mailbox. That dedupe is correct, but on its own it
  turns an indefinite park into permanent silence — there is no repeat signal
  and, for a non-auto-resolvable block, no automated remediation either. The
  incident PR sat 19 hours on a single page with a live Watchdog polling it
  throughout.

  So a park that has not changed reason re-pages on a cadence measured in
  half-days (`Arbiter.Worker.Watchdog`'s `park_heartbeat_polls`). The subject
  carries the elapsed poll count, which makes each heartbeat a *distinct*
  subject — deliberately outside `merge_blocked/3`'s uncleared-page latch, since
  the whole point is to speak again about something already in the inbox. That
  is a considered tension with #1226, not a regression of it: 12 hours apart,
  not once a minute.
  """
  @spec merge_park_heartbeat(map(), String.t() | nil, atom(), non_neg_integer()) :: :ok
  def merge_park_heartbeat(snapshot, mr_ref, reason, polls) do
    escalate_event(:merge_park_heartbeat, snapshot, fn task_id ->
      ws_id = snapshot.workspace_id

      subject = "#{task_id} still parked after #{polls} polls — #{block_label(reason)}"

      body =
        [
          "#{title_for(task_id)} has been parked on the same block for #{polls} " <>
            "consecutive Watchdog polls with no state change: #{block_label(reason)}.",
          mr_ref && "PR/MR: #{mr_ref}",
          "Reason: #{reason}",
          "Remediation: #{block_remediation(reason, auto_merge?(ws_id, task_id))}",
          "This is a heartbeat, not a new block — the original escalation is " <>
            "already in this inbox and fires only once per episode. Nothing about " <>
            "this PR has moved since; the Watchdog is alive and still polling, but " <>
            "it has no automated path forward and is waiting on you."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate an approved-but-parked PR awaiting a manual merge (bd-b4pwxa).

  Fired by `Arbiter.Worker.Watchdog` when a PR is approved and mergeable (no
  outstanding block) on a lane where `merge.auto_merge` is `false`. auto_merge
  off is a legitimate "ask a human before merging" policy — but the Watchdog used
  to honour it *silently*: it parked the PR and polled forever without ever
  telling the coordinator the PR was ready. Approved-and-done work could sit
  indefinitely with nothing in the inbox (the whole incident this addresses).

  This surfaces the ready-to-merge PR as an addressed `:escalation` **mailbox**
  message (`to_ref: "coordinator"`) — the same shape as `merge_blocked/3` — so it
  lands in `arb inbox` as an actionable item the moment the review passes. A
  block (`merge_blocked/3`) is escalated separately; this fires only when nothing
  is blocking the merge and it is purely awaiting the human decision.

  `snapshot` carries `:task_id` + `:workspace_id`; `mr_ref` is the PR/MR ref (may
  be `nil`); `via_review_gate` names the approval source in the body. Best-effort,
  returns `:ok`.
  """
  @spec approved_awaiting_merge(map(), String.t() | nil, boolean()) :: :ok
  def approved_awaiting_merge(snapshot, mr_ref, via_review_gate) do
    escalate_event(:approved_awaiting_merge, snapshot, fn task_id ->
      subject = "#{task_id} approved — awaiting manual merge (auto_merge off)"

      approval_line =
        if via_review_gate do
          "The ReviewGate approved this PR in-process and no merge block remains."
        else
          "This PR is approved and no merge block remains."
        end

      body =
        [
          "#{title_for(task_id)} is approved and ready to merge, but this workspace " <>
            "has `merge.auto_merge` disabled — so the fleet will not merge it " <>
            "automatically and it is parked awaiting a human decision.",
          mr_ref && "PR/MR: #{mr_ref}",
          approval_line,
          "Merge it now (or set `merge.auto_merge` to true for this workspace) and " <>
            "the Watchdog will complete the task on its next poll. Until then the PR " <>
            "stays open and the Watchdog keeps watching — no work is lost."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {subject, body}
    end)
  end

  @doc """
  Escalate a merged-but-unverified task (bd-9so315).

  Fired once, by whichever close path merged a task carrying
  `verify_after_deploy: true`. The change landed, but its only execution
  context is the long-lived server, so nothing has run the new code yet — this
  is the notification that turns "merged" into an explicit, assigned
  restart-and-observe.

  Addressed `:escalation` (`to_ref: "coordinator"`) rather than a broadcast
  notification: an unobserved deploy is an action item, and the whole failure
  mode this addresses is a task that closed with nobody looking.

  `merged_at` is when the merge landed; the body states whether the **running**
  server booted before that (restart required first) or after (the code is
  already live and can be observed as-is).

  Sent through `escalate_event/3` like every other escalation here, so it
  passes through the shared `:coordinator_escalation` circuit breaker
  (bd-5jr49o) exactly once rather than either bypassing it or carrying a second
  bound of its own. The breaker signature includes the task id, so two tasks
  parked in the same window never share a budget — see
  `Arbiter.CircuitBreakerAdoptionTest`.
  """
  @spec awaiting_verification(map(), String.t() | nil, DateTime.t()) :: :ok
  def awaiting_verification(snapshot, mr_ref, merged_at) do
    escalate_event(:awaiting_verification, snapshot, fn task_id ->
      booted_at = Arbiter.Boot.Time.booted_at()
      stale? = DateTime.compare(booted_at, merged_at) == :lt

      restart_line =
        if stale? do
          "The running server booted before this merge (boot #{iso(booted_at)}, " <>
            "merge #{iso(merged_at)}), so it is still on the old code — " <>
            "**restart it first**, then observe."
        else
          "The running server booted after this merge (boot #{iso(booted_at)}, " <>
            "merge #{iso(merged_at)}), so the merged code is already loaded — " <>
            "observe it directly; no restart needed."
        end

      body =
        [
          "#{title_for(task_id)} merged, but it is flagged `verify_after_deploy` — " <>
            "its only execution context is the long-lived server, so the merge alone " <>
            "proves nothing. The task is parked at `awaiting_verification` and will " <>
            "NOT close until a restart-and-observe result is recorded.",
          mr_ref && "PR/MR: #{mr_ref}",
          restart_line,
          "Record the result:",
          "  arb ticket verify #{task_id} --observed \"<what you saw on the running server>\"",
          "  arb ticket verify #{task_id} --failed   \"<what was still wrong>\"",
          "`--observed` closes the task and persists the evidence; `--failed` " <>
            "persists it and reopens the task for another attempt."
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")

      {"#{task_id} merged — awaiting verification (restart and observe)", body}
    end)
  end

  defp block_subject(task_id, reason), do: "#{task_id} merge blocked — #{block_label(reason)}"

  # The dedupe key (bd-brwx7w). Reasons in one family describe the same
  # real-world block under different names, so they must not page separately:
  #
  #   * `:needs_approval` — the generic "a required approval is missing" path.
  #   * `:needs_nonauthor_approval` — the same PR seen by the Watchdog's
  #     non-author path, which knows the fleet authored it.
  #
  # Two pollers alternating between these two atoms is precisely what produced
  # the ~1/min flood: each poller's per-reason latch reset on every flip.
  defp block_family(reason) when reason in @approval_block_reasons,
    do: @approval_block_reasons

  defp block_family(reason), do: [reason]

  # Blocks the fleet structurally cannot clear by retrying: the forge forbids a
  # PR's author approving it, so no amount of polling changes the answer. These
  # are the ones that earn the post-clear cooldown below. Every other reason
  # (`:conflict`, `:ci_failed`, `:behind_base`, …) *can* resolve and then
  # genuinely recur, so once the coordinator has cleared its page, a fresh
  # occurrence is fresh news and pages again immediately.
  defp fleet_unresolvable?(reason), do: reason in @approval_block_reasons

  # True when this ticket's open `:merge_blocked` escalation already reports
  # this reason-family, or — for a block the fleet cannot resolve — one that
  # did was raised inside the cooldown window. Both checks read the durable
  # message table, so they hold across pollers *and* across restarts, which is
  # what kills the stale duplicates that used to survive a server restart.
  #
  # bd-8if9zt: the item is identified by `(kind, ticket)`. A *different* block
  # on a ticket whose `:merge_blocked` item is still open is not a duplicate:
  # it goes through, and `Escalation.post/1` refreshes that one item to say
  # what blocks the merge now, rather than adding a second. The family's
  # subjects only decide whether the row already says this.
  #
  # Fails open: an unreadable mailbox must never swallow a genuine escalation.
  defp duplicate_block_escalation?(ws_id, task_id, reason) do
    subjects = Enum.map(block_family(reason), &block_subject(task_id, &1))
    scope = [workspace_id: ws_id, task_ref: task_id]

    case Message.last_escalation(:merge_blocked, [open: true] ++ scope) do
      %{subject: subject} ->
        subject in subjects

      nil ->
        fleet_unresolvable?(reason) and
          case Message.last_escalation(:merge_blocked, scope) do
            %{subject: subject} = last -> subject in subjects and within_cooldown?(last)
            nil -> false
          end
    end
  rescue
    _ -> false
  end

  defp within_cooldown?(%{inserted_at: %DateTime{} = at}) do
    cooldown =
      Application.get_env(
        :arbiter,
        :merge_block_escalation_cooldown_ms,
        @default_block_escalation_cooldown_ms
      )

    is_integer(cooldown) and cooldown > 0 and
      DateTime.diff(DateTime.utc_now(), at, :millisecond) < cooldown
  end

  defp within_cooldown?(_), do: false

  # bd-8lnnnt: a pre-flight probe failure (exhausted usage window or expired
  # credentials) is re-detected on *every* dispatch attempt for as long as the
  # underlying condition holds. The incident this dedupes was actually driven
  # by `Arbiter.Workflows.DispatchQueue`'s held-intent drain re-running the
  # doomed probe on `CloudProbe`'s ~5-minute broadcast cadence
  # (see that module's moduledoc) — not, as first suspected, `Autopilot`'s 15s
  # tick — but the fix here is deliberately independent of which caller
  # retries: it dedupes inside `preflight_failed/2` itself, which both
  # `dispatch.ex` call sites go through regardless of what drove the retry.
  # Left undeduped, one task stuck behind an exhausted window paged the
  # coordinator on every retry — 14 identical "pre-flight auth failed"
  # escalations in 75 minutes for a single exhausted 5h window. Mirrors
  # `duplicate_block_escalation?/3` (bd-brwx7w): suppressed while an identical
  # page is still uncleared, and for a cooldown window after it is cleared, so
  # a resolved-then-recurring condition still gets a fresh page rather than
  # resetting the flood. Fails open: an unreadable mailbox must never swallow
  # a genuine escalation.
  #
  # bd-8if9zt: keyed on `(kind, ticket)`. The subject only says whether the
  # last page reported the same cause (throttled vs. broken credentials): a
  # different cause while one is open refreshes that item instead of adding a
  # second.
  defp duplicate_preflight_escalation?(ws_id, task_id, reason) do
    subject = preflight_subject(task_id, reason)
    scope = [workspace_id: ws_id, task_ref: task_id]

    case Message.last_escalation(:preflight_failed, [open: true] ++ scope) do
      %{subject: open_subject} ->
        open_subject == subject

      nil ->
        case Message.last_escalation(:preflight_failed, scope) do
          %{subject: ^subject} = last -> within_preflight_cooldown?(last)
          _ -> false
        end
    end
  rescue
    _ -> false
  end

  defp within_preflight_cooldown?(%{inserted_at: %DateTime{} = at}) do
    cooldown =
      Application.get_env(
        :arbiter,
        :preflight_escalation_cooldown_ms,
        @default_preflight_escalation_cooldown_ms
      )

    is_integer(cooldown) and cooldown > 0 and
      DateTime.diff(DateTime.utc_now(), at, :millisecond) < cooldown
  end

  defp within_preflight_cooldown?(_), do: false

  # bd-8lnnnt: distinguishes "the account is throttled, and will recover on
  # its own" from "credentials are actually broken" — the wording a
  # `:quota_exhausted` refusal used to share with real auth failures
  # ("pre-flight auth failed") misread as a credential problem for what is
  # really a throttle with a known reset. Also doubles as the dedupe key
  # (via `preflight_subject/2`), so the two causes never share a latch.
  defp preflight_verb(%StopReason{category: :quota_exhausted}), do: "pre-flight throttled"
  defp preflight_verb(_reason), do: "pre-flight auth failed"

  defp preflight_subject(task_id, %StopReason{} = reason),
    do: "#{task_id} #{preflight_verb(reason)} — #{StopReason.label(reason)}"

  defp preflight_lead(task_id, %StopReason{category: :quota_exhausted} = reason) do
    "Refused to dispatch #{title_for(task_id)} — the account's usage window is exhausted: " <>
      "#{reason.summary}. This is a throttle, not a credential problem — dispatch resumes " <>
      "on its own once the window resets."
  end

  defp preflight_lead(task_id, reason) do
    "Refused to dispatch #{title_for(task_id)} — agent pre-flight auth probe failed: " <>
      "#{reason.summary}."
  end

  # Whether this workspace merges an approved PR itself. Defaults to `false` on
  # an unreadable workspace, matching `Workspace.auto_merge?/1`'s own default:
  # promising an auto-merge that never comes is the failure this guards against.
  #
  # bd-73zv62: read for the task's repo — a `merge.repos.<repo>.auto_merge`
  # override decides it for that repo.
  defp auto_merge?(ws_id, task_id) when is_binary(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, workspace} ->
        Workspace.auto_merge?(Arbiter.Mergers.scope(workspace, task_repo(task_id)))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp auto_merge?(_, _), do: false

  defp task_repo(task_id) when is_binary(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{repo: repo}} -> repo
      _ -> nil
    end
  end

  defp task_repo(_), do: nil

  defp block_label(:conflict), do: "merge conflict with the base branch"
  defp block_label(:behind_base), do: "branch is behind the base branch"
  defp block_label(:ci_failed), do: "required CI checks are failing"

  defp block_label(:ci_failed_external),
    do:
      "required CI checks are failing for reasons outside this branch " <>
        "(reported as broken infrastructure, not this diff)"

  defp block_label(:needs_approval), do: "required approval is missing"

  defp block_label(:needs_nonauthor_approval),
    do:
      "a required approval from a reviewer other than the author (the fleet cannot self-approve)"

  # bd-df3zlo / #1736 (P4). The merge paths' `{:unknown, _}` coverage answer,
  # waited out and then parked: not a refusal (nothing says the head is
  # unreviewed) and not a merge (nothing says it is reviewed either).
  defp block_label(:coverage_unknown),
    do: "review coverage for the current head could not be established"

  defp block_label(:draft), do: "the PR is still a draft"
  defp block_label(:blocked_other), do: "a forge merge rule is unsatisfied"
  defp block_label(other), do: "merge is blocked (#{other})"

  defp block_remediation(reason, auto_merge?)

  defp block_remediation(:conflict, _auto_merge?),
    do: "rebase or resolve the conflicts with the base branch, then re-push."

  defp block_remediation(:behind_base, _auto_merge?),
    do: "update the branch from its base (merge or rebase) and re-push."

  defp block_remediation(:ci_failed, _auto_merge?),
    do: "fix the failing checks (or re-run flaky ones), then re-push."

  # Pointedly different advice from `:ci_failed`: pushing a fix to *this* branch
  # cannot clear a failure that isn't this branch's fault, and re-running only
  # the failed job re-tests the same broken upstream artifact. The two things
  # that do work are fixing CI repo-wide and forcing a full rebuild.
  defp block_remediation(:ci_failed_external, _auto_merge?),
    do:
      "a worker diagnosed this failure as repo-wide/infrastructure, not caused by " <>
        "this diff — pushing another fix to this branch will not clear it. Fix CI " <>
        "itself, force a full pipeline re-run (`ci_rerun` with mode all_jobs or " <>
        "workflow, NOT a failed-jobs re-run, which reuses the same broken upstream " <>
        "artifact), or force-merge if the failing check is genuinely unrelated."

  defp block_remediation(:coverage_unknown, _auto_merge?),
    do:
      "the merge guard asked whether this head is covered by a review and could not get an " <>
        "answer — usually a forge compare/ancestry call failing, or a base branch it could " <>
        "not read. Check the forge's status and the PR's base branch: a re-review or a new " <>
        "push reopens the decision, and the lane stays parked and watched until one of those " <>
        "happens (nothing merges in the meantime). Merging by hand is the escape hatch until " <>
        "the operator override lands — `arb review cover <task> <sha> --reason \"…\"`, P11 " <>
        "of docs/review-coverage-and-guard-policy.md."

  defp block_remediation(:needs_approval, auto_merge?),
    do:
      "approve the PR, or re-request review if a prior approval was dismissed. " <>
        after_approval_note(auto_merge?)

  # bd-brwx7w: this used to promise "will auto-merge once approved"
  # unconditionally, which is a lie on a `merge.auto_merge: false` workspace —
  # an operator who approves and walks away leaves the PR sitting open forever,
  # and the *same* mailbox already carried an `approved_awaiting_merge/3` page
  # saying the opposite about the same PR.
  defp block_remediation(:needs_nonauthor_approval, auto_merge?),
    do:
      "have a human reviewer (someone other than the PR author) approve the PR — " <>
        "the fleet authored it and the forge forbids self-approval. " <>
        after_approval_note(auto_merge?)

  defp block_remediation(:draft, _auto_merge?), do: "mark the PR ready for review."

  defp block_remediation(:blocked_other, _auto_merge?),
    do: "inspect the PR's merge requirements on the forge and satisfy them."

  defp block_remediation(_other, _auto_merge?), do: "inspect the PR on the forge."

  # What actually happens once the approval lands — conditional on the
  # workspace's merge policy rather than asserted.
  defp after_approval_note(true),
    do:
      "The PR is parked and will auto-merge once approved; no further action is " <>
        "needed to keep it alive."

  defp after_approval_note(false),
    do:
      "The PR is parked, but this workspace has `merge.auto_merge` disabled — so " <>
        "the fleet will not merge it automatically. Merge it yourself once it is " <>
        "approved (or set `merge.auto_merge` to true for this workspace); the " <>
        "Watchdog keeps watching until then, so nothing is lost."

  defp describe_reason(%{message: msg, kind: kind}) when is_binary(msg),
    do: "#{msg} (#{kind})"

  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason(reason), do: inspect(reason)

  defp format_elapsed_seconds(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"

  # A required tracker field had no produced value on the task — name the
  # specific field(s) rather than the generic status_map hint, which would
  # send the operator down the wrong path (this is a missing-value problem, not
  # a config-mismatch one).
  defp sync_hint(%{kind: :gated_fields_missing, missing_fields: names})
       when is_list(names) and names != [] do
    "The task has not produced a value for required tracker field(s): " <>
      "#{Enum.join(names, ", ")}. Populate them on the task " <>
      "(e.g. `arb ticket update <id> --qa-notes ... --deployment-notes ...`) and re-run the sync."
  end

  # Provider explicitly rejected the payload (field-validation gate, required
  # fields not populated, etc.). The provider's real reason is already in the
  # "Error:" line — no secondary hint needed; the status_map hint would be
  # actively misleading here.
  defp sync_hint(%{kind: :validation_failed}), do: nil

  # Auth / permission failures — config-mismatch hint is wrong; name the
  # actual remediation so the operator goes to the right place.
  defp sync_hint(%{kind: :unauthenticated}) do
    "The tracker rejected the credentials — re-authenticate and update the workspace token."
  end

  defp sync_hint(%{kind: :forbidden}) do
    "The tracker rejected the request as forbidden — verify that the API token " <>
      "has the necessary permissions/scopes for this project and operation."
  end

  # A rate-limited sync already retried with backoff (see
  # `Arbiter.Trackers.Sync.do_transition/3`) before reaching escalation — say
  # how many attempts and over what window, so the reader can tell "we tried
  # and the tracker kept refusing" from "we gave up instantly". No config hint:
  # this is transient load (often GitHub's secondary/burst limit, which fires
  # even with primary quota untouched), not a config mismatch.
  defp sync_hint(%{kind: :rate_limited, retry_attempts: attempts, retry_elapsed_ms: elapsed_ms})
       when is_integer(attempts) and is_integer(elapsed_ms) do
    "Retried #{attempts} time(s) over #{format_elapsed_seconds(elapsed_ms)} honoring the " <>
      "tracker's Retry-After/backoff, but the rate limit never cleared. This is very likely " <>
      "transient load (e.g. concurrent workers tripping GitHub's secondary/burst limit) — " <>
      "no action is typically needed unless this recurs."
  end

  defp sync_hint(%{kind: :rate_limited}) do
    "The tracker's rate limit did not clear — this is likely transient load; retry the sync."
  end

  # Transient failures — no config change indicated.
  defp sync_hint(%{kind: :server_error}) do
    "The tracker returned a server error — this is likely transient. " <>
      "Retry the sync or check the tracker's status page."
  end

  defp sync_hint(%{kind: :network}) do
    "A network error occurred reaching the tracker — check connectivity and retry."
  end

  # Genuine config-mismatch: the adapter found the target status in status_map
  # but BFS could not find any path through the configured transition_graph.
  defp sync_hint(%{kind: :no_transition_path}) do
    "No path exists through the configured `transition_graph` to the target status. " <>
      "Reconcile the workspace `status_map` / `transition_graph` with the tracker's " <>
      "actual workflow (see Arbiter.Trackers.Jira.Config) and re-run the sync."
  end

  # BFS planned a route, but when the hop ran, no live transition landed on its
  # destination status — the route passes through a status the issue can't
  # reach from where it is. Hops match by destination, so a stale transition
  # *name* in the graph is harmless; the destination is what needs fixing.
  defp sync_hint(%{kind: :transition_unavailable}) do
    "A hop in the configured `transition_graph` has no live transition landing on its " <>
      "destination status. The error lists the transitions actually available now — " <>
      "correct that hop's destination status (or route the graph through a status the " <>
      "issue can reach) to match the tracker's real workflow " <>
      "(see Arbiter.Trackers.Jira.Config) and re-run the sync."
  end

  # Catch-all for any other unexpected error: demote the config hint to a
  # secondary suggestion rather than the primary explanation.
  defp sync_hint(_reason) do
    "If this persists unexpectedly, also check that the workspace `status_map` / " <>
      "`transition_graph` matches the tracker's real workflow " <>
      "(see Arbiter.Trackers.Jira.Config)."
  end

  # ---- core ---------------------------------------------------------------

  # A notification must be scoped to a workspace (Message.workspace_id is
  # required), so a worker with no workspace_id has nowhere to post.
  defp post(event, %{workspace_id: ws_id} = snapshot) when is_binary(ws_id) do
    if enabled?(ws_id) do
      Message.notify(build(event, snapshot))
    end

    :ok
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.post/2 swallowed: #{Exception.message(e)}")
      :ok
  end

  defp post(_event, _snapshot), do: :ok

  # Actionable escalations are addressed mailbox messages (not broadcast
  # notifications) so they queue in `arb inbox` for the coordinator. They are NOT
  # gated by the `coordinator_notifications` toggle — silencing routine completion
  # noise must never silence a "your credentials expired" alarm. A worker with
  # no workspace_id has nowhere to post (Message.workspace_id is required).
  defp escalate(event, %{workspace_id: ws_id} = snapshot, %StopReason{} = reason)
       when is_binary(ws_id) do
    {subject, body} = escalation_payload(event, snapshot, reason)
    task_id = Map.get(snapshot, :task_id)

    send_unless_broken(ws_id, task_id, subject, fn ->
      Escalation.post(%{
        kind: event,
        from_ref: task_id || "system",
        workspace_id: ws_id,
        task_ref: task_id,
        subject: subject,
        body: body
      })
    end)

    :ok
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.escalate/3 swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate(_event, _snapshot, _reason), do: :ok

  # Shared plumbing for the escalations above (`tracker_sync_failed/3` ..
  # `approved_awaiting_merge/3`): guard on a binary `workspace_id`, resolve
  # `task_id`, hand both to `build_fun`, and post the `{subject, body}` it
  # returns through `Escalation.post/1` as an escalation of `kind` —
  # swallowing any failure so a notification bug never disrupts the caller's
  # real work. `build_fun` may return `:skip` instead of `{subject, body}` to
  # suppress sending without erroring (used by `merge_blocked/3`'s dedupe).
  # `opts[:task_ref]` overrides the default `task_ref: task_id` — needed by
  # `overage_alert/3`, whose `task_ref` is the raw (possibly-nil) snapshot
  # `:task_id` rather than the "system"-defaulted one used for `subject`/`body`.
  defp escalate_event(kind, snapshot, build_fun),
    do: escalate_event(kind, snapshot, [], build_fun)

  defp escalate_event(kind, %{workspace_id: ws_id} = snapshot, opts, build_fun)
       when is_binary(ws_id) do
    task_id = Map.get(snapshot, :task_id, "system")

    case build_fun.(task_id) do
      :skip ->
        :ok

      {subject, body} ->
        send_unless_broken(ws_id, task_id, subject, fn ->
          Escalation.post(%{
            kind: kind,
            from_ref: task_id,
            workspace_id: ws_id,
            task_ref: Keyword.get(opts, :task_ref, task_id),
            subject: subject,
            body: body
          })
        end)

        :ok
    end
  rescue
    e ->
      Logger.debug("CoordinatorNotifier.#{kind} swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp escalate_event(_kind, _snapshot, _opts, _build_fun), do: :ok

  # The last line of defence (bd-5jr49o). Every escalation this module sends —
  # including the ones that already carry a purpose-built dedupe, and the ones
  # that don't — passes through the shared circuit breaker, keyed on
  # workspace + task + normalised subject line.
  #
  # The bound here is deliberately loose. Four other call sites (PRPatrol
  # filing, the Watchdog's merge escalations, the pre-flight refusal, the
  # DispatchQueue re-drain) have their own tighter breakers in front of this
  # one; this exists to catch the auto-escalating path nobody has thought about
  # yet — the next bd-brwx7w — not to second-guess an ordinary busy hour.
  #
  # `Arbiter.CircuitBreaker` writes its own trip page straight to
  # `Message.send_mail/1` rather than back through this module, so a tripped
  # `:coordinator_escalation` breaker can still announce itself.
  defp send_unless_broken(ws_id, task_id, subject, fun) do
    CircuitBreaker.guard(
      :coordinator_escalation,
      [task_id, subject],
      [
        workspace_id: ws_id,
        task_ref: task_id,
        detail:
          "This escalation repeated past the last-line-of-defence bound. Whatever " <>
            "raises it has no breaker of its own — that is worth fixing at the source."
      ],
      fun
    )
  end

  defp escalation_payload(:credential_expired, snapshot, %StopReason{} = reason) do
    adapter = Map.get(snapshot, :adapter)
    source = Map.get(snapshot, :source, :worker_report)
    gate_closed? = Map.get(snapshot, :gate_closed?, true)
    adapter_label = if adapter, do: inspect(adapter), else: "agent"
    subject = credential_expired_subject(adapter, source)

    body =
      [
        "Proactive credential probe: #{adapter_label} failed authentication (#{source_description(source)}).",
        reason.summary,
        reason.remediation && "Remediation: #{reason.remediation}",
        dispatch_gate_note(source, gate_closed?)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {subject, body}
  end

  # bd-8lq2g7: a *subordinate* pass (merge-queue CI fix pass / conflict
  # resolver) runs under the task's own id, after the task's own run opened
  # its PR. Its death is not the
  # task's worker dying, and the generic payload below said it was — subject
  # `"<task_id> stopped — exited without completing (exit 0)"` with the
  # remediation "run `arb worker resume <task_id>`". That hint is both wrong and
  # unfollowable: `resume` is refused while the primary is parked, so the
  # operator stops the healthy primary and the whole ReviewGate re-runs from
  # round 1. Attribute the stop to the pass that actually stopped instead.
  defp escalation_payload(:worker_stopped, %{task_id: task_id} = snapshot, %StopReason{} = reason) do
    case Arbiter.Worker.subordinate_label(snapshot) do
      nil ->
        primary_escalation_payload(:worker_stopped, snapshot, reason)

      label ->
        registry_key = Map.get(snapshot, :registry_key) || task_id
        subject = "#{task_id} #{label} stopped — #{StopReason.label(reason)}"

        body =
          [
            "The #{label} for #{title_for(task_id)} stopped: #{reason.summary}.",
            "Task: #{task_id}",
            "Worker: #{registry_key} (subordinate #{label} — NOT the task's own worker)",
            "Repo: #{repo(snapshot)}",
            exit_line(reason),
            activity_line(snapshot),
            subordinate_remediation(reason),
            "The task's own worker is unaffected — it is still parked awaiting its " <>
              "merge/review and must be left alone. Do NOT run `arb worker stop`/" <>
              "`arb worker resume` on #{task_id}: that kills the healthy worker and " <>
              "re-runs the review gate from scratch. #{retry_hint(label, task_id, registry_key)}"
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {subject, body}
    end
  end

  defp escalation_payload(event, snapshot, %StopReason{} = reason),
    do: primary_escalation_payload(event, snapshot, reason)

  defp adapter_short_name(nil), do: "Agent"
  defp adapter_short_name(adapter), do: adapter |> Module.split() |> List.last()

  # `source` keys the subject so a `:usage_poll` episode and a
  # `:periodic_probe`/`:worker_report` episode for the same adapter are two
  # distinct, independently-deduped mailbox rows (bd-6jjgk0) rather than one
  # row two unrelated signals fight over.
  defp credential_expired_subject(adapter, :usage_poll),
    do: "#{adapter_short_name(adapter)} credentials expired — usage-poll signal"

  defp credential_expired_subject(adapter, _source),
    do: "#{adapter_short_name(adapter)} credentials expired — proactive detection"

  defp source_description(:periodic_probe), do: "the Watchdog's periodic CLI probe"
  defp source_description(:usage_poll), do: "the /api/oauth/usage-family poll"
  defp source_description(_worker_report), do: "N consecutive worker auth deaths"

  # `gate_closed?` is the adapter's actual `CredentialWatchdog.expired?/1`
  # state at the moment this escalation was raised/restated, not inferred
  # from `source` — since `:usage_poll` (bd-6jjgk0 finding 1) no longer
  # closes the dispatch gate on its own (`CredentialWatchdog.gate_source?/1`),
  # it usually arrives here `false` for that source, and the note says so
  # instead of falsely claiming dispatch is suspended while workers keep
  # running fine on their own, self-refreshed session (#1875). It can still
  # be `true` for `:usage_poll` if a *different*, gate-closing expiry (the
  # periodic CLI probe, or N worker deaths) happens to be outstanding for the
  # same adapter at the same time — in that case the note says the gate is
  # closed but still names the probe's own credential as a distinct failure.
  defp dispatch_gate_note(:usage_poll, true) do
    "Note: new worker dispatches for this adapter are suspended until credentials are " <>
      "restored — a separate, gate-closing expiry is also outstanding for this adapter. " <>
      "This escalation itself was detected via the probe's own cached OAuth token (the " <>
      "/api/oauth/usage-family poll), a separate cache from what worker dispatches read — " <>
      "the worker CLI self-refreshes its own session on each run (#1875). If " <>
      "re-authenticating the operator's CLI doesn't clear this specific escalation, the " <>
      "probe's cached token needs its own refresh."
  end

  defp dispatch_gate_note(:usage_poll, false) do
    "Note: new worker dispatches for this adapter are NOT suspended by this escalation. " <>
      "This failure was detected via the probe's own cached OAuth token (the " <>
      "/api/oauth/usage-family poll), a separate cache from what worker dispatches read — " <>
      "the worker CLI self-refreshes its own session on each run and has kept dispatching " <>
      "fine (#1875). Re-authenticating the operator's CLI is still the fix; the probe's own " <>
      "cached token needs its own refresh to clear this specific escalation."
  end

  defp dispatch_gate_note(_source, true),
    do:
      "Note: new worker dispatches for this adapter are suspended until credentials are restored."

  defp dispatch_gate_note(_source, false), do: nil

  # Categories whose remediation is nothing but "re-dispatch (the task)" —
  # `:exited_without_done` ("Review the transcript, then re-dispatch"),
  # `:stalled` ("stop and re-dispatch the task"), `:crashed` ("check stderr,
  # then re-dispatch"). For a subordinate that verb points at the TASK, which is
  # the exact harm this payload exists to prevent, and the merge queue already
  # owns the pass's own retry — so those lines are dropped.
  @task_redispatch_only [:exited_without_done, :stalled, :crashed]

  # Every other category's remediation is about the environment, the account, or
  # the harness (re-authenticate, wait for the quota window, top up credits, use
  # a 1M-context model, pin the agent CLI) and applies no matter who re-runs the
  # pass. Dropping those wholesale left the coordinator with an escalation that
  # said only "the queue retries automatically" — i.e. retry straight back into
  # the same expired credential. Carry them, pass-scoped so the label can't be
  # read as an instruction to re-dispatch the task (bd-8lq2g7).
  defp subordinate_remediation(%StopReason{category: category})
       when category in @task_redispatch_only,
       do: nil

  defp subordinate_remediation(%StopReason{remediation: nil}), do: nil

  defp subordinate_remediation(%StopReason{remediation: remediation}),
    do: "Remediation (for the pass, not the task): #{remediation}"

  # The merge queue owns re-dispatch for both subordinate passes: the Watchdog
  # re-dispatches a fix pass on its next poll once this worker is terminal
  # (`fix_pass_active?/1` treats :failed as not active), and the queue re-runs
  # conflict resolution on its next tick. That re-dispatch goes through
  # `Worker.start_or_reap_terminal/1`, which reaps this now-terminal worker so
  # it can't squat the subordinate registry key and no-op every retry — without
  # that, the promise below would be a lie and the task would park forever
  # (bd-8lq2g7). The manual fallback names the SUBORDINATE key, the only
  # intervention that is safe here: `arb worker stop` takes a registry key
  # verbatim, so it reaches the pass without touching the task's own worker.
  defp retry_hint("fix pass", task_id, registry_key),
    do:
      "The merge queue re-dispatches the fix pass automatically on its next poll " <>
        "(this terminal pass is reaped when it does); inspect the run with " <>
        "`arb worker runs #{task_id}`, and if the pass itself is wedged stop it by " <>
        "its own key — `arb worker stop #{registry_key}` — never by the task id."

  defp retry_hint(_label, task_id, registry_key),
    do:
      "The merge queue owns the retry; inspect the run with `arb worker runs #{task_id}`, " <>
        "and if the pass itself is wedged stop it by its own key — " <>
        "`arb worker stop #{registry_key}` — never by the task id."

  defp primary_escalation_payload(event, %{task_id: task_id} = snapshot, %StopReason{} = reason) do
    verb =
      case event do
        :worker_stopped -> "stopped"
        :preflight_failed -> preflight_verb(reason)
        :spawn_failed -> "spawn failed"
      end

    subject = "#{task_id} #{verb} — #{StopReason.label(reason)}"

    lead =
      case event do
        :worker_stopped ->
          "Worker for #{title_for(task_id)} stopped: #{reason.summary}."

        :preflight_failed ->
          preflight_lead(task_id, reason)

        :spawn_failed ->
          "Worker for #{title_for(task_id)} failed to spawn: #{reason.summary}."
      end

    body =
      [
        lead,
        "Task: #{task_id}",
        "Repo: #{repo(snapshot)}",
        exit_line(reason),
        activity_line(snapshot),
        reason.remediation && "Remediation: #{reason.remediation}",
        resume_hint(event, task_id, reason)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    {subject, body}
  end

  # bd-auma3z: a stopped worker's worktree (committed/uncommitted
  # progress) is preserved, so the operator can continue rather than re-dispatching
  # from scratch. Offer the resume verb right in the escalation. Only for
  # `:worker_stopped` — a `:preflight_failed` refusal happens before any work,
  # so there is no worktree to resume.
  # bd-b6noq9: a destroyed workspace is the one stop where the worktree is NOT
  # preserved — the whole point of the category. Offering the resume verb here
  # points the operator (and any automation reading the page) at a directory
  # that no longer exists, which is exactly the contradictory advice the #1930
  # escalations arrived with. Checked ahead of the generic clause below.
  defp resume_hint(_event, _task_id, %StopReason{category: :workspace_destroyed}), do: nil

  defp resume_hint(:worker_stopped, task_id, _reason),
    do: "Resume: run `arb worker resume #{task_id}` to continue from the preserved worktree."

  # bd-bi5pn0: a spawn failure happens before the agent ever ran, so there is
  # no prior session/worktree progress to resume from — a plain re-dispatch
  # (not `resume`) is the correct retry.
  defp resume_hint(:spawn_failed, task_id, _reason),
    do: "Re-dispatch: run `arb dispatch #{task_id}` to retry."

  defp resume_hint(_event, _task_id, _reason), do: nil

  defp repo(%{repo: repo}) when is_binary(repo) and repo != "", do: repo
  defp repo(_), do: "unknown"

  defp exit_line(%StopReason{exit_status: nil, signal: nil}), do: nil
  defp exit_line(%StopReason{exit_status: nil}), do: nil

  defp exit_line(%StopReason{exit_status: code, signal: nil}),
    do: "Exit code: #{code}"

  defp exit_line(%StopReason{exit_status: code, signal: sig}),
    do: "Exit code: #{code} (signal #{sig})"

  defp activity_line(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :activity) do
      %{label: label} when is_binary(label) -> "Last activity: #{label}"
      label when is_binary(label) and label != "" -> "Last activity: #{label}"
      _ -> nil
    end
  end

  defp activity_line(_), do: nil

  # ---- payload construction ----------------------------------------------

  defp build(:completed, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "completed", fn title ->
      "#{title} completed in #{format_duration(elapsed_seconds(snapshot))}"
    end)
  end

  defp build(:failed, %{task_id: task_id} = snapshot) do
    case review_gate_reason(snapshot) do
      nil ->
        duration = format_duration(elapsed_seconds(snapshot))

        base(task_id, snapshot, "failed", fn title ->
          case exit_code(snapshot) do
            nil -> "#{title} failed after #{duration}"
            code -> "#{title} failed after #{duration} — exit code #{code}"
          end
        end)

      reason ->
        base(task_id, snapshot, "escalated — #{review_gate_label(reason)}", fn title ->
          "#{title} escalated — #{review_gate_sentence(reason, snapshot)}"
        end)
    end
  end

  defp build(:waiting, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "awaiting review", fn title ->
      case mr_ref(snapshot) do
        nil -> "#{title} — awaiting review"
        ref -> "#{title} opened MR #{ref} — awaiting review"
      end
    end)
  end

  defp build(:pipeline_failed, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "CI pipeline failed", fn title ->
      case mr_ref(snapshot) do
        nil ->
          "#{title} — CI pipeline failed (parked; human action required)"

        ref ->
          "#{title} MR #{ref} — CI pipeline failed (parked; human action required)"
      end
    end)
  end

  defp build(:awaiting_review_stuck, %{task_id: task_id} = snapshot) do
    base(task_id, snapshot, "stuck awaiting review", fn title ->
      case mr_ref(snapshot) do
        nil ->
          "#{title} stuck at awaiting_review — escalated (no terminal MR outcome)"

        ref ->
          "#{title} stuck at awaiting_review (MR #{ref}) — escalated (no terminal MR outcome)"
      end
    end)
  end

  defp base(task_id, snapshot, subject_suffix, body_fun) do
    title = title_for(task_id)

    %{
      workspace_id: snapshot.workspace_id,
      from_ref: task_id,
      subject: "#{task_id} #{subject_suffix}",
      body: body_fun.(title)
    }
  end

  # ---- lookups ------------------------------------------------------------

  # The task's human-readable title, falling back to the task id when the Issue
  # row can't be read (e.g. ad-hoc runs, or a workspace with no tracker row).
  # Second-precision UTC — the restart-vs-merge comparison is an ordering
  # question, and microseconds only make the escalation body harder to read.
  defp iso(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp title_for(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %{title: title}} when is_binary(title) and title != "" -> title
      _ -> task_id
    end
  rescue
    _ -> task_id
  end

  # Default-on: only an explicit `false` disables auto-posts. A missing or
  # unreadable workspace falls back to enabled. The new key wins when both are
  # set; the legacy key is consulted only when the new key is absent, so
  # workspaces configured before the bd-2bsahq rename keep their opt-out.
  defp enabled?(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, %{config: config}} ->
        config = config || %{}
        legacy_default = Map.get(config, @legacy_config_key, true)
        Map.get(config, @config_key, legacy_default) != false

      _ ->
        true
    end
  rescue
    _ -> true
  end

  defp exit_code(%{meta: meta}) when is_map(meta), do: Map.get(meta, :exit_status)
  defp exit_code(_), do: nil

  # bd-3wgdie: a worker parked by ReviewGate (non-convergence or an
  # unparseable verdict) completed its work and exited cleanly — it lost a
  # review argument, it did not crash. `:failed` + `exit code 0` reads as a
  # dead worker and buries the fact that a human decision is needed. Detect
  # the two review-gate `failure_reason`s here so `build/2` can give them
  # distinct, honest wording instead of the generic crash template.
  defp review_gate_reason(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :failure_reason) do
      :review_gate_rejected -> :rejected
      :review_gate_inconclusive -> :inconclusive
      _ -> nil
    end
  end

  defp review_gate_reason(_), do: nil

  defp review_gate_label(:rejected), do: "ReviewGate did not converge"
  defp review_gate_label(:inconclusive), do: "ReviewGate inconclusive"

  defp review_gate_sentence(:rejected, snapshot) do
    "ReviewGate did not converge#{rounds_suffix(snapshot)} — the implementer and reviewer " <>
      "did not reach agreement and it needs your judgement (see review_gate_rounds_list or " <>
      "your inbox escalation for the full argument)."
  end

  defp review_gate_sentence(:inconclusive, snapshot) do
    "ReviewGate produced no parseable verdict#{rounds_suffix(snapshot)} and needs your " <>
      "judgement (see your inbox escalation for details)."
  end

  defp rounds_suffix(%{meta: meta}) when is_map(meta) do
    case Map.get(meta, :review_gate_rounds) do
      n when is_integer(n) -> " after #{n} round(s)"
      _ -> ""
    end
  end

  defp rounds_suffix(_), do: ""

  defp mr_ref(%{meta: meta}) when is_map(meta),
    do: Map.get(meta, :mr_ref) || Map.get(meta, :mr_url)

  defp mr_ref(_), do: nil

  # ---- formatting ---------------------------------------------------------

  defp elapsed_seconds(%{started_at: %DateTime{} = started_at}),
    do: max(DateTime.diff(DateTime.utc_now(), started_at), 0)

  defp elapsed_seconds(_), do: 0

  defp format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when seconds < 3600 do
    minutes = div(seconds, 60)

    case rem(seconds, 60) do
      0 -> "#{minutes}m"
      rest -> "#{minutes}m #{rest}s"
    end
  end

  defp format_duration(seconds) do
    hours = div(seconds, 3600)

    case div(rem(seconds, 3600), 60) do
      0 -> "#{hours}h"
      minutes -> "#{hours}h #{minutes}m"
    end
  end
end
