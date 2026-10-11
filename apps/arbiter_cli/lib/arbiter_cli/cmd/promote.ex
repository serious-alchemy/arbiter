defmodule ArbiterCli.Cmd.Promote do
  @moduledoc """
  `arb ticket promote <id> [<id> ...] [--stdin] [--waive REASON]` — promote tasks from Backlog to Ready.

  Wraps `POST /api/issues/:id/promote`, which runs the `:promote_to_ready` action:
  the `promote` transition (state `backlog` → `queued`), moving the task from
  Backlog to Ready. Idempotent — promoting an already-queued task is a no-op
  success, not an error.

  bd-7mbrlg: a `bug`/`feature`/`chore` with blank `acceptance` is refused
  unless `--waive REASON` is given (`task`/`research`/`decision`/`epic` are exempt; D0
  work is auto-waived). The reason is persisted onto the task as
  `acceptance_waived` and shown in `task show`.

  Several ids (or `--stdin`, one id per line) make a bulk call
  (`POST /api/issues/promote`, at most 200 ids; `--waive` applies to all): each
  id is promoted on its own, one line per id (`ok` | `refused` | `not_found`),
  `--json` prints the per-id result list, and the exit code is 1 if any id was
  refused or not found. One id keeps the single-id output.
  """

  alias ArbiterCli.{ArgParser, Bulk, Client, Output}

  @switches [json: :boolean, waive: :string, stdin: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {opts, rest, _mode} =
      ArgParser.parse(argv, command: "arb ticket promote", switches: @switches)

    mode = if opts[:json], do: :json, else: :text
    body = waive_body(opts[:waive])

    if Bulk.bulk?(rest, opts),
      do: bulk(Bulk.collect_ids(rest, opts, "promote"), body, mode),
      else: single(parse_id(rest), body, mode)
  end

  defp bulk(ids, body, mode) do
    case Client.post("/api/issues/promote", Map.put(body, "ids", ids)) do
      {:ok, response} -> Bulk.emit(response, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp single(id, body, mode) do
    case Client.post("/api/issues/" <> id <> "/promote", body) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(friendly_error(id, err))
    end
  end

  defp parse_id(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("promote requires a ticket id")
      _ -> Output.die("promote takes exactly one positional argument: the ticket id")
    end
  end

  defp waive_body(reason) when is_binary(reason) and reason != "",
    do: %{"acceptance_waived" => reason}

  defp waive_body(_), do: %{}

  defp friendly_error(_id, err), do: err
end
