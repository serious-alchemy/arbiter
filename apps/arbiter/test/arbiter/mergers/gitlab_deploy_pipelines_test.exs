defmodule Arbiter.Mergers.GitlabDeployPipelinesTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Mergers.Gitlab.Config

  @env_var "GTE_GITLAB_DEPLOY_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => "gitlab.com",
      "project_id" => 12_345,
      "credentials_ref" => "env:#{@env_var}"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  test "deploy_pipelines/3 lists the branch's pipelines newest first with their jobs" do
    Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
      case conn.request_path do
        "/api/v4/projects/12345/pipelines" ->
          assert conn.query_string =~ "ref=main"

          json(conn, [
            %{"id" => 1, "sha" => "a", "status" => "success", "web_url" => "u1"},
            %{"id" => 2, "sha" => "b", "status" => "success", "web_url" => "u2"}
          ])

        "/api/v4/projects/12345/pipelines/2/jobs" ->
          json(conn, [%{"name" => "deploy", "status" => "skipped"}])

        "/api/v4/projects/12345/pipelines/1/jobs" ->
          json(conn, [%{"name" => "deploy", "status" => "success"}])
      end
    end)

    assert {:ok, [newest, older]} = Gitlab.deploy_pipelines("!1", "main", %{})
    assert %{id: 2, sha: "b", url: "u2", jobs: [%{name: "deploy", status: "skipped"}]} = newest
    assert %{id: 1, jobs: [%{name: "deploy", status: "success"}]} = older
  end

  describe "branch_pipeline/3 (bd-5owt7w)" do
    test "reports the newest settled pipeline, skipping one still running" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        if String.ends_with?(conn.request_path, "/jobs") do
          json(conn, [])
        else
          assert conn.request_path == "/api/v4/projects/12345/pipelines"
          assert conn.query_string =~ "ref=main"

          json(conn, [
            %{"id" => 3, "sha" => "c", "status" => "running", "web_url" => "u3"},
            %{"id" => 2, "sha" => "b", "status" => "failed", "web_url" => "u2"},
            %{"id" => 1, "sha" => "a", "status" => "success", "web_url" => "u1"}
          ])
        end
      end)

      assert {:ok, %{id: 2, sha: "b", status: "failed", url: "u2"}} =
               Gitlab.branch_pipeline("!1", "main", %{})
    end

    test "a failed pipeline carries job-level status (stage, allow_failure dropped)" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/pipelines" ->
            json(conn, [%{"id" => 2, "sha" => "b", "status" => "failed", "web_url" => "u2"}])

          "/api/v4/projects/12345/pipelines/2/jobs" ->
            json(conn, [
              %{"name" => "test", "stage" => "test", "status" => "success"},
              %{"name" => "deploy-worker", "stage" => "deploy", "status" => "failed"},
              %{
                "name" => "lint",
                "stage" => "test",
                "status" => "failed",
                "allow_failure" => true
              }
            ])
        end
      end)

      assert {:ok, %{status: "failed", jobs: jobs}} = Gitlab.branch_pipeline("!1", "main", %{})

      assert jobs == [
               %{name: "test", stage: "test", status: "success"},
               %{name: "deploy-worker", stage: "deploy", status: "failed"}
             ]
    end

    test "a branch with no settled pipeline has no verdict" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        json(conn, [%{"id" => 3, "sha" => "c", "status" => "canceled"}])
      end)

      assert {:ok, nil} = Gitlab.branch_pipeline("!1", "main", %{})
    end

    test "a failed read is an error, not a verdict" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      assert {:error, _} = Gitlab.branch_pipeline("!1", "main", %{})
    end
  end
end
