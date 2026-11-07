defmodule Arbiter.Worker.GitCredentialRefusalAlertTest do
  @moduledoc """
  Issue #1270: every dispatch, fix round and push of a repo goes through the same
  `gitlab_bot_token` guard, so when one credential refuses them all the operator
  gets ONE repo-level alert (`alert_list`) naming the repo and the reason, not one
  generic "spawn failed" per ticket. The alert clears when the guard passes again.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.GitCredential

  @http Arbiter.Worker.GitCredential.HTTP

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "gcra-#{System.unique_integer([:positive])}",
        prefix: "ga#{:rand.uniform(99_999)}",
        config: %{
          "git_credentials" => %{
            "repos" => %{
              "vstim" => %{
                "kind" => "gitlab_bot_token",
                "secret" => "GL_BOT",
                "remote" => "acme/vstim"
              }
            }
          }
        },
        secrets: %{"GL_BOT" => "glpat-bot"}
      })

    {:ok, ws: ws}
  end

  defp materialize(ws) do
    {:ok, plan} = GitCredential.plan(ws, "vstim", role: :implementer, guarded?: true)
    GitCredential.materialize(plan, ws, req_options: [plug: {Req.Test, @http}])
  end

  defp alerts(ws), do: Alerts.active(workspace_id: ws.id, kind: :git_credential_refused)

  test "repeated refusals of one repo raise a single alert naming the repo and the reason", %{
    ws: ws
  } do
    Req.Test.stub(@http, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "403 Forbidden"})
    end)

    for _ <- 1..3 do
      assert {:error, {:git_credential_bot_token_refused, {:rejected, 403}}} = materialize(ws)
    end

    assert [alert] = alerts(ws)
    assert alert.key == "#{ws.id}:vstim"
    assert alert.subject =~ "vstim"
    assert alert.detail =~ "rejected the token (HTTP 403)"
    assert alert.detail =~ "vstim"
    assert alert.raise_count == 3
  end

  test "the alert clears once the guard passes", %{ws: ws} do
    Req.Test.stub(@http, fn conn ->
      conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"message" => "403 Forbidden"})
    end)

    assert {:error, _} = materialize(ws)
    assert [_] = alerts(ws)

    expires = Date.utc_today() |> Date.add(60) |> Date.to_iso8601()

    Req.Test.stub(@http, fn conn ->
      case conn.request_path do
        "/api/v4/projects" ->
          Req.Test.json(conn, [%{"path_with_namespace" => "acme/vstim"}])

        _ ->
          Req.Test.json(conn, %{"expires_at" => expires, "scopes" => ["read_api"]})
      end
    end)

    assert {:ok, _material} = materialize(ws)
    assert alerts(ws) == []
  end
end
