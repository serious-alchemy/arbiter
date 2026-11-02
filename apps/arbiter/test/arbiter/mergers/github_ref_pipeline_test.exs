defmodule Arbiter.Mergers.GithubRefPipelineTest do
  @moduledoc """
  bd-6dyva0 — CI on a speculative merge-train car on GitHub: the car branch's
  push starts its `on: push` workflows (or a configured workflow is dispatched
  on it), and the car's verdict is every workflow run on the car's sha, taken
  together.
  """
  use ExUnit.Case, async: false

  alias Arbiter.Mergers.Github
  alias Arbiter.Mergers.Github.Config

  @env_var "GTE_GITHUB_REF_PIPELINE_TEST_TOKEN"
  @ref "#42"
  @car %{ref: "arbiter/train/bd-1", sha: "c1c1c1c1"}

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

  defp run(id, sha, status, conclusion \\ nil, name \\ "ci"),
    do: %{
      "id" => id,
      "name" => name,
      "head_sha" => sha,
      "status" => status,
      "conclusion" => conclusion,
      "html_url" => "https://github.com/octo/widget/actions/runs/#{id}"
    }

  defp stub_runs(runs) do
    stub(fn conn ->
      if String.ends_with?(conn.request_path, "/jobs") do
        Req.Test.json(conn, %{
          "jobs" => [%{"name" => "test", "status" => "completed", "conclusion" => "failure"}]
        })
      else
        assert conn.request_path == "/repos/octo/widget/actions/runs"
        assert conn.query_string =~ "head_sha=c1c1c1c1"
        assert conn.query_string =~ "branch=arbiter%2Ftrain%2Fbd-1"
        Req.Test.json(conn, %{"workflow_runs" => runs})
      end
    end)
  end

  describe "run_ref_pipeline/3" do
    test "the car branch's own push starts its workflows: nothing to ask" do
      stub(fn _conn -> flunk("no request expected") end)
      assert {:ok, nil} = Github.run_ref_pipeline(@ref, @car, %{})
    end

    test "a configured workflow is dispatched on the car branch" do
      test_pid = self()

      stub(fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch, conn.method, conn.request_path, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 204, "")
      end)

      assert {:ok, nil} = Github.run_ref_pipeline(@ref, @car, %{workflow: "train.yml"})

      assert_received {:dispatch, "POST",
                       "/repos/octo/widget/actions/workflows/train.yml/dispatches",
                       %{"ref" => "arbiter/train/bd-1"}}
    end
  end

  describe "ref_pipeline/3" do
    test "no run on the car's sha yet is nil" do
      stub_runs([])
      assert {:ok, nil} = Github.ref_pipeline(@ref, @car, %{})
    end

    test "all runs green is success; a run on another sha does not count" do
      stub_runs([
        run(12, "c1c1c1c1", "completed", "success"),
        run(11, "c1c1c1c1", "completed", "skipped", "docs"),
        run(5, "other", "completed", "failure")
      ])

      assert {:ok, %{status: "success", sha: "c1c1c1c1", id: 12}} =
               Github.ref_pipeline(@ref, @car, %{})
    end

    test "any run still going is running" do
      stub_runs([
        run(12, "c1c1c1c1", "completed", "success"),
        run(13, "c1c1c1c1", "in_progress", nil, "e2e")
      ])

      assert {:ok, %{status: "running"}} = Github.ref_pipeline(@ref, @car, %{})
    end

    test "a red run beside a green one is failed, with the failed runs' jobs" do
      stub_runs([
        run(12, "c1c1c1c1", "completed", "success"),
        run(13, "c1c1c1c1", "completed", "failure", "e2e")
      ])

      assert {:ok, %{status: "failed", id: 13, jobs: [%{name: "test", status: "failed"}]}} =
               Github.ref_pipeline(@ref, @car, %{})
    end

    test "only cancelled runs is canceled" do
      stub_runs([run(12, "c1c1c1c1", "completed", "cancelled")])
      assert {:ok, %{status: "canceled"}} = Github.ref_pipeline(@ref, @car, %{})
    end

    test "every run skipped is skipped: nothing tested the car" do
      stub_runs([
        run(12, "c1c1c1c1", "completed", "skipped"),
        run(13, "c1c1c1c1", "completed", "skipped", "e2e")
      ])

      assert {:ok, %{status: "skipped"}} = Github.ref_pipeline(@ref, @car, %{})
    end
  end

  describe "cancel_ref_pipeline/3" do
    test "cancels every unfinished run on the car's sha" do
      test_pid = self()

      stub(fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        case conn.method do
          "GET" ->
            Req.Test.json(conn, %{
              "workflow_runs" => [
                run(12, "c1c1c1c1", "in_progress"),
                run(13, "c1c1c1c1", "queued"),
                run(14, "c1c1c1c1", "completed", "success")
              ]
            })

          "POST" ->
            conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{})
        end
      end)

      assert :ok = Github.cancel_ref_pipeline(@ref, @car, %{})
      assert_received {:request, "POST", "/repos/octo/widget/actions/runs/12/cancel"}
      assert_received {:request, "POST", "/repos/octo/widget/actions/runs/13/cancel"}
      refute_received {:request, "POST", "/repos/octo/widget/actions/runs/14/cancel"}
    end
  end
end
