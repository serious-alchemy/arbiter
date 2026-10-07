defmodule ArbiterCli.Cmd.Rank do
  @moduledoc """
  `arb ticket rank <id> --top | --bottom | --before <id> | --after <id>
  [--pin | --unpin]` and `arb ticket rank <id> --pin | --unpin` —
  reorder a ticket inside its workspace's rank order (bd-djapyj): the space
  `board/scheduler.ex` and Autopilot dispatch read (priority, then rank,
  then age).

  Wraps `PATCH /api/issues/:id/rank`, which runs the `:set_rank` action.
  Exactly one of `--top`, `--bottom`, `--before <id>`, `--after <id>` is
  required unless `--pin`/`--unpin` is given alone. `--before`/`--after` must name a ticket in the same workspace.
  `--pin` / `--unpin` set or clear `rank_pinned` (P-15): alone they change the
  pin without moving the ticket; with a move, `--pin` pins with the move and
  `--unpin` moves then unpins. Without either, a move leaves the pin as it was.
  Never changes priority — ranking before/after a ticket in a different
  priority band only orders within rank, it does not move the ticket into
  that band.

  With `--json`, prints the updated ticket plus its zero-based position
  among tickets sharing its priority (`priority_band_position`) and the
  count of tickets in that band (`priority_band_size`).
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @switches [
    json: :boolean,
    top: :boolean,
    bottom: :boolean,
    before: :string,
    after: :string,
    pin: :boolean,
    unpin: :boolean
  ]

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      do_run(argv)
    end
  end

  defp do_run(argv) do
    {opts, rest, _mode} = ArgParser.parse(argv, command: "arb ticket rank", switches: @switches)
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
      [] -> Output.die("rank requires a ticket id")
      _ -> Output.die("rank takes exactly one positional argument: the ticket id")
    end
  end

  @usage "give exactly one of: --top, --bottom, --before <id>, --after <id> (optionally with --pin or --unpin), or --pin / --unpin alone"

  defp rank_body(opts) do
    forms =
      [
        opts[:top] && %{"top" => true},
        opts[:bottom] && %{"bottom" => true},
        opts[:before] && %{"before_id" => opts[:before]},
        opts[:after] && %{"after_id" => opts[:after]}
      ]
      |> Enum.reject(&(&1 == nil || &1 == false))

    pinned =
      case {opts[:pin], opts[:unpin]} do
        {true, true} -> Output.die("--pin and --unpin are mutually exclusive")
        {true, _} -> %{"pinned" => true}
        {_, true} -> %{"pinned" => false}
        _ -> %{}
      end

    case forms do
      [form] -> Map.merge(form, pinned)
      [] when pinned != %{} -> pinned
      _ -> Output.die(@usage)
    end
  end

  # The server reports where the ticket landed (`priority_band_position` /
  # `priority_band_size`, P-13 D-T-33) — no second, unbounded list call here.
  defp emit(issue, :json), do: Output.emit_issue(issue, :json)

  defp emit(issue, :text) do
    Output.emit_issue(issue, :text)

    IO.puts("rank: #{issue["rank"]}")

    with position when is_integer(position) <- issue["priority_band_position"],
         size when is_integer(size) <- issue["priority_band_size"] do
      IO.puts("priority band #{issue["priority"]}: position #{position + 1} of #{size}")
    end
  end
end
