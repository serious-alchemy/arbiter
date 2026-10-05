defmodule ArbiterWeb.SessionSocketCsrfTest do
  @moduledoc """
  `/session` through Phoenix's real transport `connect_info` path (bd-3gycsz).

  `Phoenix.ChannelTest.connect/3` injects `session:` and skips the CSRF check,
  which is how the browser terminal's missing `_csrf_token` went unnoticed.
  Here the session is read from a real cookie by `Transport.connect_info/4`.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Phoenix.Socket.Transport
  alias ArbiterWeb.SessionSocket

  defp connect_via_transport(cookie_conn, params) do
    {"/session", SessionSocket, opts} =
      Enum.find(ArbiterWeb.Endpoint.__sockets__(), &match?({"/session", _, _}, &1))

    config = Transport.load_config(opts[:websocket])

    conn =
      Enum.reduce(cookie_conn.resp_cookies, build_conn(), fn {k, %{value: v}}, acc ->
        Plug.Conn.put_req_header(acc, "cookie", "#{k}=#{v}")
      end)
      |> Map.put(:params, params)
      |> Map.put(:remote_ip, {127, 0, 0, 1})

    info = Transport.connect_info(conn, ArbiterWeb.Endpoint, config[:connect_info])
    SessionSocket.connect(params, %Phoenix.Socket{}, info)
  end

  defp logged_in_page do
    conn = get(dashboard_login(build_conn()), "/")
    [_, csrf] = Regex.run(~r/name="csrf-token" content="([^"]+)"/, html_response(conn, 200))
    {conn, csrf}
  end

  test "a granted session cookie with its matching _csrf_token connects" do
    {conn, csrf} = logged_in_page()
    assert {:ok, _socket} = connect_via_transport(conn, %{"_csrf_token" => csrf})
  end

  test "the same cookie without the token is refused" do
    {conn, _csrf} = logged_in_page()
    assert :error = connect_via_transport(conn, %{})
  end
end
