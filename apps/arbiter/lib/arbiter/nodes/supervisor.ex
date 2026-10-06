defmodule Arbiter.Nodes.Supervisor do
  @moduledoc """
  The primary-side node session tree (`docs/design/remote-workers.md` §3, §4.2):
  `Arbiter.Nodes.Registry` (node id → session) and the dynamic supervisor that
  owns one `Arbiter.Nodes.Session` per connected node.

  Starting it also fixes the primary's `boot_epoch` for this BEAM
  (`Arbiter.Nodes.boot_epoch/0`). One failure domain: if the tree restarts, every
  session is gone, which is exactly what a new epoch tells the agents.
  """

  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    _ = Arbiter.Nodes.boot_epoch()

    Supervisor.init(
      [
        Arbiter.Nodes.Registry,
        {DynamicSupervisor, strategy: :one_for_one, name: Arbiter.Nodes.SessionSupervisor}
      ],
      strategy: :one_for_all
    )
  end
end
