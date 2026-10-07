defmodule Arbiter.Nodes.Reaping do
  @moduledoc """
  What the primary sends a node so it can reap its leftovers (`docs/design/remote-workers.md`
  §10.6): `reap{install, live_set}`.

  **`live_set`** is every run id in a live `worker_runs` state (any node: a node's
  containers are labelled with the node, so a run of another node in the set is
  harmless) plus the runs the asking session itself holds. It is computed fresh for
  every request. **`install`** is `Arbiter.Nodes.InstallId`: the agent reaps only
  what carries its own node label *and* this install's id.

  **Gate:** a reap goes out only from the single primary instance
  (`Arbiter.SingleInstance.primary?/0`). A second instance (a worker running
  `mix phx.server` against a copy of the database) holds no node credentials and
  cannot reach a node at all; the gate is belt and braces, for the reason
  `Arbiter.Workers.Reconciler`'s moduledoc gives: its view of "live" is not the
  primary's. If the live set cannot be read the reap is skipped, never sent empty.

  Configuration, `config :arbiter, :node_reaper`: `enabled:` (default `true`; off in
  test) and `primary?:` (a 0-arity function, default `SingleInstance.primary?/0`).
  """

  alias Arbiter.Nodes.InstallId
  alias Arbiter.Workers.{Run, RunState}

  require Ash.Query
  require Logger

  @doc "Whether this instance may ask nodes to reap."
  @spec enabled?() :: boolean()
  def enabled? do
    config = Application.get_env(:arbiter, :node_reaper, [])

    Keyword.get(config, :enabled, true) and
      Keyword.get(config, :primary?, &Arbiter.SingleInstance.primary?/0).() == true
  end

  @doc """
  The `reap` payload for an explicit `live_set` (`Arbiter.Worker.Executor.reap/2`), or
  `nil` when reaping is off on this instance.
  """
  @spec payload([String.t()]) :: map() | nil
  def payload(live_set) when is_list(live_set) do
    if enabled?(), do: %{"install" => InstallId.get(), "live_set" => Enum.uniq(live_set)}
  end

  @doc """
  The `reap` payload, or `nil` when reaping is off here or the live set could not be
  read. `held` are run ids the asking session holds.
  """
  @spec request([String.t()]) :: map() | nil
  def request(held \\ []) do
    if enabled?() do
      case live_run_ids() do
        {:ok, ids} ->
          payload(ids ++ held)

        :error ->
          nil
      end
    end
  end

  defp live_run_ids do
    live_states = Enum.filter(RunState.states(), &RunState.live?/1)

    ids =
      Run
      |> Ash.Query.filter(state in ^live_states)
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> Enum.map(& &1.id)

    {:ok, ids}
  rescue
    e ->
      Logger.warning("nodes: live set unreadable, not reaping: #{Exception.message(e)}")
      :error
  end
end
