defmodule Arbiter.Board.ReadySince do
  @moduledoc """
  When each queued ticket became Ready (`docs/design/epic-aware-scheduling.md`
  §4 "Aged"): `max(the last ticket_transitions row with to_state = queued, the
  latest moment a gating blocker was satisfied)`.

  A blocker is satisfied once it is `:verifying` or `:closed`
  (`Arbiter.Tasks.Lifecycle.blocker_satisfied?/1`), so its time is `closed_at`,
  else `awaiting_verification_at`. The finish-first tiebreak's aging escape
  reads this; nothing else does, so `Arbiter.Board.Snapshot.load/1` only
  calls `load/3` when finish-first is on.

  `compute/3` is the pure half; `load/3` adds the one indexed
  `ticket_transitions` read (`[:ticket_id, :at]`), chunked.
  """

  require Ash.Query

  alias Arbiter.Tasks.DependencyGraph
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.TicketTransition

  @chunk 500

  @doc "Ready-since per `:queued` ticket in `issues`, read from `ticket_transitions`. Never raises."
  @spec load([map()], [map()], [map()]) :: %{optional(String.t()) => DateTime.t()}
  def load(issues, ref_issues, deps) do
    ids = for i <- issues, Lifecycle.state_of(i) == :queued, do: i.id

    ids
    |> queued_at()
    |> compute(Enum.flat_map(deps, &DependencyGraph.normalize_gating/1), issues ++ ref_issues)
  rescue
    _ -> %{}
  end

  @doc """
  `queued_at` is `%{id => last time it entered :queued}`; `edges` are
  `{dependent, dependency}` gating pairs; `issues` carry the blockers' times.
  """
  @spec compute(%{optional(String.t()) => DateTime.t()}, [{String.t(), String.t()}], [map()]) ::
          %{optional(String.t()) => DateTime.t()}
  def compute(queued_at, edges, issues) do
    by_id = Map.new(issues, &{&1.id, &1})

    blocker_at =
      edges
      |> Enum.filter(fn {dependent, _} -> Map.has_key?(queued_at, dependent) end)
      |> Enum.flat_map(fn {dependent, blocker} ->
        case satisfied_at(Map.get(by_id, blocker)) do
          nil -> []
          at -> [{dependent, at}]
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(queued_at, fn {id, at} ->
      {id, Enum.max([at | Map.get(blocker_at, id, [])], DateTime)}
    end)
  end

  defp satisfied_at(nil), do: nil

  defp satisfied_at(blocker),
    do: Map.get(blocker, :closed_at) || Map.get(blocker, :awaiting_verification_at)

  defp queued_at(ids) do
    ids
    |> Enum.chunk_every(@chunk)
    |> Enum.flat_map(fn chunk ->
      TicketTransition
      |> Ash.Query.select([:ticket_id, :at])
      |> Ash.Query.filter(ticket_id in ^chunk and to_state == :queued)
      |> Ash.read!()
    end)
    |> Enum.group_by(& &1.ticket_id, & &1.at)
    |> Map.new(fn {id, ats} -> {id, Enum.max(ats, DateTime)} end)
  end
end
