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

  Before this module, a slot meant "an author worker record in one of
  `#{inspect([:idle, :resuming, :running, :awaiting, :awaiting_review_gate])}`".
  That is not what the operator's cap is for. A worker record outlives its
  agent by a long way: once the main `claude --print` process exits, the
  record stays alive to shepherd the ReviewGate, the implementer rounds, CI
  and the merge — spending nothing, burning no quota, and still holding a slot
  that blocked the next dispatch. `:awaiting` was the sharpest case: a worker
  that asked a human a question and has no agent at all held a slot until
  somebody answered.

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

  `occupies_slot?/2` reads `:agent_live` off the worker snapshot
  (`Arbiter.Worker` stamps it from its own open ports — see
  `Arbiter.Worker.agent_session_live?/1`), so the predicate stays pure and the
  board's `derive/1` can be tested with plain maps. A snapshot that carries no
  `:agent_live` key at all is *unknown*, not "not live", and degrades to the
  old status rule — an unreadable liveness must never read as a free slot,
  which would over-dispatch.

  ## `conductor.slot_basis`

  `:agents` (the default) is the rule above. `:issues` restores the
  pre-bd-aw2cyt record-based counting, for an operator who wants the old
  behaviour back when quota loosens:

      config :arbiter, conductor_slot_basis: :issues

  ## A slot is a ticket In progress (bd-asxw4e)

  `occupies_slot?/2` / `occupied/2` above answer "is an agent burning quota
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
  author row, so a ticket held its slot through `waiting_ci_merge`,
  `in_review`, `handing_off` and an `:unknown` probe — invisibly — and a
  ReviewGate park released it. The stored state is what every surface shows,
  so the cap now cannot disagree with the board.

  Epics never hold a slot: they are never dispatched and never on the board.
  The `conductor_slot_basis` setting above only changes the `agents live`
  count; the cap is counted in tickets under either basis.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle

  @typedoc "How a slot is counted."
  @type basis :: :agents | :issues

  @default_basis :agents

  @bases [:agents, :issues]

  # Worker statuses that held a slot under the `:issues` basis — an author
  # record with a workflow still in its hands. A run that opened its PR has
  # ended (bd-741sid); the PR holds no subprocess.
  @slot_statuses [:idle, :resuming, :running, :awaiting, :awaiting_review_gate]

  # A reviewer / implementer runs under its *own* synthetic task id on behalf
  # of an author, so under the `:issues` basis it folds into the author's card
  # rather than holding a record of its own. `:fix_pass` / `:conflict_resolver`
  # share the author's task id and were counted as author rows before this
  # module existed; that is preserved exactly.
  @gate_roles [:reviewer, :implementer]

  @doc """
  The statuses that occupy a slot under the `:issues` basis.
  """
  @spec slot_statuses() :: [atom()]
  def slot_statuses, do: @slot_statuses

  @doc """
  How slots are counted on this install: `:agents` (default) or `:issues`.

  Reads `:arbiter, :conductor_slot_basis`. Accepts an atom or a string; an
  unrecognised value is not configuration, so it falls back to the default
  rather than silently adopting something nobody asked for.
  """
  @spec basis() :: basis()
  def basis do
    normalize_basis(Application.get_env(:arbiter, :conductor_slot_basis))
  rescue
    _ -> @default_basis
  end

  @doc """
  Coerce a caller-supplied basis (atom, string or `nil`) to a known one.

  Pure: `nil` and anything unrecognised resolve to the default (`:agents`),
  *not* to the configured basis — reading config here would make every slot
  predicate impure, and `basis/0` itself calls this on the env value, so the
  two would recurse. Callers that want the install's configured basis read
  `basis/0` at their own impure boundary and pass the result down; that is
  what `Arbiter.Board.Snapshot.load/1` does.
  """
  @spec normalize_basis(term()) :: basis()
  def normalize_basis(nil), do: @default_basis
  def normalize_basis(b) when b in @bases, do: b

  def normalize_basis(b) when is_binary(b) do
    # Never `String.to_atom/1` on a config value — match the known set.
    Enum.find(@bases, @default_basis, &(Atom.to_string(&1) == b))
  end

  def normalize_basis(_), do: @default_basis

  @doc """
  Does this worker snapshot occupy a worker slot?

  `basis` defaults to `:agents` (see `normalize_basis/1` — it does *not* read
  config); pass the install's basis explicitly, resolved once via `basis/0` at
  an impure boundary, so the answer stays a function of its inputs.
  """
  @spec occupies_slot?(map(), basis() | nil) :: boolean()
  def occupies_slot?(worker, basis \\ nil)

  def occupies_slot?(worker, basis) when is_map(worker) do
    case normalize_basis(basis) do
      :issues -> record_slot?(worker)
      :agents -> agent_slot?(worker)
    end
  end

  def occupies_slot?(_worker, _basis), do: false

  @doc """
  How many of `workers` occupy a slot.
  """
  @spec occupied([map()], basis() | nil) :: non_neg_integer()
  def occupied(workers, basis \\ nil) when is_list(workers) do
    basis = normalize_basis(basis)
    Enum.count(workers, &occupies_slot?(&1, basis))
  end

  @doc """
  Slots left out of `total` once `workers` have taken theirs. Never negative:
  review / fix-pass rounds are allowed to push past the cap (see the moduledoc),
  so the occupied count legitimately exceeds `total` sometimes, and "-1 slots
  free" is not a thing a scheduler or a header should ever say.
  """
  @spec free(non_neg_integer(), [map()], basis() | nil) :: non_neg_integer()
  def free(total, workers, basis \\ nil) when is_integer(total) and is_list(workers) do
    max(total - occupied(workers, basis), 0)
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
  `:active` (a legacy row is judged by the state its columns imply) and that is
  not an epic. See the moduledoc's "A slot is a ticket In progress".
  """
  @spec holds_slot?(map()) :: boolean()
  def holds_slot?(ticket) when is_map(ticket) do
    Lifecycle.state_of(ticket) == :active and
      Map.get(ticket, :issue_type) not in Issue.non_dispatchable_types()
  end

  def holds_slot?(_ticket), do: false

  @doc """
  The ids of the tickets holding a slot, in the order given. `Arbiter.Worker.ResumeSlot`
  names them in a refusal; the board and `Arbiter.Board.Drain` report them.
  """
  @spec slot_holders([map()]) :: [String.t()]
  def slot_holders(tickets) when is_list(tickets) do
    for ticket <- tickets, holds_slot?(ticket), uniq: true, do: Map.get(ticket, :id)
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

  # ---- internals ------------------------------------------------------------

  defp agent_slot?(worker) do
    case agent_live(worker) do
      true -> true
      false -> false
      # Unknown liveness degrades to the record rule rather than to "free".
      nil -> record_slot?(worker)
    end
  end

  defp record_slot?(worker) do
    Map.get(worker, :status) in @slot_statuses and role_of(worker) not in @gate_roles
  end

  defp role_of(worker) do
    Map.get(worker, :role) || get_in_meta(worker, :role)
  end

  defp get_in_meta(worker, key) do
    case Map.get(worker, :meta) do
      %{} = meta -> Map.get(meta, key) || Map.get(meta, to_string(key))
      _ -> nil
    end
  end
end
