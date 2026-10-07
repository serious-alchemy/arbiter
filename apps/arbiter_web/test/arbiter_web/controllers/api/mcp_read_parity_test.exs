defmodule ArbiterWeb.Api.McpReadParityTest do
  @moduledoc """
  P-17 acceptance 2: the MCP read tools reuse the REST serializers, so what a
  coordinator reads over MCP is what `arb` reads over REST — compared here
  body for body, after a JSON round trip.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Accounts
  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.MCP.{Catalog, Scope}
  alias Arbiter.Providers.Pause
  alias Arbiter.Usage.Event

  @coordinator %Scope{tier: :coordinator, workspace_id: nil}
  @secret "sk-parity-secret-value-9876"

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  # What a client sees: the MCP result as JSON.
  defp mcp(tool, args \\ %{}) do
    assert {:ok, result} = Catalog.call(@coordinator, tool, args)
    result |> Jason.encode!() |> Jason.decode!()
  end

  defp account!(provider, slug) do
    {:ok, account} = Ash.create(ProviderAccount, %{provider: provider, slug: slug})
    account
  end

  test "account_list / account_show render the REST account bodies", %{conn: conn} do
    account = account!(:claude, "parity-acct")

    {:ok, _} =
      Accounts.rotate_credential(account.id, %{
        kind: :oauth_token,
        env_var: "CLAUDE_CODE_OAUTH_TOKEN",
        secret: @secret
      })

    rest_list = conn |> get(~p"/api/accounts") |> json_response(200)
    assert %{"accounts" => accounts} = mcp("account_list")
    assert accounts == rest_list["data"]

    rest_show = conn |> get(~p"/api/accounts/parity-acct") |> json_response(200)
    mcp_show = mcp("account_show", %{"ref" => "parity-acct"})
    assert mcp_show == rest_show

    # Credential kind + fingerprint prefix only; the secret never appears.
    assert [%{"fingerprint" => fingerprint}] = mcp_show["credentials"]
    assert String.length(fingerprint) <= 12
    refute Jason.encode!(mcp_show) =~ @secret
  end

  test "provider_list renders the REST paused body", %{conn: conn} do
    {:ok, _} = Pause.pause("codex", reason: "parity", by: "mcp")

    rest = conn |> get(~p"/api/providers/paused") |> json_response(200)
    assert mcp("provider_list") == rest
  end

  test "usage_events_list renders the REST events body", %{conn: conn} do
    {:ok, ws} = Ash.create(Arbiter.Tasks.Workspace, %{name: "parity-ws", prefix: "pty"})

    {:ok, _} =
      Ash.create(Event, %{
        task_id: "bd-parity",
        repo: "arbiter",
        workspace_id: ws.id,
        step: :work,
        cost_usd: 1.25,
        tokens_in: 10,
        occurred_at: DateTime.utc_now()
      })

    rest = conn |> get(~p"/api/usage/events", %{workspace: ws.id}) |> json_response(200)

    assert %{"events" => events, "workspace_id" => ws_id} =
             mcp("usage_events_list", %{"workspace" => ws.id})

    assert events == rest["data"]
    assert ws_id == rest["workspace_id"]
    assert [%{"task_id" => "bd-parity"}] = events
  end

  test "usage_calibration renders the REST calibration body", %{conn: conn} do
    rest = conn |> get(~p"/api/usage/calibration") |> json_response(200)
    assert mcp("usage_calibration") == rest
  end

  test "quota_get with account renders the REST ?account= body", %{conn: conn} do
    account!(:claude, "parity-quota")

    rest = conn |> get("/api/quota?account=parity-quota") |> json_response(200)
    assert mcp("quota_get", %{"account" => "parity-quota"}) == rest["data"]
  end
end
