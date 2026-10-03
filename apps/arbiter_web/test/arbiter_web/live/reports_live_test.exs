defmodule ArbiterWeb.ReportsLiveTest do
  use ArbiterWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Arbiter.Tasks.{Issue, Workspace}

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rep-#{System.unique_integer([:positive])}", prefix: "rep"})

    {:ok, ws: ws}
  end

  defp issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "t", workspace_id: ws.id, acceptance: "- it works"}, attrs)
      )

    issue
  end

  test "renders the shell with filters and the empty state when nothing matches", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports?difficulty=5")
    _ = render_async(view)

    assert has_element?(view, "#reports-page")
    assert has_element?(view, "#reports-filters select[name='filters[workspace]']")
    assert has_element?(view, "#reports-range")
    assert has_element?(view, "#reports-empty")
    refute has_element?(view, "#reports-created-chart")
  end

  test "shows the loading state on the dead render", %{conn: conn} do
    html = conn |> get(~p"/reports") |> html_response(200)
    assert html =~ "reports-loading"
  end

  test "renders tiles and the created-per-week chart for matching tickets", %{conn: conn, ws: ws} do
    issue!(ws, %{difficulty: 3})
    issue!(ws, %{difficulty: 3})

    {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
    _ = render_async(view)

    assert has_element?(view, "#reports-tile-total [data-role=value]", "2")
    assert has_element?(view, "#reports-created-chart rect[data-value='2']")
    assert has_element?(view, "#reports-as-of")
    refute has_element?(view, "#reports-empty")
  end

  test "changing a filter patches the URL and re-queries", %{conn: conn, ws: ws} do
    issue!(ws, %{difficulty: 3})
    issue!(ws, %{difficulty: 1})

    {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
    _ = render_async(view)
    assert has_element?(view, "#reports-tile-total [data-role=value]", "2")

    view
    |> form("#reports-filters", filters: %{workspace: ws.id, difficulty: "3"})
    |> render_change()

    assert_patch(view, ~p"/reports?#{%{workspace: ws.id, difficulty: "3", range: "30d"}}")
    _ = render_async(view)
    assert has_element?(view, "#reports-tile-total [data-role=value]", "1")
  end

  test "an unknown range or type in the URL falls back instead of crashing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/reports?range=bogus&type=nope&difficulty=99")
    _ = render_async(view)
    assert has_element?(view, "#reports-page")
  end

  describe "throughput & lead time" do
    defp close!(issue) do
      {:ok, _} = Ash.update(issue, %{close_upstream: false}, action: :close)
    end

    test "renders weekly bars, lead-time histogram, P50/P90 and the weighting policy",
         %{conn: conn, ws: ws} do
      for d <- [1, 1, nil] do
        ws |> issue!(%{difficulty: d}) |> close!()
      end

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-throughput-chart rect[data-series='1'][data-value='2']")

      assert has_element?(
               view,
               "#reports-throughput-chart rect[data-series='unrated'][data-value='1']"
             )

      assert has_element?(view, "#reports-weighted-chart")
      assert has_element?(view, "#reports-lead-chart")
      assert has_element?(view, "#reports-lead-p50")
      assert has_element?(view, "#reports-lead-p90")
      assert has_element?(view, "#reports-lead-era")
      assert has_element?(view, "#reports-weighting-policy", "unrated")
    end
  end

  test "cost section shows metered dollars and marks unmetered providers", %{conn: conn, ws: ws} do
    issue = issue!(ws, %{difficulty: 2})
    {:ok, issue} = Ash.update(issue, %{close_upstream: false}, action: :close)

    for {provider, cost} <- [{"claude", 4.0}, {"gemini", nil}] do
      {:ok, _} =
        Ash.create(Arbiter.Usage.Event, %{
          task_id: issue.id,
          source: :task,
          step: :work,
          workspace_id: ws.id,
          occurred_at: DateTime.utc_now(),
          provider: provider,
          model: "m",
          cost_usd: cost
        })
    end

    {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
    _ = render_async(view)

    assert has_element?(view, "#reports-cost-d-2")
    assert has_element?(view, "#reports-cost-d-2", "$4.00")
    assert has_element?(view, "#reports-cost-d-2", "unmetered")
    assert has_element?(view, "#reports-cost-overhead")
  end

  describe "cumulative flow and stage dwell" do
    defp promote!(issue) do
      {:ok, issue} = Ash.update(issue, %{}, action: :promote)
      issue
    end

    defp start!(issue) do
      {:ok, issue} = Ash.update(issue, %{}, action: :start)
      issue
    end

    test "renders the flow chart with one column whose bands sum to the tickets created",
         %{conn: conn, ws: ws} do
      issue!(ws, %{difficulty: 1})
      ws |> issue!(%{difficulty: 1}) |> promote!()
      ws |> issue!(%{difficulty: 3}) |> promote!() |> start!()

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-flow")
      assert has_element?(view, "#reports-flow-chart rect[data-role=column][data-total='3']")
      assert has_element?(view, "#reports-flow-chart rect[data-series-backlog='1']")
      assert has_element?(view, "#reports-flow-chart rect[data-series-queued='1']")
      assert has_element?(view, "#reports-flow-chart rect[data-series-active='1']")
      assert has_element?(view, "#reports-flow-chart path[data-series='closed']")
      assert has_element?(view, "#reports-flow-cutover")
    end

    test "renders stage dwell for closed tickets: tiles, per-difficulty chart, per-stage table",
         %{conn: conn, ws: ws} do
      for d <- [1, 3] do
        ws |> issue!(%{difficulty: d}) |> promote!() |> start!() |> close!()
      end

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-dwell-n [data-role=value]", "2")
      assert has_element?(view, "#reports-dwell-queued-closed-p50")
      assert has_element?(view, "#reports-dwell-first-pr-p50")
      # Both tickets were started and closed within the same instant, so every
      # segment is zero-height and only the difficulty labels are drawn;
      # per-segment values are covered by Arbiter.Reports.FlowTest.
      assert has_element?(view, "#reports-dwell-chart text", "D1")
      assert has_element?(view, "#reports-dwell-chart text", "D3")
      assert has_element?(view, "#reports-dwell-table tr[data-stage=active]")
      assert has_element?(view, "#reports-dwell-table tr[data-stage=verifying]")
    end

    test "with no closed tickets the dwell section says so instead of drawing empty charts",
         %{conn: conn, ws: ws} do
      issue!(ws, %{difficulty: 1})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-dwell-empty")
      refute has_element?(view, "#reports-dwell-chart")
    end

    test "the epic filter narrows the flow to the epic's children", %{conn: conn, ws: ws} do
      epic = issue!(ws, %{issue_type: :epic, title: "the epic"})
      child = issue!(ws, %{difficulty: 2})
      issue!(ws, %{difficulty: 2})
      issue!(ws, %{difficulty: 2})

      Ash.create!(Arbiter.Tasks.Dependency, %{
        from_issue_id: epic.id,
        to_issue_id: child.id,
        type: :parent_of
      })

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)
      assert has_element?(view, "#reports-flow-chart rect[data-total='3']")

      assert has_element?(
               view,
               "#reports-filters select[name='filters[epic]'] option",
               "the epic"
             )

      view
      |> form("#reports-filters", filters: %{workspace: ws.id, epic: epic.id})
      |> render_change()

      assert_patch(
        view,
        ~p"/reports?#{%{workspace: ws.id, epic: epic.id, range: "30d"}}"
      )

      _ = render_async(view)
      assert has_element?(view, "#reports-flow-chart rect[data-total='1']")
      refute has_element?(view, "#reports-flow-chart rect[data-total='3']")
      assert has_element?(view, "#reports-tile-total [data-role=value]", "1")
    end

    test "an epic id that is not an epic falls back to any", %{conn: conn, ws: ws} do
      issue!(ws, %{difficulty: 2})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}&epic=bd-nope")
      _ = render_async(view)

      assert has_element?(view, "#reports-flow-chart rect[data-total='1']")
    end
  end

  describe "epic burn-up" do
    test "is absent until an epic is picked, then charts scope and done", %{conn: conn, ws: ws} do
      epic = issue!(ws, %{issue_type: :epic, title: "the epic"})
      child = issue!(ws, %{difficulty: 2})
      issue!(ws, %{difficulty: 2})

      Ash.create!(Arbiter.Tasks.Dependency, %{
        from_issue_id: epic.id,
        to_issue_id: child.id,
        type: :parent_of
      })

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)
      refute has_element?(view, "#reports-burn-up")

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}&epic=#{epic.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-burn-up")
      assert has_element?(view, "#reports-burn-up-chart path[data-role=scope]")
      assert has_element?(view, "#reports-burn-up-chart path[data-role=done]")

      assert has_element?(
               view,
               "#reports-burn-up-chart circle[data-role=scope-mark][data-value='1']"
             )

      assert has_element?(
               view,
               "#reports-burn-up-weighted-chart circle[data-role=scope-mark][data-value='2']"
             )

      assert has_element?(view, "#reports-burn-up-scope [data-role=value]", "1")
    end

    test "an epic with no children says so", %{conn: conn, ws: ws} do
      epic = issue!(ws, %{issue_type: :epic, title: "empty"})
      issue!(ws, %{difficulty: 2})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}&epic=#{epic.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-burn-up-empty")
    end
  end

  describe "ReviewGate health" do
    defp stamp!(table, id, at) do
      Arbiter.Repo.query!("UPDATE #{table} SET inserted_at = ? WHERE id = ?", [at, id])
    end

    defp round!(task_id, at, attrs) do
      {:ok, row} =
        Ash.create(
          Arbiter.ReviewGate.Round,
          Map.merge(%{task_id: task_id, round: 1, fix_round_attempt: 0, role: :review}, attrs)
        )

      stamp!("review_gate_rounds", row.id, at)
    end

    test "renders first-pass rate, rounds, outcomes, providers, resolutions and the start note",
         %{conn: conn, ws: ws} do
      now = DateTime.utc_now()
      recent = now |> DateTime.add(-86_400) |> DateTime.to_iso8601()
      a = issue!(ws, %{}).id
      b = issue!(ws, %{}).id

      round!(a, recent, %{verdict: :approve, converged: true, reviewer_provider: "claude"})
      round!(b, recent, %{verdict: :request_changes, reviewer_provider: "claude"})
      round!(b, recent, %{round: 2, verdict: :approve, converged: true})

      {:ok, _} =
        Arbiter.ReviewGate.Resolutions.record(%{task_id: b, decision: :amend, reasoning: "ok"})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-reviewgate")
      assert has_element?(view, "#reports-rg-first-pass", "50%")
      assert has_element?(view, "#reports-rg-rounds-chart rect[data-key='1']")
      assert has_element?(view, "#reports-rg-rounds-chart rect[data-key='2']")
      assert has_element?(view, "#reports-rg-outcomes-chart")
      assert has_element?(view, "#reports-rg-providers-table", "claude")
      assert has_element?(view, "#reports-rg-resolutions-table", "amend")
      assert has_element?(view, "#reports-rg-provider-note", "2026-09-20")
    end

    test "says so when there are no gate rounds", %{conn: conn, ws: ws} do
      issue!(ws, %{})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-rg-empty")
      refute has_element?(view, "#reports-rg-rounds-chart")
    end
  end

  describe "Epic Ready wait" do
    test "renders the head/tail table and the guard tile; says so when empty",
         %{conn: conn, ws: ws} do
      issue!(ws, %{})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-epic-waits")
      assert has_element?(view, "#reports-ew-guard", "—")
      assert has_element?(view, "#reports-ew-head")
      assert has_element?(view, "#reports-ew-tail")
      assert has_element?(view, "#reports-ew-row-guard")
      assert has_element?(view, "#reports-ew-row-head-p2")
      assert has_element?(view, "#reports-ew-empty")
    end
  end

  describe "Attention / wait time" do
    test "says so when there are no spans", %{conn: conn, ws: ws} do
      issue!(ws, %{})

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      assert has_element?(view, "#reports-attention")
      assert has_element?(view, "#reports-attention-empty")
    end

    test "renders per-cause rows and flags a still-open span", %{conn: conn, ws: ws} do
      issue = issue!(ws, %{})
      now = DateTime.utc_now()
      stamp = fn at -> DateTime.to_iso8601(%{at | microsecond: {elem(at.microsecond, 0), 6}}) end

      for {opened, cleared} <- [{3, 2}, {2, nil}] do
        Arbiter.Repo.query!(
          """
          INSERT INTO ticket_attention_spans
            (id, ticket_id, workspace_id, cause, owner, opened_at, cleared_at, derived, source,
             inserted_at, updated_at)
          VALUES (?, ?, ?, 'pr_closed', 'operator', ?, ?, 0, 'live', ?, ?)
          """,
          [
            Ecto.UUID.generate(),
            issue.id,
            ws.id,
            stamp.(DateTime.add(now, -opened * 3600)),
            cleared && stamp.(DateTime.add(now, -cleared * 3600)),
            stamp.(now),
            stamp.(now)
          ]
        )
      end

      {:ok, view, _html} = live(conn, ~p"/reports?workspace=#{ws.id}")
      _ = render_async(view)

      refute has_element?(view, "#reports-attention-empty")
      assert has_element?(view, "#reports-attention-row-pr_closed")
      assert has_element?(view, "#reports-attention-open", "1")
      assert has_element?(view, "#reports-attention-waiting-#{issue.id}-pr_closed")
      assert has_element?(view, "#reports-attention-operator")
    end
  end
end
