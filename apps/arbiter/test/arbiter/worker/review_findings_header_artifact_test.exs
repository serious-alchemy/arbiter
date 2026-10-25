defmodule Arbiter.Worker.ReviewFindingsHeaderArtifactTest do
  @moduledoc """
  bd-bkqpp3 (#989): on bd-dqlg03 a round-1 REQUEST_CHANGES led with a bare
  `FINDINGS:` section header. The parser grouped it as its own finding (F1.1:
  no file, no content), so the round-2 reviewer had to disposition a parser
  artifact and the verdict guard parked a correct APPROVE.

  The round-1 text below is a reconstruction of that review's shape (the real
  row was not available to this worker), not a verbatim copy.
  """

  use ExUnit.Case, async: true

  alias Arbiter.Worker.ReviewFindings

  @round1 """
  VERDICT: REQUEST_CHANGES

  FINDINGS:
  - [High] lib/arbiter/foo.ex:12 — the retry loop never backs off.
  - [Medium] lib/arbiter/bar.ex:40 — the timeout is not applied to the second call.
  arb done
  """

  test "a bare section header is not extracted as a finding" do
    findings = ReviewFindings.extract(@round1, 1)

    assert Enum.map(findings, & &1.id) == ["F1.1", "F1.2"]
    assert [%{files: ["lib/arbiter/foo.ex"]}, %{files: ["lib/arbiter/bar.ex"]}] = findings
    refute Enum.any?(findings, &(&1.text =~ ~r/^FINDINGS:?$/))
  end

  test "markdown-heading and bold headers are skipped too" do
    for header <- ["## Findings", "**Findings:**", "Findings:"] do
      text = "VERDICT: REQUEST_CHANGES\n\n#{header}\n1. [High] lib/a.ex:1 — broken.\n"
      assert [%{id: "F1.1", files: ["lib/a.ex"]}] = ReviewFindings.extract(text, 1)
    end
  end

  test "a body that is only a header yields no findings" do
    assert ReviewFindings.extract("VERDICT: REQUEST_CHANGES\n\nFINDINGS:\n", 1) == []
  end

  test "an APPROVE whose only non-ADDRESSED disposition is OBSOLETE for a header entry passes" do
    open = [
      %{id: "F1.1", round: 1, severity: :unknown, files: [], text: "FINDINGS:"},
      %{id: "F1.2", round: 1, severity: :high, files: ["lib/arbiter/foo.ex"], text: "x"},
      %{id: "F1.3", round: 1, severity: :medium, files: ["lib/arbiter/bar.ex"], text: "y"}
    ]

    approve = """
    VERDICT: APPROVE

    DISPOSITIONS:
    - [OBSOLETE] F1.1 — Parser artifact from round 1 capturing the section header FINDINGS:
    - [ADDRESSED] F1.2 — lib/arbiter/foo.ex now backs off.
    - [ADDRESSED] F1.3 — lib/arbiter/bar.ex applies the timeout.
    """

    touched = MapSet.new(["lib/arbiter/foo.ex", "lib/arbiter/bar.ex"])
    refute ReviewFindings.gap?(ReviewFindings.approval_gap(open, approve, touched))
  end

  test "the guard banner's blockers are summarised for the attention detail" do
    open = [%{id: "F1.2", round: 1, severity: :high, files: ["lib/a.ex"], text: "x"}]
    gap = ReviewFindings.approval_gap(open, "VERDICT: APPROVE\n", nil)
    banner = ReviewFindings.prepend_disposition_banner("VERDICT: APPROVE\n", gap)

    assert ReviewFindings.blocked_summary(banner) =~ "F1.2"
    assert ReviewFindings.blocked_summary("no banner here") == nil
  end
end
