defmodule ArbiterWeb.Api.ServerControllerTest do
  @moduledoc """
  bd-1c4pg3: `arb server doctor` needs a way to ask a (possibly remote, via
  ARB_HOST) server what it's actually bound to, since the CLI has no
  filesystem/OS access of its own to inspect the listening socket.
  """
  use ArbiterWeb.ConnCase, async: false

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

  # bd-80ecol: `arb server doctor` lists every Claude workspace that has no
  # credential of its own — the ones that used to fall into copying the
  # operator's `.credentials.json` (mode B), and whose dispatch is now held.
  describe "GET /api/server/claude_credentials" do
    setup do
      prev_flag = Application.get_env(:arbiter, :provider_accounts_enabled)

      prev_env =
        for v <- ~w(CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY),
            into: %{},
            do: {v, System.get_env(v)}

      Application.put_env(:arbiter, :provider_accounts_enabled, true)
      Enum.each(prev_env, fn {v, _} -> System.delete_env(v) end)

      on_exit(fn ->
        case prev_flag do
          nil -> Application.delete_env(:arbiter, :provider_accounts_enabled)
          v -> Application.put_env(:arbiter, :provider_accounts_enabled, v)
        end

        Enum.each(prev_env, fn
          {v, nil} -> System.delete_env(v)
          {v, val} -> System.put_env(v, val)
        end)
      end)

      :ok
    end

    test "names each Claude workspace with no setup token, with the fix", %{conn: conn} do
      {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "no-token-ws"})

      resp = conn |> get("/api/server/claude_credentials") |> json_response(200)

      assert resp["checked"] >= 1
      assert [entry] = Enum.filter(resp["missing"], &(&1["workspace_id"] == ws.id))
      assert entry["workspace"] == "no-token-ws"
      assert entry["provider"] == "claude"
      assert entry["reason"] == "no_account"
      assert entry["fix"] =~ "arb account attach #{ws.id} claude"
      assert entry["summary"] =~ "no Claude setup token"
    end
  end
end
