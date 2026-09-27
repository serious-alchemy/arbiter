defmodule Arbiter.Worker.ResumeSlot do
  @moduledoc """
  Whether a resume may re-enter a task right now, given the dispatch cap
  (bd-92mx1m).

  ## The incident

  On 2026-09-23, with `conductor_system_max_concurrent = 1`, bd-3usjdj ran out
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
  its slot (the 2026-09-23 incident below) while an `:awaiting_review` one on
  an open PR still held it; the stored state now decides both.

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
  """

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.SlotGate
  alias Arbiter.Workers.Run

  require Ash.Query
  require Logger

  @typedoc "What a refusal / deferral / override knows about the cap."
  @type info :: %{task_id: String.t(), cap: non_neg_integer(), holders: [String.t()]}

  @type result ::
          {:ok, :held | :acquired | :forced | :admitted}
          | {:defer, info()}
          | {:error, {:slot_cap_full, info()}}

  # Latest-run shapes that mean "cut off by a restart, not ended on its own
  # terms" — the orphan sweep's reason, the graceful-shutdown status, and a row
  # the sweep has not reached yet.
  @restart_failure_reasons ["server restarted", "server shutdown"]
  @restart_statuses [:running, :interrupted]

  @doc """
  Decide whether a resume of `task` may start now. See the moduledoc.

  Options:

    * `:origin` — `:human` (default) or `:automatic`.
    * `:force` — override a full cap (human surfaces only); recorded.
    * `:actor` — who forced it, for the audit record.
    * `:slot_admitted` — the scheduler already admitted this resume.
    * `:tickets` / `:cap` — seams: the tickets to count holders among and the
      effective cap, read from the repo and `Snapshot` when absent.
  """
  @spec admit(Issue.t(), keyword()) :: result()
  def admit(%Issue{} = task, opts \\ []) do
    cond do
      Keyword.get(opts, :slot_admitted) == true ->
        {:ok, :admitted}

      SlotGate.holds_slot?(task) ->
        {:ok, :held}

      true ->
        holders = opts |> Keyword.get_lazy(:tickets, &tickets_in_progress/0) |> holders_but(task)
        cap = Keyword.get_lazy(opts, :cap, fn -> cap_for(task, length(holders)) end)
        acquire(task, %{task_id: task.id, cap: cap, holders: holders}, opts)
    end
  end

  @doc """
  The operator-facing refusal for `{:error, {:slot_cap_full, info}}`. One
  source of truth for MCP, the REST API (and so the CLI), and the dashboard.
  """
  @spec refusal_message(info()) :: String.t()
  def refusal_message(%{task_id: task_id, cap: cap, holders: holders}) do
    "no free worker slot to resume #{task_id}: the concurrency cap is #{cap} and " <>
      "#{held_by(holders)}. #{task_id} is not In progress, so it holds no slot " <>
      "and resuming it is a new admission. Wait for a slot to free, or " <>
      "resume with force (MCP `force: true`, `arb worker resume --force`) to go " <>
      "over the cap — the override is recorded."
  end

  defp held_by([]), do: "no task is holding a slot (the cap itself is 0)"

  defp held_by(holders),
    do: "#{length(holders)} held by #{Enum.join(holders, ", ")}"

  # ---- internals -----------------------------------------------------------

  # A stale copy of the ticket being resumed in the list is not a holder: the
  # ticket itself was just judged not to hold a slot.
  defp holders_but(tickets, %Issue{id: id}),
    do: tickets |> SlotGate.slot_holders() |> List.delete(id)

  @doc """
  Was `task_id`'s latest main run cut off by a restart rather than ended on its
  own terms? What a task with no registered worker is judged by: such a task
  was in flight, and still holds its slot.
  """
  @spec cut_off_by_restart?(String.t()) :: boolean()
  def cut_off_by_restart?(task_id) do
    Run
    |> Ash.Query.filter(task_id == ^task_id and worker_type == :main)
    |> Ash.Query.sort(started_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [%Run{status: status}] when status in @restart_statuses -> true
      [%Run{failure_reason: reason}] when reason in @restart_failure_reasons -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp acquire(_task, %{cap: cap, holders: holders}, _opts) when length(holders) < cap,
    do: {:ok, :acquired}

  defp acquire(task, info, opts) do
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
      "ResumeSlot: #{info.task_id} resumed over the concurrency cap (#{info.cap}, held by " <>
        "#{inspect(info.holders)}) by force from #{inspect(Keyword.get(opts, :actor))}"
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

  # The same cap the board promotes against, for the task's own workspace. The
  # occupied count is handed in because `effective_max_concurrent/2` folds an
  # account's headroom into the caller's frame by adding it back.
  defp cap_for(%Issue{workspace_id: ws_id}, occupied),
    do: Snapshot.effective_max_concurrent(ws_id, occupied)
end
