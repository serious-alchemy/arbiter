defmodule ArbiterCli.Cmd.Close do
  @moduledoc """
  `arb close <id> [--reason ...] [--no-upstream]` — close an issue.

  If the ticket has a `tracker_ref` and a non-`:none` tracker type, the linked
  upstream tracker issue is closed as well — the server's default, so the CLI
  neither looks the ticket up first nor sends anything extra.

  Several ids (or `--stdin`, one id per line; at most 200) make a bulk call
  (`POST /api/issues/close`): the same `--reason` / `--no-upstream` apply to each
  id, one line per id (`ok` | `refused` | `not_found`), `--json` prints the
  per-id result list, and the exit code is 1 if any id failed.

  `--no-upstream` leaves the upstream tracker issue open (MCP `ticket_close`
  `close_upstream: false`). Use it when the upstream issue is already closed or
  must stay open for follow-up work.
  """

  alias ArbiterCli.{ArgParser, Bulk, Client, Output}

  @switches [reason: :string, upstream: :boolean, stdin: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv, command: "arb ticket close", switches: @switches)

      body =
        %{}
        |> then(fn b -> if opts[:reason], do: Map.put(b, "reason", opts[:reason]), else: b end)
        |> then(fn b ->
          if opts[:upstream] == false, do: Map.put(b, "close_upstream", false), else: b
        end)

      if Bulk.bulk?(rest, opts),
        do: bulk(Bulk.collect_ids(rest, opts, "close"), body, mode),
        else: single(single_id!(rest), body, mode)
    end
  end

  defp bulk(ids, body, mode) do
    case Client.post("/api/issues/close", Map.put(body, "ids", ids)) do
      {:ok, response} -> Bulk.emit(response, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp single(id, body, mode) do
    case Client.post("/api/issues/" <> id <> "/close", body) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp single_id!(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("close requires a ticket id")
      _ -> Output.die("close takes exactly one positional argument: the ticket id")
    end
  end
end
