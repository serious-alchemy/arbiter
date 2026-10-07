defmodule Arbiter.Agents.Routing.ShadowReportTest do
  @moduledoc """
  bd-adtnto (R5, design §9.2 item 3): the shadow report compares the scorer's
  recorded pick with the pick that actually dispatched, and lists every
  disagreement with its reason.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Agents.Routing.ShadowReport
  alias Arbiter.Workers.Run

  defp row(id, shadow, outcome \\ "selected", extra \\ %{}) do
    decision =
      Map.merge(
        %{
          "mode" => "scored",
          "scoring_mode" => "shadow",
          "outcome" => outcome,
          "account_slug" => "claude-1",
          "model" => "opus",
          "shadow" => shadow
        },
        extra
      )

    %{
      run_id: id,
      task_id: "t-#{id}",
      workspace_id: "ws",
      at: ~U[2026-10-01 12:00:00Z],
      decision: decision
    }
  end

  defp agree,
    do: %{"comparable" => true, "agrees" => true, "pick" => %{"account_slug" => "claude-1"}}

  defp disagree(reason),
    do: %{
      "comparable" => true,
      "agrees" => false,
      "reason" => reason,
      "pick" => %{"account_slug" => "codex-1", "model" => "gpt-5", "score" => 2.0}
    }

  describe "build/1" do
    test "counts agreement over comparable decisions and lists every disagreement" do
      report =
        ShadowReport.build([
          row("r1", agree()),
          row("r2", agree()),
          row("r3", disagree("price: scored pick is cheaper (2.0 vs 4.0)")),
          row("r4", %{"comparable" => false, "agrees" => nil}, "pinned"),
          row("r5", %{"comparable" => false, "agrees" => nil}, "no_candidate")
        ])

      assert report.shadow_decisions == 5
      assert report.comparable == 3
      assert report.agree == 2
      assert report.disagree == 1
      assert_in_delta report.agreement_rate, 2 / 3, 1.0e-9
      assert report.not_comparable == %{"pinned" => 1, "no_candidate" => 1}

      assert [d] = report.disagreements
      assert d.run_id == "r3"
      assert d.actual =~ "claude-1"
      assert d.scored =~ "codex-1"
      assert d.reason =~ "price"
    end

    test "decisions without a shadow record (most_quota, enforce) are ignored" do
      report =
        ShadowReport.build([
          row("r1", nil),
          %{row("r2", nil) | decision: %{"mode" => "most_quota"}}
        ])

      assert report.shadow_decisions == 0
      assert report.agreement_rate == nil
    end

    test "an empty window has no rate, not 100%" do
      assert ShadowReport.build([]).agreement_rate == nil
    end
  end

  describe "in both modes (bd-dde4l7)" do
    defp enforce_row(id, shadow, outcome \\ "selected") do
      base = row(id, shadow, outcome, %{"scoring_mode" => "enforce"})
      put_in(base.decision["account_slug"], "claude-1")
    end

    defp headroom(extra),
      do: Map.merge(%{"policy" => "headroom"}, extra)

    test "summarises live-vs-baseline agreement per mode, labelled by live and shadowed policy" do
      report =
        ShadowReport.build([
          row("s1", agree()),
          row("s2", disagree("tiebreak")),
          enforce_row("e1", headroom(agree())),
          enforce_row("e2", headroom(agree())),
          enforce_row("e3", headroom(disagree("price: scored pick is cheaper (1.0 vs 2.0)"))),
          enforce_row("e4", headroom(%{"comparable" => false, "agrees" => nil}), "pinned")
        ])

      assert report.shadow_decisions == 6

      assert %{live: "headroom", shadowed: "scorer", comparable: 2, agree: 1, disagree: 1} =
               report.modes["shadow"]

      assert %{
               live: "scorer",
               shadowed: "headroom",
               shadow_decisions: 4,
               comparable: 3,
               agree: 2,
               disagree: 1,
               not_comparable: %{"pinned" => 1}
             } = report.modes["enforce"]

      assert_in_delta report.modes["enforce"].agreement_rate, 2 / 3, 1.0e-9

      assert [d] = report.modes["enforce"].disagreements
      assert d.run_id == "e3"
      assert d.mode == "enforce"
      assert d.live_policy == "scorer"
      assert d.shadow_policy == "headroom"
      assert d.shadowed =~ "codex-1"
    end

    test "a record from before the policy label is read as a scorer shadow in shadow mode" do
      report = ShadowReport.build([row("old", agree())])
      assert %{live: "headroom", shadowed: "scorer", agree: 1} = report.modes["shadow"]
      assert report.modes["enforce"].shadow_decisions == 0
    end

    defp with_candidate(row, candidate),
      do: put_in(row.decision["shadow_candidate"], candidate)

    defp cand(agrees, difficulty, issue_type) do
      %{
        "comparable" => true,
        "agrees" => agrees,
        "difficulty" => difficulty,
        "issue_type" => issue_type,
        "pick" => %{"account_slug" => "codex-1", "model" => "gpt-5"},
        "live_pick" => %{"account_slug" => "claude-1", "model" => "opus"}
      }
    end

    test "summarises live-vs-candidate agreement and the cells where they differ" do
      report =
        ShadowReport.build([
          with_candidate(enforce_row("e1", headroom(agree())), cand(true, 2, "feature")),
          with_candidate(enforce_row("e2", headroom(agree())), cand(false, 3, "bug")),
          with_candidate(enforce_row("e3", headroom(agree())), cand(false, 3, "bug")),
          with_candidate(enforce_row("e4", headroom(agree())), cand(true, 3, "bug")),
          with_candidate(row("s1", agree()), cand(false, 2, "feature")),
          with_candidate(
            enforce_row("e5", headroom(agree()), "pinned"),
            %{"comparable" => false, "agrees" => nil, "difficulty" => 2, "issue_type" => "bug"}
          )
        ])

      c = report.candidate
      assert %{decisions: 6, comparable: 5, agree: 2, disagree: 3} = c
      assert_in_delta c.agreement_rate, 2 / 5, 1.0e-9
      assert c.not_comparable == %{"pinned" => 1}

      # Only cells that differ, worst first, with their own rate.
      assert [
               %{difficulty: 3, issue_type: "bug", comparable: 3, disagree: 2},
               %{difficulty: 2, issue_type: "feature", comparable: 2, disagree: 1}
             ] = c.cells

      assert_in_delta hd(c.cells).disagreement_rate, 2 / 3, 1.0e-9

      assert [%{run_id: "e2", live: live, candidate: candidate} | _] = c.disagreements
      assert live =~ "claude-1"
      assert candidate =~ "codex-1"
    end

    test "no candidate records: the candidate section is empty with no rate" do
      report = ShadowReport.build([row("s1", agree())])
      assert %{decisions: 0, agreement_rate: nil, cells: [], disagreements: []} = report.candidate
    end

    test "format prints each mode's line and the candidate section with its cells" do
      text =
        [
          row("s1", agree()),
          with_candidate(enforce_row("e1", headroom(agree())), cand(false, 3, "bug"))
        ]
        |> ShadowReport.build()
        |> ShadowReport.format()

      assert text =~ "enforce (scorer live, headroom shadow)"
      assert text =~ "shadow (headroom live, scorer shadow)"
      assert text =~ "candidate matrix vs live"
      assert text =~ "D3 bug"
    end

    test "collect/1 keeps enforce runs that carry only a shadow_candidate" do
      run =
        Ash.create!(Run, %{
          task_id: "task-#{System.unique_integer([:positive])}",
          repo: "r",
          workspace_id: "ws-1",
          kind: :implement,
          provider: "claude",
          state: :finished,
          outcome: :succeeded,
          started_at: DateTime.utc_now(),
          routing_decision: %{
            "outcome" => "selected",
            "scoring_mode" => "enforce",
            "shadow_candidate" => cand(true, 2, "feature")
          }
        })

      assert [%{run_id: id}] =
               ShadowReport.collect(since: DateTime.add(DateTime.utc_now(), -86_400, :second))

      assert id == run.id
    end
  end

  describe "format/1" do
    test "prints the rate and each disagreement with its reason" do
      text =
        [row("r1", agree()), row("r2", disagree("tiebreak"))]
        |> ShadowReport.build()
        |> ShadowReport.format()

      assert text =~ "agreement 50.0%"
      assert text =~ "r2"
      assert text =~ "tiebreak"
    end

    test "says plainly when nothing was recorded" do
      assert ShadowReport.format(ShadowReport.build([])) =~ "no shadow decisions"
    end
  end

  describe "collect/1" do
    defp run!(attrs) do
      Ash.create!(
        Run,
        Map.merge(
          %{
            task_id: "task-#{System.unique_integer([:positive])}",
            repo: "r",
            workspace_id: "ws-1",
            kind: :implement,
            provider: "claude",
            state: :finished,
            outcome: :succeeded,
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )
    end

    test "reads shadow decisions off worker_runs within the window and workspace" do
      shadow = %{"comparable" => true, "agrees" => true, "pick" => %{}}
      inside = run!(%{routing_decision: %{"outcome" => "selected", "shadow" => shadow}})
      run!(%{routing_decision: %{"outcome" => "selected", "mode" => "most_quota"}})
      run!(%{routing_decision: nil})

      run!(%{
        workspace_id: "ws-2",
        routing_decision: %{"outcome" => "selected", "shadow" => shadow}
      })

      run!(%{
        started_at: DateTime.add(DateTime.utc_now(), -40 * 86_400, :second),
        routing_decision: %{"outcome" => "selected", "shadow" => shadow}
      })

      rows =
        ShadowReport.collect(
          workspace_id: "ws-1",
          since: DateTime.add(DateTime.utc_now(), -86_400, :second)
        )

      assert [%{run_id: id}] = rows
      assert id == inside.id
      assert ShadowReport.build(rows).agree == 1
    end
  end

  describe "Arbiter.Release.shadow_report/1" do
    test "prints and returns the report without starting the repo" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert %{shadow_decisions: 0} = Arbiter.Release.shadow_report(start: false)
        end)

      assert output =~ "no shadow decisions"
    end
  end
end
