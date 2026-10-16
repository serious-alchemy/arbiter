defmodule Arbiter.Tasks.TrackerAcceptance do
  @moduledoc """
  Derives a claimed tracker issue's `acceptance` (or an explicit waiver) so
  tracker-sourced tickets can be promoted without a manual `acceptance_waived`.

  Precedence, first hit wins:

    1. the tracker's own task/checklist items (adapter's optional
       `extract_checklist/1`, e.g. Shortcut story tasks) plus Markdown
       checkboxes (`- [ ] item`) in the description → a checklist;
    2. a recognised section in the description (`Acceptance`, `Done when`,
       `Fix`, `Expected`) → that section's text;
    3. otherwise `{:waived, Issue.tracker_spec_waiver()}` — the description is
       the spec, and ReviewGate reviews against it.
  """

  alias Arbiter.Tasks.Issue

  @labels [
    "acceptance criteria",
    "acceptance",
    "done when",
    "fix",
    "expected behaviou?r",
    "expected"
  ]
  @label_re Enum.join(@labels, "|")

  # `## Acceptance`, `**Done when:**`, `Fix:` etc. on its own line; any text
  # after the colon on the same line is the first line of the section body.
  @label_line ~r/^\s{0,3}(?:\#{1,6}\s*)?(?:\*\*|__)?\s*(?:#{@label_re})\s*:?\s*(?:\*\*|__)?\s*:?\s*(.*)$/iu
  @heading ~r/^\s{0,3}(?:\#{1,6}\s|(?:\*\*|__)[^*_]+(?:\*\*|__):?\s*$)/u
  @checkbox ~r/^\s*[-*+]\s+\[[ xX]\]\s+(.+?)\s*$/u

  @spec derive(module(), map()) :: {:acceptance, String.t()} | {:waived, String.t()}
  def derive(adapter, issue_map) do
    description = adapter.extract_description(issue_map)

    case checklist(adapter, issue_map, description) do
      [_ | _] = items ->
        {:acceptance, Enum.map_join(items, "\n", &"- [ ] #{&1}")}

      [] ->
        case section(description) do
          nil -> {:waived, Issue.tracker_spec_waiver()}
          text -> {:acceptance, text}
        end
    end
  end

  defp checklist(adapter, issue_map, description) do
    native =
      if function_exported?(adapter, :extract_checklist, 1),
        do: adapter.extract_checklist(issue_map),
        else: []

    (native ++ checkboxes(description))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp checkboxes(description) when is_binary(description) do
    description
    |> String.split(~r/\R/)
    |> Enum.flat_map(fn line ->
      case Regex.run(@checkbox, line) do
        [_, item] -> [item]
        _ -> []
      end
    end)
  end

  defp checkboxes(_), do: []

  defp section(description) when is_binary(description) do
    lines = String.split(description, ~r/\R/)

    lines
    |> Enum.with_index()
    |> Enum.find_value(fn {line, idx} ->
      case Regex.run(@label_line, line) do
        [_, rest] -> collect(rest, Enum.drop(lines, idx + 1))
        _ -> nil
      end
    end)
  end

  defp section(_), do: nil

  defp collect(rest, following) do
    body = Enum.take_while(following, &(not Regex.match?(@heading, &1)))

    text =
      [rest | body]
      |> Enum.join("\n")
      |> String.trim()

    if text == "", do: nil, else: text
  end
end
