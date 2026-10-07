defmodule ArbiterCli.Cmd.Ready do
  @moduledoc """
  `arb ready [--all] [--json]` — list issues ready to work on
  (`GET /api/issues/ready`).

  By default filters to the selected workspace (`-w` or `ARB_WORKSPACE`, id or
  name; a selector that matches no workspace is an error, never a widening),
  else the workspace named `default`. Pass `--all` to see ready issues
  across every workspace — useful for cross-workspace coordination but
  noisy when imported data dominates other workspaces.

  The server-side `Issue.ready/1` query is what "ready" means, and the server
  puts the result in dispatch order (the epic-aware order, so an epic's floor
  lifts its children); this command is a thin shell over it.
  """

  alias ArbiterCli.{ArgParser, Client, Output, Workspace}

  @switches [json: :boolean, all: :boolean]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, _rest, _mode} =
        ArgParser.parse(argv, command: "arb ticket ready", switches: @switches)

      mode = if opts[:json], do: :json, else: :text

      params = ready_params(opts)

      case Client.get("/api/issues/ready", params) do
        {:ok, %{"data" => issues}} -> Output.emit_issue_list(issues, mode)
        {:ok, other} -> Output.emit_issue_list(List.wrap(other), mode)
        {:error, err} -> Output.die(err)
      end
    end
  end

  # A named selector must resolve (`selected_id/0` dies otherwise); with none,
  # fall back to the default workspace as before, and widen only when there is
  # no default to fall back to.
  defp ready_params(opts) do
    cond do
      opts[:all] == true ->
        []

      id = Workspace.selected_id() ->
        [workspace_id: id]

      true ->
        case Workspace.resolve() do
          {:ok, %{"id" => id}} -> [workspace_id: id]
          {:error, _} -> []
        end
    end
  end
end
