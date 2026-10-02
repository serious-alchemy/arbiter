defmodule Arbiter.Reports.ReviewHealthTest do
  # async: false — the report reads whole tables (like the other reports).
  use Arbiter.DataCase, async: false

  alias Arbiter.Reports.ReviewHealth
  alias Arbiter.Repo
  alias Arbiter.ReviewGate.{Resolutions, Round}
  alias Arbiter.Tasks.{Issue, Workspace}

  require Ash.Query

  @now ~U[2026-10-02 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "rh-ws-#{System.unique_integer([:positive])}", prefix: "rh"})

    %{ws: ws}
  end

  defp issue!(ws, attrs \\ %{}) do
    {:ok, issue} =
      Ash.create(
        Issue,
        Map.merge(%{title: "rh subject", workspace_id: ws.id, issue_type: :feature}, attrs)
      )

    issue
  end

  # The Round/Resolution resources stamp `inserted_at` themselves, so rewrite
  # it after the fact: the report is all about *when*.
  defp stamp!(table, id, at) do
    Repo.query!("UPDATE #{table} SET inserted_at = ? WHERE id = ?", [ts(at), id])
  end

  defp ts(%DateTime{} = at),
    do: DateTime.to_iso8601(%{at | microsecond: {elem(at.microsecond, 0), 6}})

  defp round!(task_id, at, attrs) do
    base = %{task_id: task_id, round: 1, fix_round_attempt: 0, role: :review}
    {:ok, row} = Ash.create(Round, Map.merge(base, attrs))
    stamp!("review_gate_rounds", row.id, at)
    row
  end

  defp resolve!(task_id, at, attrs \\ %{}) do
    {:ok, r} =
      Resolutions.record(
        Map.merge(%{task_id: task_id, decision: :amend, reasoning: "because"}, attrs)
      )

    stamp!("gate_resolutions", r.id, at)
    r
  end

  defp at(day, hour \\ 10), do: DateTime.new!(day, Time.new!(hour, 0, 0, {0, 6}), "Etc/UTC")

  # The Elixir truth `outcome/2` is defined by, fed the way
  # `review_gate_rounds_list` feeds it.
  defp elixir_outcome(task_id) do
    rounds =
      Round
      |> Ash.Query.filter(task_id == ^task_id)
      |> Ash.Query.sort(fix_round_attempt: :asc, round: :asc, inserted_at: :asc)
      |> Ash.read!()

    Resolutions.outcome(rounds, Resolutions.list(task_id))
  end

  describe "outcome/2 parity" do
    test "the SQL outcome equals Resolutions.outcome/2 across every shape", %{ws: ws} do
      d = fn n -> at(Date.add(~D[2026-09-21], n)) end
      t = fn -> issue!(ws).id end

      # converged: request_changes, impl fix, then approve.
      converged = t.()
      round!(converged, d.(0), %{round: 1, verdict: :request_changes})
      round!(converged, d.(0) |> DateTime.add(3600), %{round: 1, role: :impl})
      round!(converged, d.(1), %{round: 2, verdict: :approve, converged: true})

      # resolved: the last round did not approve, a later resolution ended it.
      resolved = t.()
      round!(resolved, d.(0), %{round: 1, verdict: :request_changes})
      round!(resolved, d.(1), %{round: 2, verdict: :request_changes})
      resolve!(resolved, d.(2))

      # a resolution that predates the last row does not answer it.
      stale_resolution = t.()
      resolve!(stale_resolution, d.(0))
      round!(stale_resolution, d.(1), %{round: 1, verdict: :request_changes})

      # a later resolution wins over an approving last round.
      approved_then_resolved = t.()
      round!(approved_then_resolved, d.(0), %{round: 1, verdict: :approve})
      resolve!(approved_then_resolved, d.(1), %{decision: :accept_as_is})

      # not_converged: nothing answers a non-approving last review.
      open = t.()
      round!(open, d.(0), %{round: 1, verdict: :request_changes})

      # a timed-out last review is not an approval.
      timed_out = t.()
      round!(timed_out, d.(0), %{round: 1, verdict: :timed_out})

      # a review row with no verdict is not an approval either.
      no_verdict = t.()
      round!(no_verdict, d.(0), %{round: 1, verdict: nil})

      # none: only an implementer row, no reviewer round and no resolution.
      none = t.()
      round!(none, d.(0), %{round: 1, role: :impl})

      # only a notes-gate resolution: it does not touch the review outcome.
      other_gate = t.()
      round!(other_gate, d.(0), %{round: 1, verdict: :approve})
      resolve!(other_gate, d.(1), %{gate: :notes_gate})

      # an automatic fix round restarts `round` at 1; the sort is by attempt first.
      fix_round = t.()
      round!(fix_round, d.(0), %{round: 3, verdict: :request_changes})
      round!(fix_round, d.(1), %{round: 1, fix_round_attempt: 1, verdict: :approve})

      # out-of-order stamps: "the last row" is the last by sort, not by time.
      # Here an old-round implementer row carries the newest stamp.
      skewed = t.()
      round!(skewed, d.(1), %{round: 2, verdict: :request_changes})
      round!(skewed, d.(5), %{round: 1, role: :impl})
      resolve!(skewed, d.(3))

      # a resolution with no rounds at all still reads "resolved".
      bare_resolution = t.()
      resolve!(bare_resolution, d.(0))

      expected = %{
        converged => "converged",
        resolved => "resolved",
        stale_resolution => "not_converged",
        approved_then_resolved => "resolved",
        open => "not_converged",
        timed_out => "not_converged",
        no_verdict => "not_converged",
        none => "none",
        other_gate => "converged",
        fix_round => "converged",
        skewed => "resolved",
        bare_resolution => "resolved"
      }

      sql = ReviewHealth.outcomes(%{})

      for {task_id, want} <- expected do
        assert elixir_outcome(task_id) == want, "elixir outcome drifted for #{task_id}"
        assert sql[task_id] == want, "SQL outcome for #{task_id}: #{inspect(sql[task_id])}"
      end
    end

    test "an empty task is outcome none in Elixir, and absent from the SQL scope" do
      assert Resolutions.outcome([], []) == "none"
      assert ReviewHealth.outcomes(%{}) == %{}
    end
  end

  # 20 hand-counted gate cycles. Round-1 review rows:
  #   approve          9   (cycles 1-9)
  #   request_changes  9   (cycles 10-18)
  #   timed_out        2   (cycles 19-20)
  # => first-pass approve rate 9/20 = 45%.
  # Week of 2026-09-21: cycles 1-4, 10-14 (4 approve of 9 rows).
  # Week of 2026-09-28: cycles 5-9, 15-20 (5 approve of 11 rows).
  # Later rounds, implementer rows and conflict_review rows never count.
  describe "first-pass approve rate" do
    setup %{ws: ws} do
      week1 = ~D[2026-09-22]
      week2 = ~D[2026-09-29]

      spec =
        for n <- 1..20 do
          verdict =
            cond do
              n <= 9 -> :approve
              n <= 18 -> :request_changes
              true -> :timed_out
            end

          day = if n in [1, 2, 3, 4, 10, 11, 12, 13, 14], do: week1, else: week2
          {n, verdict, day}
        end

      ids =
        for {n, verdict, day} <- spec do
          id = issue!(ws, %{title: "cycle #{n}"}).id
          round!(id, at(day), %{round: 1, verdict: verdict, converged: verdict == :approve})

          # Cycles 10-13 take a second round and approve; 14-15 take three.
          if n in 10..15 do
            round!(id, at(day), %{round: 1, role: :impl})
            round!(id, at(day, 11), %{round: 2, verdict: :request_changes})
            round!(id, at(day, 12), %{round: 2, role: :impl})
          end

          if n in 10..13, do: round!(id, at(day, 13), %{round: 3, verdict: :approve})
          if n in 14..15, do: round!(id, at(day, 13), %{round: 3, verdict: :request_changes})

          if n == 1,
            do: round!(id, at(day), %{round: 1, role: :conflict_review, verdict: :approve})

          id
        end

      %{ids: ids}
    end

    test "matches the hand count", %{ids: _ids} do
      report = ReviewHealth.load(%{"range" => "all"}, @now)

      assert report.first_pass == %{n: 20, approved: 9, rate: 0.45}
      assert report.cycles == 20
    end

    test "weekly points match the hand count" do
      report = ReviewHealth.load(%{"range" => "all"}, @now)

      assert [
               %{week: ~D[2026-09-21], n: 9, approved: 4},
               %{week: ~D[2026-09-28], n: 11, approved: 5}
             ] = report.first_pass_weekly
    end

    test "rounds per cycle" do
      report = ReviewHealth.load(%{"range" => "all"}, @now)

      # 1 round: 1-9 and 16-20 (14); 3 rounds: 10-15 (6).
      assert report.rounds == [%{rounds: 1, count: 14}, %{rounds: 3, count: 6}]
    end

    test "verdict totals" do
      report = ReviewHealth.load(%{"range" => "all"}, @now)

      # Review rows: 20 round 1, 6 round 2, 6 round 3 = 32 (conflict_review excluded).
      assert report.verdicts.review_rows == 32
      assert report.verdicts.approve == 13
      assert report.verdicts.timed_out == 2
    end

    test "the range bounds the rows by when they were written", %{ws: ws} do
      report = ReviewHealth.load(%{"range" => "7d", "workspace" => ws.id}, @now)

      # 7d before 2026-10-02 12:00 starts 2026-09-25: only the second week.
      assert report.first_pass == %{n: 11, approved: 5, rate: 5 / 11}
    end

    test "the workspace filter excludes another workspace's cycles", %{ws: ws} do
      {:ok, other} = Ash.create(Workspace, %{name: "rh-other", prefix: "ro"})
      stray = issue!(other).id
      round!(stray, at(~D[2026-09-23]), %{round: 1, verdict: :approve})

      report = ReviewHealth.load(%{"range" => "all"}, @now)
      assert report.first_pass.n == 21

      scoped = ReviewHealth.load(%{"range" => "all", "workspace" => ws.id}, @now)
      assert scoped.first_pass.n == 20
    end
  end

  describe "empty and degenerate data" do
    test "no rows" do
      report = ReviewHealth.load(%{"range" => "all"}, @now)

      assert report.cycles == 0
      assert report.first_pass == %{n: 0, approved: 0, rate: nil}
      assert report.rounds == []
      assert report.outcomes == %{converged: 0, resolved: 0, not_converged: 0, none: 0}
      assert report.resolutions == []
    end
  end

  describe "approve with unmet criteria" do
    test "counts approves whose criteria breakdown was not clean", %{ws: ws} do
      a = issue!(ws).id
      b = issue!(ws).id
      round!(a, at(~D[2026-09-23]), %{verdict: :approve, converged: true})
      round!(b, at(~D[2026-09-23]), %{verdict: :approve, converged: false, criteria_unmet: 2})

      v = ReviewHealth.load(%{"range" => "all"}, @now).verdicts
      assert v.approve == 2
      assert v.approve_unmet == 1
    end
  end

  describe "provider charts" do
    test "start at 2026-09-20 and never include earlier rows", %{ws: ws} do
      assert ReviewHealth.provider_start() == ~D[2026-09-20]

      before = issue!(ws).id
      since = issue!(ws).id

      round!(before, at(~D[2026-09-19], 23), %{
        reviewer_provider: "claude",
        reviewer_model: "opus",
        cost_usd: 5.0,
        verdict: :approve
      })

      round!(since, at(~D[2026-09-20], 0), %{
        reviewer_provider: "claude",
        reviewer_model: "opus",
        reviewer_family: "anthropic",
        cost_usd: 1.0,
        same_family_fallback: false,
        verdict: :approve
      })

      round!(since, at(~D[2026-09-21]), %{
        round: 2,
        reviewer_provider: "claude",
        reviewer_model: "opus",
        reviewer_family: "anthropic",
        cost_usd: 2.0,
        same_family_fallback: true,
        verdict: :request_changes
      })

      round!(since, at(~D[2026-09-22]), %{
        round: 3,
        reviewer_provider: "gemini",
        reviewer_model: "gemini-pro",
        verdict: :timed_out
      })

      report = ReviewHealth.load(%{"range" => "all"}, @now)

      assert report.providers.since == ~D[2026-09-20]

      assert [
               %{provider: "claude", model: "opus", family: "anthropic"} = claude,
               %{provider: "gemini", model: "gemini-pro", family: nil} = gemini
             ] = report.providers.rows

      assert %{passes: 2, priced: 2, cost_usd: 3.0} = claude
      assert %{passes: 1, priced: 0, cost_usd: nil} = gemini

      # Two cross-family passes, one of which fell back to the implementer's family.
      assert report.providers.fallback == %{passes: 2, fallbacks: 1, rate: 0.5}
    end
  end

  describe "resolutions" do
    test "group review_gate resolutions by decision and actor", %{ws: ws} do
      a = issue!(ws).id
      b = issue!(ws).id
      round!(a, at(~D[2026-09-23]), %{verdict: :request_changes})
      round!(b, at(~D[2026-09-23]), %{verdict: :request_changes})
      resolve!(a, at(~D[2026-09-24]), %{decision: :amend})
      resolve!(b, at(~D[2026-09-24]), %{decision: :amend})
      resolve!(b, at(~D[2026-09-25]), %{decision: :send_back, actor: "operator"})
      resolve!(b, at(~D[2026-09-25]), %{decision: :reject, gate: :commit_gate})

      report = ReviewHealth.load(%{"range" => "all"}, @now)

      assert report.resolutions == [
               %{decision: "amend", actor: "coordinator", count: 2},
               %{decision: "send_back", actor: "operator", count: 1}
             ]
    end
  end

  describe "weekly outcomes" do
    test "bucket each task by the week of its last activity", %{ws: ws} do
      a = issue!(ws).id
      b = issue!(ws).id
      c = issue!(ws).id
      round!(a, at(~D[2026-09-22]), %{verdict: :approve})
      round!(b, at(~D[2026-09-23]), %{verdict: :request_changes})
      resolve!(b, at(~D[2026-09-30]))
      round!(c, at(~D[2026-09-30]), %{verdict: :request_changes})

      report = ReviewHealth.load(%{"range" => "all"}, @now)

      assert report.outcomes == %{converged: 1, resolved: 1, not_converged: 1, none: 0}

      assert [
               %{week: ~D[2026-09-21], counts: %{converged: 1, resolved: 0, not_converged: 0}},
               %{week: ~D[2026-09-28], counts: %{converged: 0, resolved: 1, not_converged: 1}}
             ] = report.outcomes_weekly
    end
  end
end
