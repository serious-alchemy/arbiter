defmodule Arbiter.Nodes.Registries do
  @moduledoc """
  SI4a (`docs/design/remote-workers.md` §21.4): the registry hosts the primary names in
  `hello_ok.registries`. A machine node's agent probes each (an unauthenticated
  `GET /v2/`: 200 or 401 is reachable) and reports `reachable` / `unreachable` per host in
  its `hb`; `Arbiter.Nodes.Placement` passes over a node that reports a repo's registry
  unreachable, and `arb server doctor` shows the result per node.

  The hosts are the install's `nodes.registry` and every registry a workspace or repo
  configures in `worker.image.registry` / `worker.repos.<repo>.image.registry`.
  """

  alias Arbiter.Nodes.Placement
  alias Arbiter.Settings

  @max_hosts 16

  @doc "The distinct registry hosts to probe, bounded."
  @spec named() :: [String.t()]
  def named do
    refs = [Settings.nodes_registry() | workspace_registries()]

    refs
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&Placement.registry_host/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_hosts)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp workspace_registries do
    Arbiter.Tasks.Workspace
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn %{config: config} ->
      worker = (config || %{})["worker"] || %{}
      repos = worker["repos"] || %{}

      [get_in(worker, ["image", "registry"])] ++
        for {_name, repo} <- repos, is_map(repo), do: get_in(repo, ["image", "registry"])
    end)
  end
end
