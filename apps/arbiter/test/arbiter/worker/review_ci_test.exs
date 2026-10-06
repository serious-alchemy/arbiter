defmodule Arbiter.Worker.ReviewCiTest do
  @moduledoc """
  bd-cut6uv — the pure half of CI-gated review: the setting, the SHA-matched
  classification of a forge reading, the partial-verification carve-out, the
  reviewer-prompt block and the ticket-side `ci_wait` marker.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.ReviewCi
  alias Arbiter.Worker.ReviewVerification

  @sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @other "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  defp ws(config), do: %Workspace{id: "w", config: config}

  describe "required?/2" do
    test "defaults on for a forge repo and off for a direct one" do
      assert ReviewCi.required?(ws(%{"merge" => %{"strategy" => "github"}}), "o/r")
      assert ReviewCi.required?(ws(%{"merge" => %{"strategy" => "gitlab"}}), "o/r")
      refute ReviewCi.required?(ws(%{"merge" => %{"strategy" => "direct"}}), "o/r")
      refute ReviewCi.required?(ws(%{}), "o/r")
      refute ReviewCi.required?(nil, "o/r")
    end

    test "the workspace setting wins over the strategy default, as a boolean or a string" do
      refute ReviewCi.required?(
               ws(%{
                 "merge" => %{"strategy" => "github"},
                 "review" => %{"require_ci_green" => false}
               }),
               "o/r"
             )

      refute ReviewCi.required?(
               ws(%{
                 "merge" => %{"strategy" => "github"},
                 "review" => %{"require_ci_green" => "false"}
               }),
               "o/r"
             )

      assert ReviewCi.required?(
               ws(%{
                 "merge" => %{"strategy" => "direct"},
                 "review" => %{"require_ci_green" => true}
               }),
               "o/r"
             )
    end

    test "a per-repo override beats the workspace setting" do
      config = %{
        "merge" => %{"strategy" => "github"},
        "review" => %{
          "require_ci_green" => true,
          "repos" => %{"mesaana" => %{"require_ci_green" => false}}
        }
      }

      refute ReviewCi.required?(ws(config), "mesaana")
      assert ReviewCi.required?(ws(config), "vstim")
    end

    test "a repo whose merge override is direct defaults off even in a github workspace" do
      config = %{
        "merge" => %{
          "strategy" => "github",
          "repos" => %{"mesaana" => %{"strategy" => "direct"}}
        }
      }

      refute ReviewCi.required?(ws(config), "mesaana")
      assert ReviewCi.required?(ws(config), "vstim")
    end
  end

  describe "budget/2" do
    test "uses the repo's merge.watchdog_max_polls, defaulting when unset or infinity" do
      config = %{
        "merge" => %{
          "strategy" => "github",
          "watchdog_max_polls" => 30,
          "repos" => %{
            "fast" => %{"watchdog_max_polls" => 4},
            "slow" => %{"watchdog_max_polls" => "infinity"}
          }
        }
      }

      assert %{max_polls: 4} = ReviewCi.budget(ws(config), "fast")
      assert %{max_polls: 30} = ReviewCi.budget(ws(config), "other")

      assert %{max_polls: n} = ReviewCi.budget(ws(config), "slow")
      assert is_integer(n) and n > 0
      assert %{max_polls: _} = ReviewCi.budget(nil, nil)
    end
  end

  describe "classify/2 — the SHA match" do
    test "green only when the forge head IS the expected sha and the pipeline succeeded" do
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :success}, @sha) == :green
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :failed}, @sha) == :red
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :canceled}, @sha) == :cancelled
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :running}, @sha) == :pending
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :pending}, @sha) == :pending
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :not_started}, @sha) == :not_started
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: nil}, @sha) == :unknown
      assert ReviewCi.classify(%{head_sha: @sha, pipeline: :neutral}, @sha) == :unknown
    end

    test "a green pipeline on a different head is never green" do
      assert ReviewCi.classify(%{head_sha: @other, pipeline: :success}, @sha) ==
               {:head_mismatch, @other}

      assert ReviewCi.classify(%{head_sha: @other, pipeline: :failed}, @sha) ==
               {:head_mismatch, @other}

      assert ReviewCi.classify(%{pipeline: :success}, @sha) == {:head_mismatch, nil}
      assert ReviewCi.classify(%{head_sha: "", pipeline: :success}, @sha) == {:head_mismatch, ""}
    end

    test "a closed or merged PR is unavailable, whatever its pipeline" do
      assert {:unavailable, _} =
               ReviewCi.classify(%{status: :closed, head_sha: @sha, pipeline: :success}, @sha)

      assert {:unavailable, _} =
               ReviewCi.classify(%{status: :merged, head_sha: @sha, pipeline: :success}, @sha)
    end

    test "same_sha?/2 accepts a >=7 char prefix and nothing looser" do
      assert ReviewCi.same_sha?(@sha, String.slice(@sha, 0, 7))
      assert ReviewCi.same_sha?(String.upcase(@sha), @sha)
      refute ReviewCi.same_sha?(@sha, String.slice(@sha, 0, 6))
      refute ReviewCi.same_sha?(@sha, @other)
      refute ReviewCi.same_sha?(@sha, "")
      refute ReviewCi.same_sha?(@sha, nil)
      refute ReviewCi.same_sha?("zzzzzzzz", "zzzzzzzz")
    end
  end

  describe "call/3 and read/5" do
    defmodule RaisingAdapter do
      def get(_ref), do: raise("boom")
      def link_for(_ref), do: ""
    end

    test "a forge call that raises or exits comes back as a value, never as the caller's death" do
      assert {:error, "forge call raised: boom"} = ReviewCi.call(nil, nil, fn -> raise "boom" end)
      assert {:error, msg} = ReviewCi.call(nil, nil, fn -> exit(:gone) end)
      assert msg =~ "gone"
      assert {:ok, 42} = ReviewCi.call(nil, nil, fn -> 42 end)
    end

    test "read/5 turns a raising adapter into an unavailable reading" do
      assert {{:unavailable, why}, %{}} = ReviewCi.read(RaisingAdapter, nil, nil, "#1", @sha)
      assert why =~ "raised"
    end
  end

  describe "partial_only_full_suite?/1" do
    test "a disclosure that is only about the suite is suite-only" do
      assert ReviewVerification.partial_only_full_suite?(
               "VERDICT: APPROVE\nVERIFICATION: PARTIAL — did not run the full test suite (CI green on abc1234)"
             )

      assert ReviewVerification.partial_only_full_suite?(
               "VERIFICATION: PARTIAL - full suite not run"
             )

      assert ReviewVerification.partial_only_full_suite?(
               "VERIFICATION: PARTIAL: ran targeted tests only, not mix test"
             )
    end

    test "anything else keeps the disclosure partial" do
      refute ReviewVerification.partial_only_full_suite?("VERIFICATION: PARTIAL")

      refute ReviewVerification.partial_only_full_suite?(
               "VERIFICATION: PARTIAL — could not confirm F2 against the diff"
             )

      refute ReviewVerification.partial_only_full_suite?(
               "VERIFICATION: PARTIAL — did not run the full test suite and could not build the assets"
             )

      refute ReviewVerification.partial_only_full_suite?(
               "VERIFICATION: PARTIAL — gave up waiting on a slow dialyzer run"
             )

      refute ReviewVerification.partial_only_full_suite?("VERIFICATION: FULL")
      refute ReviewVerification.partial_only_full_suite?(nil)
    end

    test "every PARTIAL line must be suite-only" do
      findings = """
      VERIFICATION: PARTIAL — did not run the full test suite
      VERIFICATION: PARTIAL — could not confirm the migration
      """

      refute ReviewVerification.partial_only_full_suite?(findings)
    end
  end

  describe "green_block/1" do
    test "names the sha and link and carries the don't-run-the-suite instruction" do
      block =
        %{sha: @sha, url: "https://ci.example/run/1"}
        |> ReviewCi.green_block()
        |> String.replace(~r/\s+/, " ")

      assert block =~ "CI passed on #{@sha} (https://ci.example/run/1)."
      assert block =~ "Do not run the full test suite."
      assert block =~ "Run targeted tests only to check a specific claim."
      assert block =~ "Still flag missing or inadequate tests"
    end

    test "omits the link parenthesis when the forge gave none" do
      assert ReviewCi.green_block(%{sha: @sha, url: nil}) =~ "CI passed on #{@sha}. Do not"
    end
  end

  describe "the ci_wait marker" do
    test "waiting/2 reads a live marker and ignores an expired or malformed one" do
      budget = %{interval_ms: 1_000, max_polls: 2}
      marker = ReviewCi.marker(@sha, 2, budget)
      ticket = %{review_gate_state: %{"ci_wait" => marker}}

      assert %{sha: @sha, round: 2} = ReviewCi.waiting(ticket)

      assert ReviewCi.wait_label(ReviewCi.waiting(ticket)) ==
               "waiting on CI " <> String.slice(@sha, 0, 12)

      later = DateTime.add(DateTime.utc_now(), 3_600, :second)
      assert ReviewCi.waiting(ticket, later) == nil
      assert ReviewCi.waiting(%{review_gate_state: %{"ci_wait" => %{"sha" => @sha}}}) == nil
      assert ReviewCi.waiting(%{review_gate_state: %{"ci_wait" => nil}}) == nil
      assert ReviewCi.waiting(%{review_gate_state: nil}) == nil
      assert ReviewCi.waiting(%{}) == nil
    end
  end

  describe "advance/2 — the wait" do
    defp new_wait(max \\ 5), do: ReviewCi.new_wait(@sha, %{interval_ms: 1, max_polls: max})

    defp run(wait, readings) do
      Enum.map_reduce(readings, wait, fn reading, w ->
        {action, w} = ReviewCi.advance(w, reading)
        {action, w}
      end)
    end

    test "green dispatches the reviewer" do
      assert {[:green], _} = run(new_wait(), [:green])
    end

    test "pending, unknown and head mismatches keep waiting, never green" do
      assert {[:wait, :wait, :wait, :wait], _} =
               run(new_wait(), [
                 :pending,
                 :unknown,
                 {:head_mismatch, @other},
                 {:head_mismatch, nil}
               ])
    end

    test "a commit pushed after CI started blocks until CI passes on the new sha" do
      # The gate waits on @sha. The forge's head moves to @other (green there),
      # so every reading is a mismatch: the wait never turns green.
      assert {[:wait, :wait, :wait], wait} =
               run(new_wait(), List.duplicate({:head_mismatch, @other}, 3))

      assert wait.polls == 3
    end

    test "red re-runs once, then red again is the fix path" do
      {[:rerun], wait} = run(new_wait(), [:red])
      wait = ReviewCi.rerun_started(wait, [%{name: "test"}])

      # The forge still lists the old failed attempt as newest for a few polls.
      assert {[:wait, :wait], wait} = run(wait, [:red, :red])
      # The re-run was seen under way, then went red again.
      assert {[:wait, :fix], _} = run(wait, [:pending, :red])
    end

    test "a red that outlasts the grace without the re-run ever being seen is the fix path" do
      {[:rerun], wait} = run(new_wait(10), [:red])
      wait = ReviewCi.rerun_started(wait, [])

      assert {[:wait, :wait, :fix], _} = run(wait, [:red, :red, :red])
    end

    # #360: a cancelled check is an infrastructure outcome, never a code failure.
    test "cancelled re-runs with a growing backoff, then escalates as infrastructure — never :fix" do
      assert {[:rerun_infra], wait} = run(new_wait(30), [:cancelled])

      # Inside the first backoff the forge may still list the cancelled attempt.
      assert {[:wait, :wait], wait} = run(wait, [:cancelled, :cancelled])
      assert {[:rerun_infra], wait} = run(wait, [:cancelled])

      # The second re-run backs off twice as long.
      assert {[:wait, :wait, :wait, :wait, :wait], wait} =
               run(wait, List.duplicate(:cancelled, 5))

      assert {[{:infra, reason}], _} = run(wait, [:cancelled])
      assert reason =~ "cancelled"
    end

    test "cancelled that goes green on the re-run just proceeds" do
      {[:rerun_infra], wait} = run(new_wait(), [:cancelled])
      assert {[:wait, :green], _} = run(wait, [:pending, :green])
    end

    test "red then green on the re-run is a flake carrying the failing checks" do
      {[:rerun], wait} = run(new_wait(), [:red])
      checks = [%{name: "test", summary: "boom"}]
      wait = ReviewCi.rerun_started(wait, checks)

      assert {[:wait, {:flake, ^checks}], _} = run(wait, [:pending, :green])
    end

    test "zero check runs for the grace polls means no CI to wait on" do
      n = ReviewCi.not_started_grace_polls()

      assert {readings, _} = run(new_wait(50), List.duplicate(:not_started, n))
      assert List.last(readings) |> elem(0) == :fallback
      assert Enum.drop(readings, -1) |> Enum.all?(&(&1 == :wait))
    end

    test "a not_started streak is broken by a real reading" do
      n = ReviewCi.not_started_grace_polls()

      readings =
        List.duplicate(:not_started, n - 1) ++ [:pending] ++ List.duplicate(:not_started, n - 1)

      assert {actions, _} = run(new_wait(50), readings)
      assert Enum.all?(actions, &(&1 == :wait))
    end

    test "the poll budget bounds the wait and the fallback names why" do
      assert {[:wait, :wait, {:fallback, reason}], _} =
               run(new_wait(3), [:pending, :pending, :pending])

      assert reason =~ "within 3 polls"
      assert reason =~ @sha
    end

    test "a head that never matches falls back at the budget, naming the mismatch" do
      assert {[:wait, {:fallback, reason}], _} =
               run(new_wait(2), [{:head_mismatch, @other}, {:head_mismatch, @other}])

      assert reason =~ @other
    end

    test "a closed PR falls back at once; an unreadable forge after a streak" do
      assert {[{:fallback, reason}], _} = run(new_wait(), [{:unavailable, "the PR is closed"}])
      assert reason =~ "closed"

      assert {[:wait, :wait, {:fallback, reason}], _} =
               run(new_wait(), List.duplicate({:unavailable, "forge read timed out"}, 3))

      assert reason =~ "timed out"

      # A good reading in between resets the streak.
      assert {actions, _} =
               run(new_wait(20), [
                 {:unavailable, "x"},
                 {:unavailable, "x"},
                 :pending,
                 {:unavailable, "x"},
                 {:unavailable, "x"}
               ])

      assert Enum.all?(actions, &(&1 == :wait))
    end

    test "failure_findings/4 names the sha, the checks and whether a re-run happened" do
      text =
        ReviewCi.failure_findings(
          @sha,
          "o/r#7",
          [%{name: "test", url: "https://ci/1", summary: "1) boom"}],
          true
        )

      assert text =~ "CI is RED on #{@sha}"
      assert text =~ "- test (https://ci/1)"
      assert text =~ "1) boom"
      assert text =~ "re-run once"
      assert ReviewCi.failure_findings(@sha, "o/r#7", [], false) =~ "could not be re-run"
    end
  end
end
