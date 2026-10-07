defmodule ArbiterCli.Cmd.Close do
  @moduledoc """
  `arb close <id> [--reason ...] [--no-upstream]` — close an issue.

  If the ticket has a `tracker_ref` and a non-`:none` tracker type, the linked
  upstream tracker issue is closed as well — the server's default, so the CLI
  neither looks the ticket up first nor sends anything extra.

  `--no-upstream` leaves the upstream tracker issue open (MCP `ticket_close`
  `close_upstream: false`). Use it when the upstream issue is already closed or
  must stay open for follow-up work.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [reason: :string, upstream: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv, command: "arb ticket close", switches: @switches)

      id =
        case rest do
          [id] -> id
          [] -> Output.die("close requires a ticket id")
          _ -> Output.die("close takes exactly one positional argument: the ticket id")
        end

      body =
        %{}
        |> then(fn b -> if opts[:reason], do: Map.put(b, "reason", opts[:reason]), else: b end)
        |> then(fn b ->
          if opts[:upstream] == false, do: Map.put(b, "close_upstream", false), else: b
        end)

      case Client.post("/api/issues/" <> id <> "/close", body) do
        {:ok, issue} -> Output.emit_issue(issue, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end
end
