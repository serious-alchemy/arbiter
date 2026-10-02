defmodule Arbiter.Board.QueueOrder do
  @moduledoc """
  The inputs to the epic-aware queue order (`docs/design/epic-aware-scheduling.md`
  §4, §6.6; ticket ES3): what `Arbiter.Board.Scheduler.order/1` reads off a
  card beyond its own priority, rank and age.

  `build/6` resolves every ticket once (`Arbiter.Tasks.EpicFloor`) and decides
  whether the **lift cap** is reached; `annotate/3` then stamps one card with

    * `effective_priority` — `min(own, floors on epic ancestors)`, or the own
      priority when the lift is capped, the floors are switched off, or there
      is no floor;
    * `priority_via` — the epic supplying the winning floor (set on a capped
      card too, so the card can say what is waiting), else `nil`;
    * `priority_lift` — `:applied`, `:capped` or `nil`;
    * `finish_class` — `0` aged (or finish-first off), `1` child of an epic
      already in progress, `2` everything else;
    * `open_leaves` — class 1 only: open leaf descendants of the nearest epic;
      else `0`.

  Pure: the caller hands over the issues, the `parent_of` pairs, the slot total
  and a `ready_since` map (`Arbiter.Board.ReadySince`), and a clock.

  With no floor set and finish-first off nothing is resolved at all, every card
  reads `effective_priority == priority`, class `0`, `0` open leaves, and the
  order is exactly `{priority, rank, created_at}`.

  ## Lift cap

  `L` is the number of `:active` tickets that are lifted by today's floors,
  computed at plan time and never stored. When `L >= cap`, every card in the
  queue is ordered by its own priority and says so (`priority_lift: :capped`).
  The cap is `scheduling_max_lifted_in_flight`, else `max(slots_total - 1, 1)`,
  so one slot always serves unlifted work in its own order.
  """

  alias Arbiter.Tasks.EpicFloor
  alias Arbiter.Tasks.Lifecycle

  @type settings :: %{
          epic_floors_enabled: boolean(),
          max_lifted_in_flight: pos_integer() | nil,
          finish_first: boolean(),
          finish_first_max_wait_hours: pos_integer()
        }

  @type t :: %{
          resolutions: %{optional(String.t()) => EpicFloor.resolution()},
          settings: settings(),
          capped?: boolean(),
          ready_since: %{optional(String.t()) => DateTime.t()},
          now: DateTime.t()
        }

  @settings_keys [
    :epic_floors_enabled,
    :max_lifted_in_flight,
    :finish_first,
    :finish_first_max_wait_hours
  ]

  @doc "The settings with nothing overridden: floors on, derived cap, finish-first off, 24h aging."
  @spec default_settings() :: settings()
  def default_settings do
    %{
      epic_floors_enabled: true,
      max_lifted_in_flight: nil,
      finish_first: false,
      finish_first_max_wait_hours: 24
    }
  end

  @doc "`default_settings/0` overlaid with whichever keys `overrides` carries (`nil` values are skipped)."
  @spec settings(map() | nil) :: settings()
  def settings(overrides) do
    overrides =
      for {k, v} <- Map.new(overrides || %{}),
          k in @settings_keys,
          v != nil,
          into: %{},
          do: {k, v}

    Map.merge(default_settings(), overrides)
  end

  @doc "The lift cap in force for `slots_total` slots."
  @spec lift_cap(settings(), non_neg_integer()) :: pos_integer()
  def lift_cap(%{max_lifted_in_flight: n}, _slots_total) when is_integer(n) and n > 0, do: n
  def lift_cap(_settings, slots_total), do: max(slots_total - 1, 1)

  @doc """
  Resolve the board once. `issues` is every ticket the board reads (reference
  issues folded in); `parent_of` the `{parent_id, child_id}` pairs.
  """
  @spec build(
          [map()],
          [{String.t(), String.t()}],
          non_neg_integer(),
          map() | nil,
          map(),
          DateTime.t()
        ) ::
          t()
  def build(issues, parent_of, slots_total, settings, ready_since, now) do
    settings = settings(settings)
    resolutions = resolve(issues, parent_of, settings)

    %{
      resolutions: resolutions,
      settings: settings,
      capped?: capped?(issues, resolutions, lift_cap(settings, slots_total)),
      ready_since: ready_since || %{},
      now: now
    }
  end

  @doc "Stamp `card` with the five order fields. See the moduledoc."
  @spec annotate(map(), t()) :: map()
  def annotate(%{id: id, priority: own} = card, %{} = ctx) do
    res = Map.get(ctx.resolutions, id)
    {effective, via, lift} = lift(own, res, ctx.capped?)
    {class, leaves} = finish(card, res, ctx)

    Map.merge(card, %{
      effective_priority: effective,
      priority_via: via,
      priority_lift: lift,
      finish_class: class,
      open_leaves: leaves
    })
  end

  defp lift(own, %{lifted?: true, via: via}, true), do: {own, via, :capped}
  defp lift(_own, %{lifted?: true, via: via, effective: eff}, false), do: {eff, via, :applied}
  defp lift(own, _res, _capped?), do: {own, nil, nil}

  defp finish(_card, _res, %{settings: %{finish_first: false}}), do: {0, 0}

  defp finish(%{id: id}, res, ctx) do
    cond do
      aged?(id, ctx) ->
        {0, 0}

      match?(%{nearest_epic: e, in_progress: n} when e != nil and n > 0, res) ->
        {1, res.open_leaves}

      true ->
        {2, 0}
    end
  end

  defp aged?(id, %{ready_since: since, now: now, settings: settings}) do
    case Map.get(since, id) do
      %DateTime{} = at ->
        DateTime.diff(now, at, :second) > settings.finish_first_max_wait_hours * 3600

      _ ->
        false
    end
  end

  # Nothing to resolve (no floor anywhere, finish-first off): the order is
  # today's, and the walk is skipped.
  defp resolve(issues, parent_of, settings) do
    issues = if settings.epic_floors_enabled, do: issues, else: Enum.map(issues, &drop_floor/1)

    if parent_of != [] and (settings.finish_first or Enum.any?(issues, &floored_epic?/1)) do
      issues
      |> Enum.map(&resolver_issue/1)
      |> EpicFloor.resolve(parent_of)
    else
      %{}
    end
  end

  defp drop_floor(issue), do: Map.put(issue, :floor_priority, nil)

  defp floored_epic?(issue),
    do: Map.get(issue, :issue_type) == :epic and is_integer(Map.get(issue, :floor_priority))

  # `EpicFloor` reads the lifecycle `state`, which an Ash row may carry only
  # through `Lifecycle.state_of/1`.
  defp resolver_issue(issue) do
    %{
      id: issue.id,
      priority: Map.get(issue, :priority),
      issue_type: Map.get(issue, :issue_type),
      state: Lifecycle.state_of(issue),
      close_reason: Map.get(issue, :close_reason),
      floor_priority: Map.get(issue, :floor_priority)
    }
  end

  defp capped?(_issues, resolutions, _cap) when resolutions == %{}, do: false

  defp capped?(issues, resolutions, cap) do
    lifted_active =
      Enum.count(issues, fn issue ->
        Lifecycle.state_of(issue) == :active and
          match?(%{lifted?: true}, Map.get(resolutions, issue.id))
      end)

    lifted_active >= cap
  end
end
