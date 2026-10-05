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
