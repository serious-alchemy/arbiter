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
    * `:unrelated_tests` - the failures are test failures (optionally beside
      infra ones) in test files the diff does not touch, whose conventional
      subject module the diff does not touch, with no changed source file in the
      stack frames.
    * `:target_red` - the target branch is itself red (`:target_hold`).
    * `:needs_agent` - anything touching the diff, a compile error, or anything
      this cannot read. **The default**: a failure is only waved through on
      positive evidence, so a real failure is never masked. A mixed pipeline
      (one infra job, one touching the diff) is `:needs_agent`.

  Infra is recognised two ways. A *structured* signal (GitLab `failure_reason`
  / `status`, GitHub `conclusion`) is authoritative. A *log phrase* ("Insufficient
  cpu", "unschedulable") is only trusted when the log names no changed file and
  the diff could be read, since a log can mention anything.

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

  @path_line ~r/((?:[\w.\-]+\/)*[\w.\-]+\.\w+):\d+/

  @doc """
  Classify `checks` against `changed_files` (a list of repo-relative paths, or
  `:unknown` when the diff could not be read). `opts`: `:target_hold` - the
  reason string `CiSync.target_hold/5` gave when the target branch is red.
  """
  @spec classify(term(), [String.t()] | :unknown | term(), keyword()) :: result()
  def classify(checks, changed_files, opts \\ []) do
    changed = if is_list(changed_files), do: changed_files, else: :unknown

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
    tests = Enum.filter(refs, &test_path?/1)
    hits = if changed == :unknown, do: [], else: diff_hits(refs, tests, changed)

    cond do
      detail = hard_infra(check) ->
        entry(job, :infra, detail, [])

      Regex.match?(@compile_errors, text) ->
        entry(job, :touches_diff, "compile error in the log: the build itself is red", tests)

      changed == :unknown and (soft_infra(text) != nil or tests != []) ->
        entry(job, :unknown, "the PR diff could not be read", tests)

      hits != [] ->
        entry(
          job,
          :touches_diff,
          "touches changed file(s): #{Enum.join(hits, ", ")}",
          hit_refs(hits, refs, tests)
        )

      detail = soft_infra(text) ->
        entry(job, :infra, "log says: #{detail}", [])

      tests == [] ->
        entry(job, :unknown, "names no test file; cannot tell it from a failure of the diff", [])

      true ->
        entry(job, :unrelated_test, "failing test file(s) the diff does not touch", tests)
    end
  end

  defp judge(_not_a_check, _changed),
    do: entry("(unreadable check)", :unknown, "not a failing-check map", [])

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
          Enum.any?(tests, &(stem(&1) == stem(file)))
      end)

    Enum.uniq(direct ++ subjects)
  end

  defp hit_refs(hits, refs, tests) do
    direct = Enum.filter(refs, fn ref -> Enum.any?(hits, &same_path?(ref, &1)) end)
    via_subject = Enum.filter(tests, fn test -> Enum.any?(hits, &(stem(test) == stem(&1))) end)
    Enum.uniq(direct ++ via_subject)
  end

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
