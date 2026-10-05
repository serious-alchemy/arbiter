defmodule Arbiter.Events.RetentionTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Events.{Record, Retention}
  require Ash.Query

  defp insert!(inserted_at) do
    {:ok, record} =
      Record
      |> Ash.Changeset.for_create(:create, %{
        workspace_id: "ws-retention",
        topic: "worker_done",
        payload: %{},
        occurred_at: inserted_at
      })
      |> Ash.create()

    # inserted_at is a create_timestamp (always "now") — backdate it directly
    # so the test can simulate an old row without sleeping.
    record
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Arbiter.Repo.update!()

    record
  end

  test "sweep/1 deletes rows older than retention_days and keeps the rest" do
    old = insert!(DateTime.add(DateTime.utc_now(), -10, :day))
    recent = insert!(DateTime.add(DateTime.utc_now(), -1, :hour))

    Retention.sweep(retention_days: 7)

    remaining_ids =
      Record
      |> Ash.Query.filter(workspace_id == "ws-retention")
      |> Ash.read!()
      |> Enum.map(& &1.seq)

    refute old.seq in remaining_ids
    assert recent.seq in remaining_ids
  end

  defmodule KeepForever do
    @behaviour Arbiter.Events.Retention.Policy
    @impl true
    def cutoff(_now, _opts), do: :keep
  end

  defmodule OneHour do
    @behaviour Arbiter.Events.Retention.Policy
    @impl true
    def cutoff(now, _opts), do: DateTime.add(now, -1, :hour)
  end

  defp remaining_seqs do
    Record
    |> Ash.Query.filter(workspace_id == "ws-retention")
    |> Ash.read!()
    |> Enum.map(& &1.seq)
  end

  test "a policy returning :keep prunes nothing" do
    old = insert!(DateTime.add(DateTime.utc_now(), -10, :day))
    Retention.sweep(policy: KeepForever)
    assert old.seq in remaining_seqs()
  end

  test "a custom policy's cutoff replaces the default window" do
    old = insert!(DateTime.add(DateTime.utc_now(), -2, :hour))
    recent = insert!(DateTime.add(DateTime.utc_now(), -10, :minute))
    Retention.sweep(policy: OneHour)
    seqs = remaining_seqs()
    refute old.seq in seqs
    assert recent.seq in seqs
  end

  test "the default policy reproduces the retention_days window" do
    now = ~U[2026-01-10 00:00:00Z]

    assert Retention.Default.cutoff(now, retention_days: 7) == ~U[2026-01-03 00:00:00Z]
    assert Retention.Default.cutoff(now, []) == ~U[2026-01-03 00:00:00Z]
  end
end
