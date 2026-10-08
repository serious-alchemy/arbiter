defmodule ArbiterCli.Cmd.Attention do
  @moduledoc """
  `arb attention` — the attention queue: every open ticket that needs someone,
  oldest first, from `GET /api/attention` (`Arbiter.Tasks.Attention.items/1`,
  the same list the `coordinator_inbox` MCP tool carries).

  Usage:

      arb attention [--owner coordinator|operator] [--workspace <id|name>] [--json]

  With no `--owner`, both owners' items are listed. With no workspace
  (`--workspace`, `-w`, `ARB_WORKSPACE`) every workspace is listed. `arb prime`'s
  Needs-attention section reads the same route.

  Line format:

      bd-1  coordinator  the run crashed [note: …]  — <title> (active, 5m ago)
  """

  alias ArbiterCli.{ArgParser, Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv,
          command: "arb attention",
          switches: [owner: :string, workspace: :string]
        )

      if rest != [],
        do: Output.die("arb attention takes no arguments (got #{Enum.join(rest, " ")})")

      params =
        []
        |> put(:owner, opts[:owner])
        |> put(:workspace, Workspace.selected_id(opts[:workspace]))

      case Client.get("/api/attention", params) do
        {:ok, body} -> if mode == :json, do: IO.puts(Jason.encode!(body)), else: print(body)
        {:error, err} -> Output.die(err)
      end
    end
  end

  defp put(params, _key, nil), do: params
  defp put(params, key, value), do: [{key, value} | params]

  defp print(body) do
    case body["attention"] || [] do
      [] ->
        IO.puts("Nothing needs attention.")

      items ->
        IO.puts("ATTENTION (#{length(items)})")
        Enum.each(items, &IO.puts("  " <> line(&1)))
    end
  end

  defp line(i) do
    note = if i["note"] in [nil, ""], do: "", else: " [note: #{i["note"]}]"
    since = if i["since"], do: ", since #{i["since"]}", else: ""

    "#{i["ticket_id"]}  #{i["owner"]}  #{i["reason"]}#{note}  — #{i["title"]} (#{i["state"]}#{since})"
  end
end
