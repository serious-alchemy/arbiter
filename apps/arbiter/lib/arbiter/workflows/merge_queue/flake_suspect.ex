defmodule Arbiter.Workflows.MergeQueue.FlakeSuspect do
  @moduledoc """
  Tells whether a `:ci_failed` block fails only in test files the PR never
  touched (bd-2l0hzm).

  PR #2003 was docs only. It went red three times, each time on a different
  flaky test (a `DataCase` teardown race, a drain-status race, a coverage
  test), and each red run dispatched a fix pass. One of them "fixed" an
  unrelated flaky test on the docs branch. The Watchdog uses this module to
  re-run CI instead of dispatching a fix pass when the failure is outside the
  diff. See `Arbiter.Worker.Watchdog`'s `:ci_failed` handling for what it does
  when the re-run fails as well.

  Pure: callers supply the failing checks (`Arbiter.Mergers.Merger.failing_check/0`)
  and the PR's changed files.
  """

  alias Arbiter.Mergers.Merger

  # `path:line` references in a failure log. ExUnit prints app-relative paths
  # (`test/arbiter/x_test.exs:12`), so a path needs no leading directory.
  @path_line ~r/((?:[\w.\-]+\/)*[\w.\-]+\.\w+):\d+/

  # A test file by the usual conventions: under a test/spec directory, or
  # named `*_test.*`, `*_spec.*`, `*.test.*`, `test_*.py`.
  @test_path ~r/(^|\/)(test|tests|spec|__tests__)\/|_test\.\w+$|_spec\.\w+$|\.test\.\w+$|(^|\/)test_[^\/]+\.py$/

  @type verdict :: {:outside_diff, [String.t()]} | :in_diff | :unknown

  @doc """
  `{:outside_diff, test_files}` when every failing check is a test failure and
  none of those test files is among `changed_files`. `:in_diff` when the PR
  touches one of them. `:unknown` when a failing check names no test file (a
  lint or build failure, or no log context), or the diff could not be read.
  """
  @spec classify([Merger.failing_check()], [String.t()] | :unknown) :: verdict()
  def classify(_checks, :unknown), do: :unknown

  def classify(checks, changed_files) when is_list(changed_files) do
    case failing_tests(checks) do
      {:ok, files} ->
        if outside_diff?(files, changed_files), do: {:outside_diff, files}, else: :in_diff

      :unknown ->
        :unknown
    end
  end

  @doc """
  The test files the failing checks point at, in order, without duplicates.
  `:unknown` unless every check names at least one: a check with no test file
  could be anything, so the failure as a whole cannot be called a test flake.
  """
  @spec failing_tests([Merger.failing_check()]) :: {:ok, [String.t()]} | :unknown
  def failing_tests([]), do: :unknown

  def failing_tests(checks) when is_list(checks) do
    per_check = Enum.map(checks, &check_test_files/1)

    if Enum.any?(per_check, &(&1 == [])),
      do: :unknown,
      else: {:ok, per_check |> List.flatten() |> Enum.uniq()}
  end

  @doc """
  True when no file in `test_files` is among `changed_files`. Paths match when
  equal or when one is the other under a directory prefix, so the app-relative
  path ExUnit prints matches the repo-relative path in the diff.
  """
  @spec outside_diff?([String.t()], [String.t()]) :: boolean()
  def outside_diff?(test_files, changed_files) do
    not Enum.any?(test_files, fn file -> Enum.any?(changed_files, &same_path?(file, &1)) end)
  end

  defp same_path?(a, b),
    do: a == b or String.ends_with?(a, "/" <> b) or String.ends_with?(b, "/" <> a)

  defp check_test_files(check) do
    from_files = check |> field(:files) |> List.wrap()

    from_summary =
      @path_line
      |> Regex.scan(field(check, :summary) || "")
      |> Enum.map(fn [_, path] -> path end)

    (from_files ++ from_summary)
    |> Enum.filter(&(is_binary(&1) and Regex.match?(@test_path, &1)))
    |> Enum.uniq()
  end

  defp field(check, key), do: Map.get(check, key) || Map.get(check, Atom.to_string(key))
end
