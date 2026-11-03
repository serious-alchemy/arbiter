defmodule Arbiter.Mergers.GitlabRefPipelineTest do
  @moduledoc """
  bd-6dyva0 — CI on a speculative merge-train car: a pipeline on an
  Arbiter-owned ref (`arbiter/train/<task>`), started, read and cancelled through
  GitLab's pipelines API. The car ref is pushed with `-o ci.skip`, so the one
  pipeline per car is the one the train creates.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Gitlab
  alias Arbiter.Mergers.Gitlab.Config
  alias Arbiter.Mergers.Gitlab.Error

  @env_var "GTE_GITLAB_REF_PIPELINE_TEST_TOKEN"
  @car %{ref: "arbiter/train/bd-1", sha: "c1c1c1c1"}

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

  defp json(conn, body, status \\ 200),
    do: conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

  defp body(conn) do
    {:ok, raw, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(raw)
  end

  test "the car ref is pushed without a pipeline of its own" do
    assert Gitlab.ref_push_options() == ["-o", "ci.skip"]
  end

  describe "run_ref_pipeline/3" do
    test "creates a pipeline for the car ref, marked as a train car" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v4/projects/12345/pipeline"

        assert %{
                 "ref" => "arbiter/train/bd-1",
                 "variables" => [
                   %{
                     "key" => "ARBITER_TRAIN_CAR",
                     "value" => "true",
                     "variable_type" => "env_var"
                   }
                 ]
               } = body(conn)

        json(
          conn,
          %{"id" => 77, "sha" => "c1c1c1c1", "status" => "created", "web_url" => "u77"},
          201
        )
      end)

      assert {:ok, %{id: 77, sha: "c1c1c1c1", status: "created", url: "u77"}} =
               Gitlab.run_ref_pipeline("!1", @car, %{})
    end

    test "a pipeline the project's workflow:rules refuse is said so" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        json(conn, %{"message" => %{"base" => ["Pipeline filtered out by workflow rules."]}}, 400)
      end)

      assert {:error, %Error{kind: :pipeline_refused, message: message}} =
               Gitlab.run_ref_pipeline("!1", @car, %{})

      assert message =~ "workflow rules"
    end
  end

  describe "ref_pipeline/3" do
    test "reads the car's own pipeline by id" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        assert conn.request_path == "/api/v4/projects/12345/pipelines/77"

        json(conn, %{"id" => 77, "sha" => "c1c1c1c1", "status" => "success", "web_url" => "u77"})
      end)

      assert {:ok, %{id: 77, sha: "c1c1c1c1", status: "success", url: "u77"}} =
               Gitlab.ref_pipeline("!1", Map.put(@car, :pipeline, 77), %{})
    end

    test "a failed car pipeline carries its jobs (allow_failure dropped)" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        case conn.request_path do
          "/api/v4/projects/12345/pipelines/77" ->
            json(conn, %{"id" => 77, "sha" => "c1c1c1c1", "status" => "failed", "web_url" => "u"})

          "/api/v4/projects/12345/pipelines/77/jobs" ->
            json(conn, [
              %{"name" => "test", "stage" => "test", "status" => "failed"},
              %{
                "name" => "lint",
                "stage" => "test",
                "status" => "failed",
                "allow_failure" => true
              }
            ])
        end
      end)

      assert {:ok, %{status: "failed", jobs: [%{name: "test", stage: "test", status: "failed"}]}} =
               Gitlab.ref_pipeline("!1", Map.put(@car, :pipeline, 77), %{})
    end

    test "without an id, the newest pipeline on the car ref at the car's sha" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        assert conn.request_path == "/api/v4/projects/12345/pipelines"
        assert conn.query_string =~ "ref=arbiter%2Ftrain%2Fbd-1"
        assert conn.query_string =~ "sha=c1c1c1c1"

        json(conn, [
          %{"id" => 70, "sha" => "c1c1c1c1", "status" => "skipped", "web_url" => "u70"},
          %{"id" => 78, "sha" => "c1c1c1c1", "status" => "running", "web_url" => "u78"}
        ])
      end)

      assert {:ok, %{id: 78, status: "running"}} = Gitlab.ref_pipeline("!1", @car, %{})
    end

    test "no pipeline yet is nil, a failed read an error" do
      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn -> json(conn, []) end)
      assert {:ok, nil} = Gitlab.ref_pipeline("!1", @car, %{})

      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        json(conn, %{"message" => "boom"}, 500)
      end)

      assert {:error, _} = Gitlab.ref_pipeline("!1", Map.put(@car, :pipeline, 77), %{})
    end
  end

  describe "cancel_ref_pipeline/3" do
    test "cancels a superseded car's pipeline by id" do
      test_pid = self()

      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})
        json(conn, %{"id" => 77, "status" => "canceled"})
      end)

      assert :ok = Gitlab.cancel_ref_pipeline("!1", Map.put(@car, :pipeline, 77), %{})
      assert_received {:request, "POST", "/api/v4/projects/12345/pipelines/77/cancel"}
    end

    test "without an id, every unfinished pipeline on the car ref at its sha" do
      test_pid = self()

      Req.Test.stub(Arbiter.Mergers.Gitlab.HTTP, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        case conn.method do
          "GET" ->
            json(conn, [
              %{"id" => 78, "sha" => "c1c1c1c1", "status" => "running"},
              %{"id" => 79, "sha" => "c1c1c1c1", "status" => "pending"},
              %{"id" => 70, "sha" => "c1c1c1c1", "status" => "success"}
            ])

          "POST" ->
            json(conn, %{"status" => "canceled"})
        end
      end)

      assert :ok = Gitlab.cancel_ref_pipeline("!1", @car, %{})
      assert_received {:request, "POST", "/api/v4/projects/12345/pipelines/78/cancel"}
      assert_received {:request, "POST", "/api/v4/projects/12345/pipelines/79/cancel"}
      refute_received {:request, "POST", "/api/v4/projects/12345/pipelines/70/cancel"}
    end
  end
end
