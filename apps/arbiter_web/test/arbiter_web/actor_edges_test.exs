defmodule ArbiterWeb.ActorEdgesTest do
  @moduledoc """
  bd-6i7yzq: the web edges derive an `Arbiter.Actor` — REST/CLI by bearer token,
  the dashboard by session — and what a request writes is attributed to it.
  Attribution only: every call here succeeds for the same caller as before.
  """
  use ArbiterWeb.ConnCase, async: false

  require Ash.Query

  alias Arbiter.Actor
  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Tasks.Issue.Version

  setup do
    {:ok, ws} = Ash.create(Workspace, %{name: "edge-ws", prefix: "edg"})

    {:ok, issue} =
      Ash.create(Issue, %{title: "edge", workspace_id: ws.id, acceptance: "- works"})

    on_exit(fn -> Actor.put(nil) end)
    {:ok, ws: ws, issue: issue}
  end

  defp with_token(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  defp promote_actor(issue) do
    [version] =
      Version
      |> Ash.Query.filter(
        version_source_id == ^issue.id and version_action_name == :promote_to_ready
      )
      |> Ash.read!()

    version.actor
  end

  describe "REST / CLI token edge" do
    test "a coordinator token acts as the coordinator", %{conn: conn, issue: issue} do
      conn = post(conn, ~p"/api/issues/#{issue.id}/promote")
      assert json_response(conn, 200)["state"] == "queued"

      assert Actor.current() == Actor.coordinator()
      assert promote_actor(issue) == "coordinator"
    end

    test "an operator-proof token (the human's own arb) acts as operator:cli", %{
      conn: conn,
      issue: issue
    } do
      token = Scope.mint_coordinator(nil, operator: true)
      conn = conn |> with_token(token) |> post(~p"/api/issues/#{issue.id}/promote")

      assert json_response(conn, 200)["state"] == "queued"
      assert promote_actor(issue) == "operator:cli"
    end

    test "a worker token acts as worker:<ticket>", %{conn: conn, ws: ws, issue: issue} do
      token = Scope.mint_worker(issue, nil)
      _ = ws
      get(with_token(conn, token), ~p"/api/issues/#{issue.id}")

      assert Actor.current() == Actor.worker(issue.id)
    end

    test "the actor is re-derived per request, not carried over", %{conn: conn, issue: issue} do
      Actor.put(Actor.autopilot())
      get(conn, ~p"/api/issues/#{issue.id}")
      assert Actor.current() == Actor.coordinator()

      # no token on a loopback request: anonymous, so unattributed
      anon = %{Phoenix.ConnTest.build_conn() | remote_ip: {127, 0, 0, 1}}
      get(anon, ~p"/api/version")
      assert Actor.current() == nil
    end

    test "GET /api/issues/:id carries the history, each write with its actor", %{
      conn: conn,
      issue: issue
    } do
      post(conn, ~p"/api/issues/#{issue.id}/promote")
      body = conn |> get(~p"/api/issues/#{issue.id}") |> json_response(200)

      assert [
               %{"action" => "promote_to_ready", "actor" => "coordinator", "state" => "queued"}
               | _
             ] =
               body["history"]
    end
  end

  describe "dashboard edge" do
    test "the :browser plug makes the request the operator's", %{conn: conn} do
      conn |> dashboard_login() |> get("/")
      assert Actor.current() == Actor.operator("test")
    end

    test "the LiveView mount hook makes the LiveView process the operator's" do
      session = ArbiterWeb.DashboardAuth.Default.grant_session("token", "ryan")

      assert {:cont, _socket} =
               ArbiterWeb.LiveHooks.on_mount(
                 :dashboard_auth,
                 %{},
                 session,
                 %Phoenix.LiveView.Socket{}
               )

      assert Actor.current() == Actor.operator("ryan")
    end
  end
end
