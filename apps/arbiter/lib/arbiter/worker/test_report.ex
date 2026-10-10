defmodule Arbiter.Worker.TestReport do
  @moduledoc """
  Boils a `mix test` run down to what a worker needs to act on (bd-57nhsi): the
  pass/fail counts and, for each failing test, its ExUnit header, assertion and a
  few stacktrace frames — not the compile chatter, passing-test dots, warnings
  or seed lines that otherwise ride in the session's context for every later
  turn. The full log is kept on disk by the caller (`Arbiter.Worker.TestRun`).

  Pure: no I/O. `build/3` takes the raw output and the exit status and returns
  a report map; `render/1` turns it into the compact text the `run_tests` MCP
  tool hands back.

    * a green run (`exit 0`) is counts only;
    * a red run keeps every failing test's header and assertion, each block's
      stacktrace trimmed to `@stack_frames` frames, the whole bounded by
      `:limit` characters (default 3000). A tight cap shrinks the detail of
      each block, never drops a header: past `@max_listed` failures only the header
      line is kept, and past `@max_headers` the rest are summarised as a count;
    * a run that never reached a summary (compile error, missing file, boot
      failure) is an `:error` carrying `Arbiter.Mergers.CILogExcerpt` of the
      output, and a killed run is a `:timeout` carrying the output's tail.
  """

  alias Arbiter.Mergers.CILogExcerpt

  @default_limit 3000
  @stack_frames 3
  @max_listed 25
  @max_headers 100
  @max_line 140
  @min_block 160
  @timeout_statuses [124, 137]

  @ansi ~r/\e\[[0-9;?]*[A-Za-z]/
  @block_header ~r/^\s{0,4}(\d+)\) (test|doctest|property) /
  @summary ~r/^\s*(?:(\d+) doctests?, )?(?:(\d+) properties, )?(\d+) tests?, (\d+) failures?(?:, (\d+) invalid)?(?:, (\d+) skipped)?(?:, \((\d+) excluded\))?/
  @result_failed ~r/^\s*Result: (\d+)\/(\d+) passed(?:, (\d+) skipped)?/
  @result_passed ~r/^\s*Result: (\d+) passed(?:, (\d+) skipped)?/
  @chatter ~r/^\s*(Finished in |Result: |Failed: |Randomized with seed|Running ExUnit with|Excluding tags|Including tags)/

  @type status :: :passed | :failed | :error | :timeout
  @type t :: %{
          status: status(),
          exit_status: integer(),
          tests: non_neg_integer() | nil,
          failures: non_neg_integer() | nil,
          skipped: non_neg_integer(),
          summary: String.t(),
          failed_tests: [String.t()],
          omitted: non_neg_integer(),
          excerpt: String.t()
        }

  @doc """
  The report for `output` (the run's combined stdout/stderr) that exited with
  `exit_status`. Options: `:limit` — the character budget for the failure
  blocks / excerpt.
  """
  @spec build(String.t(), integer(), keyword()) :: t()
  def build(output, exit_status, opts \\ []) when is_binary(output) do
    limit = Keyword.get(opts, :limit, @default_limit)
    lines = output |> String.replace(@ansi, "") |> String.replace("\r", "") |> String.split("\n")
    counts = counts(lines)
    blocks = failure_blocks(lines)

    base = %{
      exit_status: exit_status,
      tests: counts && counts.tests,
      failures: counts && counts.failures,
      skipped: (counts && counts.skipped) || 0,
      summary: (counts && counts.line) || "",
      failed_tests: [],
      omitted: 0,
      excerpt: ""
    }

    classify(base, counts, blocks, exit_status, lines, limit)
  end

  defp classify(base, _counts, _blocks, status, lines, _limit) when status in @timeout_statuses do
    Map.merge(base, %{status: :timeout, excerpt: tail(lines, 1500)})
  end

  defp classify(base, %{failures: 0}, [], 0, _lines, _limit), do: Map.put(base, :status, :passed)

  defp classify(base, nil, [], 0, _lines, _limit), do: Map.put(base, :status, :passed)

  defp classify(base, counts, blocks, _status, lines, limit)
       when blocks != [] or (is_map(counts) and counts.failures > 0) do
    {shown, omitted} = fit(blocks, limit)

    Map.merge(base, %{
      status: :failed,
      failed_tests: shown,
      omitted: omitted,
      excerpt: if(blocks == [], do: excerpt(lines, limit), else: "")
    })
  end

  defp classify(base, _counts, _blocks, _status, lines, limit) do
    Map.merge(base, %{status: :error, excerpt: excerpt(lines, limit)})
  end

  @doc "The compact text form of a report: one line for a green run."
  @spec render(t()) :: String.t()
  def render(%{status: :passed} = r), do: "passed: #{counts_line(r)}"

  def render(%{status: :failed} = r) do
    omitted =
      if r.omitted > 0,
        do: ["... and #{r.omitted} more failing test(s) not listed; see the full log"],
        else: []

    extra = if r.excerpt == "", do: [], else: [r.excerpt]

    Enum.join(["FAILED: #{counts_line(r)}" | r.failed_tests ++ omitted ++ extra], "\n\n")
  end

  def render(%{status: :timeout} = r),
    do: "TIMED OUT (exit #{r.exit_status}); output tail:\n#{r.excerpt}"

  def render(%{status: :error} = r) do
    head = "ERROR: mix test exited #{r.exit_status} without a passing result"
    if r.excerpt == "", do: head, else: head <> "\n" <> r.excerpt
  end

  defp counts_line(%{tests: nil}), do: "no test summary"

  defp counts_line(r) do
    skipped = if r.skipped > 0, do: ", #{r.skipped} skipped", else: ""
    "#{r.tests} tests, #{r.failures} failures#{skipped}"
  end

  # -- counts ---------------------------------------------------------------

  # One summary line per umbrella app run; sum them.
  defp counts(lines) do
    case Enum.flat_map(lines, &summary_counts/1) do
      [] ->
        nil

      found ->
        %{
          line: Enum.map_join(found, "; ", & &1.line),
          tests: found |> Enum.map(& &1.tests) |> Enum.sum(),
          failures: found |> Enum.map(& &1.failures) |> Enum.sum(),
          skipped: found |> Enum.map(& &1.skipped) |> Enum.sum()
        }
    end
  end

  # ExUnit's own `N tests, M failures`, or this repo's `Result:` formatter.
  defp summary_counts(line) do
    cond do
      caps = Regex.run(@summary, line) ->
        [_ | rest] = caps
        [doctests, properties, tests, failures, _invalid, skipped] = pad(rest, 6)

        [
          %{
            line: String.trim(line),
            tests: int(doctests) + int(properties) + int(tests),
            failures: int(failures),
            skipped: int(skipped)
          }
        ]

      caps = Regex.run(@result_failed, line) ->
        [_, passed, total, skipped] = pad(caps, 4)

        [
          %{
            line: String.trim(line),
            tests: int(total),
            failures: int(total) - int(passed),
            skipped: int(skipped)
          }
        ]

      caps = Regex.run(@result_passed, line) ->
        [_, passed, skipped] = pad(caps, 3)

        [
          %{
            line: String.trim(line),
            tests: int(passed) + int(skipped),
            failures: 0,
            skipped: int(skipped)
          }
        ]

      true ->
        []
    end
  end

  defp pad(list, size), do: list ++ List.duplicate("", max(size - length(list), 0))
  defp int(""), do: 0
  defp int(n), do: String.to_integer(n)

  # -- failure blocks -------------------------------------------------------

  defp failure_blocks(lines) do
    {blocks, current} =
      Enum.reduce(lines, {[], nil}, fn line, {blocks, current} ->
        cond do
          Regex.match?(@block_header, line) -> {close(blocks, current), [line]}
          current == nil -> {blocks, nil}
          block_end?(line) or unindented?(line) -> {close(blocks, current), nil}
          true -> {blocks, [line | current]}
        end
      end)

    blocks |> close(current) |> Enum.reverse()
  end

  defp close(blocks, nil), do: blocks
  defp close(blocks, current), do: [trim_block(Enum.reverse(current)) | blocks]

  # A block runs to the next header or to the run's closing chatter, not to the
  # next blank line: assertion output (diffs, `code:`) contains blank lines.
  # ExUnit indents a failure's body; the dots, log lines and chatter that follow
  # it start at the left margin.
  defp unindented?(line), do: String.trim(line) != "" and not String.starts_with?(line, "    ")

  defp block_end?(line), do: Regex.match?(@chatter, line) or Regex.match?(@summary, line)

  defp trim_block(lines) do
    lines = trim_blank(lines)
    {detail, stack} = Enum.split_while(lines, &(not stacktrace_marker?(&1)))

    case stack do
      [] ->
        Enum.join(detail, "\n")

      [marker | frames] ->
        kept = frames |> Enum.reject(&(String.trim(&1) == "")) |> Enum.take(@stack_frames)
        Enum.join(detail ++ [marker | kept], "\n")
    end
  end

  defp stacktrace_marker?(line), do: String.trim(line) == "stacktrace:"

  defp trim_blank(lines) do
    lines |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse() |> trim_trailing()
  end

  defp trim_trailing(rev) do
    rev |> Enum.drop_while(&(String.trim(&1) == "")) |> Enum.reverse()
  end

  # -- fitting to the cap ---------------------------------------------------

  # The first `@max_listed` blocks keep their assertion (shrunk to fit `limit`);
  # past that only the header line is kept, up to `@max_headers`, so every
  # failing test is still named on a run with dozens of failures.
  defp fit(blocks, limit) do
    {listed, rest} = Enum.split(blocks, @max_listed)
    total = listed |> Enum.map(&String.length/1) |> Enum.sum()

    shown =
      if total <= limit do
        listed
      else
        per_block = max(div(limit, max(length(listed), 1)), @min_block)
        Enum.map(listed, &shrink(&1, per_block))
      end

    {headers, dropped} = Enum.split(rest, @max_headers - @max_listed)
    {shown ++ Enum.map(headers, &hd(String.split(&1, "\n"))), length(dropped)}
  end

  # Keep the header (and the file:line under it), then as much of the assertion
  # as the per-block budget allows, long lines clipped.
  defp shrink(block, budget) do
    if String.length(block) <= budget do
      block
    else
      [header | detail] = block |> String.split("\n") |> Enum.map(&clip/1)

      {kept, _} =
        Enum.reduce_while(detail, {[], String.length(header)}, fn line, {acc, used} ->
          size = String.length(line) + 1

          if used + size > budget,
            do: {:halt, {acc, used}},
            else: {:cont, {[line | acc], used + size}}
        end)

      Enum.join([header | Enum.reverse(kept)] ++ ["     ... (trimmed)"], "\n")
    end
  end

  defp clip(line) do
    if String.length(line) > @max_line,
      do: String.slice(line, 0, @max_line - 3) <> "...",
      else: line
  end

  # -- non-test failures ----------------------------------------------------

  defp excerpt(lines, limit), do: lines |> Enum.join("\n") |> CILogExcerpt.extract(limit)

  defp tail(lines, limit) do
    text = lines |> Enum.join("\n") |> String.trim()
    size = String.length(text)
    if size <= limit, do: text, else: "..." <> String.slice(text, size - limit, limit)
  end
end
