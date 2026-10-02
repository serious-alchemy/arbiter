defmodule Arbiter.Reports.FlowTest do
  @moduledoc """
  bd-836iuz: cumulative flow and stage dwell over `ticket_transitions`
  intervals (reports design v2, §5.1 and the stage half of §5.2).

  The pure half (`cumulative_flow/3`, `ticket_dwell/1`, `stage_dwell/2`) is
  checked against tickets traced by hand below; the DB half (`load/1`) against
  real `issues` / `ticket_transitions` rows with hand-stamped clocks.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Reports.Flow
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Dependency, Issue, TicketTransition, Workspace}

  defp at(s), do: DateTime.from_naive!(NaiveDateTime.from_iso8601!(s), "Etc/UTC")

  # `trace("t1", [{:backlog, "2026-09-01 09:00:00"}, ...])`
  defp trace(id, steps) do
    for {state, time} <- steps, do: %{ticket_id: id, to_state: state, at: at(time)}
  end

  # Five tickets, each traced by hand. Hours are wall-clock gaps between the
  # rows; the closed interval is never a stage.
  #
  # t1  simple          backlog 1h · queued 2h · active 2h · merging 1.5h
  # t2  return_to_work  queued 1h · active 2h+2h · merging 1h+1h (first PR after 2h)
  # t3  reopen          queued 0.5h+1h · active 1h+1h · merging 1h+1h (closed 7h between)
  # t4  no PR           backlog 2h · queued 1h · active 0.5h · verifying 3h · merging 0
  # t5  requeue         backlog 1h · active 1h+2h · queued 3h · merging 0.5h
  defp hand_traced do
    t1 =
      trace("t1", [
        {:backlog, "2026-09-01 09:00:00"},
        {:queued, "2026-09-01 10:00:00"},
        {:active, "2026-09-01 12:00:00"},
        {:merging, "2026-09-01 14:00:00"},
        {:closed, "2026-09-01 15:30:00"}
      ])

    t2 =
      trace("t2", [
        {:backlog, "2026-09-01 00:00:00"},
        {:queued, "2026-09-01 01:00:00"},
        {:active, "2026-09-01 02:00:00"},
        {:merging, "2026-09-01 04:00:00"},
        {:active, "2026-09-01 05:00:00"},
        {:merging, "2026-09-01 07:00:00"},
        {:closed, "2026-09-01 08:00:00"}
      ])

    t3 =
      trace("t3", [
        {:backlog, "2026-09-01 00:00:00"},
        {:queued, "2026-09-01 00:30:00"},
        {:active, "2026-09-01 01:00:00"},
        {:merging, "2026-09-01 02:00:00"},
        {:closed, "2026-09-01 03:00:00"},
        {:queued, "2026-09-01 10:00:00"},
        {:active, "2026-09-01 11:00:00"},
        {:merging, "2026-09-01 12:00:00"},
        {:closed, "2026-09-01 13:00:00"}
      ])

    t4 =
      trace("t4", [
        {:backlog, "2026-09-01 00:00:00"},
        {:queued, "2026-09-01 02:00:00"},
        {:active, "2026-09-01 03:00:00"},
        {:verifying, "2026-09-01 03:30:00"},
        {:closed, "2026-09-01 06:30:00"}
      ])

    t5 =
      trace("t5", [
        {:backlog, "2026-09-01 00:00:00"},
        {:active, "2026-09-01 01:00:00"},
        {:queued, "2026-09-01 02:00:00"},
        {:active, "2026-09-01 05:00:00"},
        {:merging, "2026-09-01 06:00:00"},
        {:closed, "2026-09-01 06:30:00"}
      ])

    tickets = [
      %{id: "t1", difficulty: 1, closed_at: at("2026-09-01 15:30:00")},
      %{id: "t2", difficulty: 1, closed_at: at("2026-09-01 08:00:00")},
      %{id: "t3", difficulty: 3, closed_at: at("2026-09-01 13:00:00")},
      %{id: "t4", difficulty: nil, closed_at: at("2026-09-01 06:30:00")},
      %{id: "t5", difficulty: 3, closed_at: at("2026-09-01 06:30:00")}
    ]

    {tickets, t1 ++ t2 ++ t3 ++ t4 ++ t5}
  end

  describe "ticket_dwell/1" do
    test "a straight path sums each state's interval; the final closed interval is no stage" do
      {_, rows} = hand_traced()
      rows = Enum.filter(rows, &(&1.ticket_id == "t1"))

      assert Flow.ticket_dwell(rows) == %{
               backlog: 1.0,
               queued: 2.0,
               active: 2.0,
               merging: 1.5,
               verifying: 0.0
             }
    end

    test "a return_to_work repeat adds to the stage instead of overwriting it" do
      {_, rows} = hand_traced()
      dwell = rows |> Enum.filter(&(&1.ticket_id == "t2")) |> Flow.ticket_dwell()

      assert dwell.queued == 1.0
      assert dwell.active == 4.0
      assert dwell.merging == 2.0
    end

    test "a reopen sums both passes and leaves the time spent closed out" do
      {_, rows} = hand_traced()
      dwell = rows |> Enum.filter(&(&1.ticket_id == "t3")) |> Flow.ticket_dwell()

      assert dwell.queued == 1.5
      assert dwell.active == 2.0
      assert dwell.merging == 2.0
      assert dwell.backlog == 0.5
    end

    test "a ticket with no PR has no merging time; verifying is its own stage" do
      {_, rows} = hand_traced()
      dwell = rows |> Enum.filter(&(&1.ticket_id == "t4")) |> Flow.ticket_dwell()

      assert dwell == %{backlog: 2.0, queued: 1.0, active: 0.5, merging: 0.0, verifying: 3.0}
    end

    test "a requeue returns to queued and a later start adds to active" do
      {_, rows} = hand_traced()
      dwell = rows |> Enum.filter(&(&1.ticket_id == "t5")) |> Flow.ticket_dwell()

      assert dwell == %{backlog: 1.0, queued: 3.0, active: 2.0, merging: 0.5, verifying: 0.0}
    end

    test "rows out of order are read by `at`; equal `at`s keep their given order" do
      rows =
        trace("x", [
          {:queued, "2026-09-01 02:00:00"},
          {:backlog, "2026-09-01 00:00:00"},
          {:active, "2026-09-01 02:00:00"},
          {:closed, "2026-09-01 03:00:00"}
        ])

      # queued → active at the same instant: queued gets 0h, active 1h.
      dwell = Flow.ticket_dwell(rows)
      assert dwell.backlog == 2.0
      assert dwell.queued == 0.0
      assert dwell.active == 1.0
    end
  end

  describe "stage_dwell/2" do
    test "per-stage P50/P90 over the cohort, zeros included" do
      {tickets, rows} = hand_traced()
      %{n: 5, overall: overall} = Flow.stage_dwell(tickets, rows)

      # active hours per ticket: t1 2, t2 4, t3 2, t4 0.5, t5 2 → sorted .5 2 2 2 4
      assert overall.active == %{p50_hours: 2.0, p90_hours: 4.0}
      # merging: t1 1.5, t2 2, t3 2, t4 0, t5 .5 → 0 .5 1.5 2 2
      assert overall.merging == %{p50_hours: 1.5, p90_hours: 2.0}
      # queued: 2 1 1.5 1 3 → 1 1 1.5 2 3
      assert overall.queued == %{p50_hours: 1.5, p90_hours: 3.0}
      # verifying: only t4 → 0 0 0 0 3
      assert overall.verifying == %{p50_hours: 0.0, p90_hours: 3.0}
    end

    test "median dwell per difficulty, unrated last" do
      {tickets, rows} = hand_traced()
      %{by_difficulty: by} = Flow.stage_dwell(tickets, rows)

      assert Enum.map(by, &{&1.difficulty, &1.n}) == [{1, 2}, {3, 2}, {nil, 1}]

      d1 = Enum.find(by, &(&1.difficulty == 1))
      # active t1 2h, t2 4h → nearest-rank median is the lower of two
      assert d1.medians.active == 2.0
      assert d1.medians.queued == 1.0
      assert d1.medians.merging == 1.5

      d3 = Enum.find(by, &(&1.difficulty == 3))
      # t3 (reopen) and t5 (requeue)
      assert d3.medians.queued == 1.5
      assert d3.medians.active == 2.0
      assert d3.medians.merging == 0.5

      unrated = Enum.find(by, &(&1.difficulty == nil))
      assert unrated.medians.verifying == 3.0
    end

    test "time to first PR and queued → closed" do
      {tickets, rows} = hand_traced()
      %{first_pr: first_pr, queued_to_closed: q2c} = Flow.stage_dwell(tickets, rows)

      # first active → first merging: t1 2h, t2 2h, t3 1h, t5 5h (04:00→… see below);
      # t4 never merged and is left out.
      # t5: first active 01:00, first merging 06:00 = 5h.
      assert first_pr.n == 4
      assert first_pr.p50_hours == 2.0
      assert first_pr.p90_hours == 5.0

      # first queued → closed_at: t1 10:00→15:30 5.5h, t2 01:00→08:00 7h,
      # t3 00:30→13:00 12.5h, t4 02:00→06:30 4.5h, t5 02:00→06:30 4.5h
      assert q2c.n == 5
      assert q2c.p50_hours == 5.5
      assert q2c.p90_hours == 12.5
    end

    test "an empty cohort has nothing to report" do
      assert %{n: 0, overall: overall, by_difficulty: []} = Flow.stage_dwell([], [])
      assert overall.active == %{p50_hours: nil, p90_hours: nil}
    end

    test "a ticket with no transitions is skipped, not counted as zero dwell" do
      {tickets, rows} = hand_traced()
      ghost = %{id: "ghost", difficulty: 2, closed_at: at("2026-09-01 20:00:00")}
      assert %{n: 5} = Flow.stage_dwell([ghost | tickets], rows)
    end
  end

  describe "cumulative_flow/3" do
    # a: created 09-01, queued 09-02, active 09-03, closed 09-03 (same day, later)
    # b: created 09-02 (backlog), still backlog
    # c: created 09-03, closed 09-04, reopened → queued 09-05
    defp cfd_rows do
      trace("a", [
        {:backlog, "2026-09-01 10:00:00"},
        {:queued, "2026-09-02 09:00:00"},
        {:active, "2026-09-03 09:00:00"},
        {:merging, "2026-09-03 10:00:00"},
        {:closed, "2026-09-03 11:00:00"}
      ]) ++
        trace("b", [{:backlog, "2026-09-02 12:00:00"}]) ++
        trace("c", [
          {:backlog, "2026-09-03 08:00:00"},
          {:closed, "2026-09-04 08:00:00"},
          {:queued, "2026-09-05 08:00:00"}
        ])
    end

    defp day(flow, iso), do: Enum.find(flow, &(&1.day == Date.from_iso8601!(iso)))

    test "one point per day, every state present, bands sum to tickets created" do
      flow = Flow.cumulative_flow(cfd_rows(), ~D[2026-08-31], ~D[2026-09-06])

      assert Enum.map(flow, & &1.day) ==
               Date.range(~D[2026-08-31], ~D[2026-09-06]) |> Enum.to_list()

      assert Enum.all?(flow, &(Map.keys(&1.counts) |> Enum.sort() == Enum.sort(Flow.states())))

      created = %{
        "2026-08-31" => 0,
        "2026-09-01" => 1,
        "2026-09-02" => 2,
        "2026-09-03" => 3,
        "2026-09-04" => 3,
        "2026-09-05" => 3,
        "2026-09-06" => 3
      }

      for {iso, n} <- created do
        point = day(flow, iso)
        assert point.total == n, "total on #{iso}"
        assert point.counts |> Map.values() |> Enum.sum() == n, "Σ bands on #{iso}"
      end
    end

    test "each day shows the state at the end of that day" do
      flow = Flow.cumulative_flow(cfd_rows(), ~D[2026-09-01], ~D[2026-09-05])

      assert day(flow, "2026-09-01").counts.backlog == 1
      # a queued, b backlog
      assert %{queued: 1, backlog: 1} = day(flow, "2026-09-02").counts
      # a closed the same day it went active/merging — only the end state counts
      assert %{closed: 1, backlog: 2} = day(flow, "2026-09-03").counts
      assert day(flow, "2026-09-03").counts.active == 0
      assert day(flow, "2026-09-03").counts.merging == 0
      # c closed on 09-04; a reopen steps it back out of closed on 09-05
      assert day(flow, "2026-09-04").counts.closed == 2
      assert %{closed: 1, queued: 1, backlog: 1} = day(flow, "2026-09-05").counts
    end

    test "a window that starts after the history still counts everything created before it" do
      flow = Flow.cumulative_flow(cfd_rows(), ~D[2026-09-05], ~D[2026-09-06])

      assert Enum.map(flow, & &1.total) == [3, 3]
      assert %{closed: 1, queued: 1, backlog: 1} = day(flow, "2026-09-06").counts
    end

    test "no transitions → zero totals, still one point per day" do
      flow = Flow.cumulative_flow([], ~D[2026-09-01], ~D[2026-09-02])
      assert Enum.map(flow, & &1.total) == [0, 0]
    end
  end

  # ---- DB ----

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "fl-#{System.unique_integer([:positive])}", prefix: "fl"})

    {:ok, ws: ws}
  end

  defp iso(time), do: %{at(time) | microsecond: {0, 6}} |> DateTime.to_iso8601()

  # An issue whose history is hand-written: the stored columns are set to the
  # last step (raw, so the triggers' own rows can be dropped afterwards) and
  # `steps` become its `ticket_transitions`.
  defp seed!(ws, attrs, steps) do
    issue = Ash.create!(Issue, Map.merge(%{title: "t", workspace_id: ws.id}, attrs))
    {last_state, last_time} = List.last(steps)
    {_, first_time} = hd(steps)
    closed? = last_state == :closed

    Repo.query!(
      "UPDATE issues SET state = ?, created_at = ?, closed_at = ?, close_reason = ? WHERE id = ?",
      [
        to_string(last_state),
        iso(first_time),
        if(closed?, do: iso(last_time)),
        if(closed?, do: "completed"),
        issue.id
      ]
    )

    Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])

    Enum.reduce(steps, nil, fn {state, time}, from ->
      TicketTransition
      |> Ash.Changeset.for_create(:record, %{
        ticket_id: issue.id,
        workspace_id: ws.id,
        from_state: from,
        to_state: state,
        transition: if(from, do: "unnamed", else: "create"),
        at: at(time),
        source: "backfill"
      })
      |> Ash.create!()

      state
    end)

    issue
  end

  defp filters(ws, extra \\ %{}) do
    Map.merge(
      %{
        "workspace" => ws.id,
        "repo" => "",
        "type" => "",
        "difficulty" => "",
        "epic" => "",
        "range" => "all"
      },
      extra
    )
  end

  @now ~U[2026-09-06 12:00:00Z]

  describe "load/2" do
    setup %{ws: ws} do
      a =
        seed!(ws, %{difficulty: 1}, [
          {:backlog, "2026-09-01 10:00:00"},
          {:queued, "2026-09-02 09:00:00"},
          {:active, "2026-09-03 09:00:00"},
          {:merging, "2026-09-03 10:00:00"},
          {:closed, "2026-09-03 11:00:00"}
        ])

      b = seed!(ws, %{difficulty: 3}, [{:backlog, "2026-09-02 12:00:00"}])

      c =
        seed!(ws, %{difficulty: 3}, [
          {:backlog, "2026-09-03 08:00:00"},
          {:queued, "2026-09-03 09:00:00"},
          {:active, "2026-09-03 10:00:00"},
          {:merging, "2026-09-03 12:00:00"},
          {:closed, "2026-09-04 08:00:00"}
        ])

      epic =
        seed!(ws, %{issue_type: :epic}, [
          {:backlog, "2026-09-01 08:00:00"},
          {:queued, "2026-09-01 08:30:00"}
        ])

      {:ok, a: a, b: b, c: c, epic: epic}
    end

    test "Σ bands = tickets created on every sampled day; epics are not tickets", %{ws: ws} do
      %{flow: flow} = Flow.load(filters(ws), @now)

      assert List.first(flow).day == ~D[2026-09-01]
      assert List.last(flow).day == ~D[2026-09-06]

      created_by = fn day ->
        eod = DateTime.new!(day, ~T[23:59:59.999999], "Etc/UTC")

        Issue
        |> Ash.read!()
        |> Enum.count(
          &(&1.workspace_id == ws.id and &1.issue_type != :epic and
              DateTime.compare(&1.created_at, eod) != :gt)
        )
      end

      for point <- flow do
        assert point.total == created_by.(point.day), "total on #{point.day}"

        assert point.counts |> Map.values() |> Enum.sum() == point.total,
               "Σ bands on #{point.day}"
      end

      assert Enum.map(flow, & &1.total) == [1, 2, 3, 3, 3, 3]
    end

    test "range bounds the window shown, not the tickets counted", %{ws: ws} do
      %{flow: flow} = Flow.load(filters(ws, %{"range" => "2d"}), @now)

      assert Enum.map(flow, & &1.day) == [~D[2026-09-04], ~D[2026-09-05], ~D[2026-09-06]]
      assert Enum.all?(flow, &(&1.total == 3))
      assert %{closed: 2, backlog: 1} = hd(flow).counts
    end

    test "the difficulty filter narrows both reports", %{ws: ws} do
      %{flow: flow, dwell: dwell} = Flow.load(filters(ws, %{"difficulty" => "1"}), @now)

      assert Enum.all?(flow, &(&1.total <= 1))
      assert dwell.n == 1
      assert Enum.map(dwell.by_difficulty, & &1.difficulty) == [1]
    end

    test "the epic filter keeps only the epic's parent_of children", %{ws: ws, epic: epic, c: c} do
      Ash.create!(Dependency, %{from_issue_id: epic.id, to_issue_id: c.id, type: :parent_of})

      %{flow: flow, dwell: dwell} = Flow.load(filters(ws, %{"epic" => epic.id}), @now)

      # the window opens at the first of the epic's tickets, not the install's
      assert Enum.map(flow, & &1.day) ==
               Date.range(~D[2026-09-03], ~D[2026-09-06]) |> Enum.to_list()

      assert Enum.map(flow, & &1.total) == [1, 1, 1, 1]
      assert dwell.n == 1
      # c: queued 1h (09:00→10:00), active 2h, merging 20h, backlog 1h
      assert dwell.overall.active == %{p50_hours: 2.0, p90_hours: 2.0}
      assert dwell.overall.merging == %{p50_hours: 20.0, p90_hours: 20.0}
    end

    test "an epic with no children yields an empty report", %{ws: ws, epic: epic} do
      %{flow: flow, dwell: dwell} = Flow.load(filters(ws, %{"epic" => epic.id}), @now)

      assert flow == []
      assert dwell.n == 0
    end

    test "stage dwell covers closed, completed tickets; open ones are not in the cohort",
         %{ws: ws} do
      %{dwell: dwell} = Flow.load(filters(ws), @now)

      # a and c closed; b still in backlog.
      assert dwell.n == 2
      # a: active 1h; c: active 2h
      assert dwell.overall.active == %{p50_hours: 1.0, p90_hours: 2.0}
    end

    test "the dwell range is by closed_at", %{ws: ws} do
      # Only c closed within 2 days of @now - 2d = 09-04 12:00? c closed 09-04 08:00: out.
      assert %{dwell: %{n: 0}} = Flow.load(filters(ws, %{"range" => "1d"}), @now)
      assert %{dwell: %{n: 1}} = Flow.load(filters(ws, %{"range" => "3d"}), @now)
    end
  end
end
