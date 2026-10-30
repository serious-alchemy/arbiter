defmodule Arbiter.Tasks.AcceptanceLint do
  @moduledoc """
  Filing-time lint (#1146): warns on acceptance lines whose evidence only exists
  after the merge or outside the diff (deploys, prod, CI results, operator
  action). The implementer cannot satisfy those in the diff, so the reviewer
  fails them; they belong in `deployment_notes`. Warn only — never blocks.
  """

  @patterns [
    ~r/\bafter\s+(?:the\s+)?(?:deploy(?:ment)?|merge|release|rollout)\b/i,
    ~r/\b(?:in|on)\s+(?:prod|production)\b/i,
    ~r/\bpipelines?\s+(?:shows?|logs?|results?|is\s+green|passes|pass)\b/i,
    ~r/\bpipeline\s+logs?\b/i,
    ~r/\bCI\s+(?:reports?|shows?|results?|logs?)\b/i,
    ~r/\b\d{2,}\s+(?:runs|times|iterations|consecutive)\b/i,
    ~r/\bwithin\s+\d+(?:\.\d+)?\s*%\s+(?:on|in)\s+CI\b/i,
    ~r/\boperators?\s+(?:confirms?|verifies|checks?|observes?|sees?)\b/i,
    ~r/\bdashboards?\s+(?:shows?|displays?|reports?)\b/i
  ]

  @doc "One warning per acceptance line needing post-merge or external evidence."
  @spec lint(String.t() | nil) :: [String.t()]
  def lint(acceptance) when is_binary(acceptance) do
    acceptance
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn line -> line != "" and Enum.any?(@patterns, &Regex.match?(&1, line)) end)
    |> Enum.map(fn line ->
      "Acceptance line needs post-merge or external evidence the implementer cannot " <>
        "satisfy in the diff: \"#{line}\". Consider moving it to `deployment_notes` " <>
        "(pass no_lint / --no-lint to silence this)."
    end)
  end

  def lint(_), do: []
end
