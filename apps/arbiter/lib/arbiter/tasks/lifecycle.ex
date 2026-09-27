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
  | `demote` | queued → backlog |
  | `start` | queued → active |
  | `open_pr` | active → merging |
  | `return_to_work` | merging → active |
  | `await_verification` | active \\| merging → verifying |
  | `close` | any non-closed → closed |
  | `reopen` | closed \\| verifying → queued |

  A no-PR ticket (`task`, and `research` once bd-9s9dqz lands) goes active →
  closed or active → verifying directly. Those pairs are already in the table
  (`close` and `await_verification` both accept `active`), so no type
  exception is needed to allow them.

  ## Legacy dual-write (the overlap)

  Until the later children switch every consumer to `state`, each transition
  also writes the legacy fields per `legacy_fields/1`, and
  `legacy_state/1` is the rule the migration backfilled existing rows with.

  Who writes `state`:

    * the transition actions, through `Changes.Transition`;
    * `:create`, which always lands in `:backlog`;
    * during the overlap only, a legacy `status` write — through `:update`,
      or `:return_to_backlog`'s reset of a stopped in-progress ticket —
      which re-derives `state` with `legacy_state/1`
      (`Changes.FollowLegacyStatus`) so the two never disagree. It is deleted
      with `status` in bd-36ytcl;
    * the rows written around Ash — the migration's backfill and the Dolt
      importer (`Arbiter.Tasks.DoltImport.Mapper`) — by the same rule.
  """

  @states [:backlog, :queued, :active, :merging, :verifying, :closed]
  @close_reasons [:completed, :wont_do, :duplicate]

  @rules %{
    promote: {[:backlog], :queued},
    demote: {[:queued], :backlog},
    start: {[:queued], :active},
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

  @doc "The stored state, or the one a legacy row's columns imply; `nil` when neither."
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

  @doc """
  The legacy columns a transition into `state` dual-writes.

  `refined` is omitted for `:closed`: a close leaves it as it was.
  """
  @spec legacy_fields(state()) :: %{
          required(:status) => atom(),
          optional(:refined) => boolean()
        }
  def legacy_fields(:backlog), do: %{status: :open, refined: false}
  def legacy_fields(:queued), do: %{status: :open, refined: true}
  def legacy_fields(:active), do: %{status: :in_progress, refined: true}
  def legacy_fields(:merging), do: %{status: :in_progress, refined: true}
  def legacy_fields(:verifying), do: %{status: :awaiting_verification, refined: true}
  def legacy_fields(:closed), do: %{status: :closed}

  @doc """
  The state a row's legacy columns imply — the migration's backfill rule.

  An `in_progress` row with a PR on record (`pr_ref`) or a merge the Watchdog
  deferred (`pending_merge`) is `:merging`; any other `in_progress` row is
  `:active`. An absent `refined` reads as unrefined.
  """
  @spec legacy_state(map()) :: state()
  def legacy_state(row) do
    case Map.get(row, :status) do
      :open -> if Map.get(row, :refined) == true, do: :queued, else: :backlog
      :in_progress -> if pr_on_record?(row), do: :merging, else: :active
      :awaiting_verification -> :verifying
      :closed -> :closed
    end
  end

  defp pr_on_record?(row),
    do: present?(Map.get(row, :pr_ref)) or present?(Map.get(row, :pending_merge))

  defp present?(nil), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_map(value), do: map_size(value) > 0
  defp present?(_), do: true
end
