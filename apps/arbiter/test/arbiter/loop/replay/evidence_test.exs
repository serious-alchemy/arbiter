defmodule Arbiter.Loop.Replay.EvidenceTest do
  @moduledoc """
  bd-c7lx65 (R15, `docs/design/paced-quota-routing-signals.md` §7.2): replay
  evidence is recorded as its own source, with its own weight, per competence
  cell, and never reaches the live matrix: the summary is read-only and labels
  every row `source: "replay"`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Replay.Evidence
  alias Arbiter.Loop.ReplayRun

  @at ~U[2026-10-10 12:00:00.000000Z]

  defp run(attrs) do
    struct!(
      ReplayRun,
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          task_id: "bd-#{System.unique_integer([:positive])}",
          provider: "claude",
          model: "claude-sonnet-5-5",
          pool: "claude",
          difficulty: 2,
          issue_type: "feature",
          state: :scored,
          started_at: @at,
          files: [],
          admission: [],
          runs: %{}
        },
        attrs
      )
    )
  end

  describe "summarize/2" do
    test "per cell: n, the round-1 approve rate, tests, the overlaps; labelled replay evidence" do
      runs = [
        run(%{
          converged: true,
          verdict: :approve,
          tests: :passed,
          file_overlap: 1.0,
          line_overlap: 0.5
        }),
        run(%{
          converged: false,
          verdict: :request_changes,
          tests: :failed,
          file_overlap: 0.5,
          line_overlap: 0.25
        }),
        run(%{
          converged: false,
          reason: "no change",
          tests: :not_run,
          file_overlap: 0.0,
          line_overlap: 0.0
        }),
        run(%{
          model: "claude-opus-5-5",
          converged: true,
          verdict: :approve,
          tests: :not_run,
          file_overlap: 1.0,
          line_overlap: 1.0
        })
      ]

      assert [opus, sonnet] = Evidence.summarize(runs)

      assert sonnet["source"] == "replay"
      assert sonnet["weight"] == Evidence.weight()

      assert sonnet["match"] == %{
               "provider" => "claude",
               "model" => "claude-sonnet-5-5",
               "difficulty" => 2,
               "issue_type" => "feature"
             }

      assert sonnet["n"] == 3
      assert sonnet["converged"] == 1
      assert_in_delta sonnet["round_1_approve"], 1 / 3, 1.0e-9
      assert {sonnet["tested_n"], sonnet["tests_passed"]} == {2, 0.5}
      assert_in_delta sonnet["file_overlap"], 0.5, 1.0e-9
      assert_in_delta sonnet["line_overlap"], 0.25, 1.0e-9

      assert opus["match"]["model"] == "claude-opus-5-5"

      assert {opus["n"], opus["round_1_approve"], opus["tested_n"], opus["tests_passed"]} ==
               {1, 1.0, 0, nil}
    end

    test "only scored replays are evidence: refused, unscored, failed and running ones are not" do
      runs =
        for state <- [:refused, :unscored, :failed, :running],
            do: run(%{state: state, converged: nil})

      assert Evidence.summarize(runs) == []
    end

    test "the weight can be set by the reader" do
      assert [%{"weight" => 0.25}] = Evidence.summarize([run(%{converged: true})], weight: 0.25)
    end
  end

  describe "report/1 and format/1" do
    test "reads the records, counts them by state, and prints the cells and the latest replays" do
      base = %{
        task_id: "bd-ev",
        provider: "claude",
        model: "claude-sonnet-5-5",
        pool: "claude",
        difficulty: 2,
        issue_type: "feature",
        started_at: @at,
        deadline_at: DateTime.add(@at, 3600)
      }

      ReplayRun
      |> Ash.create!(Map.put(base, :state, :running))
      |> Ash.update!(
        %{
          state: :scored,
          converged: true,
          verdict: :approve,
          tests: :passed,
          file_overlap: 0.8,
          line_overlap: 0.4
        },
        action: :finish
      )

      Ash.create!(
        ReplayRun,
        Map.merge(base, %{
          state: :refused,
          reason: "acct/claude has no expiring headroom to explore (binding: window:7d)"
        })
      )

      report =
        Evidence.report(since: DateTime.add(@at, -86_400), until: DateTime.add(@at, 86_400))

      assert report.counts == %{scored: 1, refused: 1}
      assert [%{"n" => 1, "round_1_approve" => 1.0}] = report.cells
      assert length(report.latest) == 2

      text = Evidence.format(report)
      assert text =~ "2 recorded"
      assert text =~ "1 scored"
      assert text =~ "1 refused"

      assert text =~
               "| claude | claude-sonnet-5-5 | 2 | feature | 1 | 100% (1/1) | 100% (1/1) | 0.80 | 0.40 |"

      assert text =~ "never read into the live competence matrix"

      assert text =~
               "- 2026-10-10 12:00:00Z bd-ev on claude-sonnet-5-5: scored, converged " <>
                 "(verdict approve, tests passed, overlap 0.80/0.40)"

      assert text =~
               "- 2026-10-10 12:00:00Z bd-ev on claude-sonnet-5-5: refused, " <>
                 "acct/claude has no expiring headroom"

      assert String.printable?(text) and text == for(<<c <- text>>, c < 128, into: "", do: <<c>>),
             "plain ASCII, whatever the operator's terminal"
    end

    test "nothing recorded says so" do
      text = Evidence.format(Evidence.report(since: @at, until: DateTime.add(@at, 60)))
      assert text =~ "No offline replays"
    end
  end
end
