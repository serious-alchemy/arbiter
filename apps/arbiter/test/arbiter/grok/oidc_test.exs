defmodule Arbiter.Grok.OidcTest do
  # bd-9p4lx9: the OIDC refresh_token grant against a fake issuer.
  use ExUnit.Case, async: true

  alias Arbiter.Grok.Oidc

  @creds %{
    entry_key: "https://auth.x.ai::client-1",
    access_token: "old-access",
    refresh_token: "old-refresh",
    expires_at: nil,
    issuer: "https://auth.x.ai",
    client_id: "client-1"
  }

  setup context do
    name = :"oidc_#{context.test}"
    {:ok, name: name, opts: [plug: {Req.Test, name}]}
  end

  defp discovery(conn) do
    Req.Test.json(conn, %{"token_endpoint" => "https://auth.x.ai/oauth2/token"})
  end

  test "posts the refresh_token grant to the discovered endpoint", %{name: name, opts: opts} do
    test_pid = self()

    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          discovery(conn)

        "/oauth2/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:grant, URI.decode_query(body)})

          Req.Test.json(conn, %{
            "access_token" => "new-access",
            "refresh_token" => "new-refresh",
            "expires_in" => 21_600
          })
      end
    end)

    now = ~U[2030-01-01 00:00:00.000000Z]

    assert {:ok, rotated} = Oidc.refresh(@creds, now, opts)
    assert rotated.access_token == "new-access"
    assert rotated.refresh_token == "new-refresh"
    assert rotated.expires_at == DateTime.add(now, 21_600, :second)

    assert_received {:grant,
                     %{
                       "grant_type" => "refresh_token",
                       "refresh_token" => "old-refresh",
                       "client_id" => "client-1"
                     }}
  end

  test "keeps the old refresh token when the issuer does not rotate", %{name: name, opts: opts} do
    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          discovery(conn)

        _ ->
          Req.Test.json(conn, %{"access_token" => "new-access", "expires_in" => 60})
      end
    end)

    assert {:ok, %{refresh_token: "old-refresh"}} = Oidc.refresh(@creds, DateTime.utc_now(), opts)
  end

  for code <- ~w(invalid_grant invalid_client unauthorized_client) do
    test "#{code} is a permanent failure", %{name: name, opts: opts} do
      code = unquote(code)

      Req.Test.stub(name, fn conn ->
        case conn.request_path do
          "/.well-known/openid-configuration" ->
            discovery(conn)

          _ ->
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{"error" => code, "error_description" => "Invalid or unknown"})
        end
      end)

      assert {:error, {:permanent, ^code}} = Oidc.refresh(@creds, DateTime.utc_now(), opts)
    end
  end

  test "5xx, 429 and an unparseable body are transient", %{name: name, opts: opts} do
    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" -> discovery(conn)
        _ -> conn |> Plug.Conn.put_status(503) |> Plug.Conn.send_resp(503, "down")
      end
    end)

    assert {:error, {:transient, {:http, 503}}} = Oidc.refresh(@creds, DateTime.utc_now(), opts)

    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" -> discovery(conn)
        _ -> conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "slow_down"})
      end
    end)

    assert {:error, {:transient, {:http, 429}}} = Oidc.refresh(@creds, DateTime.utc_now(), opts)

    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" -> discovery(conn)
        _ -> Req.Test.json(conn, %{"unexpected" => true})
      end
    end)

    assert {:error, {:transient, :bad_response}} =
             Oidc.refresh(@creds, DateTime.utc_now(), opts)
  end

  test "a transport error is transient", %{name: name, opts: opts} do
    Req.Test.stub(name, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, {:transient, _}} = Oidc.refresh(@creds, DateTime.utc_now(), opts)
  end

  test "a token or refresh token never appears in an error", %{name: name, opts: opts} do
    Req.Test.stub(name, fn conn ->
      case conn.request_path do
        "/.well-known/openid-configuration" ->
          discovery(conn)

        _ ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => "invalid_grant", "echo" => "old-refresh"})
      end
    end)

    result = Oidc.refresh(@creds, DateTime.utc_now(), opts)
    refute inspect(result) =~ "old-refresh"
  end
end
