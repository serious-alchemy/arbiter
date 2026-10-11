defmodule Arbiter.Machine.Hold do
  @moduledoc """
  Names the self-derated machines behind a board hold (bd-6w7usy): "held —
  ryan-oryx-pro thermal 96 °C". `Arbiter.Board.Snapshot` asks it which machines
  a workspace's placement mode could have used (`derated/2`) and, when the
  workspace's capacity is exhausted, rewrites the note with them (`note/2`).

  Options (seams for tests): `:local` (a `LocalCapacity.cap/0` map), `:nodes`
  (overview rows), `:remote_available?`.
  """

  alias Arbiter.Nodes.{LocalCapacity, Overview, Placement}

  @type derated :: %{name: String.t(), level: :soft | :hard, reason: String.t() | nil}

  @doc "The online machines a workspace in placement `mode` could run on that have derated themselves."
  @spec derated(Placement.mode(), keyword()) :: [derated()]
  def derated(mode, opts \\ []) do
    local(mode, opts) ++ nodes(mode, opts)
  end

  defp local(:remote_only, _opts), do: []

  defp local(_mode, opts) do
    cap = Keyword.get_lazy(opts, :local, &LocalCapacity.cap/0)

    case Map.get(cap, :derate, :none) do
      :none -> []
      level -> [%{name: "local", level: level, reason: Map.get(cap, :derate_reason)}]
    end
  end

  defp nodes(:local_only, _opts), do: []

  defp nodes(_mode, opts) do
    if Keyword.get_lazy(opts, :remote_available?, &Placement.remote_execution_available?/0) do
      for row <- Keyword.get_lazy(opts, :nodes, &Overview.node_rows/0),
          Map.get(row, :state) == :online,
          level = Map.get(row, :derate, :none),
          level != :none do
        %{name: Map.get(row, :name) || row.id, level: level, reason: Map.get(row, :derate_reason)}
      end
    else
      []
    end
  end

  @doc """
  `base` (a hold note, or `nil` for none) rewritten to name `derated` machines. No
  hold stays no hold: a derated machine only matters once capacity is short.
  """
  @spec note(String.t() | nil, [derated()]) :: String.t() | nil
  def note(nil, _derated), do: nil
  def note(base, []), do: base

  def note(_base, derated) do
    "held — " <>
      Enum.map_join(derated, ", ", &"#{&1.name} #{&1.reason || "derated"}") <>
      " (self-derated: no new slots until the readings stay clear; running workers continue)"
  end
end
