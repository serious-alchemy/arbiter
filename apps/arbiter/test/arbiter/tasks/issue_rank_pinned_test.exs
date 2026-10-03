defmodule Arbiter.Tasks.IssueRankPinnedTest do
  @moduledoc """
  ES6 (`docs/design/epic-aware-scheduling.md` §4, §6.3): `rank_pinned` is set by
  a board drag (`Rank.move/2` with `pin: true`) and cleared by every transition
  that makes the old manual position meaningless — promote, demote, close and
  reopen. One test per transition.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.{Issue, Rank, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rp-#{System.unique_integer([:positive])}", prefix: "rp"})

    {:ok, ws: ws}
  end

  defp ticket(ws) do
    {:ok, issue} =
      Ash.create(Issue, %{title: "t", workspace_id: ws.id, acceptance: "- it works"})

    issue
  end

  defp ready(ws) do
    {:ok, issue} = Ash.update(ticket(ws), %{}, action: :promote)
    issue
  end

  defp pinned!(issue) do
    {:ok, pinned} = Rank.move(issue, %{position: :top, pin: true})
    assert pinned.rank_pinned
    pinned
  end

  test "a new ticket is not pinned", %{ws: ws} do
    refute ticket(ws).rank_pinned
  end

  test "a rank move that does not ask to pin leaves the pin alone", %{ws: ws} do
    {:ok, moved} = Rank.move(ready(ws), %{position: :bottom})
    refute moved.rank_pinned

    {:ok, moved} = Rank.move(pinned!(moved), %{position: :bottom})
    assert moved.rank_pinned
  end

  test "a drag (pin: true) sets rank_pinned and rewrites rank", %{ws: ws} do
    a = ready(ws)
    b = ready(ws)

    {:ok, dragged} = Rank.move(b, %{before_id: a.id, pin: true})

    assert dragged.rank_pinned
    assert dragged.rank < a.rank
    refute Ash.get!(Issue, a.id).rank_pinned
  end

  test "set_rank_pinned pins and unpins without touching rank", %{ws: ws} do
    a = ready(ws)

    {:ok, pinned} = Ash.update(a, %{pinned: true}, action: :set_rank_pinned)
    assert pinned.rank_pinned
    assert pinned.rank == a.rank

    {:ok, unpinned} = Ash.update(pinned, %{pinned: false}, action: :set_rank_pinned)
    refute unpinned.rank_pinned
  end

  test "promote clears the pin", %{ws: ws} do
    backlog = pinned!(ticket(ws))

    {:ok, promoted} = Ash.update(backlog, %{}, action: :promote)

    assert promoted.state == :queued
    refute promoted.rank_pinned
  end

  test "promote_to_ready clears the pin", %{ws: ws} do
    backlog = pinned!(ticket(ws))

    {:ok, promoted} = Ash.update(backlog, %{}, action: :promote_to_ready)

    refute promoted.rank_pinned
  end

  test "an idempotent re-promote leaves the pin alone", %{ws: ws} do
    queued = pinned!(ready(ws))

    {:ok, again} = Ash.update(queued, %{}, action: :promote_to_ready)

    assert again.rank_pinned
  end

  test "demote clears the pin", %{ws: ws} do
    queued = pinned!(ready(ws))

    {:ok, demoted} = Ash.update(queued, %{}, action: :demote)

    assert demoted.state == :backlog
    refute demoted.rank_pinned
  end

  test "return_to_backlog clears the pin", %{ws: ws} do
    queued = pinned!(ready(ws))

    {:ok, demoted} = Ash.update(queued, %{}, action: :return_to_backlog)

    refute demoted.rank_pinned
  end

  test "close clears the pin", %{ws: ws} do
    queued = pinned!(ready(ws))

    {:ok, closed} = Ash.update(queued, %{reason: "completed"}, action: :close)

    assert closed.state == :closed
    refute closed.rank_pinned
  end

  test "reopen clears the pin", %{ws: ws} do
    {:ok, closed} = Ash.update(ready(ws), %{}, action: :close)
    # A pin on a closed row can only come from a stale write; reopen must
    # still leave the ticket unpinned.
    {:ok, closed} = Ash.update(closed, %{pinned: true}, action: :set_rank_pinned)
    assert closed.rank_pinned

    {:ok, reopened} = Ash.update(closed, %{}, action: :reopen)

    assert reopened.state == :queued
    refute reopened.rank_pinned
  end

  test "a transition that keeps the card in its column keeps the pin", %{ws: ws} do
    queued = pinned!(ready(ws))

    {:ok, started} = Ash.update(queued, %{}, action: :start)

    assert started.rank_pinned
  end
end
