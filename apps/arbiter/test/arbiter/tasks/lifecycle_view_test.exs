defmodule Arbiter.Tasks.LifecycleViewTest do
  @moduledoc """
  bd-6zapbl (ticket lifecycle 2/13): `Lifecycle.view/2`, the one projection
  every surface reads a ticket's column and step from, and the interim
  five-column board mapping on top of it. Pure: every input is a plain map.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Lifecycle

  @now ~U[2026-09-27 12:00:00Z]
  @long_ago ~U[2026-09-27 11:00:00Z]

  defp ticket(state, attrs \\ %{}) do
    Map.merge(
      %{
        id: "bd-t",
        state: state,
        issue_type: :task,
        updated_at: @long_ago,
        created_at: @long_ago
      },
      attrs
    )
  end

  defp run(status, attrs \\ %{}) do
    Map.merge(%{task_id: "bd-t", status: status, meta: %{}}, attrs)
  end

  defp view(ticket, ctx \\ %{}), do: Lifecycle.view(ticket, Map.put_new(ctx, :now, @now))

  describe "view/2 — the column for every stored state" do
    test "backlog → :backlog" do
      assert %{column: :backlog, step: nil, blocked_by: [], attention: nil} =
               view(ticket(:backlog))
    end

    test "queued with no blocker → :ready" do
      assert %{column: :ready, blocked_by: []} = view(ticket(:queued))
    end

    test "queued with an unsatisfied blocker → :blocked, naming it" do
      assert %{column: :blocked, blocked_by: ["bd-9"]} =
               view(ticket(:queued), %{blocked_by: ["bd-9"]})
    end

    test "active → :in_progress" do
      assert %{column: :in_progress} = view(ticket(:active))
    end

    test "merging → :merging" do
      assert %{column: :merging} = view(ticket(:merging))
    end

    test "verifying → :verifying" do
      assert %{column: :verifying, step: nil} = view(ticket(:verifying))
    end

    test "closed → :closed" do
      assert %{column: :closed, step: nil} = view(ticket(:closed))
    end

    test "attention is nil in every state until the attention child fills it" do
      for state <- Lifecycle.states() do
        assert view(ticket(state)).attention == nil
      end
    end

    test "a blocker only gates a queued ticket" do
      assert %{column: :in_progress} = view(ticket(:active), %{blocked_by: ["bd-9"]})
    end
  end

  describe "view/2 — the legacy columns stand in for a missing state" do
    test "an open refined row is queued, an open unrefined one backlog" do
      assert %{column: :ready} = view(%{id: "bd-t", status: :open, refined: true})
      assert %{column: :backlog} = view(%{id: "bd-t", status: :open})
    end

    test "an in_progress row is in progress, or merging with a PR on record" do
      assert %{column: :in_progress} = view(%{id: "bd-t", status: :in_progress})
      assert %{column: :merging} = view(%{id: "bd-t", status: :in_progress, pr_ref: "!1"})
    end

    test "awaiting_verification is verifying" do
      assert %{column: :verifying} = view(%{id: "bd-t", status: :awaiting_verification})
    end
  end

  describe "view/2 — runs never override the stored state, except a live one lagging it" do
    test "a queued ticket with a leftover completed or failed author row stays queued" do
      for status <- [:completed, :failed] do
        assert %{column: :ready} = view(ticket(:queued), %{runs: [run(status)]})

        assert %{column: :blocked} =
                 view(ticket(:queued), %{runs: [run(status)], blocked_by: ["bd-9"]})
      end
    end

    test "a live author run on a queued ticket reads as in progress (the write lags the run)" do
      assert %{column: :in_progress} = view(ticket(:queued), %{runs: [run(:running)]})
      assert %{column: :in_progress} = view(ticket(:backlog), %{runs: [run(:awaiting)]})
    end

    test "a live run never reopens a closed or verifying ticket" do
      assert %{column: :closed} = view(ticket(:closed), %{runs: [run(:running)]})
      assert %{column: :verifying} = view(ticket(:verifying), %{runs: [run(:running)]})
    end

    test "a ticket with no state at all is claimed by any non-completed author row" do
      assert %{column: :in_progress} = view(%{id: "bd-t"}, %{runs: [run(:failed)]})
      assert %{column: nil} = view(%{id: "bd-t"}, %{runs: [run(:completed)]})
      assert %{column: nil} = view(%{id: "bd-t"})
    end
  end

  describe "view/2 — the step of an in-progress ticket" do
    test "implementing: the author's own agent is live" do
      assert %{step: :implementing} =
               view(ticket(:active), %{runs: [run(:running, %{agent_live: true})]})
    end

    test "implementing: nothing more specific is known (no run yet)" do
      assert %{step: :implementing} = view(ticket(:active))
    end

    test "in_review: a reviewer is reading the diff" do
      author = run(:awaiting_review_gate, %{agent_live: false})

      reviewer =
        run(:running, %{
          task_id: "bd-t#review",
          agent_live: true,
          meta: %{role: :reviewer, reviews: "bd-t"}
        })

      assert %{step: :in_review} = view(ticket(:active), %{runs: [author, reviewer]})
    end

    test "addressing_review: an implementer round is applying findings" do
      author = run(:awaiting_review_gate, %{agent_live: false})

      implementer =
        run(:running, %{
          task_id: "bd-t#review#impl1",
          agent_live: true,
          meta: %{role: :implementer, revises: "bd-t"}
        })

      assert %{step: :addressing_review} = view(ticket(:active), %{runs: [author, implementer]})
    end

    test "fixing_ci: a CI fix pass is live" do
      author = run(:awaiting_review, %{agent_live: false})
      fix = run(:running, %{registry_key: "bd-t:fix", role: :fix_pass, agent_live: true})

      assert %{step: :fixing_ci} = view(ticket(:active), %{runs: [author, fix]})
    end

    test "resolving_conflict: a conflict resolver is live" do
      author = run(:awaiting_review, %{agent_live: false})

      resolver =
        run(:running, %{registry_key: "bd-t:conflict", role: :conflict_resolver, agent_live: true})

      assert %{step: :resolving_conflict} = view(ticket(:active), %{runs: [author, resolver]})
    end

    test "a subordinate pass with its author gone still names the step" do
      fix = run(:running, %{registry_key: "bd-t:fix", role: :fix_pass, agent_live: true})
      assert %{step: :fixing_ci} = view(ticket(:active), %{runs: [fix]})
    end
  end

  describe "view/2 — the step of a merging ticket" do
    defp merging_with(status, extra \\ %{}) do
      view(ticket(:merging, extra), %{merger_status: status})
    end

    test "waiting_ci: CI is still running" do
      assert %{step: :waiting_ci} = merging_with(%{status: :open, pipeline: :running})
      assert %{step: :waiting_ci} = merging_with(%{status: :open, pipeline: :pending})
      assert %{step: :waiting_ci} = merging_with(%{status: :open, pipeline: :not_started})
    end

    test "waiting_ci: the deferred merge on record is waiting on CI" do
      assert %{step: :waiting_ci} =
               merging_with(nil, %{pending_merge: %{"reason" => "ci_pending"}})
    end

    test "in_merge_queue: green, nothing blocking" do
      assert %{step: :in_merge_queue} =
               merging_with(%{status: :open, approved: true, pipeline: :success})

      assert %{step: :in_merge_queue} = merging_with(nil)
    end

    test "behind_base: the branch needs updating" do
      assert %{step: :behind_base} =
               merging_with(%{status: :open, approved: true, block_reason: :behind_base})
    end

    test "merge_blocked: a conflict, red CI, a draft, or an approved PR the forge refuses" do
      for reason <- [:conflict, :ci_failed, :draft] do
        assert %{step: :merge_blocked} = merging_with(%{status: :open, block_reason: reason})
      end

      assert %{step: :merge_blocked} =
               merging_with(%{status: :open, approved: true, block_reason: :needs_approval})
    end

    test "an unapproved PR awaiting its review is not merge_blocked" do
      assert %{step: :in_merge_queue} =
               merging_with(%{status: :open, approved: false, block_reason: :needs_approval})
    end

    # bd-741sid: no run holds it — the ticket's Watchdog records the poll on
    # the row, string-keyed as it reads back from the database.
    test "the merger status defaults to the poll recorded on the ticket" do
      recorded = %{"status" => "open", "pipeline" => "running"}

      assert %{step: :waiting_ci} = view(ticket(:merging, %{merger_status: recorded}))
    end
  end

  describe "blocker_satisfied?/1 — verifying unblocks dependents" do
    test "verifying and closed satisfy; every other state does not" do
      assert Lifecycle.blocker_satisfied?(:verifying)
      assert Lifecycle.blocker_satisfied?(:closed)

      for state <- [:backlog, :queued, :active, :merging, nil] do
        refute Lifecycle.blocker_satisfied?(state)
      end
    end

    test "reads a ticket's state, falling back to its legacy status" do
      assert Lifecycle.blocker_satisfied?(%{state: :verifying})
      assert Lifecycle.blocker_satisfied?(%{status: :awaiting_verification})
      refute Lifecycle.blocker_satisfied?(%{status: :in_progress})
    end
  end

  describe "board_column/2 — the interim five-column mapping" do
    defp col(ticket, ctx \\ %{}), do: Lifecycle.board_column(ticket, Map.put_new(ctx, :now, @now))

    test "backlog → Backlog; blocked and ready → Ready; closed → Closed" do
      assert col(ticket(:backlog)) == :backlog
      assert col(ticket(:queued)) == :ready
      assert col(ticket(:queued), %{blocked_by: ["bd-9"]}) == :ready
      assert col(ticket(:closed)) == :closed
    end

    test "merging and verifying → Waiting" do
      assert col(ticket(:merging)) == :waiting
      assert col(ticket(:verifying)) == :waiting
      assert col(ticket(:merging), %{runs: [run(:running)]}) == :waiting
    end

    test "in progress with a live author → Running" do
      for status <- [:idle, :resuming, :running, :awaiting_review_gate] do
        assert col(ticket(:active), %{runs: [run(status)]}) == :running
      end
    end

    test "in progress whose author is failed or awaiting → Waiting (today's needs-you cases)" do
      for status <- [:awaiting, :failed, :awaiting_review] do
        assert col(ticket(:active), %{runs: [run(status)]}) == :waiting
      end
    end

    test "the primary author run decides, not a subordinate pass sharing its id" do
      parked = run(:awaiting_review, %{role: nil})
      fix = run(:running, %{registry_key: "bd-t:fix", role: :fix_pass, meta: %{role: :fix_pass}})
      assert col(ticket(:active), %{runs: [parked, fix]}) == :waiting

      working = run(:running, %{role: nil})
      failed_fix = run(:failed, %{registry_key: "bd-t:fix", role: :fix_pass})
      assert col(ticket(:active), %{runs: [working, failed_fix]}) == :running
    end

    test "with only subordinate passes left, they decide" do
      fix = run(:running, %{registry_key: "bd-t:fix", role: :fix_pass})
      assert col(ticket(:active), %{runs: [fix]}) == :running
      assert col(ticket(:active), %{runs: [%{fix | status: :failed}]}) == :waiting
    end

    test "in progress with no worker: Running inside the dispatch grace, Waiting past it" do
      assert col(ticket(:active, %{updated_at: @now})) == :running
      assert col(ticket(:active)) == :waiting
      assert col(ticket(:active), %{runs: [run(:completed)]}) == :waiting
    end

    test "a workerless in-progress epic never reads as orphaned" do
      assert col(ticket(:active, %{issue_type: :epic})) == :running
    end

    test "a ticket with no state and no run has no column" do
      assert col(%{id: "bd-t"}) == nil
    end
  end
end
