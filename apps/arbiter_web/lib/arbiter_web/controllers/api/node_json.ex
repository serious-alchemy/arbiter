defmodule ArbiterWeb.Api.NodeJSON do
  @moduledoc """
  Render functions for `Arbiter.Nodes.Node`, `JoinToken` and `NodeEvent`.
  Whitelists fields: a credential or token hash is never rendered.
  """

  alias Arbiter.Nodes.{JoinToken, Node, NodeEvent}

  def node(%Node{} = node) do
    %{
      id: node.id,
      name: node.name,
      status: node.status,
      labels: node.labels,
      max_workers: node.max_workers,
      credential_prefix: node.credential_prefix,
      enrolled_at: node.enrolled_at,
      rotated_at: node.rotated_at,
      revoked_at: node.revoked_at,
      last_seen_at: node.last_seen_at,
      join_token_id: node.join_token_id
    }
  end

  def join_token(%JoinToken{} = t) do
    %{
      id: t.id,
      name: t.name,
      labels: t.labels,
      max_workers: t.max_workers,
      expires_at: t.expires_at,
      created_by: t.created_by
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
