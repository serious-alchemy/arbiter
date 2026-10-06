defmodule ArbiterCli.Cmd.Show do
  @moduledoc """
  `arb show <id>` — display a single issue's details.

  Flags:
    --json    emit JSON instead of human-readable text
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, rest, mode} = ArgParser.parse(argv, command: "arb ticket show", switches: [])

      case rest do
        [id] -> show(id, mode)
        [] -> Output.die("show requires a ticket id (e.g. `arb show bd-abc123`)")
        _ -> Output.die("show takes exactly one argument: the ticket id")
      end
    end
  end

  defp show(id, mode) do
    case Client.get("/api/issues/" <> id) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end
end
