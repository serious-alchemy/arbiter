defmodule Arbiter.Loop.DiscoveryTest do
  # bd-4f6opo (#1468) — discovery Stage 1: the opt-in `--discover` report tier.
  # One bounded model call over the finding residue, emitting candidate
  # *detectors* that must pass a deterministic pre-check before they are shown.
  # Every test here injects the invoker — no test ever execs a real CLI.
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.{Analysis, Discovery, PendingWrite}
  alias Arbiter.Loop.Discovery.ClaudeInvoker
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Usage.Event

  @bar %{min_incidents: 3, min_distinct_tasks: 2}

  defp unit(i, task_id, text),
    do: %{task_id: task_id, run_id: "run-#{i}", text: text}

  # Slice of residue units with a recurring "memo key" pattern across 3 tasks.
  defp sample_units do
    [
      unit(1, "bd-a", "1. The memo key omits the tenant id."),
      unit(2, "bd-b", "2. Cache key omits the locale, so two locales collide."),
      unit(3, "bd-c", "1. Memo key omits the version stamp."),
      unit(4, "bd-d", "1. The log line is at the wrong level.")
    ]
  end

  defp candidate(attrs) do
    Map.merge(
      %{
        "category" => "stale memoisation key",
        "regex" => "memo key|cache key omits",
        "matches" => [1, 2, 3],
        "rationale" => "Three tasks built a cache key that omits a discriminating field."
      },
      attrs
    )
  end

  describe "slice/1 — the bounded slice" do
    test "caps the unit count, truncates each unit, and keeps {task_id, run_id} tags" do
      long = String.duplicate("x", 1000)
      units = for i <- 1..350, do: unit(i, "bd-#{i}", long)

      slice = Discovery.slice(units)

      assert length(slice) == Discovery.unit_cap()
      assert Discovery.unit_cap() == 300

      for s <- slice do
        assert String.length(s.text) <= Discovery.unit_text_limit() + 1
      end

      assert Discovery.unit_text_limit() == 400
      # newest-first order preserved, 1-based indices for citation
      assert [%{index: 1, task_id: "bd-1", run_id: "run-1"} | _] = slice
      assert List.last(slice).index == 300
    end

    test "the prompt carries only the slice's unit text, never more than the cap" do
      units = for i <- 1..350, do: unit(i, "bd-#{i}", "finding number #{i}")
      prompt = units |> Discovery.slice() |> Discovery.build_prompt()

      assert prompt =~ "[300] finding number 300"
      refute prompt =~ "finding number 301"
    end
  end

  describe "parse_candidates/1" do
    test "extracts the candidates array from a JSON object wrapped in prose" do
      text =
        "Here you go:\n```json\n" <>
          Jason.encode!(%{"candidates" => [candidate(%{})]}) <> "\n```\nDone."

      assert {:ok, [%{"category" => "stale memoisation key"}]} = Discovery.parse_candidates(text)
    end

    test "unparseable output is an error, not an empty success" do
      assert {:error, :unparseable_model_output} = Discovery.parse_candidates("no json here")
    end
  end

  describe "precheck/4 — deterministic, before anything is shown" do
    test "a candidate whose regex matches what it claims and clears the bar is accepted" do
      slice = Discovery.slice(sample_units())

      %{accepted: [c], rejected: []} =
        Discovery.precheck([candidate(%{})], slice, sample_units(), @bar)

      assert c.category == "stale memoisation key"
      assert c.regex == "memo key|cache key omits"
      assert c.claimed == 3
      assert c.window_matches == 3
      assert c.history_matches == 3
      assert c.history_tasks == 3

      assert Enum.map(c.citations, & &1.task_id) == ["bd-a", "bd-b", "bd-c"]
      assert Enum.map(c.citations, & &1.run_id) == ["run-1", "run-2", "run-3"]
    end

    test "a claimed unit the regex does not match drops the candidate with the discrepancy" do
      slice = Discovery.slice(sample_units())
      cand = candidate(%{"matches" => [1, 2, 3, 4]})

      %{accepted: [], rejected: [r]} = Discovery.precheck([cand], slice, sample_units(), @bar)

      assert r.reason == :claim_mismatch
      assert r.detail =~ "#4"
    end

    test "a claimed unit that is not in the slice is a discrepancy" do
      slice = Discovery.slice(sample_units())
      cand = candidate(%{"matches" => [1, 2, 99]})

      %{rejected: [r]} = Discovery.precheck([cand], slice, sample_units(), @bar)
      assert r.reason == :claim_mismatch
      assert r.detail =~ "#99"
    end

    test "a candidate that claims no units is a discrepancy" do
      slice = Discovery.slice(sample_units())

      %{rejected: [r]} =
        Discovery.precheck([candidate(%{"matches" => []})], slice, sample_units(), @bar)

      assert r.reason == :claim_mismatch
    end

    test "below the evidence bar over history → rejected, whatever the model's confidence" do
      units = Enum.take(sample_units(), 2)
      slice = Discovery.slice(units)
      cand = candidate(%{"matches" => [1, 2], "confidence" => 0.99})

      %{accepted: [], rejected: [r]} = Discovery.precheck([cand], slice, units, @bar)
      assert r.reason == :below_evidence_bar
      assert r.detail =~ "2 unit(s) across 2 task(s)"
    end

    test "history counts decide the bar, not the window slice" do
      # Window slice has only 2 matching units, but retained history has a
      # third from another task — the candidate earns its place on history.
      window = Enum.take(sample_units(), 2)
      history = sample_units()
      cand = candidate(%{"matches" => [1, 2]})

      %{accepted: [c]} = Discovery.precheck([cand], Discovery.slice(window), history, @bar)
      assert c.window_matches == 2
      assert c.history_matches == 3
    end

    test "invalid regex, degenerate regex, duplicate category and malformed entries are rejected" do
      slice = Discovery.slice(sample_units())

      cands = [
        candidate(%{"regex" => "memo key(("}),
        candidate(%{"regex" => "x*|memo key"}),
        candidate(%{"category" => "missing test coverage"}),
        %{"category" => "no regex"},
        "not even a map"
      ]

      %{accepted: [], rejected: rejected} = Discovery.precheck(cands, slice, sample_units(), @bar)

      assert Enum.map(rejected, & &1.reason) == [
               :invalid_regex,
               :degenerate_regex,
               :duplicate_category,
               :malformed,
               :malformed
             ]
    end

    test "the same category proposed twice is accepted once" do
      slice = Discovery.slice(sample_units())

      %{accepted: [_], rejected: [r]} =
        Discovery.precheck([candidate(%{}), candidate(%{})], slice, sample_units(), @bar)

      assert r.reason == :duplicate_category
    end

    test "candidates beyond the cap are rejected, not silently dropped" do
      slice = Discovery.slice(sample_units())
      cands = for i <- 1..(Discovery.candidate_cap() + 2), do: candidate(%{"category" => "c#{i}"})

      %{accepted: accepted, rejected: rejected} =
        Discovery.precheck(cands, slice, sample_units(), @bar)

      assert length(accepted) == Discovery.candidate_cap()
      assert Enum.map(rejected, & &1.reason) == [:over_candidate_cap, :over_candidate_cap]
    end
  end

  describe "the slice path never reads a transcript" do
    test "neither Discovery nor its invoker references Arbiter.Worker.OutputLog" do
      for mod <- [Discovery, ClaudeInvoker] do
        {:ok, {^mod, [atoms: atoms]}} = :beam_lib.chunks(:code.which(mod), [:atoms])
        referenced = Enum.map(atoms, fn {_i, a} -> a end)

        refute Arbiter.Worker.OutputLog in referenced,
               "#{inspect(mod)} references OutputLog — the discovery slice must be a DB read only"
      end
    end
  end

  describe "ClaudeInvoker.parse_stream/1" do
    test "extracts the result text, the model and the token/cost usage" do
      stream =
        [
          %{"type" => "system", "subtype" => "init", "model" => "claude-sonnet-5"},
          %{"type" => "assistant", "message" => %{}},
          %{
            "type" => "result",
            "result" => "{\"candidates\": []}",
            "total_cost_usd" => 0.12,
            "duration_ms" => 4200,
            "usage" => %{
              "input_tokens" => 100,
              "output_tokens" => 50,
              "cache_creation_input_tokens" => 2000,
              "cache_read_input_tokens" => 300
            }
          }
        ]
        |> Enum.map_join("\n", &Jason.encode!/1)

      assert {:ok, "{\"candidates\": []}", usage} =
               ClaudeInvoker.parse_stream(stream)

      assert usage == %{
               model: "claude-sonnet-5",
               tokens_in: 100,
               tokens_out: 50,
               cache_creation_tokens: 2000,
               cache_read_tokens: 300,
               cost_usd: 0.12,
               duration_ms: 4200
             }
    end

    test "a stream with no result event is an error" do
      assert {:error, :no_result_event} =
               ClaudeInvoker.parse_stream("not json\n")
    end
  end

  # ---- end-to-end through Analysis.analyze/1 --------------------------------

  describe "Analysis.analyze/1 with and without discover?" do
    defp review_round!(task_id, findings) do
      {:ok, round} =
        Ash.create(Round, %{
          task_id: task_id,
          run_id: Ecto.UUID.generate(),
          round: 1,
          role: :review,
          verdict: :request_changes,
          converged: false,
          findings: findings
        })

      round
    end

    defp window do
      [
        since: DateTime.add(DateTime.utc_now(), -3600, :second),
        until: DateTime.add(DateTime.utc_now(), 3600, :second)
      ]
    end

    defp seed_residue do
      review_round!("bd-disc-a", "1. The memo key omits the tenant id.")
      review_round!("bd-disc-b", "1. Cache key omits the locale, so two locales collide.")
      review_round!("bd-disc-c", "1. Memo key omits the version stamp.")
      review_round!("bd-disc-d", "1. The log line is at the wrong level.")
    end

    defp spy_invoker(test_pid, reply) do
      fn prompt, opts ->
        send(test_pid, {:invoked, prompt, opts})
        reply
      end
    end

    defp model_reply(candidates) do
      {:ok, Jason.encode!(%{"candidates" => candidates}),
       %{
         model: "claude-sonnet-5",
         tokens_in: 1200,
         tokens_out: 300,
         cache_creation_tokens: 0,
         cache_read_tokens: 0,
         cost_usd: 0.05,
         duration_ms: 900
       }}
    end

    # Resolve slice indices by text, since the residue order is newest-first
    # and all four rounds are inserted within the same instant.
    defp indices_for(prompt, needles) do
      Regex.scan(~r/^\[(\d+)\] (.*)$/m, prompt)
      |> Enum.filter(fn [_, _i, text] -> Enum.any?(needles, &String.contains?(text, &1)) end)
      |> Enum.map(fn [_, i, _] -> String.to_integer(i) end)
    end

    test "without discover?: no model call, one cost row, no discovery section" do
      seed_residue()
      events_before = Repo.aggregate(Event, :count)

      assert {:ok, envelope} =
               Analysis.analyze(window() ++ [invoker: spy_invoker(self(), model_reply([]))])

      refute_received {:invoked, _, _}
      assert Map.keys(envelope) |> Enum.sort() == [:markdown, :report, :usage_event_id]
      assert envelope.report.discovery == nil
      refute envelope.markdown =~ "Candidate detectors"
      assert Repo.aggregate(Event, :count) == events_before + 1
    end

    test "with discover?: one bounded call, verified candidates, own cost row, zero pending writes" do
      seed_residue()
      events_before = Repo.aggregate(Event, :count)
      pending_before = Repo.aggregate(PendingWrite, :count)
      test_pid = self()

      # The invoker reads the slice from the prompt and claims the units it
      # "matched" — plus one hallucinated candidate whose regex matches nothing
      # it claims.
      invoker = fn prompt, opts ->
        send(test_pid, {:invoked, prompt, opts})
        good = indices_for(prompt, ["memo key", "Memo key", "Cache key"])
        bad = indices_for(prompt, ["log line"])

        model_reply([
          %{
            "category" => "stale memoisation key",
            "regex" => "memo key|cache key omits",
            "matches" => good,
            "rationale" => "cache keys omitting a discriminator"
          },
          %{
            "category" => "wrong log level",
            "regex" => "tenant",
            "matches" => bad,
            "rationale" => "hallucinated"
          }
        ])
      end

      assert {:ok, envelope} =
               Analysis.analyze(window() ++ [discover?: true, invoker: invoker])

      assert_received {:invoked, prompt, _opts}
      refute_received {:invoked, _, _}
      assert prompt =~ "memo key omits the tenant id"

      d = envelope.report.discovery
      assert d.status == :ok
      assert d.slice.units == 4
      assert [accepted] = d.candidates
      assert accepted.category == "stale memoisation key"
      assert accepted.history_matches == 3
      assert accepted.history_tasks == 3
      assert [rejected] = d.rejected
      assert rejected.reason == :claim_mismatch

      md = envelope.markdown
      assert md =~ "## Candidate detectors"
      assert md =~ "stale memoisation key"
      assert md =~ "bd-disc-a"
      assert md =~ "Rejected by the deterministic pre-check: 1"
      assert md =~ "claim_mismatch"
      # Every "the analyser drew nothing" claim stops being true under discover.
      refute md =~ "no model call"
      assert md =~ "`--discover` model call: $0.0500"
      assert md =~ "one for the\nopt-in discovery model call"

      # Two cost rows: the deterministic pass's (unchanged) and the discovery
      # call's own, under a distinct step label.
      assert Repo.aggregate(Event, :count) == events_before + 2
      assert d.cost.usage_event_id
      {:ok, ev} = Ash.get(Event, d.cost.usage_event_id)
      assert ev.step == :loop_discovery
      assert ev.source == :maintenance
      assert ev.task_id == nil
      assert ev.tokens_in == 1200
      assert ev.tokens_out == 300
      assert_in_delta ev.cost_usd, 0.05, 1.0e-9

      # Zero writes: the pass puts nothing in the proposal queue.
      assert Repo.aggregate(PendingWrite, :count) == pending_before
    end

    test "with discover? and propose?: the discovery candidates never become pending writes" do
      seed_residue()
      invoker = spy_invoker(self(), model_reply([]))

      {:ok, plain} = Analysis.analyze(window() ++ [propose?: true, record_cost?: false])
      plain_rows = Repo.aggregate(PendingWrite, :count)

      {:ok, _} =
        Analysis.analyze(
          window() ++ [propose?: true, discover?: true, invoker: invoker, record_cost?: false]
        )

      assert Repo.aggregate(PendingWrite, :count) == plain_rows
      assert length(plain.proposals) <= plain_rows
    end

    test "a failed model call is reported, not raised, and nothing else changes" do
      seed_residue()
      pending_before = Repo.aggregate(PendingWrite, :count)
      invoker = spy_invoker(self(), {:error, {:claude_failed, 1, "boom"}})

      {:ok, envelope} = Analysis.analyze(window() ++ [discover?: true, invoker: invoker])

      d = envelope.report.discovery
      assert d.status == :error
      assert d.candidates == []
      assert envelope.markdown =~ "discovery call failed"
      assert Repo.aggregate(PendingWrite, :count) == pending_before
    end

    test "an empty residue skips the model call entirely" do
      {:ok, envelope} =
        Analysis.analyze(window() ++ [discover?: true, invoker: spy_invoker(self(), nil)])

      refute_received {:invoked, _, _}
      assert envelope.report.discovery.status == :skipped
      assert envelope.report.discovery.cost.usage_event_id == nil
    end

    test "the configured :disabled invoker refuses without shelling out" do
      seed_residue()
      {:ok, envelope} = Analysis.analyze(window() ++ [discover?: true])

      assert envelope.report.discovery.status == :error
      assert envelope.report.discovery.error =~ "disabled"
    end
  end
end
