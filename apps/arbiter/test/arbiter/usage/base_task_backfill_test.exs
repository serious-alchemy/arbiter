defmodule Arbiter.Usage.BaseTaskBackfillTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo
  alias Arbiter.Usage.BaseTaskBackfill
  alias Arbiter.Usage.Budget
  alias Arbiter.Usage.Event

  @now ~U[2026-08-01 12:00:00.000000Z]

  defp insert!(task_id, attrs \\ %{}) do
    {:ok, ev} =
      Ash.create(
        Event,
        Map.merge(
          %{task_id: task_id, source: :task, step: :work, occurred_at: @now, cost_usd: 1.0},
          attrs
        )
      )

    # Ash fills nothing here, but make the legacy shape explicit.
    Repo.query!("UPDATE usage_events SET base_task_id = NULL, role = NULL WHERE id = ?1", [
      Ecto.UUID.dump!(ev.id)
    ])

    ev
  end

  setup do
    for {id, cost} <- [
          {"bt-1", 1.0},
          {"bt-1#review", 2.0},
          {"bt-1#review#impl1", 4.0},
          {"bt-1#r2", 8.0},
          {"bt-1:fixpass", 16.0},
          {"bt-1:conflict", 32.0},
          {"bt-2", 64.0},
          {"bt-2#impl2#t2", 128.0}
        ] do
      insert!(id, %{cost_usd: cost})
    end

    insert!("ext:abc")
    :ok
  end

  defp null_rows do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT COUNT(*) FROM usage_events WHERE source = 'task' AND base_task_id IS NULL AND task_id NOT LIKE 'ext:%'"
      )

    n
  end

  test "dry-run reports the count and writes nothing" do
    report = BaseTaskBackfill.backfill()

    assert %{scanned: 8, would_backfill: 8, backfilled: 0, skipped_ext: 1, failed: 0} = report
    assert null_rows() == 8
  end

  test "apply leaves no null base_task_id except ext:, and is idempotent" do
    assert %{backfilled: 8, failed: 0} = BaseTaskBackfill.backfill(apply?: true)
    assert null_rows() == 0

    %{rows: [[ext]]} =
      Repo.query!("SELECT base_task_id FROM usage_events WHERE task_id = 'ext:abc'")

    assert ext == nil
    assert %{scanned: 0, backfilled: 0} = BaseTaskBackfill.backfill(apply?: true)
  end

  test "derives role from the suffix" do
    BaseTaskBackfill.backfill(apply?: true)

    roles =
      Repo.query!("SELECT task_id, role FROM usage_events WHERE task_id LIKE 'bt-%'").rows
      |> Map.new(fn [id, role] -> {id, role} end)

    assert roles["bt-1"] == "base"
    assert roles["bt-1#review"] == "review"
    assert roles["bt-1#review#impl1"] == "impl"
    assert roles["bt-1#r2"] == "review"
    assert roles["bt-1:fixpass"] == "fix_pass"
    assert roles["bt-1:conflict"] == "conflict"
    assert roles["bt-2#impl2#t2"] == "impl"
  end

  test "per-ticket totals by base_task_id equal Budget.spend_so_far/2 after the backfill" do
    # Before: Budget's `<id>#%` prefix match cannot see the `:fixpass` /
    # `:conflict` rows (48.0 of bt-1's 63.0) on un-stamped rows.
    assert Budget.spend_so_far("bt-1") == 15.0
    assert Budget.spend_so_far("bt-2") == 192.0

    BaseTaskBackfill.backfill(apply?: true)

    for {ticket, total} <- [{"bt-1", 63.0}, {"bt-2", 192.0}] do
      %{rows: [[sum]]} =
        Repo.query!("SELECT SUM(cost_usd) FROM usage_events WHERE base_task_id = ?1", [ticket])

      assert sum == total
      assert Budget.spend_so_far(ticket) == total
    end
  end
end
