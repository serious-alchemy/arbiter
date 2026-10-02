defmodule Arbiter.Tasks.BacklogTailDigestTest do
  @moduledoc """
  bd-b1b3mp (ES8): the daily coordinator digest of unblocked Backlog leaves
  older than 24h in epics that are in progress (or floored). Informational —
  nothing is promoted.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.BacklogTailDigest
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "digest-ws-#{n}", prefix: "dg#{n}"})
    {:ok, epic} = Ash.create(Issue, %{title: "an epic", workspace_id: ws.id, issue_type: :epic})
    {:ok, ws: ws, epic: epic}
  end

  defp child(ctx, title, as) do
    {:ok, issue} = Ash.create(Issue, %{title: title, workspace_id: ctx.ws.id, issue_type: :task})

    issue =
      case as do
        :backlog -> issue
        :closed -> Ash.update!(issue, %{}, action: :close)
      end

    {:ok, _} = Dependencies.add(ctx.epic.id, issue.id, :parent_of)
    issue
  end

  defp later, do: DateTime.add(DateTime.utc_now(), 25 * 3600, :second)

  defp digests(ws), do: Message.last_escalation(:backlog_tail_digest, workspace_id: ws.id)

  test "lists stale unblocked backlog leaves of an in-progress epic", ctx do
    child(ctx, "done", :closed)
    stale = child(ctx, "stale one", :backlog)

    assert [%{epic_id: epic_id, leaves: [leaf]}] = BacklogTailDigest.collect(now: later())
    assert epic_id == ctx.epic.id
    assert leaf.id == stale.id

    assert :ok = BacklogTailDigest.sweep(now: later())
    msg = digests(ctx.ws)
    assert msg.body =~ stale.id
    assert msg.body =~ ctx.epic.id
  end

  test "leaves younger than 24h are not listed and nothing is sent", ctx do
    child(ctx, "done", :closed)
    child(ctx, "fresh", :backlog)

    assert BacklogTailDigest.collect(now: DateTime.utc_now()) == []
    assert :ok = BacklogTailDigest.sweep(now: DateTime.utc_now())
    assert digests(ctx.ws) == nil
  end

  test "an epic that has not started (no floor, nothing done or running) is skipped", ctx do
    child(ctx, "stale", :backlog)

    assert BacklogTailDigest.collect(now: later()) == []
    assert :ok = BacklogTailDigest.sweep(now: later())
    assert digests(ctx.ws) == nil
  end

  test "a blocked backlog leaf is not listed", ctx do
    child(ctx, "done", :closed)
    held = child(ctx, "held", :backlog)
    {:ok, blocker} = Ash.create(Issue, %{title: "blocker", workspace_id: ctx.ws.id})
    {:ok, _} = Dependencies.add(held.id, blocker.id, :depends_on)

    assert BacklogTailDigest.collect(now: later()) == []
  end

  test "a second sweep inside 24h does not send a second digest", ctx do
    child(ctx, "done", :closed)
    child(ctx, "stale", :backlog)

    assert :ok = BacklogTailDigest.sweep(now: later())
    first = digests(ctx.ws)
    assert :ok = BacklogTailDigest.sweep(now: later())
    assert digests(ctx.ws).id == first.id
  end

  test "never promotes: the leaves are still in backlog after a sweep", ctx do
    child(ctx, "done", :closed)
    stale = child(ctx, "stale", :backlog)

    assert :ok = BacklogTailDigest.sweep(now: later())

    reloaded = Ash.get!(Issue, stale.id)
    assert Arbiter.Tasks.Lifecycle.state_of(reloaded) == :backlog
    assert reloaded.state == stale.state
  end
end
