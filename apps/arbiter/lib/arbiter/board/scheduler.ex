defmodule Arbiter.Board.Scheduler do
  @moduledoc """
  Decides which Ready card gets dispatched next, and why every other one
  doesn't.

  The board's Ready column is a real queue, not a parking lot: nothing waits
  for a human to drag it into Running. `plan/1` is the whole decision, and it
  is a pure function — feed it a snapshot of the board (see
  `Arbiter.Board.Snapshot`) and it returns at most one task id to promote plus
  a one-line reason for every card in the queue. The caller performs the
  dispatch; this module never touches the world.

  Purity is the point. Dispatch is expensive and irreversible-ish (a worker
  spawns, a worktree lands on disk, tokens burn), so the rule that decides it
  should be testable without a repo, a supervisor, or a quota snapshot.

  ## Why at most one promotion per plan

  Even with three slots free, a plan promotes one card. Dispatch is
  asynchronous: the promoted worker does not appear in `running` until it
  registers, so a plan that promoted three at once would be reasoning about
  file overlap and slot count against stale state for the second and third.
  The board re-plans on every worker and task lifecycle event, so the next
  promotion follows within milliseconds of the first landing — one-at-a-time
  costs nothing and keeps each decision made against a picture that is true.

  ## Reason precedence

  A card's own blocks are reported ahead of anything board-wide, because they
  survive the board-wide condition clearing: telling an operator "no free
  worker slot" when the card is also waiting on an unmerged dependency would
  send them to free a slot for nothing.

    1. an open dependency — `blocked — waiting on bd-9`
    2. a `conflicts_with` counterpart in flight — `blocked — conflicts with
       bd-7 (running)`
    3. file overlap with in-flight work — `blocked — lib/a.ex in flight on bd-7`
    4. scheduler paused — `scheduler paused`
    5. quota — `blocked — quota exhausted`
    6. no free worker slot — `blocked — no free worker slot`

  Quota outranks the slot count deliberately: a free slot you may not use is
  not the fact worth showing. A declared mutex outranks a file overlap for the
  same kind of reason: the overlap is an inference from two scopes, the mutex
  is a human saying "not at the same time", and only one of those is worth
  showing when both are true.

  Only the *head* of the queue carries a board-wide hold — with one exception.
  Cards behind the head show their queue position (`2 ahead in queue`) — they
  aren't blocked, they're waiting, and the distinction is what makes a stalled
  board readable. A card held by a card-specific block is *skipped over* rather
  than counted, so the card behind it reads `next up` rather than `1 ahead` of
  work that isn't going anywhere.

  The exception is **paused**: a queue position implies a queue that is
  moving, so while the scheduler is paused *every* otherwise-unblocked card
  reads `scheduler paused`, not just the head. Card-specific blocks still win
  over it — a paused board should not hide the fact that a card is also
  waiting on a dependency.

  ## The mutex (bd-6bax7s)

  `:conflicts_with` used to be honoured only by the since-removed graph
  engine, so a coordinator who set the edge on two board cards got both
  dispatched anyway. The board now asks `Arbiter.Tasks.EdgeGate.gate/1` the
  same question; this module only supplies the inputs and phrases the
  answer.

  Two of those inputs are the caller's to compute, because purity forbids this
  module from going and looking: `card.conflicts_with` is the card's
  counterparts (symmetric — `EdgeGate` has already folded both edge
  directions), and `:conflict_claims` is `%{task_id => state}` for everything
  in flight, the state being what the card says in parentheses. The card
  promoted in *this* pass joins that map as `dispatching`, which is what makes
  a freshly-promoted pair serialize rather than both going out — the same
  within-pass claim the file-overlap check already does.
  """

  alias Arbiter.Board.FileScope
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Tasks.Lifecycle

  @typedoc """
  One Ready card. `scope` is its declared file scope (`FileScope.declared_paths/1`),
  `blocked_by` the ids of its still-open gating dependencies and
  `conflicts_with` the ids it may not run alongside.
  """
  @type card :: %{
          required(:id) => String.t(),
          optional(:scope) => FileScope.scope(),
          optional(:blocked_by) => [String.t()],
          optional(:conflicts_with) => [String.t()],
          optional(any()) => any()
        }

  @typedoc "One piece of work already in flight, with the files it has claimed."
  @type in_flight :: %{
          required(:task_id) => String.t(),
          optional(:scope) => FileScope.scope(),
          optional(any()) => any()
        }

  @typedoc "`:ok`, or a hold carrying the phrase to show the operator."
  @type quota :: :ok | nil | {:hold, String.t()}

  @typedoc """
  What is in flight for mutex purposes, and what to call it on a card:
  `%{task_id => "running"}`. Wider than `:running`, which only carries the
  slot-holding workers whose *files* are claimed — a Merging ticket holds an
  open MR rather than a slot, and is still very much something a
  `conflicts_with` counterpart must not run beside.
  """
  @type conflict_claims :: %{optional(String.t()) => String.t()}

  @type input :: %{
          optional(:ready) => [card()],
          optional(:running) => [in_flight()],
          optional(:conflict_claims) => conflict_claims() | [String.t()],
          optional(:slots_free) => integer(),
          optional(:quota) => quota(),
          optional(:card_quota) => %{optional(String.t()) => quota()},
          optional(:card_constraint) => %{optional(String.t()) => :ok | {:hold, String.t()}},
          optional(:paused) => boolean()
        }

  @typedoc """
  A card's queue standing. `:next` is the one card being dispatched this
  cycle, `:queued` is waiting its turn, `:blocked` cannot go yet.
  """
  @type state :: :next | :queued | :blocked

  @type entry :: %{
          id: String.t(),
          state: state(),
          reason: String.t(),
          card: card()
        }

  @type t :: %{promote: String.t() | nil, entries: [entry()]}

  # What a card promoted in this very pass is called when it holds a mutex
  # against a card further down the queue.
  @dispatching_state "dispatching"

  # A claim the caller named without a state. Never reached on the live board
  # (`Arbiter.Board.Snapshot` always labels), but a hand-built plan may.
  @unlabelled_state "in flight"

  @next_reason "next up — dispatching..."
  @paused_reason "scheduler paused"
  @no_slot_reason "blocked — no free worker slot"

  @doc """
  Plan one dispatch cycle.

  Returns `%{promote: task_id | nil, entries: [...]}` with one entry per Ready
  card, in queue order. `promote` is the single card the caller should
  dispatch, or `nil` when nothing is eligible.
  """
  @spec plan(input()) :: t()
  def plan(input) when is_map(input) do
    ready = input |> Map.get(:ready) |> List.wrap() |> order()
    running = Map.get(input, :running) || []

    board = %{
      paused: Map.get(input, :paused) == true,
      quota: Map.get(input, :quota),
      # Per-ticket quota verdicts (a ticket's own routing candidates), which
      # take precedence over the board-wide `quota` for that card.
      card_quota: Map.get(input, :card_quota) || %{},
      # bd-13pqcp: per-ticket provider-constraint verdicts — a ticket whose
      # constraint leaves no eligible account is held on its own, which never
      # advances the queue.
      card_constraint: Map.get(input, :card_constraint) || %{},
      slots_free: Map.get(input, :slots_free, 0)
    }

    seed = %{
      promote: nil,
      held?: false,
      ahead: 0,
      in_flight: Enum.map(running, &{&1.task_id, scope_of(&1)}),
      claimed: nil,
      mutex: conflict_claims(Map.get(input, :conflict_claims))
    }

    {entries, acc} =
      Enum.map_reduce(ready, seed, fn card, acc -> step(card, board, acc) end)

    %{promote: acc.promote, entries: entries}
  end

  def plan(_), do: %{promote: nil, entries: []}

  @doc """
  The queue's order (bd-asxw4e; `docs/design/epic-aware-scheduling.md` §4),
  ascending on

      {effective_priority, pinned, finish_class, open_leaves, priority, rank, created_at}

  `effective_priority` is `min(own, epic floors)` (`Arbiter.Board.QueueOrder`);
  `pinned` is `0` for a card an operator dragged within its band
  (`rank_pinned: true`), else `1`; `finish_class` and `open_leaves` are the
  finish-first tiebreak; `rank` is the manual order inside a band
  (`docs/design/ticket-lifecycle.md` §1); then `created_at`, oldest first.

  A card that carries none of the new fields reads `effective_priority ==
  priority`, unpinned, class `0` and `0` open leaves, so the order collapses
  to today's `{priority, rank, created_at}`. The sort is stable, so cards that
  carry none of the keys keep the order they were given in.
  """
  @spec order([card()]) :: [card()]
  def order(cards) when is_list(cards), do: Enum.sort_by(cards, &order_key/1)

  # A missing key sorts after every present one (an atom outranks any number
  # in term order), so an unranked card never jumps a ranked one.
  defp order_key(card) do
    priority = Map.get(card, :priority) || :none

    {
      Map.get(card, :effective_priority) || priority,
      if(Map.get(card, :rank_pinned) == true, do: 0, else: 1),
      Map.get(card, :finish_class) || 0,
      Map.get(card, :open_leaves) || 0,
      priority,
      Map.get(card, :rank) || :none,
      created_key(card)
    }
  end

  defp created_key(%{created_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)
  defp created_key(_card), do: :none

  # One card's standing, from the one dispatch-eligibility predicate
  # (`Lifecycle.dispatchable/2`, bd-asxw4e). `acc.held?` records that the
  # board-wide hold has already been shown on the card it actually applies
  # to; `acc.ahead` counts the cards genuinely queued in front of this one.
  defp step(card, board, acc) do
    case Lifecycle.dispatchable(ticket(card), ctx(card, board, acc)) do
      :ok ->
        decide(card, nil, acc)

      # Paused holds every otherwise-eligible card, not just the head.
      {:held, :paused} ->
        {entry(card, :blocked, @paused_reason), bump(acc)}

      # Only the head of the queue carries a board-wide hold.
      {:held, :no_slot} ->
        decide(card, @no_slot_reason, acc)

      {:held, {:quota, _} = hold} ->
        decide(card, phrase(hold, acc.mutex), acc)

      # A card's own block never advances the queue position: the card behind
      # it is still next in line.
      {:held, hold} ->
        {entry(card, :blocked, phrase(hold, acc.mutex)), acc}
    end
  end

  # A card handed to `plan/1` is a Ready candidate, so one that carries no
  # state of its own (a hand-built plan) reads as queued. `Arbiter.Board.Snapshot`
  # always stamps the ticket's real state, so a card that is no longer Ready
  # by the time it is planned is held in its column rather than dispatched.
  defp ticket(card), do: Map.put_new(card, :state, :queued)

  defp ctx(card, board, acc) do
    board = Map.put(board, :quota, Map.get(board.card_quota, card.id, board.quota))

    Map.merge(board, %{
      blocked_by: Map.get(card, :blocked_by),
      conflicts_with: Map.get(card, :conflicts_with),
      claimed: acc.mutex,
      provider_constraint: Map.get(board.card_constraint, card.id),
      scope: scope_of(card),
      in_flight: claims(acc)
    })
  end

  defp decide(card, _hold, %{held?: true} = acc), do: queued(card, acc)
  defp decide(card, _hold, %{promote: p} = acc) when p != nil, do: queued(card, acc)

  # The head of the queue: it either goes, or it carries the hold that stopped it.
  defp decide(card, nil, acc) do
    acc = %{
      acc
      | promote: card.id,
        claimed: {card.id, scope_of(card)},
        mutex: Map.put(acc.mutex, card.id, @dispatching_state)
    }

    {entry(card, :next, @next_reason), bump(acc)}
  end

  defp decide(card, reason, acc) when is_binary(reason) do
    {entry(card, :blocked, reason), bump(%{acc | held?: true})}
  end

  # Already-running work first, then the card promoted this cycle — so a
  # collision is attributed to the worker that has actually been holding the
  # file, not to a sibling that only just won the slot.
  defp claims(%{in_flight: in_flight, claimed: nil}), do: in_flight
  defp claims(%{in_flight: in_flight, claimed: claim}), do: in_flight ++ [claim]

  defp queued(card, acc), do: {entry(card, :queued, ahead_reason(acc.ahead)), bump(acc)}

  defp bump(acc), do: %{acc | ahead: acc.ahead + 1}

  defp ahead_reason(n), do: "#{n} ahead in queue"

  defp entry(card, state, reason),
    do: %{id: card.id, state: state, reason: reason, card: card}

  # The hold, as the card says it. The counterpart's state is the half of a
  # mutex reason the predicate cannot know: it answers *whether* the mutex
  # holds, the board says what is holding it.
  defp phrase({:blocked_by, ids}, _mutex),
    do: "blocked — " <> EdgeGate.describe({:waiting_on, ids})

  defp phrase({:conflicts_with, peer} = hold, mutex),
    do: "blocked — #{Lifecycle.describe_hold(hold)} (#{Map.get(mutex, peer, @unlabelled_state)})"

  # bd-13pqcp: a provider-constraint hold reads `held — provider constraint (…)`.
  defp phrase({:provider_constraint, _detail} = hold, _mutex),
    do: "held — " <> Lifecycle.describe_hold(hold)

  defp phrase(hold, _mutex), do: "blocked — " <> Lifecycle.describe_hold(hold)

  # A bare list of ids is accepted so a caller that has no states to report
  # still gets the mutex honoured, just with a vaguer reason.
  defp conflict_claims(nil), do: %{}
  defp conflict_claims(claims) when is_map(claims), do: claims
  defp conflict_claims(ids) when is_list(ids), do: Map.new(ids, &{&1, @unlabelled_state})

  defp scope_of(%{scope: %MapSet{} = scope}), do: scope
  defp scope_of(%{scope: paths}) when is_list(paths), do: MapSet.new(paths)
  defp scope_of(_), do: MapSet.new()
end
