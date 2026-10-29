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
    * `:offered` — the slots on offer, `:max` less what the machine has derated itself by
      (bd-6w7usy, `Arbiter.Machine.Derate`): `:derate` (`:none | :soft | :hard`),
      `:derate_reason` (`"thermal 96 °C"`), `:temp_c` and `:psi` (the machine's own
      sensing; `nil` when unknown). `contributes` and placement use `:offered`.
    * `:suggested` (what the node reported), `:override` (the operator's own
      value) and `:ceiling` (what the node's owner set on the node itself, a
      hard bound the override cannot beat)

  The `local` row's suggestion is the primary's hardware suggestion
  (`Arbiter.Nodes.LocalCapacity.suggestion/0`, `NodeAgent.Protocol.suggestion/2`),
  the same formula a remote row's `suggested` comes from, and the default cap is
  enforced. Its override may be 0.

  `total` is the install's capacity, `local + Σ the caps of every available
  node` (`Arbiter.Nodes.Capacity`: an offline, lost, draining, suspect, revoked
  or unhealthy node adds 0, and so does every node while remote execution is
  off), and each node row's `:contributes` is what it added. `total` is the
  concurrency the board plans to: there is no install-wide cap above the
  machines. `warnings` names what the operator should look at: `:local_cap_zero`.
  """

  import Bitwise

  require Ash.Query

  alias Arbiter.Machine.Derate
  alias Arbiter.Nodes

  alias Arbiter.Nodes.{
    Agent,
    Capacity,
    ClusterInstall,
    Hello,
    LocalCapacity,
    Node,
    Registry,
    Session,
    Skew
  }

  alias Arbiter.Settings
  alias Arbiter.Workers.{Run, RunState}

  @default_helm_release "arbiter-node"

  @type row :: map()

  @doc "The whole overview: `%{local:, nodes:, total:, remote_execution?:, warnings:}`."
  @spec build() :: %{
          local: row(),
          nodes: [row()],
          total: non_neg_integer(),
          remote_execution?: boolean(),
          warnings: [atom()]
        }
  def build do
    snapshots = Map.new(Registry.list(), fn {_pid, id} -> {id, safe_snapshot(id)} end)
    nodes = Enum.map(Nodes.list_nodes(), &node_row(&1, Map.get(snapshots, &1.id)))
    remote_ids = snapshots |> Map.values() |> Enum.flat_map(&run_ids/1)
    local = local_row(remote_ids)
    capacity = Capacity.breakdown(nodes: nodes, local_cap: local.offered)
    contributions = Map.new(capacity.nodes, &{&1.id, &1.contributes})
    nodes = Enum.map(nodes, &Map.put(&1, :contributes, Map.fetch!(contributions, &1.id)))

    %{
      local: local,
      nodes: nodes,
      total: capacity.sum,
      remote_execution?: capacity.remote_execution?,
      warnings: warnings(local)
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
    max = Hello.effective_max_workers(node.max_workers, capacity)

    %{
      id: node.id,
      name: node.name,
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
      max: max,
      cap_source: Hello.cap_source(node.max_workers, capacity),
      suggested: positive(capacity["suggestion"]),
      override: node.max_workers,
      ceiling: positive(capacity["ceiling"]),
      workspace_ids: node.workspace_ids,
      draining?: node.status == :draining,
      allow_unenforced_network: node.allow_unenforced_network
    }
    |> Map.merge(cluster_fields(node, snapshot))
    |> Map.merge(derate_fields(max, snapshot))
  end

  # bd-6w7usy: what the machine says about itself, and the slots that leaves on offer.
  defp derate_fields(max, snapshot) do
    pressure = (snapshot && Map.get(snapshot, :pressure)) || %{}
    level = Map.get(pressure, :level, :none)

    %{
      offered: offered(max, run_ids(snapshot), level),
      derate: level,
      derate_reason: pressure[:reason],
      temp_c: pressure[:temp_c],
      psi: pressure[:psi]
    }
  end

  # The slots a machine offers the scheduler: its cap, less what it has derated itself by
  # (`Arbiter.Machine.Derate`). A node with no known cap offers none.
  defp offered(max, run_ids, level) when is_integer(max),
    do: Derate.apply_level(max, length(run_ids), level)

  defp offered(_max, _run_ids, _level), do: nil

  # A3/A7: what a cluster node adds to its row. A node that never connected, and every
  # machine, is a machine with nothing degraded, constrained or pending.
  defp cluster_fields(node, nil), do: cluster_fields(node, %{})

  defp cluster_fields(node, snapshot) do
    %{
      kind: kind(node, snapshot),
      k8s_version: Map.get(snapshot, :k8s_version),
      degraded: Map.get(snapshot, :degraded, []),
      readiness: Map.get(snapshot, :readiness, []),
      constrained?: constrained?(snapshot),
      pending: pending(snapshot)
    }
    |> Map.merge(upgrade_fields(node, snapshot))
  end

  # What the node says it is wins; a node that never connected is what its join token made it.
  defp kind(_node, %{kind: "cluster"}), do: :cluster
  defp kind(%Node{kind: "cluster"}, %{kind: nil}), do: :cluster
  defp kind(%Node{kind: "cluster"}, snapshot) when not is_map_key(snapshot, :kind), do: :cluster
  defp kind(_node, _snapshot), do: :machine

  # K9 (K§2.4): an `outdated` cluster node that cannot patch its own Deployment is shown the
  # exact `kubectl set image` for the controller image of this server's version. One that
  # reports `caps.self_upgrade` is on its way and gets none; a machine, a current node and a
  # primary with no `nodes.registry` have no command to give.
  #
  # KH8 (OD2): a node whose `caps.install.method` is `helm` is owned by Helm: self-upgrade is
  # off and it is shown `helm upgrade ...`, never `kubectl set image`.
  defp upgrade_fields(node, snapshot) do
    caps = Map.get(snapshot, :caps) || %{}
    install = install(caps)
    helm? = install["method"] == "helm"
    self_upgrade? = not helm? and caps["self_upgrade"] == true

    base = %{
      image: nil,
      upgrade_command: nil,
      self_upgrade?: self_upgrade?,
      install_method: install["method"],
      upgrade_pending_to: node.upgrade_pending_to,
      upgrade_refused: node.upgrade_refused_reason
    }

    with :cluster <- kind(node, snapshot),
         health when health in [:outdated, :ahead] <- Map.get(snapshot, :health) do
      if helm?,
        do: %{base | upgrade_command: helm_command(install, caps)},
        else: set_image_fields(base, caps, self_upgrade?)
    else
      _ -> base
    end
  end

  defp set_image_fields(base, caps, self_upgrade?) do
    case ClusterInstall.controller_image() do
      {:ok, image} ->
        command =
          if self_upgrade?,
            do: nil,
            else: ClusterInstall.set_image_command(namespace(caps), image)

        %{base | image: image, upgrade_command: command}

      _ ->
        base
    end
  end

  # The chart version is the release's, without the `v` of its tag. `nodes.chart_ref` is the
  # operator's say; the chart the node reported is the fallback.
  defp helm_command(install, caps) do
    with version when is_binary(version) <- Agent.release_tag() do
      ClusterInstall.helm_upgrade_command(
        install["release"] || @default_helm_release,
        Settings.nodes_chart_ref() || install["chart"] || ClusterInstall.chart_ref(),
        String.trim_leading(version, "v"),
        namespace(caps)
      )
    end
  end

  # A node that reports no `caps.install` (older controller) is a raw-manifest install.
  defp install(%{"install" => %{} = install}), do: Map.put_new(install, "method", "manifest")
  defp install(_caps), do: %{"method" => "manifest"}

  defp namespace(%{"namespace" => ns}) when is_binary(ns) and ns != "", do: ns
  defp namespace(_caps), do: ClusterInstall.default_namespace()

  # A3: `hb.capacity.constrained` / `.pending` (cluster nodes only; machines never send it).
  defp constrained?(%{node_capacity: %{"constrained" => true}}), do: true
  # bd-bmecet: a placement on this node was just failed over; rank it last for a while.
  defp constrained?(%{placement_stalled?: true}), do: true
  defp constrained?(_snapshot), do: false

  defp pending(%{node_capacity: %{"pending" => n}}) when is_integer(n) and n >= 0, do: n
  defp pending(_snapshot), do: 0

  defp local_row(remote_run_ids) do
    suggested = LocalCapacity.suggestion()
    override = Settings.nodes_local_max_workers()
    capacity = LocalCapacity.cap()

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
      holding: local_holding(),
      max: capacity.cap,
      offered: capacity.offered,
      derate: capacity.derate,
      derate_reason: capacity.derate_reason,
      temp_c: capacity.temp_c,
      psi: local_psi(),
      contributes: capacity.offered,
      cap_source: if(override, do: :override, else: :suggestion),
      suggested: suggested,
      override: override,
      ceiling: nil,
      workspace_ids: [],
      draining?: false
    }
  end

  defp local_psi do
    case Arbiter.Machine.Monitor.current() do
      %{psi: psi} when is_map(psi) -> Map.new(psi, fn {k, v} -> {Atom.to_string(k), v} end)
      _ -> nil
    end
  end

  # What the primary's cap counts: `LocalCapacity.holders/0`, the number admission compares to
  # `max`. Unlike `live` (every live `Run` row), it leaves out a run released while it waits on
  # CI and a primary parked behind its own review/fix sub-worker, so `live` may exceed `max`
  # while `holding` never does (short of an audited `--over-cap` override).
  defp local_holding do
    length(Arbiter.Nodes.LocalCapacity.holders())
  rescue
    _ -> nil
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

  defp warnings(local), do: if(local.max == 0, do: [:local_cap_zero], else: [])

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
