defmodule ArbiterCli.Cmd.Epic do
  @moduledoc """
  Epic subcommand router (ES2, bd-3e7inj):

      arb epic floor <id> P1|P2|P3|none [--json]

  `floor` sets or clears an epic's priority floor
  (`docs/design/epic-aware-scheduling.md` §6.2): a ticket under the epic is
  scheduled as `min(own priority, floor)`. `none` clears it. P0 is never a
  floor, so an incident always beats one. Only an epic can carry a floor, and
  the epic's own `priority` is a separate, display-only field that this never
  changes.

  Wraps `PATCH /api/issues/:id/floor`, which runs the `:set_floor` action.
  Operator and coordinator tokens only; a worker token gets a 403.
  """

  alias ArbiterCli.{ArgParser, Client, Output}

  @usage "epic floor requires: <id> P1|P2|P3|none"

  def run(argv) do
    if Output.help?(argv) do
      IO.puts(@moduledoc)
    else
      {_opts, rest, mode} = ArgParser.parse(argv, command: "arb epic", switches: [])

      case rest do
        ["floor" | rest] -> floor(rest, mode)
        [] -> Output.die("epic requires a subcommand: `floor`")
        [unknown | _] -> Output.die("unknown epic subcommand: #{unknown}")
      end
    end
  end

  defp floor([id, value], mode) do
    floor = parse_floor(value)

    case Client.patch("/api/issues/" <> id <> "/floor", %{"floor_priority" => floor}) do
      {:ok, epic} -> emit(epic, mode)
      {:error, err} -> Output.die(err)
    end
  end

  defp floor(_args, _mode), do: Output.die(@usage)

  # Mirrors `Arbiter.Tasks.Floor.parse/1`; the server re-validates.
  defp parse_floor(value) do
    case value |> String.trim() |> String.downcase() do
      "none" -> nil
      "p" <> digit when digit in ~w(1 2 3) -> String.to_integer(digit)
      digit when digit in ~w(1 2 3) -> String.to_integer(digit)
      _ -> Output.die("floor must be P1, P2, P3 or none (P0 is never a floor)")
    end
  end

  defp emit(epic, :json), do: Output.emit_issue(epic, :json)

  defp emit(epic, :text) do
    IO.puts("#{epic["id"]} — #{epic["title"]}")
    IO.puts("floor #{label(epic["floor_priority"])}")
    IO.puts("epic priority (display only) #{label(epic["priority"])}")
  end

  defp label(nil), do: "none"
  defp label(n) when is_integer(n), do: "P#{n}"
  defp label(other), do: to_string(other)
end
