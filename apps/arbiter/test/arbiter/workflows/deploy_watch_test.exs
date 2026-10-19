defmodule Arbiter.Workflows.DeployWatchTest do
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.Tasks.{Issue, Verification, Workspace}
  alias Arbiter.Workflows.DeployWatch

  # Forge double: the test process holds `:fake_forge` = %{merge_shas: %{pr_ref => sha},
  # pipelines: [...], ancestry: [{older, newer}]}; `sweep/4` runs in the test process.
  defmodule FakeForge do
    def get(ref) do
      forge = Process.get(:fake_forge)
      {:ok, %{status: :merged, merge_sha: Map.get(forge.merge_shas, ref)}}
    end

    def deploy_pipelines(_ref, _branch, _opts), do: {:ok, Process.get(:fake_forge).pipelines}

    def ancestor?(_ref, older, newer) do
      {:ok, older == newer or {older, newer} in Process.get(:fake_forge).ancestry}
    end
  end

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "dw-#{System.unique_integer([:positive])}",
        prefix: "dw#{System.unique_integer([:positive])}",
        config: %{
          "merge" => %{
            "strategy" => "gitlab",
            "repos" => %{
              "tonic" => %{"deploy_watch" => %{"job" => "deploy", "timeout_minutes" => 90}}
            }
          }
        }
      })

    {:ok, ws: ws}
  end

  defp merged_task(ws, pr_ref) do
    {:ok, task} = Ash.create(Issue, %{title: "t #{pr_ref}", workspace_id: ws.id, repo: "tonic"})
    {:ok, task} = Ash.update(task, %{pr_ref: pr_ref}, action: :update)
    {:ok, :closed, closed} = Verification.finalize_merged(task, close_upstream: false)
    closed
  end

  defp forge(merge_shas, pipelines, ancestry \\ []),
    do:
      Process.put(:fake_forge, %{merge_shas: merge_shas, pipelines: pipelines, ancestry: ancestry})

  defp pipeline(id, sha, status, jobs),
    do: %{
      id: id,
      sha: sha,
      status: status,
      url: "https://gl/p/#{id}",
      jobs: Enum.map(jobs, fn {n, s} -> %{name: n, status: s} end)
    }

  defp sweep(ws, now \\ nil), do: DeployWatch.sweep(ws, "tonic", FakeForge, now: now)

  defp watch_of(task), do: Ash.get!(Issue, task.id).merger_status["deploy_watch"]

  defp active_alerts(ws),
    do: Alerts.active(workspace_id: ws.id) |> Enum.filter(&(&1.kind == :deploy_failing))

  test "config is off unless deploy_watch is set", %{ws: ws} do
    assert DeployWatch.config(ws, "tonic").jobs == ["deploy"]
    assert DeployWatch.config(ws, "other") == nil
    assert DeployWatch.sweep(ws, "other", FakeForge) == :off
  end

  test "AC1: a successful deploy job is recorded on the ticket and raises nothing", %{ws: ws} do
    task = merged_task(ws, "!1")

    forge(%{"!1" => "aaa"}, [
      pipeline(10, "aaa", "success", [{"build", "success"}, {"deploy", "success"}])
    ])

    sweep(ws)

    assert %{"state" => "deployed", "pipeline_id" => 10, "deployed_at" => _} = watch_of(task)
    assert active_alerts(ws) == []
  end

  test "an open alert is cleared when the alerted ticket ages out or the watch is removed",
       %{ws: ws} do
    task = merged_task(ws, "!9")
    forge(%{"!9" => "ddd"}, [pipeline(40, "ddd", "success", [{"deploy", "skipped"}])])
    sweep(ws)
    assert [_] = active_alerts(ws)

    # Aged out of the 7-day window: nothing unresolved, the alert goes.
    later = DateTime.add(DateTime.utc_now(), 8 * 86_400, :second)
    sweep(ws, later)
    assert active_alerts(ws) == []
    _ = task

    # Watch removed from config: a stale alert is cleared on the :off path.
    {:ok, _} =
      Alerts.raise_alert(%{
        kind: :deploy_failing,
        key: DeployWatch.alert_key(ws.id, "tonic"),
        workspace_id: ws.id,
        subject: "stale",
        detail: "stale",
        owner: :coordinator
      })

    {:ok, ws} = Ash.update(ws, %{config: %{}}, action: :update)
    assert DeployWatch.sweep(ws, "tonic", FakeForge) == :off
    assert active_alerts(ws) == []
  end

  test "AC2: the 10-18 case — pipeline success but build/deploy skipped — alerts once", %{ws: ws} do
    task = merged_task(ws, "!367")

    forge(%{"!367" => "bbb"}, [
      pipeline(20, "bbb", "success", [{"build", "skipped"}, {"deploy", "skipped"}])
    ])

    sweep(ws)

    assert %{"state" => "alerted", "job_statuses" => %{"deploy" => "skipped"}} = watch_of(task)
    assert [alert] = active_alerts(ws)
    assert alert.owner == :coordinator
    assert alert.detail =~ "bbb"
    assert alert.detail =~ "deploy=skipped"
    assert alert.detail =~ "https://gl/p/20"
    assert alert.subject =~ "tonic"

    # A second sweep neither re-alerts nor adds a row.
    sweep(ws)
    assert [%{raise_count: 1}] = active_alerts(ws)
  end

  test "a missing deploy job alerts as missing", %{ws: ws} do
    task = merged_task(ws, "!2")
    forge(%{"!2" => "ccc"}, [pipeline(30, "ccc", "success", [{"build", "success"}])])
    sweep(ws)
    assert %{"job_statuses" => %{"deploy" => "missing"}} = watch_of(task)
    assert [_] = active_alerts(ws)
  end

  test "no pipeline yet waits, then alerts at the timeout", %{ws: ws} do
    task = merged_task(ws, "!3")
    forge(%{"!3" => "ddd"}, [])
    sweep(ws)
    assert watch_of(task)["state"] == "pending"
    assert active_alerts(ws) == []

    sweep(ws, DateTime.add(DateTime.utc_now(), 91 * 60, :second))
    assert watch_of(task)["state"] == "alerted"
    assert [alert] = active_alerts(ws)
    assert alert.detail =~ "ddd"
  end

  test "AC3: an auto-canceled pipeline whose commit is in a later successful deploy does not alert",
       %{ws: ws} do
    task = merged_task(ws, "!4")

    forge(
      %{"!4" => "old"},
      [
        pipeline(41, "new", "success", [{"deploy", "success"}]),
        pipeline(40, "old", "canceled", [{"deploy", "canceled"}])
      ],
      [{"old", "new"}]
    )

    sweep(ws)

    assert %{"state" => "deployed", "pipeline_id" => 41} = watch_of(task)
    assert active_alerts(ws) == []
  end

  test "a canceled pipeline with no successor yet waits instead of alerting", %{ws: ws} do
    task = merged_task(ws, "!5")
    forge(%{"!5" => "old"}, [pipeline(50, "old", "canceled", [{"deploy", "canceled"}])])
    sweep(ws)
    assert watch_of(task)["state"] == "pending"
    assert active_alerts(ws) == []
  end

  test "a failed own pipeline waits while a containing pipeline is still running", %{ws: ws} do
    task = merged_task(ws, "!6")

    forge(
      %{"!6" => "old"},
      [
        pipeline(61, "new", "running", [{"deploy", "created"}]),
        pipeline(60, "old", "failed", [{"deploy", "failed"}])
      ],
      [{"old", "new"}]
    )

    sweep(ws)
    assert watch_of(task)["state"] == "pending"
    assert active_alerts(ws) == []
  end

  test "AC4: several merges in one outage give one alert, cleared by a later deploy", %{ws: ws} do
    t1 = merged_task(ws, "!7")
    t2 = merged_task(ws, "!8")

    forge(%{"!7" => "s1", "!8" => "s2"}, [
      pipeline(72, "s2", "success", [{"deploy", "skipped"}]),
      pipeline(71, "s1", "success", [{"deploy", "skipped"}])
    ])

    sweep(ws)

    assert [alert] = active_alerts(ws)
    assert alert.detail =~ "s1" and alert.detail =~ "s2"
    assert watch_of(t1)["state"] == "alerted"
    assert watch_of(t2)["state"] == "alerted"

    # The outage ends: a later pipeline deploys, containing both commits.
    forge(
      %{"!7" => "s1", "!8" => "s2"},
      [
        pipeline(73, "s3", "success", [{"deploy", "success"}]),
        pipeline(72, "s2", "success", [{"deploy", "skipped"}]),
        pipeline(71, "s1", "success", [{"deploy", "skipped"}])
      ],
      [{"s1", "s3"}, {"s2", "s3"}]
    )

    sweep(ws)

    assert watch_of(t1)["state"] == "deployed"
    assert watch_of(t2)["state"] == "deployed"
    assert active_alerts(ws) == []
  end
end
