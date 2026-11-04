defmodule Arbiter.MCP.Tools.WorkspaceConfigGitCredentialsTest do
  @moduledoc """
  Issue #1270: `workspace_config_set` on a `git_credentials` entry runs the dispatch
  guard and puts its answer in the response, so a token every dispatch would refuse
  is seen when it is set, not when the first ticket is stranded.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.MCP.Scope
  alias Arbiter.MCP.Tools
  alias Arbiter.Tasks.Workspace

  @http Arbiter.Worker.GitCredential.HTTP

  setup do
    put_app_env(:arbiter, :git_credential_req_options, plug: {Req.Test, @http})

    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "cfg-gc-#{System.unique_integer([:positive])}",
        prefix: "cg#{:rand.uniform(99_999)}",
        secrets: %{"GL_BOT" => "glpat-bot"}
      })

    {:ok,
     ws: ws, coordinator: %Scope{tier: :coordinator, workspace_id: ws.id, can_dispatch: true}}
  end

  defp patch_entry(scope, extra \\ %{}) do
    Tools.workspace_config_set(scope, %{
      "patch" => %{
        "git_credentials" => %{
          "repos" => %{
            "vstim" =>
              Map.merge(
                %{"kind" => "gitlab_bot_token", "secret" => "GL_BOT", "remote" => "acme/vstim"},
                extra
              )
          }
        }
      }
    })
  end

  test "a token GitLab answers 403 for is saved, and the response says the guard refuses it",
       %{coordinator: scope} do
    Req.Test.stub(@http, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "403 Forbidden"})
    end)

    assert {:ok, data} = patch_entry(scope)

    assert [%{repo: "vstim", status: "refused", message: message}] = data.git_credential_checks
    assert message =~ "HTTP 403"
    assert [warning] = data.warnings
    assert warning =~ "vstim"
    assert warning =~ "refused"
    # saved regardless: a GitLab outage must not block a config edit
    assert get_in(data.config, ["git_credentials", "repos", "vstim", "kind"]) ==
             "gitlab_bot_token"
  end

  test "a token the guard passes reports ok and no warning", %{coordinator: scope} do
    expires = Date.utc_today() |> Date.add(60) |> Date.to_iso8601()

    Req.Test.stub(@http, fn conn ->
      case conn.request_path do
        "/api/v4/projects" ->
          Req.Test.json(conn, [%{"path_with_namespace" => "acme/vstim"}])

        _ ->
          Req.Test.json(conn, %{"expires_at" => expires, "scopes" => ["read_api"]})
      end
    end)

    assert {:ok, data} = patch_entry(scope)
    assert [%{repo: "vstim", status: "ok"}] = data.git_credential_checks
    assert data.warnings == []
  end

  test "a write that does not touch git_credentials asks GitLab nothing", %{coordinator: scope} do
    assert {:ok, data} =
             Tools.workspace_config_set(scope, %{"key" => "merge.auto_merge", "value" => true})

    refute Map.has_key?(data, :git_credential_checks)
  end
end
