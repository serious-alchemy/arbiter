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

  ## The walk (DC6, `docs/design/provider-dynamic-concurrency.md` §4)

  Handed a `:walk` (`t:walk/0`), `plan/1` answers the same question the other
  way: by capacity, not by one board-wide slot count. Without `:walk` the plan
  is exactly the head-of-line plan above, byte for byte (I1); the walk only
  runs where `Arbiter.Board.Snapshot` was asked for it, and until DC8 nothing
  dispatches by it (`scheduler_admission: shadow` records it beside every
  dispatch, `Arbiter.Board.AdmissionShadow`).

    1. **Capacity sets first (§4.1).** A pool is open while its seats plus this
       walk's placements are below its budget (or its exempt budget); a machine
       while its used slots plus placements are below its cap; a repo while its
       implementer runs are below its cap. With no open pool or no open
       machine the walk stops at once: every free card reads `waiting for
       capacity — <why>` and no card's candidates are evaluated.
    2. **Walk Ready in the ES3 order (§4.2).** A card's own holds come first
       (column, mutex, overlap, guardrail, the 15 s retry window — the same
       `Lifecycle.dispatchable/2` predicate, asked without the board-wide
       quota and slot holds the walk replaces). Then its candidates, in its
       own preference order: the pools that have room for it, then its repo,
       then a machine that can run that pool — the first node group with room,
       ranked like `Arbiter.Nodes.Placement` (lowest load, then name).
    3. **Skip, don't stop.** A card that fits nowhere is skipped with that
       layer's reason (`waiting for claude:default: 3 of 3 seats`, `repo
       vstim: 2 of 2 implementer runs`, `no machine slot for … work: local 6
       of 6`) and the next card is tried. A skipped card is first in line on
       the next pass, because every pass starts from the top.
    4. **Many placements per plan (§4.3).** Each placement takes a seat, a
       machine slot and a repo run, and claims its files and mutex like the
       head-of-line promotion does. The first placement is `:next` (`promote`);
       the rest are `:starting`. Once no pool or machine is open the remaining
       cards are `N ahead in queue`.

  Every walk entry carries `wait_cause` (`t:wait_cause/0`) and the placed ones
  their `pair`; the plan carries `placements` in order.
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
          optional(:slot_note) => String.t() | nil,
          optional(:quota) => quota(),
          optional(:card_quota) => %{optional(String.t()) => quota()},
          optional(:card_constraint) => %{optional(String.t()) => :ok | {:hold, String.t()}},
          optional(:card_guardrail) => %{optional(String.t()) => :ok | {:hold, String.t()}},
          optional(:dispatch_holds) => %{optional(String.t()) => {:hold, String.t()}},
          optional(:paused) => boolean(),
          optional(:walk) => walk()
        }

  @typedoc """
  The walk's capacity sets and each card's candidates (DC6). `pools` is keyed
  by whatever identifies a pool to the caller (`{account_id, pool}` on the live
  board), `nodes` by machine id (`"local"` is the primary). `candidates` is a
  `%{card_id => result}` or a function of the card, asked lazily — only for a
  card that reaches the capacity step while capacity remains. `repos` is the
  optional repo layer (DC9); a repo it does not name is unbounded.
  """
  @type walk :: %{
          required(:pools) => %{optional(term()) => walk_pool()},
          required(:nodes) => %{optional(String.t()) => walk_machine()},
          required(:candidates) =>
            %{optional(String.t()) => candidates()} | (card() -> candidates()),
          optional(:repos) => %{optional(term()) => walk_repo()}
        }

  @typedoc """
  A pool: its published `budget` (or `:unlimited`), the `seats` held on it now,
  and the `exempt_budget` an exempt card may use (R7). `label` and `reason`
  phrase it.
  """
  @type walk_pool :: %{
          required(:budget) => non_neg_integer() | :unlimited,
          required(:seats) => non_neg_integer(),
          optional(:exempt_budget) => non_neg_integer() | nil,
          optional(:label) => String.t(),
          optional(:reason) => String.t() | nil
        }

  @typedoc "A machine: its worker `cap` and the slots `used` on it now (live plus reserved)."
  @type walk_machine :: %{
          required(:cap) => non_neg_integer() | :unlimited,
          required(:used) => non_neg_integer(),
          optional(:label) => String.t(),
          optional(:constrained?) => boolean()
        }

  @typedoc "A repo's implementer-run cap and the runs in it now."
  @type walk_repo :: %{
          required(:cap) => non_neg_integer(),
          required(:used) => non_neg_integer(),
          optional(:label) => String.t()
        }

  @typedoc """
  What a card can run on. A list of candidates, best first; `{:hold, hold}`
  when the card holds itself (its provider constraint allows nothing); or
  `{:none, phrase}` when no provider can take it now (each one paused, out of
  auth, circuit-broken).

  A candidate names its `pool`, the machines that can run it as node groups in
  preference order (`[[id]]`; a flat `[id]` is one group), and optionally the
  `budget` that binds this card there (a policy workspace's, or the exempt
  budget for an exempt card) and its `repo`.
  """
  @type candidates ::
          [candidate()]
          | {:hold, Arbiter.Tasks.Lifecycle.Dispatchable.hold()}
          | {:none, String.t()}

  @type candidate :: %{
          required(:pool) => term(),
          required(:nodes) => [String.t()] | [[String.t()]],
          optional(:budget) => non_neg_integer() | :unlimited,
          optional(:repo) => term()
        }

  @typedoc """
  A card's queue standing. `:next` is the one card being dispatched this
  cycle, `:queued` is waiting its turn, `:blocked` cannot go yet. The walk adds
  `:starting`: a card placed after the first, which a later pass dispatches.
  """
  @type state :: :next | :starting | :queued | :blocked

  @typedoc """
  Why a walk entry is not being dispatched (DC6; ES7 attributes Ready wait by
  it): behind placed work (`:queued`), on a full layer (`{:capacity, layer}`),
  on its own hold (`:own_hold`), or on a paused scheduler (`:paused`). `nil`
  for a placed card.
  """
  @type wait_cause :: :queued | :own_hold | :paused | {:capacity, :provider | :node | :repo}

  @type entry :: %{
          required(:id) => String.t(),
          required(:state) => state(),
          required(:reason) => String.t(),
          required(:hold) => Arbiter.Tasks.Lifecycle.Dispatchable.hold() | nil,
          required(:card) => card(),
          optional(:wait_cause) => wait_cause() | nil,
          optional(:pair) => %{pool: term(), node: String.t()} | nil
        }

  @typedoc "One walk placement, in the order they were made."
  @type placement :: %{id: String.t(), pool: term(), node: String.t()}

  @type t :: %{
          required(:promote) => String.t() | nil,
          required(:entries) => [entry()],
          optional(:placements) => [placement()]
        }

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

  With a `:walk` it is the scheduler walk instead (see "The walk" above): the
  same keys, plus `placements`, a `wait_cause` on every entry and a `pair` on
  each placed one. `promote` is then the first placement.
  """
  @spec plan(input()) :: t()
  def plan(%{walk: %{} = walk} = input), do: walk_plan(input, walk)

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
      # bd-atll60 (G13): per-ticket guardrail verdicts — no eligible model, or a
      # permission awaiting the operator. A card's own block, like the above.
      card_guardrail: Map.get(input, :card_guardrail) || %{},
      slots_free: Map.get(input, :slots_free, 0),
      slot_note: Map.get(input, :slot_note)
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
        {entry(card, :blocked, @paused_reason, :paused), bump(acc)}

      # Only the head of the queue carries a board-wide hold.
      {:held, :no_slot} ->
        card |> decide(no_slot_reason(board.slot_note), acc) |> with_hold(:no_slot)

      {:held, {:quota, _} = hold} ->
        card |> decide(phrase(hold, acc.mutex), acc) |> with_hold(hold)

      # A card's own block never advances the queue position: the card behind
      # it is still next in line.
      {:held, hold} ->
        {entry(card, :blocked, phrase(hold, acc.mutex), hold), acc}
    end
  end

  # bd-5fl9sx: the structured hold rides on the entry beside its phrase, so a
  # reader that wants to explain it never parses the phrase. A card that was
  # queued behind the head is not held by it (`N ahead in queue`).
  defp with_hold({%{state: :blocked} = entry, acc}, hold), do: {%{entry | hold: hold}, acc}
  defp with_hold(result, _hold), do: result

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
      guardrail: Map.get(board.card_guardrail, card.id),
      scope: scope_of(card),
      in_flight: claims(acc)
    })
  end

  # bd-48prlb: name the binding limit when the snapshot knows it.
  defp no_slot_reason(note) when is_binary(note), do: "#{@no_slot_reason} (#{note})"
  defp no_slot_reason(_note), do: @no_slot_reason

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

  defp entry(card, state, reason, hold \\ nil),
    do: %{id: card.id, state: state, reason: reason, hold: hold, card: card}

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

  # bd-atll60 (G13): `held — guardrail (…)`.
  defp phrase({:guardrail, _detail} = hold, _mutex),
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

  # ---- the walk (DC6) --------------------------------------------------------

  defp walk_plan(input, walk) do
    ready = input |> Map.get(:ready) |> List.wrap() |> order()
    board = walk_board(input)
    caps = walk_caps(walk)
    used = %{pools: %{}, nodes: %{}, repos: %{}}

    seed = %{
      placements: [],
      used: used,
      ahead: 0,
      in_flight: Enum.map(Map.get(input, :running) || [], &{&1.task_id, scope_of(&1)}),
      mutex: conflict_claims(Map.get(input, :conflict_claims)),
      # A placed card's own counterparts, so a later card it names is held even
      # when the edge reached only one side (the board folds both; a hand-built
      # plan may not).
      named: %{},
      exhausted: exhausted(caps, used)
    }

    {entries, acc} =
      Enum.map_reduce(ready, seed, fn card, acc -> walk_step(card, board, caps, acc) end)

    placements = Enum.reverse(acc.placements)
    %{promote: first_id(placements), entries: entries, placements: placements}
  end

  # The ticket's own holds only: the walk's capacity sets replace the board-wide
  # quota and slot holds, and the legacy constraint map (which folds capacity
  # in) gives way to the candidates' own evaluation.
  defp walk_board(input) do
    %{
      paused: Map.get(input, :paused) == true,
      card_guardrail: Map.get(input, :card_guardrail) || %{},
      dispatch_holds: Map.get(input, :dispatch_holds) || %{}
    }
  end

  defp walk_caps(walk) do
    Map.new([:pools, :nodes, :repos, :candidates], &{&1, Map.get(walk, &1) || %{}})
  end

  defp first_id([%{id: id} | _]), do: id
  defp first_id([]), do: nil

  defp walk_step(card, board, caps, acc) do
    case Lifecycle.dispatchable(ticket(card), walk_ctx(card, board, acc)) do
      :ok ->
        place_or_wait(card, caps, acc)

      {:held, :paused} ->
        {walk_entry(card, :blocked, @paused_reason, :paused, hold: :paused), bump(acc)}

      # Own holds never advance the queue position.
      {:held, hold} ->
        {walk_entry(card, :blocked, phrase(hold, acc.mutex), :own_hold, hold: hold), acc}
    end
  end

  # The 15 s retry window rides where the head-of-line plan carries it, as the
  # ticket's own constraint-shaped hold (`Arbiter.Board.Autopilot`).
  defp walk_ctx(card, board, acc) do
    %{
      paused: board.paused,
      blocked_by: Map.get(card, :blocked_by),
      conflicts_with:
        List.wrap(Map.get(card, :conflicts_with)) ++ Map.get(acc.named, card.id, []),
      claimed: acc.mutex,
      provider_constraint: Map.get(board.dispatch_holds, card.id),
      guardrail: Map.get(board.card_guardrail, card.id),
      scope: scope_of(card),
      in_flight: acc.in_flight
    }
  end

  defp place_or_wait(card, _caps, %{exhausted: {layer, why}} = acc) do
    if acc.placements == [],
      do: wait(card, {:capacity, layer}, "waiting for capacity — " <> why, acc),
      else: {walk_entry(card, :queued, ahead_reason(acc.ahead), :queued), bump(acc)}
  end

  defp place_or_wait(card, caps, acc) do
    case candidates_for(caps.candidates, card) do
      [_ | _] = candidates ->
        pick_pair(card, candidates, caps, acc)

      {:hold, hold} ->
        {walk_entry(card, :blocked, phrase(hold, acc.mutex), :own_hold, hold: hold), acc}

      {:none, why} ->
        wait(card, {:capacity, :provider}, "waiting for a provider — " <> why, acc)

      _none ->
        wait(card, {:capacity, :provider}, "waiting for a provider — no eligible provider", acc)
    end
  end

  defp candidates_for(fun, card) when is_function(fun, 1), do: fun.(card)
  defp candidates_for(candidates, card) when is_map(candidates), do: Map.get(candidates, card.id)

  # §2.3: pools, then the repo, then a machine that can run the pool.
  defp pick_pair(card, candidates, caps, acc) do
    {open, closed} = Enum.split_with(candidates, &pool_room?(&1, caps, acc))
    {in_repo, repo_full} = Enum.split_with(open, &repo_room?(&1, caps, acc))

    cond do
      open == [] ->
        wait(card, {:capacity, :provider}, "waiting for " <> pools_phrase(closed, caps, acc), acc)

      in_repo == [] ->
        wait(card, {:capacity, :repo}, repo_phrase(hd(repo_full), caps, acc), acc)

      pair = Enum.find_value(in_repo, &pair(&1, caps, acc)) ->
        place(card, pair, caps, acc)

      true ->
        wait(card, {:capacity, :node}, nodes_phrase(in_repo, caps, acc), acc)
    end
  end

  defp pair(candidate, caps, acc) do
    case best_node(candidate, caps, acc) do
      nil -> nil
      node -> {candidate, node}
    end
  end

  defp place(card, {candidate, node}, caps, acc) do
    first? = acc.placements == []

    acc =
      acc
      |> take(:pools, candidate.pool)
      |> take(:nodes, node)
      |> take(:repos, Map.get(candidate, :repo))
      |> Map.update!(:placements, &[%{id: card.id, pool: candidate.pool, node: node} | &1])
      |> Map.update!(:in_flight, &(&1 ++ [{card.id, scope_of(card)}]))
      |> Map.update!(:mutex, &Map.put(&1, card.id, @dispatching_state))
      |> Map.update!(:named, &name_peers(&1, card))
      |> bump()

    acc = %{acc | exhausted: exhausted(caps, acc.used)}

    {state, reason} =
      if first?,
        do: {:next, @next_reason},
        else:
          {:starting,
           "starting — #{pool_label(candidate.pool, caps)} on #{node_label(node, caps)}"}

    {walk_entry(card, state, reason, nil, pair: %{pool: candidate.pool, node: node}), acc}
  end

  defp wait(card, cause, reason, acc),
    do: {walk_entry(card, :blocked, reason, cause), bump(acc)}

  defp walk_entry(card, state, reason, wait_cause, opts \\ []) do
    card
    |> entry(state, reason, Keyword.get(opts, :hold))
    |> Map.merge(%{wait_cause: wait_cause, pair: Keyword.get(opts, :pair)})
  end

  defp name_peers(named, card) do
    card
    |> Map.get(:conflicts_with)
    |> List.wrap()
    |> Enum.reduce(named, fn peer, named ->
      Map.update(named, peer, [card.id], &[card.id | &1])
    end)
  end

  defp take(acc, _layer, nil), do: acc

  defp take(acc, layer, key),
    do: update_in(acc, [:used, layer], &Map.update(&1, key, 1, fn n -> n + 1 end))

  defp placed(acc, layer, key), do: get_in(acc, [:used, layer, key]) || 0

  # ---- capacity --------------------------------------------------------------

  # `{layer, why}` once no pool or no machine has room for anyone, else `nil`.
  defp exhausted(caps, used) do
    acc = %{used: used}

    cond do
      caps.pools == %{} ->
        {:provider, "no provider budget is published"}

      not Enum.any?(caps.pools, fn {id, pool} -> room?(widest(pool), seats(pool, id, acc)) end) ->
        {:provider, "no pool has a free seat: " <> pool_summary(caps, acc)}

      caps.nodes == %{} ->
        {:node, "no machine is available"}

      not Enum.any?(caps.nodes, fn {id, node} -> room?(node.cap, used(node, id, acc)) end) ->
        {:node, "no machine has a free slot: " <> node_summary(caps, acc)}

      true ->
        nil
    end
  end

  defp pool_room?(candidate, caps, acc) do
    case Map.get(caps.pools, candidate.pool) do
      nil -> false
      pool -> room?(limit(candidate, pool), seats(pool, candidate.pool, acc))
    end
  end

  defp repo_room?(candidate, caps, acc) do
    case Map.get(caps.repos, Map.get(candidate, :repo)) do
      nil -> true
      repo -> room?(repo.cap, repo.used + placed(acc, :repos, candidate.repo))
    end
  end

  # The first node group with room; inside it, Placement's rank: lowest load,
  # then name.
  defp best_node(candidate, caps, acc) do
    candidate
    |> node_groups()
    |> Enum.find_value(fn group ->
      group
      |> Enum.filter(&node_room?(&1, caps, acc))
      |> Enum.min_by(&{load(&1, caps, acc), node_label(&1, caps)}, fn -> nil end)
    end)
  end

  defp node_groups(%{nodes: [first | _] = groups}) when is_list(first), do: groups
  defp node_groups(%{nodes: ids}) when is_list(ids), do: [ids]
  defp node_groups(_candidate), do: []

  defp node_room?(id, caps, acc) do
    case Map.get(caps.nodes, id) do
      nil -> false
      node -> room?(node.cap, used(node, id, acc))
    end
  end

  defp load(id, caps, acc) do
    case Map.fetch!(caps.nodes, id) do
      %{cap: cap} = node when is_integer(cap) and cap > 0 -> used(node, id, acc) / cap
      _unlimited -> 0.0
    end
  end

  # The budget that binds this card on this pool: a policy workspace's or the
  # exempt budget when the candidate names one, else the pool's.
  defp limit(candidate, pool), do: Map.get(candidate, :budget) || pool.budget

  # The most any card could use: the exempt budget when it is wider.
  defp widest(%{exempt_budget: exempt, budget: budget})
       when is_integer(exempt) and is_integer(budget),
       do: max(exempt, budget)

  defp widest(pool), do: pool.budget

  defp seats(pool, id, acc), do: pool.seats + placed(acc, :pools, id)
  defp used(node, id, acc), do: node.used + placed(acc, :nodes, id)

  defp room?(:unlimited, _used), do: true
  defp room?(limit, used) when is_integer(limit), do: used < limit

  # ---- phrases ---------------------------------------------------------------

  defp pools_phrase(candidates, caps, acc) do
    candidates
    |> Enum.uniq_by(& &1.pool)
    |> Enum.map_join("; ", fn candidate ->
      label = pool_label(candidate.pool, caps)

      case Map.get(caps.pools, candidate.pool) do
        nil ->
          "#{label}: no budget published"

        pool ->
          "#{label}: #{seats(pool, candidate.pool, acc)} of #{limit(candidate, pool)} seats" <>
            reason_suffix(Map.get(pool, :reason))
      end
    end)
  end

  defp repo_phrase(candidate, caps, acc) do
    repo = Map.fetch!(caps.repos, candidate.repo)
    used = repo.used + placed(acc, :repos, candidate.repo)

    "repo #{Map.get(repo, :label) || to_string(candidate.repo)}: #{used} of #{repo.cap} implementer runs"
  end

  defp nodes_phrase(candidates, caps, acc) do
    pools = candidates |> Enum.map(&pool_label(&1.pool, caps)) |> Enum.uniq() |> Enum.join(", ")

    machines =
      candidates
      |> Enum.flat_map(&List.flatten(node_groups(&1)))
      |> Enum.uniq()
      |> Enum.map_join(", ", fn id ->
        case Map.get(caps.nodes, id) do
          nil -> "#{id} unavailable"
          node -> "#{node_label(id, caps)} #{used(node, id, acc)} of #{node.cap}"
        end
      end)

    "no machine slot for #{pools} work: " <>
      if(machines == "", do: "none can run it", else: machines)
  end

  defp pool_summary(caps, acc) do
    caps.pools
    |> Enum.map(fn {id, pool} -> {pool_label(id, caps), seats(pool, id, acc), widest(pool)} end)
    |> Enum.sort()
    |> Enum.map_join("; ", fn {label, seats, budget} -> "#{label} #{seats} of #{budget} seats" end)
  end

  defp node_summary(caps, acc) do
    caps.nodes
    |> Enum.map(fn {id, node} -> {node_label(id, caps), used(node, id, acc), node.cap} end)
    |> Enum.sort()
    |> Enum.map_join("; ", fn {label, used, cap} -> "#{label} #{used} of #{cap}" end)
  end

  defp reason_suffix(reason) when is_binary(reason) and reason != "", do: " (#{reason})"
  defp reason_suffix(_reason), do: ""

  defp pool_label(id, caps) do
    case Map.get(caps.pools, id) do
      %{label: label} when is_binary(label) -> label
      _ -> default_label(id)
    end
  end

  defp node_label(id, caps) do
    case Map.get(caps.nodes, id) do
      %{label: label} when is_binary(label) -> label
      _ -> to_string(id)
    end
  end

  defp default_label({account, pool}), do: "#{account} #{pool}"
  defp default_label(id) when is_binary(id), do: id
  defp default_label(id), do: inspect(id)
end
