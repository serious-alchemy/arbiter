defmodule ArbiterCli.Cmd.Verify do
  @moduledoc """
  `arb ticket verify <id> --observed "<evidence>" | --failed "<evidence>"`

  Records the post-merge restart-and-observe result for a task in state
  `verifying` (bd-9so315).

  A task flagged `verify_after_deploy` does not close when its PR merges: its
  only execution context is the long-lived server, so the merge proves nothing
  until someone restarts and looks. The task waits here until you say what you
  saw.

      arb ticket verify bd-9so315 --observed "restarted 14:02; GET /api/doctor now reports 3 repos"
      arb ticket verify bd-9so315 --failed   "after restart capture_source still reads headers"

  `--observed` closes the task. `--failed` reopens it for another attempt, with
  a fresh PR. Either way the evidence text is persisted on the task, so "this
  is live and working" is an auditable record rather than a memory.

  Wraps `POST /api/issues/:id/verify`. Several ids (or `--stdin`, one id per line;
  at most 200) make a bulk call (`POST /api/issues/verify`) with the one shared
  verdict: `--failed` reopens each id exactly as a single verify does. One line
  per id, `--json` prints the per-id list, exit 1 if any id failed.
  """

  alias ArbiterCli.{ArgParser, Bulk, Client, Output}

  @switches [observed: :string, failed: :string, stdin: :boolean, json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} =
        ArgParser.parse(argv, command: "arb ticket verify", switches: @switches)

      mode = if opts[:json], do: :json, else: :text

      bulk? = Bulk.bulk?(rest, opts)
      ids = if bulk?, do: Bulk.collect_ids(rest, opts, "verify"), else: [single_id!(rest)]
      {outcome, evidence} = verdict!(opts)
      body = %{"outcome" => outcome, "evidence" => evidence}

      if bulk?,
        do: bulk(ids, body, mode),
        else: single(hd(ids), body, mode)
    end
  end

  defp bulk(ids, body, mode) do
    case Client.post("/api/issues/verify", Map.put(body, "ids", ids)) do
      {:ok, response} -> Bulk.emit(response, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp single(id, body, mode) do
    case Client.post("/api/issues/" <> id <> "/verify", body) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp single_id!(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("verify requires a ticket id", usage_hint())
      _ -> Output.die("verify takes exactly one positional argument: the ticket id")
    end
  end

  defp verdict!(opts) do
    case {opts[:observed], opts[:failed]} do
      {nil, nil} ->
        Output.die("verify requires --observed <evidence> or --failed <evidence>", usage_hint())

      {obs, fail} when is_binary(obs) and is_binary(fail) ->
        Output.die("verify takes --observed or --failed, not both")

      {obs, nil} ->
        {"observed", obs}

      {nil, fail} ->
        {"failed", fail}
    end
  end

  defp usage_hint do
    ~s(e.g. `arb ticket verify bd-9so315 --observed "restarted; the new path fires"`)
  end
end
