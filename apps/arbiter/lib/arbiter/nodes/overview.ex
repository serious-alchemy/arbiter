defmodule Arbiter.Nodes.Overview do
  @moduledoc """
  The operator's view of the fleet (`docs/design/remote-workers.md` §13, §14):
  one row per node plus the primary as a `local` row, with the capacity sums
  the nodes page, `GET /api/nodes` and `arb server doctor` all read.

  A row is a plain map:

    * `:id`, `:name`, `:kind` (`:local | :machine | :cluster`), `:labels`, `:status`
    * `:state` — `:online | :suspect | :offline | :draining | :revoked`
      (online is a property of the live `Arbiter.Nodes.Session`, not stored)
    * `:health`, `:agent_version`, `:server_version`, `:last_heartbeat_at`
    * `:live` runs and `:max`, the **effective** cap
    * `:suggested` (what the node reported), `:override` (the operator's own
      value) and `:ceiling` (what the node's owner set on the node itself, a
      hard bound the override cannot beat)

  The `local` row's suggestion is the install's own local concurrency
  (`Arbiter.Board.Snapshot.system_max_concurrent/0`), so an install that never
  overrides it behaves as before. Its override may be 0.

  `total` is the install's capacity, `local + Σ the caps of every available
  node` (`Arbiter.Nodes.Capacity`: an offline, lost, draining, suspect, revoked
  or unhealthy node adds 0, and so does every node while remote execution is
  off), and each node row's `:contributes` is what it added. `ceiling` is the
  operator's `conductor.max_concurrent` when set and `nil` when not, and
  `effective` is `min(total, ceiling)`, the concurrency the board plans to. The
  ceiling is never derived from node caps. `warnings` names what the operator
  should look at: `:local_cap_zero`, and `:ceiling_below_total` only while an
  explicit ceiling cuts the sum.
  """

  import Bitwise

  require Ash.Query

  alias Arbiter.Board.Snapshot, as: Board
  alias Arbiter.Nodes
  alias Arbiter.Nodes.{Capacity, Hello, Node, Registry, Session, Skew}
  alias Arbiter.Settings
  alias Arbiter.Workers.{Run, RunState}

  @type row :: map()

  @doc "The whole overview: `%{local:, nodes:, total:, effective:, ceiling:, remote_execution?:, warnings:}`."
  @spec build() :: %{
          local: row(),
          nodes: [row()],
          total: non_neg_integer(),
          effective: non_neg_integer(),
          ceiling: pos_integer() | nil,
          remote_execution?: boolean(),
          warnings: [atom()]
        }
  def build do
    snapshots = Map.new(Registry.list(), fn {_pid, id} -> {id, safe_snapshot(id)} end)
    nodes = Enum.map(Nodes.list_nodes(), &node_row(&1, Map.get(snapshots, &1.id)))
    remote_ids = snapshots |> Map.values() |> Enum.flat_map(&run_ids/1)
    local = local_row(remote_ids)
    capacity = Capacity.breakdown(nodes: nodes, local_cap: local.max)
    contributions = Map.new(capacity.nodes, &{&1.id, &1.contributes})
    nodes = Enum.map(nodes, &Map.put(&1, :contributes, Map.fetch!(contributions, &1.id)))

    %{
      local: local,
      nodes: nodes,
      total: capacity.sum,
      effective: capacity.effective,
      ceiling: capacity.ceiling,
      remote_execution?: capacity.remote_execution?,
      warnings: warnings(local, capacity)
    }
  end

  @doc """
  The remote node rows alone (what `Arbiter.Nodes.Placement` picks among), each
  with its live run count and effective cap.
  """
  @spec node_rows() :: [row()]
  def node_rows do
    snapshots = Map.new(Registry.list(), fn {_pid, id} -> {id, safe_snapshot(id)} end)
    Enum.map(Nodes.list_nodes(), &node_row(&1, Map.get(snapshots, &1.id)))
  end

  @doc "The row for one node, by id, or `nil`."
  @spec get(String.t()) :: row() | nil
  def get(id) do
    case Nodes.get_node(id) do
      nil -> nil
      %Node{} = node -> node_row(node, safe_snapshot(id))
    end
  end

  @doc """
  The node a run is on: the one whose live session holds the run id. `nil` for a
  run on the primary, or on a node that is not connected.
  """
  @spec node_for_run(String.t() | nil) :: row() | nil
  def node_for_run(run_id) when is_binary(run_id) do
    Enum.find_value(Registry.list(), fn {_pid, id} ->
      snapshot = safe_snapshot(id)

      if run_id in run_ids(snapshot), do: get(id)
    end)
  end

  def node_for_run(_), do: nil

  # ---- rows ------------------------------------------------------------------

  defp node_row(%Node{} = node, snapshot) do
    capacity = (snapshot && snapshot.capacity) || %{}

    %{
      id: node.id,
      name: node.name,
      kind: kind(snapshot),
      k8s_version: snapshot && snapshot.k8s_version,
      degraded: (snapshot && snapshot.degraded) || [],
      constrained?: constrained?(snapshot),
      pending: pending(snapshot),
      allow_unenforced_network: node.allow_unenforced_network,
      labels: node.labels,
      status: node.status,
      state: state(node, snapshot),
      health: snapshot && snapshot.health,
      agent_version: snapshot && snapshot.agent_version,
      server_version: Skew.primary().version,
      last_heartbeat_at: last_heartbeat(node, snapshot),
      live: length(run_ids(snapshot)),
      run_ids: run_ids(snapshot),
      proto: snapshot && snapshot.proto,
      caps: (snapshot && snapshot.caps) || %{},
      capacity: capacity,
      max: Hello.effective_max_workers(node.max_workers, capacity),
      cap_source: Hello.cap_source(node.max_workers, capacity),
      suggested: positive(capacity["suggestion"]),
      override: node.max_workers,
      ceiling: positive(capacity["ceiling"]),
      workspace_ids: node.workspace_ids,
      draining?: node.status == :draining
    }
  end

  defp kind(%{kind: "cluster"}), do: :cluster
  defp kind(_snapshot), do: :machine

  # A3: `hb.capacity.constrained` / `.pending` (cluster nodes only; machines never send it).
  defp constrained?(%{node_capacity: %{"constrained" => true}}), do: true
  defp constrained?(_snapshot), do: false

  defp pending(%{node_capacity: %{"pending" => n}}) when is_integer(n) and n >= 0, do: n
  defp pending(_snapshot), do: 0

  defp local_row(remote_run_ids) do
    suggested = Board.system_max_concurrent()
    override = Settings.nodes_local_max_workers()

    %{
      id: Nodes.local_name(),
      name: Nodes.local_name(),
      kind: :local,
      labels: [],
      status: :active,
      state: :online,
      health: :ready,
      agent_version: Skew.primary().version,
      server_version: Skew.primary().version,
      last_heartbeat_at: nil,
      live: local_live(remote_run_ids),
      max: override || suggested,
      contributes: override || suggested,
      cap_source: if(override, do: :override, else: :suggestion),
      suggested: suggested,
      override: override,
      ceiling: nil,
      workspace_ids: [],
      draining?: false
    }
  end

  # Live runs the primary itself holds: every live `Run` row that no node's
  # session reports.
  defp local_live(remote_run_ids) do
    states = Enum.filter(RunState.states(), &RunState.live?/1)

    Run
    |> Ash.Query.filter(state in ^states)
    |> Ash.Query.select([:id])
    |> Ash.read!()
    |> Enum.count(&(&1.id not in remote_run_ids))
  end

  defp state(%Node{status: :revoked}, _), do: :revoked
  defp state(%Node{status: :draining}, _), do: :draining
  defp state(_node, nil), do: :offline
  defp state(_node, %{connected?: false}), do: :offline
  defp state(_node, %{state: state}), do: state

  defp last_heartbeat(node, nil), do: node.last_seen_at

  defp last_heartbeat(_node, %{silence_ms: ms}),
    do: DateTime.add(DateTime.utc_now(), -ms, :millisecond)

  defp run_ids(nil), do: []
  defp run_ids(%{runs: runs}), do: Map.keys(runs)

  defp safe_snapshot(id) do
    Session.snapshot(id)
  catch
    :exit, _ -> nil
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  # ---- warnings --------------------------------------------------------------

  defp warnings(local, capacity) do
    Enum.filter(
      [local.max == 0 && :local_cap_zero, capacity.ceiling_cuts? && :ceiling_below_total],
      & &1
    )
  end

  # ---- exposure (§4.3) -------------------------------------------------------

  @doc """
  Whether the configured `nodes.public_url` is a private path: `:private` for a
  tailnet name (`*.ts.net`), `localhost`, or an address in loopback, RFC 1918,
  CGNAT (100.64/10) or ULA (fc00::/7) space; `:public` for anything else (a
  public DNS name or address, which is how `tailscale funnel` or a port-forward
  looks); `:unset` for no URL. A heuristic: it cannot see a reverse proxy.
  """
  @spec exposure(String.t() | nil) :: :private | :public | :unset
  def exposure(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) and host != "" -> host_exposure(host)
      _ -> :unset
    end
  end

  def exposure(_), do: :unset

  defp host_exposure(host) do
    host = host |> String.trim_leading("[") |> String.trim_trailing("]") |> String.downcase()

    if host == "localhost" or String.ends_with?(host, ".ts.net"),
      do: :private,
      else: ip_exposure(host)
  end

  defp ip_exposure(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> if private_ip?(ip), do: :private, else: :public
      {:error, _} -> :public
    end
  end

  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({172, b, _, _}) when b in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({100, b, _, _}) when b in 64..127, do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({a, _, _, _, _, _, _, _}) when (a &&& 0xFE00) == 0xFC00, do: true
  defp private_ip?(_), do: false
end
