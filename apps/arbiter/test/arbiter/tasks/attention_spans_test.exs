defmodule Arbiter.Tasks.AttentionSpansTest do
  @moduledoc """
  bd-cq1wsp (reports design v2 §4.3): `ticket_attention_spans` — one row per
  stretch of a ticket's attention, opened when a cause is raised (or a derived
  one is first seen by the sweep) and closed when it clears, with its owner
  moves; plus the one-off backfill from the paper trail and typed escalations.
  """
  use Arbiter.DataCase, async: false

  import Arbiter.LifecycleFixtures

  alias Arbiter.Messages.{Escalation, Message}
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Attention, AttentionSpan, AttentionSpanBackfill, AttentionSpans}
  alias Arbiter.Tasks.{AttentionSweep, Issue, Workspace}
  alias Arbiter.Worker.Registry, as: PRegistry
  alias Arbiter.Worker.Watchdog

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "spans-#{System.unique_integer([:positive])}", prefix: "sp"})

    {:ok, task} = Ash.create(Issue, %{title: "spans", workspace_id: ws.id, issue_type: :feature})

    %{ws: ws, task: put_state!(task, :active)}
  end

  defp spans(task), do: AttentionSpans.for_ticket(task.id)

  defp reload(task), do: Ash.get!(Issue, task.id)

  # A process registered where `Watchdog.alive?/1` looks, so a merging
  # ticket's derived `merge_blocked` ("no Watchdog is polling its PR") goes.
  defp fake_watchdog(task) do
    name = PRegistry.via_tuple(task.id <> Watchdog.registry_suffix())

    start_supervised!(%{
      id: {:fake_watchdog, task.id},
      start: {Agent, :start_link, [fn -> nil end, [name: name]]}
    })
  end

  describe "stored causes" do
    test "a raise opens a span; raising it again keeps the one span", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed, "boom")
      issue = reload(ctx.task)

      assert [span] = spans(ctx.task)
      assert span.cause == "run_crashed"
      assert span.owner == :coordinator
      assert span.owner_at_close == :coordinator
      assert span.derived == false
      assert span.source == :live
      assert span.workspace_id == ctx.ws.id
      assert DateTime.compare(span.opened_at, issue.attention_since) == :eq
      assert span.cleared_at == nil
      assert span.cleared_by == nil

      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed, "boom again")
      assert [%{id: same_id, cleared_at: nil}] = spans(ctx.task)
      assert same_id == span.id
    end

    test "a different cause closes the first span as replaced and opens its own", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed)
      {:ok, _} = Attention.raise_cause(ctx.task.id, :tracker_sync_failed)

      assert [first, second] = spans(ctx.task)
      assert first.cause == "run_crashed"
      assert first.cleared_by == :replaced
      assert %DateTime{} = first.cleared_at
      assert second.cause == "tracker_sync_failed"
      assert second.cleared_at == nil
    end

    test "a transition closes the span", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed)
      _ = put_state!(reload(ctx.task), :queued)

      assert [%{cleared_by: :transition, cleared_at: %DateTime{}}] = spans(ctx.task)
    end

    test "a run restart closes the span as a resume", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed)
      {:ok, _} = Attention.clear(ctx.task.id, :run_restarted)

      assert [%{cleared_by: :resume, cleared_at: %DateTime{}}] = spans(ctx.task)
    end

    test "clearing a ReviewGate park closes the span as a clear", ctx do
      {:ok, parked} =
        Ash.update(reload(ctx.task), %{cause: :reviewer_timeout}, action: :park_review)

      assert [%{cause: "reviewer_timeout", cleared_at: nil}] = spans(ctx.task)

      {:ok, _} = Ash.update(parked, %{}, action: :clear_review_park)
      assert [%{cleared_by: :clear}] = spans(ctx.task)
    end

    test "entering verification opens an awaiting_verification span", ctx do
      verifying = put_state!(reload(ctx.task), :verifying)

      assert [span] = spans(ctx.task)
      assert span.cause == "awaiting_verification"
      assert DateTime.compare(span.opened_at, verifying.attention_since) == :eq

      _ = put_state!(verifying, :closed)
      assert [%{cleared_by: :transition}] = spans(ctx.task)
    end

    test "a write that leaves the attention alone writes nothing", ctx do
      {:ok, _} = Ash.update(reload(ctx.task), %{notes: "hello"}, action: :update)
      assert spans(ctx.task) == []
    end
  end

  describe "owner moves" do
    test "a hand-off and a hand-back move the open span's owner", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "needs a key", workers: [])
      handed = reload(ctx.task)

      assert [span] = spans(ctx.task)
      assert span.owner == :coordinator
      assert span.owner_at_close == :operator
      assert DateTime.compare(span.owner_changed_at, handed.attention_owner_since) == :eq

      {:ok, _} = Attention.hand_off(ctx.task.id, :coordinator, nil, workers: [])
      assert [%{owner: :coordinator, owner_at_close: :coordinator}] = spans(ctx.task)

      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "still stuck", workers: [])
      _ = put_state!(reload(ctx.task), :queued)

      assert [%{owner_at_close: :operator, cleared_by: :transition}] = spans(ctx.task)
    end

    test "a sweep promotion moves the span to the operator", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed)
      later = DateTime.add(DateTime.utc_now(), 5 * 3600, :second)

      assert %{promoted: [_]} = AttentionSweep.run(now: later, workers: [])

      assert [span] = spans(ctx.task)
      assert span.owner == :coordinator
      assert span.owner_at_close == :operator
      assert %DateTime{} = span.owner_changed_at
      assert span.cleared_at == nil
    end
  end

  describe "derived causes (AttentionSweep)" do
    test "a derived merge_blocked opens a derived span on first sight and closes when it clears",
         ctx do
      merging = put_state!(reload(ctx.task), :merging)
      assert merging.attention_cause == nil
      t0 = DateTime.utc_now()

      AttentionSweep.run(now: t0, workers: [])

      assert [span] = spans(ctx.task)
      assert span.cause == "merge_blocked"
      assert span.derived == true
      assert span.owner == :coordinator
      assert DateTime.compare(span.opened_at, t0) == :eq
      assert span.cleared_at == nil

      # Seen again — by this sweep or a fresh one after a restart — it is the
      # same span.
      AttentionSweep.run(now: DateTime.add(t0, 60, :second), workers: [])
      AttentionSweep.run(now: DateTime.add(t0, 120, :second), workers: [], seen: %{})
      assert [%{id: id, cleared_at: nil}] = spans(ctx.task)
      assert id == span.id

      fake_watchdog(ctx.task)
      t1 = DateTime.add(t0, 180, :second)
      AttentionSweep.run(now: t1, workers: [])

      assert [closed] = spans(ctx.task)
      assert closed.derived == true
      assert closed.cleared_by == :sweep_gone
      assert DateTime.compare(closed.cleared_at, t1) == :eq
    end

    test "a transition closes a derived span at once", ctx do
      merging = put_state!(reload(ctx.task), :merging)
      AttentionSweep.run(workers: [])
      assert [%{derived: true, cleared_at: nil}] = spans(ctx.task)

      _ = put_state!(merging, :active)
      assert [%{derived: true, cleared_by: :transition}] = spans(ctx.task)
    end

    test "handing off a derived item moves its span's owner", ctx do
      _ = put_state!(reload(ctx.task), :merging)
      AttentionSweep.run(workers: [])

      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "needs a human", workers: [])
      assert [%{derived: true, owner: :coordinator, owner_at_close: :operator}] = spans(ctx.task)

      # The operator now owns it; the sweep still tracks it, and does not close it.
      AttentionSweep.run(workers: [])
      assert [%{cleared_at: nil, owner_at_close: :operator}] = spans(ctx.task)
    end

    test "a sweep scoped to some tickets leaves other tickets' derived spans open", ctx do
      _ = put_state!(reload(ctx.task), :merging)
      AttentionSweep.run(workers: [])

      {:ok, other} = Ash.create(Issue, %{title: "other", workspace_id: ctx.ws.id})
      AttentionSweep.run(workers: [], issues: [put_state!(other, :active)])

      assert [%{cleared_at: nil}] = spans(ctx.task)
    end
  end

  describe "backfill" do
    defp wipe_spans, do: Repo.delete_all(AttentionSpan)

    test "rebuilds stored spans and owner moves from the paper trail, idempotently", ctx do
      {:ok, _} = Attention.raise_cause(ctx.task.id, :run_crashed)
      {:ok, _} = Attention.hand_off(ctx.task.id, :operator, "stuck", workers: [])
      _ = put_state!(reload(ctx.task), :queued)
      [live] = spans(ctx.task)

      # Live capture already has it: the backfill adds nothing.
      assert %{inserted: 0} = AttentionSpanBackfill.backfill(apply?: true)

      wipe_spans()
      assert %{inserted: 0, planned: planned} = AttentionSpanBackfill.backfill([])
      assert planned >= 1
      assert spans(ctx.task) == []

      assert %{inserted: inserted} = AttentionSpanBackfill.backfill(apply?: true)
      assert inserted == planned

      assert [span] = spans(ctx.task)
      assert span.source == :backfill
      assert span.cause == "run_crashed"
      assert span.owner == :coordinator
      assert span.owner_at_close == :operator
      assert span.cleared_by == :transition
      assert span.workspace_id == ctx.ws.id
      assert DateTime.compare(span.opened_at, live.opened_at) == :eq
      assert DateTime.compare(span.owner_changed_at, live.owner_changed_at) == :eq
      assert DateTime.compare(span.cleared_at, live.cleared_at) != :lt

      # Idempotent.
      assert %{inserted: 0} = AttentionSpanBackfill.backfill(apply?: true)
      assert [_] = spans(ctx.task)
    end

    test "reads a legacy ReviewGate park from review_park_reason", ctx do
      parked_at = ~U[2026-09-16 10:00:00.000001Z]
      cleared_at = ~U[2026-09-16 11:00:00.000002Z]

      insert_version(ctx.task.id, "park_review", parked_at, %{
        "review_park_reason" => "reviewer_timeout",
        "review_parked_at" => DateTime.to_iso8601(parked_at)
      })

      insert_version(ctx.task.id, "clear_review_park", cleared_at, %{
        "review_park_reason" => nil,
        "review_parked_at" => nil
      })

      # Before the window: ignored.
      insert_version(ctx.task.id, "park_review", ~U[2026-09-01 00:00:00Z], %{
        "review_park_reason" => "inconclusive",
        "review_parked_at" => "2026-09-01T00:00:00Z"
      })

      AttentionSpanBackfill.backfill(apply?: true)

      assert [span] = spans(ctx.task)
      assert span.cause == "reviewer_timeout"
      assert DateTime.compare(span.opened_at, parked_at) == :eq
      assert DateTime.compare(span.cleared_at, cleared_at) == :eq
      assert span.cleared_by == :clear

      assert %{inserted: 0} = AttentionSpanBackfill.backfill(apply?: true)
    end

    test "a typed escalation the paper trail has no cause for becomes a span", ctx do
      queued = put_state!(reload(ctx.task), :queued)

      {:ok, msg} =
        Escalation.post(%{
          kind: :merge_conflict,
          task_ref: queued.id,
          workspace_id: ctx.ws.id,
          subject: "conflict",
          body: "the PR conflicts"
        })

      # A queued ticket takes no cause, so only the escalation recorded it.
      assert reload(ctx.task).attention_cause == nil
      Message.resolve_ticket_escalations(queued.id)

      AttentionSpanBackfill.backfill(apply?: true)

      assert [span] = spans(ctx.task)
      assert span.cause == "merge_blocked"
      assert span.source == :backfill
      assert DateTime.compare(span.opened_at, msg.inserted_at) == :eq
      assert %DateTime{} = span.cleared_at

      assert %{inserted: 0} = AttentionSpanBackfill.backfill(apply?: true)
    end

    test "an escalation that raised a stored cause is not counted twice", ctx do
      {:ok, _} =
        Escalation.post(%{
          kind: :merge_conflict,
          task_ref: ctx.task.id,
          workspace_id: ctx.ws.id,
          subject: "conflict",
          body: "the PR conflicts"
        })

      assert reload(ctx.task).attention_cause == :merge_blocked
      _ = put_state!(reload(ctx.task), :queued)

      wipe_spans()
      AttentionSpanBackfill.backfill(apply?: true)

      assert [%{cause: "merge_blocked", cleared_by: :transition}] = spans(ctx.task)
    end
  end

  defp insert_version(ticket_id, action, at, changes) do
    Repo.query!(
      """
      INSERT INTO issues_versions
        (id, version_source_id, version_action_name, version_action_type, changes,
         version_action_inputs, version_inserted_at, version_updated_at)
      VALUES (?1, ?2, ?3, 'update', ?4, '{}', ?5, ?5)
      """,
      [Ecto.UUID.generate(), ticket_id, action, Jason.encode!(changes), DateTime.to_iso8601(at)]
    )
  end
end
