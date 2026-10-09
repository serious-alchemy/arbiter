defmodule Arbiter.Worker.SpendCapParkTest do
  # G19: `Worker.park_spend_cap/2` stops a live run on a spend cap, with the typed
  # `:spend_cap` cause, and refuses a run that is not live.
  use Arbiter.DataCase, async: false

  alias Arbiter.Worker
  alias Arbiter.Worker.ClaudeSession
  alias Arbiter.Worker.StopReason
  alias Arbiter.Workers.Run

  require Ash.Query

  @reason %{cap: :wall_clock_s, limit: 1800, measured: 3900, tier: :quarantine}

  defp live_worker do
    task_id = "bd-spendcap-#{System.unique_integer([:positive])}"
    {:ok, pid} = Worker.start(task_id: task_id, repo: "arbiter", workspace_id: "ws-runs")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)

    :ok = Worker.advance(pid, :claude)

    {:ok, port} =
      ClaudeSession.start(
        owner: pid,
        worktree_path: System.tmp_dir!(),
        command: ["sh", "-c", "sleep 30"]
      )

    {pid, port, task_id}
  end

  test "parks a live run: agent stopped, run failed with the spend_cap cause" do
    {pid, port, task_id} = live_worker()
    assert Port.info(port) != nil

    assert :ok = Worker.park_spend_cap(pid, StopReason.spend_cap(@reason))

    assert %{state: :finished, outcome: :failed, meta: meta} = Worker.state(pid)
    assert meta.stop_reason.category == :spend_cap
    assert meta.failure_reason =~ "spend cap reached"
    assert Port.info(port) == nil

    [run] = Run |> Ash.Query.filter(task_id == ^task_id) |> Ash.read!()
    assert run.stop_category == "spend_cap"
  end

  test "refuses a run that is already finished" do
    {pid, _port, _task_id} = live_worker()
    reason = StopReason.spend_cap(@reason)
    assert :ok = Worker.park_spend_cap(pid, reason)

    assert {:error, {:invalid_transition, :finished, :park_spend_cap}} =
             Worker.park_spend_cap(pid, reason)
  end
end
