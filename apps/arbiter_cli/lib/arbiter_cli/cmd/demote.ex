defmodule ArbiterCli.Cmd.Demote do
  @moduledoc """
  `arb ticket demote <id> [<id> ...] [--stdin]` — demote tasks from Ready to Backlog.

  Wraps `POST /api/issues/:id/demote`, which runs the `:return_to_backlog` action:
  the `demote` transition (state `queued` | `active` | `merging` → `backlog`).
  Idempotent — demoting an already-backlog task is a no-op success, not an error.

  Refused if the task has a live worker, or is `verifying` or `closed`.

  Several ids (or `--stdin`, one id per line) make a bulk call
  (`POST /api/issues/demote`, at most 200 ids): one line per id (`ok` |
  `refused` | `not_found`), `--json` prints the per-id result list, and the exit
  code is 1 if any id was refused or not found.
  """

  alias ArbiterCli.{ArgParser, Bulk, Client, Output}

  @switches [json: :boolean, stdin: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {opts, rest, _mode} = ArgParser.parse(argv, command: "arb ticket demote", switches: @switches)
    mode = if opts[:json], do: :json, else: :text

    if Bulk.bulk?(rest, opts),
      do: bulk(Bulk.collect_ids(rest, opts, "demote"), mode),
      else: single(parse_id(rest), mode)
  end

  defp bulk(ids, mode) do
    case Client.post("/api/issues/demote", %{"ids" => ids}) do
      {:ok, response} -> Bulk.emit(response, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp single(id, mode) do
    case Client.post("/api/issues/" <> id <> "/demote", %{}) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(friendly_error(id, err))
    end
  end

  defp parse_id(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("demote requires a ticket id")
      _ -> Output.die("demote takes exactly one positional argument: the ticket id")
    end
  end

  defp friendly_error(_id, err), do: err
end
