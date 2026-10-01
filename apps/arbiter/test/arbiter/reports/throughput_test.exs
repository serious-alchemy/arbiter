defmodule Arbiter.Reports.ThroughputTest do
  use ExUnit.Case, async: true

  alias Arbiter.Reports.Throughput

  defp row(difficulty, closed, created \\ nil) do
    closed_at = DateTime.from_naive!(NaiveDateTime.from_iso8601!(closed), "Etc/UTC")
    created_at = created && DateTime.from_naive!(NaiveDateTime.from_iso8601!(created), "Etc/UTC")
    %{difficulty: difficulty, closed_at: closed_at, created_at: created_at || closed_at}
  end

  test "weight table: D0 0.5, D1..D4 = 1..4, unrated = 2" do
    assert Throughput.weights() == %{0 => 0.5, 1 => 1, 2 => 2, 3 => 3, 4 => 4}
    assert Throughput.unrated_weight() == 2
    assert Throughput.weight(nil) == 2
    assert Throughput.weight(0) == 0.5
    assert Throughput.weight(4) == 4
  end

  test "weekly counts and weighted size match a manual GROUP BY for 3 weeks" do
    rows = [
      # week of Mon 2026-09-07 (Sun 09-13 23:59 still belongs to it)
      row(1, "2026-09-07 00:00:00"),
      row(1, "2026-09-10 12:00:00"),
      row(3, "2026-09-13 23:59:59"),
      # week of 09-14
      row(0, "2026-09-14 00:00:00"),
      row(nil, "2026-09-18 08:00:00"),
      # week of 09-21
      row(2, "2026-09-21 09:00:00"),
      row(2, "2026-09-27 09:00:00"),
      row(4, "2026-09-22 09:00:00"),
      row(nil, "2026-09-23 09:00:00")
    ]

    weekly = Throughput.compute(rows).weekly
    by = Map.new(weekly, &{Date.to_iso8601(&1.week), &1})

    assert by["2026-09-07"].count == 3
    assert by["2026-09-07"].counts == %{1 => 2, 3 => 1}
    assert by["2026-09-07"].weighted == 5

    assert by["2026-09-14"].count == 2
    assert by["2026-09-14"].counts == %{0 => 1, nil => 1}
    assert by["2026-09-14"].weighted == 2.5

    assert by["2026-09-21"].count == 4
    assert by["2026-09-21"].counts == %{2 => 2, 4 => 1, nil => 1}
    assert by["2026-09-21"].weighted == 10
  end

  test "empty weeks between the first and last are filled with zero" do
    weekly =
      Throughput.compute([row(1, "2026-09-01 00:00:00"), row(1, "2026-09-16 00:00:00")]).weekly

    assert Enum.map(weekly, &{Date.to_iso8601(&1.week), &1.count}) ==
             [{"2026-08-31", 1}, {"2026-09-07", 0}, {"2026-09-14", 1}]
  end

  test "4-week moving average of weighted size" do
    rows =
      for {d, i} <- Enum.with_index(~w(2026-09-01 2026-09-08 2026-09-15 2026-09-22 2026-09-29)) do
        row(4, "#{d} 00:00:00") |> Map.put(:difficulty, i + 1)
      end

    avgs = Enum.map(Throughput.compute(rows).weekly, & &1.moving_avg)
    # weighted per week: 1,2,3,4 and D5 (unrated → 2) → trailing windows of up to 4
    assert avgs == [1.0, 1.5, 2.0, 2.5, 2.75]
  end

  test "lead-time P50/P90 (nearest rank) match a hand computation on 5 tickets" do
    # leads in hours: 24, 48, 72, 96, 240  → n=5
    # P50 = ceil(0.5*5)=3rd = 72h ; P90 = ceil(0.9*5)=5th = 240h
    rows =
      for {h, i} <- Enum.with_index([240, 24, 96, 48, 72]) do
        created = ~N[2026-09-01 00:00:00] |> NaiveDateTime.add(i * 60)
        closed = NaiveDateTime.add(created, h * 3600)
        row(1, NaiveDateTime.to_iso8601(closed), NaiveDateTime.to_iso8601(created))
      end

    lead = Throughput.compute(rows).lead
    assert lead.n == 5
    assert lead.p50_hours == 72.0
    assert lead.p90_hours == 240.0
  end

  test "lead time is split at the 2026-08-24 era boundary" do
    assert Throughput.era_cutover() == ~D[2026-08-24]

    rows = [
      row(1, "2026-08-20 00:00:00", "2026-08-19 00:00:00"),
      row(1, "2026-09-02 00:00:00", "2026-09-01 12:00:00"),
      row(1, "2026-09-03 00:00:00", "2026-09-01 00:00:00")
    ]

    %{before: b, after: a} = Throughput.compute(rows).lead.eras
    assert b.n == 1 and b.p50_hours == 24.0
    assert a.n == 2 and a.p50_hours == 12.0 and a.p90_hours == 48.0
  end

  test "histogram buckets are contiguous day ranges and cover every ticket" do
    rows = [
      row(1, "2026-09-02 00:00:00", "2026-09-01 18:00:00"),
      row(1, "2026-09-04 00:00:00", "2026-09-01 00:00:00"),
      row(1, "2026-12-01 00:00:00", "2026-09-01 00:00:00")
    ]

    buckets = Throughput.compute(rows).lead.buckets
    assert Enum.sum(Enum.map(buckets, & &1.count)) == 3
    assert hd(buckets).count == 1
    assert List.last(buckets).count == 1

    buckets
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] -> assert a.to == b.from end)
  end

  test "empty input" do
    r = Throughput.compute([])
    assert r.weekly == []
    assert r.lead.n == 0 and r.lead.p50_hours == nil
  end
end
