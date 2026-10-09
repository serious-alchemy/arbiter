defmodule Arbiter.Mergers.CILogExcerpt do
  @moduledoc """
  Boils a failed CI job's raw log down to the part a fix pass needs: failing
  test names, `file:line` pointers, and assertion / error blocks, bounded in
  size (bd-1fzpx8).

  A podman worker has no forge credential and no `gh`, so the host fetches the
  log and this module filters it before it goes into the fix-pass prompt. Pure:
  no I/O. When nothing in the log looks like a failure it falls back to the
  log's tail, so a briefing never carries *less* than the old raw tail did.
  """

  @ansi ~r/\e\[[0-9;?]*[A-Za-z]/
  # GitHub Actions prefixes every line with an ISO timestamp.
  @gh_timestamp ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z ?/
  # GitLab's collapsible-section markers (`section_start:123:name\r\e[0K`).
  @gl_section ~r/section_(start|end):\d+:[\w.\-]+\r?/

  # An ExUnit-style numbered failure header: `  1) test name (Module)`.
  @block_header ~r/^\s*\d+\) (test|doctest|property) /
  @block_max_lines 30

  # Single lines worth keeping, with a little context around them.
  @marker_patterns [
    ~r/\*\* \(\w[\w.]*\)/,
    ~r/Assertion with .* failed/,
    ~r/^\s*(left|right|code|actual|expected):/i,
    ~r/##\[error\]/,
    ~r/^\s*(FAIL|FAILED|ERROR)\b/,
    ~r/\b(AssertionError|Traceback|panic:|Exception|error\[E\d+\])/,
    ~r/^\s*(error|fatal)\b:?/i,
    ~r/^\s*(✗|✘|×)/u,
    ~r/\b[\w.\/-]+\.(exs?|rb|py|go|rs|ts|tsx|js|jsx|java|kt|c|cc|cpp|h):\d+/,
    ~r/^\s*\d+ (tests?|doctests?|properties|examples?), \d+ failures?/,
    ~r/^\s*(Tests|Test Suites):.*failed/,
    ~r/^---\s+FAIL:/
  ]

  @summary ~r/^\s*\d+ (tests?|doctests?|properties|examples?), \d+ failures?/

  @context_before 1
  @context_after 2

  @doc """
  Extract at most roughly `limit` characters of failure-relevant text from
  `log`. Returns `""` for an empty or non-binary log.
  """
  @spec extract(term(), pos_integer()) :: String.t()
  def extract(log, limit) when is_binary(log) and is_integer(limit) and limit > 0 do
    lines = clean_lines(log)
    total = length(lines)
    indexed = Enum.with_index(lines)

    blocks = indexed |> block_ranges(total) |> Enum.sort() |> merge()
    summaries = for {line, i} <- indexed, Regex.match?(@summary, line), do: {i, i}
    primary = merge(Enum.sort(blocks ++ summaries))

    markers =
      for {line, i} <- indexed, marker?(line) do
        {max(i - @context_before, 0), min(i + @context_after, total - 1)}
      end

    if primary == [] and markers == [] do
      tail(Enum.join(lines, "\n") |> String.trim(), limit)
    else
      assemble(blocks, summaries, markers, lines, limit)
    end
  end

  def extract(_log, _limit), do: ""

  defp clean_lines(log) do
    log
    |> String.replace(@ansi, "")
    |> String.replace(@gl_section, "")
    |> String.replace("\r", "")
    |> String.split("\n")
    |> Enum.map(&Regex.replace(@gh_timestamp, &1, ""))
    |> Enum.map(&String.trim_trailing/1)
  end

  # Failure blocks and the run's summary line are what a fix pass needs most,
  # so they are budgeted first (blocks up to 80% of the limit); generic
  # file:line / error lines — which a noisy compile or slow-test report can
  # produce in bulk — only fill whatever budget is left. Rendered in log order.
  defp assemble(blocks, summaries, markers, lines, limit) do
    kept_blocks = take_within(blocks, lines, div(limit * 4, 5), 0, [])
    primary = merge(Enum.sort(kept_blocks ++ summaries))
    left = limit - rendered_size(primary, lines)

    kept_markers =
      markers
      |> Enum.sort()
      |> merge()
      |> Enum.reject(&overlaps_any?(&1, blocks ++ summaries))
      |> take_within(lines, left, 0, [])

    (primary ++ kept_markers)
    |> Enum.sort()
    |> render(lines)
    |> bound(limit)
  end

  # Greedy, in log order; the first range is always kept so a single oversized
  # failure block is truncated by `bound/2` rather than dropped.
  defp take_within([], _lines, _budget, _used, acc), do: Enum.reverse(acc)

  defp take_within([range | rest], lines, budget, used, acc) do
    size = rendered_size([range], lines)

    if used + size <= budget or (acc == [] and used == 0),
      do: take_within(rest, lines, budget, used + size, [range | acc]),
      else: take_within(rest, lines, budget, used, acc)
  end

  defp rendered_size(ranges, lines), do: ranges |> render(lines) |> String.length() |> Kernel.+(3)

  defp overlaps_any?({s, e}, ranges),
    do: Enum.any?(ranges, fn {ps, pe} -> s <= pe and e >= ps end)

  defp block_ranges(indexed, total) do
    for {line, i} <- indexed, Regex.match?(@block_header, line) do
      stop =
        indexed
        |> Enum.drop(i + 1)
        |> Enum.take(@block_max_lines)
        |> Enum.find_value(fn {l, j} -> if Regex.match?(@block_header, l), do: j - 1 end)

      {i, stop || min(i + @block_max_lines, total - 1)}
    end
  end

  defp marker?(line), do: Enum.any?(@marker_patterns, &Regex.match?(&1, line))

  defp merge(ranges) do
    ranges
    |> Enum.reduce([], fn
      {s, e}, [{ps, pe} | rest] when s <= pe + 1 -> [{ps, max(e, pe)} | rest]
      range, acc -> [range | acc]
    end)
    |> Enum.reverse()
  end

  defp render(ranges, lines) do
    ranges
    |> Enum.map(fn {s, e} ->
      lines |> Enum.slice(s..e//1) |> trim_blank() |> Enum.join("\n")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n…\n")
  end

  defp trim_blank(lines) do
    lines
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  # Over the limit: keep the head (the first failures) and the tail (the run's
  # closing summary line, e.g. "100 tests, 100 failures"), elide the middle.
  defp bound(text, limit) do
    len = String.length(text)

    if len <= limit do
      text
    else
      tail_len = div(limit, 5)
      head_len = limit - tail_len
      String.slice(text, 0, head_len) <> "\n…\n" <> String.slice(text, len - tail_len, tail_len)
    end
  end

  defp tail(text, limit) do
    len = String.length(text)
    if len > limit, do: "…" <> String.slice(text, len - limit, limit), else: text
  end
end
