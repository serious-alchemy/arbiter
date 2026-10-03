defmodule Arbiter.Tasks.EffectivePriority do
  @moduledoc """
  A ticket's effective priority on every surface that is not the board
  (`docs/design/epic-aware-scheduling.md` §6.3, §9; ticket ES4).

  The board resolves it once per pass inside `Arbiter.Board.Snapshot`. The read
  surfaces — `ticket_show`, `GET /api/issues/:id`, `GET /api/issues/ready`,
  `GET /api/issues/lifecycle` (and so `arb ready` / `arb prime` and the
  `ticket_ready` MCP tool) and the DispatchQueue — go through here, so they
  resolve through `Arbiter.Tasks.EpicFloor` with the same floors, kill switch
  and lift cap the board uses (`Arbiter.Board.Snapshot.order_context/1`).

    * `fields/1` — `effective_priority`, `priority_via` and `priority_lift`
      (`"applied" | "capped" | nil`). `priority` itself stays the own priority.
    * `effective/1` — the number the DispatchQueue orders held intents by.
    * `order/1` — a list of tickets in the §4 key (`Arbiter.Board.Scheduler.order/1`).

  With no floor on any epic (and, for `order/1`, finish-first off) nothing is
  resolved: `fields/1` reads the own priority, `order/1` is exactly
  `Scheduler.order/1` on the bare tickets — `{priority, rank, created_at}`. One
  `floor_priority IS NOT NULL` existence check is the whole cost of that case.
  Every read is best-effort: an unreadable board degrades to own priority, never
  a raise.
  """

  require Ash.Query

  alias Arbiter.Board.QueueOrder
  alias Arbiter.Board.Scheduler
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Issue

  @type fields :: %{
          effective_priority: integer() | nil,
          priority_via: String.t() | nil,
          priority_lift: String.t() | nil
        }

  # P2 is what an unreadable ticket has always been queued as.
  @default_priority 2

  @doc "The three ES4 fields for `issue`. See the moduledoc."
  @spec fields(map() | nil, keyword()) :: fields()
  def fields(issue, opts \\ [])

  def fields(%{id: _, priority: own} = issue, opts) do
    case floor_context(opts) do
      nil ->
        own_fields(own)

      ctx ->
        resolved = QueueOrder.annotate(card(issue), ctx)

        %{
          effective_priority: resolved.effective_priority,
          priority_via: resolved.priority_via,
          priority_lift: lift_name(resolved.priority_lift)
        }
    end
  rescue
    _ -> own_fields(own)
  end

  def fields(_issue, _opts), do: own_fields(nil)

  @doc "The effective priority `issue` is queued by; P2 when it can't be read."
  @spec effective(map() | nil) :: integer()
  def effective(issue) do
    case fields(issue) do
      %{effective_priority: p} when is_integer(p) -> p
      _ -> @default_priority
    end
  end

  @doc """
  `issues` in the §4 order. `Scheduler.order/1` is stable, so tickets that tie
  on the whole key keep the order they came in.
  """
  @spec order([map()], keyword()) :: [map()]
  def order(issues, opts \\ []) when is_list(issues) do
    case order_context(opts) do
      nil ->
        Scheduler.order(issues)

      ctx ->
        issues
        |> Enum.map(&Map.put(QueueOrder.annotate(card(&1), ctx), :issue, &1))
        |> Scheduler.order()
        |> Enum.map(& &1.issue)
    end
  rescue
    _ -> Scheduler.order(issues)
  end

  # Floors only: `fields/1` doesn't read the finish-first class.
  defp floor_context(opts) do
    settings = settings(opts)
    if floors?(settings), do: build(settings, opts)
  end

  defp order_context(opts) do
    settings = settings(opts)
    if settings.finish_first or floors?(settings), do: build(settings, opts)
  end

  defp build(settings, opts), do: Snapshot.order_context(Keyword.put(opts, :scheduling, settings))

  defp settings(opts),
    do: QueueOrder.settings(Keyword.get_lazy(opts, :scheduling, &Arbiter.Settings.scheduling/0))

  # A floor only counts when the kill switch is on, and only an epic carries one.
  defp floors?(%{epic_floors_enabled: false}), do: false

  defp floors?(_settings) do
    Issue
    |> Ash.Query.filter(issue_type == :epic and not is_nil(floor_priority))
    |> Ash.exists?()
  rescue
    _ -> false
  end

  defp card(issue) do
    %{
      id: issue.id,
      priority: issue.priority,
      rank: Map.get(issue, :rank),
      rank_pinned: Map.get(issue, :rank_pinned),
      created_at: Map.get(issue, :created_at)
    }
  end

  defp own_fields(own), do: %{effective_priority: own, priority_via: nil, priority_lift: nil}

  defp lift_name(nil), do: nil
  defp lift_name(lift) when is_atom(lift), do: Atom.to_string(lift)
end
