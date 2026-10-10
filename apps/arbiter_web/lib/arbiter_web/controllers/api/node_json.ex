defmodule ArbiterWeb.Api.NodeJSON do
  @moduledoc """
  Render functions for `Arbiter.Nodes.Node`, `JoinToken` and `NodeEvent`.
  Whitelists fields: a credential or token hash is never rendered.
  """

  alias Arbiter.Nodes.{Credentials, JoinToken, Node, NodeEvent, PairingRequest}

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
      :max,
      :suggested,
      :override,
      :ceiling,
      :cap_source,
      :contributes,
      :k8s_version,
      :degraded,
      :readiness,
      :pending,
      :image,
      :upgrade_command
    ])
    |> Map.put(:max_workers, row.override)
    |> Map.put(:self_upgrade, Map.get(row, :self_upgrade?, false))
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
