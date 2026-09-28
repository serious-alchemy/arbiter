defmodule ArbiterCli.Cmd.Handoff do
  @moduledoc """
  `arb issue handoff <id> --note "<what you need>"` — hand a ticket's attention
  to the operator (the coordinator's hand-off; the note is required).

  `arb issue handback <id> [--note "<what changed>"]` — hand it back to the
  coordinator (the operator's answer to a hand-off or to an item promoted
  past its limit). The coordinator gets a fresh time limit and resume budget.

  Wraps `POST /api/issues/:id/handoff` and `/handback` (bd-8nlez1). The ticket
  must have attention now, not already owned by the side it is going to.
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, note: :string]

  @spec run(:operator | :coordinator, [String.t()]) :: :ok
  def run(to, argv) when to in [:operator, :coordinator] do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(to, argv)
    end
  end

  defp do_run(to, argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    verb = if to == :operator, do: "handoff", else: "handback"
    id = parse_id(rest, verb)
    note = opts[:note]

    if to == :operator and blank?(note),
      do: Output.die("handoff requires --note: say what the operator has to do")

    body = if blank?(note), do: %{}, else: %{"note" => note}

    case Client.post("/api/issues/" <> id <> "/" <> verb, body) do
      {:ok, issue} -> emit(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp parse_id([id], _verb), do: id
  defp parse_id([], verb), do: Output.die("#{verb} requires an issue id")

  defp parse_id(_, verb),
    do: Output.die("#{verb} takes exactly one positional argument: the issue id")

  defp blank?(nil), do: true
  defp blank?(s), do: String.trim(s) == ""

  defp emit(issue, :json), do: Output.emit_issue(issue, :json)

  defp emit(issue, :text) do
    Output.emit_issue(issue, :text)
    IO.puts("attention: #{issue["attention_owner"]}")
    if issue["attention_note"], do: IO.puts("note: #{issue["attention_note"]}")
    :ok
  end
end
