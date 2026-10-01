defmodule Arbiter.Usage.EventIndexPlanTest do
  # bd-bdjgwc: AshSqlite compiles `Ash.Query.filter(col == ^v)` on
  # `usage_events` to `CAST(col AS TEXT) = CAST(? AS TEXT)` (ash_sql wraps
  # both operands in `type/2`; ecto_sqlite3 renders text-stored types —
  # utc_datetime_usec, uuid, atom — as CAST AS TEXT). A plain index on the
  # bare column can't serve that, so the planner SCANs. The expression indexes
  # from the 20261001160000 migration match the CAST verbatim.
  use Arbiter.DataCase, async: false

  alias Arbiter.Repo
  alias Arbiter.Usage.Event
  require Ash.Query

  defp plan(query) do
    {:ok, ecto} = Ash.Query.data_layer_query(query)
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, ecto)
    %{rows: rows} = Ecto.Adapters.SQL.query!(Repo, "EXPLAIN QUERY PLAN " <> sql, params)
    Enum.map(rows, fn row -> List.last(row) end)
  end

  defp assert_search(details) do
    assert Enum.any?(details, &String.starts_with?(&1, "SEARCH u0")),
           "expected an index SEARCH, got: #{inspect(details)}"

    refute Enum.any?(details, &String.starts_with?(&1, "SCAN u0")),
           "unexpected full SCAN: #{inspect(details)}"
  end

  test "windowed (occurred_at) ledger read uses an index" do
    since = ~U[2026-09-01 00:00:00.000000Z]
    assert_search(plan(Ash.Query.filter(Event, occurred_at >= ^since)))
  end

  test "per-account ledger read uses an index" do
    id = Ecto.UUID.generate()
    assert_search(plan(Ash.Query.filter(Event, provider_account_id == ^id)))
  end

  test "per-account windowed read uses an index" do
    id = Ecto.UUID.generate()
    since = ~U[2026-09-01 00:00:00.000000Z]

    assert_search(
      plan(Ash.Query.filter(Event, provider_account_id == ^id and occurred_at >= ^since))
    )
  end

  test "source + window read uses an index" do
    since = ~U[2026-09-01 00:00:00.000000Z]

    assert_search(plan(Ash.Query.filter(Event, source == :preflight and occurred_at >= ^since)))
  end

  test "filtered results are unchanged and ordered by the window" do
    acct = Ecto.UUID.generate()
    other = Ecto.UUID.generate()
    now = ~U[2026-09-15 12:00:00.000000Z]

    mk = fn attrs ->
      {:ok, ev} =
        Ash.create(
          Event,
          Map.merge(
            %{task_id: "bd-plan-#{System.unique_integer([:positive])}", step: :work},
            attrs
          )
        )

      ev
    end

    old = mk.(%{provider_account_id: acct, occurred_at: DateTime.add(now, -40, :day)})
    a = mk.(%{provider_account_id: acct, occurred_at: now, source: :preflight})
    b = mk.(%{provider_account_id: other, occurred_at: DateTime.add(now, 1, :hour)})

    since = DateTime.add(now, -30, :day)

    ids = fn q -> q |> Ash.read!() |> Enum.map(& &1.id) |> Enum.sort() end

    assert ids.(Ash.Query.filter(Event, provider_account_id == ^acct)) == Enum.sort([old.id, a.id])
    assert ids.(Ash.Query.filter(Event, occurred_at >= ^since)) == Enum.sort([a.id, b.id])

    assert ids.(Ash.Query.filter(Event, provider_account_id == ^acct and occurred_at >= ^since)) ==
             [a.id]

    assert ids.(Ash.Query.filter(Event, source == :preflight and occurred_at >= ^since)) ==
             [a.id]
  end
end
