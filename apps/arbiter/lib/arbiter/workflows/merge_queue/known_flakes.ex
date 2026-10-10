defmodule Arbiter.Workflows.MergeQueue.KnownFlakes do
  @moduledoc """
  The registry of CI tests known to fail intermittently, and the check that a
  red CI run failed in nothing else (bd-4qj7io).

  Between 09-28 and 10-10 about 40% of test-shard failures were flakes or merge
  skew, and every one of them cost a fix-pass worker: a cold spawn, ~10 minutes
  of CI and a held slot, to conclude "re-run it". `Arbiter.Worker.Watchdog`
  asks `confined/1` before it dispatches a fix pass: when every failing test in
  the run is registered here, it re-runs CI once on that head instead. The same
  test failing again on the re-run is no longer a flake to wait out, so the
  Watchdog dispatches the fix pass as it would for any real failure.

  This is different from `Arbiter.Workflows.MergeQueue.FlakeSuspect`, which
  guesses from the PR's diff (a test the PR never touched). A registry entry is
  a recorded fact about a test, and applies to a PR that touches it too.

  ## What counts as "confined"

  Read from the failing checks' log excerpts (`Arbiter.Mergers.CILogExcerpt`
  keeps ExUnit's numbered failure headers, `1) test <name> (<Module>)`, and the
  `N tests, M failures` line). Every failure must match an entry — same module,
  and the entry's `:test` text contained in the test name — and the headers
  found must account for every failure the run counted. Anything else is
  `:none`: a lint or build failure, an unregistered test, a log truncated
  before all its failures, or no test output at all. Unreadable means a fix
  pass, never a silent re-run.

  ## Adding an entry

  An entry is a statement that the test is flaky for a reason that is not the
  PR's: give its `:cause`, and the `:ticket` that tracks the fix. Remove it
  when the test is fixed; the registry test fails for an entry whose test no
  longer exists in the repo.
  """

  alias Arbiter.Mergers.Merger

  @type entry :: %{
          id: String.t(),
          module: String.t(),
          test: String.t(),
          ticket: String.t(),
          cause: String.t()
        }

  @entries [
    %{
      id: "dispatch-queue-quota-preflight-hold",
      module: "Arbiter.Workflows.DispatchQueueTest",
      test: "quota-exhausted pre-flight hold on the drain path",
      ticket: "bd-4qj7io",
      cause:
        "wall-clock budgets (500ms receives, a 400ms hold lead) around a drain that does " <>
          "SQLite round-trips off-process; a loaded CI box overruns them"
    },
    %{
      id: "remote-checkout-primary-veto",
      module: "ArbiterWeb.RemoteCheckoutTest",
      test: "a repo the primary vetoes",
      ticket: "bd-4qj7io",
      cause:
        "the refusal is an answer pushed once over a live node channel and then " <>
          "awaited with a bounded wait; a slow or flapping channel on CI outlasts it"
    },
    %{
      id: "ticket-watchdog-direct-strategy",
      module: "Arbiter.Worker.TicketWatchdogTest",
      test: "the Direct strategy",
      ticket: "bd-4qj7io",
      cause:
        "the Driver's max_ticks (200 x 10ms) was a 2s wall-clock budget for a real agent " <>
          "process plus a git merge; past it the Driver fails the run"
    },
    %{
      id: "worker-resume-rest-mcp-parity",
      module: "ArbiterWeb.Api.WorkerResumeParityTest",
      test: "REST and MCP resume spawn",
      ticket: "bd-4qj7io",
      cause:
        "two real spawns, each polled for 5s, with the first run's teardown racing " <>
          "the second resume"
    }
  ]

  # `  1) test <name> (<Module>)` — the name may itself contain parentheses.
  @failure_header ~r/^\s*\d+\) (?:test|doctest|property) (.+) \(([A-Z][\w.]*)\)\s*$/m
  @summary ~r/^\s*\d+ (?:tests?|doctests?|properties|examples?)[^\n]*?(\d+) failures?/m

  @doc "The registered known-flaky tests."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc """
  `{:ok, ids}` — the ids of the entries matched, sorted — when every failing
  test in every failing check is registered; otherwise `:none`.
  """
  @spec confined([Merger.failing_check()], [entry()]) :: {:ok, [String.t()]} | :none
  def confined(checks, entries \\ @entries)

  def confined([_ | _] = checks, [_ | _] = entries) do
    per_check = Enum.map(checks, &check_ids(&1, entries))

    if :none in per_check,
      do: :none,
      else:
        {:ok, per_check |> Enum.flat_map(fn {:ok, ids} -> ids end) |> Enum.uniq() |> Enum.sort()}
  end

  def confined(_checks, _entries), do: :none

  defp check_ids(check, entries) do
    summary = Map.get(check, :summary) || Map.get(check, "summary")

    with true <- is_binary(summary),
         [_ | _] = failures <- failures(summary),
         true <- counted(summary) == length(failures),
         matched = Enum.map(failures, &match_entry(&1, entries)),
         false <- nil in matched do
      {:ok, matched}
    else
      _ -> :none
    end
  end

  defp failures(summary) do
    @failure_header
    |> Regex.scan(summary)
    |> Enum.map(fn [_, name, module] -> {module, name} end)
  end

  # The failures the run said it had, summed over every app's summary line.
  # `nil` when the excerpt carries no summary line, which can never equal a
  # count of headers, so it reads as unreadable.
  defp counted(summary) do
    case Regex.scan(@summary, summary) do
      [] -> nil
      lines -> lines |> Enum.map(fn [_, n] -> String.to_integer(n) end) |> Enum.sum()
    end
  end

  defp match_entry({module, name}, entries) do
    Enum.find_value(entries, fn entry ->
      if entry.module == module and String.contains?(name, entry.test), do: entry.id
    end)
  end
end
