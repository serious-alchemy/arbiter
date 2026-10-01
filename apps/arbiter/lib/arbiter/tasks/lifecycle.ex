defmodule Arbiter.Tasks.Lifecycle do
  @moduledoc """
  The ticket lifecycle (bd-9yqspm, child 1: bd-842qio): one stored `state`
  per ticket, changed only by named transitions.

  This module is the table. It is pure (no DB, no Ash) so the resource, the
  migration test and the design doc (`docs/design/ticket-lifecycle.md`) can
  all be checked against one definition. `Arbiter.Tasks.Issue.Changes.Transition`
  applies it inside the Issue actions.

  ## States

      backlog → queued → active ⇄ merging
                           │         │
                           └────┬────┘
                                ▼
                            verifying → closed

  | state | meaning |
  |---|---|
  | `:backlog` | filed, not refined — never dispatched automatically |
  | `:queued` | refined and waiting for a slot (the board's Blocked/Ready split is computed from its dependency edges) |
  | `:active` | holding a slot: an implementer, fix or conflict run is working on it |
  | `:merging` | a PR is open and the merge path owns it |
  | `:verifying` | merged, waiting for the post-merge restart-and-observe |
  | `:closed` | done; `close_reason` says how |

  ## Transitions

  | transition | from → to |
  |---|---|
  | `promote` | backlog → queued |
  | `demote` | queued \\| active \\| merging → backlog |
  | `start` | backlog \\| queued → active |
  | `requeue` | active \\| merging → queued |
  | `open_pr` | active → merging |
  | `return_to_work` | merging → active |
  | `await_verification` | active \\| merging → verifying |
  | `close` | any non-closed → closed |
  | `reopen` | closed \\| verifying → queued |

  A no-PR ticket (`task` or `research` — `Issue.no_pr_type?/1`) goes active →
  closed or active → verifying directly. Those pairs are already in the table
  (`close` and `await_verification` both accept `active`), so no type
  exception is needed to allow them.

  The three moves that used to be legacy `status` writes (bd-36ytcl) are
  transitions too:

    * `start` from `backlog` — a forced manual dispatch that skips the Ready
      queue. `dispatchable/2` holds a Backlog ticket, so only
      `Worker.Dispatch` with `--force` takes this edge;
    * `requeue` — a run that stopped without finishing puts its ticket back in
      the queue (`Worker.AuthDeath`, after the run's credentials died);
    * `demote` from `active` / `merging` — `:return_to_backlog` on a ticket
      whose worker already stopped (bd-2098). `Changes.GuardDemote` refuses
      while a worker is live.

  Who writes `state`:

    * the transition actions, through `Changes.Transition`;
    * `:create`, which always lands in `:backlog`;
    * the rows written around Ash — the lifecycle migration's backfill and
      the Dolt importer (`Arbiter.Tasks.DoltImport.Mapper`).

  Every one of them leaves a `ticket_transitions` row
  (`Arbiter.Tasks.TicketTransition`, bd-5gkqdr): triggers on `issues` record
  each change of `state` in the same statement, naming it by its `(from, to)`
  pair in this table.
  """

  @states [:backlog, :queued, :active, :merging, :verifying, :closed]
  @close_reasons [:completed, :wont_do, :duplicate]

  @rules %{
    promote: {[:backlog], :queued},
    demote: {[:queued, :active, :merging], :backlog},
    start: {[:backlog, :queued], :active},
    requeue: {[:active, :merging], :queued},
    open_pr: {[:active], :merging},
    return_to_work: {[:merging], :active},
    await_verification: {[:active, :merging], :verifying},
    close: {@states -- [:closed], :closed},
    reopen: {[:closed, :verifying], :queued}
  }

  @type state :: :backlog | :queued | :active | :merging | :verifying | :closed
  @type close_reason :: :completed | :wont_do | :duplicate
  @type transition ::
          :promote
          | :demote
          | :start
          | :requeue
          | :open_pr
          | :return_to_work
          | :await_verification
          | :close
          | :reopen

  @doc """
  The ticket's column, step, blockers and attention (bd-6zapbl). See
  `Arbiter.Tasks.Lifecycle.View` for the rules and `ctx`'s keys.
  """
  defdelegate view(ticket, ctx \\ %{}), to: Arbiter.Tasks.Lifecycle.View

  @doc "The interim five-column board mapping. See `Arbiter.Tasks.Lifecycle.View.board_column/2`."
  defdelegate board_column(ticket, ctx \\ %{}), to: Arbiter.Tasks.Lifecycle.View

  @doc "Whether a gating blocker no longer holds its dependents back: `:verifying` or `:closed`."
  defdelegate blocker_satisfied?(ticket_or_state), to: Arbiter.Tasks.Lifecycle.View

  @doc "The ticket's stored state; `nil` for a map that carries none."
  defdelegate state_of(ticket), to: Arbiter.Tasks.Lifecycle.View

  @doc """
  The one dispatch-eligibility predicate (bd-asxw4e): `:ok` when the ticket is
  in the `:ready` column and the scheduler holds nothing against it, else
  `{:held, hold}`. See `Arbiter.Tasks.Lifecycle.Dispatchable` for `ctx`.
  """
  defdelegate dispatchable(ticket, ctx \\ %{}), to: Arbiter.Tasks.Lifecycle.Dispatchable

  @doc "Whether `dispatchable/2` is `:ok`."
  defdelegate dispatchable?(ticket, ctx \\ %{}), to: Arbiter.Tasks.Lifecycle.Dispatchable

  @doc ~s[A dispatch hold, phrased for an operator ("in Backlog", "blocked by bd-3").]
  defdelegate describe_hold(hold), to: Arbiter.Tasks.Lifecycle.Dispatchable

  @doc "The stored states, in lifecycle order."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Why a closed ticket closed."
  @spec close_reasons() :: [close_reason()]
  def close_reasons, do: @close_reasons

  @doc "The named transitions."
  @spec transitions() :: [transition()]
  def transitions, do: Map.keys(@rules)

  @doc "`{from_states, to_state}` for `transition`."
  @spec rule(transition()) :: {[state()], state()}
  def rule(transition), do: Map.fetch!(@rules, transition)

  @doc "Whether `transition` may leave `from`."
  @spec allowed?(atom(), atom()) :: boolean()
  def allowed?(transition, from) do
    case Map.fetch(@rules, transition) do
      {:ok, {sources, _target}} -> from in sources
      :error -> false
    end
  end
end
