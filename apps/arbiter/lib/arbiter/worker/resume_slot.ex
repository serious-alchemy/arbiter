defmodule Arbiter.Worker.ResumeSlot do
  @moduledoc """
  Whether a resume may re-enter a task right now, given the dispatch cap
  (bd-92mx1m).

  ## The incident

  On 2026-09-23, with the install-wide cap at 1 (then `conductor_system_max_concurrent`,
  since removed by DC1), bd-3usjdj ran out
  of ReviewGate fix rounds and parked at `:waiting_on_you`, which releases its
  slot (bd-45pwo1). Autopilot correctly admitted bd-d7mfdq into the freed slot.
  Four seconds later the coordinator ran `arb worker resume bd-3usjdj`, and
  `Arbiter.Worker.Dispatch.resume/2` re-entered it without asking anyone about
  the cap: two tasks in flight under a cap of 1, and the scheduler could admit
  nothing until both merged.

  ## The rule: is the ticket In progress?

  Not who is resuming it. A ticket holds a slot exactly while its stored state
  is `:active` (bd-asxw4e) — the same rule the board's `slots_used` counts by
  (`Arbiter.Tasks.SlotGate.holds_slot?/1`), so the gate can never disagree
  with the number on the board:

    * **Held** — the ticket is `:active`, whatever its worker did: working,
      between ReviewGate rounds, failed mid hand-off so an automatic round can
      replace it, parked on a human, or cut off by a restart. The resume
      passes through **uncapped**. This is the #1969/#1995 no-deadlock
      guarantee: a round for a ticket already In progress is never a new
      admission.
    * **Not held** — any other state: `:queued` (requeued, reopened),
      `:merging` (an open PR holds no slot), `:verifying`. The resume must
      **acquire** a slot, exactly like a new admission, against the ticket's
      workspace's effective cap
      (`Arbiter.Board.Snapshot.effective_max_concurrent/2`).

  No worker rows are read. Before bd-asxw4e the answer came from the
  author row's `Arbiter.Worker.Phase`, so a human-parked ticket had released
  its slot (the 2026-09-23 incident below) while one parked on an open PR
  still held it; the stored state now decides both.

  ## When no slot is free

  Which of the two happens is the only thing the caller's origin decides:

    * `origin: :human` (the default — refusing is the one answer that neither
      fails silently nor bypasses) → `{:error, {:slot_cap_full, info}}`, which
      every human surface renders with `refusal_message/1`: the cap, the tasks
      holding it, and how to override. `force: true` overrides, and the
      override is written to the audit log as a `slot_cap_override` event
      (`Arbiter.Events`) naming the actor, the cap and the holders.
    * `origin: :automatic` → `{:defer, info}`. `Dispatch` hands the resume to
      `Arbiter.Board.Autopilot.defer_resume/4`, which starts it as soon as a
      slot frees, ahead of any new Ready dispatch.

  `slot_admitted: true` marks a resume the scheduler has already admitted into
  a free slot (the Autopilot draining a deferred resume); it is not re-checked.

  ## Under `scheduler_admission: enforce` (DC8)

  For a ticket whose pin account (`implementer_account_id`, else the account
  its workspace meters its last authoring provider under) is in `enforce`, the
  slot becomes the pin pool's **seat** (`docs/design/provider-dynamic-concurrency.md`
  §3.2, §7):

    * **In progress** — the ticket holds its pin seat in every phase, held for
      quota and idle included (the seat is wider than the slot), so a resume
      needs nothing new: `{:ok, :held}`.
    * **Not In progress** — the resume takes the ticket back into In progress:
      it needs a free seat on its pin pool (`Arbiter.Accounts.SeatCheck`), and at
      a full pool it is deferred, refused or forced exactly as at a full cap.
    * **`follow_up: true`** — a CI fix or conflict pass
      (`Arbiter.Workflows.MergeQueue.PassAdmission`) is a follow-up of in-flight
      work and is never held for a full pool (I9): `{:ok, :follow_up}`.

  Under `legacy` and `shadow` everything above this section is unchanged and
  no seat is read. `:mode`, `:account` and `:seat_opts` are seams.
  """

  alias Arbiter.Accounts.AdmissionMode
  alias Arbiter.Accounts.Resolver
  alias Arbiter.Accounts.SeatCheck
  alias Arbiter.Accounts.SlotLimit
  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.IdleTickets
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.SlotGate
  alias Arbiter.Workers.Run

  require Ash.Query
  require Logger

  @typedoc "What a refusal / deferral / override knows about the cap."
  @type info :: %{
          required(:task_id) => String.t(),
          required(:cap) => non_neg_integer(),
          required(:holders) => [String.t()],
          optional(:limit) => SlotLimit.t() | nil,
          optional(:seat) => SeatCheck.info()
        }

  @type result ::
          {:ok, :held | :acquired | :forced | :admitted | :follow_up}
          | {:defer, info()}
          | {:error, {:slot_cap_full, info()}}

  # Latest-run shapes that mean "cut off by a restart, not ended on its own
  # terms" — the orphan sweep's reason, the graceful-shutdown outcome, and a
  # row the sweep has not reached yet.
  @restart_failure_reasons ["server restarted", "server shutdown"]

  @doc """
  Decide whether a resume of `task` may start now. See the moduledoc.

  Options:

    * `:origin` — `:human` (default) or `:automatic`.
    * `:force` — override a full cap (human surfaces only); recorded.
    * `:actor` — who forced it, for the audit record.
    * `:slot_admitted` — the scheduler already admitted this resume.
    * `:held_ids` — tasks the quota gate is holding, which hold no slot
      (`SlotGate.holds_slot?/2`); the DispatchQueue passes it from inside its
      own drain.
    * `:tickets` / `:cap` — seams: the tickets to count holders among and the
      effective cap, read from the repo and `Snapshot` when absent.
    * `:follow_up` — a CI fix or conflict pass (DC8): under `enforce` never
      held for a full pool; ignored otherwise.
  """
  @spec admit(Issue.t(), keyword()) :: result()
  def admit(%Issue{} = task, opts \\ []) do
    if Keyword.get(opts, :slot_admitted) == true do
      {:ok, :admitted}
    else
      case enforced_account(task, opts) do
        {:enforce, account} -> admit_seat(task, account, opts)
        :slot -> admit_slot(task, opts)
      end
    end
  end

  defp admit_slot(%Issue{} = task, opts) do
    if SlotGate.holds_slot?(task, slot_opts(opts)) do
      {:ok, :held}
    else
      tickets = Keyword.get_lazy(opts, :tickets, &tickets_in_progress/0)
      slot_opts = Keyword.put_new_lazy(slot_opts(opts), :idle_ids, fn -> idle_ids(tickets) end)
      holders = holders_but(tickets, task, slot_opts)

      cap = Keyword.get_lazy(opts, :cap, fn -> cap_for(task, length(holders)) end)
      acquire(task, %{task_id: task.id, cap: cap, holders: holders}, opts)
    end
  end

  # ---- enforce (DC8) -----------------------------------------------------------

  # The pin account and its effective mode; `:slot` for today's rule. An
  # unreadable account or mode reads as `legacy`, today's rule.
  defp enforced_account(%Issue{} = task, opts) do
    account = Keyword.get_lazy(opts, :account, fn -> pin_account(task) end)

    if Keyword.get_lazy(opts, :mode, fn -> AdmissionMode.mode(account) end) == :enforce,
      do: {:enforce, account},
      else: :slot
  rescue
    _ -> :slot
  catch
    :exit, _ -> :slot
  end

  defp pin_account(%Issue{implementer_account_id: id}) when is_binary(id), do: Resolver.get(id)

  defp pin_account(%Issue{id: id, workspace_id: ws_id}) do
    provider = Run.latest_authoring_provider(id) || Arbiter.Quota.default_provider(ws_id)
    Resolver.account(ws_id, provider)
  end

  defp admit_seat(%Issue{} = task, account, opts) do
    cond do
      Keyword.get(opts, :follow_up) == true -> {:ok, :follow_up}
      task.state == :active -> {:ok, :held}
      is_nil(account) -> {:ok, :acquired}
      true -> acquire_seat(task, account, opts)
    end
  end

  # No predicted model here: the pin pool is the account's lowest budget (§3.1).
  defp acquire_seat(%Issue{} = task, account, opts) do
    seat_opts =
      Keyword.merge(
        [
          workspace_id: task.workspace_id,
          pool: nil,
          priority: task.priority,
          exclude_task: task.id
        ],
        Keyword.get(opts, :seat_opts, [])
      )

    case SeatCheck.check(account, seat_opts) do
      {:ok, _seat} ->
        {:ok, :acquired}

      {:full, seat} ->
        over_cap(
          task,
          %{task_id: task.id, cap: seat.limit, holders: seat.holders, seat: seat},
          opts
        )
    end
  end

  @doc """
  The operator-facing refusal for `{:error, {:slot_cap_full, info}}`. One
  source of truth for MCP, the REST API (and so the CLI), and the dashboard.
  """
  @spec refusal_message(info()) :: String.t()
  def refusal_message(%{task_id: task_id, seat: %{}} = info) do
    "no free seat to resume #{task_id}: #{limit_phrase(info)}. #{task_id} is not In progress, " <>
      "so it holds no seat on its pool and resuming it is a new admission. Wait for a seat " <>
      "to free, or resume with force (MCP `force: true`, `arb worker resume --force`) to go " <>
      "over — the override is recorded."
  end

  def refusal_message(%{task_id: task_id} = info) do
    "no free worker slot to resume #{task_id}: #{limit_phrase(info)}. #{task_id} is not In progress, so it holds no slot " <>
      "and resuming it is a new admission. Wait for a slot to free, or " <>
      "resume with force (MCP `force: true`, `arb worker resume --force`) to go " <>
      "over the cap — the override is recorded."
  end

  @doc """
  Names the binding limit — the account ceiling, the workspace cap or the
  install cap — and who is counted against it (bd-48prlb). Falls back to the
  workspace-framed number when the binding limit is unknown. Shared by the
  refusal and the deferred-resume log line.
  """
  @spec limit_phrase(info()) :: String.t()
  def limit_phrase(%{seat: %{} = seat, holders: [_ | _] = holders}),
    do: "#{SeatCheck.describe(seat)}, held by #{Enum.join(holders, ", ")}"

  def limit_phrase(%{seat: %{} = seat}), do: SeatCheck.describe(seat)

  def limit_phrase(%{limit: %{} = limit, holders: holders}),
    do: SlotLimit.describe(limit, holders)

  def limit_phrase(%{cap: cap, holders: holders}),
    do: "the concurrency cap is #{cap} and #{held_by(holders)}"

  defp held_by([]), do: "no task is holding a slot (the cap itself is 0)"

  defp held_by(holders),
    do: "#{length(holders)} held by #{Enum.join(holders, ", ")}"

  # ---- internals -----------------------------------------------------------

  # A stale copy of the ticket being resumed in the list is not a holder: the
  # ticket itself was just judged not to hold a slot.
  defp holders_but(tickets, %Issue{id: id}, slot_opts),
    do: tickets |> SlotGate.slot_holders(slot_opts) |> List.delete(id)

  # bd-3fbj83: orphaned tickets (no run, nothing queued) hold no slot.
  defp idle_ids(tickets) do
    IdleTickets.ids(tickets, queued_ids: Autopilot.deferred_resume_ids())
  rescue
    _ -> []
  end

  defp slot_opts(opts), do: Keyword.take(opts, [:held_ids, :idle_ids])

  @doc """
  Was `task_id`'s latest main run cut off by a restart rather than ended on its
  own terms? What a task with no registered worker is judged by: such a task
  was in flight, and still holds its slot.
  """
  @spec cut_off_by_restart?(String.t()) :: boolean()
  def cut_off_by_restart?(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and kind == :implement)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{state: state}] when state != :finished -> true
      [%Run{outcome: :interrupted}] -> true
      [%Run{failure_reason: reason}] when reason in @restart_failure_reasons -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp acquire(_task, %{cap: cap, holders: holders}, _opts) when length(holders) < cap,
    do: {:ok, :acquired}

  defp acquire(task, info, opts),
    do: over_cap(task, Map.put(info, :limit, limit_for(task, info)), opts)

  defp over_cap(task, info, opts) do
    cond do
      Keyword.get(opts, :force) == true ->
        record_override(task, info, opts)
        {:ok, :forced}

      Keyword.get(opts, :origin, :human) == :automatic ->
        {:defer, info}

      true ->
        {:error, {:slot_cap_full, info}}
    end
  end

  defp record_override(%Issue{workspace_id: ws_id}, info, opts) do
    Logger.warning(
      "ResumeSlot: #{info.task_id} resumed over the concurrency limit (#{limit_phrase(info)}) by force from #{inspect(Keyword.get(opts, :actor))}"
    )

    Arbiter.Events.broadcast(ws_id, "slot_cap_override", %{
      "task_id" => info.task_id,
      "cap" => info.cap,
      "holders" => info.holders,
      "actor" => Keyword.get(opts, :actor),
      "origin" => opts |> Keyword.get(:origin, :human) |> to_string()
    })
  end

  # Every ticket In progress, the board's own count (`Snapshot.derive/1`
  # counts over every ticket it reads). An unreadable table is no holders:
  # the cap is still enforced against what could be read.
  defp tickets_in_progress do
    Issue
    |> Ash.Query.filter(state == :active)
    |> Ash.read!()
  rescue
    _ -> []
  end

  defp limit_for(%Issue{workspace_id: ws_id}, %{holders: holders}) do
    case Ash.get(Arbiter.Tasks.Workspace, ws_id) do
      {:ok, ws} -> SlotLimit.binding(ws, length(holders))
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The same cap the board promotes against, for the task's own workspace. The
  # occupied count is handed in because `effective_max_concurrent/2` folds an
  # account's headroom into the caller's frame by adding it back.
  defp cap_for(%Issue{workspace_id: ws_id}, occupied),
    do: Snapshot.effective_max_concurrent(ws_id, occupied)
end
