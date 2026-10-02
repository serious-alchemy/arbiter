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
    {:ok, issue} = Ash.create(Issue, Map.merge(%{title: "t", workspace_id: ws.id}, attrs))
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
end
