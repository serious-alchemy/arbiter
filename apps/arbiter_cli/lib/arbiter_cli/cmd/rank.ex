defmodule ArbiterCli.Cmd.Rank do
  @moduledoc """
  `arb issue rank <id> --top | --bottom | --before <id> | --after <id>` —
  reorder a ticket inside its workspace's rank order (bd-djapyj): the space
  `board/scheduler.ex` and Autopilot dispatch read (priority, then rank,
  then age).

  Wraps `PATCH /api/issues/:id/rank`, which runs the `:set_rank` action.
  Exactly one of `--top`, `--bottom`, `--before <id>`, `--after <id>` is
  required. `--before`/`--after` must name a ticket in the same workspace.
  Never changes priority — ranking before/after a ticket in a different
  priority band only orders within rank, it does not move the ticket into
  that band.

  With `--json`, prints the updated ticket plus its zero-based position
  among tickets sharing its priority (`priority_band_position`) and the
  count of tickets in that band (`priority_band_size`).
  """

  alias ArbiterCli.{Client, Output}

  @switches [json: :boolean, top: :boolean, bottom: :boolean, before: :string, after: :string]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {opts, rest, _invalid} = OptionParser.parse(argv, switches: @switches)
    mode = if opts[:json], do: :json, else: :text
    id = parse_id(rest)
    body = rank_body(opts)

    case Client.patch("/api/issues/" <> id <> "/rank", body) do
      {:ok, issue} -> emit(issue, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp parse_id(rest) do
    case rest do
      [id] -> id
      [] -> Output.die("rank requires an issue id")
      _ -> Output.die("rank takes exactly one positional argument: the issue id")
    end
  end

  defp rank_body(opts) do
    forms =
      [
        opts[:top] && %{"top" => true},
        opts[:bottom] && %{"bottom" => true},
        opts[:before] && %{"before_id" => opts[:before]},
        opts[:after] && %{"after_id" => opts[:after]}
      ]
      |> Enum.reject(&(&1 == nil || &1 == false))

    case forms do
      [form] -> form
      [] -> Output.die("give exactly one of: --top, --bottom, --before <id>, --after <id>")
      _ -> Output.die("give exactly one of: --top, --bottom, --before <id>, --after <id>")
    end
  end

  defp emit(issue, :json) do
    {position, size} = priority_band_position(issue)

    issue
    |> Map.put("priority_band_position", position)
    |> Map.put("priority_band_size", size)
    |> Output.emit_issue(:json)
  end

  defp emit(issue, :text) do
    Output.emit_issue(issue, :text)

    {position, size} = priority_band_position(issue)
    IO.puts("rank: #{issue["rank"]}")
    IO.puts("priority band #{issue["priority"]}: position #{position + 1} of #{size}")
  end

  # Fetches every open ticket in the same workspace + priority band to report
  # where this ticket landed — matching the Ready queue order (priority, then
  # rank, then age; `board/scheduler.ex`). Best-effort: if the list call
  # fails, the rank update itself already succeeded, so we still show the
  # ticket, just without the position.
  defp priority_band_position(issue) do
    with workspace_id when is_binary(workspace_id) <- issue["workspace_id"],
         priority when is_integer(priority) <- issue["priority"],
         {:ok, %{"data" => issues}} <-
           Client.get("/api/issues", workspace_id: workspace_id, priority: priority) do
      ordered =
        issues
        |> Enum.reject(&(&1["status"] == "closed"))
        |> Enum.sort_by(&{&1["rank"], &1["created_at"]})

      position = Enum.find_index(ordered, &(&1["id"] == issue["id"])) || 0
      {position, length(ordered)}
    else
      _ -> {0, 1}
    end
  end
end
