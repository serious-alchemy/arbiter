defmodule ArbiterWeb.Api.AttentionController do
  @moduledoc """
  `GET /api/attention?owner=&workspace=` — the attention queue: every open
  ticket with attention, oldest first (`Arbiter.Tasks.Attention.items/1`, the
  same read as the `coordinator_inbox` MCP tool's `attention` list).

    * `owner` — `coordinator` or `operator`; omitted, both;
    * `workspace` / `workspace_id` — id or name; omitted, every workspace
      (`workspace_id: null` in the response).

  `arb attention` and `arb prime`'s Needs-attention section read this.
  """

  use ArbiterWeb, :controller

  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Attention
  alias ArbiterWeb.Api.WorkspaceParam

  action_fallback(ArbiterWeb.Api.FallbackController)

  def index(conn, params) do
    with {:ok, owner} <- parse_owner(params["owner"]),
         {:ok, ws_id} <- WorkspaceParam.resolve(conn, params, :read) do
      items =
        [workspace_id: ws_id, owner: owner]
        |> Attention.items()
        |> Enum.map(&Tools.serialize_attention_item/1)

      json(conn, %{attention: items, attention_count: length(items), workspace_id: ws_id})
    end
  end

  defp parse_owner(nil), do: {:ok, nil}
  defp parse_owner(""), do: {:ok, nil}
  defp parse_owner("coordinator"), do: {:ok, :coordinator}
  defp parse_owner("operator"), do: {:ok, :operator}

  defp parse_owner(other),
    do: {:error, {:invalid, "owner must be coordinator or operator, got #{inspect(other)}"}}
end
