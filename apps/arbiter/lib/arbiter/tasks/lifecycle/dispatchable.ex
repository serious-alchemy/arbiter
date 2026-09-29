defmodule Arbiter.Tasks.Lifecycle.Dispatchable do
  @moduledoc """
  The one dispatch-eligibility predicate (bd-9yqspm, child 3: bd-asxw4e).

  Before this module there were four answers to "may this ticket be
  dispatched?": the board's Ready filter, the scheduler's own card blocks,
  Autopilot's own re-check in `Arbiter.Worker.Dispatch`, and nothing at
  all for a manual dispatch, which went ahead from Backlog or past open
  blockers without a word. Now `Arbiter.Board.Scheduler.plan/1` and
  `Arbiter.Worker.Dispatch` both ask `dispatchable/2`.

  A ticket is dispatchable when

    1. its column (`Arbiter.Tasks.Lifecycle.view/2`) is `:ready` — `:queued`,
       with no unsatisfied gating blocker; and
    2. the scheduler holds nothing against it: a `:conflicts_with`
       counterpart in flight, a file overlap with in-flight work, a paused
       scheduler, a quota or auth hold, or no free slot.

  It is pure, like the view: every hold is an input in `ctx`, and a hold the
  caller does not pass is not asked about. So the scheduler passes all of
  them, and a manual dispatch — the operator overriding the scheduler —
  passes only the column's inputs.

  ## ctx

    * `:blocked_by`, `:runs` — as for `Arbiter.Tasks.Lifecycle.view/2`;
    * `:conflicts_with` — the ticket's `:conflicts_with` counterparts, and
      `:claimed` — `%{id => label}` (or a list of ids) of what is in flight;
    * `:scope` — the ticket's declared file scope, and `:in_flight` —
      `[{task_id, scope}]` for work already holding files;
    * `:paused` — the scheduler is paused;
    * `:quota` — `:ok`, or `{:hold, reason}`;
    * `:slots_free` — free slots; absent means "not asked".

  ## Holds, in precedence order

  The column first, then the ticket's own holds, then the board-wide ones —
  the same order the board has always shown reasons in, because a card's own
  block survives the board-wide one clearing.

  | hold | meaning |
  |---|---|
  | `{:column, :backlog}` | in Backlog — not promoted |
  | `{:blocked_by, ids}` | queued, waiting on these blockers |
  | `{:column, column}` | already past Ready (`:in_progress`, `:merging`, `:verifying`, `:closed`) |
  | `{:conflicts_with, id}` | a `:conflicts_with` counterpart is in flight |
  | `{:file_overlap, files, id}` | these declared files are in flight on `id` |
  | `:paused` | the scheduler is paused |
  | `{:quota, reason}` | a quota or auth hold |
  | `:no_slot` | no free worker slot |
  """

  alias Arbiter.Board.FileScope
  alias Arbiter.Tasks.EdgeGate
  alias Arbiter.Tasks.Lifecycle.View

  @type hold ::
          {:column, View.column() | nil}
          | {:blocked_by, [String.t()]}
          | {:conflicts_with, String.t()}
          | {:file_overlap, [String.t()], String.t()}
          | :paused
          | {:quota, String.t()}
          | :no_slot

  @type result :: :ok | {:held, hold()}

  @column_names %{
    backlog: "in Backlog",
    in_progress: "already In progress",
    merging: "already Merging",
    verifying: "already Verifying",
    closed: "Closed"
  }

  @doc "May `ticket` be dispatched, given `ctx`? See the moduledoc."
  @spec dispatchable(map(), map()) :: result()
  def dispatchable(ticket, ctx \\ %{}) when is_map(ticket) and is_map(ctx) do
    with :ok <- column_hold(View.view(ticket, Map.take(ctx, [:blocked_by, :runs]))),
         :ok <- mutex_hold(ctx),
         :ok <- overlap_hold(ctx) do
      board_hold(ctx)
    end
  end

  @doc "`dispatchable/2 == :ok`."
  @spec dispatchable?(map(), map()) :: boolean()
  def dispatchable?(ticket, ctx \\ %{}), do: dispatchable(ticket, ctx) == :ok

  @doc ~s(The hold, phrased for an operator: `"in Backlog"`, `"blocked by bd-3, bd-9"`.)
  @spec describe_hold(hold()) :: String.t()
  def describe_hold({:column, column}), do: Map.get(@column_names, column, "not on the board")
  def describe_hold({:blocked_by, ids}), do: "blocked by " <> Enum.join(ids, ", ")
  def describe_hold({:conflicts_with, peer}), do: EdgeGate.describe({:conflicts_with, peer})

  def describe_hold({:file_overlap, files, task_id}),
    do: "#{name_files(files)} in flight on #{task_id}"

  def describe_hold(:paused), do: "scheduler paused"
  def describe_hold({:quota, reason}), do: reason
  def describe_hold(:no_slot), do: "no free worker slot"

  # ---- holds ----------------------------------------------------------------

  defp column_hold(%{column: :ready}), do: :ok
  defp column_hold(%{column: :blocked, blocked_by: ids}), do: {:held, {:blocked_by, ids}}
  defp column_hold(%{column: column}), do: {:held, {:column, column}}

  defp mutex_hold(ctx) do
    case EdgeGate.gate(%{
           conflicts: Map.get(ctx, :conflicts_with),
           claimed: Map.get(ctx, :claimed)
         }) do
      :ok -> :ok
      {:blocked, {:conflicts_with, peer}} -> {:held, {:conflicts_with, peer}}
    end
  end

  # Already-running work first, in the order given — so a collision is
  # attributed to the worker that has actually been holding the file.
  defp overlap_hold(ctx) do
    scope = scope_of(Map.get(ctx, :scope))

    ctx
    |> Map.get(:in_flight)
    |> List.wrap()
    |> Enum.find_value(:ok, fn {task_id, other} ->
      case FileScope.overlap(scope, scope_of(other)) do
        [] -> nil
        files -> {:held, {:file_overlap, files, task_id}}
      end
    end)
  end

  defp board_hold(%{paused: true}), do: {:held, :paused}
  defp board_hold(%{quota: {:hold, reason}}), do: {:held, {:quota, reason}}

  defp board_hold(%{slots_free: free}) when not (is_integer(free) and free > 0),
    do: {:held, :no_slot}

  defp board_hold(_ctx), do: :ok

  defp scope_of(%MapSet{} = scope), do: scope
  defp scope_of(paths) when is_list(paths), do: MapSet.new(paths)
  defp scope_of(_), do: MapSet.new()

  defp name_files([file]), do: file
  defp name_files([file | rest]), do: "#{file} +#{length(rest)} more"
end
