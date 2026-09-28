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

  # bd-cvvb02: `:provider_accounts_enabled` ships `:auto`. An un-migrated
  # install carrying legacy credentials is held off at boot; the doctor needs
  # the server's own answer to report it (and to name any workspace a spawn
  # would raise MissingCredentialError for while accounts are on).
  describe "GET /api/server/provider_accounts" do
    setup do
      prev_flag = Application.get_env(:arbiter, :provider_accounts_enabled)
      prev_resolution = Application.get_env(:arbiter, :provider_accounts_resolution)
      prev_token = System.get_env("CLAUDE_CODE_OAUTH_TOKEN")
      System.delete_env("CLAUDE_CODE_OAUTH_TOKEN")

      on_exit(fn ->
        for {key, value} <- [
              provider_accounts_enabled: prev_flag,
              provider_accounts_resolution: prev_resolution
            ] do
          if is_nil(value),
            do: Application.delete_env(:arbiter, key),
            else: Application.put_env(:arbiter, key, value)
        end

        if prev_token, do: System.put_env("CLAUDE_CODE_OAUTH_TOKEN", prev_token)
      end)

      :ok
    end

    test "reports an auto-resolved install held off by legacy credentials", %{conn: conn} do
      {:ok, _ws} =
        Ash.create(Arbiter.Tasks.Workspace, %{
          name: "legacy-ws",
          worker_env: %{"CLAUDE_CODE_OAUTH_TOKEN" => %{"value" => "t", "secret" => true}}
        })

      Application.put_env(:arbiter, :provider_accounts_enabled, :auto)
      ExUnit.CaptureLog.capture_log(fn -> Arbiter.Accounts.Enablement.resolve() end)

      resp = conn |> get("/api/server/provider_accounts") |> json_response(200)

      assert resp["configured"] == "auto"
      assert resp["enabled"] == false
      assert resp["decision"] == "unmigrated_legacy_credentials"
      assert resp["stranded_workspaces"] == ["legacy-ws"]
      assert resp["server_env_token"] == false
      assert resp["runbook"] == "docs/provider-accounts-release-runbook.md"
    end

    test "reports an explicit setting as such", %{conn: conn} do
      Application.put_env(:arbiter, :provider_accounts_enabled, false)
      Arbiter.Accounts.Enablement.resolve()

      resp = conn |> get("/api/server/provider_accounts") |> json_response(200)

      assert resp["configured"] == "false"
      assert resp["enabled"] == false
      assert resp["decision"] == "explicit_off"
    end
  end
end
