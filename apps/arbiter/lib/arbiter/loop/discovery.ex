defmodule Arbiter.Loop.Discovery do
  @moduledoc """
  Loop discovery **Stage 1** (bd-4f6opo, #1468): the opt-in `--discover`
  report tier. The first model call inside `Arbiter.Loop` — decided in
  `docs/design/loop-inference-discovery-pass.md` §§2–4, and fenced accordingly.

  ## What it does

  One model call per pass over the **finding residue and only the finding
  residue** — the reviewer-finding units `Arbiter.Loop.FindingBuckets` matched
  to no bucket, which `Arbiter.Loop.Corpus` already retains on
  `meta.finding_residue.units`. The model proposes **candidate detectors**: a
  would-be `@finding_buckets` tuple (regex + category name), the slice units it
  claims the regex matches, and a one-line rationale. Never a finding.

  ## The fences

    * **Bounded slice** (`slice/1`): at most `unit_cap/0` units, newest-first,
      each truncated to `unit_text_limit/0` characters, tagged
      `{task_id, run_id}` for citation. Enforced here, independently of the
      bound `Corpus` already applies. The slice and the history below are
      reads of the `review_gate_rounds.findings` column; nothing on this path
      calls `Arbiter.Worker.OutputLog` (a test asserts it on the BEAM).
    * **Deterministic pre-check** (`precheck/4`) before a candidate is shown to
      anyone: the regex is compiled and run over the window's slice — a
      candidate whose regex does not match every unit it claims is dropped,
      with the discrepancy reported — and over retained history, where it must
      clear the evidence bar (≥ `min_incidents` units across ≥
      `min_distinct_tasks` tasks). The model's confidence is never requested
      and never read.
    * **Zero writes.** The only row this pass inserts is its own
      `usage_events` cost row, through `Corpus.record_pass_cost/1` under step
      `:loop_discovery`. It never calls `Arbiter.Loop.record/2`, so no model
      output reaches `Arbiter.Loop.fingerprint/1`, a `PendingWrite`, or the
      evidence count. A human merging a candidate into `@finding_buckets` is
      the only way one ever becomes a detector (discovery Stage 2).
    * **Off by default.** `Arbiter.Loop.Analysis.analyze/1` only calls `run/2`
      under `discover?: true`.

  ## The invoker

  `:invoker` in opts, else `config :arbiter, :loop_discovery_invoker`, else
  `Arbiter.Loop.Discovery.ClaudeInvoker`. Either a module exporting
  `invoke/2` or a 2-arity function, `(prompt, opts) -> {:ok, text, usage} |
  {:error, reason}`. The value `:disabled` refuses without spawning anything —
  what `config/test.exs` sets, so no test can exec a real CLI by accident.
  """

  require Logger

  alias Arbiter.Loop.{Corpus, FindingBuckets, Scarcity}

  # §4: one string per unit, ≤ 400 chars, ≤ 300 units newest-first.
  @unit_cap 300
  @unit_text_limit 400
  # A pass emits at most this many candidates; the rest are rejected (counted).
  @candidate_cap 10
  # A detector is one alternation of phrases, not a program.
  @regex_max_length 300
  @rationale_max_length 200
  # "Retained history" = the residue over this many analysis windows ending at
  # the window's `until` (design §2 step 2: "the last N windows' residue").
  @history_windows 4
  @history_unit_cap @unit_cap * @history_windows
  @citation_n 10

  @type slice_unit :: %{
          index: pos_integer(),
          task_id: String.t(),
          run_id: String.t() | nil,
          text: String.t()
        }

  @doc "Maximum units in one pass's slice."
  @spec unit_cap() :: pos_integer()
  def unit_cap, do: @unit_cap

  @doc "Per-unit character bound in the slice."
  @spec unit_text_limit() :: pos_integer()
  def unit_text_limit, do: @unit_text_limit

  @doc "Maximum candidates one pass may emit."
  @spec candidate_cap() :: pos_integer()
  def candidate_cap, do: @candidate_cap

  @doc """
  Bound and index the residue units: the first `unit_cap/0` (callers pass them
  newest-first), each truncated to `unit_text_limit/0` characters, numbered
  from 1 for citation.
  """
  @spec slice([map()]) :: [slice_unit()]
  def slice(units) when is_list(units) do
    units
    |> Enum.take(@unit_cap)
    |> Enum.with_index(1)
    |> Enum.map(fn {u, i} ->
      %{index: i, task_id: u.task_id, run_id: u.run_id, text: truncate(u.text, @unit_text_limit)}
    end)
  end

  @doc """
  The prompt for one pass. Carries the slice's unit text by index and nothing
  else from the corpus — no task ids, no transcripts.
  """
  @spec build_prompt([slice_unit()]) :: String.t()
  def build_prompt(slice) do
    units = Enum.map_join(slice, "\n", fn u -> "[#{u.index}] #{one_line(u.text)}" end)
    existing = Enum.map_join(FindingBuckets.categories(), "\n", &"  - #{&1}")

    """
    You are helping maintain a deterministic classifier of code-review findings.
    It sorts each reviewer finding into a category with a fixed list of
    case-insensitive regexes. The findings below matched NONE of the existing
    categories:

    #{existing}

    Your job: propose NEW detectors — each a case-insensitive PCRE regex plus a
    short category name — for problems that RECUR across these findings. A
    human will review each detector as source code before it is ever used.

    Rules:
      - Propose at most #{@candidate_cap} detectors. Propose none if nothing recurs.
      - A detector must describe a recurring kind of problem, not one finding.
      - The regex must match every finding you list under "matches", and should
        not match findings about unrelated problems. Keep it short (a few
        alternated phrases, under #{@regex_max_length} characters), with no
        leading/trailing slashes and no flags.
      - "matches" lists the bracketed numbers of the findings below the regex
        matches.
      - "rationale" is one line saying what the recurring problem is.

    Respond with a SINGLE JSON object and nothing else:

    {"candidates": [{"category": "<short name>", "regex": "<pattern>",
                     "matches": [<finding numbers>], "rationale": "<one line>"}]}

    Findings (#{length(slice)}):

    #{units}
    """
  end

  @doc """
  Pull the `"candidates"` list out of the model's reply, tolerating prose or a
  code fence around the JSON object.
  """
  @spec parse_candidates(String.t()) :: {:ok, list()} | {:error, :unparseable_model_output}
  def parse_candidates(text) when is_binary(text) do
    with [json] <- Regex.run(~r/\{.*\}/s, text),
         {:ok, %{"candidates" => list}} when is_list(list) <- Jason.decode(json) do
      {:ok, list}
    else
      _ -> {:error, :unparseable_model_output}
    end
  end

  def parse_candidates(_), do: {:error, :unparseable_model_output}

  @doc """
  The deterministic pre-check. Every candidate is either accepted — with its
  match counts over the window's slice and over `history`, and citations — or
  rejected with a reason atom and a human-readable discrepancy. Nothing is
  dropped silently. Pure.

  `bar` is `%{min_incidents:, min_distinct_tasks:}` — the evidence bar's own
  thresholds (`Arbiter.Loop.evidence_bar/1`).
  """
  @spec precheck(list(), [slice_unit()], [map()], map()) :: %{accepted: list(), rejected: list()}
  def precheck(candidates, slice, history, bar) when is_list(candidates) do
    {within, over} = Enum.split(candidates, @candidate_cap)
    existing = MapSet.new(FindingBuckets.categories(), &String.downcase/1)

    {accepted, rejected, _seen} =
      Enum.reduce(within, {[], [], existing}, fn cand, {acc, rej, seen} ->
        case check(cand, slice, history, bar, seen) do
          {:ok, c} -> {[c | acc], rej, MapSet.put(seen, String.downcase(c.category))}
          {:error, r} -> {acc, [r | rej], seen}
        end
      end)

    over_cap =
      Enum.map(over, fn cand ->
        rejection(cand, :over_candidate_cap, "beyond the #{@candidate_cap}-candidate cap")
      end)

    %{accepted: Enum.reverse(accepted), rejected: Enum.reverse(rejected) ++ over_cap}
  end

  defp check(cand, slice, history, bar, seen) do
    with {:ok, cat, src, claimed, rationale} <- shape(cand),
         :ok <- new_category(cand, cat, seen),
         {:ok, re} <- compile(cand, src),
         :ok <- claims_hold(cand, re, claimed, slice),
         {:ok, hits} <- clears_bar(cand, re, history, bar) do
      {:ok,
       %{
         category: cat,
         regex: src,
         rationale: rationale,
         claimed: length(claimed),
         window_matches: Enum.count(slice, &Regex.match?(re, &1.text)),
         history_matches: length(hits),
         history_tasks: distinct_tasks(hits),
         citations:
           hits |> Enum.take(@citation_n) |> Enum.map(&%{task_id: &1.task_id, run_id: &1.run_id})
       }}
    end
  end

  defp shape(%{"category" => cat, "regex" => src, "matches" => claimed} = cand)
       when is_binary(cat) and is_binary(src) and is_list(claimed) do
    cat = cat |> one_line() |> String.trim()

    cond do
      cat == "" or String.trim(src) == "" ->
        {:error, rejection(cand, :malformed, "empty category or regex")}

      not Enum.all?(claimed, &is_integer/1) ->
        {:error, rejection(cand, :malformed, "\"matches\" must be a list of finding numbers")}

      true ->
        rationale = cand |> Map.get("rationale") |> rationale_text()
        {:ok, cat, src, Enum.uniq(claimed), rationale}
    end
  end

  defp shape(cand),
    do: {:error, rejection(cand, :malformed, "expected category, regex and matches")}

  defp new_category(cand, cat, seen) do
    if MapSet.member?(seen, String.downcase(cat)),
      do:
        {:error, rejection(cand, :duplicate_category, "category already exists or was proposed")},
      else: :ok
  end

  # Compiled with `i` only — exactly what a merged `@finding_buckets` tuple
  # (`~r/.../i`) would be, so the pre-check measures the detector a human
  # would actually merge.
  defp compile(cand, src) do
    with :ok <- short_enough(cand, src),
         {:ok, re} <- regex(cand, src) do
      if Regex.match?(re, ""),
        do: {:error, rejection(cand, :degenerate_regex, "regex matches the empty string")},
        else: {:ok, re}
    end
  end

  defp short_enough(cand, src) do
    if String.length(src) > @regex_max_length,
      do:
        {:error,
         rejection(cand, :regex_too_long, "regex exceeds #{@regex_max_length} characters")},
      else: :ok
  end

  defp regex(cand, src) do
    case Regex.compile(src, "i") do
      {:ok, re} ->
        {:ok, re}

      {:error, {msg, pos}} ->
        {:error, rejection(cand, :invalid_regex, "does not compile: #{msg} at #{pos}")}
    end
  end

  # The corroborate-the-label discipline (`FailureClassifier`): the model says
  # which units its regex matches; the regex, run here, must agree on every one.
  defp claims_hold(cand, re, claimed, slice) do
    by_index = Map.new(slice, &{&1.index, &1})

    missing =
      Enum.reject(claimed, fn i ->
        case Map.get(by_index, i) do
          nil -> false
          u -> Regex.match?(re, u.text)
        end
      end)

    cond do
      claimed == [] ->
        {:error, rejection(cand, :claim_mismatch, "claims to match no finding")}

      missing != [] ->
        {:error,
         rejection(
           cand,
           :claim_mismatch,
           "claimed #{length(claimed)} finding(s); the regex does not match " <>
             Enum.map_join(missing, ", ", &"##{&1}")
         )}

      true ->
        :ok
    end
  end

  defp clears_bar(cand, re, history, bar) do
    hits = Enum.filter(history, &Regex.match?(re, &1.text))
    n = length(hits)
    tasks = distinct_tasks(hits)
    min_n = Map.get(bar, :min_incidents, 3)
    min_t = Map.get(bar, :min_distinct_tasks, 2)

    if n >= min_n and tasks >= min_t do
      {:ok, hits}
    else
      {:error,
       rejection(
         cand,
         :below_evidence_bar,
         "matches #{n} unit(s) across #{tasks} task(s) in history; " <>
           "the bar is ≥ #{min_n} across ≥ #{min_t}"
       )}
    end
  end

  defp rejection(cand, reason, detail) do
    %{
      category: field(cand, "category"),
      regex: field(cand, "regex"),
      reason: reason,
      detail: detail
    }
  end

  defp field(%{} = cand, key) do
    case Map.get(cand, key) do
      v when is_binary(v) -> truncate(one_line(v), @regex_max_length)
      _ -> nil
    end
  end

  defp field(_cand, _key), do: nil

  defp rationale_text(r) when is_binary(r), do: r |> one_line() |> truncate(@rationale_max_length)
  defp rationale_text(_), do: ""

  defp distinct_tasks(units), do: units |> Enum.map(& &1.task_id) |> Enum.uniq() |> length()

  # ---- the pass -------------------------------------------------------------

  @doc """
  Run the pass for one fetched window. `meta` is `Corpus.fetch/1`'s meta.
  Options: `:invoker`, `:workspace_id`, `:evidence_bar`.

  Never raises on a model or parse failure — the result's `:status` says what
  happened (`:ok`, `:error`, or `:skipped` when the residue is empty and no
  call was made). Writes nothing but its own cost row when a call was made.
  """
  @spec run(map(), keyword()) :: map()
  def run(meta, opts \\ []) do
    slice = meta |> residue() |> Map.get(:units, []) |> slice()
    bar = Keyword.get(opts, :evidence_bar) || Arbiter.Loop.evidence_bar(nil)
    base = base_result(meta, slice)

    if slice == [] do
      %{base | status: :skipped}
    else
      history = history(meta)
      base = %{base | history: Map.put(base.history, :units, length(history))}
      started = System.monotonic_time(:millisecond)
      reply = invoke(build_prompt(slice), opts)
      elapsed = System.monotonic_time(:millisecond) - started

      interpret(reply, base, slice, history, bar, fn usage ->
        record_cost(usage, elapsed, meta, opts, length(slice))
      end)
    end
  end

  # A reply that came back at all has drawn tokens, so its cost row is written
  # before the text is parsed — an unparseable reply still shows up in the
  # ledger. A failed call returns no usage to record.
  defp interpret({:ok, text, usage}, base, slice, history, bar, record) do
    cost = record.(usage)

    if Map.get(usage, :is_error) do
      %{base | status: :error, error: "model error: #{text}", cost: cost}
    else
      case parse_candidates(text) do
        {:ok, candidates} ->
          %{accepted: acc, rejected: rej} = precheck(candidates, slice, history, bar)
          %{base | status: :ok, candidates: acc, rejected: rej, cost: cost}

        {:error, reason} ->
          %{base | status: :error, error: inspect(reason), cost: cost}
      end
    end
  end

  defp interpret({:error, reason}, base, _slice, _history, _bar, _record),
    do: %{base | status: :error, error: inspect(reason)}

  defp interpret(other, base, _slice, _history, _bar, _record),
    do: %{base | status: :error, error: "unexpected invoker reply: " <> inspect(other)}

  defp base_result(meta, slice) do
    fr = residue(meta)

    %{
      status: nil,
      error: nil,
      slice: %{
        units: length(slice),
        residue_count: Map.get(fr, :count, 0),
        unit_cap: @unit_cap,
        unit_text_limit: @unit_text_limit
      },
      history: history_span(meta) |> Map.put(:units, 0),
      candidates: [],
      rejected: [],
      cost: %{usage_event_id: nil, cost_usd: nil, weighted_tokens: nil, window_share_5h: nil}
    }
  end

  defp residue(meta), do: Map.get(meta, :finding_residue) || Corpus.empty_finding_residue()

  defp history_span(meta) do
    case {Map.get(meta, :since), Map.get(meta, :until)} do
      {%DateTime{} = since, %DateTime{} = until} ->
        span = DateTime.diff(until, since, :second)
        %{since: DateTime.add(until, -span * @history_windows, :second), until: until}

      _ ->
        %{since: nil, until: nil}
    end
  end

  # Retained history for the bar. Falls back to the window's own residue when
  # the meta carries no span (a hand-assembled caller).
  defp history(meta) do
    case history_span(meta) do
      %{since: %DateTime{} = since, until: %DateTime{} = until} ->
        Corpus.residue_units(since, until, @history_unit_cap)

      _ ->
        meta |> residue() |> Map.get(:units, [])
    end
  end

  defp invoke(prompt, opts) do
    case Keyword.get(opts, :invoker) ||
           Application.get_env(:arbiter, :loop_discovery_invoker) ||
           Arbiter.Loop.Discovery.ClaudeInvoker do
      :disabled -> {:error, :model_calls_disabled}
      fun when is_function(fun, 2) -> fun.(prompt, opts)
      mod when is_atom(mod) -> mod.invoke(prompt, opts)
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  # The pass's own draw, through the loop's one cost-accounting path, under
  # its own step label — and its 5h-window share (#1463) beside the dollars.
  defp record_cost(usage, elapsed, meta, opts, units) do
    usage = if is_map(usage), do: usage, else: %{}
    weighted = Scarcity.weighted_tokens(usage)
    calibration = meta |> Map.get(:scarcity, %{}) |> Map.get(:calibration)
    share = Scarcity.window_share(weighted, calibration)

    id =
      Corpus.record_pass_cost(%{
        step: :loop_discovery,
        model: Map.get(usage, :model) || "loop-discovery-pass",
        provider: "claude",
        workspace_id: Keyword.get(opts, :workspace_id) || Map.get(meta, :workspace_id),
        cost_usd: Map.get(usage, :cost_usd),
        tokens_in: Map.get(usage, :tokens_in, 0),
        tokens_out: Map.get(usage, :tokens_out, 0),
        cache_creation_tokens: Map.get(usage, :cache_creation_tokens, 0),
        cache_read_tokens: Map.get(usage, :cache_read_tokens, 0),
        duration_ms: Map.get(usage, :duration_ms) || elapsed,
        rows_scanned: units,
        raw: %{
          kind: "loop_discovery_pass",
          quota_window_draw: %{weighted_tokens: weighted, window_share_5h: share}
        }
      })

    %{
      usage_event_id: id,
      cost_usd: Map.get(usage, :cost_usd),
      weighted_tokens: weighted,
      window_share_5h: share
    }
  end

  # ---- rendering ------------------------------------------------------------

  @doc "Render the report section. Pure."
  @spec to_markdown(map()) :: String.t()
  def to_markdown(%{} = d) do
    """
    ## Candidate detectors (discovery Stage 1 — opt-in model pass)

    One model call over this window's reviewer-finding residue — #{d.slice.units} unit(s)
    (of #{d.slice.residue_count}; capped at #{d.slice.unit_cap}, each truncated to
    #{d.slice.unit_text_limit} characters; no transcripts). Each candidate is a
    proposed `@finding_buckets` tuple, **not a finding**: it has passed a
    deterministic pre-check — its regex matches every unit the model claimed, and
    clears the evidence bar over retained history#{history_text(d.history)}. Nothing
    here was written anywhere; a candidate becomes a detector only when a human
    merges it into `Arbiter.Loop.FindingBuckets`.

    #{status_text(d)}
    #{cost_text(d.cost)}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp history_text(%{since: %DateTime{} = since, until: %DateTime{} = until, units: n}),
    do: " (#{n} residue unit(s), #{iso(since)} → #{iso(until)})"

  defp history_text(_), do: ""

  defp status_text(%{status: :skipped}),
    do: "_No residue this window — no model call was made._\n"

  defp status_text(%{status: :error, error: error}),
    do: "⚠ The discovery call failed: `#{error}`. No candidates this window.\n"

  defp status_text(%{candidates: cands, rejected: rej}) do
    shown =
      case cands do
        [] -> "_No candidate passed the pre-check._\n"
        _ -> Enum.map_join(cands, "\n", &candidate_md/1) <> "\n"
      end

    shown <> "\n" <> rejected_md(rej)
  end

  defp candidate_md(c) do
    cites =
      Enum.map_join(c.citations, ", ", fn cite ->
        run = if cite.run_id, do: " / `#{cite.run_id}`", else: ""
        "`#{cite.task_id}`#{run}"
      end)

    """
    ### #{c.category}

    - Proposed tuple: `{~r/#{String.replace(c.regex, "/", "\\/")}/i, #{inspect(c.category)}}`
    - Matches over history: **#{c.history_matches}** unit(s) across **#{c.history_tasks}** task(s); #{c.window_matches} in this window (the model claimed #{c.claimed})
    - Rationale (model's, unverified): #{c.rationale}
    - Citations: #{cites}
    """
  end

  defp rejected_md([]), do: "Rejected by the deterministic pre-check: 0\n"

  defp rejected_md(rej) do
    lines =
      Enum.map_join(rej, "\n", fn r ->
        "- `#{r.reason}` — #{r.category || "(no category)"}: #{r.detail}"
      end)

    "Rejected by the deterministic pre-check: #{length(rej)}\n\n" <> lines <> "\n"
  end

  defp cost_text(%{usage_event_id: nil}), do: ""

  defp cost_text(cost) do
    dollars =
      case cost.cost_usd do
        n when is_number(n) -> "$" <> :erlang.float_to_binary(n * 1.0, decimals: 4)
        _ -> "unknown"
      end

    "**This pass's own draw:** #{dollars}; #{Scarcity.format_share(cost.window_share_5h)} " <>
      "(`usage_events` row `#{cost.usage_event_id}`, step `loop_discovery`).\n"
  end

  # ---- helpers --------------------------------------------------------------

  defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: String.slice(text, 0, limit) <> "…", else: text
  end

  defp truncate(_text, _limit), do: ""

  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
