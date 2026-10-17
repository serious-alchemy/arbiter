defmodule Arbiter.Mergers.GitlabVisualArtifactsTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Mergers.Gitlab.Config

  @ref "!42"
  @env_var "GTE_GITLAB_VISUAL_TEST_TOKEN"
  @pipelines "/api/v4/projects/12345/merge_requests/42/pipelines"

  setup do
    System.put_env(@env_var, "test-gitlab-token")

    Config.put_active(%{
      "host" => "gitlab.com",
      "project_id" => 12_345,
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main"
    })

    for {:gitlab_project_path, _, _} = key <- Enum.map(:persistent_term.get(), &elem(&1, 0)) do
      :persistent_term.erase(key)
    end

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fun)
  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  describe "ci_job_artifacts/3" do
    test "the latest pipeline's failed jobs, and the visual job's artifacts archive" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines ->
            json(conn, [
              %{"id" => 200, "sha" => "headsha", "status" => "failed"},
              %{"id" => 100, "sha" => "oldsha", "status" => "success"}
            ])

          "/api/v4/projects/12345/pipelines/200/jobs" ->
            json(conn, [
              %{"id" => 1, "name" => "build", "status" => "success"},
              %{"id" => 2, "name" => "visual", "status" => "failed"},
              %{"id" => 3, "name" => "lint", "status" => "failed", "allow_failure" => true}
            ])

          "/api/v4/projects/12345/jobs/2/artifacts" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/zip")
            |> Plug.Conn.resp(200, "ZIPBYTES")
        end
      end)

      assert {:ok, %{sha: "headsha", failed_jobs: ["visual"], archive: "ZIPBYTES"}} =
               Gitlab.ci_job_artifacts(@ref, "visual", %{})
    end

    test "other failed jobs are reported, so the caller can refuse" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines ->
            json(conn, [%{"id" => 200, "sha" => "headsha", "status" => "failed"}])

          "/api/v4/projects/12345/pipelines/200/jobs" ->
            json(conn, [
              %{"id" => 2, "name" => "visual", "status" => "failed"},
              %{"id" => 4, "name" => "unit", "status" => "failed"}
            ])

          "/api/v4/projects/12345/jobs/2/artifacts" ->
            Plug.Conn.resp(conn, 200, "Z")
        end
      end)

      assert {:ok, %{failed_jobs: failed}} = Gitlab.ci_job_artifacts(@ref, "visual", %{})
      assert Enum.sort(failed) == ["unit", "visual"]
    end

    test "no pipeline, or no artifacts, is an error rather than an empty archive" do
      stub(fn conn -> json(conn, []) end)
      assert {:error, :no_pipeline} = Gitlab.ci_job_artifacts(@ref, "visual", %{})

      stub(fn conn ->
        case conn.request_path do
          @pipelines ->
            json(conn, [%{"id" => 200, "sha" => "h", "status" => "failed"}])

          "/api/v4/projects/12345/pipelines/200/jobs" ->
            json(conn, [%{"id" => 2, "name" => "visual", "status" => "failed"}])

          _ ->
            Plug.Conn.resp(conn, 404, ~s({"message":"404 Not Found"}))
        end
      end)

      assert {:error, _} = Gitlab.ci_job_artifacts(@ref, "visual", %{})
    end
  end

  describe "last_green_job_sha/3" do
    test "the sha of the newest pipeline whose job passed" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines ->
            json(conn, [
              %{"id" => 300, "sha" => "headsha", "status" => "failed"},
              %{"id" => 200, "sha" => "mid", "status" => "failed"},
              %{"id" => 100, "sha" => "greensha", "status" => "success"}
            ])

          "/api/v4/projects/12345/pipelines/300/jobs" ->
            json(conn, [%{"id" => 9, "name" => "visual", "status" => "failed"}])

          "/api/v4/projects/12345/pipelines/200/jobs" ->
            json(conn, [%{"id" => 8, "name" => "visual", "status" => "failed"}])

          "/api/v4/projects/12345/pipelines/100/jobs" ->
            json(conn, [%{"id" => 7, "name" => "visual", "status" => "success"}])
        end
      end)

      assert {:ok, "greensha"} = Gitlab.last_green_job_sha(@ref, "visual", %{})
    end

    test "a job that never passed is {:ok, nil}" do
      stub(fn conn ->
        case conn.request_path do
          @pipelines -> json(conn, [%{"id" => 300, "sha" => "h", "status" => "failed"}])
          _ -> json(conn, [%{"id" => 9, "name" => "visual", "status" => "failed"}])
        end
      end)

      assert {:ok, nil} = Gitlab.last_green_job_sha(@ref, "visual", %{})
    end
  end

  test "get/1 reports the source branch as head_ref" do
    stub(fn conn ->
      case conn.request_path do
        "/api/v4/projects/12345/merge_requests/42" ->
          json(conn, %{
            "iid" => 42,
            "state" => "opened",
            "sha" => "headsha",
            "source_branch" => "feature/x",
            "target_branch" => "main"
          })

        _ ->
          json(conn, [])
      end
    end)

    assert {:ok, %{head_ref: "feature/x", base_ref: "main", head_sha: "headsha"}} =
             Gitlab.get(@ref)
  end
end
