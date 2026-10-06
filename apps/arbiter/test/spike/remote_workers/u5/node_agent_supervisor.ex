# RW2 spike (bd-6tx1xv) U5 — NOT product code, never compiled by `mix`.
# A stand-in for the design's `Arbiter.NodeAgent.Supervisor`: the only thing the
# patched `Arbiter.Application` starts when `config :arbiter, role: :agent`.
defmodule Arbiter.NodeAgent.Supervisor do
  @moduledoc false
  use Supervisor

  def start_link(_), do: Supervisor.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_), do: Supervisor.init([Arbiter.NodeAgent.Probe], strategy: :one_for_one)
end
