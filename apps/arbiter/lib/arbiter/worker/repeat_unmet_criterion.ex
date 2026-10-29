defmodule Arbiter.Worker.RepeatUnmetCriterion do
  @moduledoc """
  Detects a ReviewGate rejection whose `[NOT MET]` set repeats a criterion the
  previous round already flagged `[NOT MET]` (bd-hrhkzj).

  A criterion still unmet after an implementer round means the round did not
  move it: either the evidence already exists and the reviewer disagrees, or the
  gap is not something another implementer pass will close. The fleet's
  fix-pass analysis (2026-10-29) found 14% of REQUEST_CHANGES rounds repeated
  the previous round's unmet criterion, nearly all ending in a coordinator
  accept-as-is or amend. The gate therefore parks for the coordinator with the
  repeated criterion, both reviewers' reasons and the implementer's response in
  between, rather than dispatching another round. New, different unmet criteria
  still get a normal round.

  Criteria are matched on `normalize/1`: markup (`[NOT MET]`, `[MET]`, tags),
  list markers, case and whitespace are ignored, and so is the reviewer's
  reason (everything after the first ` — `).
  """

  @marker "ReviewGate: a criterion was [NOT MET] on two consecutive rounds, so it goes to the coordinator instead of another implementer round"

  @criteria_line ~r/^\s*(?:[-*]|\d+[.)])\s*\[\s*NOT\s+MET\s*\]/i
  @list_marker ~r/^\s*(?:[-*]|\d+[.)])\s*/
  @bracket_tag ~r/\[[^\]]*\]/
  @reason_split ~r/\s+(?:—|–|--)\s+|\s+-\s+/u

  @type repeat :: %{criterion: String.t(), previous: String.t(), current: String.t()}

  @doc "The leading sentence of a repeat-unmet-criterion escalation."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "Whether `findings` is an escalation produced by this rule (prefix check)."
  @spec escalation?(String.t() | nil) :: boolean()
  def escalation?(findings) when is_binary(findings), do: String.starts_with?(findings, @marker)
  def escalation?(_), do: false

  @doc """
  Normalise a criterion line (or bare criterion text) to a comparison key:
  no list marker, no `[...]` markup, no reason suffix, lowercase, collapsed
  whitespace.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(line) when is_binary(line) do
    line
    |> String.replace(@list_marker, "")
    |> String.replace(@bracket_tag, " ")
    |> String.split(@reason_split, parts: 2)
    |> hd()
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
    |> String.trim(".:;, ")
  end

  @doc "`[{key, trimmed_line}]` for every `[NOT MET]` criteria line in `findings`."
  @spec unmet_criteria(String.t() | nil) :: [{String.t(), String.t()}]
  def unmet_criteria(findings) when is_binary(findings) do
    findings
    |> String.split("\n")
    |> Enum.filter(&Regex.match?(@criteria_line, &1))
    |> Enum.map(&{normalize(&1), String.trim(&1)})
    |> Enum.reject(fn {key, _} -> key == "" end)
  end

  def unmet_criteria(_), do: []

  @doc """
  The criteria unmet in both `previous` and `current` findings, each with the
  previous and current reviewer line.
  """
  @spec repeated(String.t() | nil, String.t() | nil) :: [repeat()]
  def repeated(previous, current) do
    prev = Map.new(unmet_criteria(previous))

    current
    |> unmet_criteria()
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, line} ->
      case Map.fetch(prev, key) do
        {:ok, prev_line} -> [%{criterion: key, previous: prev_line, current: line}]
        :error -> []
      end
    end)
  end

  @doc """
  The findings reported when the gate parks on a repeated criterion: `marker/0`,
  the criterion and both rounds' reviewer reasons, the implementer's responses
  between them, then `payload` (the usual escalation payload).
  """
  @spec escalation_findings([repeat()], String.t(), String.t()) :: String.t()
  def escalation_findings(repeats, implementer_response, payload) do
    """
    #{@marker}. No further fix round was dispatched; this needs a human.

    #{Enum.map_join(repeats, "\n\n", &render_repeat/1)}

    ## Implementer's response between the two rounds

    #{blank_to_none(implementer_response)}

    #{payload}
    """
  end

  defp render_repeat(%{criterion: c, previous: p, current: n}) do
    """
    Repeated unmet criterion: #{c}
    - Previous round reviewer: #{p}
    - This round reviewer: #{n}\
    """
  end

  defp blank_to_none(text) do
    if String.trim(text) == "", do: "(no implementer response was recorded)", else: text
  end
end
