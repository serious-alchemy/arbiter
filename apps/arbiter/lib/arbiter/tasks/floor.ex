defmodule Arbiter.Tasks.Floor do
  @moduledoc """
  The wire form of an epic's priority floor (ES2, bd-3e7inj;
  `docs/design/epic-aware-scheduling.md` §6.2), shared by every surface that
  sets one: REST `PATCH /api/issues/:id/floor`, the `epic_floor` MCP tool and
  the epic page's control. `arb epic floor` mirrors it client-side.

  `parse/1` turns what a caller typed into the `:set_floor` action's
  `floor_priority` argument: `1`, `"1"`, `"P1"` or `"p1"` for a floor, and
  `nil`, `""` or `"none"` to clear one. P0 and anything past P3 are not
  floors, and fail here with the sentence the caller sees.
  """

  @doc "Parses a caller-supplied floor into `{:ok, 1..3 | nil}` or an error message."
  @spec parse(term()) :: {:ok, 1..3 | nil} | {:error, String.t()}
  def parse(nil), do: {:ok, nil}
  def parse(n) when n in 1..3, do: {:ok, n}

  def parse(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      clear when clear in ["", "none", "null"] -> {:ok, nil}
      "p" <> digit when digit in ~w(1 2 3) -> {:ok, String.to_integer(digit)}
      digit when digit in ~w(1 2 3) -> {:ok, String.to_integer(digit)}
      _ -> {:error, invalid_message()}
    end
  end

  def parse(_other), do: {:error, invalid_message()}

  defp invalid_message,
    do: "floor_priority must be P1, P2, P3 or none (P0 is never a floor)"
end
