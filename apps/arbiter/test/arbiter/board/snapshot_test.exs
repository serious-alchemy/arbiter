defmodule Arbiter.Board.SnapshotTest do
  use ExUnit.Case, async: true

  alias Arbiter.Board.Snapshot

  @now ~U[2026-08-22 12:00:00Z]
  @yesterday ~U[2026-08-21 23:00:00Z]

  defp issue(id, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        title: "Task #{id}",
        status: :open,
        priority: 2,
        difficulty: 2,
        issue_type: :task,
        workspace_id: "ws-1",
        # bd-b5wyjd: the fixture is a *refined* issue, because that is what
        # every column but Backlog is about. Backlog tests pass `refined: false`
        # explicitly, which is also what a freshly created issue actually is.
        refined: true,
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

    test "an open issue with a live worker belongs to Running, not Ready" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          workers: [worker("bd-a", :working)]
        )

      assert ids(board.ready) == ["bd-b"]
      assert ids(board.running) == ["bd-a"]
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

    test "an open gating dependency surfaces as the card's reason" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — waiting on bd-z"}, _] =
               board.ready

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
            issue("bd-run", %{status: :in_progress, description: "Touches `lib/board.ex` too."})
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

  # bd-b5wyjd — Backlog is Ready minus the refinement flag. Same filter, same
  # card, different order: newest-first, because an unrefined pile is a
  # to-think-about list, not a queue.
  describe "backlog column" do
    test "an unrefined open issue sits in Backlog, not Ready" do
      board = derive(issues: [issue("bd-a", %{refined: false}), issue("bd-b")])

      assert ids(board.backlog) == ["bd-a"]
      assert ids(board.ready) == ["bd-b"]
    end

    test "an issue with no refined flag at all reads as unrefined" do
      board = derive(issues: [Map.delete(issue("bd-a"), :refined)])

      assert ids(board.backlog) == ["bd-a"]
      assert ids(board.ready) == []
    end

    test "Backlog is newest-first — provisional, not a priority queue" do
      board =
        derive(
          issues: [
            issue("bd-old", %{refined: false, priority: 1, created_at: @yesterday}),
            issue("bd-new", %{refined: false, priority: 3, created_at: @now})
          ]
        )

      assert ids(board.backlog) == ["bd-new", "bd-old"]
    end

    test "an unrefined issue with a live worker belongs to Running, not Backlog" do
      board =
        derive(
          issues: [issue("bd-a", %{refined: false})],
          workers: [worker("bd-a", :working)]
        )

      assert ids(board.backlog) == []
      assert ids(board.running) == ["bd-a"]
    end

    test "a closed issue is not in Backlog, whatever its flag says" do
      board =
        derive(
          issues: [issue("bd-a", %{refined: false, status: :closed, updated_at: @now})],
          now: @now
        )

      assert ids(board.backlog) == []
      assert ids(board.closed_today) == ["bd-a"]
    end

    test "epics are a rollup, so they never queue in Backlog either" do
      board =
        derive(issues: [issue("bd-a", %{refined: false, issue_type: :epic})])

      assert ids(board.backlog) == []
    end

    test "a refined but dependency-blocked card stays in Ready with its reason" do
      board =
        derive(
          issues: [issue("bd-a"), issue("bd-b")],
          blocked_by: %{"bd-a" => ["bd-z"]}
        )

      assert ids(board.backlog) == []

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — waiting on bd-z"}, _] =
               board.ready
    end

    test "an unrefined card is never the scheduler's promote, however free the slots" do
      board = derive(issues: [issue("bd-a", %{refined: false})], slots_total: 8)

      assert board.promote == nil
    end

    test "cards carry what a Backlog card is read by" do
      board =
        derive(
          issues: [
            issue("bd-a", %{refined: false, title: "think about caching"})
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
      assert [running] = board.running
      refute Map.has_key?(running, :assignee)
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

    test "the LiveView's :ready_order no longer feeds the queue" do
      board =
        derive(
          issues: [issue("bd-a", %{priority: 1}), issue("bd-b", %{priority: 3})],
          ready_order: ["bd-b"]
        )

      assert ids(board.ready) == ["bd-a", "bd-b"]
      assert board.promote == "bd-a"
    end
  end

  describe "empty/1" do
    test "is a full board shape a screen can render, reporting itself paused" do
      board = Arbiter.Board.Snapshot.empty(@now)

      assert board.backlog == []
      assert board.ready == []
      assert board.running == []
      assert board.waiting == []
      assert board.closed_today == []
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
            issue("bd-1", %{state: :active, status: :in_progress}),
            issue("bd-2", %{state: :active, status: :in_progress})
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
          issues: [issue("bd-1", %{state: :merging, status: :in_progress, pr_ref: "pr/1"})],
          workers: [worker("bd-1", :succeeded)]
        )

      assert board.slots_free == 2
    end

    test "a closed ticket frees its slot" do
      board =
        derive(
          slots_total: 2,
          issues: [issue("bd-1", %{state: :closed, status: :closed})],
          workers: [worker("bd-1", :succeeded)]
        )

      assert board.slots_free == 2
    end

    test "no free slot holds the queue and says so" do
      board =
        derive(
          slots_total: 1,
          issues: [issue("bd-a"), issue("bd-1", %{state: :active, status: :in_progress})],
          workers: [worker("bd-1", :working)]
        )

      assert board.promote == nil
      assert [%{state: :blocked, reason: "blocked — no free worker slot"}] = board.ready
    end
  end

  describe "running column" do
    test "shows what the worker is doing right now" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
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
                 step: :implement,
                 activity: "edit · scheduler.ex"
               }
             ] =
               board.running
    end

    test "a worker under review is still running, not waiting on you" do
      board = derive(workers: [worker("bd-a", :review_gate)])

      assert [%{id: "bd-a", activity: "in review"}] = board.running
      assert board.waiting == []
    end

    test "reviewer workers fold into the author's card instead of queueing twice" do
      board =
        derive(
          workers: [
            worker("bd-a", :review_gate),
            worker("bd-a#review", :working, %{meta: %{role: :reviewer, reviews: "bd-a"}})
          ]
        )

      assert ids(board.running) == ["bd-a"]
    end

    test "a ReviewGate fix-up round folds into the original issue's card, not a second one" do
      review_id = Arbiter.Worker.ReviewGate.reviewer_task_id("bd-a")

      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
          workers: [
            worker("bd-a", :review_gate),
            worker(review_id <> "#impl2", :working, %{
              meta: %{role: :implementer, revises: "bd-a"}
            })
          ]
        )

      assert [%{id: "bd-a", title: "Task bd-a", activity: "round 2 implementation"}] =
               board.running
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

      assert [%{id: "bd-a", activity: "round 2 review"}] = board.running
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

      assert [%{id: "bd-a", activity: "round 2 review"}] = board.running
    end

    test "an author-only card's provider is the author's own" do
      board = derive(workers: [worker("bd-a", :working, %{meta: %{provider: "codex"}})])

      assert [%{id: "bd-a", provider: "codex"}] = board.running
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

      assert [%{id: "bd-a", provider: "gemini"}] = board.running
    end

    test "an unknown provider is nil, not a guess" do
      board = derive(workers: [worker("bd-a", :working, %{meta: %{}})])

      assert [%{id: "bd-a", provider: nil}] = board.running
    end
  end

  describe "waiting column" do
    test "unions the parked and the merge-parked, longest wait first" do
      board =
        derive(
          # bd-741sid: an open PR is a Merging ticket, carded from its row.
          issues: [
            issue("bd-c", %{
              state: :merging,
              status: :in_progress,
              pr_ref: "!41",
              updated_at: @yesterday
            })
          ],
          workers: [
            worker("bd-a", :failed, %{
              step_started_at: ~U[2026-08-22 11:00:00Z],
              meta: %{stop_reason: %{category: :exited_without_done, summary: "review rejected"}}
            }),
            worker("bd-b", :question, %{
              step_started_at: @now,
              meta: %{await_reason: "needs a decision"}
            }),
            worker("bd-d", :working)
          ]
        )

      assert ids(board.waiting) == ["bd-c", "bd-a", "bd-b"]
      refute Map.has_key?(board, :needs_you)
      refute Map.has_key?(board, :merge_queue)
    end

    test "carries the halt reason of a parked worker and the merge fields of a merge-parked one" do
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
              status: :in_progress,
              updated_at: @yesterday,
              pr_ref: "!42",
              merger_url: "https://example.test/42",
              merger_status: %{"approved" => false}
            })
          ]
        )

      assert [
               %{id: "bd-b", mr_ref: "!42", merger_url: "https://example.test/42"},
               %{id: "bd-a", reason: "needs a decision"}
             ] = board.waiting

      assert [%{merger_status: %{approved: false}}, %{merger_status: nil}] = board.waiting
    end

    # bd-2mv3lx: `arb worker stop` on a worker (the documented pre-flight for `arb server deploy`) leaves the issue
    # `in_progress` with no live worker — a state that used to match none of
    # the five columns and vanished from the board entirely.
    # Explicitly `:active`: with a `pr_ref` and no `state`, the backfill rule
    # would read the row as Merging, whose card is the ticket's own
    # (bd-741sid) — no worker is expected there.
    # bd-8if9zt: a stopped run is the coordinator's to resume first, so the
    # card carries that attention without flagging the operator.
    test "an in_progress issue with no live worker still shows, as the coordinator's" do
      board =
        derive(
          issues: [
            issue("bd-a", %{
              status: :in_progress,
              state: :active,
              updated_at: @yesterday,
              pr_ref: "123"
            })
          ]
        )

      assert [%{id: "bd-a", reason: reason, mr_ref: "123", needs_you: false} = card] =
               board.waiting

      assert reason =~ "worker stopped"
      assert %{owner: :coordinator, cause: :run_crashed} = card.attention

      refute Enum.any?([board.backlog, board.ready, board.running, board.closed_today], fn col ->
               "bd-a" in ids(col)
             end)
    end

    test "an in_progress epic with no live worker is not treated as orphaned" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :in_progress, updated_at: @yesterday, issue_type: :epic})
          ]
        )

      assert board.waiting == []
    end

    test "an in_progress issue that just started dispatch is not flagged orphaned yet" do
      board = derive(issues: [issue("bd-a", %{status: :in_progress, updated_at: @now})])

      assert board.waiting == []
    end

    test "an in_progress issue with a live worker is not double-counted as orphaned" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress})],
          workers: [worker("bd-a", :question)]
        )

      assert ids(board.waiting) == ["bd-a"]
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
              status: :in_progress,
              state: :active,
              updated_at: @yesterday,
              pr_ref: "!293",
              review_park_reason: "resume_blocked",
              attention_cause: :resume_blocked
            })
          ],
          workers: [worker("bd-a", :succeeded)]
        )

      assert [%{id: "bd-a", reason: reason, mr_ref: "!293", needs_you: false} = card] =
               board.waiting

      assert reason =~ "resume_blocked"
      assert %{owner: :coordinator, cause: :resume_blocked} = card.attention

      refute Enum.any?([board.backlog, board.ready, board.running, board.closed_today], fn col ->
               "bd-a" in ids(col)
             end)
    end

    test "an in_progress issue whose only worker row succeeded and has no park reason still shows" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :in_progress, updated_at: @yesterday})
          ],
          workers: [worker("bd-a", :succeeded)]
        )

      assert [%{id: "bd-a", reason: reason}] = board.waiting
      assert reason =~ "worker stopped"
    end

    test "an in_progress issue with both a succeeded row and a live row is not double-counted" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress, updated_at: @yesterday})],
          workers: [
            worker("bd-a", :succeeded),
            worker("bd-a", :question)
          ]
        )

      assert ids(board.waiting) == ["bd-a"]
    end
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
        assert board.waiting == [] and board.running == [] and board.backlog == []
      end
    end

    test "a blocked queued ticket with a leftover author row stays in Ready, keeping its reason" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :queued})],
          workers: [worker("bd-a", :failed)],
          blocked_by: %{"bd-a" => ["bd-9"]}
        )

      assert [%{id: "bd-a", state: :blocked, reason: "blocked — waiting on bd-9"}] = board.ready
    end

    test "a backlog ticket with a leftover author row stays in Backlog" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :backlog, refined: false})],
          workers: [worker("bd-a", :succeeded)]
        )

      assert ids(board.backlog) == ["bd-a"]
    end

    test "a merging ticket is Waiting, even with its author row still running" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :merging, status: :in_progress, pr_ref: "!1"})],
          workers: [worker("bd-a", :working)]
        )

      assert [%{id: "bd-a", reason: nil}] = board.waiting
      assert board.running == []
    end

    test "a verifying ticket gets its one verification card, whatever rows linger" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :verifying, status: :awaiting_verification})],
          workers: [worker("bd-a", :failed)]
        )

      assert [%{id: "bd-a", status: :awaiting_verification}] = board.waiting
    end

    test "an in-progress ticket inside the dispatch grace is a Running dispatching card" do
      board = derive(issues: [issue("bd-a", %{state: :active, status: :in_progress})])

      # bd-741sid: no hand-off phase — a run not yet registered reads as its stage.
      assert [%{id: "bd-a", activity: "dispatching", phase: :implementing, agent_live: false}] =
               board.running

      assert board.waiting == []
    end

    test "a working author and a live fix pass render one Running card" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :active, status: :in_progress})],
          workers: [
            worker("bd-a", :working),
            worker("bd-a", :working, %{role: :fix_pass, registry_key: "bd-a:fix"})
          ]
        )

      assert [%{id: "bd-a", status: :working}] = board.running
    end
  end

  describe "waiting/running column invariant (bd-6lvc1r)" do
    # Whatever `classify_columns/2` says an issue's column is, `derive/1` must
    # produce exactly one card for it in that column — never zero (the bug),
    # never two.
    test "every issue classify_columns puts in :waiting or :running gets exactly one card" do
      issues = [
        issue("bd-running", %{status: :in_progress}),
        issue("bd-waiting-question", %{status: :in_progress}),
        issue("bd-waiting-failed", %{status: :in_progress}),
        issue("bd-waiting-merging", %{status: :in_progress, state: :merging, pr_ref: "!1"}),
        issue("bd-waiting-succeeded-only", %{status: :in_progress, updated_at: @yesterday}),
        issue("bd-waiting-orphaned", %{status: :in_progress, updated_at: @yesterday}),
        issue("bd-waiting-verification", %{status: :awaiting_verification})
      ]

      workers = [
        worker("bd-running", :working),
        worker("bd-waiting-question", :question),
        worker("bd-waiting-failed", :failed),
        worker("bd-waiting-merging", :succeeded),
        worker("bd-waiting-succeeded-only", :succeeded)
      ]

      board = derive(issues: issues, workers: workers)
      columns = Snapshot.classify_columns(issues, workers)

      for issue <- issues, Map.get(columns, issue.id) in [:waiting, :running] do
        count =
          Enum.count(board.waiting ++ board.running, &(&1.id == issue.id))

        assert count == 1, "expected exactly one card for #{issue.id}, got #{count}"
      end
    end
  end

  # bd-8jixav: a task's own waiting row and a subordinate `:fixpass` /
  # `:conflict` pass's failed row both belong in Waiting, so one task rendered
  # as two cards in the Waiting column — read at a glance as two different
  # stuck tickets.
  describe "waiting column, one card per task" do
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

      assert ids(board.waiting) == ["bd-a"]
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
                 mr_ref: "!42",
                 since: @yesterday
               }
             ] = board.waiting
    end

    test "a subordinate pass with no primary row still gets its own card" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ]
        )

      assert [%{id: "bd-a", status: :finished, outcome: :failed}] = board.waiting
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
                 needs_you: false,
                 attention: %{owner: :coordinator, cause: :run_asked_question},
                 collapsed_note: note
               }
             ] = board.waiting

      assert note =~ "fix pass"
      assert note =~ "failed"
    end

    # bd-741sid: an open PR's card is its Merging ticket's; a healthy pass
    # still registered under it adds nothing.
    test "a collapsed healthy row adds no note and no flag" do
      board =
        derive(
          issues: [issue("bd-a", %{state: :merging, status: :in_progress, pr_ref: "!42"})],
          workers: [
            worker("bd-a", :working, %{registry_key: "bd-a:fixpass", role: :fix_pass})
          ],
          watchdog_live: MapSet.new(["bd-a"])
        )

      assert [%{id: "bd-a", needs_you: false, collapsed_note: nil}] = board.waiting
    end

    test "distinct tasks are never collapsed" do
      board =
        derive(
          workers: [
            worker("bd-a", :question, %{step_started_at: @yesterday}),
            worker("bd-b", :question, %{step_started_at: @now})
          ]
        )

      assert ids(board.waiting) == ["bd-a", "bd-b"]
    end
  end

  # bd-8jixav: a Watchdog is a :temporary child — when it crashes it is gone
  # for good, silently, and the parked card looks exactly like a healthy one.
  # bd-741sid: no run stays resident on an open PR, so a Watchdog belongs to a
  # Merging ticket (see "Merging tickets") and a worker card never has one.
  describe "watchdog liveness on a waiting card" do
    test "a worker card reports liveness as unknown, not missing" do
      board =
        derive(
          workers: [
            worker("bd-a", :failed, %{}),
            worker("bd-b", :question, %{step_started_at: @yesterday})
          ],
          watchdog_live: MapSet.new()
        )

      assert [%{id: "bd-b", watchdog_alive: nil}, %{id: "bd-a", watchdog_alive: nil}] =
               board.waiting
    end

    test "an orphaned issue card carries the field too, as unknown" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress, updated_at: @yesterday})],
          watchdog_live: MapSet.new()
        )

      assert [%{id: "bd-a", watchdog_alive: nil}] = board.waiting
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
            status: :in_progress,
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
                 status: :merging,
                 reason: nil,
                 mr_ref: "!42",
                 merger_url: "https://example.test/42",
                 merger_status: %{status: :open, approved: false},
                 watchdog_alive: true,
                 needs_you: false,
                 collapsed_note: nil,
                 phase: :waiting_ci_merge,
                 agent_live: false,
                 since: @yesterday
               }
             ] = board.waiting
    end

    test "one whose Watchdog is gone says so, as the coordinator's" do
      board = derive(issues: [merging("bd-m")], watchdog_live: MapSet.new())

      assert [%{id: "bd-m", watchdog_alive: false, needs_you: false} = card] = board.waiting
      assert %{owner: :coordinator, cause: :merge_blocked} = card.attention
    end

    test "omitting the liveness input reports unknown rather than missing" do
      board = derive(issues: [merging("bd-m")])

      assert [%{id: "bd-m", watchdog_alive: nil, needs_you: false}] = board.waiting
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

      assert [%{id: "bd-m", status: :merging, needs_you: false, collapsed_note: note}] =
               board.waiting

      assert note =~ "failed"
    end
  end

  # The flag is not "which status" — it is "has the system run out of things to
  # try on its own", read off each Waiting card.
  defp flags(board), do: Map.new(board.waiting, &{&1.id, &1.needs_you})

  # bd-8if9zt (AC6): the flag is `attention.owner == :operator`. The
  # coordinator comes first — a card it can act on carries its attention but
  # does not flag the operator; child 7 (bd-8nlez1) adds the hand-off and the
  # limits that move an item to the operator.
  describe "the needs-you flag" do
    test "a worker that asked a question is the coordinator's to answer" do
      board = derive(workers: [worker("bd-a", :question, %{meta: %{await_reason: "which?"}})])

      assert flags(board) == %{"bd-a" => false}
      assert [%{attention: %{owner: :coordinator, cause: :run_asked_question}}] = board.waiting
    end

    test "a failed run with a follow-up round under way is not flagged" do
      board =
        derive(
          issues: [issue("bd-a", %{status: :in_progress, state: :active})],
          workers: [
            worker("bd-a", :failed),
            worker("bd-a#impl", :working, %{
              registry_key: "bd-a#impl",
              meta: %{role: :implementer, revises: "bd-a"}
            })
          ]
        )

      assert [%{id: "bd-a", needs_you: false, attention: nil}] = board.waiting
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
               Map.new(board.waiting, &{&1.id, &1.attention.owner})
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

      for card <- board.waiting, do: assert(card.attention.cause == :merge_blocked)
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
      assert [%{attention: %{owner: :coordinator, cause: :run_crashed}}] = board.waiting
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
      assert [%{attention: %{cause: :run_crashed}}] = board.waiting
    end
  end

  # bd-9so315 — merged-but-unverified tasks are the coordinator's: nothing else
  # will clear them, so they belong in Waiting alongside the other cards that
  # need a human.
  describe "awaiting-verification cards" do
    test "a parked task appears in Waiting with its age, as the coordinator's to verify" do
      board =
        derive(
          issues: [
            issue("bd-v", %{
              status: :awaiting_verification,
              awaiting_verification_at: @yesterday
            })
          ]
        )

      assert [card] = board.waiting
      assert card.id == "bd-v"
      assert card.status == :awaiting_verification
      assert card.needs_you == false
      assert %{owner: :coordinator, waiting_on: :verification} = card.attention
      assert card.since == @yesterday
      assert card.reason =~ "verif"
    end

    test "falls back to updated_at when the stamp predates the field" do
      board =
        derive(
          issues: [
            issue("bd-v", %{status: :awaiting_verification, updated_at: @yesterday})
          ]
        )

      assert [%{since: @yesterday}] = board.waiting
    end

    test "an open or closed task produces no awaiting card" do
      board =
        derive(issues: [issue("bd-a"), issue("bd-b", %{status: :closed, updated_at: @now})])

      assert board.waiting == []
    end

    test "a parked task is not also a Ready or Backlog card" do
      board = derive(issues: [issue("bd-v", %{status: :awaiting_verification})])

      assert ids(board.ready) == []
      assert ids(board.backlog) == []
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
            issue("bd-a", %{status: :closed, closed_at: ~U[2026-08-21 13:00:00Z]}),
            issue("bd-b", %{status: :closed, closed_at: ~U[2026-08-21 16:00:00Z]}),
            issue("bd-c", %{status: :closed, closed_at: ~U[2026-08-21 23:00:00Z]})
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
            issue("bd-a", %{status: :closed, closed_at: ~U[2026-08-21 11:00:00Z]}),
            issue("bd-b", %{status: :closed, closed_at: ~U[2026-08-22 11:00:00Z]})
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
              status: :closed,
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
            issue("bd-a", %{status: :closed, closed_at: nil, updated_at: ~U[2026-08-22 11:00:00Z]})
          ]
        )

      # Should include it because updated_at is within 24h
      assert ids(board.closed_today) == ["bd-a"]
    end

    test "excludes legacy issues with nil closed_at updated more than 24h ago" do
      board =
        derive(
          issues: [
            issue("bd-a", %{status: :closed, closed_at: nil, updated_at: ~U[2026-08-21 11:00:00Z]})
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
              status: :closed,
              closed_at: ~U[2026-08-22 11:00:00Z]
            }),
            issue("bd-a", %{status: :closed, closed_at: ~U[2026-08-22 10:00:00Z]})
          ]
        )

      assert ids(board.closed_today) == ["bd-a"]
    end

    test "excluding the epic leaves every other column, the counts and the slot math alone" do
      issues = [
        issue("bd-epic", %{issue_type: :epic, status: :closed, closed_at: @now}),
        issue("bd-ready"),
        issue("bd-backlog", %{refined: false}),
        issue("bd-run", %{status: :in_progress}),
        issue("bd-closed", %{status: :closed, closed_at: @now})
      ]

      board = derive(issues: issues, workers: [worker("bd-run", :working)])

      assert ids(board.backlog) == ["bd-backlog"]
      assert Enum.map(board.ready, & &1.card.id) == ["bd-ready"]
      assert ids(board.running) == ["bd-run"]
      assert board.waiting == []
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
  # look at — so it flags on the board the way `needs_you` does. The estimate
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
            issue("bd-backlog", %{refined: false}),
            issue("bd-ready"),
            issue("bd-run", %{status: :in_progress}),
            issue("bd-wait", %{status: :in_progress, updated_at: @yesterday})
          ],
          workers: [worker("bd-run", :working)],
          over_budget: ["bd-backlog", "bd-ready", "bd-run", "bd-wait"]
        )

      assert [%{over_budget: true}] = board.backlog
      assert [%{card: %{over_budget: true}}] = board.ready
      assert [%{over_budget: true}] = board.running
      assert [%{over_budget: true}] = board.waiting
    end

    test "a closed card never flags, even if its id is in the set" do
      board =
        derive(
          issues: [issue("bd-closed", %{status: :closed, closed_at: @now})],
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
            issue("bd-b", %{status: :closed, closed_at: @now})
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
      board =
        derive(
          issues: [
            issue("bd-epic", %{issue_type: :epic, title: "Epic"}),
            issue("bd-backlog", %{refined: false}),
            issue("bd-run", %{status: :in_progress}),
            issue("bd-wait", %{status: :in_progress, updated_at: @yesterday}),
            issue("bd-closed", %{status: :closed, closed_at: @now})
          ],
          workers: [worker("bd-run", :working)],
          parent_of: [
            parent_of("bd-epic", "bd-backlog"),
            parent_of("bd-epic", "bd-run"),
            parent_of("bd-epic", "bd-wait"),
            parent_of("bd-epic", "bd-closed")
          ]
        )

      assert [%{parent: %{id: "bd-epic"}}] = board.backlog
      assert [%{parent: %{id: "bd-epic"}}] = board.running
      assert [%{parent: %{id: "bd-epic"}}] = board.waiting
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
      assert Snapshot.classify_columns([issue("bd-a", %{refined: false})]) == %{
               "bd-a" => :backlog
             }
    end

    test "a refined open issue lands in ready" do
      assert Snapshot.classify_columns([issue("bd-a", %{refined: true})]) == %{"bd-a" => :ready}
    end

    test "an in-progress issue with a live running worker lands in running" do
      issues = [issue("bd-a", %{status: :in_progress})]
      workers = [worker("bd-a", :working)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :running}
    end

    test "a worker's presence outranks a stale open status, same as the board" do
      issues = [issue("bd-a", %{status: :open})]
      workers = [worker("bd-a", :starting)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :running}
    end

    test "an in-progress issue with a parked worker lands in waiting" do
      issues = [issue("bd-a", %{status: :in_progress})]
      workers = [worker("bd-a", :failed)]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :waiting}
    end

    test "an in-progress issue with no worker at all lands in waiting" do
      issues = [issue("bd-a", %{status: :in_progress})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :waiting}
    end

    test "an awaiting_verification issue lands in waiting" do
      issues = [issue("bd-a", %{status: :awaiting_verification})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :waiting}
    end

    test "a closed issue lands in closed" do
      issues = [issue("bd-a", %{status: :closed})]

      assert Snapshot.classify_columns(issues) == %{"bd-a" => :closed}
    end

    test "a reviewer/implementer worker on the same task does not count as running" do
      issues = [issue("bd-a", %{status: :in_progress})]
      workers = [worker("bd-a", :working, %{meta: %{role: :reviewer}})]

      assert Snapshot.classify_columns(issues, workers) == %{"bd-a" => :waiting}
    end

    test "classifies a full mix of issues independently" do
      issues = [
        issue("bd-backlog", %{refined: false}),
        issue("bd-ready", %{refined: true}),
        issue("bd-running", %{status: :in_progress}),
        issue("bd-waiting", %{status: :in_progress}),
        issue("bd-closed", %{status: :closed})
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
