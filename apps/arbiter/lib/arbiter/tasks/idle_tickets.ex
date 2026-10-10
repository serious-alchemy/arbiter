defmodule Arbiter.Tasks.IdleTickets do
  @moduledoc """
  The orphaned tickets: stored state `:active`, but nothing is working on them
  and nothing is queued to (bd-3fbj83).

  A restart or crash that loses an in-memory follow-up leaves a ticket In
  progress with no run. `Arbiter.Tasks.SlotGate` used to count it as a slot
  holder anyway, so it filled the provider cap until somebody resumed it by
  hand. `ids/2` names those tickets so callers can pass them to
  `SlotGate` as `idle_ids:`.

  A ticket is **not** idle when any of these holds:

    * a worker (author, reviewer or implementer round) is live for it;
    * it is queued in the scheduler (`:queued_ids`) or a dispatch/review is
      tracked for it;
    * it carries a durable follow-up marker in `review_gate_state`: a ReviewGate
      `pass` (including a held fix round), a `held_resume`, or a `ci_wait`;
    * it changed within `:grace_ms` (default 5 minutes) — a dispatch that is
      still starting its worker must not read as orphaned.

  Epics and tickets that are not `:active` are never reported.

  Options: `:workers` (live worker snapshots; default
  `Arbiter.Worker.list_children/0`), `:queued_ids`, `:now`, `:grace_ms`.
  """

  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Worker
  alias Arbiter.Worker.HeldResume
  alias Arbiter.Worker.ReviewCi
  alias Arbiter.Worker.ReviewPass

  @default_grace_ms :timer.minutes(5)

  @spec ids([map()], keyword()) :: [String.t()]
  def ids(tickets, opts \\ []) when is_list(tickets) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    grace_ms = Keyword.get(opts, :grace_ms, @default_grace_ms)
    queued = opts |> Keyword.get(:queued_ids, []) |> base_ids()
    workers = Keyword.get_lazy(opts, :workers, &list_workers/0)
    live = workers |> Enum.map(&Map.get(&1, :task_id)) |> base_ids()

    for ticket <- tickets, idle?(ticket, queued, live, now, grace_ms), do: ticket.id
  end

  defp idle?(ticket, queued, live, now, grace_ms) do
    Lifecycle.state_of(ticket) == :active and
      Map.get(ticket, :issue_type) not in Issue.non_dispatchable_types() and
      not MapSet.member?(queued, ticket.id) and not MapSet.member?(live, ticket.id) and
      is_nil(Worker.whereis(ticket.id)) and not marked?(ticket, now) and
      settled?(ticket, now, grace_ms)
  end

  defp marked?(ticket, now) do
    not is_nil(ReviewPass.stored(ticket)) or not is_nil(HeldResume.stored_kind(ticket)) or
      not is_nil(ReviewCi.waiting(ticket, now))
  end

  defp settled?(ticket, now, grace_ms) do
    case Map.get(ticket, :updated_at) do
      %DateTime{} = at -> DateTime.diff(now, at, :millisecond) > grace_ms
      _ -> false
    end
  end

  # A reviewer / implementer round's synthetic id is `<task>#review…`: it
  # keeps its author ticket's slot-holding claim alive.
  defp base_ids(ids) do
    for id <- ids, is_binary(id), into: MapSet.new() do
      id |> String.split("#", parts: 2) |> hd()
    end
  end

  defp list_workers do
    Worker.list_children()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end
end
