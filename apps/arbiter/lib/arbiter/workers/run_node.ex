defmodule Arbiter.Workers.RunNode do
  @moduledoc """
  Where a run executes — the one reading every surface shares (the dashboard,
  `arb`, REST and MCP).

  A run's `node_id` names the remote node it was placed on
  (`Arbiter.Nodes.Placement`); `nil` is the primary. It rides on a live
  worker snapshot (`:node_id`), on a `Arbiter.Workers.Run` row, and on the
  `Arbiter.Workers.Current` view built from either.

  The serialized form is `%{node_id:, node_name:}`, both `nil` for a local run.
  Display code uses `label/1` (the node name, or `"local"`) where there is
  room and `remote?/1` where only local/remote fits.
  """

  alias Arbiter.Nodes
  alias Arbiter.Workers.Run

  @type source :: map() | Run.t() | nil

  @doc "The node id a run view, snapshot or row was placed on; `nil` for the primary."
  @spec node_id(source()) :: String.t() | nil
  def node_id(%Run{node_id: id}), do: id
  def node_id(%{node_id: id}) when is_binary(id), do: id
  def node_id(%{run: %Run{node_id: id}}), do: id
  def node_id(%{meta: %{node_id: id}}) when is_binary(id), do: id
  def node_id(_), do: nil

  @doc "True when the run executes on a remote node."
  @spec remote?(source()) :: boolean()
  def remote?(source), do: not is_nil(node_id(source))

  @doc "The node's name; `nil` for a local run. A vanished node falls back to its id."
  @spec node_name(source()) :: String.t() | nil
  def node_name(source) do
    case node_id(source) do
      nil -> nil
      id -> name_for(id)
    end
  end

  @doc "The node name, or `\"local\"` for a run on the primary."
  @spec label(source()) :: String.t()
  def label(source), do: node_name(source) || Nodes.local_name()

  @doc "`%{node_id:, node_name:}` — both `nil` for a local run."
  @spec fields(source()) :: %{node_id: String.t() | nil, node_name: String.t() | nil}
  def fields(source) do
    id = node_id(source)
    %{node_id: id, node_name: id && name_for(id)}
  end

  defp name_for(id) do
    case Nodes.get_node(id) do
      %{name: name} -> name
      _ -> id
    end
  rescue
    _ -> id
  end
end
