defmodule Arbiter.Worker.ReviewFindingsTest do
  @moduledoc """
  Finding identity and the per-round DISPOSITIONS protocol (bd-6r8caj / #1137).

  Before this module existed, `review_gate_rounds.findings` was free prose: a
  round-2 reviewer could emit `VERDICT: APPROVE` / `VERIFICATION: FULL` without
  ever revisiting the round-1 finding it had raised, and nothing in the gate
  could tell. These tests pin the mechanical half of the fix — stable ids,
  severity ranking, disposition parsing, and the approval gap — so the gate's
  guard has something checkable to read back.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewFindings

  describe "extract/2" do
    test "assigns a stable F<round>.<n> id to each enumerated finding" do
      findings = """
      VERDICT: REQUEST_CHANGES

      - **Medium**: `proxy_5xx?/1` over-matches bare "http 500" substrings
        (apps/arbiter/lib/arbiter/loop/failure_classifier.ex:172).
      - **Low**: a stray typo in the moduledoc (lib/arbiter/loop/foo.ex:3).
      """

      assert [one, two] = ReviewFindings.extract(findings, 1)
      assert one.id == "F1.1"
      assert two.id == "F1.2"
      assert one.round == 1
      assert one.severity == :medium
      assert two.severity == :low
      assert "apps/arbiter/lib/arbiter/loop/failure_classifier.ex" in one.files
    end

    test "ids are namespaced by round so round 2's findings never collide with round 1's" do
      assert [%{id: "F2.1"}] =
               ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- [high] a.ex:1 bad", 2)
    end

    test "unstructured prose findings become a single fail-closed finding" do
      findings = "VERDICT: REQUEST_CHANGES\nfindings: feature.txt:1 needs a guard before merge"

      assert [%{id: "F1.1", severity: :unknown} = f] = ReviewFindings.extract(findings, 1)
      assert ReviewFindings.blocking?(f), "an unlabelled finding must be treated as blocking"
    end

    test "ignores verdict payload that is not a finding" do
      findings = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] Criterion one — delivered in foo.ex
      - [NOT MET] Criterion two — missing
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed in foo.ex:12
      VERIFICATION: FULL
      arb done
      ⚙ claude session success · 94.7s · $0.59
      """

      assert ReviewFindings.extract(findings, 2) == []
    end

    test "ignores markdown bold and formatted verdict lines as verdict payload" do
      findings = """
      **VERDICT: REQUEST_CHANGES**
      VERIFICATION: PARTIAL

      - **High**: nil pointer exception in lib/foo.ex:42
      """

      assert [one] = ReviewFindings.extract(findings, 1)
      assert one.id == "F1.1"
      assert one.severity == :high
      assert "lib/foo.ex" in one.files
    end

    test "returns [] for nil / blank findings" do
      assert ReviewFindings.extract(nil, 1) == []
      assert ReviewFindings.extract("VERDICT: APPROVE\n", 1) == []
    end

    test "a numbered item's 3-space-indented sub-bullets are continuation, not new findings (bd-93cnn9)" do
      # "3. " is 3 characters wide, so a reviewer's elaboration sub-bullets
      # naturally indent 3 spaces to align under it — the same column range
      # @item used to treat as a brand-new top-level item. Observed live on
      # bd-6d3h8m / PR #2074: an approving round's item 3 ("**[Low]**
      # ... non-blocking") spawned three extra severity-:unknown (fail-closed
      # blocking) findings from its own continuation bullets, and one of them
      # cited a path (`~/.arbiter/arbiter.sqlite3`) no revision could ever
      # "touch", tripping the approval-gap guard on a clean APPROVE.
      findings = """
      VERDICT: REQUEST_CHANGES

      1. **[Medium]** `a.ex:1` — the real finding.
      2. **[Low]** `b.ex:2` — non-blocking, fine to leave as-is.
         - The file is named after that round, but it's a fair trim.
         - The real reviews mark AC1 and AC2 met.
         - Fix: base the fixture on that real text.
      """

      assert [one, two] = ReviewFindings.extract(findings, 1)
      assert one.severity == :medium
      assert two.severity == :low
      assert two.text =~ "Fix: base the fixture"
    end
  end

  describe "blocking?/1 severity ranking" do
    for {label, sev} <- [
          {"Critical", :critical},
          {"Blocker", :blocker},
          {"High", :high},
          {"Major", :major},
          {"Medium", :medium},
          {"Moderate", :moderate}
        ] do
      test "#{label} is Medium-or-higher and therefore blocking" do
        assert [f] =
                 ReviewFindings.extract(
                   "VERDICT: REQUEST_CHANGES\n- #{unquote(label)}: a.ex:1 x",
                   1
                 )

        assert f.severity == unquote(sev)
        assert ReviewFindings.blocking?(f)
      end
    end

    for {label, sev} <- [{"Low", :low}, {"Minor", :minor}, {"Nit", :nit}] do
      test "#{label} is below Medium and not blocking" do
        assert [f] =
                 ReviewFindings.extract(
                   "VERDICT: REQUEST_CHANGES\n- #{unquote(label)}: a.ex:1 x",
                   1
                 )

        assert f.severity == unquote(sev)
        refute ReviewFindings.blocking?(f)
      end
    end
  end

  describe "extract/2 — non-blocking observations (bd-c6tdbu / bd-1xss5z)" do
    test "an unlabelled item under a 'Non-blocking observations' header is not fail-closed" do
      findings = """
      VERDICT: REQUEST_CHANGES
      - **Minor**: rename `x` for clarity (a.ex:1).
      - **Minor**: extract a helper eventually (b.ex:2).
      - **Low**: stray whitespace (c.ex:3).

      Non-blocking observations (no change requested):
      - The retry loop could be simplified, but it's not wrong.
      - Consider a follow-up for the duplicated setup code.
      """

      assert [f1, f2, f3, f4, f5] = ReviewFindings.extract(findings, 1)
      assert f1.severity == :minor
      assert f2.severity == :minor
      assert f3.severity == :low

      assert f4.severity == :non_blocking
      assert f5.severity == :non_blocking
      refute ReviewFindings.blocking?(f4)
      refute ReviewFindings.blocking?(f5)
      assert f4.id == "F1.4"
      assert f5.id == "F1.5"
    end

    test "an unlabelled item OUTSIDE any non-blocking header still fails closed at Medium" do
      findings = """
      VERDICT: REQUEST_CHANGES
      - **Minor**: cosmetic nit (a.ex:1).
      - this one has no severity label at all (b.ex:2).
      """

      assert [f1, f2] = ReviewFindings.extract(findings, 1)
      assert f1.severity == :minor
      assert f2.severity == :unknown
      assert ReviewFindings.blocking?(f2)
    end

    test "a non-blocking section header variant without the parenthetical is recognized" do
      findings = """
      VERDICT: REQUEST_CHANGES
      Non-blocking observations:
      - Just a passing thought.
      """

      assert [f] = ReviewFindings.extract(findings, 1)
      assert f.severity == :non_blocking
    end
  end

  describe "dispositions/1" do
    test "parses every disposition status, in either order" do
      text = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed in failure_classifier.ex:180
      - [NOT ADDRESSED] F1.2 — the implementer never touched this
      - [OBSOLETE] F1.3 — the branch it cited was deleted by another fix
      - F1.4 [ADDRESSED] — id-first form is tolerated too
      VERIFICATION: FULL
      """

      d = ReviewFindings.dispositions(text)

      assert d["F1.1"].status == :addressed
      assert d["F1.2"].status == :not_addressed
      assert d["F1.3"].status == :obsolete
      assert d["F1.4"].status == :addressed
    end

    test "[NOT ADDRESSED] is never mis-read as [ADDRESSED]" do
      d = ReviewFindings.dispositions("DISPOSITIONS:\n- [NOT ADDRESSED] F1.1 — nope")
      assert d["F1.1"].status == :not_addressed
    end

    test "returns an empty map when no DISPOSITIONS block is present" do
      assert ReviewFindings.dispositions("VERDICT: APPROVE\nlooks good\nVERIFICATION: FULL") ==
               %{}

      assert ReviewFindings.dispositions(nil) == %{}
    end
  end

  describe "approval_gap/3 — the bd-8mtb0q shape" do
    setup do
      open =
        ReviewFindings.extract(
          """
          VERDICT: REQUEST_CHANGES
          - **Medium**: proxy_5xx?/1 over-matches (apps/arbiter/lib/arbiter/loop/failure_classifier.ex:172)
          - **Low**: typo in the moduledoc (apps/arbiter/lib/arbiter/loop/other.ex:3)
          """,
          1
        )

      {:ok, open: open}
    end

    test "a round-2 APPROVE that never mentions the prior Medium finding is a gap", %{open: open} do
      approve = "VERDICT: APPROVE\nThe change looks good.\nVERIFICATION: FULL\narb done"

      gap = ReviewFindings.approval_gap(open, approve, nil)

      assert ReviewFindings.gap?(gap)
      assert ["F1.1"] = Enum.map(gap.missing, & &1.id)
      assert gap.unaddressed == []
      assert gap.unproven == []
    end

    test "a Low finding left undispositioned is NOT a gap", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — guarded in failure_classifier.ex:180
      VERIFICATION: FULL
      """

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, nil))
    end

    test "an APPROVE that admits a Medium finding is NOT ADDRESSED is a gap", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.1 — still over-matches, but I'll let it slide
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, approve, nil)
      assert ReviewFindings.gap?(gap)
      assert ["F1.1"] = Enum.map(gap.unaddressed, & &1.id)
    end

    test "OBSOLETE dispositions a finding invalidated by a different fix (AC5)", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [OBSOLETE] F1.1 — the whole proxy_5xx? branch was deleted, so the over-match cannot occur
      VERIFICATION: FULL
      """

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, nil))
    end

    test "the untouched-file backstop rejects an ADDRESSED claim with no diff and no evidence",
         %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — the implementer resolved this
      VERIFICATION: FULL
      """

      # The implementer's revise round touched only an unrelated file — exactly
      # the bd-8mtb0q shape, where `git diff` for the cited file was empty.
      touched = MapSet.new(["apps/arbiter/lib/arbiter/loop/unrelated.ex"])

      gap = ReviewFindings.approval_gap(open, approve, touched)
      assert ReviewFindings.gap?(gap)
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end

    test "naming an untouched file is not an escape hatch — a fix cannot land in an unchanged file",
         %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed in apps/arbiter/lib/arbiter/loop/failure_classifier.ex:180
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, approve, MapSet.new(["docs/loop-review.md"]))
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end

    test "an ADDRESSED claim that names where the fix landed survives the backstop", %{open: open} do
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — the classification now happens in apps/arbiter/lib/arbiter/loop/router.ex:44
      VERIFICATION: FULL
      """

      touched = MapSet.new(["apps/arbiter/lib/arbiter/loop/router.ex"])
      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end

    test "an ADDRESSED claim whose cited file WAS touched survives the backstop", %{open: open} do
      approve =
        "VERDICT: APPROVE\nDISPOSITIONS:\n- [ADDRESSED] F1.1 — guarded now\nVERIFICATION: FULL"

      touched = MapSet.new(["apps/arbiter/lib/arbiter/loop/failure_classifier.ex"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end

    test "no open findings means no gap — a round-1 APPROVE is untouched by this guard" do
      refute ReviewFindings.gap?(ReviewFindings.approval_gap([], "VERDICT: APPROVE", nil))
    end

    test "an ADDRESSED claim citing a dotfile survives the backstop when that dotfile was touched",
         %{open: open} do
      # bd-bm6bfs (emr-8fqbng, MR !294): the finding and its disposition both
      # cite `.gitlab-ci.yml`. `git diff --name-only` reports the leading dot
      # too, so the touched set below is exactly what a real diff produces.
      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — `.gitlab-ci.yml:57` now includes the missing glob
      VERIFICATION: FULL
      """

      touched = MapSet.new([".gitlab-ci.yml"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end
  end

  describe "approval_gap/3 — bd-bm6bfs (emr-8fqbng round 2, false park on a dispositioned APPROVE)" do
    setup do
      # The exact round-1 findings text persisted for emr-8fqbng (MR !294),
      # read verbatim from `review_gate_rounds.findings` for
      # run_id=0ddfed09-50cc-43df-aa38-8b9d59a2f2d9 (round 1, 2026-09-24
      # 00:56:40Z) — the round the incident's round-2 APPROVE was actually
      # judged against, not the later request-changes round at 01:12:29Z.
      round1 = """
      VERDICT: REQUEST_CHANGES
      CRITERIA:
      - [MET] No `minio/minio` or `minio/mc` Docker Hub references remain in `.gitlab-ci.yml` or other CI/dev config; every one points to a pinned `quay.io/minio/...` tag — confirmed via repo-wide grep (`.gitlab-ci.yml:35`, `.gitlab-ci.yml:108`, `docker-compose.yml:14` all use `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`; no other hits anywhere, including `ansible/`).
      - [NOT MET] The MR's own pipeline gets past 'prepare environment' on the test, coverage and visual jobs, and those jobs pass — only `visual` actually ran and passed (job 16696508264, pipeline 2877022362, confirmed live: successfully pulled `quay.io/minio/minio:RELEASE...` and completed). `test` and `coverage` never appear in the pipeline's job list at all (verified twice via `GET /pipelines/2877022362/jobs?per_page=100`) because their `rules: changes:` globs (`.gitlab-ci.yml:48-56`, `.gitlab-ci.yml:199-208`) don't include `.gitlab-ci.yml`/`docker-compose.yml`, unlike `visual`'s rule (`.gitlab-ci.yml:113-121`) which does. So this MR's pipeline supplies zero direct evidence that the fixed image works under the `test`/`coverage` jobs' execution context.
      Findings:
      1. **Major** — `.gitlab-ci.yml:48-56` (and mirrored at `.gitlab-ci.yml:199-208` for `coverage`, which additionally `needs: test`): the `test` job's rule `changes:` list (`lib/**/*`, `test/**/*`, `mix.exs`, `mix.lock`, `config/**/*`, `priv/**/*`, `assets/**/*`, `rel/**/*`) omits `.gitlab-ci.yml`, so for an MR that only edits `.gitlab-ci.yml`/`docker-compose.yml` — exactly this MR — GitLab CI never creates the `test` or `coverage` jobs. Live confirmation: pipeline `2877022362` for HEAD `2218e545` contains only `visual` and the five `audit:*` jobs; no `test`/`coverage` job exists in the run at all.
         - Failure scenario: acceptance criterion 2 requires this MR's own pipeline to show `test`, `coverage`, and `visual` getting past 'prepare environment' and passing. Since `test`/`coverage` never start, there is no pipeline evidence — only inference from `visual`'s success — that the image pull, `MINIO_KMS_SECRET_KEY` handshake, and SSE-S3 behavior work correctly under the `test` job's 4-way `parallel` matrix or the `coverage` merge step.
         - Suggested fix: add `".gitlab-ci.yml"` to the `changes:` globs for the `test` job (`.gitlab-ci.yml:49-56`) and `coverage` job (`.gitlab-ci.yml:200-207`), mirroring what `visual`'s rule already does at `.gitlab-ci.yml:113-121`. Push that as part of this MR (or a fixup commit) so the pipeline actually exercises `test`/`coverage`, then attach their passing results as evidence before merge. This also fixes the underlying gap for any future CI-only change.
      The image-reference change itself is correct and minimal: `command`, `alias`, and the SSE/KMS variables are untouched in both `.gitlab-ci.yml` services, `docker-compose.yml` was updated identically, and I independently confirmed the pinned tag `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z` exists and is pullable (`docker manifest inspect` succeeded) and that the `visual` job in this MR's real pipeline pulled it and passed. The blocking issue is purely that criterion 2's required pipeline evidence for `test`/`coverage` doesn't exist yet due to a pre-existing rules gap, not a defect in the image substitution itself.
      VERIFICATION: FULL
      arb done
      """

      {:ok, open: ReviewFindings.extract(round1, 1)}
    end

    test "the round's own DISPOSITIONS block dispositions every open finding and the APPROVE is accepted",
         %{open: open} do
      # The exact round-2 findings text persisted for emr-8fqbng, read
      # verbatim from `review_gate_rounds.findings` for
      # run_id=0d06cc85-7653-48e3-bf21-850a77f109d3 (round 2, 2026-09-24
      # 01:09:26Z) — the APPROVE the verdict guard wrongly parked because it
      # thought F1.2/F1.4 were undispositioned, even though the DISPOSITIONS
      # block plainly addresses them. `.gitlab-ci.yml` is the file both the
      # findings and the dispositions cite, and it really was touched by the
      # revise round.
      round2 = """
      VERDICT: APPROVE
      CRITERIA:
      - [MET] No `minio/minio` or `minio/mc` Docker Hub references remain in `.gitlab-ci.yml` or other CI/dev config; every one points to a pinned `quay.io/minio/...` tag — repo-wide grep confirms zero remaining Docker Hub references; `.gitlab-ci.yml:35` (test), `.gitlab-ci.yml:109` (visual), and `docker-compose.yml` all use `quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z`.
      - [MET] The MR's own pipeline gets past 'prepare environment' on the test, coverage and visual jobs, and those jobs pass — pipeline `2877033012` (MR !294, commit `313f5efdc7872a58f329815021436aa5c2422432`) shows `test 1/4` through `4/4`, `coverage`, and `visual` all with status `success`. Job traces confirm real execution, not stubs: job `16696573577` (`test 1/4`) shows `Using effective pull policy of [] for container minio` → `Preparing environment` → `Finished in 116.8 seconds`; job `16696573582` (`coverage`) shows `Preparing environment` → `[TOTAL] 84.0%` → `Job succeeded`; job `16696573581` (`visual`) shows the same minio pull → `Preparing environment` → `Job succeeded`. This is the pipeline evidence that was missing in round 1 and is now present because the `changes:` rule gap (F1.2/F1.4) is fixed.
      Findings: none.
      VERIFICATION: FULL
      DISPOSITIONS:
      - [ADDRESSED] F1.2 — `.gitlab-ci.yml:57` (test job) and `.gitlab-ci.yml:209` (coverage job) now include `".gitlab-ci.yml"` in their `changes:` globs, mirroring `visual`'s existing rule. Confirmed by `git diff e48cfee..HEAD -- .gitlab-ci.yml` (commit `313f5ef`) and by re-reading the current file at both lines.
      - [ADDRESSED] F1.4 — same fix as F1.2, same locations (`.gitlab-ci.yml:57`, `.gitlab-ci.yml:209`); this id's suggested fix is identical to F1.2's and was implemented verbatim.
      - [ADDRESSED] F1.3 — the missing pipeline evidence for `test`/`coverage` under the real execution context now exists: live pipeline `2877033012` for commit `313f5ef` shows `test 1/4`-`4/4`, `coverage`, and `visual` all succeeding, with job traces confirming the `quay.io` minio image pulled and the KMS/SSE handshake worked (tests ran to completion, coverage computed `[TOTAL] 84.0%`). This evidence exists because the `.gitlab-ci.yml:57`/`209` fix (same as F1.2) let the jobs actually run.
      - [OBSOLETE] F1.1 — this id carried no file citation and an empty findings body (just a bare "Findings:" header with no content), duplicating the round-1 reviewer output structure rather than naming a distinct problem. Its only substantive content is captured by F1.2/F1.4, which are addressed above.
      arb done
      """

      d = ReviewFindings.dispositions(round2)
      assert %{status: :addressed} = d["F1.2"]
      assert %{status: :addressed} = d["F1.3"]
      assert %{status: :addressed} = d["F1.4"]
      assert %{status: :obsolete} = d["F1.1"]

      # The revise round's real `git diff --name-only` output — it only
      # touched `.gitlab-ci.yml`.
      touched = MapSet.new([".gitlab-ci.yml"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, round2, touched))
    end
  end

  describe "approval_gap/3 — bd-bcroux (PR #2086 round 3, false park) root cause (bd-7urncn)" do
    # Verbatim from `review_gate_rounds.findings`, task_id=bd-bcroux, round 1,
    # role=review, id=cb0758d5-ebcf-4e55-b072-393f992f27f9. This is the exact
    # text the live round-1 reviewer produced and the live round-3 reviewer
    # (below) was reacting to.
    @bcroux_round1 """
    VERDICT: REQUEST_CHANGES
    CRITERIA:
    - [NOT MET] Every listed issue is fixed at 375px and 414px widths in light and dark themes, with no page-level horizontal scroll — both issues are fixed in code: the pane scrolls sideways (`domain.ex:603-616`, `overflow-x-auto`, rows `w-max min-w-full`, `whitespace-pre`), and close/Max are 44px below `sm` (`session_dock_live.ex:2050,2089`) with Compact taken out of the row that overflowed (`session_dock_live.ex:903-908`). But the PR itself says the page still scrolls sideways by about 4px at 375px (`#app-status-bar`) and calls that out of scope. It also gives no clear way back out of Maximize on a phone (finding 2).
    - [NOT MET] No desktop regression at 1280px (screenshots) — every `max-sm:` change is inactive at 1280px, so a regression is unlikely. But the PR has no 1280px screenshots, only a statement that some were taken locally in `/tmp`.
    - [NOT MET] Before/after mobile screenshots in the PR — the PR says outright that the screenshots are not in it ("They live only in this local run's `/tmp` scratch space") and hands the reviewer a command to make them.
    - [NOT MET] `mix precommit` passes — the PR marks this `[~]` and lists failing tests as unrelated or flaky. It is not shown passing. The failures it lists do match known baseline flakes (the `ARB_*` worker-env tests and a browser test under parallel load), but the criterion is still unmet as written.
    Findings:
    1. **High — PR description (AC 2 and AC 3): the required screenshots are missing.** The ticket asks for before/after mobile screenshots, and a 1280px comparison, in the PR. The PR contains none.
       - Fix: run `ARB_MOBILE_TOUCH_SCREENSHOT=... mix test .../mobile_touch_browser_test.exs --include browser`.
       - Attach the PNGs through GitHub's own PR image upload, or commit them to the branch and link them. Do not use a public or anonymous paste host.
       - If attaching is impossible from a worker, list the criterion as unmet and escalate it rather than relying on local `/tmp` files.
    2. **Medium — `apps/arbiter_web/lib/arbiter_web/live/session_dock_live.ex:2049` has no clear "way back" from Maximize below `sm`.**
       - The ticket says Maximize should fill the viewport "with an obvious way back".
       - Below `sm`, Compact and Side are hidden (`size != "max" && "max-sm:hidden"`). Once maximized, the only visible size button is Max, already pressed, and pressing it again does nothing (`set_size` just stores `"max"`, line 312).
       - The only other exits are tapping the window title (collapses it, which nothing signals) and Dismiss (closes the window).
       - On a phone, Compact is now nearly full-screen anyway (`inset-x-3`), so the two sizes look almost the same and there is nothing to restore to.
       - Fix: below `sm`, show one touch-sized Restore/Minimize button in place of Max while maximized. It can call `collapse`, or `set_size` back to the stored non-max preference. Add a test asserting it is present and at least 44px.
    3. **Medium — AC 1, the page still scrolls sideways at 375px.**
       - The PR's own measurements show `#app-status-bar` (`layouts.ex`) overflowing the viewport by about 4px at 375px on every page, including the pages this ticket covers. The acceptance criterion rules out any page-level horizontal scroll.
       - Fix: stop the status bar overflowing below `sm`, for example `min-w-0` or truncation on the wordmark, or tighter gaps under `max-sm:`. Or get the coordinator to confirm the carve-out.
       - Once fixed, drop the header-hiding exception from `scripts/verify_mobile_touch.mjs` so the browser test checks the page as users actually see it.
    4. **Low — `apps/arbiter_web/lib/arbiter_web/live/session_dock_live.ex:2126`: the window-menu trigger (`...`) is still 22px below `sm`.**
       - It sits in the same title bar as the resized close and Max buttons, and it is the only way to reach Detach, Kill and Info on a phone.
       - Fix: add `max-sm:size-11` for consistency with the other title-bar controls.
    5. **Low — `apps/arbiter_web/lib/arbiter_web/components/core_components/domain.ex:603-640`: the change reaches pages beyond the worker view.**
       - `log_stream/1` is also used by `run_detail_live.ex:173` and `task_detail_live.ex:2479,2521`. Those panes switch from ellipsis truncation to horizontal scrolling too.
       - This is probably what we want, but the PR doesn't mention it and there are no screenshots of those pages.
       - Fix: say so in the PR, and include a 1280px screenshot of task detail as well.
    What was checked: I confirmed HEAD is `ab9d4f0d` and reviewed only this branch's changes (diff against `ef2effa5`). I did not run `mix precommit` or the browser test, and I did not boot the app.
    VERIFICATION: FULL
    arb done
    ⚙ claude session success · 115.1s · $0.4671
    """

    # ROOT CAUSE (bd-7urncn): the guard's own log said "approved without
    # dispositioning open finding(s) F1.20, F1.3" for the round-3 APPROVE
    # below, even though that text plainly contains "[ADDRESSED] F1.3" and
    # "[ADDRESSED] F1.20" lines that `dispositions/1` parses correctly (see
    # the parsing test below — it always could). The guard's ids never came
    # from those two `[ADDRESSED]` lines failing to parse; they came from the
    # extractor that was live at the time (pre-#2105 / bd-93cnn9)
    # FRAGMENTING round 1's own indented sub-bullets into their own
    # `:unknown`-severity (fail-closed blocking) top-level findings. Under
    # that old extractor, item 1's "- Fix: run `ARB_MOBILE_TOUCH_SCREENSHOT=…`
    # … .../mobile_touch_browser_test.exs" sub-bullet became its own finding
    # (numbered "F1.3" in the live run), and item 5's "- `log_stream/1` is
    # also used by `run_detail_live.ex:173` and
    # `task_detail_live.ex:2479,2521`" sub-bullet became another (numbered
    # "F1.20") — both citing files the PR's revise rounds never touched again
    # (one names a *command target*, not a file to edit; the other repeats a
    # citation from the initial commit, before round 1 ever ran). The
    # round-3 reviewer, prompted with THOSE ids, correctly dispositioned them
    # — the DISPOSITIONS lines are right there — but the guard's mechanical
    # unproven-file backstop (bd-6r8caj) rejected both anyway, because
    # neither cited file had been touched by any revision.
    #
    # `extract/2`'s current behavior (bd-93cnn9 / #2105, already on this
    # branch's base) fixes the fragmentation itself: an indented sub-bullet is
    # a continuation of its parent item, not a new finding. Re-running the
    # verbatim round-1 text above through today's `extract/2` proves the
    # phantom "F1.3"/"F1.20" fragments this incident hinged on can no longer
    # be manufactured.
    test "extract/2 no longer fragments round 1's sub-bullets into phantom unknown-severity findings" do
      items = ReviewFindings.extract(@bcroux_round1, 1)

      # The two phantom fragments from the live incident must not appear as
      # their own standalone finding text.
      refute Enum.any?(items, fn f ->
               String.trim(f.text) ==
                 "- Fix: run `ARB_MOBILE_TOUCH_SCREENSHOT=... mix test .../mobile_touch_browser_test.exs --include browser`."
             end)

      refute Enum.any?(items, fn f ->
               String.trim(f.text) ==
                 "- `log_stream/1` is also used by `run_detail_live.ex:173` and `task_detail_live.ex:2479,2521`."
             end)

      # Instead, each numbered item (plus the bare "Findings:" header, which
      # is a separate pre-existing quirk this task does not touch) stays a
      # single finding: 5 numbered items + 1 header = 6, with the real
      # severities the reviewer actually wrote.
      assert Enum.map(items, & &1.severity) == [:unknown, :high, :medium, :medium, :low, :low]
    end

    # The `[ADDRESSED] F1.3` / `[ADDRESSED] F1.20` lines from the real
    # round-3 text, exactly as persisted — proving `dispositions/1` was never
    # the part of the pipeline that misread this incident.
    test "dispositions/1 correctly parses the real F1.3 and F1.20 ADDRESSED lines verbatim" do
      text = """
      DISPOSITIONS:
      - [ADDRESSED] F1.3 — The implementer ran the browser test with `ARB_MOBILE_TOUCH_SCREENSHOT` set, on this branch and on an `ef2effa5` scratch worktree. The test file needed no edit. The resulting PNGs are committed under `docs/pr-2086-screenshots/`.
      - [ADDRESSED] F1.20 — Disclosed in PR body Summary bullet 1, which names `run_detail_live.ex` and `task_detail_live.ex`. Neither file needed a change.
      """

      d = ReviewFindings.dispositions(text)

      assert %{status: :addressed} = d["F1.3"]
      assert %{status: :addressed} = d["F1.20"]
    end

    # Verbatim from `review_gate_rounds.findings`, task_id=bd-bcroux, round 2,
    # role=review, id=5d04238f-9518-4ec3-ba76-9e456e01b051.
    @bcroux_round2 """
    VERDICT: REQUEST_CHANGES
    CRITERIA:
    - [MET] Every listed issue is fixed at 375px and 414px in light and dark themes, with no page-level horizontal scroll — I ran `mix test test/arbiter_web/live/mobile_touch_browser_test.exs --include browser` in headless Chromium and it printed `RESULT: PASS`. At both widths and in both themes:
      - The output pane has `overflow-x=auto` and scrolls sideways by itself (pane `scrollWidth=3364`, `clientWidth=341`/`380`; `pane.scrollLeft=200` while `page.scrollX` stays at 0).
      - The page's `scrollWidth` equals the viewport width.
      - Close, Max, Restore and the `...` menu button are all 44x44.
      - Max fills the viewport (351x670 in 375x812), and Restore goes back to compact.
      - Code: `domain.ex:603-640` (`overflow-x-auto`, `w-max min-w-full`, `whitespace-pre`), `session_dock_live.ex:903-908` (Compact is `fixed` below `sm`), `:2035-2085` (Max and the new Restore button), `:2115` and `:2158` (`max-sm:size-11`), `app.css:298-308`, `layouts.ex:126-136`.
    - [MET] No desktop regression at 1280px — the browser check `desktop-1280-no-page-level-horizontal-scroll` passes (`scrollWidth=1265`, viewport 1280). The PR has 1280 screenshots of worker output and the session dock, and all the new phone classes are behind `max-sm:`/`sm:hidden`. The 147 tests in `session_dock_live_test.exs`, `worker_detail_live_test.exs` and `run_detail_live_test.exs` pass with 0 failures.
    - [NOT MET] Before/after mobile screenshots in the PR — every mobile screenshot is an "after" capture. The PR body says so itself: "These are 'after' captures from this round's live run. I did not re-capture pre-round-2 'before' shots…" The round-1 "before" states (the line cut off with an ellipsis, the Compact window pushed off-screen) are only described in text. The file `414-light-session-dock-before-maximize.png` means "before pressing Max", not "before the fix".
    - [NOT MET] `mix precommit` passes — the implementer marks this `[~]` and reports 8 umbrella failures they call unrelated. My own checks came out clean: `mix format --check-formatted` exits 0, `mix credo --strict` finds no issues in the changed files, and the targeted tests pass. But neither I nor the implementer has recorded a clean full `mix precommit` run.
    FINDINGS:
    1. **Severity: Medium** — the PR description (PR #2086 body, "## Screenshots" section; images in `docs/pr-2086-screenshots/`) has no "before" mobile screenshots, which acceptance criterion 3 requires.
       - Fix: check out the fork point `ef2effa5` in a scratch worktree and copy in `scripts/verify_mobile_touch.mjs` and `mobile_touch_browser_test.exs`. The script's checks will fail there, which is expected; the screenshots are still written. Run it with `ARB_MOBILE_TOUCH_SCREENSHOT=<path>` so it captures `375-{light,dark}-worker-output` and `375/414-*-session-dock-before-maximize` from the unfixed code. Add them to the PR as clearly labelled Before/After pairs.
    2. **Severity: Low** — the "Test plan" in the PR body leaves `mix precommit` as `[~]`.
       - Fix: re-run `mix precommit && mix audit` with `ARB_WORKER_BEAD_ID`, `ARB_RELEASE_REPO`, `ARB_PRIMARY_CHECKOUT` and `ARB_WORKSPACE` unset (the 6 env-dependent failures are a known artifact of running inside a worker). Re-run any flaky timing test such as `ProcessTeardownTest` on its own, and record the resulting pass in the PR.
    3. **Severity: Low (optional)** — `docs/pr-2086-screenshots/*.png` commits about 230KB of PR-only images to the repo permanently.
       - Fix: once the PR body points at hosted copies, consider dropping `docs/pr-2086-screenshots/` from the branch before merge, or confirm with the coordinator that screenshots belong in the repo.
    The code changes themselves were checked in a real browser and I found no correctness defects in them. Changing `log_stream/1` also affects the run and task detail panes: they now scroll sideways instead of cutting off long lines with an ellipsis. That is consistent with the ticket, and the PR says so.
    VERIFICATION: FULL
    arb done
    ⚙ claude session success · 203.2s · $0.6274
    """

    # Verbatim from `review_gate_rounds.findings`, task_id=bd-bcroux, round 3,
    # role=review, id=9f7c1b37-b2dd-46e3-83e3-0995ee2df2c1 — the exact APPROVE
    # text the live guard rejected as `verdict_guard_exhausted`.
    @bcroux_round3 """
    VERDICT: APPROVE
    DISPOSITIONS:
    - [ADDRESSED] F1.1 — This is the empty "Findings:" header from round 1, not a finding in itself. Every item under it is dispositioned below.
    - [ADDRESSED] F1.2 — PR #2086 body, "## Screenshots" section, now has before/after pairs and two 1280px shots. The images are in `docs/pr-2086-screenshots/before-*.png`, `after-*.png` and `desktop-1280-*.png`. I opened the PNGs: the before shots show the pre-fix wordmark, the ellipsis-truncated line and the Compact/Side/Max strip. The after shots show the icon brandmark, the scrollable pane and the Restore icon. All 12 files have different md5 hashes. The PR's rendered HTML resolves the image `src` to `../blob/<branch>/docs/...?raw=true`.
    - [ADDRESSED] F1.3 — The implementer ran the browser test with `ARB_MOBILE_TOUCH_SCREENSHOT` set, on this branch and on an `ef2effa5` scratch worktree. The test file needed no edit. The resulting PNGs are committed under `docs/pr-2086-screenshots/`.
    - [ADDRESSED] F1.4 — The PNGs are committed to the branch (`docs/pr-2086-screenshots/*`) and linked through github.com blob URLs. No paste host was used.
    - [OBSOLETE] F1.5 — This was the fallback in case attaching proved impossible. It didn't: the screenshots are attached.
    - [ADDRESSED] F1.6 — There is now a Restore button below `sm` while maximized: `session_dock_live.ex:2073-2085` (`id="session-dock-restore-…"`, `size-11 sm:hidden`, `set_size` to `compact`).
    - [ADDRESSED] F1.7 — The Restore button (`session_dock_live.ex:2076`) is the way back. It is visible in `after-375-light-session-dock-maximized.png`.
    - [ADDRESSED] F1.8 — Max now hides itself below `sm` while maximized (`session_dock_live.ex:2054-2055`), and Restore takes its place.
    - [ADDRESSED] F1.9 — Leaving Maximize no longer depends on tapping the title or dismissing the window, because Restore exists (`session_dock_live.ex:2073-2085`).
    - [OBSOLETE] F1.10 — This was context for F1.6/F1.11. Restoring to Compact returns the window to its docked `fixed inset-x-3` layout (`:903-908`), which the browser check confirms.
    - [ADDRESSED] F1.11 — The button is at `session_dock_live.ex:2073-2085`. The test at `session_dock_live_test.exs:1491-1509` checks that it is absent, then present with `size-11` once maximized, and that clicking it removes it. The browser check `restore-from-maximize-is-touch-sized` is at `verify_mobile_touch.mjs:286`.
    - [ADDRESSED] F1.12 — Below `sm` the status bar shows the icon brandmark instead of the wordmark (`layouts.ex:126,134`). The browser check `no-page-level-horizontal-scroll` now runs without the header exception (`verify_mobile_touch.mjs:342-349`).
    - [ADDRESSED] F1.13 — `layouts.ex:126` (wordmark `max-sm:hidden`) and `layouts.ex:134` (icon `sm:hidden`).
    - [ADDRESSED] F1.14 — Same fix, in `layouts.ex:126-136`.
    - [ADDRESSED] F1.15 — The header-hiding exception has been removed from `scripts/verify_mobile_touch.mjs:342-349`, and the comment there records the removal.
    - [ADDRESSED] F1.16 — The menu trigger now has `max-sm:size-11` (`session_dock_live.ex:2158`).
    - [ADDRESSED] F1.17 — Same fix as F1.16 (`session_dock_live.ex:2158`).
    - [ADDRESSED] F1.18 — `max-sm:size-11` is on the trigger at `session_dock_live.ex:2158`.
    - [ADDRESSED] F1.19 — The fix is a disclosure rather than a code change. The PR body's Summary bullet 1 says the run and task detail panes get the same horizontal scroll. The behaviour change is intended by the ticket.
    - [ADDRESSED] F1.20 — Disclosed in PR body Summary bullet 1, which names `run_detail_live.ex` and `task_detail_live.ex`. Neither file needed a change.
    - [ADDRESSED] F1.21 — Disclosed in the PR body. The body also says openly that task and run detail were reviewed by inspection, not by screenshot.
    - [ADDRESSED] F1.22 — The disclosure is done. There is no task-detail 1280px shot, but the PR body says so plainly. The worker-output 1280px shot uses the same `log_stream/1` component (`domain.ex:603-640`). The round-2 review accepted this.
    - [OBSOLETE] F2.1 — This was a positive observation from round 2's CRITERIA, not a defect. The code it describes is still in place at `domain.ex:610,628,640`.
    - [OBSOLETE] F2.2 — A positive observation, not a defect. It is still covered by the `no-page-level-horizontal-scroll` check (`verify_mobile_touch.mjs:349`).
    - [OBSOLETE] F2.3 — A positive observation, not a defect. The controls are still at `session_dock_live.ex:2076,2115,2158`.
    - [OBSOLETE] F2.4 — A positive observation, not a defect. The Max and Restore behaviour is still at `session_dock_live.ex:2054,2073-2085`.
    - [OBSOLETE] F2.5 — This is a list of code citations from round 2's CRITERIA, not a defect. I re-read each cited location in the current diff and it still matches.
    - [ADDRESSED] F2.6 — The PR body now has labelled before/after pairs. The before files are `docs/pr-2086-screenshots/before-375-{light,dark}-worker-output.png`, `before-375-{light,dark}-session-dock-maximized.png` and `before-414-light-session-dock-before-maximize.png`, all added in commit `8f0d706b`. I viewed them, and they show the pre-fix UI.
    - [ADDRESSED] F2.7 — The implementer followed this procedure: a scratch worktree at `ef2effa5` with the test and script copied in. The resulting `before-*.png` files were committed in `8f0d706b`.
    - [ADDRESSED] F2.8 — The Test plan in the PR body now marks `mix precommit` `[x]` with counts from a run with the worker env vars unset. The only failure is `EpicPageBrowserTest`'s "stuck chip" check, a known failure that also happens on main.
    - [ADDRESSED] F2.9 — The re-run with `ARB_*` unset is recorded in the PR body's Test plan, together with a clean `mix audit` result.
    - [OBSOLETE] F2.10 — This was optional. Hosting the images anywhere but the repo is ruled out, and AC3 needs them in the PR. Committing them to the repo was the approach round 1 suggested. The implementer's rebuttal holds, and whether to keep them is for the coordinator to decide.
    - [OBSOLETE] F2.11 — Same reason as F2.10: there is no hosted copy the PR could point to instead.
    CRITERIA:
    - [MET] Every listed issue is fixed at 375px and 414px, in light and dark themes, with no page-level horizontal scroll.
      - Output pane: `overflow-x-auto`, rows are `w-max min-w-full`, text is `whitespace-pre` (`domain.ex:610,628,640`).
      - Dock: Compact is `fixed` below `sm` (`session_dock_live.ex:903-908`).
      - Touch targets are 44px: close at `:2115`, menu at `:2158`, Max at `:2054-2055`, Restore at `:2073-2085`.
      - Status bar uses the icon below `sm` (`layouts.ex:126,134`).
      - The browser check runs without the header exception.
    - [MET] No desktop regression at 1280px. All the new classes are scoped to `max-sm:` or `sm:hidden`. The check `desktop-1280-no-page-level-horizontal-scroll` passes (`verify_mobile_touch.mjs:173`), and the 1280px screenshots are in the PR.
    - [MET] Before/after mobile screenshots in the PR. They are real before (`ef2effa5`) and after captures, committed and embedded as labelled pairs. I viewed them and confirmed they are distinct and plausible.
    - [MET] `mix precommit` passes. The PR records a run with the worker env vars unset: arbiter 0 failures, arbiter_cli 0 failures, and arbiter_web 1 failure, the known "stuck chip" check that also fails on main. `mix audit` is clean. I re-ran `session_dock_live_test.exs` and `worker_detail_live_test.exs` just now: 147 tests, 0 failures. `mix format --check-formatted` exits 0.
    FINDINGS:
    None blocking. One informational note: Restore always returns to `compact` rather than to the last non-max size the user had. That is acceptable, because Side is not available below `sm` anyway.
    VERIFICATION: FULL
    arb done
    ⚙ claude session success · 152.4s · $0.7205
    """

    # THE REAL INCIDENT (bd-7urncn round 2 finding 1): running the actual
    # stored round-3 APPROVE above through `approval_gap/3` — with `open`
    # built from round 1's AND round 2's real blocking findings, and
    # `touched` the real files `git diff --name-only` reports across the
    # merged PR's round-2 (`18eb2da9`) and round-3 (`8f0d706b`) commits — used
    # to still return `unproven: ["F1.2"]` even after the fragmentation fix
    # above (bd-93cnn9): F1.2's real disposition line cites only glob paths
    # (`docs/pr-2086-screenshots/before-*.png`, `after-*.png`,
    # `desktop-1280-*.png`), and neither `files_in/1` nor `touched?/2` could
    # match a `*` against a literal committed filename — `files_in/1` did not
    # even extract a glob as a path token (the filename character class
    # rejected `*` outright), so the disposition named no location at all and
    # `unproven?/3` fired. The fix widens `@path`'s filename segment to accept
    # `*` and gives `touched?/2` a glob-matching branch (`*` never crosses
    # `/`) so a disposition can legitimately point at a whole family of
    # committed files instead of one literal path.
    test "the real bd-bcroux round-3 APPROVE clears the guard against round 1 + round 2's real open findings" do
      open1 =
        ReviewFindings.extract(@bcroux_round1, 1) |> Enum.filter(&ReviewFindings.blocking?/1)

      open2 =
        ReviewFindings.extract(@bcroux_round2, 2) |> Enum.filter(&ReviewFindings.blocking?/1)

      assert Enum.map(open1, & &1.id) == ["F1.1", "F1.2", "F1.3", "F1.4"]
      assert Enum.map(open2, & &1.id) == ["F2.1", "F2.2"]

      # The real files `git show --name-only` reports for the merged PR's
      # round-2 (`18eb2da9`) and round-3 (`8f0d706b`) commits — the same
      # material `record_touched_files/3` would have accumulated across those
      # two revise rounds. Verified directly against this repo's history
      # (both commits are on `main`): 11 files from `18eb2da9` plus 10 from
      # `8f0d706b`, 21 total.
      touched =
        MapSet.new([
          "apps/arbiter_web/lib/arbiter_web/components/layouts.ex",
          "apps/arbiter_web/lib/arbiter_web/live/session_dock_live.ex",
          "apps/arbiter_web/test/arbiter_web/live/session_dock_live_test.exs",
          "scripts/verify_mobile_touch.mjs",
          "docs/pr-2086-screenshots/375-dark-session-dock-maximized.png",
          "docs/pr-2086-screenshots/375-dark-worker-output.png",
          "docs/pr-2086-screenshots/375-light-session-dock-maximized.png",
          "docs/pr-2086-screenshots/375-light-worker-output.png",
          "docs/pr-2086-screenshots/414-light-session-dock-before-maximize.png",
          "docs/pr-2086-screenshots/desktop-1280-session-dock.png",
          "docs/pr-2086-screenshots/desktop-1280-worker-output.png",
          "docs/pr-2086-screenshots/after-375-dark-session-dock-maximized.png",
          "docs/pr-2086-screenshots/after-375-dark-worker-output.png",
          "docs/pr-2086-screenshots/after-375-light-session-dock-maximized.png",
          "docs/pr-2086-screenshots/after-375-light-worker-output.png",
          "docs/pr-2086-screenshots/after-414-light-session-dock-before-maximize.png",
          "docs/pr-2086-screenshots/before-375-dark-session-dock-maximized.png",
          "docs/pr-2086-screenshots/before-375-dark-worker-output.png",
          "docs/pr-2086-screenshots/before-375-light-session-dock-maximized.png",
          "docs/pr-2086-screenshots/before-375-light-worker-output.png",
          "docs/pr-2086-screenshots/before-414-light-session-dock-before-maximize.png"
        ])

      gap = ReviewFindings.approval_gap(open1 ++ open2, @bcroux_round3, touched)

      refute ReviewFindings.gap?(gap)
    end
  end

  describe "approval_gap/3 — F-id prefix collisions (bd-7urncn AC3)" do
    test "an F1.20 disposition does not satisfy the distinct open finding F1.2" do
      open = [
        %{
          id: "F1.2",
          round: 1,
          severity: :medium,
          files: ["router.ex"],
          text: "short-circuit missing"
        },
        %{
          id: "F1.20",
          round: 1,
          severity: :medium,
          files: ["other.ex"],
          text: "unrelated 20th finding"
        }
      ]

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.20 — fixed in other.ex:9
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, approve, MapSet.new(["other.ex"]))

      assert ["F1.2"] = Enum.map(gap.missing, & &1.id)
    end

    test "an F1.3 disposition does not satisfy the distinct open finding F1.30" do
      open = [
        %{id: "F1.3", round: 1, severity: :medium, files: ["a.ex"], text: "third finding"},
        %{id: "F1.30", round: 1, severity: :medium, files: ["b.ex"], text: "thirtieth finding"}
      ]

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.3 — fixed in a.ex:2
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, approve, MapSet.new(["a.ex"]))

      assert ["F1.30"] = Enum.map(gap.missing, & &1.id)
    end

    test "id-first form also keeps F1.3 and F1.30 distinct" do
      d =
        ReviewFindings.dispositions("""
        F1.30 — [ADDRESSED] fixed
        F1.3 — [NOT ADDRESSED] still open
        """)

      assert %{status: :addressed} = d["F1.30"]
      assert %{status: :not_addressed} = d["F1.3"]
    end
  end

  describe "approval_gap/3 — glob paths in a disposition line (bd-7urncn round 2 finding 1)" do
    # `files: ["missing.png"]` mirrors the real F1.2 shape: the finding itself
    # cites a placeholder file nobody would ever commit (a command target, not
    # an edit target), so the ONLY thing that can prove the disposition is the
    # glob path the disposition line itself names — `unproven?/3`'s early
    # `files: []` escape hatch must not be the reason these pass.
    test "a disposition citing only a glob path proves a finding whose committed files match it" do
      open = [
        %{
          id: "F1.1",
          round: 1,
          severity: :medium,
          files: ["missing.png"],
          text: "missing screenshots"
        }
      ]

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — screenshots are committed under `docs/shots/before-*.png` and `after-*.png`.
      VERIFICATION: FULL
      """

      touched = MapSet.new(["docs/shots/before-375-light.png", "docs/shots/after-375-light.png"])

      refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
    end

    test "a glob does not cross a directory boundary" do
      open = [
        %{
          id: "F1.1",
          round: 1,
          severity: :medium,
          files: ["missing.png"],
          text: "missing screenshots"
        }
      ]

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — screenshots are committed under `docs/shots/before-*.png`.
      VERIFICATION: FULL
      """

      # Same basename shape but in a different directory — must NOT match,
      # since `*` in a glob is scoped to one path segment.
      touched = MapSet.new(["docs/other/before-nested/375-light.png"])

      gap = ReviewFindings.approval_gap(open, approve, touched)
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end

    test "a glob disposition does not prove an unrelated file was touched" do
      open = [
        %{
          id: "F1.1",
          round: 1,
          severity: :medium,
          files: ["missing.png"],
          text: "missing screenshots"
        }
      ]

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — screenshots are committed under `docs/shots/before-*.png`.
      VERIFICATION: FULL
      """

      touched = MapSet.new(["lib/unrelated.ex"])

      gap = ReviewFindings.approval_gap(open, approve, touched)
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end
  end

  describe "approval_gap/3 — the untouched-file backstop with no seed in place (bd-7urncn)" do
    # `revise_touched_files` no longer seeds from the PR's initial
    # `base_sha..head_sha` commit (the prior round of this PR removed
    # `ReviewGate.seed_touched_files/1`). A finding whose only cited file was
    # part of that initial commit — never revisited by any revise round — must
    # still be rejected as unproven when the round-N reviewer claims it
    # `[ADDRESSED]`, exactly as bd-6r8caj/bd-8mtb0q intended: an `[ADDRESSED]`
    # claim needs a revision to actually back it, not just a citation to
    # code that has always been there.
    test "an ADDRESSED disposition citing a file only from the initial commit is still rejected" do
      open = [
        %{
          id: "F1.1",
          round: 1,
          severity: :medium,
          files: ["run_detail_live.ex"],
          text: "log_stream/1 also affects run_detail_live.ex, from the initial commit"
        }
      ]

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — disclosed in the PR body; `run_detail_live.ex` needed no change.
      VERIFICATION: FULL
      """

      # The revise round's real `git diff --name-only` output — it never
      # touched `run_detail_live.ex`, which only appeared in the PR's initial
      # commit, before round 1 ever reviewed it.
      touched = MapSet.new(["session_dock_live.ex"])

      gap = ReviewFindings.approval_gap(open, approve, touched)
      assert ["F1.1"] = Enum.map(gap.unproven, & &1.id)
    end
  end

  describe "dispositions/1 — long lines (bd-7urncn AC3)" do
    test "a very long single-line ADDRESSED disposition is still parsed" do
      long_reason =
        String.duplicate(
          "verified against the current diff and confirmed the fix landed exactly here; ",
          20
        )

      text = "- [ADDRESSED] F1.1 — #{long_reason}see router.ex:42"

      assert %{status: :addressed, line: line} = ReviewFindings.dispositions(text)["F1.1"]
      assert line == String.trim(text)
    end

    test "a long line does not stop the NEXT disposition line from parsing" do
      long_reason = String.duplicate("x", 2000)

      text = """
      - [ADDRESSED] F1.1 — #{long_reason}
      - [NOT ADDRESSED] F1.2 — still broken
      """

      d = ReviewFindings.dispositions(text)
      assert %{status: :addressed} = d["F1.1"]
      assert %{status: :not_addressed} = d["F1.2"]
    end
  end

  describe "approval_gap/3 — the bd-1xss5z deadlock shape (bd-c6tdbu)" do
    test "an honest APPROVE that marks non-blocking observations [NOT ADDRESSED] is not a gap" do
      round1 =
        """
        VERDICT: REQUEST_CHANGES
        - **Minor**: tighten the error message (a.ex:1).
        - **Minor**: rename a local var (a.ex:5).
        - **Low**: stray blank line (b.ex:2).

        Non-blocking observations (no change requested):
        - The retry loop could be simplified in a follow-up.
        - Consider extracting the duplicated setup helper.
        """

      open = ReviewFindings.extract(round1, 1)
      assert Enum.map(open, & &1.severity) == [:minor, :minor, :low, :non_blocking, :non_blocking]

      # Round 2: the Minor/Low findings need no disposition (below Medium), and
      # the reviewer honestly declines to call the non-blocking observations
      # "addressed" — exactly the bd-1xss5z transcript shape.
      round2 = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.4 — logged in round 1 as a non-blocking observation
        with no change requested, not a defect; recording it honestly rather
        than laundering it — it does not gate this approval.
      - [NOT ADDRESSED] F1.5 — also logged in round 1 as a non-blocking
        observation with no change requested.
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, round2, nil)

      refute ReviewFindings.gap?(gap),
             "a non-blocking observation marked NOT ADDRESSED must not block the approval"
    end

    test "bd-6r8caj still holds: a real Medium finding alongside a non-blocking section still gaps" do
      round1 = """
      VERDICT: REQUEST_CHANGES
      - **Medium**: `proxy_5xx?/1` over-matches (a.ex:172).

      Non-blocking observations (no change requested):
      - Consider a follow-up for the retry loop.
      """

      open = ReviewFindings.extract(round1, 1)
      assert Enum.map(open, & &1.severity) == [:medium, :non_blocking]

      # Marks the non-blocking observation honestly, but never disposition the
      # real Medium finding at all — must still gap.
      omitted = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.2 — logged as a non-blocking observation, no change requested.
      VERIFICATION: FULL
      """

      gap = ReviewFindings.approval_gap(open, omitted, nil)
      assert ["F1.1"] = Enum.map(gap.missing, & &1.id)

      # Or dispositions it but admits it is still open — also must still gap.
      not_addressed = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [NOT ADDRESSED] F1.1 — still over-matches
      - [NOT ADDRESSED] F1.2 — logged as a non-blocking observation, no change requested.
      VERIFICATION: FULL
      """

      gap2 = ReviewFindings.approval_gap(open, not_addressed, nil)
      assert ["F1.1"] = Enum.map(gap2.unaddressed, & &1.id)
    end
  end

  describe "carry_over/2" do
    test "keeps undispositioned and NOT ADDRESSED findings, drops ADDRESSED and OBSOLETE ones" do
      open =
        ReviewFindings.extract(
          """
          VERDICT: REQUEST_CHANGES
          - **High**: one (a.ex:1)
          - **High**: two (b.ex:1)
          - **High**: three (c.ex:1)
          - **High**: four (d.ex:1)
          """,
          1
        )

      text = """
      VERDICT: REQUEST_CHANGES
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — fixed
      - [OBSOLETE] F1.2 — gone
      - [NOT ADDRESSED] F1.3 — still open
      """

      assert ["F1.3", "F1.4"] = open |> ReviewFindings.carry_over(text) |> Enum.map(& &1.id)
    end
  end

  describe "prompt + persistence surfaces" do
    test "open_findings_block/2 names each id, its severity, and flags untouched cited files" do
      open =
        ReviewFindings.extract(
          "VERDICT: REQUEST_CHANGES\n- **Medium**: over-match (a/b.ex:172)",
          1
        )

      block = ReviewFindings.open_findings_block(open, MapSet.new(["a/other.ex"]))

      assert block =~ "F1.1"
      assert block =~ "medium"
      assert block =~ "a/b.ex"
      assert block =~ "NOT TOUCHED"
    end

    test "disposition_block/1 states the required syntax" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)
      block = ReviewFindings.disposition_block(open)

      assert block =~ "DISPOSITIONS:"
      assert block =~ "[ADDRESSED]"
      assert block =~ "[NOT ADDRESSED]"
      assert block =~ "[OBSOLETE]"
      assert block =~ "F1.1"
    end

    test "encode_ids/1 and encode_dispositions/2 render persistable JSON" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)

      assert ReviewFindings.encode_ids(open) == ~s(["F1.1"])
      assert ReviewFindings.encode_ids([]) == nil

      text = "DISPOSITIONS:\n- [ADDRESSED] F1.1 — done"
      assert ReviewFindings.encode_dispositions(open, text) == ~s({"F1.1":"addressed"})
      assert ReviewFindings.encode_dispositions([], text) == nil
    end

    test "prepend_disposition_banner/2 puts the banner directly under the VERDICT line" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)
      gap = ReviewFindings.approval_gap(open, "VERDICT: APPROVE\nok", nil)

      banner = ReviewFindings.prepend_disposition_banner("VERDICT: APPROVE\nok", gap)

      assert ["VERDICT: APPROVE", "", line | _] = String.split(banner, "\n")
      assert line =~ "PRIOR FINDINGS NOT ACCOUNTED FOR"
      assert banner =~ "F1.1"
    end

    test "prepend_disposition_banner/2 quotes the disposition line it DID parse for an unproven claim, " <>
           "so a coordinator can tell a parser miss from a real omission (bd-bm6bfs)" do
      open =
        ReviewFindings.extract(
          "VERDICT: REQUEST_CHANGES\n- **Medium**: x (.gitlab-ci.yml:1)",
          1
        )

      approve = """
      VERDICT: APPROVE
      DISPOSITIONS:
      - [ADDRESSED] F1.1 — `.gitlab-ci.yml:57` now includes the missing glob
      """

      # An empty touched set makes the disposition "unproven" even though the
      # parser plainly saw and parsed it — the false-park shape.
      gap = ReviewFindings.approval_gap(open, approve, MapSet.new())

      # Isolate the BANNER text itself (not the untouched findings text it
      # gets spliced next to) — the banner is what a coordinator actually
      # reads in the park message.
      banner_text = ReviewFindings.disposition_banner_text(gap, approve)

      assert banner_text =~
               "[ADDRESSED] F1.1 — `.gitlab-ci.yml:57` now includes the missing glob"
    end

    test "prepend_disposition_banner/2 says plainly when a finding has no parsed line at all" do
      open = ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n- **Medium**: x (a/b.ex:1)", 1)
      gap = ReviewFindings.approval_gap(open, "VERDICT: APPROVE\nok", nil)

      banner_text = ReviewFindings.disposition_banner_text(gap, "VERDICT: APPROVE\nok")

      assert banner_text =~ "no disposition at all"
      refute banner_text =~ "[ADDRESSED]"
    end
  end
end
