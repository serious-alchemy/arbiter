defmodule ArbiterWeb.Api.GrokTokenControllerTest do
  @moduledoc """
  bd-9p4lx9: `POST /api/grok/token`, the transport behind `arb grok-token` (the
  worker's `GROK_AUTH_PROVIDER_COMMAND`). A worker-tier token may call it; it
  answers `{access_token, expires_in}` and never the refresh token.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Agents.CredentialWatchdog
  alias Arbiter.Grok.CredentialBroker
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @entry_key "https://auth.x.ai::client-1"

  setup do
    dir = Path.join(System.tmp_dir!(), "gtc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "auth.json")

    File.write!(
      path,
      Jason.encode!(%{
        @entry_key => %{
          "key" => "access-secret-0",
          "auth_mode" => "oidc",
          "refresh_token" => "refresh-secret-0",
          "expires_at" => DateTime.utc_now() |> DateTime.add(6 * 3600) |> DateTime.to_iso8601(),
          "oidc_issuer" => "https://auth.x.ai",
          "oidc_client_id" => "client-1"
        }
      })
    )

    {:ok, watchdog} =
      start_supervised(%{
        id: make_ref(),
        start: {CredentialWatchdog, :start_link, [[name: nil, enabled: false, adapters: []]]}
      })

    {:ok, broker} =
      start_supervised(%{
        id: make_ref(),
        start:
          {CredentialBroker, :start_link,
           [
             [
               name: nil,
               auth_path: path,
               credential_watchdog: watchdog,
               hold_adapter: __MODULE__
             ]
           ]}
      })

    Application.put_env(:arbiter, :grok_broker_server, broker)

    on_exit(fn ->
      Application.delete_env(:arbiter, :grok_broker_server)
      File.rm_rf!(dir)
    end)

    n = System.unique_integer([:positive])
    {:ok, ws} = Ash.create(Workspace, %{name: "grok-ws-#{n}", prefix: "gw"})
    {:ok, task} = Ash.create(Issue, %{title: "a grok worker's task", workspace_id: ws.id})

    {:ok, path: path, task: task, worker_token: Scope.mint_worker(task)}
  end

  defp as_worker(token) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  test "a worker gets an access token and its lifetime, nothing more", ctx do
    resp = ctx.worker_token |> as_worker() |> post("/api/grok/token", %{}) |> json_response(200)

    assert resp["access_token"] == "access-secret-0"
    assert is_integer(resp["expires_in"]) and resp["expires_in"] > 3600
    assert Map.keys(resp) |> Enum.sort() == ["access_token", "expires_in"]
    refute Jason.encode!(resp) =~ "refresh"
  end

  test "a refine-tier token is refused", ctx do
    session = Ash.create!(Arbiter.Sessions.Session, %{cwd: "/tmp/grok-token-refine"})
    token = Scope.mint_refine(session.id, ctx.task.workspace_id, ctx.task.id)

    assert token |> as_worker() |> post("/api/grok/token", %{}) |> json_response(403)
  end

  test "a worker token whose task is not in its workspace is refused (P-28)", ctx do
    {:ok, other} = Ash.create(Workspace, %{name: "grok-other-#{ctx.task.id}", prefix: "go"})
    token = Scope.mint_worker(%{ctx.task | workspace_id: other.id})

    resp = token |> as_worker() |> post("/api/grok/token", %{}) |> json_response(403)
    refute Jason.encode!(resp) =~ "access-secret"
  end

  test "a worker token for a task that no longer exists is refused (P-28)", ctx do
    token = Scope.mint_worker(%{ctx.task | id: "bd-gone00"})

    assert token |> as_worker() |> post("/api/grok/token", %{}) |> json_response(403)
  end

  test "a coordinator token is not workspace-checked", _ctx do
    conn =
      coordinator_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> post("/api/grok/token", %{})

    assert json_response(conn, 200)["access_token"] == "access-secret-0"
  end

  test "the response is not cacheable", ctx do
    conn = ctx.worker_token |> as_worker() |> post("/api/grok/token", %{})
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "an anonymous caller is refused", _ctx do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("accept", "application/json")
      |> post("/api/grok/token", %{})

    assert json_response(conn, 401)
  end

  test "a dead login answers 503 with the remedy and no token", ctx do
    File.write!(ctx.path, "{}")

    resp = ctx.worker_token |> as_worker() |> post("/api/grok/token", %{}) |> json_response(503)

    assert resp["error"]["type"] == "grok_not_logged_in"
    assert resp["error"]["message"] =~ "grok login"
    refute Jason.encode!(resp) =~ "secret"
  end

  test "the request is logged with the asking worker's task and no token (bd-8rvkqd)", ctx do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        ctx.worker_token |> as_worker() |> post("/api/grok/token", %{}) |> json_response(200)
      end)

    assert log =~ "token request task=#{ctx.task.id} run=- force=false outcome=ok"
    refute log =~ "access-secret"
    refute log =~ "refresh-secret"
  end
end
