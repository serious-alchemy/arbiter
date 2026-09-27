defmodule ArbiterWeb.Api.ServerControllerTest do
  @moduledoc """
  bd-1c4pg3: `arb server doctor` needs a way to ask a (possibly remote, via
  ARB_HOST) server what it's actually bound to, since the CLI has no
  filesystem/OS access of its own to inspect the listening socket.
  """
  use ArbiterWeb.ConnCase, async: true

  test "GET /api/server/bind_address reports loopback for the default 127.0.0.1 bind", %{
    conn: conn
  } do
    original = Application.get_env(:arbiter_web, ArbiterWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :ip, {127, 0, 0, 1})
    Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, Keyword.put(original, :http, http))
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, original) end)

    resp = conn |> get("/api/server/bind_address") |> json_response(200)

    assert resp["ip"] == "127.0.0.1"
    assert resp["loopback"] == true
  end

  test "GET /api/server/bind_address reports non-loopback for an overridden 0.0.0.0 bind", %{
    conn: conn
  } do
    original = Application.get_env(:arbiter_web, ArbiterWeb.Endpoint)
    http = Keyword.put(original[:http] || [], :ip, {0, 0, 0, 0})
    Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, Keyword.put(original, :http, http))
    on_exit(fn -> Application.put_env(:arbiter_web, ArbiterWeb.Endpoint, original) end)

    resp = conn |> get("/api/server/bind_address") |> json_response(200)

    assert resp["ip"] == "0.0.0.0"
    assert resp["loopback"] == false
  end

  # bd-8xy1mf: `arb server doctor` needs the host's own can-jail-agy answer
  # even when no workspace currently resolves `:strict` — this endpoint
  # exposes `Arbiter.Worker.Jail.diagnose/0` for that.
  describe "GET /api/server/agy_write_jail" do
    setup do
      prev = Application.get_env(:arbiter, :worker_jail_available)

      on_exit(fn ->
        case prev do
          nil -> Application.delete_env(:arbiter, :worker_jail_available)
          v -> Application.put_env(:arbiter, :worker_jail_available, v)
        end

        Arbiter.Worker.Jail.reset()
      end)

      :ok
    end

    test "reports available: true when the host can jail agy", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_available, true)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)

      assert resp == %{"available" => true}
    end

    test "reports available: false with cause/message/fix when it can't", %{conn: conn} do
      Application.put_env(:arbiter, :worker_jail_available, false)

      resp = conn |> get("/api/server/agy_write_jail") |> json_response(200)

      assert resp["available"] == false
      assert is_binary(resp["cause"])
      assert is_binary(resp["message"])
    end
  end
end
