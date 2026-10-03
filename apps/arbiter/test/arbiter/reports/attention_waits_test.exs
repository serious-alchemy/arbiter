defmodule Arbiter.Reports.AttentionWaitsTest do
  # async: false — the report reads whole tables (like the other reports).
  use Arbiter.DataCase, async: false

  alias Arbiter.Reports.AttentionWaits
  alias Arbiter.Repo
  alias Arbiter.Tasks.{Issue, Workspace}

  @now ~U[2026-10-02 12:00:00.000000Z]

  defp ago(hours), do: DateTime.add(@now, -round(hours * 3600), :second)

  defp ts(%DateTime{} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {elem(at.microsecond, 0), 6}})

  defp span(cause, from_h, to_h, extra \\ %{}) do
    Map.merge(
      %{
        ticket_id: "t-#{System.unique_integer([:positive])}",
        cause: cause,
        owner: :coordinator,
        owner_changed_at: nil,
        owner_at_close: nil,
        opened_at: ago(from_h),
        cleared_at: to_h && ago(to_h)
      },
      extra
    )
  end

  # Five `pr_closed` spans of 1, 2, 4, 8 and 16 hours. By hand (nearest rank):
  # P50 = ceil(0.5 * 5) = 3rd = 4h, P90 = ceil(0.9 * 5) = 5th = 16h; total 31h.
  # The 8h span moved to the operator after 3h; the 16h span is still open.
  defp five do
    [
      span("pr_closed", 101, 100),
      span("pr_closed", 52, 50),
      span("pr_closed", 34, 30),
      span("pr_closed", 28, 20, %{
        owner_changed_at: ago(25),
        owner_at_close: :operator
      }),
      span("pr_closed", 16, nil)
    ]
  end

  describe "compute/3" do
    test "per-cause P50/P90 match the hand computation over 5 spans" do
      report = AttentionWaits.compute(five(), [], @now)

      assert [row] = report.causes
      assert row.cause == "pr_closed"
      assert row.n == 5
      assert row.p50_hours == 4.0
      assert row.p90_hours == 16.0
      assert_in_delta row.total_hours, 31.0, 1.0e-9
    end

    test "open spans are flagged still waiting and run to now" do
      report = AttentionWaits.compute(five(), [], @now)

      assert report.open == 1
      assert [waiting] = report.waiting
      assert waiting.cause == "pr_closed"
      assert_in_delta waiting.hours, 16.0, 1.0e-9
      assert [%{open: 1}] = report.causes
    end

    test "operator and coordinator time are separable" do
      report = AttentionWaits.compute(five(), [], @now)

      assert [row] = report.causes
      assert_in_delta row.coordinator_hours, 26.0, 1.0e-9
      assert_in_delta row.operator_hours, 5.0, 1.0e-9
      assert_in_delta report.owners.coordinator, 26.0, 1.0e-9
      assert_in_delta report.owners.operator, 5.0, 1.0e-9

      assert Enum.any?(report.cells, &(&1.owner == :operator and &1.cause == "pr_closed"))
    end

    test "verifying dwell is its own coordinator cause; the stored span is not double counted" do
      stored = span("awaiting_verification", 10, nil)
      dwell = [%{ticket_id: stored.ticket_id, opened_at: ago(10), cleared_at: ago(4)}]

      report = AttentionWaits.compute([stored], dwell, @now)

      assert [row] = report.causes
      assert row.cause == "awaiting_verification"
      assert row.n == 1
      assert row.open == 0
      assert_in_delta row.coordinator_hours, 6.0, 1.0e-9
      assert report.waiting == []
    end

    test "no data is an empty report" do
      assert %{spans: 0, open: 0, causes: [], weekly: [], waiting: []} =
               AttentionWaits.compute([], [], @now)
    end
  end

  describe "load/2" do
    setup do
      {:ok, ws} =
        Ash.create(Workspace, %{name: "aw-#{System.unique_integer([:positive])}", prefix: "aw"})

      {:ok, issue} = Ash.create(Issue, %{title: "aw", workspace_id: ws.id, issue_type: :feature})
      %{ws: ws, issue: issue}
    end

    defp insert_span!(s, ws_id) do
      Repo.query!(
        """
        INSERT INTO ticket_attention_spans
          (id, ticket_id, workspace_id, cause, owner, owner_changed_at, owner_at_close,
           opened_at, cleared_at, derived, source, inserted_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 'live', ?, ?)
        """,
        [
          Ecto.UUID.generate(),
          s.ticket_id,
          ws_id,
          s.cause,
          Atom.to_string(s.owner),
          s.owner_changed_at && ts(s.owner_changed_at),
          s.owner_at_close && Atom.to_string(s.owner_at_close),
          ts(s.opened_at),
          s.cleared_at && ts(s.cleared_at),
          ts(@now),
          ts(@now)
        ]
      )
    end

    test "reads spans scoped by workspace and range", %{ws: ws, issue: issue} do
      for s <- five(), do: insert_span!(%{s | ticket_id: issue.id}, ws.id)

      # An old span, out of the 7d window
      insert_span!(%{span("run_crashed", 24 * 20, 24 * 20 - 1) | ticket_id: issue.id}, ws.id)

      report = AttentionWaits.load(%{"workspace" => ws.id, "range" => "7d"}, @now)
      assert [%{cause: "pr_closed", n: 5, p50_hours: 4.0, p90_hours: 16.0}] = report.causes

      all = AttentionWaits.load(%{"workspace" => ws.id, "range" => "all"}, @now)
      assert Enum.map(all.causes, & &1.cause) |> Enum.sort() == ["pr_closed", "run_crashed"]

      other = AttentionWaits.load(%{"workspace" => "nope", "range" => "all"}, @now)
      assert other.causes == []
    end

    test "verifying dwell comes from transitions; a still-verifying ticket is open", %{
      issue: issue
    } do
      Repo.query!("DELETE FROM ticket_transitions WHERE ticket_id = ?", [issue.id])

      for {from, to, state, at} <- [
            {"active", "verifying", "verifying", ago(10)},
            {"verifying", "closed", "closed", ago(4)},
            {"closed", "verifying", "verifying", ago(2)}
          ] do
        Repo.query!(
          """
          INSERT INTO ticket_transitions (id, ticket_id, from_state, to_state, transition, at, source)
          VALUES (?, ?, ?, ?, 'test', ?, 'live')
          """,
          [Ecto.UUID.generate(), issue.id, from, to || state, ts(at)]
        )
      end

      report = AttentionWaits.load(%{"type" => "feature", "range" => "all"}, @now)
      assert row = Enum.find(report.causes, &(&1.cause == "awaiting_verification"))
      assert row.n == 2
      assert row.open == 1
      assert_in_delta row.total_hours, 8.0, 1.0e-9
      assert Enum.any?(report.waiting, &(&1.ticket_id == issue.id))
    end
  end
end
