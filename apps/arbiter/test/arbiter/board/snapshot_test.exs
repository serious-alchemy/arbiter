defmodule Arbiter.Board.SnapshotTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.Lifecycle

  @now ~U[2026-08-22 12:00:00Z]
  @yesterday ~U[2026-08-21 23:00:00Z]

  defp issue(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        state: :queued,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        description: nil,
        acceptance: nil,
        notes: nil,
        created_at: @now,
        updated_at: @now,
        closed_at: nil
      },
      attrs
    )
  end

  # A worker snapshot in one of its run's states. `:question` and
  # `:review_gate` are a `:waiting` run and what it waits on; `:succeeded`,
  # `:failed` and `:interrupted` are a finished run's outcome.
  defp worker(task_id, state, attrs \\ %{}) do
    Map.merge(
      Map.merge(
        %{
          task_id: task_id,
          workspace_id: "ws-1",
          current_step: :implement,
          started_at: @now,
          step_started_at: @now,
          mr_ref: nil,
          merger_url: nil,
          meta: %{}
        },
        run_fields(state)
      ),
      attrs
    )
  end

  defp run_fields(:question), do: %{state: :waiting, waiting_on: :question, outcome: nil}
  defp run_fields(:review_gate), do: %{state: :waiting, waiting_on: :review_gate, outcome: nil}

  defp run_fields(outcome) when outcome in [:succeeded, :failed, :interrupted],
    do: %{state: :finished, waiting_on: nil, outcome: outcome}

  defp run_fields(state), do: %{state: state, waiting_on: nil, outcome: nil}

  defp derive(overrides) do
    Snapshot.derive(
      Map.merge(
        %{
          issues: [],
          workers: [],
          blocked_by: %{},
          changed_files: %{},
          now: @now,
          slots_total: 4,
          quota: :ok,
          paused: false
        },
        Map.new(overrides)
      )
    )
  end

  defp ids(cards), do: Enum.map(cards, & &1.id)

  defp parent_of(parent_id, child_id), do: {parent_id, child_id}

  describe "ready column" do
    test "holds open issues that have no live worker, highest priority first" do
      board =
        derive(
          issues: [
            issue("bd-a", %{priority: 3}),
            issue("bd-b", %{priority: 1}),
            issue("bd-c", %{priority: 1, created_at: @yesterday})
          ]
        )

      assert ids(board.ready) == ["bd-c", "bd-b", "bd-a"]
    end

    test "an open issue with a live worker belongs to In progress, not Ready" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          workers: [worker("bd-a", :working)]
        )

      assert ids(board.ready) == ["bd-b"]
      assert ids(board.in_progress) == ["bd-a"]
    end

    test "epics are not dispatchable work and never queue" do
      board = derive(issues: [issue("bd-a", %{issue_type: :epic}), issue("bd-b")])

      assert ids(board.ready) == ["bd-b"]
    end

    test "each card carries the scheduler's state and one-line reason" do
      board = derive(issues: [issue("bd-a"), issue("bd-b")])

      assert [
               %{id: "bd-a", state: :next, reason: "next up — dispatching..."},
               %{id: "bd-b", state: :queued, reason: "1 ahead in queue"}
             ] = board.ready
    end

    # bd-79w1fs: a dependency is not a Ready hold any more — the ticket is
    # Blocked, out of the scheduler's queue, naming what it waits on.
    test "an open gating dependency takes the card out of Ready, into Blocked" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert ids(board.ready) == ["bd-b"]
      assert [%{id: "bd-a", blocked_by: ["bd-z"]}] = board.blocked
      assert board.promote == "bd-b"
    end

    test "file overlap with an in-flight worker holds the card" do
      board =
        derive(
          issues: [
            issue("bd-a", %{description: "Rewrites `lib/board.ex`."}),
            issue("bd-b")
          ],
          workers: [worker("bd-run", :working)],
          changed_files: %{"bd-run" => ["lib/board.ex"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: reason}, _] = board.ready
      assert reason == "blocked — lib/board.ex in flight on bd-run"
    end

    test "a running worker's own issue text counts as in-flight scope" do
      board =
        derive(
          issues: [
            issue("bd-a", %{description: "Rewrites `lib/board.ex`."}),
            issue("bd-run", %{state: :active, description: "Touches `lib/board.ex` too."})
          ],
          workers: [worker("bd-run", :working)]
        )

      assert [
               %{
                 id: "bd-a",
                 state: :blocked,
                 reason: "blocked — lib/board.ex in flight on bd-run"
               }
             ] =
               board.ready
    end
  end

  # bd-b5wyjd — the fixture is a `:queued` ticket, because that is what every
  # column but Backlog is about; Backlog tests pass `state: :backlog`, which is
  # also what a freshly created issue actually is. bd-79w1fs: Backlog is
  # in the same manual order as Ready (priority, then rank, then age), so a
  # drag within the column rewrites `rank` the way it does in Ready.
  describe "backlog column" do
    test "a :backlog ticket sits in Backlog, not Ready" do
      board = derive(issues: [issue("bd-a", %{state: :backlog}), issue("bd-b")])

      assert ids(board.backlog) == ["bd-a"]
      assert ids(board.ready) == ["bd-b"]
    end

    test "Backlog is in manual order: priority first, whatever the age" do
      board =
        derive(
          issues: [
            issue("bd-new", %{state: :backlog, priority: 3, created_at: @now}),
            issue("bd-old", %{state: :backlog, priority: 1, created_at: @yesterday})
          ]
        )

      assert ids(board.backlog) == ["bd-old", "bd-new"]
    end

    test "equal priority and rank in Backlog fall back to the older ticket" do
      board =
        derive(
          issues: [
            issue("bd-new", %{state: :backlog, rank: 1024, created_at: @now}),
            issue("bd-old", %{state: :backlog, rank: 1024, created_at: @yesterday})
          ]
        )

      assert ids(board.backlog) == ["bd-old", "bd-new"]
    end

    test "an unrefined issue with a live worker belongs to In progress, not Backlog" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :backlog})],
          workers: [worker("bd-a", :working)]
        )

      assert ids(board.backlog) == []
      assert ids(board.in_progress) == ["bd-a"]
    end

    test "a closed issue is not in Backlog, whatever its flag says" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :closed, updated_at: @now})],
          now: @now
        )

      assert ids(board.backlog) == []
      assert ids(board.closed_today) == ["bd-a"]
    end

    test "epics are a rollup, so they never queue in Backlog either" do
      board =
        derive(issues: [issue("bd-a", %{state: :backlog, issue_type: :epic})])

      assert ids(board.backlog) == []
    end

    test "a refined but dependency-blocked card is Blocked, not Backlog" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert ids(board.backlog) == []
      assert [%{id: "bd-a", blocked_by: ["bd-z"]}] = board.blocked
    end

    test "an unrefined card is never the scheduler's promote, however free the slots" do
      board = derive(issues: [issue("bd-a", %{state: :backlog})], slots_total: 8)

      assert board.promote == nil
    end

    test "cards carry what a Backlog card is read by" do
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :backlog, title: "think about caching"})
          ]
        )

      assert [
               %{
                 id: "bd-a",
                 title: "think about caching",
                 priority: 2,
                 difficulty: 2,
                 issue_type: :task,
                 workspace_id: "ws-1",
                 created_at: @now
               }
             ] = board.backlog
    end

    test "cards carry no assignee (bd-1ozks5: local assignee field removed)" do
      board =
        derive(
          issues: [issue("bd-a")],
          workers: [worker("bd-b", :working)]
        )

      assert [ready] = board.ready
      refute Map.has_key?(ready.card, :assignee)
      assert [in_progress] = board.in_progress
      refute Map.has_key?(in_progress, :assignee)
    end
  end

  describe "Ready order (bd-asxw4e): priority, then rank, then created_at" do
    test "a lower rank goes first within a priority band, whatever the creation order" do
      older = DateTime.add(@now, -3600)

      board =
        derive(
          issues: [
            issue("bd-old", %{priority: 2, rank: 2048, created_at: older}),
            issue("bd-new", %{priority: 2, rank: 1024, created_at: @now})
          ]
        )

      assert ids(board.ready) == ["bd-new", "bd-old"]
      assert board.promote == "bd-new"
    end

    test "priority outranks rank" do
      board =
        derive(
          issues: [
            issue("bd-a", %{priority: 3, rank: 0}),
            issue("bd-b", %{priority: 1, rank: 9000})
          ]
        )

      assert ids(board.ready) == ["bd-b", "bd-a"]
    end

    test "equal priority and rank fall back to the older ticket" do
      board =
        derive(
          issues: [
            issue("bd-new", %{rank: 1024, created_at: @now}),
            issue("bd-old", %{rank: 1024, created_at: DateTime.add(@now, -60)})
          ]
        )

      assert ids(board.ready) == ["bd-old", "bd-new"]
    end
  end

  describe "empty/1" do
    test "is a full board shape a screen can render, reporting itself paused" do
      board = Arbiter.Board.Snapshot.empty(@now)

      for column <- [
            :backlog,
            :blocked,
            :ready,
            :in_progress,
            :merging,
            :verifying,
            :closed_today
          ] do
        assert Map.fetch!(board, column) == []
      end

      assert board.attention == []
      assert board.promote == nil
      assert board.slots_total == 0
      assert board.slots_free == 0
      assert board.quota == :ok
      # Paused, because nothing should claim a queue position in a queue this
      # process could not read.
      assert board.paused
      assert board.now == @now
    end
  end

  describe "slots" do
    # bd-asxw4e: a slot is a ticket In progress — the `:active` tickets.
    test "every ticket In progress consumes a slot" do
      board =
        derive(
          slots_total: 3,
          issues: [
            issue("bd-1", %{state: :active}),
            issue("bd-2", %{state: :active})
          ],
          workers: [worker("bd-1", :working), worker("bd-2", :review_gate)]
        )

      assert board.slots_total == 3
      assert board.slots_used == 2
      assert board.slots_free == 1
    end

    test "a ticket Merging on its open PR releases its slot" do
      board =
        derive(
          slots_total: 2,
          # bd-741sid: its author run finished when the PR opened.
          issues: [issue("bd-1", %{state: :merging, pr_ref: "pr/1"})],
          workers: [worker("bd-1", :succeeded)]
        )

      assert board.slots_free == 2
    end

    # bd-2g179m: an approved ticket parked for a manual merge (`merge.auto_merge`
    # off) is Merging, so with a cap of 1 it must not block the next dispatch —
    # and the board's `slots_free` must be exactly what the plan then does.
    test "a ticket parked for a manual merge does not hold the only slot" do
      board =
        derive(
          slots_total: 1,
          issues: [
            issue("bd-parked", %{
              state: :merging,
              pr_ref: "!274",
              attention_cause: :awaiting_manual_merge
            }),
            issue("bd-next", %{})
          ],
          workers: [worker("bd-parked", :review_gate)]
        )

      assert board.slots_used == 0
      assert board.slots_free == 1
      assert board.promote == "bd-next"
    end

    test "slots_free is zero exactly when the plan will not dispatch" do
      board =
        derive(
          slots_total: 1,
          issues: [
            issue("bd-busy", %{state: :active}),
            issue("bd-next", %{})
          ],
          workers: [worker("bd-busy", :review_gate)]
        )

      assert board.slots_free == 0
      assert board.promote == nil
    end

    test "a closed ticket frees its slot" do
      board =
        derive(
          slots_total: 2,
          issues: [issue("bd-1", %{state: :closed})],
          workers: [worker("bd-1", :succeeded)]
        )

      assert board.slots_free == 2
    end

    test "no free slot holds the queue and says so" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-a"), issue("bd-1", %{state: :active})],
          workers: [worker("bd-1", :working)]
        )

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — no free worker slot"}] = board.ready
    end
  end

  # bd-79w1fs: a live run is an In progress card with `live: true`, its
  # `activity` saying what the agent is doing right now.
  describe "in progress column, live runs" do
    test "shows what the worker is doing right now" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active})],
          workers: [
            worker("bd-a", :working, %{
              current_step: :implement,
              meta: %{activity: "edit · scheduler.ex"}
            })
          ]
        )

      assert [
               %{
                 id: "bd-a",
                 title: "Task bd-a",
                 live: true,
                 step: :implementing,
                 activity: "edit · scheduler.ex"
               }
             ] =
               board.in_progress
    end

    test "a worker under review is still live, not waiting on you" do
      board = derive(workers: [worker("bd-a", :review_gate)])

      assert [%{id: "bd-a", activity: "in review", live: true, attention: nil}] =
               board.in_progress

      assert board.attention == []
    end

    test "reviewer workers fold into the author's card instead of queueing twice" do
      board =
        derive(
          workers: [
            worker("bd-a", :review_gate),
            worker("bd-a#review", :working, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert ids(board.in_progress) == ["bd-a"]
    end

    test "a ReviewGate fix-up round folds into the original issue's card, not a second one" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          issues: [issue("bd-a", %{state: :active})],
          workers: [
            worker("bd-a", :review_gate),
            worker(review_id <> "#impl2", :working, %{
              meta: %{role: :implementer, revises: "bd-a"}
            })
          ]
        )

      assert [%{id: "bd-a", title: "Task bd-a", activity: "round 2 implementation"}] =
               board.in_progress
    end

    test "a round-2+ reviewer pass shows a round-aware label on the author's card" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          workers: [
            worker("bd-a", :review_gate),
            worker(review_id <> "#r2", :working, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert [%{id: "bd-a", activity: "round 2 review"}] = board.in_progress
    end

    test "a re-prompted round-2 reviewer pass still resolves the round label through the chain" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          workers: [
            worker("bd-a", :review_gate),
            worker(review_id <> "#r2#v2", :working, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert [%{id: "bd-a", activity: "round 2 review"}] = board.in_progress
    end

    test "an author-only card's provider is the author's own" do
      board = derive(workers: [worker("bd-a", :working, %{meta: %{provider: "codex"}})])

      assert [%{id: "bd-a", provider: "codex"}] = board.in_progress
    end

    test "an author waiting on the review gate shows the gate worker's provider, not its own" do
      board =
        derive(
          workers: [
            worker("bd-a", :review_gate, %{meta: %{provider: "claude"}}),
            worker("bd-a#review", :working, %{
              meta: %{role: :reviewer, reviews: "bd-a", provider: "gemini"}
            })
          ]
        )

      assert [%{id: "bd-a", provider: "gemini"}] = board.in_progress
    end

    test "an unknown provider is nil, not a guess" do
      board = derive(workers: [worker("bd-a", :working, %{meta: %{}})])

      assert [%{id: "bd-a", provider: nil}] = board.in_progress
    end
  end

  # bd-79w1fs: the Waiting column is gone. A parked run keeps its ticket In
  # progress (the halt reason is the card's `activity`, `live: false`), and a
  # ticket with an open PR is Merging.
  describe "parked runs and the merge-parked" do
    test "parked runs stay In progress and open PRs are Merging, each longest wait first" do
      board =
        derive(
          # bd-741sid: an open PR is a Merging ticket, carded from its row.
          issues: [
            issue("bd-c", %{
              state: :merging,
              pr_ref: "!41",
              updated_at: @yesterday
            }),
            issue("bd-e", %{state: :merging, pr_ref: "!43"})
          ],
          workers: [
            worker("bd-a", :failed, %{
              step_started_at: ~U[2026-08-22 11:00:00Z],
              meta: %{stop_reason: %{category: :exited_without_done, summary: "review rejected"}}
            }),
            worker("bd-b", :question, %{
              step_started_at: ~U[2026-08-22 11:30:00Z],
              meta: %{await_reason: "needs a decision"}
            }),
            worker("bd-d", :working)
          ]
        )

      assert ids(board.merging) == ["bd-c", "bd-e"]
      assert ids(board.in_progress) == ["bd-a", "bd-b", "bd-d"]
      refute Map.has_key?(board, :waiting)
      refute Map.has_key?(board, :needs_you)
      refute Map.has_key?(board, :merge_queue)
    end

    test "a parked run's card carries its halt reason; a Merging card its merge fields" do
      board =
        derive(
          workers: [
            worker("bd-a", :question, %{meta: %{await_reason: "needs a decision"}})
          ],
          # bd-741sid: the merge-parked one is a Merging ticket, its merge
          # fields on its own row.
          issues: [
            issue("bd-b", %{
              state: :merging,
              updated_at: @yesterday,
              pr_ref: "!42",
              merger_url: "https://example.test/42",
              merger_status: %{"approved" => false}
            })
          ]
        )

      assert [
               %{
                 id: "bd-b",
                 mr_ref: "!42",
                 merger_url: "https://example.test/42",
                 merger_status: %{approved: false}
               }
             ] = board.merging

      assert [%{id: "bd-a", live: false, activity: "needs a decision"}] = board.in_progress
    end

    # bd-2mv3lx: `arb worker stop` on a worker (the documented pre-flight for `arb server deploy`) leaves the issue
    # `in_progress` with no live worker — a state that used to match none of
    # the five columns and vanished from the board entirely.
    # bd-8if9zt: a stopped run is the coordinator's to resume first, so the
    # card carries that attention without flagging the operator.
    test "an in_progress issue with no live worker still shows, as the coordinator's" do
      board =
        derive(
          issues: [
            issue("bd-a", %{
              state: :active,
              updated_at: @yesterday,
              pr_ref: "123"
            })
          ]
        )

      assert [%{id: "bd-a", live: false, activity: activity, phase: :waiting_on_you} = card] =
               board.in_progress

      assert activity =~ "worker stopped"
      assert %{owner: :coordinator, cause: :run_crashed} = card.attention
      assert elsewhere(board, "bd-a") == []
    end

    # bd-2gc809: a restart re-arms a CI wait with no run row at all; the card
    # names the wait and the ticket has no attention (it is not a crash).
    test "an in_progress issue waiting on CI with no worker reads waiting-on-CI, not stopped" do
      marker =
        Arbiter.Worker.ReviewCi.marker("a1b2c3d4e5f6a7b8", 1, %{
          interval_ms: 60_000,
          max_polls: 30
        })

      board =
        derive(
          issues: [
            issue("bd-a", %{
              state: :active,
              updated_at: @yesterday,
              pr_ref: "123",
              review_gate_state: %{"ci_wait" => marker}
            })
          ]
        )

      assert [%{id: "bd-a", live: false, activity: activity, step: :awaiting_ci} = card] =
               board.in_progress

      assert activity == "waiting on CI a1b2c3d4e5f6"
      assert card.attention == nil
      assert board.attention == []
    end

    test "an in_progress epic with no live worker is not treated as orphaned" do
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :active, updated_at: @yesterday, issue_type: :epic})
          ]
        )

      assert board.in_progress == []
      assert board.attention == []
    end

    test "an in_progress issue that just started dispatch is not flagged orphaned yet" do
      board = derive(issues: [issue("bd-a", %{state: :active, updated_at: @now})])

      assert [%{id: "bd-a", activity: "dispatching", attention: nil}] = board.in_progress
    end

    test "an in_progress issue with a live worker is not double-counted as orphaned" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active})],
          workers: [worker("bd-a", :question)]
        )

      assert ids(board.in_progress) == ["bd-a"]
    end

    # bd-6lvc1r: a run finished `:succeeded` is a real, terminal row — the CI
    # fix pass finished — but it is neither running nor waiting, and its presence in `worked` used to be enough to
    # keep `orphaned_cards` from picking the issue up either. The task
    # vanished from every column even though `classify_columns` still called
    # it `:waiting`.
    test "an in_progress issue whose only worker row succeeded still shows, with its park" do
      board =
        derive(
          issues: [
            issue("bd-a", %{
              state: :active,
              updated_at: @yesterday,
              pr_ref: "!293",
              attention_cause: :resume_blocked
            })
          ],
          workers: [worker("bd-a", :succeeded)]
        )

      assert [%{id: "bd-a", live: false, activity: activity} = card] = board.in_progress
      assert activity =~ "resume_blocked"
      assert %{owner: :coordinator, cause: :resume_blocked} = card.attention
      assert elsewhere(board, "bd-a") == []
    end

    test "an in_progress issue whose only worker row succeeded and has no park reason still shows" do
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :active, updated_at: @yesterday})
          ],
          workers: [worker("bd-a", :succeeded)]
        )

      assert [%{id: "bd-a", activity: activity}] = board.in_progress
      assert activity =~ "worker stopped"
    end

    test "an in_progress issue with both a succeeded row and a live row is not double-counted" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active, updated_at: @yesterday})],
          workers: [
            worker("bd-a", :succeeded),
            worker("bd-a", :question)
          ]
        )

      assert ids(board.in_progress) == ["bd-a"]
    end
  end

  # Every column but In progress, for asserting a card landed nowhere else.
  defp elsewhere(board, id) do
    for column <- [:backlog, :blocked, :ready, :merging, :verifying, :closed_today],
        id in ids(Map.fetch!(board, column)),
        do: column
  end

  # bd-6zapbl: the board reads each ticket's column from `Lifecycle.view/2`.
  describe "columns from the lifecycle projection (bd-6zapbl)" do
    test "a queued ticket with a leftover finished author row stays in Ready" do
      for outcome <- [:succeeded, :failed, :interrupted] do
        board =
          derive(
            issues: [issue("bd-a", %{state: :queued})],
            workers: [worker("bd-a", outcome)]
          )

        assert ids(Enum.map(board.ready, & &1.card)) == ["bd-a"], "#{outcome} row hid it"
        assert board.in_progress == [] and board.blocked == [] and board.backlog == []
      end
    end

    test "a blocked queued ticket with a leftover author row stays Blocked, keeping its blockers" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :queued})],
          workers: [worker("bd-a", :failed)],
          blocked_by: %{"bd-a" => ["bd-9"]}
        )

      assert [%{id: "bd-a", blocked_by: ["bd-9"]}] = board.blocked
      assert board.ready == [] and board.in_progress == []
    end

    test "a backlog ticket with a leftover author row stays in Backlog" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :backlog})],
          workers: [worker("bd-a", :succeeded)]
        )

      assert ids(board.backlog) == ["bd-a"]
    end

    test "a merging ticket is Merging, even with its author row still running" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :merging, pr_ref: "!1"})],
          workers: [worker("bd-a", :working)]
        )

      assert [%{id: "bd-a", mr_ref: "!1"}] = board.merging
      assert board.in_progress == []
    end

    test "a verifying ticket gets its one verification card, whatever rows linger" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :verifying})],
          workers: [worker("bd-a", :failed)]
        )

      assert [%{id: "bd-a"}] = board.verifying
      assert board.in_progress == []
    end

    test "an in-progress ticket inside the dispatch grace is an In progress dispatching card" do
      board = derive(issues: [issue("bd-a", %{state: :active})])

      # bd-741sid: no hand-off phase — a run not yet registered reads as its stage.
      assert [
               %{
                 id: "bd-a",
                 live: false,
                 activity: "dispatching",
                 phase: :implementing,
                 agent_live: false
               }
             ] = board.in_progress
    end

    test "a working author and a live fix pass render one In progress card" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active})],
          workers: [
            worker("bd-a", :working),
            worker("bd-a", :working, %{role: :fix_pass, registry_key: "bd-a:fix"})
          ]
        )

      assert [%{id: "bd-a", status: :working}] = board.in_progress
    end
  end

  describe "In progress / Merging / Verifying column invariant (bd-6lvc1r)" do
    # Whatever `classify_columns/2` says an issue's column is, `derive/1` must
    # produce exactly one card for it — never zero (the bug), never two. Since
    # bd-79w1fs the interim :running / :waiting split into In progress,
    # Merging and Verifying, by the ticket's `Lifecycle.view/2` column.
    test "every issue classify_columns puts in :waiting or :running gets exactly one card" do
      issues = [
        issue("bd-running", %{state: :active}),
        issue("bd-waiting-question", %{state: :active}),
        issue("bd-waiting-failed", %{state: :active}),
        issue("bd-waiting-merging", %{state: :merging, pr_ref: "!1"}),
        issue("bd-waiting-succeeded-only", %{state: :active, updated_at: @yesterday}),
        issue("bd-waiting-orphaned", %{state: :active, updated_at: @yesterday}),
        issue("bd-waiting-verification", %{state: :verifying})
      ]

      workers = [
        worker("bd-running", :working),
        worker("bd-waiting-question", :question),
        worker("bd-waiting-failed", :failed),
        worker("bd-waiting-merging", :succeeded),
        worker("bd-waiting-succeeded-only", :succeeded)
      ]

      board = derive(issues: issues, workers: workers)
      columns = Snapshot.classify_columns(issues, workers, now: @now)

      for issue <- issues, Map.get(columns, issue.id) in [:waiting, :running] do
        cards =
          for column <- [:in_progress, :merging, :verifying],
              card <- Map.fetch!(board, column),
              card.id == issue.id,
              do: column

        runs = Enum.filter(workers, &(&1.task_id == issue.id))
        view = Lifecycle.view(issue, %{runs: runs, blocked_by: [], now: @now})

        assert cards == [view.column],
               "expected one #{view.column} card for #{issue.id}, got #{inspect(cards)}"
      end

      # …and the converse: nothing else is carded in those three columns.
      for column <- [:in_progress, :merging, :verifying], card <- Map.fetch!(board, column) do
        assert Map.get(columns, card.id) in [:waiting, :running]
      end
    end
  end

  # bd-8jixav: a task's own waiting row and a subordinate `:fixpass` /
  # `:conflict` pass's failed row both belong to the ticket, so one task used
  # to render as two cards — read at a glance as two different stuck tickets.
  # bd-79w1fs: both are In progress now.
  describe "in progress column, one card per task" do
    test "a subordinate pass does not add a second card for the same task" do
      board =
        derive(
          workers: [
            worker("bd-a", :question, %{
              mr_ref: "!42",
              step_started_at: @yesterday
            }),
            worker("bd-a", :failed, %{
              registry_key: "bd-a:fixpass",
              role: :fix_pass,
              step_started_at: @now,
              meta: %{stop_reason: %{category: :exited_without_done, summary: "fix pass died"}}
            })
          ]
        )

      assert ids(board.in_progress) == ["bd-a"]
    end

    test "the primary row's fields win over the subordinate pass's" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              registry_key: "bd-a:conflict",
              role: :conflict,
              step_started_at: @now
            }),
            worker("bd-a", :question, %{
              mr_ref: "!42",
              merger_url: "https://example.test/42",
              step_started_at: @yesterday
            })
          ]
        )

      assert [
               %{
                 id: "bd-a",
                 status: :waiting,
                 waiting_on: :question,
                 outcome: nil,
                 since: @yesterday
               }
             ] = board.in_progress
    end

    test "a subordinate pass with no primary row still gets its own card" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ]
        )

      assert [%{id: "bd-a", status: :finished, outcome: :failed}] = board.in_progress
    end

    # bd-741sid: the "primary alone reads as the machine clearing a CI block"
    # case is a Merging ticket now — see "Merging tickets" below. On a worker
    # card the collapsed pass still names itself.
    test "a collapsed dead fix pass still names itself on the card" do
      board =
        derive(
          workers: [
            worker("bd-a", :question, %{mr_ref: "!42", registry_key: "bd-a"}),
            worker("bd-a", :failed, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ],
          watchdog_live: MapSet.new(["bd-a"])
        )

      assert [
               %{
                 id: "bd-a",
                 status: :waiting,
                 waiting_on: :question,
                 attention: %{owner: :coordinator, cause: :run_asked_question},
                 collapsed_note: note
               }
             ] = board.in_progress

      assert note =~ "fix pass"
      assert note =~ "failed"
    end

    # bd-741sid: an open PR's card is its Merging ticket's; a healthy pass
    # still registered under it adds nothing.
    test "a collapsed healthy row adds no note and no flag" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :merging, pr_ref: "!42"})],
          workers: [
            worker("bd-a", :working, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ],
          watchdog_live: MapSet.new(["bd-a"])
        )

      assert [%{id: "bd-a", attention: nil, collapsed_note: nil}] = board.merging
    end

    test "distinct tasks are never collapsed" do
      board =
        derive(
          workers: [
            worker("bd-a", :question, %{step_started_at: @yesterday}),
            worker("bd-b", :question, %{step_started_at: @now})
          ]
        )

      assert ids(board.in_progress) == ["bd-a", "bd-b"]
    end
  end

  # bd-8jixav: a Watchdog is a :temporary child — when it crashes it is gone
  # for good, silently, and the parked card looks exactly like a healthy one.
  # bd-741sid: no run stays resident on an open PR, so a Watchdog belongs to a
  # Merging ticket (see "Merging tickets") and a worker card never has one.
  # bd-79w1fs: an In progress card carries no Watchdog field at all, so it can
  # never read as a missing Watchdog.
  describe "watchdog liveness on an In progress card" do
    test "a worker card carries no liveness field, so never reads as missing" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{}),
            worker("bd-b", :question, %{step_started_at: @yesterday})
          ],
          watchdog_live: MapSet.new()
        )

      assert ids(board.in_progress) == ["bd-b", "bd-a"]
      refute Enum.any?(board.in_progress, &Map.has_key?(&1, :watchdog_alive))
    end

    test "an orphaned issue card carries no liveness field either" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active, updated_at: @yesterday})],
          watchdog_live: MapSet.new()
        )

      assert [%{id: "bd-a"} = card] = board.in_progress
      refute Map.has_key?(card, :watchdog_alive)
    end
  end

  # bd-741sid: a Merging ticket's implementer stopped when its PR opened, so
  # nothing registered speaks for it — the card is built from the ticket.
  describe "Merging tickets" do
    defp merging(id, attrs \\ %{}) do
      issue(
        id,
        Map.merge(
          %{
            state: :merging,
            pr_ref: "!42",
            merger_url: "https://example.test/42",
            merger_status: %{"status" => "open", "approved" => false},
            updated_at: @yesterday
          },
          attrs
        )
      )
    end

    test "with no worker, a Merging ticket is a merge card from its row, not an orphan" do
      board = derive(issues: [merging("bd-m")], watchdog_live: MapSet.new(["bd-m"]))

      assert [
               %{
                 id: "bd-m",
                 mr_ref: "!42",
                 merger_url: "https://example.test/42",
                 merger_status: %{status: :open, approved: false},
                 watchdog_alive: true,
                 attention: nil,
                 collapsed_note: nil,
                 agent_live: false,
                 since: @yesterday
               } = card
             ] = board.merging

      assert board.in_progress == []
      refute Map.has_key?(card, :reason)
      # bd-36ytcl: an open PR is no worker phase; what it waits on is the
      # ticket's step.
      refute Map.has_key?(card, :phase)
      assert card.step == :in_merge_queue
    end

    test "one whose Watchdog is gone says so, as the coordinator's" do
      board = derive(issues: [merging("bd-m")], watchdog_live: MapSet.new())

      assert [%{id: "bd-m", watchdog_alive: false} = card] = board.merging
      assert %{owner: :coordinator, cause: :merge_blocked} = card.attention
    end

    test "omitting the liveness input reports unknown rather than missing" do
      board = derive(issues: [merging("bd-m")])

      assert [%{id: "bd-m", watchdog_alive: nil, attention: nil}] = board.merging
    end

    test "a block the Watchdog clears itself does not flag; one it cannot, does" do
      board =
        derive(
          issues: [
            merging("bd-a", %{
              merger_status: %{"approved" => true, "block_reason" => "ci_failed"}
            }),
            merging("bd-b", %{
              merger_status: %{"approved" => true, "block_reason" => "needs_approval"}
            })
          ],
          watchdog_live: MapSet.new(["bd-a", "bd-b"])
        )

      assert flags(board) == %{"bd-a" => false, "bd-b" => true}
    end

    test "a failed pass still registered under the ticket names itself on the card" do
      board =
        derive(
          issues: [merging("bd-m")],
          workers: [worker("bd-m", :failed, %{role: :fix_pass, meta: %{role: :fix_pass}})],
          watchdog_live: MapSet.new(["bd-m"])
        )

      assert [%{id: "bd-m", attention: nil, collapsed_note: note}] =
               board.merging

      assert note =~ "failed"
    end
  end

  # The flag is not "which status" — it is "has the system run out of things to
  # try on its own". bd-79w1fs: the card's `needs_you` is gone; the flag is
  # its attention being the operator's, read off every card that can have one.
  defp flags(board) do
    Map.new(
      board.in_progress ++ board.merging ++ board.verifying,
      &{&1.id, match?(%{attention: %{owner: :operator}}, &1)}
    )
  end

  # bd-8if9zt (AC6): the flag is `attention.owner == :operator`. The
  # coordinator comes first — a card it can act on carries its attention but
  # does not flag the operator; child 7 (bd-8nlez1) adds the hand-off and the
  # limits that move an item to the operator.
  describe "operator attention (the former needs-you flag)" do
    test "a worker that asked a question is the coordinator's to answer" do
      board = derive(workers: [worker("bd-a", :question, %{meta: %{await_reason: "which?"}})])

      assert flags(board) == %{"bd-a" => false}

      assert [%{attention: %{owner: :coordinator, cause: :run_asked_question}}] =
               board.in_progress
    end

    test "a failed run with a follow-up round under way is not flagged" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active})],
          workers: [
            worker("bd-a", :failed),
            worker("bd-a#impl", :working, %{
              registry_key: "bd-a#impl",
              meta: %{role: :implementer, revises: "bd-a"}
            })
          ]
        )

      assert [%{id: "bd-a", live: false, attention: nil}] = board.in_progress
    end

    test "an operator-owned cause flags; a coordinator-owned one does not" do
      board =
        derive(
          issues: [
            merging("bd-a", %{attention_cause: :awaiting_manual_merge}),
            merging("bd-b", %{attention_cause: :merge_blocked})
          ]
        )

      assert flags(board) == %{"bd-a" => true, "bd-b" => false}

      assert %{"bd-a" => :operator, "bd-b" => :coordinator} ==
               Map.new(board.merging, &{&1.id, &1.attention.owner})
    end

    # bd-741sid: a merge request is a Merging ticket's, its last poll on the
    # ticket's row.
    test "a merge request the forge is still chewing on does not flag" do
      board =
        derive(
          issues: [
            merging("bd-a", %{merger_status: %{approved: false}}),
            merging("bd-b", %{merger_status: nil})
          ]
        )

      assert flags(board) == %{"bd-a" => false, "bd-b" => false}
    end

    test "an approved merge request needing an approval the fleet cannot give flags; other blocks are the coordinator's" do
      board =
        derive(
          issues:
            for {id, reason} <- [
                  {"bd-a", :conflict},
                  {"bd-b", :needs_approval},
                  {"bd-c", :needs_nonauthor_approval},
                  # A draft or a forge-specific block is the coordinator's to
                  # try first (bd-8if9zt).
                  {"bd-d", :draft},
                  {"bd-e", :blocked_other}
                ] do
              merging(id, %{merger_status: %{approved: true, block_reason: reason}})
            end
        )

      assert flags(board) == %{
               "bd-a" => false,
               "bd-b" => true,
               "bd-c" => true,
               "bd-d" => false,
               "bd-e" => false
             }

      for card <- board.merging, do: assert(card.attention.cause == :merge_blocked)
    end

    test "a block the system still auto-handles does not flag" do
      board =
        derive(
          issues:
            for {id, reason} <- [{"bd-a", :behind_base}, {"bd-b", :ci_failed}] do
              merging(id, %{merger_status: %{approved: true, block_reason: reason}})
            end
        )

      assert flags(board) == %{"bd-a" => false, "bd-b" => false}
    end

    test "a parked failure with nothing left in flight is the coordinator's" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              meta: %{stop_reason: %{category: :exited_without_done, summary: "review rejected"}}
            })
          ]
        )

      assert flags(board) == %{"bd-a" => false}
      assert [%{attention: %{owner: :coordinator, cause: :run_crashed}}] = board.in_progress
    end

    # A review-timeout failure keeps the last poll's merger status in its meta,
    # so a terminal worker can still be carrying an auto-resolvable block. The
    # worker is dead either way — the status wins over the stale block.
    test "a parked failure carrying a stale auto-resolvable block is still the coordinator's" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{
              meta: %{last_merger_status: %{approved: true, block_reason: :ci_failed}}
            })
          ]
        )

      assert flags(board) == %{"bd-a" => false}
      assert [%{attention: %{cause: :run_crashed}}] = board.in_progress
    end
  end

  # bd-9so315 — merged-but-unverified tasks are the coordinator's: nothing else
  # will clear them. bd-79w1fs: they have their own column, Verifying.
  describe "awaiting-verification cards" do
    test "a parked task appears in Verifying with its age, as the coordinator's to verify" do
      board =
        derive(
          issues: [
            issue("bd-v", %{
              state: :verifying,
              awaiting_verification_at: @yesterday
            })
          ]
        )

      assert [card] = board.verifying
      assert card.id == "bd-v"

      assert %{owner: :coordinator, waiting_on: :verification, cause: :awaiting_verification} =
               card.attention

      assert card.since == @yesterday
      assert [%{id: "bd-v", column: :verifying, owner: :coordinator}] = board.attention
    end

    test "falls back to updated_at when the stamp predates the field" do
      board =
        derive(
          issues: [
            issue("bd-v", %{state: :verifying, updated_at: @yesterday})
          ]
        )

      assert [%{since: @yesterday}] = board.verifying
    end

    test "an open or closed task produces no awaiting card" do
      board =
        derive(issues: [issue("bd-a"), issue("bd-b", %{state: :closed, updated_at: @now})])

      assert board.verifying == []
    end

    test "a parked task is not also a Ready, Backlog or In progress card" do
      board = derive(issues: [issue("bd-v", %{state: :verifying})])

      assert ids(board.ready) == []
      assert ids(board.backlog) == []
      assert ids(board.in_progress) == []
    end
  end

  describe "closed recent column (last 24 hours)" do
    test "includes issues closed within the last 24 hours, newest-closed first" do
      # @now = 2026-08-22 12:00:00 UTC
      # 13h ago (within 24h, yesterday): 2026-08-21 23:00:00 UTC
      # 20h ago (within 24h): 2026-08-21 16:00:00 UTC
      # 23h ago (within 24h): 2026-08-21 13:00:00 UTC
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :closed, closed_at: ~U[2026-08-21 13:00:00Z]}),
            issue("bd-b", %{state: :closed, closed_at: ~U[2026-08-21 16:00:00Z]}),
            issue("bd-c", %{state: :closed, closed_at: ~U[2026-08-21 23:00:00Z]})
          ]
        )

      # Should include all (all are within 24h), sorted newest-closed first
      assert ids(board.closed_today) == ["bd-c", "bd-b", "bd-a"]
    end

    test "excludes issues closed more than 24 hours ago" do
      # @now = 2026-08-22 12:00:00 UTC
      # 25h ago (beyond 24h): 2026-08-21 11:00:00 UTC
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :closed, closed_at: ~U[2026-08-21 11:00:00Z]}),
            issue("bd-b", %{state: :closed, closed_at: ~U[2026-08-22 11:00:00Z]})
          ]
        )

      # Should exclude bd-a (25h ago), include bd-b (1h ago)
      assert ids(board.closed_today) == ["bd-b"]
    end

    test "does not include recently updated issues closed more than 24h ago" do
      # @now = 2026-08-22 12:00:00 UTC
      # Closed 30h ago but updated 1h ago: should NOT be included
      board =
        derive(
          issues: [
            issue("bd-a", %{
              state: :closed,
              closed_at: ~U[2026-08-21 06:00:00Z],
              updated_at: ~U[2026-08-22 11:00:00Z]
            })
          ]
        )

      # Should be empty (closed_at is what matters, not updated_at)
      assert ids(board.closed_today) == []
    end

    test "falls back to updated_at for legacy issues with nil closed_at" do
      # For backward compatibility, if closed_at is nil, use updated_at
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :closed, closed_at: nil, updated_at: ~U[2026-08-22 11:00:00Z]})
          ]
        )

      # Should include it because updated_at is within 24h
      assert ids(board.closed_today) == ["bd-a"]
    end

    test "excludes legacy issues with nil closed_at updated more than 24h ago" do
      board =
        derive(
          issues: [
            issue("bd-a", %{state: :closed, closed_at: nil, updated_at: ~U[2026-08-21 11:00:00Z]})
          ]
        )

      # Should exclude it because even updated_at is beyond 24h
      assert ids(board.closed_today) == []
    end

    # bd-38of5i (design bd-2s901b §4): an epic is a rollup of children, not a
    # piece of work — so "the day's evidence of progress" is the children that
    # closed, not the container that closed because they did. Closed-today was
    # the one column epics still leaked into; every other column already
    # excludes them via `queueable?/2` / `orphaned?/3`.
    test "an epic closed in the last 24h is not a Closed card" do
      board =
        derive(
          issues: [
            issue("bd-epic", %{
              issue_type: :epic,
              state: :closed,
              closed_at: ~U[2026-08-22 11:00:00Z]
            }),
            issue("bd-a", %{state: :closed, closed_at: ~U[2026-08-22 10:00:00Z]})
          ]
        )

      assert ids(board.closed_today) == ["bd-a"]
    end

    test "excluding the epic leaves every other column, the counts and the slot math alone" do
      issues = [
        issue("bd-epic", %{issue_type: :epic, state: :closed, closed_at: @now}),
        issue("bd-ready"),
        issue("bd-backlog", %{state: :backlog}),
        issue("bd-run", %{state: :active}),
        issue("bd-closed", %{state: :closed, closed_at: @now})
      ]

      board = derive(issues: issues, workers: [worker("bd-run", :working)])

      assert ids(board.backlog) == ["bd-backlog"]
      assert Enum.map(board.ready, & &1.card.id) == ["bd-ready"]
      assert ids(board.in_progress) == ["bd-run"]
      assert board.blocked == [] and board.merging == [] and board.verifying == []
      assert ids(board.closed_today) == ["bd-closed"]
      assert board.slots_total == 4
      assert board.slots_free == 3
    end
  end

  # bd-38of5i (design bd-2s901b §4): with epics gone from every column, a
  # child card is the only place an epic stays discoverable on the board — so
  # every card carries a ref to its parent for the view to render as a chip.
  # bd-8j9i9p (design bd-9jj5lf §3): a task whose worker spend has passed its
  # difficulty/type group's p90 is not a stuck worker, but it is a thing to
  # look at — so it flags on the board the way attention does. The estimate
  # itself is an *input* here: `derive/1` never reads the ledger.
  describe "over-budget attention flag" do
    test "an open issue in the over-budget set flags on its card" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          over_budget: ["bd-a"]
        )

      assert [%{card: %{id: "bd-a", over_budget: true}}, %{card: %{over_budget: false}}] =
               board.ready
    end

    test "every open column carries the flag" do
      board =
        derive(
          issues: [
            issue("bd-backlog", %{state: :backlog}),
            issue("bd-blocked"),
            issue("bd-ready"),
            issue("bd-run", %{state: :active}),
            issue("bd-wait", %{state: :active, updated_at: @yesterday}),
            issue("bd-merge", %{state: :merging, pr_ref: "!1"}),
            issue("bd-verify", %{state: :verifying})
          ],
          workers: [worker("bd-run", :working)],
          blocked_by: %{"bd-blocked" => ["bd-ready"]},
          over_budget: [
            "bd-backlog",
            "bd-blocked",
            "bd-ready",
            "bd-run",
            "bd-wait",
            "bd-merge",
            "bd-verify"
          ]
        )

      assert [%{over_budget: true}] = board.backlog
      assert [%{over_budget: true}] = board.blocked
      assert [%{card: %{over_budget: true}}] = board.ready
      assert [%{over_budget: true}, %{over_budget: true}] = board.in_progress
      assert [%{over_budget: true}] = board.merging
      assert [%{over_budget: true}] = board.verifying
    end

    test "a closed card never flags, even if its id is in the set" do
      board =
        derive(
          issues: [issue("bd-closed", %{state: :closed, closed_at: @now})],
          over_budget: ["bd-closed"]
        )

      assert [%{over_budget: false}] = board.closed_today
    end

    test "no over-budget input means no card flags" do
      board = derive(issues: [issue("bd-a")])

      assert [%{card: %{over_budget: false}}] = board.ready
    end
  end

  describe "parent ref on cards" do
    test "a card whose issue has a parent_of parent carries the parent's id, title and progress" do
      board =
        derive(
          issues: [
            issue("bd-epic", %{issue_type: :epic, title: "Browser sessions"}),
            issue("bd-a"),
            issue("bd-b", %{state: :closed, closed_at: @now})
          ],
          parent_of: [parent_of("bd-epic", "bd-a"), parent_of("bd-epic", "bd-b")]
        )

      assert [%{card: %{parent: parent}}] = board.ready

      assert parent == %{
               id: "bd-epic",
               title: "Browser sessions",
               issue_type: :epic,
               child_total: 2,
               child_closed: 1
             }
    end

    test "a card whose issue has no parent carries a nil parent" do
      board = derive(issues: [issue("bd-a")])

      assert [%{card: %{parent: nil}}] = board.ready
    end

    test "every column's cards carry the ref, not just Ready" do
      children = [
        issue("bd-backlog", %{state: :backlog}),
        issue("bd-blocked"),
        issue("bd-run", %{state: :active}),
        issue("bd-wait", %{state: :active, updated_at: @yesterday}),
        issue("bd-merge", %{state: :merging, pr_ref: "!1"}),
        issue("bd-verify", %{state: :verifying}),
        issue("bd-closed", %{state: :closed, closed_at: @now})
      ]

      board =
        derive(
          issues: [issue("bd-epic", %{issue_type: :epic, title: "Epic"}) | children],
          workers: [worker("bd-run", :working)],
          blocked_by: %{"bd-blocked" => ["bd-9"]},
          parent_of: Enum.map(children, &parent_of("bd-epic", &1.id))
        )

      assert [%{parent: %{id: "bd-epic"}}] = board.backlog
      assert [%{parent: %{id: "bd-epic"}}] = board.blocked
      assert [%{parent: %{id: "bd-epic"}}, %{parent: %{id: "bd-epic"}}] = board.in_progress
      assert [%{parent: %{id: "bd-epic"}}] = board.merging
      assert [%{parent: %{id: "bd-epic"}}] = board.verifying
      assert [%{parent: %{id: "bd-epic"}}] = board.closed_today
    end

    # Multiple parents are unusual but legal. A card has room for one chip, so
    # it takes the most recently updated parent — the same tie-break the
    # detail-page banner stacks by.
    test "with more than one parent, the card takes the most recently updated one" do
      board =
        derive(
          issues: [
            issue("bd-old", %{issue_type: :epic, updated_at: @yesterday}),
            issue("bd-new", %{issue_type: :epic, updated_at: @now}),
            issue("bd-a")
          ],
          parent_of: [parent_of("bd-old", "bd-a"), parent_of("bd-new", "bd-a")]
        )

      assert [%{card: %{parent: %{id: "bd-new"}}}] = board.ready
    end

    # A parent_of row pointing at an issue the board never read is a dangling
    # edge, not a chip: better no chip than one that links to a 404 with a
    # blank title.
    test "a parent the board did not read produces no ref" do
      board = derive(issues: [issue("bd-a")], parent_of: [parent_of("bd-gone", "bd-a")])

      assert [%{card: %{parent: nil}}] = board.ready
    end

    # A non-epic parent (a plain task with subtasks) still gets a chip; the
    # component renders it without the epic chrome.
    test "a non-epic parent still produces a ref, carrying its own type" do
      board =
        derive(
          issues: [issue("bd-parent", %{issue_type: :task}), issue("bd-a")],
          parent_of: [parent_of("bd-parent", "bd-a")]
        )

      assert %{card: %{parent: %{id: "bd-parent", issue_type: :task}}} =
               Enum.find(board.ready, &(&1.card.id == "bd-a"))
    end
  end

  describe "board-wide holds" do
    test "an exhausted quota blocks promotion and names itself" do
      board = derive(issues: [issue("bd-a")], quota: {:hold, "quota exhausted"})

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — quota exhausted"}] = board.ready
    end

    test "a paused board dispatches nothing" do
      board = derive(issues: [issue("bd-a")], paused: true)

      assert board.promote == nil
      assert [%{state: :blocked, reason: "scheduler paused"}] = board.ready
    end
  end

  # bd-1273p2: an epic detail page groups its children into the same five
  # columns the board renders, using this helper so the two surfaces can't
  # drift onto different classifications.
  describe "classify_columns/2" do
    test "an unrefined open issue lands in backlog" do
      assert Snapshot.classify_columns([issue("bd-a", %{state: :backlog})]) == %{
               "bd-a" => :backlog
             }
    end

    test "a refined open issue lands in ready" do
      assert Snapshot.classify_columns([issue("bd-a", %{state: :queued})]) == %{"bd-a" => :ready}
    end

    test "an in-progress issue with a live running worker lands in running" do
      issues = [issue("bd-a", %{state: :active})]
      workers = [worker("bd-a", :working)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :running}
    end

    test "a worker's presence outranks a stale open status, same as the board" do
      issues = [issue("bd-a", %{state: :queued})]
      workers = [worker("bd-a", :starting)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :running}
    end

    test "an in-progress issue with a parked worker lands in waiting" do
      issues = [issue("bd-a", %{state: :active})]
      workers = [worker("bd-a", :failed)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :waiting}
    end

    test "an in-progress issue with no worker at all lands in waiting" do
      issues = [issue("bd-a", %{state: :active})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :waiting}
    end

    test "an awaiting_verification issue lands in waiting" do
      issues = [issue("bd-a", %{state: :verifying})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :waiting}
    end

    test "a closed issue lands in closed" do
      issues = [issue("bd-a", %{state: :closed})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :closed}
    end

    test "a reviewer/implementer worker on the same task does not count as running" do
      issues = [issue("bd-a", %{state: :active})]
      workers = [worker("bd-a", :working, %{meta: %{role: :reviewer}})]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :waiting}
    end

    test "classifies a full mix of issues independently" do
      issues = [
        issue("bd-backlog", %{state: :backlog}),
        issue("bd-ready", %{state: :queued}),
        issue("bd-running", %{state: :active}),
        issue("bd-waiting", %{state: :active}),
        issue("bd-closed", %{state: :closed})
      ]

      workers = [worker("bd-running", :working)]

      assert Snapshot.classify_columns(issues, workers) == %{
               "bd-backlog" => :backlog,
               "bd-ready" => :ready,
               "bd-running" => :running,
               "bd-waiting" => :waiting,
               "bd-closed" => :closed
             }
    end
  end
end
