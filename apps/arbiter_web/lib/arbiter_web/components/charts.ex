defmodule ArbiterWeb.Charts do
  @moduledoc """
  Server-rendered inline-SVG chart components for `/reports` (bd-an8t0e;
  `docs/design/reports-design-v2.md` §7.2). No JS, no dependency: every mark
  is a real element carrying `data-*` values so LiveViewTest can assert on it,
  with an SVG `<title>` as the tooltip. Colours are the theme's CSS variables,
  so light/dark follow the theme.

  Data contract: a list of points per series.

    * `bar/1`, `area/1`, `step_line/1` — `%{key: term, label: String.t(), value: number}`
    * `stacked_bar/1`, `stacked_area/1` — `%{key:, label:, values: %{series_key => number}}`
      plus `series`, a list of `%{key:, label:}` (stacked bottom-up in list order)
    * `burn_up/1` — `%{key:, label:, scope: n, done: n}` (two step lines)
    * `histogram/1` — `%{from: number, to: number, count: number}`

  An empty point list renders an `data-empty` placeholder, never a blank axis.
  """
  use Phoenix.Component

  @w 640
  @h 240
  @left 40
  @right 8
  @top 8
  @bottom 28

  @palette Enum.map(
             ~w(info live attention proposal fail done),
             &"var(--arb-#{&1})"
           )

  @doc "Series colour for index `i` (cycles)."
  @spec series_color(non_neg_integer()) :: String.t()
  def series_color(i), do: Enum.at(@palette, rem(i, length(@palette)))

  # ---- stat tile ----

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :note, :string, default: nil
  attr :class, :any, default: nil

  def stat_tile(assigns) do
    ~H"""
    <div
      id={@id}
      data-chart="stat_tile"
      class={[
        "flex flex-col gap-[6px] px-[16px] py-[14px] min-w-0",
        "bg-[var(--surface-panel)] border border-[var(--border-default)] rounded-[var(--radius-panel)]",
        @class
      ]}
    >
      <span class="font-medium text-[10.5px] uppercase text-[var(--text-label)] font-[family-name:var(--font-mono)]">
        {@label}
      </span>
      <span data-role="value" class="font-semibold text-[26px] leading-none tabular-nums">
        {@value}
      </span>
      <span
        :if={@note}
        data-role="note"
        class="text-[11.5px] text-[var(--text-label)] font-[family-name:var(--font-mono)]"
      >
        {@note}
      </span>
    </div>
    """
  end

  # ---- bar ----

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :title, :string, required: true, doc: "accessible name"
  attr :color, :string, default: "var(--arb-info)"
  attr :empty, :string, default: "No data for these filters."

  def bar(assigns) do
    max = max_of(Enum.map(assigns.points, & &1.value))
    n = length(assigns.points)

    bars =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        {x, w} = column(i, n)
        h = scale(p.value, max)
        %{key: p.key, label: p.label, value: p.value, x: x, w: w, y: @top + plot_h() - h, h: h}
      end)

    assigns = assign(assigns, bars: bars, max: max, n: n)

    ~H"""
    <.frame id={@id} kind="bar" title={@title} empty={@empty} n={@n} max={@max}>
      <rect
        :for={b <- @bars}
        data-key={b.key}
        data-value={b.value}
        x={b.x}
        y={b.y}
        width={b.w}
        height={b.h}
        rx="2"
        fill={@color}
        class="arb-chart-mark"
      >
        <title>{b.label}: {b.value}</title>
      </rect>
      <.x_labels points={@points} />
    </.frame>
    """
  end

  # ---- stacked bar ----

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :series, :list, required: true
  attr :title, :string, required: true
  attr :empty, :string, default: "No data for these filters."

  def stacked_bar(assigns) do
    totals = Enum.map(assigns.points, fn p -> p.values |> Map.values() |> Enum.sum() end)
    max = max_of(totals)
    n = length(assigns.points)

    segments =
      assigns.points
      |> Enum.with_index()
      |> Enum.flat_map(fn {p, i} ->
        {x, w} = column(i, n)

        {segs, _} =
          assigns.series
          |> Enum.with_index()
          |> Enum.reduce({[], 0}, fn {s, si}, {acc, base} ->
            v = Map.get(p.values, s.key, 0)
            h = scale(v, max)
            top = base + h

            seg = %{
              key: p.key,
              series: s.key,
              label: "#{p.label} · #{s.label}",
              value: v,
              x: x,
              w: w,
              y: @top + plot_h() - top,
              h: h,
              color: series_color(si)
            }

            {if(v > 0, do: [seg | acc], else: acc), top}
          end)

        Enum.reverse(segs)
      end)

    assigns = assign(assigns, segments: segments, max: max, n: n)

    ~H"""
    <.frame id={@id} kind="stacked_bar" title={@title} empty={@empty} n={@n} max={@max}>
      <rect
        :for={s <- @segments}
        data-key={s.key}
        data-series={s.series}
        data-value={s.value}
        x={s.x}
        y={s.y}
        width={s.w}
        height={s.h}
        fill={s.color}
        class="arb-chart-mark"
      >
        <title>{s.label}: {s.value}</title>
      </rect>
      <.x_labels points={@points} />
    </.frame>
    <.legend :if={@n > 0} id={"#{@id}-legend"} series={@series} />
    """
  end

  # ---- stacked area ----

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :series, :list, required: true
  attr :title, :string, required: true
  attr :empty, :string, default: "No data for these filters."

  def stacked_area(assigns) do
    n = length(assigns.points)
    totals = Enum.map(assigns.points, fn p -> p.values |> Map.values() |> Enum.sum() end)
    max = max_of(totals)

    # `tops[i]` is the running total after each series, bottom-up, so band `s`
    # lies between `tops[s - 1]` and `tops[s]` at every point.
    tops =
      Enum.map(assigns.points, fn p ->
        assigns.series
        |> Enum.scan(0, fn s, acc -> acc + Map.get(p.values, s.key, 0) end)
      end)

    bands =
      assigns.series
      |> Enum.with_index()
      |> Enum.map(fn {s, si} ->
        upper =
          tops
          |> Enum.with_index()
          |> Enum.map(fn {t, i} -> {label_x(i, n), y_at(t, si, max)} end)

        lower =
          tops
          |> Enum.with_index()
          |> Enum.map(fn {t, i} -> {label_x(i, n), y_at(t, si - 1, max)} end)

        %{
          key: s.key,
          label: s.label,
          color: series_color(si),
          d: "M" <> polyline_xy(upper) <> " L" <> polyline_xy(Enum.reverse(lower)) <> " Z"
        }
      end)

    columns =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {p, i} ->
        {x, w} = column(i, n)

        %{
          key: p.key,
          x: x,
          w: w,
          total: Enum.at(totals, i),
          title:
            "#{p.label}: " <>
              Enum.map_join(assigns.series, ", ", &"#{&1.label} #{Map.get(p.values, &1.key, 0)}"),
          attrs: Map.new(assigns.series, &{"data-series-#{&1.key}", Map.get(p.values, &1.key, 0)})
        }
      end)

    assigns =
      assign(assigns, bands: bands, columns: columns, max: max, n: n, plot_h: plot_h(), top: @top)

    ~H"""
    <.frame id={@id} kind="stacked_area" title={@title} empty={@empty} n={@n} max={@max}>
      <path
        :for={b <- @bands}
        data-role="band"
        data-series={b.key}
        d={b.d}
        fill={b.color}
        fill-opacity="0.85"
        stroke={b.color}
        stroke-width="1"
      >
        <title>{b.label}</title>
      </path>
      <rect
        :for={c <- @columns}
        data-role="column"
        data-key={c.key}
        data-total={c.total}
        {c.attrs}
        x={c.x}
        y={@top}
        width={c.w}
        height={@plot_h}
        fill="transparent"
        class="arb-chart-mark"
      >
        <title>{c.title}</title>
      </rect>
      <.x_labels points={@points} />
    </.frame>
    <.legend :if={@n > 0} id={"#{@id}-legend"} series={@series} />
    """
  end

  # Height of the stack after series `si` (-1 = the baseline).
  defp y_at(_tops, -1, _max), do: @top + plot_h()
  defp y_at(tops, si, max), do: @top + plot_h() - scale(Enum.at(tops, si), max)

  defp polyline_xy(coords),
    do: Enum.map_join(coords, " L", fn {x, y} -> "#{fmt(x)},#{fmt(y)}" end)

  # ---- area ----

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :title, :string, required: true
  attr :color, :string, default: "var(--arb-info)"
  attr :empty, :string, default: "No data for these filters."

  def area(assigns) do
    {coords, max} = line_coords(assigns.points)
    base = @top + plot_h()

    area_d =
      case coords do
        [] ->
          ""

        _ ->
          {fx, _, _} = hd(coords)
          {lx, _, _} = List.last(coords)
          "M#{fmt(fx)},#{base} L#{polyline(coords)} L#{fmt(lx)},#{base} Z"
      end

    assigns = assign(assigns, coords: coords, max: max, n: length(coords), area_d: area_d)

    ~H"""
    <.frame id={@id} kind="area" title={@title} empty={@empty} n={@n} max={@max}>
      <path data-role="area" d={@area_d} fill={@color} fill-opacity="0.18" stroke="none" />
      <path
        data-role="line"
        d={"M" <> polyline(@coords)}
        fill="none"
        stroke={@color}
        stroke-width="2"
      />
      <circle
        :for={{x, y, p} <- @coords}
        data-key={p.key}
        data-value={p.value}
        cx={x}
        cy={y}
        r="3"
        fill={@color}
        class="arb-chart-mark"
      >
        <title>{p.label}: {p.value}</title>
      </circle>
      <.x_labels points={@points} />
    </.frame>
    """
  end

  # ---- step line ----

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :title, :string, required: true
  attr :color, :string, default: "var(--arb-live)"
  attr :empty, :string, default: "No data for these filters."

  def step_line(assigns) do
    {coords, max} = line_coords(assigns.points)

    d =
      case coords do
        [] ->
          ""

        [{x0, y0, _} | rest] ->
          Enum.reduce(rest, "M#{fmt(x0)},#{fmt(y0)}", fn {x, y, _}, acc ->
            acc <> " H#{fmt(x)} V#{fmt(y)}"
          end)
      end

    assigns = assign(assigns, coords: coords, max: max, n: length(coords), d: d)

    ~H"""
    <.frame id={@id} kind="step_line" title={@title} empty={@empty} n={@n} max={@max}>
      <path data-role="line" d={@d} fill="none" stroke={@color} stroke-width="2" />
      <circle
        :for={{x, y, p} <- @coords}
        data-key={p.key}
        data-value={p.value}
        cx={x}
        cy={y}
        r="3"
        fill={@color}
        class="arb-chart-mark"
      >
        <title>{p.label}: {p.value}</title>
      </circle>
      <.x_labels points={@points} />
    </.frame>
    """
  end

  # ---- pace lines ----

  attr :id, :string, required: true
  attr :points, :list, required: true, doc: "%{key:, label:, value: pct, ceiling: pct | nil}"
  attr :title, :string, required: true
  attr :empty, :string, default: "No data for these filters."

  # Utilization against the pace ceiling, both in percent on a fixed 0..100 axis.
  def pace_lines(assigns) do
    n = length(assigns.points)

    util =
      assigns.points
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> {label_x(i, n), @top + plot_h() - scale(p.value, 100), p} end)

    ceiling =
      assigns.points
      |> Enum.with_index()
      |> Enum.filter(fn {p, _} -> is_number(p.ceiling) end)
      |> Enum.map(fn {p, i} -> {label_x(i, n), @top + plot_h() - scale(p.ceiling, 100), p} end)

    assigns =
      assign(assigns,
        n: n,
        util: util,
        util_d: if(util == [], do: "", else: "M" <> polyline(util)),
        ceiling_d: if(ceiling == [], do: "", else: "M" <> polyline(ceiling)),
        series: [
          %{key: "utilization", label: "Utilization"},
          %{key: "ceiling", label: "Pace ceiling"}
        ]
      )

    ~H"""
    <.frame id={@id} kind="pace_lines" title={@title} empty={@empty} n={@n} max={100}>
      <path
        data-role="ceiling"
        d={@ceiling_d}
        fill="none"
        stroke="var(--arb-fail)"
        stroke-width="1.5"
        stroke-dasharray="4 3"
      />
      <path data-role="utilization" d={@util_d} fill="none" stroke="var(--arb-live)" stroke-width="2" />
      <circle
        :for={{x, y, p} <- @util}
        data-key={p.key}
        data-value={p.value}
        cx={x}
        cy={y}
        r="2.5"
        fill="var(--arb-live)"
        class="arb-chart-mark"
      >
        <title>
          {p.label}: {p.value}%<%= if p.ceiling do %>
            (ceiling {p.ceiling}%)
          <% end %>
        </title>
      </circle>
      <.x_labels points={@points} />
    </.frame>
    <.legend :if={@n > 0} id={"#{@id}-legend"} series={@series} />
    """
  end

  # ---- burn-up ----

  attr :id, :string, required: true
  attr :points, :list, required: true, doc: "%{key:, label:, scope: n, done: n}"
  attr :title, :string, required: true
  attr :empty, :string, default: "No data for these filters."

  def burn_up(assigns) do
    n = length(assigns.points)
    max = max_of(Enum.map(assigns.points, & &1.scope))

    scope = Enum.map(assigns.points, &{&1.scope, &1})
    done = Enum.map(assigns.points, &{&1.done, &1})
    scope_xy = step_xy(scope, n, max)
    done_xy = step_xy(done, n, max)

    # The open remainder: between the scope line and the done line.
    remainder =
      case {scope_xy, done_xy} do
        {[], _} ->
          ""

        _ ->
          "M" <>
            polyline_xy(Enum.map(scope_xy, fn {x, y, _} -> {x, y} end)) <>
            " L" <>
            polyline_xy(done_xy |> Enum.reverse() |> Enum.map(fn {x, y, _} -> {x, y} end)) <> " Z"
      end

    assigns =
      assign(assigns,
        n: n,
        max: max,
        scope_xy: scope_xy,
        done_xy: done_xy,
        scope_d: step_path(scope_xy),
        done_d: step_path(done_xy),
        remainder: remainder,
        today_x: if(n > 0, do: label_x(n - 1, n)),
        top: @top,
        base: @top + plot_h(),
        series: [%{key: "scope", label: "Scope"}, %{key: "done", label: "Done"}]
      )

    ~H"""
    <.frame id={@id} kind="burn_up" title={@title} empty={@empty} n={@n} max={@max}>
      <path data-role="remainder" d={@remainder} fill="var(--arb-info)" fill-opacity="0.12" />
      <path
        data-role="scope"
        d={@scope_d}
        fill="none"
        stroke="var(--arb-info)"
        stroke-width="2"
      />
      <path data-role="done" d={@done_d} fill="none" stroke="var(--arb-live)" stroke-width="2" />
      <line
        data-role="today"
        x1={@today_x}
        x2={@today_x}
        y1={@top}
        y2={@base}
        stroke="var(--border-strong)"
        stroke-dasharray="3 3"
      />
      <circle
        :for={{x, y, p} <- @scope_xy}
        data-role="scope-mark"
        data-key={p.key}
        data-value={p.scope}
        cx={x}
        cy={y}
        r="3"
        fill="var(--arb-info)"
        class="arb-chart-mark"
      >
        <title>{p.label}: scope {p.scope}</title>
      </circle>
      <circle
        :for={{x, y, p} <- @done_xy}
        data-role="done-mark"
        data-key={p.key}
        data-value={p.done}
        cx={x}
        cy={y}
        r="3"
        fill="var(--arb-live)"
        class="arb-chart-mark"
      >
        <title>{p.label}: done {p.done}</title>
      </circle>
      <.x_labels points={@points} />
    </.frame>
    <.legend :if={@n > 0} id={"#{@id}-legend"} series={@series} />
    """
  end

  defp step_xy(pairs, n, max) do
    pairs
    |> Enum.with_index()
    |> Enum.map(fn {{v, p}, i} -> {label_x(i, n), @top + plot_h() - scale(v, max), p} end)
  end

  defp step_path([]), do: ""

  defp step_path([{x0, y0, _} | rest]) do
    Enum.reduce(rest, "M#{fmt(x0)},#{fmt(y0)}", fn {x, y, _}, acc ->
      acc <> " H#{fmt(x)} V#{fmt(y)}"
    end)
  end

  # ---- histogram ----

  attr :id, :string, required: true
  attr :buckets, :list, required: true, doc: "[%{from:, to:, count:}], contiguous"
  attr :title, :string, required: true
  attr :color, :string, default: "var(--arb-proposal)"
  attr :unit, :string, default: ""
  attr :empty, :string, default: "No data for these filters."

  def histogram(assigns) do
    max = max_of(Enum.map(assigns.buckets, & &1.count))
    n = length(assigns.buckets)

    rects =
      assigns.buckets
      |> Enum.with_index()
      |> Enum.map(fn {b, i} ->
        w = plot_w() / max(n, 1)
        h = scale(b.count, max)

        %{
          from: b.from,
          to: b.to,
          count: b.count,
          x: @left + i * w,
          w: max(w - 1, 1),
          y: @top + plot_h() - h,
          h: h
        }
      end)

    assigns = assign(assigns, rects: rects, max: max, n: n, h_total: @h)

    ~H"""
    <.frame id={@id} kind="histogram" title={@title} empty={@empty} n={@n} max={@max}>
      <rect
        :for={r <- @rects}
        data-from={r.from}
        data-to={r.to}
        data-count={r.count}
        x={r.x}
        y={r.y}
        width={r.w}
        height={r.h}
        fill={@color}
        class="arb-chart-mark"
      >
        <title>{r.from}–{r.to}{@unit}: {r.count}</title>
      </rect>
      <text
        :for={{r, i} <- Enum.with_index(@rects)}
        :if={rem(i, label_every(@n)) == 0}
        x={r.x}
        y={@h_total - 8}
        font-size="10"
        fill="var(--text-label)"
      >
        {r.from}
      </text>
    </.frame>
    """
  end

  # ---- shared ----

  attr :id, :string, required: true
  attr :kind, :string, required: true
  attr :title, :string, required: true
  attr :empty, :string, required: true
  attr :n, :integer, required: true
  attr :max, :any, required: true
  slot :inner_block, required: true

  defp frame(assigns) do
    assigns = assign(assigns, w: @w, left: @left, top: @top, base: @top + plot_h())

    ~H"""
    <div
      :if={@n == 0}
      id={@id}
      data-chart={@kind}
      data-empty="true"
      class="flex items-center justify-center h-[120px] text-[12.5px] text-[var(--text-secondary)] rounded-[var(--radius-field)] border border-dashed border-[var(--border-strong)]"
    >
      {@empty}
    </div>
    <svg
      :if={@n > 0}
      id={@id}
      data-chart={@kind}
      data-max={@max}
      viewBox={"0 0 #{@w} 240"}
      role="img"
      aria-label={@title}
      class="w-full h-auto text-[var(--text-label)]"
    >
      <title>{@title}</title>
      <line
        x1={@left}
        x2={@w}
        y1={@base}
        y2={@base}
        stroke="var(--border-default)"
      />
      <line x1={@left} x2={@left} y1={@top} y2={@base} stroke="var(--border-default)" />
      <text x={@left - 6} y={@top + 8} text-anchor="end" font-size="10" fill="currentColor">
        {fmt(@max)}
      </text>
      <text x={@left - 6} y={@base} text-anchor="end" font-size="10" fill="currentColor">
        0
      </text>
      {render_slot(@inner_block)}
    </svg>
    """
  end

  attr :points, :list, required: true

  defp x_labels(assigns) do
    n = length(assigns.points)
    assigns = assign(assigns, n: n, every: label_every(n), h: @h)

    ~H"""
    <text
      :for={{p, i} <- Enum.with_index(@points)}
      :if={rem(i, @every) == 0}
      x={label_x(i, @n)}
      y={@h - 8}
      text-anchor="middle"
      font-size="10"
      fill="currentColor"
    >
      {p.label}
    </text>
    """
  end

  attr :id, :string, required: true
  attr :series, :list, required: true

  defp legend(assigns) do
    ~H"""
    <ul
      id={@id}
      class="flex flex-wrap gap-x-4 gap-y-1 mt-2 text-[11.5px] text-[var(--text-secondary)]"
    >
      <li
        :for={{s, i} <- Enum.with_index(@series)}
        data-series={s.key}
        class="flex items-center gap-[6px]"
      >
        <span class="inline-block size-[10px] rounded-[2px]" style={"background:#{series_color(i)}"} />
        {s.label}
      </li>
    </ul>
    """
  end

  defp plot_w, do: @w - @left - @right
  defp plot_h, do: @h - @top - @bottom

  defp column(i, n) do
    step = plot_w() / max(n, 1)
    pad = step * 0.15
    {@left + i * step + pad, step - 2 * pad}
  end

  defp label_x(i, n) do
    {x, w} = column(i, n)
    x + w / 2
  end

  defp label_every(n), do: max(ceil(n / 12), 1)

  defp max_of(values), do: values |> Enum.max(fn -> 0 end) |> max(0) |> nonzero()
  # `0.0` too: an all-zero float series (dwell medians) must not divide by zero.
  defp nonzero(v) when v == 0, do: 1
  defp nonzero(v), do: v

  defp scale(v, max), do: v / max * plot_h()

  # Points sit at slot centres so line charts line up with bar charts.
  defp line_coords(points) do
    max = max_of(Enum.map(points, & &1.value))
    n = length(points)

    coords =
      points
      |> Enum.with_index()
      |> Enum.map(fn {p, i} -> {label_x(i, n), @top + plot_h() - scale(p.value, max), p} end)

    {coords, max}
  end

  defp polyline(coords),
    do: Enum.map_join(coords, " L", fn {x, y, _} -> "#{fmt(x)},#{fmt(y)}" end)

  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 1)
  defp fmt(v), do: to_string(v)
end
