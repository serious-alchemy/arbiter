defmodule ArbiterCli.Cmd.SyncUpstreamClose do
  @moduledoc """
  `arb ticket sync-upstream-close <id>` — push a close to the linked tracker
  issue for a ticket that is already closed locally but whose close never
  propagated upstream. This is the remedy `arb sync` names for each `drift`
  entry.

  Wraps `POST /api/issues/:id/sync_upstream_close`. Makes no local state change:
  the ticket must already be closed and carry a tracker ref.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [json: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, _mode} =
        ArgParser.parse(argv, command: "arb ticket sync-upstream-close", switches: @switches)

      mode = if opts[:json], do: :json, else: :text

      id =
        case rest do
          [id] ->
            id

          [] ->
            Output.die("sync-upstream-close requires a ticket id")

          _ ->
            Output.die("sync-upstream-close takes exactly one positional argument: the ticket id")
        end

      case Client.post("/api/issues/" <> id <> "/sync_upstream_close", %{}) do
        {:ok, issue} -> Output.emit_issue(issue, mode)
        {:error, err} -> Output.die(err)
      end
    end
  end
end
