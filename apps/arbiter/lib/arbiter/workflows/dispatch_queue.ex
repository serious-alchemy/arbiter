defmodule Arbiter.Workflows.DispatchQueue do
  @moduledoc """
  Per-workspace draining dispatch queue for quota-aware throttling (bd-7cd38f).

  Modeled on `Arbiter.Workflows.MergeQueue`: one GenServer per workspace,
  registered under `Arbiter.Workflows.DispatchQueueRegistry` keyed by
  `workspace_id`. It is the holding pen for dispatches the quota gate
  (`Arbiter.Quota.Gate.Throttle`) decided to HOLD near the 5h cap, plus the
  per-workspace state for `:continue`-mode overage alerting.

  ## `:throttle` — hold + drain

  When `Arbiter.Worker.Dispatch.dispatch/2`'s quota seam gets `{:hold, reason}`,
  it calls `hold/4`, which enqueues the `(task_id, opts)` intent here instead of
  spawning a worker. The held task is NOT transitioned to `:active` — it
  stays in its pre-dispatch `state`, so nothing is lost even across a restart
  (the task is still resolvable and re-dispatchable from its state).

  The queue drains — re-running `dispatch/2` for held intents in priority order —
  on two triggers:

    * `{:quota_updated, ws, quota}` on PubSub topic `quota:<ws>` — a fresh capture
      that may show headroom (bd-5boun6's broadcast).
    * a `reset_5h_at` `Process.send_after` timer — a deterministic wake at the 5h
      window reset, so the queue drains even if no traffic produces a fresh
      capture.

  On drain, each intent is re-checked against the current gate/quota; only those
  the gate now `:allow`s are dispatched (with `skip_quota_gate: true` so they
  don't re-enter the gate and loop). Order is priority-first, FIFO tiebreak —
  the same `{priority, opened_at}` key `MergeQueue` uses, except that the
  priority is the *effective* one (an epic's floor, `EffectivePriority`), read
  when the intent is held (ES4).

  ## A held intent for a task that has since closed is dropped, not retried forever (bd-atjyzu)

  A held intent outlives the task it was created for: nothing un-holds it when
  the task closes out from under it. Two mechanisms together make sure that
  doesn't turn into a permanent, silently-failing re-dispatch every drain:

    * `drop/2` — the task's `:close` action calls this directly
      (`Arbiter.Tasks.Issue.Changes.DropDispatchHold`) so the hold is removed
      the instant the task closes, not on the next drain.
    * a terminal-vs-retryable split in the requeue path — a drain that still
      finds a stale hold (the close raced the drop, or predates this fix)
      re-dispatches it and gets back a **terminal** failure, which is dropped
      instead of requeued:
        - `{:task_closed, _}` — `Dispatch.dispatch/2`'s `ensure_dispatchable/2`
        - `{:task_not_found, _}` — `Dispatch.dispatch/2`'s `load_task/1`
      Every other failure shape is **retryable** — quota still held, a live
      agent session already on the task, a migration/preflight hiccup, a
      transient exception/exit. Retryable does not mean unbounded: each
      requeue is recorded against the `:dispatch_queue_redispatch` circuit
      breaker (bd-5jr49o), and once the same task+failure signature trips it
      the held intent is dropped with exactly one coordinator page instead of
      re-draining forever. See `requeue_or_drop/4`.

      The one exemption is a failure that carries a `retry_not_before` — the
      quota-exhausted shape below, historical as of bd-2jgs2h (see that
      section). That shape already has its own wall-clock backoff, so it
      bypasses the breaker entirely and requeues unchanged: a long quota wait
      can never be mistaken for a runaway.

  ## A held intent for a task that has moved on is dropped, not replayed (bd-6omte4)

  Each item records the task's `state` and newest run when it was held. A
  drain refuses an item whose task has since been closed, has a live worker,
  has a newer run (it was re-dispatched) or changed state (stopped back to
  the queue, moved to merging) — `stale_reason/1` — and logs which. Two
  sources also cancel it outright, with a log line: a dispatch that went ahead
  for the task (`Arbiter.Worker.Dispatch`) and stopping the task
  (`Arbiter.Worker.stop/3` by task id). A second hold for a task already held
  replaces the intent, keeping its place in the queue.

  What is held is readable: `held_items/1`, `held_item/2` and `describe/1`
  back `arb quota`'s held-dispatch list and the held phase on
  `arb worker show`.

  ## A quota-exhausted pre-flight failure is held, not redrained every cycle (bd-8lnnnt)

  Historical: this held a `{:auth_check_failed, %StopReason{category:
  :quota_exhausted}}` shape that `Dispatch.dispatch/2`'s per-dispatch auth
  probe (`Dispatch.run_preflight/2`) could produce even when the last
  captured quota snapshot looked fine. bd-2jgs2h retired that probe — see
  `Arbiter.Worker.Dispatch`'s moduledoc and `docs/quota-and-auth.md` for the
  current posture. `dispatch/2`'s own auth guard now only ever produces
  `:auth_expired`, so this shape is currently unreachable from a real
  dispatch through this queue; `Arbiter.Worker.PreflightHold` (which this hold
  delegates policy to) still matches on it, and is kept in case a future
  producer of a classified `:quota_exhausted` refusal reappears here. Without
  a hold, a held intent whose dispatch
  fails this way gets `{:requeue, item}`'d (below) and re-attempted on the very
  next drain trigger — and `CloudProbe` broadcasts `quota_updated`
  every 5 minutes for as long as anything is held, so the doomed probe reran on
  a ~5-minute cadence for the whole incident this bug tracks (bd-7qbavq: 12
  identical failures, each preceded by a `quota_gate_bypass` event, landing on
  5-minute wall-clock boundaries — the queue drain, not `Arbiter.Board.Autopilot`'s
  15s tick, which would have produced ~300 attempts in that window, not 12).

  So a quota-exhausted pre-flight failure sets `retry_not_before` on the
  requeued item (`Arbiter.Worker.PreflightHold.retry_not_before/3` — the same
  policy `Autopilot` uses for its own tick: the probe's reported reset time
  when known, else a bounded exponential backoff), and `maybe_drain/1` skips
  re-checking/re-dispatching a held item until that time passes, regardless of
  what the gate says. `schedule_reset_drain/1`'s timer wakes the queue at
  `next_reset_at/1` — the earliest of any held provider's snapshot reset_at
  *or* any item's own `retry_not_before` — so a hold that falls after the raw
  snapshot reset (the reset-buffer or a no-reset-time backoff) still gets its
  own precise wake instead of waiting on the next 5-minute broadcast.

  ## A provider quota stop is held until the reset, resumed, or rerouted (bd-a6vh2x)

  A run that *stopped* because its provider account ran out of allowance
  (`Arbiter.Worker.StopReason` `:quota_exhausted`: agy `RESOURCE_EXHAUSTED`,
  Claude's session/weekly limit, grok's free-usage limit) is not a crash.
  `Arbiter.Worker` opens a timed account hold (`Arbiter.Providers.Pause.quota_hold/4`)
  and enqueues the ticket here with `quota_resume: true`, the hold's reset
  time as `retry_not_before`, and the reset as the wake time. The item then
  waits like any held dispatch (`arb quota` → Held dispatches, "held — quota"
  on the board, no `run_crashed` attention) and leaves in one of two ways:

    * **resume** — the reset passes and the account is no longer held:
      `Arbiter.Worker.Dispatch.dispatch/2` turns `quota_resume: true` into a
      session-level resume of the same session in the preserved worktree;
    * **reroute** — before the reset, another provider is neither paused nor
      quota-gated and the ticket's provider constraint lets routing pick it
      (`reroutable?/3`): the item drains early, and the same resume continues the
      work there from the preserved worktree, briefed from its git state.

  ## `:continue` — overage alert debounce

  When the gate returns `{:overage, spend_usd}` (dispatch proceeds past the cap),
  the dispatcher calls `record_overage/3`. This process tracks the windowed
  overage spend against the workspace's `overage_alert_usd` threshold and fires
  exactly one `Arbiter.Messages.CoordinatorNotifier.overage_alert/3` per threshold
  crossing (debounced on the crossed multiple) — it never stops dispatch. Once
  the spend is back under the threshold, or the threshold is raised or removed,
  it calls `overage_cleared/2` to clear the alert (bd-7gt8rm).

  ## Injection seams (start_link opts / app-env)

    * `:dispatcher` → `:arbiter, :dispatch_queue_dispatcher` → `Arbiter.Worker.Dispatch`
      — the module whose `dispatch/2` drains held intents. Tests pass a stub.
    * `:quota_reader` → `Arbiter.Quota` — supplies `latest_for_workspace/2`
      snapshots on drain (one per distinct provider held).
    * `:notifier` → `Arbiter.Messages.CoordinatorNotifier` — the overage-alert channel.
    * `:auto_subscribe` (default `true`) — subscribe to the `quota:<ws>` topic.
  """

  use GenServer

  require Logger

  alias Arbiter.CircuitBreaker
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Tasks.EffectivePriority
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker
  alias Arbiter.Worker.PreflightHold
  alias Arbiter.Worker.ResumeSlot
  alias Arbiter.Workers.Run
  alias Arbiter.Workflows.DispatchQueueSupervisor

  require Ash.Query

  @typedoc """
  A held dispatch intent. `provider` is the agent type the dispatch resolved to
  (`:claude` / `:codex` / `:gemini`) — the drain re-checks each item against
  *that* provider's quota snapshot (bd-2mpo3f), so a Codex hold is not gated on
  Anthropic headroom and vice versa.
  """
  @type item :: %{
          task_id: String.t(),
          opts: keyword(),
          priority: non_neg_integer(),
          opened_at: DateTime.t(),
          reason: term(),
          provider: atom(),
          preflight_failures: non_neg_integer(),
          retry_not_before: DateTime.t() | nil,
          held_state: atom() | nil,
          held_run_id: String.t() | nil
        }

  defmodule State do
    @moduledoc false
    defstruct [
      :workspace_id,
      :workspace,
      :dispatcher,
      :quota_reader,
      :notifier,
      :auto_subscribe,
      :reset_timer_ref,
      items: [],
      last_overage_alert_multiple: 0
    ]
  end

  # ---- public API (facade over the per-workspace registry) ----------------

  @doc """
  Start a dispatch queue for a workspace. See moduledoc for options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  HOLD a dispatch intent for `workspace_id` (the `:throttle` path). Resolves —
  starting if necessary — the workspace's queue and enqueues the intent.

  `provider` is the agent type the held dispatch resolved to; the drain re-checks
  the intent against that provider's quota snapshot (bd-2mpo3f). Defaults to
  `:claude`.

  Returns `:ok` on enqueue, `{:error, reason}` if the queue can't be reached (the
  caller then fails open and dispatches, rather than dropping the work).
  """
  @spec hold(String.t(), String.t(), keyword(), term(), atom()) :: :ok | {:error, term()}
  def hold(workspace_id, task_id, opts, reason, provider \\ :claude)

  def hold(workspace_id, task_id, opts, reason, provider)
      when is_binary(workspace_id) and is_binary(task_id) do
    with {:ok, pid} <- DispatchQueueSupervisor.ensure_started(workspace_id) do
      GenServer.call(pid, {:hold, task_id, opts, reason, provider})
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, r -> {:error, {:exit, r}}
  end

  def hold(_workspace_id, _task_id, _opts, _reason, _provider), do: {:error, :no_workspace}

  @doc """
  `hold/5` for a dispatch that must not be replayed before `until` (bd-a6vh2x):
  a provider quota stop's reset time. The item is skipped by the drain until
  then — unless it can be rerouted to another provider sooner (see the
  moduledoc).
  """
  @spec hold_until(String.t(), String.t(), keyword(), term(), atom(), DateTime.t()) ::
          :ok | {:error, term()}
  def hold_until(workspace_id, task_id, opts, reason, provider, %DateTime{} = until)
      when is_binary(workspace_id) and is_binary(task_id) do
    with {:ok, pid} <- DispatchQueueSupervisor.ensure_started(workspace_id) do
      GenServer.call(pid, {:hold, task_id, opts, reason, provider, until})
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, r -> {:error, {:exit, r}}
  end

  @doc """
  Record windowed overage `spend_usd` for `workspace_id` (the `:continue` path)
  and fire an alert if it crossed a new `overage_alert_usd` multiple. Best-effort
  — never blocks or fails a dispatch.
  """
  @spec record_overage(String.t(), Issue.t(), float(), atom() | nil) :: :ok
  def record_overage(workspace_id, task, spend_usd, provider \\ nil)

  def record_overage(workspace_id, %Issue{} = task, spend_usd, provider)
      when is_binary(workspace_id) and is_number(spend_usd) do
    with {:ok, pid} <- DispatchQueueSupervisor.ensure_started(workspace_id) do
      GenServer.call(pid, {:record_overage, task, spend_usd * 1.0, provider})
    end

    :ok
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def record_overage(_workspace_id, _task, _spend, _provider), do: :ok

  @doc "Force a drain cycle. Returns `:ok` once it completes."
  @spec drain(GenServer.server()) :: :ok
  def drain(server \\ __MODULE__), do: GenServer.call(server, :drain)

  @doc """
  Drop any held intent for `task_id` in `workspace_id`'s queue (bd-atjyzu).

  Called from the task's `:close` teardown so a closed task's hold is
  removed the moment it closes rather than waiting to be discovered — and
  requeued anyway — on the next drain trigger. Best-effort: `:ok` whether or
  not a queue is running, or the task was ever held there.
  """
  #
  # `why` (bd-6omte4) is logged when an intent was actually dropped, so a
  # cancelled hold is never silent: the task was re-dispatched, or stopped.
  @spec drop(String.t(), String.t(), String.t() | nil) :: :ok
  def drop(workspace_id, task_id, why \\ nil)

  def drop(workspace_id, task_id, why) when is_binary(workspace_id) and is_binary(task_id) do
    case DispatchQueueSupervisor.whereis(workspace_id) do
      pid when is_pid(pid) -> GenServer.call(pid, {:drop, task_id, why})
      _ -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  def drop(_workspace_id, _task_id, _why), do: :ok

  @doc """
  Cancel whatever intent is held for `task_id`, in whichever workspace the
  task belongs to (bd-6omte4), logging `why`. `true` when one was held.
  Called when the task is stopped by hand: a held fix round must not
  start after the operator stopped the task.
  """
  @spec cancel(String.t(), String.t()) :: boolean()
  def cancel(task_id, why) when is_binary(task_id) do
    with %Issue{workspace_id: ws_id} when is_binary(ws_id) <- load_task(task_id),
         %{} <- held_item(ws_id, task_id) do
      drop(ws_id, task_id, why)
      true
    else
      _ -> false
    end
  end

  @doc """
  The intent held for `task_id` in `workspace_id`'s queue, or nil
  (bd-6omte4). Best-effort: nil if the queue isn't running.
  """
  @spec held_item(String.t() | nil, String.t()) :: item() | nil
  def held_item(workspace_id, task_id) when is_binary(workspace_id) and is_binary(task_id) do
    workspace_id |> held_items() |> Enum.find(&(&1.task_id == task_id))
  end

  def held_item(_workspace_id, _task_id), do: nil

  @doc "Every intent held in `workspace_id`'s queue. `[]` if it isn't running."
  @spec held_items(String.t() | nil) :: [item()]
  def held_items(workspace_id) when is_binary(workspace_id) do
    case DispatchQueueSupervisor.whereis(workspace_id) do
      pid when is_pid(pid) -> pid |> state() |> Map.get(:items, [])
      _ -> []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  def held_items(_workspace_id), do: []

  @doc """
  A held intent as an operator reads it (bd-6omte4): which task, on which
  provider, why the gate held it, since when, and what it will do when it
  drains — `intent` is `"ReviewGate fix round 2"`, `"resume"` or
  `"dispatch"`, and `fix_round` the round number, if it is one.
  """
  @spec describe(item()) :: %{
          task_id: String.t(),
          provider: atom(),
          reason: String.t(),
          held_since: DateTime.t() | nil,
          retry_not_before: DateTime.t() | nil,
          intent: String.t(),
          fix_round: pos_integer() | nil
        }
  def describe(%{task_id: task_id} = item) do
    opts = Map.get(item, :opts) || []
    fix_round = Keyword.get(opts, :review_gate_fix_round_attempts)

    %{
      task_id: task_id,
      provider: item_provider(item),
      reason: reason_text(Map.get(item, :reason)),
      held_since: Map.get(item, :opened_at),
      retry_not_before: Map.get(item, :retry_not_before),
      intent: intent(opts, fix_round),
      fix_round: fix_round
    }
  end

  @doc """
  `describe/1`'s map (or an item) as JSON for the API, MCP and `arb`: string
  provider with its label, ISO-8601 times. nil passes through.
  """
  @spec serialize_held(map() | nil) :: map() | nil
  def serialize_held(nil), do: nil

  def serialize_held(%{opts: _} = item), do: item |> describe() |> serialize_held()

  def serialize_held(%{task_id: _} = held) do
    %{
      task_id: held.task_id,
      provider: held.provider && to_string(held.provider),
      provider_label: provider_label(held.provider),
      reason: held.reason,
      intent: held.intent,
      fix_round: held.fix_round,
      held_since: iso(held.held_since),
      retry_not_before: iso(held.retry_not_before)
    }
  end

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(_), do: nil

  defp intent(_opts, round) when is_integer(round), do: "ReviewGate fix round #{round}"

  defp intent(opts, _round) do
    if Keyword.get(opts, :resume) == true or Keyword.get(opts, :quota_resume) == true,
      do: "resume",
      else: "dispatch"
  end

  @doc """
  A held provider as an operator names it. The agent type `:gemini` is the
  Antigravity CLI (`agy`), whose quota `arb quota` shows as Antigravity.
  """
  @spec provider_label(atom() | String.t() | nil) :: String.t()
  def provider_label(provider) when provider in [:gemini, "gemini"], do: "Antigravity (agy)"
  def provider_label(provider) when provider in [:claude, "claude"], do: "Claude"
  def provider_label(provider) when provider in [:codex, "codex"], do: "Codex"
  def provider_label(nil), do: "unknown provider"
  def provider_label(provider), do: to_string(provider)

  @doc """
  The operator-facing wording of a gate's hold reason: the phrase
  `Arbiter.Quota.Gate.Throttle` attaches (`"7d quota 91% ≥ 90%"`), else
  the window it names, else the term itself.
  """
  @spec reason_text(term()) :: String.t()
  def reason_text(%{phrase: phrase}) when is_binary(phrase) and phrase != "", do: phrase
  def reason_text(%{window: window}) when not is_nil(window), do: "#{window} quota"
  def reason_text(nil), do: "quota"
  def reason_text(reason) when is_binary(reason), do: reason
  def reason_text(reason), do: inspect(reason)

  @doc "Return a snapshot of the queue state for inspection / tests."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @doc """
  Whether a task is currently held in `workspace_id`'s queue. Best-effort:
  `false` if the queue isn't running.
  """
  @spec held?(String.t(), String.t()) :: boolean()
  def held?(workspace_id, task_id) when is_binary(workspace_id) and is_binary(task_id) do
    case DispatchQueueSupervisor.whereis(workspace_id) do
      pid when is_pid(pid) ->
        pid |> state() |> Map.get(:items, []) |> Enum.any?(&(&1.task_id == task_id))

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def held?(_workspace_id, _task_id), do: false

  # ---- GenServer callbacks ------------------------------------------------

  @impl true
  def init(opts) do
    # bd-6i7yzq: writes this process makes are attributed to it (`Arbiter.Actor`).
    Arbiter.Actor.put(Arbiter.Actor.autopilot())

    workspace_id =
      case Keyword.fetch(opts, :workspace_id) do
        {:ok, id} when is_binary(id) and id != "" -> id
        _ -> raise ArgumentError, "DispatchQueue requires :workspace_id"
      end

    auto_subscribe = Keyword.get(opts, :auto_subscribe, true)
    if auto_subscribe, do: Phoenix.PubSub.subscribe(Arbiter.PubSub, "quota:" <> workspace_id)

    state = %State{
      workspace_id: workspace_id,
      workspace: load_workspace(workspace_id),
      dispatcher:
        Keyword.get(
          opts,
          :dispatcher,
          Application.get_env(:arbiter, :dispatch_queue_dispatcher, Arbiter.Worker.Dispatch)
        ),
      quota_reader: Keyword.get(opts, :quota_reader, Arbiter.Quota),
      notifier: Keyword.get(opts, :notifier, Arbiter.Messages.CoordinatorNotifier),
      auto_subscribe: auto_subscribe,
      items: [],
      last_overage_alert_multiple: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:hold, task_id, opts, reason, provider}, from, %State{} = state),
    do: handle_call({:hold, task_id, opts, reason, provider, nil}, from, state)

  def handle_call({:hold, task_id, opts, reason, provider, until}, _from, %State{} = state) do
    item = %{new_item(state, task_id, opts, reason, provider) | retry_not_before: until}

    # A second hold for a task already held replaces the intent (bd-6omte4):
    # the newest dispatch is the one wanted — a later fix round's findings, a
    # resume on another provider — while the queue position and any
    # pre-flight backoff stay with the task.
    items =
      if already_held?(state, task_id) do
        Enum.map(state.items, fn
          %{task_id: ^task_id} = held -> replace_intent(held, item)
          other -> other
        end)
      else
        [item | state.items]
      end

    state = %{state | items: items}

    # A held intent needs a deterministic wake at the 5h reset even if no fresh
    # capture arrives — (re)arm the reset timer from the latest snapshot.
    state = schedule_reset_drain(state)
    {:reply, :ok, state}
  end

  def handle_call({:record_overage, task, spend, provider}, _from, %State{} = state) do
    # Re-read the threshold: raising or removing it clears the alert
    # (bd-7gt8rm), and a drain may not have run since the change.
    {reply, state} = state |> reload_workspace() |> do_record_overage(task, spend, provider)
    {:reply, reply, state}
  end

  def handle_call(:drain, _from, %State{} = state) do
    {:reply, :ok, drain_and_reschedule(state)}
  end

  def handle_call({:drop, task_id, why}, _from, %State{} = state) do
    {dropped, items} = Enum.split_with(state.items, &(&1.task_id == task_id))

    for item <- dropped, why do
      Logger.warning(
        "DispatchQueue: dropped the held #{describe(item).intent} for #{task_id}: #{why}"
      )
    end

    {:reply, :ok, schedule_reset_drain(%{state | items: items})}
  end

  def handle_call(:state, _from, %State{} = state) do
    {:reply, snapshot(state), state}
  end

  @impl true
  def handle_info({:quota_updated, _ws_id, _quota}, %State{} = state) do
    {:noreply, drain_and_reschedule(state)}
  end

  def handle_info(:drain_on_reset, %State{} = state) do
    {:noreply, drain_and_reschedule(%{state | reset_timer_ref: nil})}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  # A drained intent whose off-process dispatch failed comes back here so it is
  # retried on a later drain trigger — no work is dropped (finding 3). Re-arm the
  # reset timer since we may have gone from empty back to non-empty.
  #
  # A competing `hold/5` for the same task can land while the drain Task that
  # produces this cast is still in flight (finding 2, bd-8lnnnt round 2):
  # `maybe_drain/1` removes the task from `state.items` optimistically before
  # dispatching, so a fresh `hold/5` for that same task in the gap sees
  # `already_held?/2` false and inserts a new `retry_not_before: nil` item.
  # If this cast then just no-op'd on "already held", the computed hold would
  # be silently discarded and the task left eligible to redrain immediately —
  # so merge the requeued hold fields onto whatever is currently present
  # instead of dropping them.
  @impl true
  def handle_cast({:requeue, item}, %State{} = state) do
    {:noreply, schedule_reset_drain(%{state | items: merge_requeued_item(state.items, item)})}
  end

  # ---- drain --------------------------------------------------------------

  defp drain_and_reschedule(state) do
    state
    |> reload_workspace()
    |> maybe_drain()
    |> schedule_reset_drain()
  end

  # Reload the workspace so a runtime config change (mode / threshold) is picked
  # up on the next drain, mirroring MergeQueue's per-cycle workspace reload.
  defp reload_workspace(%State{workspace_id: ws_id} = state) do
    %{state | workspace: load_workspace(ws_id) || state.workspace}
  end

  defp maybe_drain(%State{items: []} = state), do: state

  defp maybe_drain(%State{} = state) do
    # A quota-exhausted pre-flight failure holds its item until its own
    # `retry_not_before` passes (bd-8lnnnt) — set aside before the gate check
    # even runs, since the gate has no notion of this per-item hold.
    now = DateTime.utc_now()
    gate = Arbiter.Quota.gate_for_workspace(state.workspace)
    {on_hold, eligible} = Enum.split_with(state.items, &preflight_held?(&1, now))

    # bd-a6vh2x: a provider quota stop waits for its reset, but not if routing
    # can already hand the ticket to a provider with headroom — that one leaves
    # the hold now and is replayed (and rerouted) by the drain below.
    {rerouted, on_hold} =
      Enum.split_with(on_hold, &(quota_resume?(&1) and reroutable?(state, gate, &1)))

    eligible = eligible ++ rerouted

    # One snapshot read per distinct provider held in this queue (bd-2mpo3f) —
    # a Codex hold must be re-checked against CodexQuota, not AnthropicQuota, or
    # it would drain on Anthropic's headroom (or never drain at all, since a
    # Codex-only install has no Anthropic snapshot).
    snapshots = provider_snapshots(state)
    # P7 (§4.2): the gate's thresholds resolve `min(account, workspace)`, so
    # the drain re-check has to hand it the same account `Dispatch` does or a
    # held intent could drain on a ceiling the dispatcher would re-hold at.
    accounts = provider_accounts(state)

    # Partition (fast: a pure gate check per item) into those the gate still
    # holds and those there is now headroom for. The gate check and quota read
    # are cheap; the expensive part — the real dispatch of each drained intent —
    # is handed off to a supervised Task below so it never runs inside (and
    # blocks) this GenServer's message loop (finding 3).
    {to_dispatch, keep} =
      eligible
      |> Enum.sort_by(&queue_order_key/1)
      |> Enum.split_with(fn item ->
        provider = item_provider(item)
        quota = Map.get(snapshots, provider)
        account = Map.get(accounts, provider)
        gate_opts = [account: account]

        # bd-5ef587: a pause outlives quota headroom. A paused item is released
        # only when routing now lands on a different, unpaused, ungated
        # provider; otherwise it stays queued until the pause is lifted.
        if paused?(provider, account) do
          reroutable?(state, gate, item)
        else
          task = exempt_task(state, item, account)

          not match?({:hold, _}, gate.check(task, quota, state.workspace, gate_opts)) and
            slot_free?(state, item)
        end
      end)

    # Optimistically remove the to-dispatch intents now; the drain Task casts
    # `{:requeue, item}` back for any that fail, so nothing is dropped.
    _ = spawn_drain(state, to_dispatch)
    %{state | items: on_hold ++ keep}
  end

  # The P0 pace exemption (bd-6bxv7h) reads the held ticket's own priority, so
  # a P0 held at its exempt cap drains the moment it is back under it rather
  # than waiting for the paced line to catch up. The read only happens when the
  # account grants an exemption at all; off, the check stays task-less exactly
  # as before. Fails open to `nil` (no exemption).
  defp exempt_task(%State{workspace: workspace}, %{task_id: task_id}, account) do
    if Arbiter.Quota.Gate.pace_exempt_priority({account, workspace}) do
      case Ash.get(Issue, task_id) do
        {:ok, %Issue{} = task} -> task
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  # bd-zkmvia: a held round for an In-progress ticket holds no slot while it
  # waits (`SlotGate.holds_slot?/1`), so replaying it is a new admission:
  # headroom in the quota is not enough, the cap needs room too. The item is
  # still queued here, so `ResumeSlot.admit/2` judges the ticket as not holding.
  # Fails open: an unreadable ticket or cap must not strand the round.
  defp slot_free?(%State{items: items}, %{task_id: task_id, opts: opts}) do
    with true <- Keyword.get(opts, :review) != true,
         {:ok, %Issue{state: :active} = task} <- Ash.get(Issue, task_id) do
      # This process cannot ask itself (`held?/2` is a call), so it names the
      # held tasks.
      held_ids = Enum.map(items, & &1.task_id)
      match?({:ok, _}, ResumeSlot.admit(task, origin: :automatic, held_ids: held_ids))
    else
      _ -> true
    end
  rescue
    _ -> true
  end

  # bd-5ef587: would a replay of this pause-held item route to another
  # provider that is neither paused nor quota-gated? A caller-forced provider
  # (`:agent_type` / `:agent_adapter`) is never re-routed.
  defp reroutable?(%State{} = state, gate, %{task_id: task_id, opts: opts} = item) do
    with nil <- Keyword.get(opts, :agent_type),
         nil <- Keyword.get(opts, :agent_adapter),
         {:ok, %Issue{} = task} <- Ash.get(Issue, task_id),
         {alt, _reason, _decision} <-
           Arbiter.Agents.ProviderRouting.implementer_provider(
             task,
             state.workspace,
             Keyword.get(opts, :routing_role, :resume)
           ),
         true <- alt != item_provider(item) do
      account = safe_account(state, alt)

      not paused?(alt, account) and
        not match?(
          {:hold, _},
          gate.check(nil, safe_latest(state, alt), state.workspace, account: account)
        )
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp paused?(provider, account) do
    Arbiter.Providers.Pause.for_provider(provider) != nil or
      (match?(%Arbiter.Accounts.ProviderAccount{}, account) and
         Arbiter.Providers.Pause.for_account(account) != nil)
  end

  defp quota_resume?(%{opts: opts}) when is_list(opts),
    do: Keyword.get(opts, :quota_resume) == true

  defp quota_resume?(_item), do: false

  defp preflight_held?(%{retry_not_before: %DateTime{} = at}, now),
    do: DateTime.compare(now, at) == :lt

  defp preflight_held?(_item, _now), do: false

  # Dispatch the drained intents off-process, sequentially in the priority order
  # already established by the caller, so headroom is consumed highest-priority
  # first. Fire-and-forget under a supervisor; failures are re-queued via cast.
  defp spawn_drain(_state, []), do: :ok

  defp spawn_drain(%State{dispatcher: dispatcher, workspace_id: ws_id}, items) do
    queue = self()

    start_drain_task(fn ->
      Enum.each(items, fn item ->
        case stale_reason(item) do
          nil -> drain_item(queue, ws_id, dispatcher, item)
          why -> skip_stale(item, why)
        end
      end)
    end)
  end

  defp drain_item(queue, ws_id, dispatcher, item) do
    case safe_dispatch(dispatcher, item) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        requeue_or_drop(queue, ws_id, item, reason)

      other ->
        requeue_or_drop(queue, ws_id, item, other)
    end
  end

  # `maybe_drain/1` already took the item out of `state.items`, so skipping it
  # is dropping it.
  defp skip_stale(item, why) do
    Logger.warning(
      "DispatchQueue: not draining the held #{describe(item).intent} for #{item.task_id}: " <>
        "#{why}; the held intent is dropped"
    )

    :ok
  end

  # ---- stale held intents (bd-6omte4) ---------------------------------------
  #
  # A held intent is replayed verbatim, possibly hours later. By then the task
  # may have moved on: on bd-aro53b an agy ReviewGate fix round was held for
  # quota, and 13 minutes later the coordinator re-dispatched the task on
  # Claude. Nothing cancelled the held round, so the next drain would have
  # replayed an old fix round onto a task with a live worker on its worktree.
  #
  # So a drain first asks whether the task is still the one that was held:
  #
  #   * it is closed or gone;
  #   * a worker is live on it — someone else is working it now;
  #   * it has a newer run than when it was held — it was re-dispatched (and
  #     that run may have finished already);
  #   * its state changed — it was stopped back to the queue, demoted, or
  #     moved to merging. A promotion out of the backlog is the one move that
  #     leaves a held dispatch still wanted.
  #
  # Any of these drops the intent, with a log line saying which. Nil = still
  # current, drain it.
  @doc false
  @spec stale_reason(item()) :: String.t() | nil
  def stale_reason(%{task_id: task_id} = item) do
    case load_task(task_id) do
      nil -> "the task no longer exists"
      %Issue{state: :closed} -> "the task is closed"
      %Issue{} = task -> moved_on(task, item)
    end
  end

  defp moved_on(%Issue{} = task, item) do
    held_run = Map.get(item, :held_run_id, :unknown)
    held_state = Map.get(item, :held_state)

    cond do
      Keyword.get(item.opts, :review) != true and live_worker?(task.id) ->
        "a worker is live on the task"

      held_run != :unknown and latest_run_id(task.id) != held_run ->
        "the task was re-dispatched after it was held (run #{latest_run_id(task.id)})"

      state_moved?(held_state, task.state) ->
        "the task moved from #{held_state} to #{task.state} after it was held"

      true ->
        nil
    end
  end

  defp live_worker?(task_id) do
    case Worker.whereis(task_id) do
      nil -> false
      pid -> not match?(%{state: :finished}, Worker.state(pid))
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp state_moved?(nil, _now), do: false
  defp state_moved?(same, same), do: false
  defp state_moved?(:backlog, :queued), do: false
  defp state_moved?(_held, _now), do: true

  # A dispatch failure is either terminal (the task can never dispatch again
  # as-is, e.g. it closed underneath the hold) or retryable (a later drain
  # might succeed, e.g. quota is still held). Terminal failures are dropped —
  # `maybe_drain/1` already removed the item from `state.items` optimistically
  # before dispatch, so "drop" here just means "don't requeue it" — a
  # requeue would otherwise re-dispatch and fail the same way forever
  # (bd-atjyzu). Retryable failures requeue exactly as before.
  #
  # Terminal (drop, don't requeue):
  #   * `{:task_closed, _}`     — `Dispatch.dispatch/2`'s `ensure_dispatchable/2`
  #   * `{:task_not_found, _}`  — `Dispatch.dispatch/2`'s `load_task/1`
  #
  # Retryable (requeue, same as before): everything else — quota still held,
  # a live agent session already running the task, a migration/preflight
  # hiccup, a transient exception/exit, the quota-exhausted pre-flight
  # refusal `hold_item/2` already gives its own backoff.
  #
  # A *retryable* failure that keeps recurring identically is the third case
  # (bd-5jr49o). Retryable means "a later drain might succeed", but nothing in
  # the classification above can tell a task that will fail this way forever
  # from one that is merely waiting. The shared circuit breaker supplies the
  # missing bound: once the same task has failed the same way more than K times
  # inside the window, the item is dropped rather than requeued, and the
  # coordinator is paged once. Keyed on task + failure shape — the attempt count
  # and any elapsed time in the reason are scrubbed out of the signature, so a
  # growing counter cannot defeat the match.
  #
  # **Except** when the failure already carries its own bounded hold. A
  # quota-exhausted pre-flight refusal (bd-8lnnnt) gets a `retry_not_before`
  # from `PreflightHold`, which is exactly the "waiting, not broken" case the
  # breaker cannot distinguish by failure shape alone: an exhausted 5h window
  # with no parseable reset time backs off 30s → … → 15m (capped), so six
  # attempts land inside ~16 minutes and would trip a 5-per-hour breaker long
  # before the window actually resets — dropping an intent that was going to
  # self-heal and turning it into manual work (bd-7qbavq was 12 such failures).
  # Those items are already rate-limited by the hold and already paged once by
  # the `:preflight_auth_failed` breaker at the dispatch site, so they requeue
  # as they did before this change, and never count against the re-dispatch
  # breaker.
  defp requeue_or_drop(queue, ws_id, item, reason) do
    if terminal_dispatch_failure?(reason) do
      Logger.info(
        "DispatchQueue: dropping held intent for #{item.task_id}, terminal dispatch failure: #{inspect(reason)}"
      )

      :ok
    else
      held = hold_item(item, reason)

      cond do
        held.retry_not_before != nil ->
          GenServer.cast(queue, {:requeue, held})

        # A replay the quota gate or a pause still holds is waiting, not
        # failing: it requeues as often as it takes and is never counted
        # toward the breaker, which would drop a legitimately held intent
        # after K drains (bd-a6vh2x, seen on bd-4df3ma).
        still_held?(reason) ->
          GenServer.cast(queue, {:requeue, held})

        redispatch_broken?(ws_id, item, reason) ->
          Logger.warning(
            "DispatchQueue: circuit breaker open for #{item.task_id}; dropping held intent " <>
              "instead of re-draining (last failure: #{inspect(reason)})"
          )

          :ok

        true ->
          GenServer.cast(queue, {:requeue, held})
      end
    end
  end

  defp still_held?({:quota_held, _}), do: true
  defp still_held?({:provider_paused, _, _}), do: true
  defp still_held?(_reason), do: false

  defp redispatch_broken?(ws_id, item, reason) do
    match?(
      {:suppress, _},
      CircuitBreaker.check(
        :dispatch_queue_redispatch,
        [item.task_id, failure_shape(reason)],
        workspace_id: ws_id,
        task_ref: item.task_id,
        detail:
          "This held intent kept failing to dispatch the same way on every drain. " <>
            "It has been dropped from the queue; re-dispatch it by hand once the " <>
            "underlying cause is fixed."
      )
    )
  end

  # The coarse shape of a dispatch failure, stable across attempts. A
  # `StopReason` struct's summary carries elapsed times and window resets, so
  # only its category keys the breaker.
  defp failure_shape({:auth_check_failed, %{category: category}}),
    do: [:auth_check_failed, category]

  defp failure_shape({tag, %{category: category}}) when is_atom(tag), do: [tag, category]
  defp failure_shape({tag, _detail}) when is_atom(tag), do: [tag]
  defp failure_shape(reason) when is_atom(reason), do: [reason]
  defp failure_shape(reason), do: [inspect(reason)]

  defp terminal_dispatch_failure?({:task_closed, _}), do: true
  defp terminal_dispatch_failure?({:task_not_found, _}), do: true
  defp terminal_dispatch_failure?(_), do: false

  # A dispatch that failed on this drain gets requeued (below) so it isn't
  # dropped. If the failure was a quota-exhausted pre-flight refusal
  # (bd-8lnnnt), set `retry_not_before` so `maybe_drain/1` doesn't re-run the
  # same doomed CLI probe on the next 5-minute broadcast — see this module's
  # moduledoc and `Arbiter.Worker.PreflightHold`. Any other failure shape
  # requeues with no hold, unchanged from before.
  defp hold_item(item, reason) do
    count = Map.get(item, :preflight_failures, 0) + 1

    item
    |> Map.put(:preflight_failures, count)
    |> Map.put(
      :retry_not_before,
      PreflightHold.retry_not_before(reason, count, DateTime.utc_now())
    )
  end

  # Prefer the app-supervised Task.Supervisor; fall back to an unsupervised
  # process if it isn't running (e.g. a bare unit test), so drain still proceeds.
  defp start_drain_task(fun) do
    case Process.whereis(Arbiter.Workflows.DispatchDrainSupervisor) do
      pid when is_pid(pid) -> Task.Supervisor.start_child(pid, fun)
      _ -> {:ok, spawn(fun)}
    end
  rescue
    _ -> {:ok, spawn(fun)}
  end

  defp safe_dispatch(dispatcher, %{task_id: task_id, opts: opts}) do
    dispatcher.dispatch(task_id, Keyword.put(opts, :skip_quota_gate, true))
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    :exit, r -> {:error, {:exit, r}}
  end

  # `%{provider_atom => snapshot_row | nil}` for every provider currently held.
  defp provider_snapshots(%State{items: items} = state) do
    items
    |> Enum.map(&item_provider/1)
    |> Enum.uniq()
    |> Map.new(&{&1, safe_latest(state, &1)})
  end

  defp provider_accounts(%State{items: items} = state) do
    items
    |> Enum.map(&item_provider/1)
    |> Enum.uniq()
    |> Map.new(&{&1, safe_account(state, &1)})
  end

  defp safe_account(%State{workspace_id: ws_id}, provider) do
    Arbiter.Accounts.Resolver.get(Arbiter.Quota.account_id(ws_id, provider))
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_latest(%State{quota_reader: reader, workspace_id: ws_id}, provider) do
    reader.latest_for_workspace(ws_id, provider)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # (Re)arm the deterministic reset-drain timer from the earliest primary-window
  # reset across the providers currently held — whichever provider frees up first
  # should wake the queue. No-op when nothing is queued or no reset time is known.
  defp schedule_reset_drain(%State{items: []} = state), do: cancel_reset_timer(state)

  defp schedule_reset_drain(%State{} = state) do
    state = cancel_reset_timer(state)

    case next_reset_at(state) do
      %DateTime{} = reset ->
        delay = DateTime.diff(reset, DateTime.utc_now(), :millisecond)

        if delay > 0 do
          ref = Process.send_after(self(), :drain_on_reset, delay)
          %{state | reset_timer_ref: ref}
        else
          # The reset time is already in the past — the window has rolled. Do NOT
          # re-arm against a past time or a held-items cycle becomes a hot loop.
          # The staleness check in Gate.over_cap?/in_overage? now fails open for
          # stale snapshots, so the next drain trigger (PubSub quota_updated or
          # a new hold/5 call that re-reads the snapshot) will clear any queued
          # items.
          state
        end

      _ ->
        state
    end
  end

  # The wake time is the earliest of: a provider's snapshot reset_at, or any
  # held item's own `retry_not_before` (finding 2, bd-8lnnnt round 2) — a
  # `PreflightHold`-derived hold can fall after the snapshot's reset_at (the
  # +60s buffer, or a fallback backoff with no reset_at at all), and without
  # this the queue only re-arms a timer for the snapshot's reset, then finds
  # `maybe_drain/1` still holds the item and has nothing left to wake it until
  # the next `quota_updated` broadcast (up to 5 minutes late).
  defp next_reset_at(%State{} = state) do
    snapshot_resets =
      state
      |> provider_snapshots()
      |> Map.values()
      |> Enum.map(&Snapshot.normalize/1)
      |> Enum.flat_map(fn
        %{reset_at: %DateTime{} = reset} -> [reset]
        _ -> []
      end)

    item_holds =
      state.items
      |> Enum.flat_map(fn
        %{retry_not_before: %DateTime{} = at} -> [at]
        _ -> []
      end)

    now = DateTime.utc_now()

    # A stale/past snapshot reset_at must not win over a still-future item
    # hold just for being numerically smaller — `schedule_reset_drain/1`
    # already declines to arm a timer for a past time, so filter those out
    # here rather than letting one suppress a real future wake.
    (snapshot_resets ++ item_holds)
    |> Enum.filter(&(DateTime.compare(&1, now) == :gt))
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp cancel_reset_timer(%State{reset_timer_ref: nil} = state), do: state

  defp cancel_reset_timer(%State{reset_timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | reset_timer_ref: nil}
  end

  # ---- overage alerting (debounced) ---------------------------------------

  defp do_record_overage(%State{} = state, task, spend, provider) do
    case Workspace.quota_overage_alert_usd(state.workspace) do
      alert_usd when is_number(alert_usd) and alert_usd > 0 ->
        multiple = trunc(Float.floor(spend / alert_usd))
        last = state.last_overage_alert_multiple

        cond do
          multiple > last ->
            fire_overage_alert(state, task, spend, alert_usd, provider)
            {{:alerted, multiple}, %{state | last_overage_alert_multiple: multiple}}

          multiple == 0 ->
            # Under the threshold — the window rolled or the threshold was
            # raised: the alert's condition has cleared (bd-7gt8rm).
            clear_overage_alert(state, provider)
            {:ok, %{state | last_overage_alert_multiple: 0}}

          multiple < last ->
            # Spend dropped (the 5h window rolled) — reset the debounce so the
            # next crossing alerts again, but don't alert on the way down.
            {:ok, %{state | last_overage_alert_multiple: multiple}}

          true ->
            {:ok, state}
        end

      _ ->
        # No threshold configured — record silently, never alert, and clear
        # an alert raised under a threshold since removed (bd-7gt8rm).
        clear_overage_alert(state, provider)
        {:ok, %{state | last_overage_alert_multiple: 0}}
    end
  end

  defp clear_overage_alert(%State{} = state, provider) do
    state.notifier.overage_cleared(state.workspace_id, provider)
    :ok
  rescue
    e ->
      Logger.debug("DispatchQueue.clear_overage_alert swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  defp fire_overage_alert(%State{} = state, %Issue{} = task, spend, alert_usd, provider) do
    snapshot = %{workspace_id: state.workspace_id, task_id: task.id, provider: provider}
    state.notifier.overage_alert(snapshot, spend, alert_usd)
    :ok
  rescue
    e ->
      Logger.debug("DispatchQueue.fire_overage_alert swallowed: #{Exception.message(e)}")
      :ok
  catch
    :exit, _ -> :ok
  end

  # ---- helpers ------------------------------------------------------------

  defp replace_intent(held, item) do
    held = Map.merge(held, Map.take(item, [:opts, :reason, :provider, :held_state, :held_run_id]))

    # A later hold that names no replay time (an ordinary gate hold) leaves the
    # one already recorded; a quota stop's reset replaces it.
    case item.retry_not_before do
      %DateTime{} = at -> %{held | retry_not_before: at}
      _ -> held
    end
  end

  defp already_held?(%State{items: items}, task_id),
    do: Enum.any?(items, &(&1.task_id == task_id))

  # Insert `item` if its task isn't already present; otherwise merge its hold
  # fields onto the existing entry rather than dropping them (finding 2,
  # bd-8lnnnt round 2) — takes the later of the two `retry_not_before` values
  # and the higher `preflight_failures` count, on the theory that either
  # represents a hold computed from real information and neither should be
  # allowed to erase the other.
  defp merge_requeued_item(items, item) do
    case Enum.find(items, &(&1.task_id == item.task_id)) do
      nil ->
        [item | items]

      existing ->
        merged = merge_hold_fields(existing, item)

        Enum.map(items, fn
          %{task_id: task_id} when task_id == item.task_id -> merged
          other -> other
        end)
    end
  end

  defp merge_hold_fields(existing, requeued) do
    %{
      existing
      | retry_not_before: later_retry(existing.retry_not_before, requeued.retry_not_before),
        preflight_failures:
          max(
            Map.get(existing, :preflight_failures, 0),
            Map.get(requeued, :preflight_failures, 0)
          )
    }
  end

  defp later_retry(nil, nil), do: nil
  defp later_retry(nil, %DateTime{} = b), do: b
  defp later_retry(%DateTime{} = a, nil), do: a

  defp later_retry(%DateTime{} = a, %DateTime{} = b) do
    if DateTime.compare(a, b) == :gt, do: a, else: b
  end

  # `held_state` / `held_run_id` are what the task looked like when it was
  # held (bd-6omte4): the drain compares them against the task as it is then,
  # so a held intent never lands on a task that has moved on — see
  # `stale_reason/1`.
  defp new_item(%State{} = _state, task_id, opts, reason, provider) do
    task = load_task(task_id)

    %{
      task_id: task_id,
      opts: opts,
      priority: priority_of(task),
      opened_at: DateTime.utc_now(),
      reason: reason,
      provider: provider,
      preflight_failures: 0,
      retry_not_before: nil,
      held_state: task && task.state,
      held_run_id: latest_run_id(task_id)
    }
  end

  # The provider a held intent was gated on. Items enqueued before this field
  # existed (or by a caller that omitted it) read as :claude — the historical
  # Anthropic-only behaviour.
  defp item_provider(item) do
    case Map.get(item, :provider) do
      p when is_atom(p) and not is_nil(p) -> p
      p when is_binary(p) and p != "" -> String.to_existing_atom(p)
      _ -> :claude
    end
  rescue
    ArgumentError -> :claude
  end

  # Task priority (0 = P0 highest … 4 = P4 lowest) for the queue order key: the
  # *effective* priority, so an epic's floor lifts its children's held intents
  # the way it lifts them on the board (`docs/design/epic-aware-scheduling.md`
  # §6.4: effective priority decides *when*; own priority decides what may be
  # spent, which this key never touches). Resolved through `EpicFloor` when the
  # intent is held; defaults to P2 if the task can't be read.
  defp priority_of(%Issue{} = task), do: EffectivePriority.effective(task)
  defp priority_of(_task), do: 2

  # A read that exits is as unreadable as one that raises: a checkout against a
  # pool (or, under test, a sandbox proxy) that is gone exits with `:noproc`,
  # and `cancel/2` runs on `Worker.stop/2`'s way to stopping a worker, which
  # must not die of a lookup that was only ever best-effort (bd-jw7cb0).
  defp load_task(task_id) do
    case Ash.get(Issue, task_id) do
      {:ok, %Issue{} = task} -> task
      _ -> nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # The id of the task's own newest run (not a ReviewGate reviewer's, which
  # runs under a synthetic `<task>#…` id). A resume links its new run to this
  # one, so it is the run a held resume was going to continue.
  defp latest_run_id(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> case do
      [%Run{id: id}] -> id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Priority-first, FIFO tiebreak — same shape as MergeQueue.queue_order_key/1.
  defp queue_order_key(item) do
    {Map.get(item, :priority) || 2, opened_at_key(item.opened_at)}
  end

  defp opened_at_key(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp opened_at_key(_), do: 9_223_372_036_854_775_807

  defp load_workspace(ws_id) do
    case Ash.get(Workspace, ws_id) do
      {:ok, ws} -> ws
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp snapshot(%State{} = s) do
    %{
      workspace_id: s.workspace_id,
      items: s.items,
      last_overage_alert_multiple: s.last_overage_alert_multiple,
      dispatcher: s.dispatcher,
      quota_reader: s.quota_reader
    }
  end
end
