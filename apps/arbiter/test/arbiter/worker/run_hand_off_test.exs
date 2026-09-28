defmodule Arbiter.Worker.RunHandOffTest do
  @moduledoc """
  bd-1uu19b: `handed_off` is the outcome of a run a follow-up run superseded.
  A resume starts a new run linked to the prior one (`resumed_from_run_id`,
  bd-auma3z); a prior row still live — the worker it belonged to went away
  without finishing it — is finished `:handed_off` when the new run starts.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Workers.Run

  defp prior_run(task_id, attrs) do
    Ash.create!(
      Run,
      Map.merge(
        %{
          task_id: task_id,
          repo: "arbiter",
          workspace_id: "ws-hand-off",
          started_at: DateTime.add(DateTime.utc_now(), -600, :second)
        },
        attrs
      )
    )
  end

  defp resume(task_id, prior) do
    {:ok, pid} =
      Worker.start(
        task_id: task_id,
        repo: "arbiter",
        workspace_id: "ws-hand-off",
        meta: %{resume: true, resumed_from_run_id: prior.id}
      )

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  test "an unfinished prior run is handed off to the resumed run" do
    task_id = "bd-handoff-#{System.unique_integer([:positive])}"
    prior = prior_run(task_id, %{state: :working})

    pid = resume(task_id, prior)

    reloaded = Ash.get!(Run, prior.id)
    assert {reloaded.state, reloaded.outcome} == {:finished, :handed_off}
    assert %DateTime{} = reloaded.completed_at
    assert %{state: :starting, outcome: nil} = Worker.state(pid)
  end

  test "a prior run that already finished keeps its own outcome" do
    task_id = "bd-handoff-done-#{System.unique_integer([:positive])}"
    prior = prior_run(task_id, %{state: :finished, outcome: :interrupted})

    resume(task_id, prior)

    reloaded = Ash.get!(Run, prior.id)
    assert {reloaded.state, reloaded.outcome} == {:finished, :interrupted}
  end
end
