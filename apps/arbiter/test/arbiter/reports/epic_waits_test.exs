defmodule Arbiter.Reports.EpicWaitsTest do
  @moduledoc """
  bd-agj7wt: the epic Ready-wait readout (ES7). `compute/3` is checked against
  `test/fixtures/epic_waits.json`, whose expected numbers are the output of
  `docs/design/epic-aware-scheduling/measure_epic_waits.py` run over a sqlite
  copy of the same fixture (`--as-of 2026-09-28T08:00:00Z --workspace t`); the
  guard line is the script's `GUARD: no parent, P1+P2`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Reports.EpicWaits
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Dependency, Issue, TicketTransition, Workspace}

  @as_of ~U[2026-09-28 08:00:00Z]

  defp at(s), do: DateTime.from_naive!(NaiveDateTime.from_iso8601!(s), "Etc/UTC")
  defp parse(nil), do: nil
  defp parse(s), do: s |> DateTime.from_iso8601() |> elem(1)

  defp fixture do
    json = "test/fixtures/epic_waits.json" |> File.read!() |> Jason.decode!()

    %{
      issues:
        for(
          i <- json["issues"],
          do: %{
            id: i["id"],
            priority: i["priority"],
            state: i["state"],
            type: i["type"],
            closed_at: parse(i["closed"])
          }
        ),
      dependencies: for([from, to, type] <- json["dependencies"], do: {from, to, type}),
      transitions:
        for([id, from, to, time] <- json["transitions"], do: {id, from, to, parse(time)})
    }
  end

  defp assert_summary(summary, n, median, p75, p90, mean) do
    assert summary.n == n
    assert_in_delta summary.median, median, 1.0e-6
    assert_in_delta summary.p75, p75, 1.0e-6
    assert_in_delta summary.p90, p90, 1.0e-6
    assert_in_delta summary.mean, mean, 1.0e-6
  end

  describe "compute/3 against measure_epic_waits.py" do
    setup do
      {:ok,
       result: EpicWaits.compute(fixture(), @as_of, subject?: &String.starts_with?(&1, "t-"))}
    end

    test "head, middle and tail Ready wait", %{result: r} do
      assert r.closed_children == 9
      assert [head, middle, tail] = r.buckets
      assert {head.key, middle.key, tail.key} == {:head, :middle, :tail}
      assert_summary(head.all, 4, 4.5, 13.0, 13.0, 5.75)
      assert_summary(middle.all, 3, 14.0, 30.0, 30.0, 16.333333333333)
      assert_summary(tail.all, 2, 57.5, 76.0, 76.0, 57.5)
    end

    test "the same split inside own priority P2", %{result: r} do
      [head, middle, tail] = r.buckets
      assert_summary(head.p2, 2, 4.0, 7.0, 7.0, 4.0)
      assert_summary(middle.p2, 2, 22.0, 30.0, 30.0, 22.0)
      assert tail.p2 == %{n: 0, median: nil, p75: nil, p90: nil, mean: nil}
    end

    test "by own priority, epic children vs parentless", %{result: r} do
      by = Map.new(r.by_priority, &{&1.priority, &1})
      assert_summary(by[1].epic_child, 1, 2.0, 2.0, 2.0, 2.0)
      assert_summary(by[1].parentless, 3, 3.0, 27.0, 27.0, 10.333333333333)
      assert_summary(by[2].epic_child, 4, 10.5, 30.0, 30.0, 13.0)
      assert_summary(by[2].parentless, 5, 11.0, 19.0, 48.0, 15.8)
      assert by[0].parentless.n == 0
      assert by[4].epic_child.n == 0
    end

    test "the parentless P1/P2 p90 guard", %{result: r} do
      assert_summary(r.guard, 8, 7.0, 27.0, 48.0, 13.75)
    end
  end

  test "an epic with fewer than three direct children is ignored" do
    data = %{
      issues: [
        %{id: "e", priority: 1, state: "queued", type: "epic", closed_at: nil},
        %{id: "a", priority: 1, state: "closed", type: "task", closed_at: @as_of},
        %{id: "b", priority: 1, state: "closed", type: "task", closed_at: @as_of}
      ],
      dependencies: [{"e", "a", "parent_of"}, {"e", "b", "parent_of"}],
      transitions: [
        {"a", nil, "queued", DateTime.add(@as_of, -7200)},
        {"a", "queued", "closed", @as_of}
      ]
    }

    assert EpicWaits.compute(data, @as_of).closed_children == 0
  end

  describe "load/2" do
    test "reads the same shapes from the database" do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "ew-#{System.unique_integer([:positive])}", prefix: "ew"})

      epic = Ash.create!(Issue, %{title: "e", workspace_id: ws.id, issue_type: :epic})

      kids =
        for {wait_h, n} <- [{1, 1}, {2, 2}, {30, 3}] do
          issue = Ash.create!(Issue, %{title: "c#{n}", workspace_id: ws.id, priority: 2})

          Ash.create!(Dependency, %{
            from_issue_id: epic.id,
            to_issue_id: issue.id,
            type: :parent_of
          })

          Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])
          start = at("2026-09-01 00:00:00")
          active = DateTime.add(start, wait_h * 3600)
          closed = DateTime.add(active, 3600)

          for {from, to, time} <- [
                {nil, :queued, start},
                {:queued, :active, active},
                {:active, :closed, closed}
              ] do
            TicketTransition
            |> Ash.Changeset.for_create(:record, %{
              ticket_id: issue.id,
              workspace_id: ws.id,
              from_state: from,
              to_state: to,
              transition: if(from, do: "unnamed", else: "create"),
              at: time,
              source: "backfill"
            })
            |> Ash.create!()
          end

          Repo.query!("UPDATE issues SET state = 'closed', closed_at = ? WHERE id = ?", [
            closed |> DateTime.to_iso8601() |> String.replace("Z", ".000000Z"),
            issue.id
          ])

          issue
        end

      result = EpicWaits.load(%{"workspace" => ws.id, "range" => "all"}, ~U[2026-10-01 00:00:00Z])

      assert result.closed_children == length(kids)
      [head, middle, tail] = result.buckets
      assert head.all.n == 1 and head.all.median == 1.0
      assert middle.all.n == 1 and middle.all.median == 2.0
      assert tail.all.n == 1 and tail.all.median == 30.0
      assert result.guard.n == 0
    end
  end
end
