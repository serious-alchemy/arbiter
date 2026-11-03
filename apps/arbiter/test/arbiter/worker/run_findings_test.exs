defmodule Arbiter.Worker.RunFindingsTest do
  use Arbiter.DataCase, async: true

  import Arbiter.LifecycleFixtures, only: [put_state!: 2]

  alias Arbiter.Actor
  alias Arbiter.Tasks.{Issue, Workspace}
  alias Arbiter.Worker.RunFindings
  alias Arbiter.Workers.Run

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "run-findings-#{System.unique_integer([:positive])}",
        prefix: "rf",
        config: %{}
      })

    {:ok, task} = Ash.create(Issue, %{title: "t", workspace_id: ws.id, issue_type: :research})
    %{task: put_state!(task, :active)}
  end

  defp write!(task, actor, input) do
    {:ok, fresh} = Ash.get(Issue, task.id)

    Actor.with_actor(actor, fn ->
      {:ok, _} = Ash.update(fresh, input, action: :update)
    end)
  end

  defp earlier(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  test "true for the ticket's own worker actor inside the window", %{task: task} do
    since = earlier(60)
    write!(task, Actor.worker(task.id), %{notes: "found it"})
    assert RunFindings.written?(task.id, since) == true
  end

  test "false with no notes write at all", %{task: task} do
    assert RunFindings.written?(task.id, earlier(60)) == false
  end

  test "false for another actor, and for another ticket's worker", %{task: task} do
    since = earlier(60)
    write!(task, Actor.coordinator(), %{notes: "coordinator context"})
    write!(task, Actor.worker("bd-other"), %{notes: "someone else"})
    assert RunFindings.written?(task.id, since) == false
  end

  test "false when the worker only changed a non-notes field", %{task: task} do
    since = earlier(60)
    write!(task, Actor.worker(task.id), %{title: "renamed"})
    assert RunFindings.written?(task.id, since) == false
  end

  test "a write before the window does not count", %{task: task} do
    write!(task, Actor.worker(task.id), %{notes: "earlier"})
    assert RunFindings.written?(task.id, DateTime.add(DateTime.utc_now(), 60, :second)) == false
  end

  describe "window_start/2" do
    defp run!(attrs) do
      Ash.create!(
        Run,
        Map.merge(
          %{
            task_id: "bd-chain-#{System.unique_integer([:positive])}",
            kind: :implement,
            repo: "arbiter",
            state: :finished,
            outcome: :failed
          },
          attrs
        )
      )
    end

    test "is the run's own start when it was not resumed" do
      started = earlier(10)
      assert RunFindings.window_start(started, nil) == started
    end

    test "reaches back to the first run in a resume chain" do
      first = run!(%{started_at: earlier(300)})
      second = run!(%{started_at: earlier(200), resumed_from_run_id: first.id})
      started = earlier(10)

      assert DateTime.compare(RunFindings.window_start(started, second.id), first.started_at) ==
               :eq
    end

    test "an unknown prior run falls back to the run's own start" do
      started = earlier(10)
      assert RunFindings.window_start(started, Ecto.UUID.generate()) == started
    end
  end
end
