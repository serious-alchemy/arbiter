defmodule Arbiter.Board.SnapshotLoadTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Dependencies
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "snapshot-test-#{System.unique_integer([:positive])}",
        prefix: "snp#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  describe "slots_total respects workspace-level max_concurrent" do
    test "uses workspace max when it's lower than system max", %{ws: ws} do
      # Set workspace max_concurrent to 2
      {:ok, ws} =
        Ash.update(ws, %{
          config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => 2})
        })

      # Set system max to a higher value
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(4)

      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      end)

      # Load snapshot for this workspace
      snapshot = Snapshot.load(workspace_id: ws.id)

      # Should use the lower value (2)
      assert snapshot.slots_total == 2
    end

    test "uses system max when workspace max is not set", %{ws: ws} do
      # Don't set workspace max_concurrent
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(6)

      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      end)

      snapshot = Snapshot.load(workspace_id: ws.id)

      assert snapshot.slots_total == 6
    end

    test "uses workspace max when it's lower (system default)", %{ws: ws} do
      # Set workspace max_concurrent to 1
      {:ok, ws} =
        Ash.update(ws, %{
          config: Map.put(ws.config || %{}, "conductor", %{"max_concurrent" => 1})
        })

      # Don't override system max, use default
      snapshot = Snapshot.load(workspace_id: ws.id)

      # Should use the workspace limit (1) which is lower than system default (16)
      assert snapshot.slots_total == 1
    end

    test "no regression: uses system max when no workspace_id is passed" do
      # Set system max to a specific value
      {:ok, _} = Arbiter.Settings.set_conductor_system_max_concurrent(5)

      on_exit(fn ->
        Arbiter.Settings.set_conductor_system_max_concurrent(nil)
      end)

      # Load snapshot without workspace_id (existing behavior)
      snapshot = Snapshot.load()

      # Should use the system max (5)
      assert snapshot.slots_total == 5
    end
  end

  # bd-38of5i: `derive/1` takes the `parent_of` pairs as an input; `load/1` is
  # the half that has to go and read them. Without this the board would render
  # a chip-less card for every child on a live install while the pure tests
  # stayed green.
  describe "parent refs are read from the dependency rows" do
    test "a child issue's card carries its parent's ref", %{ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "Parent epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "A child", workspace_id: ws.id})

      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)

      snapshot = Snapshot.load(workspace_id: ws.id)
      card = Enum.find(snapshot.backlog, &(&1.id == child.id))

      assert %{parent: %{id: parent_id, title: "Parent epic", issue_type: :epic}} = card
      assert parent_id == epic.id
      assert card.parent.child_total == 1
      assert card.parent.child_closed == 0
    end

    test "a closed epic does not reach the Closed column, but its child does", %{ws: ws} do
      {:ok, epic} =
        Ash.create(Issue, %{title: "Done epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, child} = Ash.create(Issue, %{title: "Done child", workspace_id: ws.id})

      {:ok, _} = Dependencies.add(epic.id, child.id, :parent_of)
      {:ok, _} = Ash.update(child, %{close_upstream: false}, action: :close)
      {:ok, _} = Ash.update(epic, %{close_upstream: false}, action: :close)

      snapshot = Snapshot.load(workspace_id: ws.id)
      closed_ids = Enum.map(snapshot.closed_today, & &1.id)

      assert child.id in closed_ids
      refute epic.id in closed_ids
    end
  end

  # bd-8j9i9p (design bd-9jj5lf §3): `load/1` is where the ledger question is
  # actually asked. `derive/1`'s own tests cover the flag's shape; these cover
  # that the real read reaches the right answer.
  describe "over-budget attention flag is read from the ledger" do
    setup %{ws: ws} do
      # n=10 closed D2 features costing $1..$10 → p75 $8, p90 $9.
      Enum.each(1..10, fn n ->
        {:ok, issue} =
          Ash.create(Issue, %{
            title: "history #{n}",
            workspace_id: ws.id,
            difficulty: 2,
            issue_type: :feature
          })

        {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
        spend!(closed.id, n * 1.0, ws)
      end)

      :ok
    end

    test "an open issue past its group's p90 flags on the board", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "runaway",
          workspace_id: ws.id,
          difficulty: 2,
          issue_type: :feature
        })

      spend!(task.id, 40.0, ws)

      snapshot = Snapshot.load(workspace_id: ws.id)
      card = Enum.find(snapshot.backlog, &(&1.id == task.id))

      assert card.over_budget
    end

    test "a closed issue that ran over does not flag", %{ws: ws} do
      {:ok, task} =
        Ash.create(Issue, %{
          title: "ran over, then landed",
          workspace_id: ws.id,
          difficulty: 2,
          issue_type: :feature
        })

      spend!(task.id, 40.0, ws)
      {:ok, closed} = Ash.update(task, %{close_upstream: false}, action: :close)

      snapshot = Snapshot.load(workspace_id: ws.id)
      card = Enum.find(snapshot.closed_today, &(&1.id == closed.id))

      assert card
      refute card.over_budget
    end
  end

  describe "agents_live through load/1 (bd-aw2cyt)" do
    test "counts live agents, so a record with no agent adds nothing", %{ws: ws} do
      board =
        Snapshot.load(workspace_id: ws.id, issues: [], workers: [stale_author(ws)], deps: [])

      assert board.agents_live == 0
    end
  end

  # An author record whose run is still live but whose agent has exited.
  defp stale_author(ws) do
    %{
      task_id: "bd-stale",
      registry_key: "bd-stale",
      state: :working,
      role: nil,
      workspace_id: ws.id,
      current_step: :implement,
      started_at: DateTime.utc_now(),
      step_started_at: DateTime.utc_now(),
      mr_ref: nil,
      merger_url: nil,
      agent_live: false,
      meta: %{}
    }
  end

  describe "slim snapshot loading (bd-3d1zge)" do
    test "skips issues closed longer ago than 24h", %{ws: ws} do
      now = DateTime.utc_now()
      old_time = DateTime.add(now, -48, :hour)
      recent_time = DateTime.add(now, -2, :hour)

      {:ok, old_issue} = Ash.create(Issue, %{title: "Old closed issue", workspace_id: ws.id})
      {:ok, _} = Ash.update(old_issue, %{close_upstream: false}, action: :close)

      import Ecto.Query

      from(i in "issues", where: i.id == ^old_issue.id)
      |> Arbiter.Repo.update_all(set: [closed_at: old_time, updated_at: old_time])

      {:ok, recent_issue} =
        Ash.create(Issue, %{title: "Recent closed issue", workspace_id: ws.id})

      {:ok, _} = Ash.update(recent_issue, %{close_upstream: false}, action: :close)

      from(i in "issues", where: i.id == ^recent_issue.id)
      |> Arbiter.Repo.update_all(set: [closed_at: recent_time, updated_at: recent_time])

      # Verify load_issues query filters out old closed issues at the DB level
      loaded_issues = Snapshot.load_issues(now)
      loaded_ids = Enum.map(loaded_issues, & &1.id)
      assert recent_issue.id in loaded_ids
      refute old_issue.id in loaded_ids

      # Verify unselected heavy fields are not loaded
      sample = Enum.find(loaded_issues, &(&1.id == recent_issue.id))
      assert match?(%Ash.NotLoaded{}, sample.pr_body)
      assert match?(%Ash.NotLoaded{}, sample.posted_findings)

      snapshot = Snapshot.load(workspace_id: ws.id, now: now)

      closed_ids = Enum.map(snapshot.closed_today, & &1.id)
      assert recent_issue.id in closed_ids
      refute old_issue.id in closed_ids
    end

    test "another workspace's blocked ticket stays blocked without :workspace_id", %{ws: ws} do
      {:ok, other_ws} =
        Ash.create(Workspace, %{
          name: "other-ws-#{System.unique_integer([:positive])}",
          prefix: "oth#{System.unique_integer([:positive])}"
        })

      {:ok, ws_task1} =
        Ash.create(Issue, %{title: "WS task 1", workspace_id: ws.id, acceptance: "- crit"})

      {:ok, ws_task2} =
        Ash.create(Issue, %{title: "WS task 2", workspace_id: ws.id, acceptance: "- crit"})

      {:ok, ws_task2} = Ash.update(ws_task2, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(ws_task1.id, ws_task2.id, :blocks)

      {:ok, other_task1} =
        Ash.create(Issue, %{title: "Other 1", workspace_id: other_ws.id, acceptance: "- crit"})

      {:ok, other_task2} =
        Ash.create(Issue, %{title: "Other 2", workspace_id: other_ws.id, acceptance: "- crit"})

      {:ok, other_task2} = Ash.update(other_task2, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(other_task1.id, other_task2.id, :blocks)

      for opts <- [[], [workspace_id: ws.id]] do
        snapshot = Snapshot.load(opts)

        for {blocked, blocker} <- [{ws_task2, ws_task1}, {other_task2, other_task1}] do
          card = Enum.find(snapshot.blocked, &(&1.id == blocked.id))
          assert card, "#{blocked.title} should be blocked with opts #{inspect(opts)}"
          assert blocker.id in card.blocked_by
        end
      end
    end

    test "a blocker closed long ago still satisfies; long-closed children/epics still count",
         %{ws: ws} do
      now = DateTime.utc_now()
      old = DateTime.add(now, -48, :hour)

      {:ok, blocker} = Ash.create(Issue, %{title: "Old blocker", workspace_id: ws.id})

      {:ok, blocked} =
        Ash.create(Issue, %{title: "Waiting", workspace_id: ws.id, acceptance: "- c"})

      {:ok, blocked} = Ash.update(blocked, %{}, action: :promote_to_ready)
      {:ok, _} = Dependencies.add(blocker.id, blocked.id, :blocks)

      {:ok, epic} =
        Ash.create(Issue, %{title: "Old epic", workspace_id: ws.id, issue_type: :epic})

      {:ok, done_child} = Ash.create(Issue, %{title: "Old child", workspace_id: ws.id})
      {:ok, open_child} = Ash.create(Issue, %{title: "Open child", workspace_id: ws.id})
      {:ok, _} = Dependencies.add(epic.id, done_child.id, :parent_of)
      {:ok, _} = Dependencies.add(epic.id, open_child.id, :parent_of)

      for i <- [blocker, done_child, epic] do
        {:ok, _} = Ash.update(i, %{close_upstream: false}, action: :close)
      end

      import Ecto.Query

      from(i in "issues", where: i.id in ^[blocker.id, done_child.id, epic.id])
      |> Arbiter.Repo.update_all(set: [closed_at: old, updated_at: old])

      loaded_ids = Enum.map(Snapshot.load_issues(now), & &1.id)
      refute blocker.id in loaded_ids

      snapshot = Snapshot.load(now: now)

      refute Enum.any?(snapshot.blocked, &(&1.id == blocked.id))

      card = Enum.find(snapshot.backlog, &(&1.id == open_child.id))
      assert %{parent: %{id: epic_id, child_total: 2, child_closed: 1}} = card
      assert epic_id == epic.id
    end

    test "derive/1 produces identical output with full issue vs slim issue fixture" do
      now = ~U[2026-09-01 12:00:00Z]

      full_issue = %{
        id: "task-1",
        title: "Test Task",
        priority: 1,
        rank: 10,
        state: :active,
        difficulty: 2,
        issue_type: :feature,
        workspace_id: "ws-1",
        created_at: ~U[2026-09-01 10:00:00Z],
        updated_at: ~U[2026-09-01 11:00:00Z],
        closed_at: nil,
        close_reason: nil,
        pr_ref: "123",
        merger_url: nil,
        merger_status: nil,
        merge_watch: nil,
        pending_merge: nil,
        awaiting_verification_at: nil,
        attention_cause: nil,
        attention_detail: nil,
        attention_since: nil,
        attention_owner: nil,
        attention_owner_cause: nil,
        attention_note: nil,
        attention_owner_since: nil,
        description: "Some description touching lib/foo.ex",
        acceptance: "acceptance criteria",
        notes: "some notes",
        # Extra heavy fields that should not affect derive/1
        posted_findings: %{"findings" => ["huge", "data"]},
        settled_threads: ["t1", "t2"],
        review_gate_state: %{"large" => "map"},
        verification_evidence: "huge evidence text",
        pr_body: "huge pr body content",
        qa_notes: "huge qa notes",
        deployment_notes: "deployment notes"
      }

      slim_fields = Snapshot.needed_issue_fields()
      slim_issue = Map.take(full_issue, slim_fields)

      full_input = %{
        issues: [full_issue],
        workers: [],
        blocked_by: %{},
        parent_of: [],
        conflicts_with: [],
        changed_files: %{},
        now: now,
        slots_total: 4,
        quota: :ok,
        paused: false,
        watchdog_live: MapSet.new(),
        over_budget: MapSet.new()
      }

      slim_input = %{full_input | issues: [slim_issue]}

      assert Snapshot.derive(full_input) == Snapshot.derive(slim_input)
    end
  end

  describe "load_issues/2 :exclude_engagements? (bd-crk6tb)" do
    setup %{ws: ws} do
      mk = fn title, attrs ->
        Ash.create!(
          Issue,
          Map.merge(%{title: title, tracker_type: :none, workspace_id: ws.id}, attrs)
        )
      end

      %{
        engagement: mk.("engagement", %{review_only: true, source_pr: "7"}),
        worker_review: mk.("worker review", %{review_only: true}),
        follow_up: mk.("follow up", %{source_pr: "8"})
      }
    end

    defp loaded_ids(opts),
      do: nil |> Snapshot.load_issues(opts) |> MapSet.new(& &1.id)

    test "drops only the engagement when on", ctx do
      ids = loaded_ids(exclude_engagements?: true)

      refute ctx.engagement.id in ids
      assert ctx.worker_review.id in ids
      assert ctx.follow_up.id in ids
    end

    test "the default read still carries engagements (the Autopilot's view)", ctx do
      assert ctx.engagement.id in loaded_ids([])
    end

    test "load/1 threads the option through to the board's issue read", ctx do
      board = Snapshot.load(workspace_id: ctx.engagement.workspace_id, exclude_engagements?: true)
      ids = MapSet.new(board.backlog, & &1.id)

      refute ctx.engagement.id in ids
      assert ctx.follow_up.id in ids
    end
  end

  defp spend!(task_id, cost, ws) do
    {:ok, ev} =
      Ash.create(Arbiter.Usage.Event, %{
        task_id: task_id,
        base_task_id: task_id,
        source: :task,
        step: :work,
        role: "base",
        workspace_id: ws.id,
        occurred_at: DateTime.utc_now(),
        cost_usd: cost
      })

    ev
  end
end
