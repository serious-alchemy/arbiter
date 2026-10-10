defmodule Arbiter.Workers.RunState do
  @moduledoc """
  The one run vocabulary (ticket lifecycle 5/13, bd-1uu19b), shared by the
  worker GenServer (`Arbiter.Worker`) and its durable row
  (`Arbiter.Workers.Run`). A run is one attempt at a ticket, and never
  describes the ticket. See `docs/design/ticket-lifecycle.md` §6.

  | Field | Values |
  |---|---|
  | kind | `implement \\| review \\| fix_pass \\| conflict` |
  | state | `starting \\| working \\| waiting \\| finished` |
  | outcome (when finished) | `succeeded \\| failed \\| interrupted \\| handed_off \\| stopped` |

    * `starting` — registered, agent not driving yet (a fresh dispatch, or a
      resume re-attaching to its preserved worktree).
    * `working` — the agent is driving.
    * `waiting` — paused on something outside the run: the agent asked a
      question (`waiting_on: :question`), or the ReviewGate is judging the
      author's diff (`waiting_on: :review_gate`).
    * `finished` — over, with an `outcome`: `succeeded`; `failed` (a review
      park or a review that never started is a failed run, with its cause
      recorded on the ticket); `interrupted` (the server stopped under it); or
      `handed_off` (a follow-up run superseded it).

  An unfinished run has no outcome.
  """

  @kinds [:implement, :review, :fix_pass, :conflict]
  @states [:starting, :working, :waiting, :finished]
  @outcomes [:succeeded, :failed, :interrupted, :handed_off, :stopped]

  @type kind :: :implement | :review | :fix_pass | :conflict
  @type state :: :starting | :working | :waiting | :finished
  @type outcome :: :succeeded | :failed | :interrupted | :handed_off | :stopped

  @doc "Every run kind."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Every run state."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Every finished run's outcome."
  @spec outcomes() :: [outcome()]
  def outcomes, do: @outcomes

  @doc "True for a run still in flight (any state but `:finished`)."
  @spec live?(term()) :: boolean()
  def live?(state), do: state in [:starting, :working, :waiting]

  @doc """
  The kind of a run from the worker's meta, by the role tag the ReviewGate,
  Dispatch and the merge queue stamp on it. An authoring worker and the
  ReviewGate's revise-round implementer are both `:implement`.
  """
  @spec kind_from_meta(map() | nil) :: kind()
  def kind_from_meta(meta) when is_map(meta) do
    case Map.get(meta, :role) do
      :reviewer -> :review
      :fix_pass -> :fix_pass
      :conflict_resolver -> :conflict
      _ -> if review_only?(meta), do: :review, else: :implement
    end
  end

  def kind_from_meta(_), do: :implement

  defp review_only?(meta),
    do: Map.get(meta, :review_only) == true or Map.get(meta, "review_only") == true

  @doc """
  The kind for a pre-5/13 `worker_type`. The same rule as the migration that
  backfilled `worker_runs.kind`.
  """
  @spec kind_for_worker_type(atom()) :: kind()
  def kind_for_worker_type(:review), do: :review
  def kind_for_worker_type(:fix_pass), do: :fix_pass
  def kind_for_worker_type(:conflict), do: :conflict
  def kind_for_worker_type(_main_or_impl), do: :implement

  @doc """
  `{state, outcome}` for a pre-5/13 `worker_runs.status`. The same rule as
  the migration that backfilled `state` and `outcome`.
  """
  @spec from_legacy_status(atom()) :: {state(), outcome() | nil}
  def from_legacy_status(:running), do: {:working, nil}
  def from_legacy_status(:completed), do: {:finished, :succeeded}
  def from_legacy_status(:interrupted), do: {:finished, :interrupted}
  def from_legacy_status(_failed_or_review_park), do: {:finished, :failed}

  @doc """
  A short human label: `"working"`, `"waiting"`, `"finished (failed)"`.
  """
  @spec label(state() | nil, outcome() | nil) :: String.t()
  def label(:finished, outcome) when outcome in @outcomes, do: "finished (#{outcome})"
  def label(state, _outcome) when state in @states, do: Atom.to_string(state)
  def label(_state, _outcome), do: "unknown"
end
