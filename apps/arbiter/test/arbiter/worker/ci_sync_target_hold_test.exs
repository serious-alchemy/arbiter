defmodule Arbiter.Worker.CiSyncTargetHoldTest do
  # The target-branch-red hold judges the jobs that test the code, not a failed
  # deploy / release job (bd-dtbsgx).
  use Arbiter.DataCase, async: false

  alias Arbiter.Tasks.Workspace
  alias Arbiter.Worker.CiSync

  @moduletag :capture_log

  setup do
    Arbiter.Test.StubMerger.reset()
    :ok
  end

  defp workspace(merge_repo_cfg) do
    %Workspace{
      name: "ws",
      prefix: "ws",
      config: %{"merge" => %{"repos" => %{"vstim" => merge_repo_cfg}}}
    }
  end

  defp failed(jobs),
    do: {:ok, %{id: 3_002_507_446, sha: "abcdef123456", status: "failed", url: "u", jobs: jobs}}

  defp hold(ws), do: CiSync.target_hold(Arbiter.Test.StubMerger, "!1", "main", ws, "vstim")

  defp job(name, stage, status \\ "failed"), do: %{name: name, stage: stage, status: status}

  test "only a failed deploy job (in deploy_watch.jobs) is not red" do
    Arbiter.Test.StubMerger.set_branch_pipeline(
      failed([job("test", "test", "success"), job("deploy-worker", "x")])
    )

    ws = workspace(%{"deploy_watch" => %{"jobs" => ["deploy-web", "deploy-worker"]}})
    assert hold(ws) == nil
  end

  test "a failed job in a deploy/release stage is not red by default" do
    Arbiter.Test.StubMerger.set_branch_pipeline(
      failed([job("ship", "deploy"), job("tag", "Release")])
    )

    assert hold(workspace(%{})) == nil
  end

  test "target_red_ignore_jobs and target_red_stages are honoured" do
    Arbiter.Test.StubMerger.set_branch_pipeline(
      failed([job("notify", "post"), job("smoke", "verify")])
    )

    ws = workspace(%{"target_red_ignore_jobs" => ["notify"], "target_red_stages" => ["verify"]})
    assert hold(ws) == nil
    assert hold(workspace(%{})) =~ "notify"
  end

  test "a failed test job beside a failed deploy job holds and names only the test job" do
    Arbiter.Test.StubMerger.set_branch_pipeline(
      failed([job("unit-tests", "test"), job("deploy-worker", "deploy")])
    )

    why = hold(workspace(%{"deploy_watch" => %{"jobs" => ["deploy-worker"]}}))
    assert why =~ "target branch red: main pipeline 3002507446"
    assert why =~ "unit-tests"
    refute why =~ "deploy-worker"
  end

  test "no job detail keeps the pipeline-level verdict" do
    Arbiter.Test.StubMerger.set_branch_pipeline(failed(nil))
    assert hold(workspace(%{})) =~ "target branch red"
  end

  describe "judge_failure/3 (a merge-train car's failed pipeline, bd-6dyva0)" do
    test "only ignored deploy jobs failing is not a code failure" do
      ws = workspace(%{"deploy_watch" => %{"jobs" => ["deploy-worker"]}})

      {:ok, pipeline} =
        failed([job("unit-tests", "test", "success"), job("deploy-worker", "deploy")])

      assert {:ignored, ["deploy-worker"]} = CiSync.judge_failure(pipeline, ws, "vstim")
    end

    test "a failed test job is red, and no job detail keeps the pipeline verdict" do
      {:ok, pipeline} = failed([job("unit-tests", "test")])
      assert {:red, ["unit-tests"]} = CiSync.judge_failure(pipeline, workspace(%{}), "vstim")

      {:ok, bare} = failed(nil)
      assert {:red, []} = CiSync.judge_failure(bare, workspace(%{}), "vstim")
    end
  end
end
