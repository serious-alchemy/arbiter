defmodule ArbiterCli.Cmd.Dep do
  @moduledoc """
  Dependency subcommand router:

      arb dep add  <from> <type> <to>
      arb dep add  --stdin [--json]
      arb dep rm   <from> <to> [--type T]
      arb dep list [<issue>] [--type T] [--workspace W] [--json]

  `list` with no `<issue>` lists every edge in the active workspace (see
  `arb where` / `ARB_WORKSPACE` / `--workspace`); with an `<issue>` it lists
  that issue's edges in both directions (bd-1defgu). Each row shows both
  endpoints' id, title, state and priority, so a live edge is
  distinguishable from a closed↔closed one without a second lookup.

  A `conflicts_with` edge (or any other symmetric type) is stored once,
  directed, like every other edge — `list` does not synthesize a mirrored
  second row for it: it appears exactly once in a workspace-wide listing,
  and exactly once when scoped to either one of its two endpoints.

  Edge types:

      depends_on       <from> waits until <to> has merged (verifying) or
                       closed. Gates dispatch.
      blocks           the mirror image: <to> waits on <from> the same way.
      conflicts_with   symmetric mutex — never run the two at the same time.
                       Enforced by the board scheduler (Autopilot), in either
                       edge direction. A card held by it says
                       `blocked — conflicts with bd-1c4pg3 (running)`, and
                       dispatches once the counterpart merges, closes or is
                       parked.
      parent_of        <from> is the parent (epic) of <to>. Rolls up child
                       progress; does not gate.
      relates_to       informational cross-reference; does not gate.
      discovered_from  <from> was found while working <to>; does not gate.

  A `depends_on` / `blocks` edge that would close a cycle is refused, with the
  cycle named.

  ## Bulk: `arb dep add --stdin`

  Reads many edges from standard input and adds them in one call
  (`POST /api/dependencies` with `edges`). Input is either a JSON array

      [{"from": "bd-1", "to": "bd-2", "type": "blocks"}, ...]

  (or `{"edges": [...]}`), or one `<from> <type> <to>` per line — the positional
  order of the single form; blank lines and `#` comments are skipped.

  Edges are applied in order, each through the same rules as a single `dep add`
  (an edge sees the ones before it), and each gets its own result — `ok` or
  `rejected` with the reason (a cycle, an unknown ticket, ...). A rejected edge does
  **not** undo the others; arb prints one line per edge and exits 1 if any was
  rejected. At most 200 edges per call. Wire all edges **before** promoting the
  tickets they gate. To file new tickets together with their edges atomically use
  `arb ticket create --from-file`.
  """

  alias ArbiterCli.{ArgParser, BatchFile, Client, Output, Workspace}

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {opts, rest, mode} =
        ArgParser.parse(argv,
          command: "arb dep",
          switches: [type: :string, workspace: :string, json: :boolean, stdin: :boolean]
        )

      case rest do
        ["add" | args] -> add_cmd(args, opts[:stdin] == true, mode)
        ["rm" | positional] -> rm(positional, opts, mode)
        ["remove" | positional] -> rm(positional, opts, mode)
        ["list" | positional] -> list(positional, opts, mode)
        [] -> Output.die("dep requires a subcommand: `add`, `rm` or `list`")
        [unknown | _] -> Output.die("unknown dep subcommand: #{unknown}")
      end
    end
  end

  defp add(from, type, to, mode) do
    body = %{"from_issue_id" => from, "to_issue_id" => to, "type" => type}

    case Client.post("/api/dependencies", body) do
      {:ok, dep} -> Output.emit_dependency(dep, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp add_cmd(_args, true, mode), do: add_stdin(mode)
  defp add_cmd([from, type, to | _], false, mode), do: add(from, type, to, mode)
  defp add_cmd(_args, false, _mode), do: Output.die("dep add requires: <from> <type> <to>")

  defp add_stdin(mode) do
    edges = "-" |> BatchFile.read!() |> BatchFile.edges!("stdin")

    case Client.post("/api/dependencies", %{"edges" => edges}) do
      {:ok, %{"results" => results} = response} -> emit_bulk(response, results, mode)
      {:ok, other} -> Output.die("unexpected response from the server: #{inspect(other)}")
      {:error, err} -> Output.die(err)
    end
  end

  defp emit_bulk(response, results, :json) do
    IO.puts(Jason.encode!(response))
    exit_unless_all_ok(results)
  end

  defp emit_bulk(response, results, :text) do
    Enum.each(results, &IO.puts(edge_line(&1)))
    c = response["counts"] || %{}
    IO.puts("#{c["ok"] || 0} ok, #{c["rejected"] || 0} rejected (#{c["total"] || 0} total)")
    exit_unless_all_ok(results)
  end

  defp exit_unless_all_ok(results) do
    if Enum.all?(results, &(&1["status"] == "ok")), do: :ok, else: Output.halt(1)
  end

  defp edge_line(%{"status" => "ok"} = r), do: "ok         #{edge_label(r)}"

  defp edge_line(r),
    do: "#{String.pad_trailing(r["status"] || "rejected", 10)} #{edge_label(r)}: #{r["reason"]}"

  defp edge_label(r), do: "#{r["from"]} -#{r["type"]}-> #{r["to"]}"

  defp rm(positional, opts, mode) do
    case positional do
      [from, to] ->
        params = if opts[:type], do: [type: opts[:type]], else: []

        case Client.delete("/api/dependencies/" <> from <> "/" <> to, params) do
          {:ok, body} ->
            removed = removed_count(body)

            cond do
              mode == :json -> IO.puts(Jason.encode!(%{ok: true, removed: removed}))
              removed == 0 -> IO.puts("no dependency edge: #{from} -> #{to} (nothing removed)")
              true -> IO.puts("removed #{removed} dependency edge(s): #{from} -> #{to}")
            end

          {:error, err} ->
            Output.die(err)
        end

      _ ->
        Output.die("dep rm requires: <from> <to> [--type T]")
    end
  end

  # The server answers `{removed: n}`; an older server answered 204 with no body
  # (an edge it did remove).
  defp removed_count(%{"removed" => n}) when is_integer(n), do: n
  defp removed_count(_), do: 1

  defp list(positional, opts, mode) do
    if opts[:workspace], do: System.put_env("ARB_WORKSPACE", opts[:workspace])

    case positional do
      [] -> list_workspace(opts, mode)
      [issue] -> list_issue(issue, opts, mode)
      _ -> Output.die("dep list takes at most one argument: a ticket id")
    end
  end

  defp list_workspace(opts, mode) do
    case Workspace.resolve() do
      {:ok, %{"id" => ws_id}} ->
        params = [workspace_id: ws_id] |> put_type(opts[:type])
        fetch_and_emit("/api/dependencies", params, mode)

      {:error, err} ->
        Output.die(err)
    end
  end

  defp list_issue(issue, opts, mode) do
    params = put_type([], opts[:type])
    fetch_and_emit("/api/dependencies/" <> issue, params, mode)
  end

  defp put_type(params, nil), do: params
  defp put_type(params, type), do: Keyword.put(params, :type, type)

  defp fetch_and_emit(path, params, mode) do
    case Client.get(path, params) do
      {:ok, %{"data" => deps}} -> Output.emit_dependency_list(deps, mode)
      {:error, err} -> Output.die(err)
    end
  end
end
