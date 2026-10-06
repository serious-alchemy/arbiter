defmodule ArbiterWeb.Plugs.NodeAuth do
  @moduledoc """
  Authentication for the node tier (`docs/design/remote-workers.md` §5.3, §15):
  `/nodes/*` and `/node/*`, outside `/api` and `/mcp`.

  The only credential admitted is an `arbn_<node_id>.<secret>` node credential
  in `Authorization: Bearer`, checked by `Arbiter.Nodes.authenticate/1`. It is
  **structurally separate** from `ArbiterWeb.Plugs.ApiAuth`: a node credential
  is not an `Arbiter.MCP.Scope` token, so `Scope.from_token/1` rejects it on
  every `/api` and `/mcp` route; and this plug never consults `Scope`, so a
  coordinator, operator, worker or refine token (or a join token) is just an
  unrecognised string here.

  Every failure — no header, a Scope token, a join token, a wrong secret, an
  unknown id, a revoked node — is the same `401` with the same body. There is
  no `403` and no message that tells the cases apart. The credential is read
  from the header only: a `?token=` query parameter (which ends up in logs) is
  ignored.

  On success the node is assigned to `conn.assigns[:current_node]` and the
  ambient `Arbiter.Actor` is the node (`node:<name>`), so a write made while
  serving the request is attributed to it. The actor is cleared first on every
  call: a keep-alive connection reuses one process across requests.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.Actor
  alias Arbiter.Nodes
  alias ArbiterWeb.ErrorResponse

  @message "Invalid node credential"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    Actor.put(nil)

    with {:ok, credential} <- bearer(conn),
         {:ok, node} <- Nodes.authenticate(credential) do
      Actor.put(Actor.node(node.name))
      assign(conn, :current_node, node)
    else
      _ -> unauthorized(conn)
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> credential] -> {:ok, String.trim(credential)}
      _ -> :error
    end
  end

  defp unauthorized(conn) do
    ErrorResponse.halt_with(conn, :unauthenticated, @message)
  end
end
