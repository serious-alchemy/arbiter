defmodule Arbiter.Loop.DetectorBackfillTest do
  # Stage 2 of the discovery pass (bd-8u2aqn): a hand-merged `@finding_buckets`
  # detector, backfilled over the review rounds Stage 0 retained. The fixture
  # detector below is test-only — no production detector is added by this stage.
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.{DetectorBackfill, FindingBuckets, PendingWrite}
  alias Arbiter.Repo
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.Workspace

  @category "cross-tenant cache leakage (fixture)"
  @buckets FindingBuckets.buckets() ++ [{~r/tenant/i, @category}]

  setup do
    {:ok, _} = Ash.create(Workspace, %{name: "backfill-ws", prefix: "bkf"})
    :ok
  end

  defp round!(task_id, findings, run_id, inserted_at \\ DateTime.utc_now()) do
    {:ok, round} =
      Ash.create(Round, %{
        task_id: task_id,
        round: 1,
        role: :review,
        verdict: :request_changes,
        converged: false,
        findings: findings,
        run_id: run_id
      })

    Repo.query!("UPDATE review_gate_rounds SET inserted_at = ?1 WHERE id = ?2", [
      DateTime.to_iso8601(inserted_at),
      round.id
    ])

    round
  end

  defp seed do
    round!("bd-aaa", "1. The cache key omits the tenant id.", Ecto.UUID.generate())
    round!("bd-bbb", "1. Two tenants share one slot.", Ecto.UUID.generate())
    round!("bd-ccc", "1. Unrelated style nit.", Ecto.UUID.generate())
  end

  defp rows, do: Ash.read!(PendingWrite)

  test "a merged detector's backfill writes PendingWrite rows through Loop.record/2" do
    seed()

    assert {:ok, report} = DetectorBackfill.run(@category, buckets: @buckets, apply?: true)
    assert report.dropped == []
    assert report.units == 2
    assert [row] = rows()
    assert row.category == @category
    assert row.evidence_count == 2
    assert Enum.sort(row.task_refs) == ["bd-aaa", "bd-bbb"]
  end

  test "dry run reports the reach and writes nothing" do
    seed()
    assert {:ok, report} = DetectorBackfill.run(@category, buckets: @buckets)
    assert report.units == 2
    assert report.applied? == false
    assert rows() == []
  end

  test "running twice is idempotent: no duplicate rows, unchanged counts" do
    seed()
    assert {:ok, _} = DetectorBackfill.run(@category, buckets: @buckets, apply?: true)
    [first] = rows()

    assert {:ok, _} = DetectorBackfill.run(@category, buckets: @buckets, apply?: true)
    assert [second] = rows()

    assert second.id == first.id
    assert second.evidence_count == first.evidence_count
    assert second.distinct_tasks == first.distinct_tasks
    assert Enum.sort(second.incident_refs) == Enum.sort(first.incident_refs)
    assert Enum.sort(second.task_refs) == Enum.sort(first.task_refs)
  end

  test "a later window's ordinary reinforcement unions onto the backfilled row" do
    seed()
    assert {:ok, _} = DetectorBackfill.run(@category, buckets: @buckets, apply?: true)
    round!("bd-ddd", "1. Tenant isolation is missing.", Ecto.UUID.generate())
    assert {:ok, _} = DetectorBackfill.run(@category, buckets: @buckets, apply?: true)
    assert [row] = rows()
    assert row.evidence_count == 3
  end

  test "retention bound: units older than retention_days are unreachable, and the span is clamped" do
    old =
      DateTime.add(DateTime.utc_now(), -(DetectorBackfill.retention_days() + 2) * 86_400, :second)

    round!("bd-old", "1. Old tenant leak.", Ecto.UUID.generate(), old)
    round!("bd-new", "1. New tenant leak.", Ecto.UUID.generate())

    far = DateTime.add(DateTime.utc_now(), -365 * 86_400, :second)

    assert {:ok, report} =
             DetectorBackfill.run(@category, buckets: @buckets, since: far, apply?: true)

    assert report.units == 1
    assert report.clamped? == true
    assert [row] = rows()
    assert row.task_refs == ["bd-new"]
  end

  test "retention bound: at most unit_limit units are read, newest first" do
    older = DateTime.add(DateTime.utc_now(), -3600, :second)
    round!("bd-old2", "1. Old tenant leak.", Ecto.UUID.generate(), older)
    round!("bd-new2", "1. New tenant leak.", Ecto.UUID.generate())

    assert {:ok, report} =
             DetectorBackfill.run(@category, buckets: @buckets, unit_limit: 1, apply?: true)

    assert report.units == 1
    assert report.truncated? == true
    assert [row] = rows()
    assert row.task_refs == ["bd-new2"]

    # a caller cannot raise the cap above the stated bound
    assert {:ok, capped} =
             DetectorBackfill.run(@category, buckets: @buckets, unit_limit: 1_000_000)

    assert capped.unit_limit == DetectorBackfill.unit_limit()
  end

  test "a category no bucket produces is refused" do
    assert {:error, :unknown_category} = DetectorBackfill.run("nope", buckets: @buckets)
  end
end
