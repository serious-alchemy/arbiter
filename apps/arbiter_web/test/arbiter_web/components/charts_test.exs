defmodule ArbiterWeb.ChartsTest do
  use ArbiterWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ArbiterWeb.Charts

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp q(html, sel), do: html |> doc() |> LazyHTML.query(sel)

  defp attrs(html, sel, name),
    do: html |> q(sel) |> Enum.map(&(&1 |> LazyHTML.attribute(name) |> hd()))

  @weeks [
    %{key: "2026-W38", label: "W38", value: 4},
    %{key: "2026-W39", label: "W39", value: 8},
    %{key: "2026-W40", label: "W40", value: 0}
  ]

  test "stat_tile renders label, value and note" do
    html =
      render_component(&Charts.stat_tile/1, id: "t", label: "Done", value: 12, note: "last 30d")

    assert html |> q("#t[data-chart=stat_tile] [data-role=value]") |> LazyHTML.text() =~ "12"
    assert html |> q("#t [data-role=note]") |> LazyHTML.text() =~ "last 30d"
  end

  test "bar renders one rect per point scaled to the max" do
    html = render_component(&Charts.bar/1, id: "b", title: "Created", points: @weeks)

    assert attrs(html, "#b[data-chart=bar] rect", "data-key") == ~w(2026-W38 2026-W39 2026-W40)
    assert attrs(html, "#b rect", "data-value") == ~w(4 8 0)
    [h1, h2, h3] = attrs(html, "#b rect", "height") |> Enum.map(&String.to_float/1)
    assert_in_delta h1 * 2, h2, 0.01
    assert h3 == 0.0
    assert attrs(html, "#b", "data-max") == ["8"]
    assert html |> q("#b rect title") |> LazyHTML.text() =~ "W39: 8"
  end

  test "stacked_bar renders a segment per non-zero series value and a legend" do
    series = [%{key: "d1", label: "D1"}, %{key: "d2", label: "D2"}]

    points = [
      %{key: "w1", label: "W1", values: %{"d1" => 2, "d2" => 3}},
      %{key: "w2", label: "W2", values: %{"d1" => 0, "d2" => 5}}
    ]

    html =
      render_component(&Charts.stacked_bar/1, id: "s", title: "T", points: points, series: series)

    assert attrs(html, "#s[data-chart=stacked_bar] rect", "data-series") == ~w(d1 d2 d2)
    assert attrs(html, "#s rect", "data-value") == ~w(2 3 5)
    assert attrs(html, "#s-legend li", "data-series") == ~w(d1 d2)
    assert attrs(html, "#s", "data-max") == ["5"]
  end

  test "stacked_area stacks one band per series in order, with a hover column per point" do
    series = [%{key: :closed, label: "Closed"}, %{key: :open, label: "Open"}]

    points = [
      %{key: "d1", label: "D1", values: %{closed: 1, open: 2}},
      %{key: "d2", label: "D2", values: %{closed: 3, open: 1}}
    ]

    html =
      render_component(&Charts.stacked_area/1,
        id: "a",
        title: "T",
        points: points,
        series: series
      )

    assert attrs(html, "#a[data-chart=stacked_area] path[data-role=band]", "data-series") ==
             ~w(closed open)

    assert attrs(html, "#a rect[data-role=column]", "data-key") == ~w(d1 d2)
    assert attrs(html, "#a rect[data-role=column]", "data-total") == ~w(3 4)
    assert attrs(html, "#a rect[data-key=d2]", "data-series-closed") == ["3"]
    assert attrs(html, "#a rect[data-key=d2]", "data-series-open") == ["1"]
    assert attrs(html, "#a", "data-max") == ["4"]
    assert attrs(html, "#a-legend li", "data-series") == ~w(closed open)
  end

  test "an all-zero float series scales to the placeholder max instead of dividing by zero" do
    series = [%{key: :a, label: "A"}]
    points = [%{key: "k", label: "K", values: %{a: 0.0}}]

    html =
      render_component(&Charts.stacked_bar/1, id: "z", title: "T", points: points, series: series)

    assert attrs(html, "#z", "data-max") == ["1"]
  end

  test "area renders an area path, a line path and a marker per point" do
    html = render_component(&Charts.area/1, id: "a", title: "T", points: @weeks)

    assert html |> q("#a[data-chart=area] path[data-role=area]") |> Enum.count() == 1
    assert [d] = attrs(html, "#a path[data-role=line]", "d")
    assert String.starts_with?(d, "M")
    assert attrs(html, "#a circle", "data-value") == ~w(4 8 0)
  end

  test "step_line holds the value horizontally before stepping" do
    html = render_component(&Charts.step_line/1, id: "l", title: "T", points: @weeks)

    assert [d] = attrs(html, "#l[data-chart=step_line] path[data-role=line]", "d")
    assert [_move | steps] = String.split(d, " ")
    assert Enum.map(steps, &String.first/1) == ~w(H V H V)
    assert attrs(html, "#l circle", "data-key") == ~w(2026-W38 2026-W39 2026-W40)
  end

  test "histogram renders a rect per bucket with its range and count" do
    buckets = [%{from: 0, to: 2, count: 5}, %{from: 2, to: 4, count: 1}]
    html = render_component(&Charts.histogram/1, id: "h", title: "T", buckets: buckets, unit: "d")

    assert attrs(html, "#h[data-chart=histogram] rect", "data-from") == ~w(0 2)
    assert attrs(html, "#h rect", "data-to") == ~w(2 4)
    assert attrs(html, "#h rect", "data-count") == ~w(5 1)
  end

  describe "pace_lines/1 (bd-bq0gi8)" do
    # One point per fifth of the window; the stored ceiling is the gate's line.
    defp line_points(curve, floor) do
      for e <- [0.0, 0.2, 0.4, 0.6, 0.8, 1.0] do
        ceiling = Float.round(Arbiter.Quota.Pace.line(curve, floor, e) * 100, 1)
        %{key: "k#{e}", label: "#{e}", value: 5.0, ceiling: ceiling}
      end
    end

    # The ceiling path's y coordinates, top of the plot being the smallest.
    defp ceiling_ys(points) do
      html = render_component(&Charts.pace_lines/1, id: "p", title: "T", points: points)
      assert [d] = attrs(html, "#p path[data-role=ceiling]", "d")

      "M" <> rest = d

      rest
      |> String.split(" L")
      |> Enum.map(fn xy -> xy |> String.split(",") |> List.last() |> String.to_float() end)
    end

    test "the ramp is drawn as one straight line from the floor to 100% at the reset" do
      assert [y0, y1, y2, y3, y4, y5] = ys = ceiling_ys(line_points(:ramp, 0.10))

      # the ceiling is 10% at the reset and 100% at the next one
      assert y0 > y5
      steps = Enum.chunk_every(ys, 2, 1, :discard) |> Enum.map(fn [a, b] -> a - b end)
      assert Enum.all?(steps, &(abs(&1 - hd(steps)) < 0.25)), "not straight: #{inspect(steps)}"
      assert hd(steps) > 0, "no plateau at the start: #{inspect([y0, y1, y2, y3, y4])}"
    end

    test "the plateau curve, for contrast, is flat at the floor before it rises" do
      assert [y0, y1 | _] = ceiling_ys(line_points(:plateau, 0.35))
      assert y0 == y1
    end
  end

  test "every chart renders an empty placeholder, not an axis, with no points" do
    for {fun, extra} <- [
          {&Charts.bar/1, [points: []]},
          {&Charts.stacked_bar/1, [points: [], series: []]},
          {&Charts.stacked_area/1, [points: [], series: []]},
          {&Charts.area/1, [points: []]},
          {&Charts.step_line/1, [points: []]},
          {&Charts.histogram/1, [buckets: []]}
        ] do
      html = render_component(fun, [id: "e", title: "T"] ++ extra)
      assert html |> q("#e[data-empty=true]") |> Enum.count() == 1
      assert html |> q("svg") |> Enum.count() == 0
    end
  end
end
