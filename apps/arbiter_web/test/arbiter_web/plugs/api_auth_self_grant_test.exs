defmodule ArbiterWeb.Plugs.ApiAuthSelfGrantTest do
  # G17: a worker's REST attempt to widen its own authority is refused (403)
  # and recorded as a critical guardrail event.
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.Guardrails.Events
  alias Arbiter.MCP.Scope

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp worker_conn(conn, task_id) do
    token = Scope.mint_worker(%{id: task_id, workspace_id: Ash.UUID.generate()})
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  test "a worker minting a token is recorded", %{conn: conn} do
    conn = conn |> worker_conn("bd-sg-rest1") |> post("/api/mcp/tokens", %{})
    assert conn.status == 403

    assert [%{kind: :self_grant_attempt, severity: :critical, source: :bridge_audit}] =
             Events.for_run("bd-sg-rest1")
  end

  test "a worker patching guardrails config is refused and recorded", %{conn: conn} do
    conn =
      conn
      |> worker_conn("bd-sg-rest2")
      |> patch("/api/workspaces/#{Ash.UUID.generate()}/config", %{
        "key" => "guardrails.cap.egress",
        "value" => "open"
      })

    assert conn.status == 403
    assert [%{kind: :self_grant_attempt}] = Events.for_run("bd-sg-rest2")
  end

  test "a worker's ordinary progress update leaves no event", %{conn: conn} do
    conn
    |> worker_conn("bd-sg-rest3")
    |> patch("/api/issues/bd-sg-rest3", %{"notes" => "done"})

    assert Events.for_run("bd-sg-rest3") == []
  end

  test "a coordinator token is not audited", %{conn: conn} do
    conn
    |> put_req_header("authorization", "Bearer #{Scope.mint_coordinator(nil)}")
    |> post("/api/mcp/tokens", %{})

    assert Events.for_run("unknown") == []
  end
end
