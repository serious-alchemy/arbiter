defmodule Arbiter.Tasks.EpicRollupTest do
  @moduledoc """
  bd-2wmxt5 — the per-status child aggregation behind `/epics`.

  bd-58z2tu replaced the three independent "stuck" signals with a single
  `needs_you` rule: an epic needs the operator when a child is parked in
  `awaiting_verification` (rule 1), a child's own live worker needs the
  operator per the board's shared `Snapshot.child_needs_you?/2` (rule 2), or
  a child is blocked only by something that itself needs the operator
  (rule 3). `blocked_children` / `idle_with_ready_work` stay as
  informational counts.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.EpicRollup
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    n = System.unique_integer([:positive])

    {:ok, ws} = Ash.create(Workspace, %{name: "epic-ws-#{n}", prefix: "epr#{n}"})

    {:ok, epic} =
      Ash.create(Issue, %{title: "an epic", workspace_id: ws.id, issue_type: :epic})

    {:ok, ws: ws, epic: epic}
  end

  defp child(ws, epic, title, opts) do
    {:ok, issue} =
      Ash.create(Issue, %{title: title, workspace_id: ws.id, issue_type: :task})

    issue =
      case Keyword.get(opts, :as) do
        :backlog -> issue
        :ready -> Ash.update!(issue, %{}, action: :promote_to_ready)
        :running -> Ash.update!(issue, %{status: :in_progress})
        # bd-842qio: only work in progress parks for verification.
        :waiting -> issue |> Ash.update!(%{status: :in_progress}) |> park()
        :closed -> Ash.update!(issue, %{}, action: :close)
      end

    {:ok, _} = Dependencies.add(epic.id, issue.id, :parent_of)
    issue
  end

  defp park(issue), do: Ash.update!(issue, %{}, action: :await_verification)

  # A worker snapshot in one of its run's states. `:question` and
  # `:review_gate` are a `:waiting` run and what it waits on; `:failed` is a
  # finished run's outcome.
  defp worker(task_id, state, attrs \\ %{}) do
    %{task_id: task_id, meta: %{}}
    |> Map.merge(run_fields(state))
    |> Map.merge(attrs)
  end

  defp run_fields(:question), do: %{state: :waiting, waiting_on: :question, outcome: nil}
  defp run_fields(:review_gate), do: %{state: :waiting, waiting_on: :review_gate, outcome: nil}
  defp run_fields(:failed), do: %{state: :finished, waiting_on: nil, outcome: :failed}
  defp run_fields(state), do: %{state: state, waiting_on: nil, outcome: nil}

  defp rollup(epic, opts \\ []), do: Map.fetch!(EpicRollup.for_epics([epic], opts), epic.id)

  describe "per-status child counts" do
    test "buckets children into backlog/ready/running/waiting/closed", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)
      child(ctx.ws, ctx.epic, "b2", as: :backlog)
      child(ctx.ws, ctx.epic, "r1", as: :ready)
      child(ctx.ws, ctx.epic, "run1", as: :running)
      child(ctx.ws, ctx.epic, "w1", as: :waiting)
      child(ctx.ws, ctx.epic, "c1", as: :closed)
      child(ctx.ws, ctx.epic, "c2", as: :closed)

      r = rollup(ctx.epic)

      assert r.counts == %{backlog: 2, ready: 1, running: 1, waiting: 1, closed: 2}
      assert r.total == 7
      assert r.closed == 2
    end

    test "an epic with no children rolls up to all zeroes", ctx do
      r = rollup(ctx.epic)

      assert r.counts == %{backlog: 0, ready: 0, running: 0, waiting: 0, closed: 0}
      assert r.total == 0
      assert r.closed == 0
      assert r.percent_complete == 0
      refute r.needs_you
      assert r.needs_you_reasons == []
    end

    test "percent_complete is closed over total", ctx do
      child(ctx.ws, ctx.epic, "c1", as: :closed)
      child(ctx.ws, ctx.epic, "c2", as: :closed)
      child(ctx.ws, ctx.epic, "b1", as: :backlog)
      child(ctx.ws, ctx.epic, "b2", as: :backlog)

      assert rollup(ctx.epic).percent_complete == 50
    end

    test "only :parent_of children count, not other edge types", ctx do
      {:ok, related} = Ash.create(Issue, %{title: "related", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(ctx.epic.id, related.id, :relates_to)

      assert rollup(ctx.epic).total == 0
    end
  end

  describe "blocked_children and idle_with_ready_work (informational only)" do
    test "a child blocked by an open gating edge counts, but does not alone flag needs_you",
         ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, blocker} =
        Ash.create(Issue, %{
          title: "the blocker",
          workspace_id: ctx.ws.id,
          issue_type: :task,
          acceptance: "n/a"
        })

      Ash.update!(blocker, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.blocked_children == 1
      refute r.needs_you
    end

    test "a closed blocker no longer counts as blocking", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "the blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)
      Ash.update!(blocker, %{}, action: :close)

      r = rollup(ctx.epic)

      assert r.blocked_children == 0
    end

    test "an inbound :blocks edge blocks the child too", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, blocker} =
        Ash.create(Issue, %{
          title: "the blocker",
          workspace_id: ctx.ws.id,
          issue_type: :task,
          acceptance: "n/a"
        })

      Ash.update!(blocker, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocker.id, blocked.id, :blocks)

      assert rollup(ctx.epic).blocked_children == 1
    end

    test "zero running children with a Ready child counts as idle, but does not flag needs_you",
         ctx do
      child(ctx.ws, ctx.epic, "r1", as: :ready)

      r = rollup(ctx.epic)

      assert r.idle_with_ready_work
      refute r.needs_you
    end

    test "no Ready children means no idle signal, however quiet the epic is", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)

      r = rollup(ctx.epic)

      refute r.idle_with_ready_work
      refute r.needs_you
    end
  end

  describe "needs_you rule 1: a child awaiting verification" do
    test "flags needs_you with a verify reason naming the child", ctx do
      w1 = child(ctx.ws, ctx.epic, "w1", as: :waiting)
      child(ctx.ws, ctx.epic, "r1", as: :ready)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert r.awaiting_verification == 1
      assert "verify #{w1.id}" in r.needs_you_reasons
    end
  end

  describe "needs_you rule 2: a child's own worker needs the operator" do
    test "a live worker waiting on a question flags needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "asking-child", as: :running)
      w = worker(c.id, :question, %{meta: %{await_reason: "which?"}})

      r = rollup(ctx.epic, workers: [w])

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "a run finished :failed (parked) flags needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "failed-child", as: :running)
      w = worker(c.id, :failed, %{meta: %{stop_reason: %{summary: "review rejected"}}})

      r = rollup(ctx.epic, workers: [w])

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "an in_progress child with no live worker at all flags needs_you past the dispatch grace window",
         ctx do
      c = child(ctx.ws, ctx.epic, "orphaned-child", as: :running)
      later = DateTime.add(DateTime.utc_now(), 120, :second)

      r = rollup(ctx.epic, workers: [], now: later)

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "an in_progress child with no live worker does not flag needs_you inside the dispatch grace window",
         ctx do
      child(ctx.ws, ctx.epic, "dispatching-child", as: :running)

      r = rollup(ctx.epic, workers: [])

      refute r.needs_you
    end

    test "an in_progress :epic child never flags needs_you, however long it sits with no worker",
         ctx do
      {:ok, nested_epic} =
        Ash.create(Issue, %{title: "nested epic", workspace_id: ctx.ws.id, issue_type: :epic})

      nested_epic = Ash.update!(nested_epic, %{status: :in_progress})
      {:ok, _} = Dependencies.add(ctx.epic.id, nested_epic.id, :parent_of)

      later = DateTime.add(DateTime.utc_now(), 120, :second)

      r = rollup(ctx.epic, workers: [], now: later)

      refute r.needs_you
    end

    # bd-741sid: an open MR is a Merging child's, its last poll on its row.
    test "an approved MR blocked on something the Watchdog can't clear flags needs_you", ctx do
      c =
        merging_child(ctx, "blocked-mr-child", %{
          status: :open,
          approved: true,
          block_reason: :needs_approval
        })

      r = rollup(ctx.epic, workers: [], watchdog_live: MapSet.new([c.id]))

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "an approved MR blocked on an auto-resolvable reason does not flag needs_you", ctx do
      c =
        merging_child(ctx, "auto-resolvable-child", %{
          status: :open,
          approved: true,
          block_reason: :ci_failed
        })

      r = rollup(ctx.epic, workers: [], watchdog_live: MapSet.new([c.id]))

      refute r.needs_you
    end

    test "a running child with a live author worker does not flag needs_you", ctx do
      c = child(ctx.ws, ctx.epic, "running-child", as: :running)
      w = worker(c.id, :working)

      r = rollup(ctx.epic, workers: [w])

      refute r.needs_you
    end

    test "an in-review child (its author waiting on the review gate) does not flag needs_you",
         ctx do
      c = child(ctx.ws, ctx.epic, "reviewing-child", as: :running)
      w = worker(c.id, :review_gate)

      r = rollup(ctx.epic, workers: [w], watchdog_live: MapSet.new([c.id]))

      refute r.needs_you
    end

    test "agrees with the board's own needs_you flag for the same worker fixture", ctx do
      c = child(ctx.ws, ctx.epic, "shared-predicate-child", as: :running)

      w = worker(c.id, :question, %{meta: %{await_reason: "which?"}})

      watchdog_live = MapSet.new([c.id])

      epic_r = rollup(ctx.epic, workers: [w], watchdog_live: watchdog_live)

      board =
        Snapshot.derive(%{
          issues: [c],
          workers: [w],
          blocked_by: %{},
          changed_files: %{},
          now: DateTime.utc_now(),
          slots_total: 4,
          quota: :ok,
          paused: false,
          watchdog_live: watchdog_live
        })

      [card] = board.waiting

      assert card.needs_you == true
      assert epic_r.needs_you == card.needs_you
    end
  end

  # bd-741sid: a Merging child has no worker — its implementer stopped when the
  # PR opened — so the ticket's own row and its Watchdog decide, exactly as on
  # the board's merge card.
  describe "a Merging child" do
    defp merging_child(ctx, title, merger_status) do
      c = child(ctx.ws, ctx.epic, title, as: :running)
      {:ok, _} = Issue.pr_opened(c.id, "!#{System.unique_integer([:positive])}")
      :ok = Arbiter.Tasks.PullRequest.record_merger_status(c.id, merger_status)
      Ash.get!(Issue, c.id)
    end

    test "with a live Watchdog and nothing it cannot clear, does not flag", ctx do
      c = merging_child(ctx, "merging-child", %{status: :open, approved: false})

      refute rollup(ctx.epic, workers: [], watchdog_live: MapSet.new([c.id])).needs_you
    end

    test "whose Watchdog is gone flags", ctx do
      c = merging_child(ctx, "unwatched-child", %{status: :open, approved: false})

      r = rollup(ctx.epic, workers: [], watchdog_live: MapSet.new())

      assert r.needs_you
      assert "#{c.id} parked" in r.needs_you_reasons
    end

    test "agrees with the board's merge card", ctx do
      c =
        merging_child(ctx, "blocked-child", %{
          status: :open,
          approved: true,
          block_reason: :needs_approval
        })

      watchdog_live = MapSet.new([c.id])
      epic_r = rollup(ctx.epic, workers: [], watchdog_live: watchdog_live)

      board =
        Snapshot.derive(%{
          issues: [c],
          workers: [],
          blocked_by: %{},
          changed_files: %{},
          now: DateTime.utc_now(),
          slots_total: 4,
          quota: :ok,
          paused: false,
          watchdog_live: watchdog_live
        })

      assert [%{status: :merging, needs_you: true}] = board.waiting
      assert epic_r.needs_you
    end
  end

  describe "needs_you rule 3: blocked only by something that itself needs the operator" do
    test "blocked by an unrefined (Backlog) blocker flags needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "unrefined blocker", workspace_id: ctx.ws.id})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert "blocked by unrefined #{blocker.id}" in r.needs_you_reasons
    end

    # bd-6zapbl: verifying unblocks dependents, so a verifying blocker outside
    # the epic is not blocking the child at all, let alone a needs-you cause.
    test "a verifying blocker is not a needs-you cause — it no longer blocks", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "waiting blocker", workspace_id: ctx.ws.id})
      blocker = blocker |> Ash.update!(%{status: :in_progress}) |> park()
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      r = rollup(ctx.epic)

      refute r.needs_you
      assert r.needs_you_reasons == []
      assert r.blocked_children == 0
      assert [%{blocked?: false}] = EpicRollup.children_with_status(ctx.epic)
    end

    test "blocked by a parked (needs-you) blocker flags needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "parked blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{status: :in_progress})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      w = worker(blocker.id, :failed, %{meta: %{stop_reason: %{summary: "gave up"}}})

      r = rollup(ctx.epic, workers: [w])

      assert r.needs_you
      assert "blocked by #{blocker.id} (parked)" in r.needs_you_reasons
    end

    test "a blocker outside the epic still counts", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, other_epic} =
        Ash.create(Issue, %{title: "other epic", workspace_id: ctx.ws.id, issue_type: :epic})

      outside_blocker = child(ctx.ws, other_epic, "outside-blocker", as: :backlog)
      {:ok, _} = Dependencies.add(blocked.id, outside_blocker.id, :depends_on)

      r = rollup(ctx.epic)

      assert r.needs_you
      assert "blocked by unrefined #{outside_blocker.id}" in r.needs_you_reasons
    end

    test "blocked by a Ready blocker does not flag needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)

      {:ok, blocker} =
        Ash.create(Issue, %{
          title: "ready blocker",
          workspace_id: ctx.ws.id,
          issue_type: :task,
          acceptance: "n/a"
        })

      Ash.update!(blocker, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      refute rollup(ctx.epic).needs_you
    end

    test "blocked by a running blocker with a live worker does not flag needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "running blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{status: :in_progress})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      w = worker(blocker.id, :working)

      refute rollup(ctx.epic, workers: [w]).needs_you
    end

    test "blocked by a blocker mid-review does not flag needs_you", ctx do
      blocked = child(ctx.ws, ctx.epic, "blocked-child", as: :ready)
      {:ok, blocker} = Ash.create(Issue, %{title: "reviewing blocker", workspace_id: ctx.ws.id})
      blocker = Ash.update!(blocker, %{status: :in_progress})
      {:ok, _} = Dependencies.add(blocked.id, blocker.id, :depends_on)

      w = worker(blocker.id, :review_gate)

      refute rollup(ctx.epic, workers: [w], watchdog_live: MapSet.new([blocker.id])).needs_you
    end
  end

  describe "last_child_activity_at" do
    test "is the newest child updated_at", ctx do
      child(ctx.ws, ctx.epic, "b1", as: :backlog)
      newest = child(ctx.ws, ctx.epic, "b2", as: :closed)

      r = rollup(ctx.epic)

      assert r.last_child_activity_at
      assert DateTime.compare(r.last_child_activity_at, newest.updated_at) != :lt
    end

    test "is nil for a childless epic", ctx do
      assert rollup(ctx.epic).last_child_activity_at == nil
    end
  end

  describe "open_epic_count/0" do
    test "counts non-closed epics only", ctx do
      {:ok, second} =
        Ash.create(Issue, %{title: "second epic", workspace_id: ctx.ws.id, issue_type: :epic})

      {:ok, third} =
        Ash.create(Issue, %{title: "third epic", workspace_id: ctx.ws.id, issue_type: :epic})

      {:ok, _plain} = Ash.create(Issue, %{title: "not an epic", workspace_id: ctx.ws.id})

      before = Tasks.open_epic_count()
      Ash.update!(third, %{}, action: :close)

      assert Tasks.open_epic_count() == before - 1
      assert second.status == :open
    end
  end

  test "rolls up several epics in one call", ctx do
    {:ok, other} =
      Ash.create(Issue, %{title: "other epic", workspace_id: ctx.ws.id, issue_type: :epic})

    child(ctx.ws, ctx.epic, "a1", as: :closed)
    child(ctx.ws, other, "b1", as: :ready)

    rollups = Tasks.epic_rollups([ctx.epic, other])

    assert rollups[ctx.epic.id].counts.closed == 1
    assert rollups[other.id].counts.ready == 1
  end
end
