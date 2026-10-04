defmodule ArbiterWeb.Api.WorkspaceGuardrailAuthorityTest do
  @moduledoc """
  G11 (bd-anwb0u) AC3 over REST: loosening `guardrails.*` and `agent.security`
  is operator-only, tested for each token tier. A worker or refine token is
  refused at the route; a coordinator token may tighten and is refused a
  loosening; only a coordinator token with operator proof (minted over the
  operator socket) may loosen.
  """
  use ArbiterWeb.ConnCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace

  @cap %{"match" => %{"provider" => "antigravity"}, "max_tier" => "probation"}

  setup do
    n = System.unique_integer([:positive])

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gr-auth-#{n}",
        prefix: "gra",
        config: %{
          "guardrails" => %{"subjects" => [@cap]},
          "agent" => %{"security" => %{"permissions" => %{"mode" => "strict"}}}
        }
      })

    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id})
    {:ok, ws: ws, task: task}
  end

  defp as(token) do
    Phoenix.ConnTest.build_conn()
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp patch_config(conn, ws, body), do: patch(conn, "/api/workspaces/#{ws.id}/config", body)

  @loosen_guardrails %{"patch" => %{"guardrails" => %{"subjects" => [%{@cap | "max_tier" => "trusted"}]}}}
  @loosen_security %{"patch" => %{"agent" => %{"security" => %{"permissions" => %{"mode" => "bypass"}}}}}
  @tighten_guardrails %{"patch" => %{"guardrails" => %{"subjects" => [%{@cap | "max_tier" => "quarantine"}]}}}
  @tighten_security %{"patch" => %{"agent" => %{"security" => %{"sandbox" => %{"egress" => "none"}}}}}

  describe "worker and refine tokens" do
    test "a worker token is refused the config route outright", %{ws: ws, task: task} do
      conn = as(Scope.mint_worker(task))
      assert patch_config(conn, ws, @tighten_guardrails).status == 403
      assert patch_config(conn, ws, @loosen_guardrails).status == 403
    end

    test "a refine token is refused the config route outright", %{ws: ws, task: task} do
      session = Ash.create!(Arbiter.Sessions.Session, %{cwd: "/tmp/gr-auth-refine"})
      conn = as(Scope.mint_refine(session.id, ws.id, task.id))
      assert patch_config(conn, ws, @tighten_security).status == 403
      assert patch_config(conn, ws, @loosen_security).status == 403
    end

    test "and the config is untouched", %{ws: ws, task: task} do
      _ = patch_config(as(Scope.mint_worker(task)), ws, @loosen_guardrails)
      assert get_in(Ash.get!(Workspace, ws.id).config, ["guardrails", "subjects"]) == [@cap]
    end
  end

  describe "coordinator token (no operator proof)" do
    setup %{ws: _} do
      {:ok, conn: as(Scope.mint_coordinator(nil))}
    end

    test "may tighten guardrails.* and agent.security", %{conn: conn, ws: ws} do
      assert patch_config(conn, ws, @tighten_guardrails).status == 200
      assert patch_config(conn, ws, @tighten_security).status == 200
    end

    test "is refused a loosening of guardrails.*", %{conn: conn, ws: ws} do
      resp = patch_config(conn, ws, @loosen_guardrails)
      assert resp.status == 422
      assert inspect(json_response(resp, 422)) =~ "operator-only"
      assert get_in(Ash.get!(Workspace, ws.id).config, ["guardrails", "subjects"]) == [@cap]
    end

    test "is refused a loosening of agent.security", %{conn: conn, ws: ws} do
      assert patch_config(conn, ws, @loosen_security).status == 422
      assert get_in(Ash.get!(Workspace, ws.id).config, ["agent", "security", "permissions", "mode"]) == "strict"
    end

    test "is refused loosening through unset_paths and through the whole-config update", %{conn: conn, ws: ws} do
      assert patch_config(conn, ws, %{"unset_paths" => ["guardrails.subjects"]}).status == 422
      assert patch_config(conn, ws, %{"unset_paths" => ["agent.security.permissions.mode"]}).status == 422
      assert patch(conn, "/api/workspaces/#{ws.id}", %{"config" => %{}}).status == 422
    end

    test "may edit unrelated config", %{conn: conn, ws: ws} do
      assert patch_config(conn, ws, %{"patch" => %{"merge" => %{"auto_merge" => true}}}).status == 200
    end
  end

  describe "coordinator token with operator proof" do
    test "may loosen guardrails.* and agent.security", %{ws: ws} do
      conn = as(Scope.mint_coordinator(nil, operator: true))
      assert patch_config(conn, ws, @loosen_guardrails).status == 200
      assert patch_config(conn, ws, @loosen_security).status == 200
    end
  end
end
