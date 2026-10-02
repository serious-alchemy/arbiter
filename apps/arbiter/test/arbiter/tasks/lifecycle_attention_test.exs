defmodule Arbiter.Tasks.LifecycleAttentionTest do
  @moduledoc """
  bd-8if9zt (ticket lifecycle 6/13, AC4): `Lifecycle.view/2` fills
  `attention: %{owner, waiting_on, reason}` from the ticket's stored cause,
  its state, its latest runs and its PR, through the owner table in
  `Arbiter.Tasks.Lifecycle.Attention`. Pure: every input is a plain map.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Lifecycle
  alias Arbiter.Tasks.Lifecycle.Attention

  @now ~U[2026-09-27 12:00:00Z]
  @long_ago ~U[2026-09-27 11:00:00Z]

  defp ticket(state, attrs \\ %{}) do
    Map.merge(
      %{
        id: "bd-t",
        state: state,
        issue_type: :feature,
        updated_at: @long_ago,
        created_at: @long_ago
      },
      attrs
    )
  end

  defp run(fields),
    do: Map.merge(%{task_id: "bd-t", meta: %{}, waiting_on: nil, outcome: nil}, fields)

  defp view(ticket, ctx \\ %{}), do: Lifecycle.view(ticket, Map.put_new(ctx, :now, @now))

  # The state a stored cause is raised in, and the PR facts that select the
  # table row's `when`.
  defp state_for(:pr_closed), do: :active
  defp state_for(:run_crashed), do: :active
  defp state_for(:run_asked_question), do: :active
  defp state_for(:merge_blocked), do: :merging
  defp state_for(:awaiting_manual_merge), do: :merging
  defp state_for(:awaiting_verification), do: :verifying
  defp state_for(_park_reason), do: :active

  defp ctx_for(%{when: :approval}),
    do: %{
      merger_status: %{status: :open, approved: true, block_reason: :needs_nonauthor_approval}
    }

  defp ctx_for(_row), do: %{}

  describe "the owner table — one case per ticket-scoped row" do
    for row <- Attention.table() do
      @row row
      test "#{row.cause}#{if row.when, do: " (#{row.when})"} → #{row.owner} / #{row.waiting_on}" do
        row = @row
        since = ~U[2026-09-27 10:00:00Z]

        stored =
          ticket(state_for(row.cause), %{attention_cause: row.cause, attention_since: since})

        assert %{attention: attention} = view(stored, ctx_for(row))

        assert attention == %{
                 owner: row.owner,
                 waiting_on: row.waiting_on,
                 reason: row.reason,
                 cause: row.cause,
                 since: since,
                 note: nil,
                 owner_since: nil
               }
      end
    end

    test "the table covers every cause a ticket can store" do
      assert Enum.sort(Enum.uniq(Enum.map(Attention.table(), & &1.cause))) ==
               Enum.sort(Attention.causes())

      for park <- Arbiter.Tasks.ReviewPark.park_reasons(), do: assert(park in Attention.causes())
    end

    test "only the approval-blocked merge and the manual merge are the operator's" do
      operator = for r <- Attention.table(), r.owner == :operator, do: {r.cause, r.when}
      assert Enum.sort(operator) == [{:awaiting_manual_merge, nil}, {:merge_blocked, :approval}]
    end

    # bd-8nlez1: a hand-off, a hand-back or an expired limit moves the owner
    # of the cause it was made for, and only that cause.
    test "a moved owner applies to its own cause only" do
      moved = ~U[2026-09-27 11:00:00Z]

      handed =
        ticket(:active, %{
          attention_cause: :run_crashed,
          attention_owner: :operator,
          attention_owner_cause: :run_crashed,
          attention_note: "needs the prod key",
          attention_owner_since: moved
        })

      assert %{owner: :operator, note: "needs the prod key", owner_since: ^moved} =
               view(handed).attention

      stale = %{handed | attention_cause: :pr_closed}
      assert %{owner: :coordinator, note: nil, owner_since: nil} = view(stale).attention
    end

    test "a stored detail is the reason" do
      stored =
        ticket(:active, %{attention_cause: :pr_closed, attention_detail: "#42 closed by @someone"})

      assert %{reason: "#42 closed by @someone"} = view(stored).attention
    end
  end

  describe "derived attention — no cause stored" do
    test "a verifying ticket waits on its verification" do
      assert %{owner: :coordinator, waiting_on: :verification, cause: :awaiting_verification} =
               view(ticket(:verifying)).attention
    end

    test "an active ticket whose primary run asked a question" do
      runs = [run(%{state: :waiting, waiting_on: :question})]

      assert %{owner: :coordinator, waiting_on: :answer, cause: :run_asked_question} =
               view(ticket(:active), %{runs: runs}).attention
    end

    test "an active ticket whose run finished failed, with nothing else running" do
      runs = [run(%{state: :finished, outcome: :failed})]

      assert %{owner: :coordinator, waiting_on: :resume, cause: :run_crashed} =
               view(ticket(:active), %{runs: runs}).attention
    end

    test "a failed run with a follow-up round under way needs no one's attention" do
      runs = [
        run(%{state: :finished, outcome: :failed}),
        run(%{
          task_id: "bd-t#impl",
          state: :working,
          meta: %{role: :implementer, revises: "bd-t"}
        })
      ]

      assert view(ticket(:active), %{runs: runs}).attention == nil
    end

    test "an active ticket with no run at all past the dispatch grace" do
      assert %{cause: :run_crashed, owner: :coordinator} =
               view(ticket(:active), %{runs: []}).attention
    end

    test "a run held for quota is not a crash, whether its worker row is failed or gone" do
      failed = [run(%{state: :finished, outcome: :failed})]

      assert view(ticket(:active), %{runs: failed, held: true}).attention == nil
      assert view(ticket(:active), %{runs: [], held: true}).attention == nil
    end

    test "a crash with no hold still raises run_crashed" do
      failed = [run(%{state: :finished, outcome: :failed})]

      assert %{cause: :run_crashed} =
               view(ticket(:active), %{runs: failed, held: false}).attention

      assert %{cause: :run_crashed} = view(ticket(:active), %{runs: [], held: false}).attention
    end

    test "an active ticket with no runs read is not called orphaned" do
      assert view(ticket(:active)).attention == nil
    end

    test "a working run needs no attention" do
      assert view(ticket(:active), %{runs: [run(%{state: :working})]}).attention == nil
    end

    test "a merging ticket blocked by a conflict is the coordinator's" do
      ctx = %{merger_status: %{status: :open, approved: true, block_reason: :conflict}}

      assert %{owner: :coordinator, waiting_on: :merge_block, cause: :merge_blocked} =
               view(ticket(:merging), ctx).attention
    end

    test "a merging ticket that needs a non-author approval is the operator's" do
      ctx = %{
        merger_status: %{status: :open, approved: true, block_reason: :needs_nonauthor_approval}
      }

      assert %{owner: :operator, waiting_on: :approval} = view(ticket(:merging), ctx).attention
    end

    test "a merging ticket the Watchdog resolves by itself needs no attention" do
      for block <- [:behind_base, :ci_failed] do
        ctx = %{merger_status: %{status: :open, approved: true, block_reason: block}}
        assert view(ticket(:merging), ctx).attention == nil
      end
    end

    test "a merging ticket whose Watchdog is gone is the coordinator's" do
      assert %{owner: :coordinator, cause: :merge_blocked} =
               view(ticket(:merging), %{watchdog_alive: false}).attention
    end

    test "queued, backlog and closed tickets never need attention, whatever is stored" do
      for state <- [:backlog, :queued, :closed] do
        assert view(ticket(state, %{attention_cause: :pr_closed})).attention == nil
      end
    end

    test "a stored cause outranks what the runs say" do
      stored = ticket(:active, %{attention_cause: :inconclusive})
      runs = [run(%{state: :finished, outcome: :failed})]

      assert %{cause: :inconclusive, waiting_on: :review_decision} =
               view(stored, %{runs: runs}).attention
    end
  end
end
