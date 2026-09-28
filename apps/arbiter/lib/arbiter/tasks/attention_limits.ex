defmodule Arbiter.Tasks.AttentionLimits do
  @moduledoc """
  How long the coordinator may hold a ticket's attention before it goes to the
  operator (ticket lifecycle 7/13, bd-8nlez1). Read per workspace from the
  `attention` section of its config:

  | key | default | meaning |
  |---|---|---|
  | `attention.coordinator_limit_minutes` | `240` (4 h) | a coordinator-owned item unresolved this long moves to the operator |
  | `attention.run_crashed_max_resumes` | `3` | a `run_crashed` item whose ticket was already resumed this many times out of a failed run moves to the operator |

  `0` turns a limit off. The clock runs from when the item was raised (or,
  for a derived item, first seen by `Arbiter.Tasks.AttentionSweep`), or from
  a hand-back to the coordinator if that came later.

  `workspace_config_get` reads these through `with_defaults/1`, so a
  workspace that never set them still shows the limits in force.
  """

  @section "attention"

  @defaults %{
    "coordinator_limit_minutes" => 240,
    "run_crashed_max_resumes" => 3
  }

  @type t :: %{minutes: non_neg_integer(), max_resumes: non_neg_integer()}

  @doc "The config section the limits live in."
  @spec section() :: String.t()
  def section, do: @section

  @doc "The documented defaults, keyed as in the config."
  @spec defaults() :: %{String.t() => non_neg_integer()}
  def defaults, do: @defaults

  @doc """
  `config` with the `attention` section's missing keys filled from the
  defaults — what `workspace_config_get` shows.
  """
  @spec with_defaults(map() | nil) :: map()
  def with_defaults(config) do
    config = config || %{}

    case Map.get(config, @section) do
      %{} = set -> Map.put(config, @section, Map.merge(@defaults, set))
      _ -> Map.put(config, @section, @defaults)
    end
  end

  @doc "The limits in force for `workspace` (a Workspace, a config map, or nil)."
  @spec for_workspace(map() | nil) :: t()
  def for_workspace(%{config: config}), do: for_workspace(config)

  def for_workspace(config) do
    section = config |> with_defaults() |> Map.fetch!(@section)

    %{
      minutes: count(section, "coordinator_limit_minutes"),
      max_resumes: count(section, "run_crashed_max_resumes")
    }
  end

  @doc "The limit phrase a promotion's note names, e.g. `\"4h\"` or `\"90m\"`."
  @spec describe_minutes(pos_integer()) :: String.t()
  def describe_minutes(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)}h"
  def describe_minutes(minutes), do: "#{minutes}m"

  # A set value that is not a non-negative integer (or its JSON string form)
  # falls back to the default — `ValidateConfig` refuses one on write.
  defp count(section, key) do
    case Map.get(section, key) do
      n when is_integer(n) and n >= 0 ->
        n

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> Map.fetch!(@defaults, key)
        end

      _ ->
        Map.fetch!(@defaults, key)
    end
  end
end
