defmodule Arbiter.Usage.BudgetPatrolTest do
  @moduledoc """
  The system alert raised while an open task's worker spend is past its
  estimate group's p90 (bd-8j9i9p AC5, operator decision 2026-09-15), and
  cleared once it is not (bd-7gt8rm).

  It informs; it does not intervene. Nothing here stops a worker, pauses
  anything or trips the circuit breaker — the point is that someone gets to
  say whether the overrun is expected.
  """

  # async: false — the sweep reads the whole ledger and the whole issue table.
  use Arbiter.DataCase, async: false

  alias Arbiter.Alerts
  alias Arbiter.Alerts.SystemAlert
  alias Arbiter.Messages.CoordinatorNotifier
  alias Arbiter.Messages.Message
  alias Arbiter.Tasks.Issue
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.BudgetPatrol
  alias Arbiter.Usage.Event

  require Ash.Query

  @now ~U[2026-09-15 12:00:00.000000Z]

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "patrol-ws-#{System.unique_integer([:positive])}",
        prefix: "pw"
      })

    # n=10 closed D2 features costing $1..$10 → p25 $3, p75 $8, p90 $9.
    Enum.each(1..10, fn n ->
      issue = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(issue.id, ws, %{cost_usd: n * 1.0})
    end)

    %{ws: ws}
  end

  defp open_issue!(ws, attrs) do
    {:ok, issue} =
      Ash.create(Issue, Map.merge(%{title: "patrol subject", workspace_id: ws.id}, attrs))

    issue
  end

  defp closed_issue!(ws, attrs) do
    issue = open_issue!(ws, attrs)
    {:ok, closed} = Ash.update(issue, %{close_upstream: false}, action: :close)
    closed
  end

  defp event!(task_id, ws, attrs) do
    base = %{
      task_id: task_id,
      base_task_id: task_id,
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ws.id,
      occurred_at: @now
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  # The active budget alerts shown in the workspace.
  defp alerts(ws), do: Alerts.active(kind: :budget_exceeded, workspace_id: ws.id)

  # Every budget alert row for the workspace, active or cleared.
  defp all_alerts(ws) do
    ws_id = ws.id

    SystemAlert
    |> Ash.Query.filter(workspace_id == ^ws_id and kind == :budget_exceeded)
    |> Ash.read!()
  end

  defp escalations(ws), do: Message.inbox(Message.coordinator_ref(), workspace_id: ws.id)

  describe "sweep/1" do
    test "an open task past p90 raises one operator alert naming the numbers, and no escalation",
         %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature, title: "runaway task"})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [alert] = alerts(ws)
      assert alert.key == task.id
      assert alert.owner == :operator
      assert alert.subject =~ task.id
      # The fields needed to judge whether this is expected.
      assert alert.detail =~ "runaway task"
      assert alert.detail =~ "$40.00"
      assert alert.detail =~ "$3.00"
      assert alert.detail =~ "$9.00"
      assert alert.detail =~ "difficulty+type"
      assert alert.detail =~ "n=10"
      assert alert.detail =~ "D2"
      # And the copy is honest about what the figure covers.
      assert alert.detail =~ "worker spend"
      assert escalations(ws) == []
    end

    test "a second sweep refreshes the one alert with the new figure", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)
      # More spend arrives, and the sweep runs again — as it does every tick.
      event!(task.id, ws, %{cost_usd: 10.0, step: :review})
      assert :ok = BudgetPatrol.sweep(now: @now)
      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [alert] = all_alerts(ws)
      assert alert.detail =~ "$50.00"
      assert is_nil(alert.cleared_at)
    end

    test "the threshold moving above the spend clears the alert", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)
      assert [alert] = alerts(ws)

      # Ten more D2 features closed at $100 each: the group's p90 is now well
      # past $40, so the task is back under budget.
      Enum.each(1..10, fn _ ->
        issue = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
        event!(issue.id, ws, %{cost_usd: 100.0})
      end)

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert alerts(ws) == []
      assert Ash.get!(SystemAlert, alert.id).cleared_at
    end

    test "closing the task clears its alert", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)
      assert [_] = alerts(ws)

      {:ok, _} = Ash.update(task, %{close_upstream: false}, action: :close)
      assert :ok = BudgetPatrol.sweep(now: @now)

      assert alerts(ws) == []
    end

    test "a sweep that fails clears nothing", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})
      assert :ok = BudgetPatrol.sweep(now: @now)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          assert :ok = BudgetPatrol.sweep(now: @now, sample: [%{}])
        end)

      assert log =~ "BudgetPatrol.sweep failed"

      assert [_] = alerts(ws)
    end

    test "a closed task that ran over is never alerted", %{ws: ws} do
      task = closed_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [] = alerts(ws)
    end

    test "a restart does not re-raise or re-announce an alert that is already open", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})
      assert :ok = BudgetPatrol.sweep(now: @now)
      assert [alert] = alerts(ws)

      Phoenix.PubSub.subscribe(Arbiter.PubSub, Arbiter.Events.pubsub_topic(ws.id))

      # A boot is a fresh patrol process running its first sweep.
      pid = start_supervised!({BudgetPatrol, name: nil, enabled: false})
      assert :ok = BudgetPatrol.poll(pid)

      assert [same] = all_alerts(ws)
      assert same.id == alert.id
      refute_receive {:event, %{topic: "inbox", kind: "alert", event: "raised"}}, 100
    end

    test "a finished task awaiting verification with no worker is not alerted, and its alert clears",
         %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})
      assert :ok = BudgetPatrol.sweep(now: @now)
      assert [_] = alerts(ws)

      _ = Arbiter.LifecycleFixtures.put_state!(Ash.get!(Issue, task.id), :verifying)
      assert :ok = BudgetPatrol.sweep(now: @now, workers: [])

      assert alerts(ws) == []
    end

    test "a task under p90 is not alerted", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 8.5})

      assert :ok = BudgetPatrol.sweep(now: @now)

      assert [] = alerts(ws)
    end

    test "a task with no estimate is never alerted, however much it has spent", %{ws: ws} do
      # D4 has no history of its own, and `min_n: 10` keeps it off the global
      # rung too — so there is no p90 to be over.
      task = open_issue!(ws, %{difficulty: 4, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 500.0})

      assert :ok = BudgetPatrol.sweep(now: @now, min_n: 11)

      assert [] = alerts(ws)
    end
  end

  # The sweep above is called directly; this drives the process the
  # application actually supervises — `init/1` -> a `:poll` call -> the same
  # sweep — so the GenServer wiring is proven, not just the function under it.
  # bd-8vnuy3: the patrol reads the same live-inclusive figure the issue page
  # shows, so a runaway pass pages *while it runs*, not after it ends.
  describe "sweep/1 against live spend" do
    setup do
      root = Path.join(System.tmp_dir!(), "patrol-live-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      %{config_dir: Path.join(root, "claude"), cwd: Path.join(root, "wt")}
    end

    # A live claude worker whose in-flight session has spent `dollars` so far
    # (claude-sonnet-5: 100_000 output tokens = $1.00).
    defp live_pass!(ctx, task_id, dollars) do
      now = DateTime.utc_now()
      slug = Arbiter.Usage.ClaudeSessionFile.project_slug(ctx.cwd)
      dir = Path.join([ctx.config_dir, "projects", slug])
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "sid-#{task_id}.jsonl"),
        Jason.encode!(%{
          "type" => "assistant",
          "timestamp" => now |> DateTime.add(-60, :second) |> DateTime.to_iso8601(),
          "message" => %{
            "id" => "m-#{task_id}",
            "model" => "claude-sonnet-5",
            "usage" => %{"input_tokens" => 0, "output_tokens" => round(dollars * 100_000)}
          }
        }) <> "\n"
      )

      %{
        task_id: task_id,
        agent_live: true,
        started_at: DateTime.add(now, -600, :second),
        status: :running,
        current_step: :implement,
        meta: %{config_dir: ctx.config_dir, cwd: ctx.cwd, provider: "claude"}
      }
    end

    test "a pass that is still running raises the alert once it is past p90, and only one",
         %{ws: ws} = ctx do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature, title: "runaway pass"})
      # Settled: $4 — under p75. The pass in flight has burned $30 more.
      event!(task.id, ws, %{cost_usd: 4.0})
      workers = [live_pass!(ctx, task.id, 30.0)]

      assert :ok = BudgetPatrol.sweep(now: @now, workers: workers)

      assert [alert] = alerts(ws)
      assert alert.detail =~ "$34.00"
      assert alert.detail =~ "≈$30.00 of that is an in-flight estimate"

      assert :ok = BudgetPatrol.sweep(now: @now, workers: workers)
      assert [_only_one] = all_alerts(ws)
    end

    test "without the live pass the same task is not over", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 4.0})

      assert :ok = BudgetPatrol.sweep(now: @now, workers: [])
      assert [] = alerts(ws)
    end
  end

  describe "the supervised ticker" do
    test "a poll on the running process raises the alert the same way", %{ws: ws} do
      task = open_issue!(ws, %{difficulty: 2, issue_type: :feature})
      event!(task.id, ws, %{cost_usd: 40.0})

      pid = start_supervised!({BudgetPatrol, name: nil, enabled: false})

      assert :ok = BudgetPatrol.poll(pid)

      assert [alert] = alerts(ws)
      assert alert.subject == CoordinatorNotifier.budget_exceeded_subject(task.id)
    end
  end
end
