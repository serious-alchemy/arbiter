defmodule Arbiter.NodeAgent.Supervisor do
  @moduledoc """
  The only supervision tree an agent-role VM starts (`Arbiter.NodeAgent`).
  """
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
end
