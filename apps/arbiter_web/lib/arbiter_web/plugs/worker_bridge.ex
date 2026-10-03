defmodule ArbiterWeb.Plugs.WorkerBridge do
  @moduledoc """
  Recognises a request that arrived through a jailed worker's Arbiter bridge
  and pins it to that worker (bd-c1qq7l, G9; design §2.5, §4.4).

  A bridge (`Arbiter.Worker.Egress.Forward`) dials this endpoint on host
  loopback, so by address alone its traffic is anonymous loopback, which is
  not an identity. `Arbiter.Worker.Egress.BridgeIdentity` records the bridge's
  own connections; this plug asks it about the connection `peer_data` names.

  For a bridged request it

    * assigns `:worker_bridge` (`{run_id, {:ok, %Scope{tier: :worker}} |
      {:error, reason}}`). `ArbiterWeb.Plugs.ApiAuth` and `ArbiterWeb.MCP.Plug`
      authenticate as that scope and **ignore** any `Authorization` header or
      `?token=` the client sent, so a bridge can never be used to present a
      wider token, and a run with no usable scope is refused rather than
      treated as anonymous;
    * refuses everything outside `/api` and `/mcp` with `403`: the dashboard,
      its LiveView pages, the Anthropic proxy and static files are loopback
      surfaces for the operator, not for a jailed worker.

  Every other request, which is the coordinator, the operator's shell and
  unjailed workers, has no `:worker_bridge` assign and is untouched.

  `bridged?/1` is the same question for a socket's `peer_data`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Arbiter.Worker.Egress.BridgeIdentity

  @allowed_prefixes ["api", "mcp"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    case lookup(get_peer_data(conn)) do
      :none ->
        conn

      {:bridge, run_id, resolution} ->
        conn = assign(conn, :worker_bridge, {run_id, resolution})

        if allowed_path?(conn.path_info), do: conn, else: refuse(conn)
    end
  end

  @doc "True when `peer_data` (a `Plug.Conn` or socket `connect_info` map) is a worker-bridge connection."
  @spec bridged?(map() | nil) :: boolean()
  def bridged?(%Plug.Conn{} = conn), do: Map.has_key?(conn.assigns, :worker_bridge)
  def bridged?(%{peer_data: peer}), do: lookup(peer) != :none
  def bridged?(_), do: false

  @doc "The `{run_id, resolution}` a bridged request is pinned to, else `nil`."
  @spec identity(Plug.Conn.t()) ::
          {String.t(), {:ok, Arbiter.MCP.Scope.t()} | {:error, atom()}} | nil
  def identity(%Plug.Conn{assigns: %{worker_bridge: identity}}), do: identity
  def identity(%Plug.Conn{}), do: nil

  defp lookup(%{address: address, port: port}), do: BridgeIdentity.resolve(address, port)
  defp lookup(_), do: :none

  defp allowed_path?([first | _]), do: first in @allowed_prefixes
  defp allowed_path?([]), do: false

  defp refuse(conn) do
    body =
      Jason.encode!(%{
        "error" => %{"message" => "not available to a worker through the Arbiter bridge"}
      })

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(403, body)
    |> halt()
  end
end
