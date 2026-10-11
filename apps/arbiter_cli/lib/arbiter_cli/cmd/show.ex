defmodule ArbiterCli.Cmd.Show do
  @moduledoc """
  `arb show <id> [<id> ...]` — display issue details.

  With several ids the tickets are read in one request (the list-row shape plus
  `parent_id`, `depends_on` and `blocks`); ids that don't exist are reported
  per id on stderr (`not_found` in `--json`), not as a failure of the call.

  Flags:
    --json    emit JSON instead of human-readable text
  """

  alias ArbiterCli.{ArgParser, Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, rest, mode} = ArgParser.parse(argv, command: "arb ticket show", switches: [])

      case rest do
        [id] -> show(id, mode)
        [] -> Output.die("show requires a ticket id (e.g. `arb show bd-abc123`)")
        ids -> show_many(ids, mode)
      end
    end
  end

  defp show(id, mode) do
    case Client.get("/api/issues/" <> id) do
      {:ok, issue} -> Output.emit_issue(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp show_many(ids, mode) do
    params =
      [ids: Enum.join(ids, ","), include: "parent,deps"]
      |> Keyword.merge(workspace_param())

    case Client.get("/api/issues", params) do
      {:ok, body} -> emit_many(body, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp workspace_param do
    case Workspace.selected_id(nil) do
      nil -> []
      ws_id -> [workspace_id: ws_id]
    end
  end

  defp emit_many(body, :json) do
    IO.puts(Jason.encode!(%{data: body["data"] || [], not_found: body["not_found"] || []}))
  end

  defp emit_many(body, :text) do
    body["data"]
    |> List.wrap()
    |> Enum.map_join("\n\n", &Output.format_issue_detail/1)
    |> case do
      "" -> :ok
      text -> IO.puts(text)
    end

    case body["not_found"] do
      [_ | _] = missing -> IO.puts(:stderr, "arb: not found: " <> Enum.join(missing, ", "))
      _ -> :ok
    end
  end
end
