defmodule ArbiterWeb.Api.NodeJSON do
  @moduledoc """
  Render functions for `Arbiter.Nodes.Node`, `JoinToken` and `NodeEvent`.
  Whitelists fields: a credential or token hash is never rendered.
  """

  alias Arbiter.Nodes.{Credentials, JoinToken, Node, NodeEvent, PairingRequest, PlacementWatch}
  alias Arbiter.Worker
  alias Arbiter.Workers.RunNode

  def node(%Node{} = node) do
    %{
      id: node.id,
      name: node.name,
      kind: node.kind,
      status: node.status,
      labels: node.labels,
      max_workers: node.max_workers,
      workspace_ids: node.workspace_ids,
      allow_unenforced_network: node.allow_unenforced_network,
      credential_prefix: node.credential_prefix,
      enrolled_at: node.enrolled_at,
      rotated_at: node.rotated_at,
      revoked_at: node.revoked_at,
      last_seen_at: node.last_seen_at,
      join_token_id: node.join_token_id
    }
  end

  @doc """
  A node as the operator sees it: the stored fields plus the live ones from
  `Arbiter.Nodes.Overview` (`state`, `health`, versions, `live`, and the cap
  breakdown `suggested` / `override` / `ceiling` / `max`, `cap_source`, which
  says whether the ceiling is what bound it, and `contributes`, what it adds to
  the install's capacity: its `max` while it is available, else 0). `max_workers` stays
  the operator's override, as before.
  """
  def node(%Node{} = node, %{} = row) do
    Map.merge(__MODULE__.node(node), overview(row))
  end

  @doc """
  The remote placements the primary has in flight (bd-cch1jh): the budget, each attempt
  (`task_id`, `node_name`, `stage`, `age_ms`) and the ones past it, which the placement
  deadline should have ended (`arb doctor` warns on those).
  """
  def placements do
    timeout = PlacementWatch.timeout_ms()
    in_flight = PlacementWatch.in_flight()

    %{
      timeout_ms: if(is_integer(timeout), do: timeout),
      in_flight: Enum.map(in_flight, &placement/1),
      stuck: stuck(in_flight, timeout)
    }
  end

  # bd-3jjt3p: the attempts past the timeout, plus every run the workers still show in
  # `placing` past it that has no such attempt (a step that hung before the attempt began).
  defp stuck(in_flight, timeout) do
    attempts = Enum.filter(in_flight, &stuck?/1)
    known = MapSet.new(in_flight, & &1.task_id)

    runs =
      Worker.list_children()
      |> PlacementWatch.stuck_runs(timeout)
      |> Enum.reject(&MapSet.member?(known, &1.task_id))
      |> Enum.map(&Map.put(&1, :node_name, RunNode.name_for(&1.node_id)))

    Enum.map(attempts ++ runs, &placement/1)
  end

  defp stuck?(%{age_ms: age, timeout_ms: ms}), do: is_integer(ms) and age >= ms

  defp placement(entry) do
    %{
      entry
      | stage: to_string(entry.stage),
        timeout_ms: if(is_integer(entry.timeout_ms), do: entry.timeout_ms)
    }
  end

  @doc "The `local` (primary) row, in the same shape as a node."
  def local(%{} = row), do: overview(row)

  defp overview(row) do
    Map.take(row, [
      :id,
      :name,
      :kind,
      :state,
      :health,
      :agent_version,
      :server_version,
      :last_heartbeat_at,
      :live,
      :holding,
      :max,
      :suggested,
      :override,
      :ceiling,
      :cap_source,
      :contributes,
      :offered,
      :derate,
      :derate_reason,
      :temp_c,
      :psi,
      :k8s_version,
      :degraded,
      :readiness,
      :allow_unenforced_network,
      :pending,
      :image,
      :upgrade_command,
      :upgrade_pending_to,
      :upgrade_refused
    ])
    |> Map.put(:max_workers, row.override)
    |> Map.put(:self_upgrade, Map.get(row, :self_upgrade?, false))
    |> Map.put(:registries, get_in(row, [:caps, "registries"]) || [])
    |> put_constrained(row)
  end

  # A3: `hb.capacity.constrained`, for cluster nodes (the `local` row has none).
  defp put_constrained(map, %{constrained?: constrained?}),
    do: Map.put(map, :constrained, constrained?)

  defp put_constrained(map, _row), do: map

  def join_token(%JoinToken{} = t) do
    %{
      id: t.id,
      name: t.name,
      labels: t.labels,
      max_workers: t.max_workers,
      kind: t.kind,
      expires_at: t.expires_at,
      created_by: t.created_by
    }
  end

  @doc """
  A pairing request as the operator sees it. The poll secret hash is never
  rendered; the `code` is the typed form (`XXXX-XXXX`).
  """
  def pairing(%PairingRequest{} = r) do
    %{
      id: r.id,
      code: Credentials.format_pairing_code(r.code),
      state: r.state,
      hostname: r.hostname,
      peer: r.peer,
      name: r.name,
      labels: r.labels,
      max_workers: r.max_workers,
      expires_at: r.expires_at,
      approved_by: r.approved_by,
      inserted_at: r.inserted_at
    }
  end

  def event(%NodeEvent{} = e) do
    %{
      id: e.id,
      node_id: e.node_id,
      kind: e.kind,
      actor: e.actor,
      detail: e.detail,
      remote_addr_hint: e.remote_addr_hint,
      at: e.at
    }
  end
end
