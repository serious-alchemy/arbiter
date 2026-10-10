defmodule Arbiter.Board.AdmissionShadow do
  @moduledoc """
  What `scheduler_admission` records (DC6, bd-9ycsk4;
  `docs/design/provider-dynamic-concurrency.md` §10.1-§10.2).

  ## The modes

  `mode/0` reads the installation setting (`Arbiter.Settings.scheduler_admission/0`):

    * `legacy` (the default) — today's plan, gate and caps; nothing new runs
      or is recorded (I1).
    * `shadow` — dispatch is unchanged (I2); the board also plans the
      scheduler walk (`Arbiter.Board.Snapshot.load/1`, `Arbiter.Board.WalkInputs`)
      and `Arbiter.Board.Autopilot` records it beside today's decision.
    * `enforce` — dispatches by the walk and the budgets once DC8 wires it.
      Until then it dispatches and records exactly as `shadow`: nothing may
      change a dispatch decision before DC8.

  ## What is recorded

    * **Beside every dispatch** — `dispatch_record/3`, stored on the run as
      `routing_decision.admission_shadow`: the walk's first pick and its
      (pool, machine) pair, whether it agrees with the card dispatched, whether
      the pass was comparable (both sides had a candidate), and — when they
      differ — why the walk would not have dispatched ours (`cause`,
      `reason`).
    * **On every hold change** — `signature/1` is what a pass decided on each
      side: today's pick or the head it holds and why, the walk's first
      placement or the head it skips and why, and the pools whose budget sits
      below today's cap. Autopilot writes one `Arbiter.Board.AdmissionShadowEvent`
      (`event/3`, `record_event/1`) when the signature changes, so a steady
      board writes nothing however often it is planned.

  Everything here is a record. Nothing it returns reaches a dispatch decision.
  """

  require Logger

  alias Arbiter.Board.AdmissionShadowEvent

  @type mode :: :legacy | :shadow | :enforce

  @board_holds [:no_slot, :quota, :paused]

  @doc "The admission mode in force; `:legacy` when it cannot be read."
  @spec mode() :: mode()
  def mode do
    Arbiter.Settings.scheduler_admission()
  rescue
    _ -> :legacy
  catch
    :exit, _ -> :legacy
  end

  @doc "Whether `mode` plans the scheduler walk beside today's plan."
  @spec walks?(mode()) :: boolean()
  def walks?(mode), do: mode in [:shadow, :enforce]

  # ---- beside a dispatch -------------------------------------------------------

  @doc """
  The `admission_shadow` record for a dispatch of `dispatched` off `board`, or
  `nil` when the board carries no walk. String keys: it is stored as-is.
  """
  @spec dispatch_record(map(), mode(), String.t()) :: map() | nil
  def dispatch_record(%{walk: %{} = walk}, mode, dispatched) when is_binary(dispatched) do
    pick = walk.promote

    walk
    |> pick_fields()
    |> Map.merge(%{
      "policy" => to_string(mode),
      "dispatched" => dispatched,
      "pick" => pick,
      "agrees" => pick == dispatched,
      "comparable" => not is_nil(pick),
      "cause" => cause(walk, dispatched),
      "reason" => if(pick == dispatched, do: nil, else: walk_reason(walk, dispatched)),
      "placements" => length(walk.placements)
    })
  end

  def dispatch_record(_board, _mode, _dispatched), do: nil

  # ---- on a hold change --------------------------------------------------------

  @doc """
  What a board's pass decided, on both sides, without the words: today's pick
  or the head it holds and its hold, the walk's first placement or the head it
  skips and its wait cause, and the pools whose budget is below today's cap.
  Two passes with the same signature are the same admission outcome.
  """
  @spec signature(map()) :: term()
  def signature(board) do
    walk = Map.get(board, :walk) || %{}
    {legacy_outcome(board), walk_outcome(walk), below_cap(walk)}
  end

  @doc "The `AdmissionShadowEvent` attributes for `board`'s pass at `at`."
  @spec event(map(), mode(), DateTime.t()) :: map()
  def event(board, mode, %DateTime{} = at) do
    walk = Map.get(board, :walk) || %{promote: nil, placements: [], entries: [], pools: %{}}
    legacy_pick = Map.get(board, :promote)
    walk_pick = walk.promote

    %{
      at: at,
      policy: to_string(mode),
      legacy_pick: legacy_pick,
      walk_pick: walk_pick,
      agrees: legacy_pick == walk_pick,
      comparable: not is_nil(legacy_pick) and not is_nil(walk_pick),
      cause: event_cause(walk, legacy_pick, walk_pick),
      legacy: legacy_side(board),
      walk: walk_side(walk),
      budgets: budgets(Map.get(walk, :pools) || %{})
    }
  end

  @doc "Write one event row. A row that cannot be written is logged and dropped."
  @spec record_event(map()) :: :ok
  def record_event(attrs) do
    case Ash.create(AdmissionShadowEvent, attrs, action: :record) do
      {:ok, _row} -> :ok
      {:error, error} -> drop(error)
    end
  rescue
    e -> drop(e)
  catch
    :exit, reason -> drop(reason)
  end

  defp drop(error) do
    Logger.warning("AdmissionShadow: an event row was not written: #{inspect(error, limit: 5)}")
    :ok
  end

  # ---- the two sides -----------------------------------------------------------

  defp legacy_outcome(board) do
    case Map.get(board, :promote) do
      id when is_binary(id) ->
        {:place, id}

      nil ->
        case legacy_head(board) do
          nil -> :empty
          entry -> {:hold, entry.id, hold_kind(entry.hold)}
        end
    end
  end

  defp walk_outcome(walk) do
    case Map.get(walk, :placements) || [] do
      [first | _] ->
        {:place, first.id, first.pool, first.node}

      [] ->
        case walk_head(walk) do
          nil -> :empty
          entry -> {:hold, entry.id, entry.wait_cause}
        end
    end
  end

  defp below_cap(walk) do
    for {id, pool} <- Map.get(walk, :pools) || %{},
        is_integer(Map.get(pool, :cap)) and is_integer(pool.budget) and pool.budget < pool.cap,
        do: id,
        into: MapSet.new()
  end

  # Today's head when it holds: the card a board-wide hold stopped, else the
  # first card held on its own.
  defp legacy_head(board) do
    blocked = board |> Map.get(:ready, []) |> Enum.filter(&(&1.state == :blocked))
    Enum.find(blocked, &(hold_kind(&1.hold) in @board_holds)) || List.first(blocked)
  end

  # The walk's head when it places nothing: the first card waiting on a layer
  # or behind work, else the first card held on its own.
  defp walk_head(walk) do
    entries = Map.get(walk, :entries) || []
    Enum.find(entries, &(&1.wait_cause not in [nil, :own_hold])) || List.first(entries)
  end

  defp legacy_side(board) do
    case Map.get(board, :promote) do
      id when is_binary(id) ->
        %{"pick" => id, "head" => id, "hold" => nil, "reason" => entry_reason(board.ready, id)}

      nil ->
        head = legacy_head(board)

        %{
          "pick" => nil,
          "head" => head && head.id,
          "hold" => head && kind_text(hold_kind(head.hold)),
          "reason" => head && head.reason
        }
    end
  end

  defp walk_side(walk) do
    head = if walk.promote, do: nil, else: walk_head(walk)

    walk
    |> pick_fields()
    |> Map.merge(%{
      "pick" => walk.promote,
      "placements" => Enum.map(walk.placements, & &1.id),
      "head" => head && head.id,
      "wait_cause" => head && cause_text(head.wait_cause),
      "reason" => head && head.reason
    })
  end

  defp pick_fields(%{placements: [first | _]} = walk) do
    {account_id, pool} = pool_parts(first.pool)

    %{
      "account_id" => account_id,
      "pool" => pool,
      "pool_label" => get_in(walk, [:pools, first.pool, :label]),
      "node" => first.node
    }
  end

  defp pick_fields(_walk),
    do: %{"account_id" => nil, "pool" => nil, "pool_label" => nil, "node" => nil}

  defp budgets(pools) do
    pools
    |> Enum.map(fn {id, pool} ->
      {account_id, name} = pool_parts(id)

      %{
        "account_id" => account_id,
        "pool" => name,
        "label" => Map.get(pool, :label),
        "budget" => json_count(pool.budget),
        "seats" => pool.seats,
        "free" => free(pool),
        "exempt_budget" => Map.get(pool, :exempt_budget),
        "cap" => Map.get(pool, :cap),
        "binding" => binding_text(Map.get(pool, :binding)),
        "reason" => Map.get(pool, :reason)
      }
    end)
    |> Enum.sort_by(&{&1["label"] || "", &1["pool"] || ""})
  end

  # ---- causes ------------------------------------------------------------------

  # Why the walk would not have dispatched `id` first: placed too, but after a
  # card today holds (`legacy_hold`); else its own wait cause.
  defp cause(%{promote: id}, id), do: nil

  defp cause(walk, id) do
    case Enum.find(walk.entries, &(&1.id == id)) do
      %{state: state} when state in [:next, :starting] -> "legacy_hold"
      %{wait_cause: wait_cause} -> cause_text(wait_cause)
      nil -> "not_planned"
    end
  end

  defp event_cause(_walk, pick, pick), do: nil
  defp event_cause(_walk, nil, _walk_pick), do: "legacy_hold"
  defp event_cause(walk, legacy_pick, _walk_pick), do: cause(walk, legacy_pick)

  defp walk_reason(walk, id) do
    case Enum.find(walk.entries, &(&1.id == id)) do
      %{reason: reason} -> reason
      nil -> nil
    end
  end

  defp entry_reason(ready, id) do
    case Enum.find(ready || [], &(&1.id == id)) do
      %{reason: reason} -> reason
      nil -> nil
    end
  end

  # ---- words -------------------------------------------------------------------

  defp hold_kind(nil), do: nil
  defp hold_kind({kind, _}), do: kind
  defp hold_kind({kind, _, _}), do: kind
  defp hold_kind(kind) when is_atom(kind), do: kind

  defp kind_text(nil), do: nil
  defp kind_text(kind), do: to_string(kind)

  defp cause_text(nil), do: nil
  defp cause_text({:capacity, layer}), do: "capacity:#{layer}"
  defp cause_text(cause) when is_atom(cause), do: to_string(cause)

  defp binding_text(nil), do: nil
  defp binding_text({:window, label}), do: "window:#{label}"
  defp binding_text(binding) when is_atom(binding), do: to_string(binding)
  defp binding_text(binding), do: inspect(binding)

  defp pool_parts({:unmetered, provider}), do: {nil, to_string(provider)}
  defp pool_parts({account_id, pool}), do: {account_id, pool}
  defp pool_parts(other), do: {nil, inspect(other)}

  defp free(%{budget: :unlimited}), do: "unlimited"
  defp free(%{budget: budget, seats: seats}), do: max(budget - seats, 0)

  defp json_count(:unlimited), do: "unlimited"
  defp json_count(n), do: n
end
