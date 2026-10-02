defmodule Arbiter.Tasks.SlotGate do
  @moduledoc """
  One answer to "what occupies a worker slot?" — the companion predicate to
  `Arbiter.Tasks.EdgeGate`, for the other half of the same dispatch decision.

  `EdgeGate` answers *may* this task be dispatched given its edges.
  `SlotGate` answers *is there room* to dispatch anything at all. The board
  scheduler (`Arbiter.Board.Snapshot` → `Arbiter.Board.Scheduler` →
  `Arbiter.Board.Autopilot`) is the only dispatcher, and it used to answer
  this itself, inline in `derive/1`. Both halves of the dispatch decision now
  live beside each other as pure predicates so neither can drift from what the
  board renders.

  ## A slot is a live agent, not a record (bd-aw2cyt)

  Before this module, a slot meant "an author worker record whose run is
  still live" (`#{inspect([:starting, :working, :waiting])}` in today's run
  vocabulary, `Arbiter.Workers.RunState`).
  That is not what the operator's cap is for. A worker record outlives its
  agent by a long way: once the main `claude --print` process exits, the
  record stays alive to shepherd the ReviewGate, the implementer rounds, CI
  and the merge — spending nothing, burning no quota, and still holding a slot
  that blocked the next dispatch. A run `:waiting` on a question was the
  sharpest case: a worker that asked a human a question and has no agent at
  all held a slot until somebody answered.

  So a slot is occupied by a **live agent subprocess**, whatever role it
  belongs to: the main author session, a ReviewGate reviewer, an implementer
  round, a CI fix pass, a conflict resolver. Each is a separate paid session,
  so each costs a slot. A worker record with no live agent — waiting on CI,
  waiting on a merge, waiting on a person, between rounds — occupies none.

  ## The cap gates new dispatches only

  Counting review / implementer / fix-pass rounds toward the cap is what makes
  the number honest, but it must never be what *stops* them: a cap of 1 with
  one author in flight would deadlock the moment that author needed a review
  round, because the round could not start and the author could never finish.
  So the rounds always spawn when the work needs them, and the cap they push
  over is only consulted when deciding whether to start something **new**.
  The callers enforce that by construction — only the board scheduler's
  admission path asks this module anything — and `Arbiter.Worker.ReviewGate` /
  the merge-queue dispatchers never do.

  ## Liveness is an input

  `occupies_slot?/1` reads `:agent_live` off the worker snapshot
  (`Arbiter.Worker` stamps it from its own open ports — see
  `Arbiter.Worker.agent_session_live?/1`), so the predicate stays pure and the
  board's `derive/1` can be tested with plain maps.

  A snapshot that carries no `:agent_live` key at all is *unknown*, not "not
  live", and fails closed: it counts unless its run is provably over
  (`:finished` — the one run state that owns no agent), whatever its role.
  An unreadable liveness must never read as "nothing is running". (The
  opt-in record-based slot basis is gone since bd-36ytcl: the dispatch cap is
  counted in tickets, below, and this count only feeds the `agents live`
  header.)

  ## A slot is a ticket In progress (bd-asxw4e)

  `occupies_slot?/1` / `occupied/1` above answer "is an agent burning quota
  right now" — the `agents live: X of N` header. They are **not** what gates
  a new dispatch.

  The dispatch cap counts **tickets whose stored state is `:active`**
  (`Arbiter.Tasks.Lifecycle`) — exactly the board's In progress column
  (`holds_slot?/1`, `slots_used/1`, `slot_holders/1`). The worker list is not
  an input at all: no resident worker row can hold a slot on its own, and
  none can release one. So:

    * a ticket between ReviewGate rounds, or handing off, is still `:active`
      and holds its slot with no agent live (the bd-45pwo1 guarantee — the
      fleet can no longer run three tickets against a cap of two);
    * a ticket parked on a human is still `:active` — it is In progress with
      an attention flag, and it holds its slot until it moves;
    * `:merging` and `:verifying` release the slot. An open PR waiting on CI
      or the merge queue is not work in progress. This deliberately replaces
      the 2026-09-21 rule "another slot doesn't open until the issue
      occupying it is merged" (operator, 2026-09-27; `docs/design/ticket-lifecycle.md` §5).

  Before bd-asxw4e the count read `Arbiter.Worker.Phase` off each task's
  author row, so a ticket held its slot through an open PR waiting on CI, a
  review round, a hand-off between agents and an unknown probe — invisibly —
  and a ReviewGate park released it. (Those worker phases are gone since
  bd-36ytcl: a ticket's step comes from `Arbiter.Tasks.Lifecycle.view/2`.) The stored state is what every surface shows,
  so the cap now cannot disagree with the board.

  A ticket whose ReviewGate is holding its reviewer back until CI is green on
  the head (bd-cut6uv, `Arbiter.Worker.ReviewCi.waiting/2`) is the one exception
  to "`:active` holds a slot": it is still In progress on the board, but no agent
  is live for it and it is waiting on a machine, exactly like a Merging PR waiting
  on CI — so it releases its slot while it waits. The marker expires, so a gate
  that died mid-wait cannot hold a ticket out of the count forever.

  A ticket whose next round the quota gate is holding (`DispatchQueue`, phase
  `held_for_quota`) is likewise waiting with no agent, possibly for hours on a
  weekly pace: it releases its slot while held (bd-zkmvia). The drain checks
  the cap again (`Arbiter.Worker.ResumeSlot.admit/2`) before replaying it.

  Epics never hold a slot: they are never dispatched and never on the board.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Worker.ReviewCi
  alias Arbiter.Workflows.DispatchQueue

  # The one run state that provably owns no agent: the run is over. A
  # snapshot of unknown liveness in any other state counts (see the moduledoc).
  @over_state :finished

  @doc """
  Does this worker snapshot occupy a worker slot — is an agent subprocess live
  for it? Unknown liveness fails closed (see the moduledoc).
  """
  @spec occupies_slot?(map()) :: boolean()
  def occupies_slot?(worker) when is_map(worker) do
    case agent_live(worker) do
      true -> true
      false -> false
      nil -> Map.get(worker, :state) != @over_state
    end
  end

  def occupies_slot?(_worker), do: false

  @doc """
  How many of `workers` occupy a slot.
  """
  @spec occupied([map()]) :: non_neg_integer()
  def occupied(workers) when is_list(workers), do: Enum.count(workers, &occupies_slot?/1)

  @doc """
  Slots left out of `total` once `workers` have taken theirs. Never negative:
  review / fix-pass rounds are allowed to push past the cap (see the moduledoc),
  so the occupied count legitimately exceeds `total` sometimes, and "-1 slots
  free" is not a thing a scheduler or a header should ever say.
  """
  @spec free(non_neg_integer(), [map()]) :: non_neg_integer()
  def free(total, workers) when is_integer(total) and is_list(workers) do
    max(total - occupied(workers), 0)
  end

  @doc """
  Is this worker snapshot's agent subprocess live?

  `nil` when the snapshot does not carry the answer — a caller that could not
  ask (a pure test fixture, an older serialized row) gets "unknown", never a
  false "no".
  """
  @spec agent_live(map()) :: boolean() | nil
  def agent_live(worker) when is_map(worker) do
    case Map.get(worker, :agent_live, Map.get(worker, "agent_live")) do
      true -> true
      false -> false
      _ -> nil
    end
  end

  @doc """
  Does this ticket hold a slot? True only for a ticket whose stored state is
  `:active`, that is not an epic and whose ReviewGate is not waiting on CI. See
  the moduledoc's "A slot is a ticket In progress".
  """
  @spec holds_slot?(map(), keyword()) :: boolean()
  def holds_slot?(ticket, opts \\ [])

  def holds_slot?(ticket, opts) when is_map(ticket) do
    Lifecycle.state_of(ticket) == :active and
      Map.get(ticket, :issue_type) not in Issue.non_dispatchable_types() and
      is_nil(ReviewCi.waiting(ticket)) and not held_for_quota?(ticket, opts)
  end

  def holds_slot?(_ticket, _opts), do: false

  # bd-zkmvia: a ticket whose next round the quota gate is holding
  # (`Arbiter.Workflows.DispatchQueue`) has no agent and may wait hours; it
  # releases its slot like a ticket waiting on CI, and re-takes it when the
  # hold drains.
  #
  # `held_ids:` names the held tasks outright, for the one caller that cannot
  # ask the queue (the queue itself, mid-drain).
  defp held_for_quota?(ticket, opts) do
    case Keyword.fetch(opts, :held_ids) do
      {:ok, ids} -> Map.get(ticket, :id) in ids
      :error -> DispatchQueue.held?(Map.get(ticket, :workspace_id), Map.get(ticket, :id))
    end
  end

  @doc """
  The ids of the tickets holding a slot, in the order given. `Arbiter.Worker.ResumeSlot`
  names them in a refusal; the board and `Arbiter.Board.Drain` report them.
  """
  @spec slot_holders([map()], keyword()) :: [String.t()]
  def slot_holders(tickets, opts \\ []) when is_list(tickets) do
    for ticket <- tickets, holds_slot?(ticket, opts), uniq: true, do: Map.get(ticket, :id)
  end

  @doc "How many of `tickets` hold a slot — the dispatch cap's used count."
  @spec slots_used([map()]) :: non_neg_integer()
  def slots_used(tickets) when is_list(tickets), do: tickets |> slot_holders() |> length()

  @doc """
  Slots left out of `total` once `tickets` have taken theirs. Never negative:
  a forced dispatch or resume may legitimately push the count past the cap,
  and "-1 slots free" is not a thing a scheduler or a header should ever say.
  """
  @spec slots_free(non_neg_integer(), [map()]) :: non_neg_integer()
  def slots_free(total, tickets) when is_integer(total) and is_list(tickets),
    do: max(total - slots_used(tickets), 0)
end
