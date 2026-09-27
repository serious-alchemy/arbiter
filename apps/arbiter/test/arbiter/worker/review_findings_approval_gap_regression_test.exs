defmodule Arbiter.Worker.ReviewFindingsApprovalGapRegressionTest do
  @moduledoc """
  bd-93cnn9: ReviewGate ran an implementer pass after an APPROVE verdict, then
  parked the task "fix round produced no changes after an approval-gap
  rejection" — observed live twice on 2026-09-26 (bd-6d3h8m / PR #2074 at
  03:53:44Z, bd-9inpfa / PR #2084 at 13:38:09Z), both times on a round-2
  APPROVE whose own DISPOSITIONS block accounted for every carried-forward
  finding (`undispositioned_count: 0` on both `review_gate_rounds` rows).

  Root cause: `Arbiter.Worker.ReviewFindings`'s `@item` regex treated a `-`/`*`
  bullet indented up to column 3 as a brand-new top-level finding, not a
  continuation of the item above it. A numbered marker like `3. ` is itself 3
  characters wide, so a reviewer's own elaboration sub-bullets naturally
  indent 3 spaces to align under it — colliding with that "top-level"
  tolerance. On bd-6d3h8m's round-1 review, item 3's three explanatory
  sub-bullets were split into three extra, severity-less (so fail-closed
  BLOCKING) findings; one of them (a bullet reading "The real round-3 reviews
  … read-only from `~/.arbiter/arbiter.sqlite3`") cited a path no code
  revision could ever "touch", tripping `approval_gap/3`'s mechanical
  `unproven?` backstop even though the round-2 reviewer had genuinely
  dispositioned everything real. The fix restricts `@item` to strict column 0.

  These fixtures are the real `review_gate_rounds.findings` text for both
  incidents, read from the live DB (`~/.arbiter/arbiter.sqlite3`,
  `review_gate_rounds` where `task_id` is `bd-6d3h8m` / `bd-9inpfa`).
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewFindings

  @bd_6d3h8m_round1 Path.expand("../../fixtures/review_findings_bd_6d3h8m_round1.md", __DIR__)
  @bd_6d3h8m_round2 Path.expand("../../fixtures/review_findings_bd_6d3h8m_round2.md", __DIR__)
  @bd_9inpfa_round1 Path.expand("../../fixtures/review_findings_bd_9inpfa_round1.md", __DIR__)
  @bd_9inpfa_round2 Path.expand("../../fixtures/review_findings_bd_9inpfa_round2.md", __DIR__)

  describe "bd-6d3h8m / PR #2074 (round 2 APPROVE at 2026-09-26T03:53:44Z)" do
    test "round 1's sub-bulleted [Low] finding does not fragment into spurious blocking findings" do
      round1 = File.read!(@bd_6d3h8m_round1)
      open = ReviewFindings.extract(round1, 1)

      # Before the fix this was 19 — item 3's three explanatory sub-bullets
      # (aligned 3 spaces under "3. ") each became their own severity-less,
      # fail-closed-BLOCKING "finding" (its own `f.text` starting with the
      # bullet itself, not merged as a continuation of item 3). None of them
      # should stand alone post-fix — the sqlite3/round-3/fixture prose is
      # legitimate continuation text of item 3's own [Low] finding.
      refute Enum.any?(open, &String.starts_with?(&1.text, "- The real round-3 reviews"))
      refute Enum.any?(open, &String.starts_with?(&1.text, "- The file is named after"))
      refute Enum.any?(open, &String.starts_with?(&1.text, "- **Fix:** base the fixture"))
    end

    test "round 2's APPROVE, which dispositions every real finding, has no approval gap" do
      round1 = File.read!(@bd_6d3h8m_round1)
      round2 = File.read!(@bd_6d3h8m_round2)
      open = ReviewFindings.extract(round1, 1)

      # `touched_files` mirrors the files round 2's own DISPOSITIONS block cites
      # as where each fix landed (task_detail_live.ex, prompt_builder.ex, the
      # round.ex/migration/mcp/tools.ex/fixture/test files) — a stand-in for
      # the real `git diff --name-only` the production run had. Deliberately
      # does NOT include `.arbiter/arbiter.sqlite3`: reading a live DB
      # read-only is not a code change, so no revision could ever "touch" it —
      # exactly the file a spurious sub-bullet-turned-finding cited.
      touched =
        MapSet.new([
          "apps/arbiter_web/lib/arbiter_web/live/task_detail_live.ex",
          "apps/arbiter/lib/arbiter/worker/prompt_builder.ex",
          "apps/arbiter/lib/arbiter/worker/review_gate/round.ex",
          "apps/arbiter/priv/repo/migrations/20260925130000_add_fix_round_attempt_to_review_gate_rounds.exs",
          "apps/arbiter/lib/arbiter/mcp/tools.ex",
          "apps/arbiter/test/fixtures/review_findings_bd_28t80i_round3.md",
          "apps/arbiter/test/arbiter/worker/review_gate_coordinator_only_test.exs",
          "apps/arbiter_web/test/arbiter_web/controllers/api/review_gate_round_controller_test.exs",
          "apps/arbiter_web/test/arbiter_web/live/task_detail_live_test.exs",
          "apps/arbiter/test/arbiter/worker/dispatch_test.exs"
        ])

      gap = ReviewFindings.approval_gap(open, round2, touched)

      refute ReviewFindings.gap?(gap),
             "expected the round-2 APPROVE to have no approval gap, got: #{inspect(gap)}"
    end
  end

  describe "bd-9inpfa / PR #2084 (round 2 APPROVE at 2026-09-26T13:38:09Z)" do
    test "round 1's two real [MEDIUM] findings survive extraction intact, not fragmented by their own sub-bullets" do
      round1 = File.read!(@bd_9inpfa_round1)
      open = ReviewFindings.extract(round1, 1)

      medium = Enum.filter(open, &(&1.severity == :medium))
      assert length(medium) == 2, "expected exactly 2 [MEDIUM] findings, got: #{inspect(medium)}"

      assert Enum.any?(medium, &(&1.text =~ "missing dividers between the Policy groups"))
      assert Enum.any?(medium, &(&1.text =~ "Before/after screenshots are not in the PR"))

      # Each finding's own elaboration sub-bullets (- **Cause:**, - **Evidence:**,
      # - **Suggested fix:**, indented to align under the numbered marker) must
      # have merged in as continuation text, not spawned their own ids.
      refute Enum.any?(open, &String.starts_with?(&1.text, "- **Cause:**"))
      refute Enum.any?(open, &String.starts_with?(&1.text, "- **Evidence:**"))
      refute Enum.any?(open, &String.starts_with?(&1.text, "- **Suggested fix:**"))
    end

    test "round 2's APPROVE, which dispositions every real finding, has no approval gap" do
      round1 = File.read!(@bd_9inpfa_round1)
      round2 = File.read!(@bd_9inpfa_round2)
      open = ReviewFindings.extract(round1, 1)

      gap = ReviewFindings.approval_gap(open, round2, nil)

      refute ReviewFindings.gap?(gap),
             "expected the round-2 APPROVE to have no approval gap, got: #{inspect(gap)}"
    end
  end
end
