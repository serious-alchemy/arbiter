defmodule Arbiter.Worker.UnperformedWork do
  @moduledoc """
  Detects a research run whose own findings say it could not do the work
  (bd-8r2iat).

  On 2026-10-10 a PR-patrol CI-triage follow-up (bd-b6ct5l) ran in a podman
  sandbox with no `gh` and no `ci_*` tools, wrote "Triage NOT performed: no gh
  CLI or ci_* MCP tools in this sandbox ... Needs re-dispatch", printed
  `arb done`, and the ticket closed as completed. Non-blank notes satisfy the
  notes gate, so the follow-up was silently dropped.

  `declared?/1` reads the run's `notes` for the declarations a worker uses to
  say "I did not do this": `NOT performed`, `blocked: missing tool`, `needs
  re-dispatch`, and the like. A run that declares it parks for the coordinator
  with the reason rather than closing completed.
  """

  # Anchored to the start of a line (after optional markdown markers) so
  # analytical prose that merely mentions "not performed" or "needs redispatch"
  # mid-sentence is not a declaration; a worker states it as the line's opening.
  @patterns [
    ~r/^[ \t]*(?:[#>*_\-]+[ \t]*)?(?:triage|work|task|investigation|research)\s+(?:was\s+|is\s+)?(?:not\s+performed|could\s+not\s+be\s+(?:performed|completed|done))\b/im,
    ~r/^[ \t]*(?:[#>*_\-]+[ \t]*)?blocked\s*:\s*missing\b/im,
    ~r/^[ \t]*(?:[#>*_\-]+[ \t]*)?(?:work\s+)?needs?\s+re-?dispatch/im,
    ~r/^[ \t]*(?:[#>*_\-]+[ \t]*)?(?:unable\s+to|could\s+not|couldn't|cannot|can't)\s+(?:perform|complete|do)\s+(?:the\s+|this\s+)?(?:work|task|triage|investigation)\b/im
  ]

  @doc "True when `notes` declares the work was not (or could not be) done."
  @spec declared?(term()) :: boolean()
  def declared?(notes) when is_binary(notes), do: Enum.any?(@patterns, &Regex.match?(&1, notes))
  def declared?(_), do: false

  @doc "The first line of `notes` that makes the declaration, trimmed and clipped."
  @spec reason(String.t()) :: String.t()
  def reason(notes) when is_binary(notes) do
    notes
    |> String.split("\n")
    |> Enum.find(&declared?/1)
    |> case do
      nil -> "the run declared its work was not performed"
      line -> line |> String.trim() |> String.slice(0, 300)
    end
  end
end
