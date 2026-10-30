defmodule Arbiter.Workflows.MergeQueue.CiTriage do
  @moduledoc """
  Deterministic triage of a red MR pipeline, before a fix pass is spawned
  (GitHub #1144).

  Of 127 fix passes in 14 days only ~21 changed code; 35 reported "not my diff,
  re-ran CI" (flaky or unrelated tests, runner/infra failures) and most of the
  rest left no message. Telling those apart from the job data is mechanical, so
  it is Arbiter's chore, not an agent's. `classify/3` sorts a failed pipeline's
  checks (`Arbiter.Mergers.Merger.failing_check/0`) into one of:

    * `:infra` - every failing job died of the runner, not the code: a job
      timeout, `runner_system_failure`, a stuck or unschedulable pod, OOM kill,
      a DB pool timeout, a cancelled job.
    * `:unrelated_tests` - the failures are ExUnit test failures (optionally
      beside infra ones) in test files the diff does not touch, whose conventional
      subject module (or module directory) the diff does not touch, with no
      changed source file in the stack frames, and a diff that touches no shared
      build / test scope (`config/`, `mix.exs`, `test/support/`, migrations...).
      The positive evidence is a numbered `N) test ...` failure block (or an
      `N tests, M failures` line, M > 0), and the test files come only from those
      blocks, never from annotations or stray paths in the log.
    * `:target_red` - the target branch is itself red (`:target_hold`).
    * `:needs_agent` - anything touching the diff, a compile error, or anything
      this cannot read: an empty or unreadable diff, a truncated log excerpt, a
      test_helper crash, warnings-as-errors. **The default**: a failure is only
      waved through on positive evidence, so a real failure is never masked. A
      mixed pipeline (one infra job, one touching the diff) is `:needs_agent`.

  Infra is recognised two ways. A *structured* signal (GitLab `failure_reason`
  / `status`, GitHub `conclusion`) is authoritative. A *log phrase* ("Insufficient
  cpu", "unschedulable") is only trusted when the log names no changed file, the
  diff could be read, the excerpt is whole and no test-failure block is present
  (an OOM or a dropped pool connection can be a new bug's symptom).

  Pure: callers supply the failing checks and the PR's changed files (or
  `:unknown`). The result is `%{class, reason, evidence}`; `evidence` is one map
  per job (`:job`, `:verdict`, `:detail`, `:files`), and `render/1` turns the
  whole into the text recorded on the ticket and handed to a fix pass.
  """

  alias Arbiter.Workflows.MergeQueue.FlakeSuspect

  @type class :: :infra | :unrelated_tests | :target_red | :needs_agent
  @type verdict :: :infra | :unrelated_test | :touches_diff | :unknown
  @type evidence :: %{
          job: String.t(),
          verdict: verdict(),
          detail: String.t(),
          files: [String.t()]
        }
  @type result :: %{class: class(), reason: String.t(), evidence: [evidence()]}

  # GitLab `failure_reason` values that are the runner's, not the script's.
  @infra_failure_reasons ~w(
    runner_system_failure stuck_or_timeout_failure job_execution_timeout
    scheduler_failure runner_unsupported stale_schedule
  )

  # A check-run conclusion / job status that never gave a code verdict.
  @infra_conclusions ~w(timed_out cancelled canceled stale)

  # Log phrases that say the runner or its database, not the code, gave out.
  @infra_phrases [
    ~r/unschedulable/i,
    ~r/insufficient (?:cpu|memory)/i,
    ~r/OOMKilled|exit code 137|out of memory/i,
    ~r/runner has received a shutdown signal/i,
    ~r/lost communication with the server/i,
    ~r/exceeded the maximum execution time/i,
    ~r/no space left on device/i,
    ~r/ImagePullBackOff|ErrImagePull/i,
    ~r/connection not available and request was dropped from queue/i
  ]

  # A build that does not compile is the diff's, whatever else the log prints.
  @compile_errors ~r/CompileError|SyntaxError|TokenMissingError|Compilation failed|Could not compile|warnings as errors/i

  # A test run that failed on warnings, not on a test: the diff's own warnings.
  @warnings_failure ~r/Test suite (?:failed|aborted)[^\n]*warnings/i

  @path_line ~r/((?:[\w.\-]+\/)*[\w.\-]+\.\w+):\d+/

  # An ExUnit numbered failure header, and where its block ends.
  @block_header ~r/^\s*\d+\) (?:test|doctest|property) /
  @block_end ~r/^\s*(?:Finished in |Randomized with seed|\d+ (?:tests?|doctests?|properties|property)\b.*failures?)/
  @block_max_lines 40

  # `N tests, M failures`: only M > 0 is failure evidence.
  @summary_line ~r/(\d+) (?:tests?|doctests?|properties|property)(?:, \d+ doctests?)?, (\d+) failures?/

  # Files a green-to-red flip can come from without touching a test's own
  # subject: build config, dependencies, test support, schema migrations. When
  # the diff changes one, no test failure is "unrelated". Repo equivalents for
  # the non-Elixir stacks are listed beside the Elixir ones.
  @shared_scope ~r{(?:^|/)(?:config/|test/support/|spec/support/|priv/repo/migrations/|db/migrate/|\.github/workflows/)|(?:^|/)(?:mix\.exs|mix\.lock|test_helper\.exs|package\.json|package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Gemfile|Gemfile\.lock|go\.mod|go\.sum|Cargo\.toml|Cargo\.lock|pyproject\.toml|poetry\.lock|conftest\.py|spec_helper\.rb|rails_helper\.rb|\.gitlab-ci\.yml)$|(?:^|/)requirements[\w.\-]*\.txt$}

  # A failing "test" that is really the harness.
  @test_infra ~r{(?:^|/)(?:test_helper\.exs|test/support/[^\s]*|spec/support/[^\s]*|conftest\.py|spec_helper\.rb)$}

  @doc """
  Classify `checks` against `changed_files` (a list of repo-relative paths, or
  `:unknown` when the diff could not be read). `opts`: `:target_hold` - the
  reason string `CiSync.target_hold/5` gave when the target branch is red.
  """
  @spec classify(term(), [String.t()] | :unknown | term(), keyword()) :: result()
  def classify(checks, changed_files, opts \\ []) do
    # An empty list is an unreadable diff, not "the PR touched nothing".
    changed = if is_list(changed_files) and changed_files != [], do: changed_files, else: :unknown

    case Keyword.get(opts, :target_hold) do
      why when is_binary(why) and why != "" -> target_red(checks, changed, why)
      _ -> classify_checks(checks, changed)
    end
  end

  defp target_red(checks, changed, why) do
    %{
      class: :target_red,
      reason: "the target branch is red, so this MR cannot go green by itself: #{why}",
      evidence: judge_all(checks, changed)
    }
  end

  defp classify_checks(checks, changed) do
    case judge_all(checks, changed) do
      [] ->
        result(:needs_agent, "no failing-check data to triage", [])

      evidence ->
        aggregate(evidence)
    end
  end

  defp judge_all(checks, changed) when is_list(checks), do: Enum.map(checks, &judge(&1, changed))
  defp judge_all(_checks, _changed), do: []

  defp aggregate(evidence) do
    {bad, rest} = Enum.split_with(evidence, &(&1.verdict in [:touches_diff, :unknown]))

    cond do
      bad != [] ->
        result(
          :needs_agent,
          "#{length(bad)} of #{length(evidence)} failing job(s) touch the diff or could not " <>
            "be classified (#{names(bad)}); an agent must look",
          evidence
        )

      Enum.any?(rest, &(&1.verdict == :unrelated_test)) ->
        result(
          :unrelated_tests,
          "every failing job is a test failure in files the diff does not touch, or an " <>
            "infra failure (#{details(evidence)})",
          evidence
        )

      true ->
        result(
          :infra,
          "every failing job died of the runner, not the code (#{details(evidence)})",
          evidence
        )
    end
  end

  defp result(class, reason, evidence), do: %{class: class, reason: reason, evidence: evidence}

  defp names(evidence), do: evidence |> Enum.map(& &1.job) |> Enum.uniq() |> Enum.join(", ")

  defp details(evidence), do: Enum.map_join(evidence, "; ", &"#{&1.job}: #{&1.detail}")

  # ---- one job ----------------------------------------------------------

  defp judge(check, changed) when is_map(check) do
    job = to_string(field(check, :name) || "(unnamed job)")
    text = to_string(field(check, :summary) || "")
    refs = refs(check, text)

    ctx = %{
      text: text,
      refs: refs,
      blocks: failure_blocks(text),
      failures?: failure_count(text) > 0,
      truncated?: field(check, :truncated) == true,
      changed: changed
    }

    {verdict, detail, files} =
      case hard_infra(check) do
        nil -> judge_log(ctx)
        detail -> {:infra, detail, []}
      end

    entry(job, verdict, detail, files)
  end

  defp judge(_not_a_check, _changed),
    do: entry("(unreadable check)", :unknown, "not a failing-check map", [])

  # No structured infra signal: what the log and the diff say.
  defp judge_log(%{text: text, blocks: blocks, changed: changed} = ctx) do
    tests = block_tests(blocks)

    cond do
      Regex.match?(@compile_errors, text) ->
        {:touches_diff, "compile error in the log: the build itself is red", tests}

      Regex.match?(@warnings_failure, text) ->
        {:touches_diff, "the test run failed on warnings (warnings-as-errors)", tests}

      ctx.truncated? ->
        {:unknown, "the log excerpt was truncated; it may hide a failure of the diff", tests}

      changed == :unknown ->
        {:unknown, "the PR diff could not be read (empty, failed or overflowed)", tests}

      true ->
        judge_against_diff(ctx, tests)
    end
  end

  defp judge_against_diff(
         %{text: text, refs: refs, blocks: blocks, changed: changed} = ctx,
         tests
       ) do
    hits = diff_hits(refs, tests, changed)
    phrase = if blocks == [] and not ctx.failures?, do: soft_infra(text)

    cond do
      hits != [] ->
        {:touches_diff, "touches changed file(s): #{Enum.join(hits, ", ")}",
         hit_refs(hits, refs, tests)}

      phrase ->
        {:infra, "log says: #{phrase}", []}

      not (blocks != [] or ctx.failures?) ->
        {:unknown,
         "no ExUnit failure block in the log; cannot tell it from a failure of the diff", []}

      tests == [] ->
        {:unknown, "names no failing test file; cannot tell it from a failure of the diff", []}

      infra = Enum.find(blocks, &(&1.location && Regex.match?(@test_infra, &1.location))) ->
        {:touches_diff, "the failure is in test infrastructure (#{infra.location})", tests}

      scope = Enum.find(changed, &Regex.match?(@shared_scope, &1)) ->
        {:touches_diff, "the diff changes shared build/test scope (#{scope}); any test can break",
         tests}

      true ->
        {:unrelated_test, "failing test file(s) the diff does not touch", tests}
    end
  end

  # ---- ExUnit evidence --------------------------------------------------

  # The `N) test ...` blocks of an ExUnit report, each with the paths it prints.
  # `location` is the first one, which ExUnit prints right under the header: the
  # failing test's own file.
  defp failure_blocks(text) do
    lines = String.split(text, "\n")

    lines
    |> Enum.with_index()
    |> Enum.filter(fn {line, _} -> Regex.match?(@block_header, line) end)
    |> Enum.map(fn {_header, i} ->
      body =
        lines
        |> Enum.drop(i + 1)
        |> Enum.take(@block_max_lines)
        |> Enum.take_while(
          &(not Regex.match?(@block_header, &1) and not Regex.match?(@block_end, &1))
        )

      paths = for [_, path] <- Regex.scan(@path_line, Enum.join(body, "\n")), do: path
      %{location: List.first(paths), paths: paths}
    end)
  end

  # The failing test files: test paths printed inside failure blocks, minus the
  # harness frames (`test/support/...`) that only sit in a stack.
  defp block_tests(blocks) do
    blocks
    |> Enum.flat_map(fn %{location: location, paths: paths} ->
      Enum.filter(paths, &(test_path?(&1) and (&1 == location or not test_infra?(&1))))
    end)
    |> Enum.uniq()
  end

  defp test_infra?(path), do: Regex.match?(@test_infra, path)

  # Failures reported by `N tests, M failures` lines (summed over an umbrella).
  defp failure_count(text) do
    @summary_line
    |> Regex.scan(text)
    |> Enum.map(fn [_, _, failures] -> String.to_integer(failures) end)
    |> Enum.sum()
  end

  defp entry(job, verdict, detail, files),
    do: %{job: job, verdict: verdict, detail: detail, files: files}

  defp hard_infra(check) do
    reason = field(check, :failure_reason)
    status = field(check, :status)
    conclusion = field(check, :conclusion)

    cond do
      reason in @infra_failure_reasons -> "failure_reason #{reason}"
      conclusion in @infra_conclusions -> "conclusion #{conclusion}"
      status in @infra_conclusions -> "status #{status}"
      true -> nil
    end
  end

  defp soft_infra(text) do
    Enum.find_value(@infra_phrases, fn regex ->
      case Regex.run(regex, text) do
        [match | _] -> match
        nil -> nil
      end
    end)
  end

  # ---- the diff ---------------------------------------------------------

  defp refs(check, text) do
    from_files = check |> field(:files) |> List.wrap()
    from_text = @path_line |> Regex.scan(text) |> Enum.map(fn [_, path] -> path end)

    (from_files ++ from_text) |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
  end

  # Changed files the failure points at: a changed path named in the failure
  # (a failing test the PR edits, a changed source file in a stack frame), or a
  # changed source file that is the conventional subject of a failing test
  # (`drain_test.exs` <-> `drain.ex`).
  defp diff_hits(refs, tests, changed) do
    direct = Enum.filter(changed, fn file -> Enum.any?(refs, &same_path?(&1, file)) end)

    subjects =
      Enum.filter(changed, fn file ->
        not test_path?(file) and source_file?(file) and
          Enum.any?(tests, &(stem(&1) == stem(file) or same_module_dir?(&1, file)))
      end)

    Enum.uniq(direct ++ subjects)
  end

  defp hit_refs(hits, refs, tests) do
    direct = Enum.filter(refs, fn ref -> Enum.any?(hits, &same_path?(ref, &1)) end)

    via_subject =
      Enum.filter(tests, fn test ->
        Enum.any?(hits, &(stem(test) == stem(&1) or same_module_dir?(test, &1)))
      end)

    Enum.uniq(direct ++ via_subject)
  end

  # `lib/app/accounts.ex` (or anything in `lib/app/accounts/`) is the module
  # directory of `test/app/accounts/user_test.exs`. Roots (`apps/x/`) are compared
  # loosely: ExUnit prints app-relative paths, the diff repo-relative ones.
  defp same_module_dir?(test, source) do
    with {test_root, test_rel} <- split_root(test, ~w(test spec tests)),
         {src_root, src_rel} <- split_root(source, ~w(lib src)),
         true <- roots_compatible?(test_root, src_root) do
      test_dir = Path.dirname(test_rel)
      src_dir = Path.dirname(src_rel)
      src_module = Path.rootname(src_rel)

      test_dir == src_module or String.starts_with?(test_dir, src_module <> "/") or
        (src_dir != "." and test_dir == src_dir)
    else
      _ -> false
    end
  end

  defp split_root(path, markers) do
    segments = Path.split(path)

    case Enum.find_index(segments, &(&1 in markers)) do
      nil ->
        nil

      i ->
        {segments |> Enum.take(i) |> Enum.join("/"),
         segments |> Enum.drop(i + 1) |> Enum.join("/")}
    end
  end

  defp roots_compatible?(a, b),
    do:
      a == "" or b == "" or a == b or String.ends_with?(a, "/" <> b) or
        String.ends_with?(b, "/" <> a)

  defp same_path?(a, b),
    do: a == b or String.ends_with?(a, "/" <> b) or String.ends_with?(b, "/" <> a)

  defp test_path?(path), do: FlakeSuspect.test_path?(path)

  defp source_file?(path), do: Path.extname(path) not in ["", ".md", ".txt", ".rst", ".adoc"]

  # `board/drain_test.exs` and `board/drain.ex` -> "drain"; `test_foo.py` -> "foo".
  defp stem(path) do
    path
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/(_test|_spec|\.test|\.spec)$/, "")
    |> String.replace(~r/^test_/, "")
  end

  defp field(check, key), do: Map.get(check, key) || Map.get(check, Atom.to_string(key))

  # ---- rendering --------------------------------------------------------

  @doc """
  The triage as plain text for a ticket note or a fix-pass brief: the class, the
  reason and one line of evidence per job.
  """
  @spec render(result()) :: String.t()
  def render(%{class: class, reason: reason, evidence: evidence}) do
    lines =
      Enum.map(evidence, fn e ->
        files = if e.files == [], do: "", else: " [#{Enum.join(e.files, ", ")}]"
        "  - #{e.job}: #{e.verdict} - #{e.detail}#{files}"
      end)

    Enum.join(["CI triage: #{class} - #{reason}" | lines], "\n")
  end
end
