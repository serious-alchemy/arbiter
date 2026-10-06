defmodule ArbiterWeb.Spike.Router do
  @moduledoc "RW2 spike: `/nodes/ping`, a header dump (U20 evidence) and a dashboard stand-in. Not product code."
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["nodes", "ping"]} = conn, _), do: send_resp(conn, 200, "pong")

  def call(%Plug.Conn{path_info: ["nodes", "headers"]} = conn, _) do
    body =
      Jason.encode!(%{
        peer: inspect(conn.remote_ip),
        request_path: conn.request_path,
        headers: Map.new(conn.req_headers)
      })

    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end

  def call(conn, _), do: send_resp(conn, 200, "dashboard")
end
