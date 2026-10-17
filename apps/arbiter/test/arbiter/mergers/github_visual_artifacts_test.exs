defmodule Arbiter.Mergers.GithubVisualArtifactsTest do
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.Github.Config

  @ref "#42"
  @env_var "GTE_GITHUB_VISUAL_TEST_TOKEN"

  setup do
    System.put_env(@env_var, "test-github-token")

    Config.put_active(%{
      "owner" => "octo",
      "repo" => "widget",
      "credentials_ref" => "env:#{@env_var}",
      "default_target_branch" => "main"
    })

    on_exit(fn ->
      Config.clear()
      System.delete_env(@env_var)
    end)

    :ok
  end

  defp stub(fun), do: Req.Test.stub(Arbiter.Mergers.Github.HTTP, fun)
  defp json(conn, body), do: conn |> Plug.Conn.put_status(200) |> Req.Test.json(body)

  describe "ci_job_artifacts/3" do
    test "failed check names on the head, and the named artifact of the head's run" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            json(conn, %{"head" => %{"sha" => "sha1", "ref" => "feature/x"}})

          "/repos/octo/widget/commits/sha1/check-runs" ->
            json(conn, %{
              "check_runs" => [
                %{"id" => 1, "name" => "build", "conclusion" => "success"},
                %{"id" => 2, "name" => "visual", "conclusion" => "failure"}
              ]
            })

          "/repos/octo/widget/actions/runs" ->
            json(conn, %{
              "workflow_runs" => [
                %{"id" => 77, "status" => "completed", "conclusion" => "failure"}
              ]
            })

          "/repos/octo/widget/actions/runs/77/artifacts" ->
            json(conn, %{
              "artifacts" => [
                %{"id" => 500, "name" => "playwright-actuals", "expired" => false}
              ]
            })

          "/repos/octo/widget/actions/artifacts/500/zip" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/zip")
            |> Plug.Conn.resp(200, "ZIPBYTES")
        end
      end)

      assert {:ok, %{sha: "sha1", failed_jobs: ["visual"], archive: "ZIPBYTES"}} =
               Github.ci_job_artifacts(@ref, "visual", %{artifact: "playwright-actuals"})
    end

    test "needs the artifact name: GitHub artifacts are per workflow run, not per job" do
      assert {:error, :artifact_name_required} = Github.ci_job_artifacts(@ref, "visual", %{})
    end

    test "an expired or missing artifact is an error" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42" ->
            json(conn, %{"head" => %{"sha" => "sha1"}})

          "/repos/octo/widget/commits/sha1/check-runs" ->
            json(conn, %{
              "check_runs" => [%{"id" => 2, "name" => "visual", "conclusion" => "failure"}]
            })

          "/repos/octo/widget/actions/runs" ->
            json(conn, %{
              "workflow_runs" => [
                %{"id" => 77, "status" => "completed", "conclusion" => "failure"}
              ]
            })

          "/repos/octo/widget/actions/runs/77/artifacts" ->
            json(conn, %{"artifacts" => [%{"id" => 500, "name" => "a", "expired" => true}]})
        end
      end)

      assert {:error, :no_artifact} = Github.ci_job_artifacts(@ref, "visual", %{artifact: "a"})
    end
  end

  describe "last_green_job_sha/3" do
    test "walks the PR's commits newest first for a passing check of that name" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42/commits" ->
            json(conn, [%{"sha" => "c1"}, %{"sha" => "c2"}, %{"sha" => "c3"}])

          "/repos/octo/widget/commits/c3/check-runs" ->
            json(conn, %{
              "check_runs" => [%{"id" => 9, "name" => "visual", "conclusion" => "failure"}]
            })

          "/repos/octo/widget/commits/c2/check-runs" ->
            json(conn, %{
              "check_runs" => [%{"id" => 8, "name" => "visual", "conclusion" => "success"}]
            })
        end
      end)

      assert {:ok, "c2"} = Github.last_green_job_sha(@ref, "visual", %{})
    end

    test "never green is {:ok, nil}" do
      stub(fn conn ->
        case conn.request_path do
          "/repos/octo/widget/pulls/42/commits" -> json(conn, [%{"sha" => "c1"}])
          _ -> json(conn, %{"check_runs" => []})
        end
      end)

      assert {:ok, nil} = Github.last_green_job_sha(@ref, "visual", %{})
    end
  end

  test "get/1 reports the head branch as head_ref" do
    stub(fn conn ->
      case conn.request_path do
        "/repos/octo/widget/pulls/42" ->
          json(conn, %{
            "state" => "open",
            "head" => %{"sha" => "sha1", "ref" => "feature/x"},
            "base" => %{"ref" => "main"}
          })

        _ ->
          json(conn, %{"check_runs" => [], "reviews" => []})
      end
    end)

    assert {:ok, %{head_ref: "feature/x", head_sha: "sha1"}} = Github.get(@ref)
  end
end
