defmodule Arbiter.Board.AdmissionLegacyTest do
  @moduledoc """
  I1 at runtime (DC6, provider-dynamic-concurrency §11): under
  `scheduler_admission: legacy` — the default — no admission path calls the
  provider budget, the seats or the walk's inputs. The board read and a whole
  Autopilot pass are traced; nothing in the budget path may be called. Under
  `shadow` the same reads do reach it, so the trace is known to see the calls
  it is looking for.

  `Arbiter.Quota.BudgetShadowTest` pins the same thing structurally: no
  admission surface names the budget at all.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Board.Autopilot
  alias Arbiter.Board.Snapshot
  alias Arbiter.Tasks.{Issue, Workspace}

  @watched [
    Arbiter.Quota.Budget,
    Arbiter.Quota.Budget.Server,
    Arbiter.Quota.Seats,
    Arbiter.Board.WalkInputs
  ]

  setup do
    on_exit(fn -> Arbiter.Settings.set_scheduler_admission(nil) end)

    ws =
      Ash.create!(Workspace, %{
        name: "legacy-#{System.unique_integer([:positive])}",
        prefix: "lg#{System.unique_integer([:positive])}"
      })

    created =
      Ash.create!(Issue, %{title: "ready", workspace_id: ws.id, acceptance: "- legacy fixture"})

    ready = Ash.update!(created, %{}, action: :promote_to_ready)
    %{ws: ws, ready: ready}
  end

  # Every call into a watched module made by `pids` while `fun` runs.
  defp calls(pids, fun) do
    Enum.each(@watched, &Code.ensure_loaded!/1)
    Enum.each(@watched, &:erlang.trace_pattern({&1, :_, :_}, true, [:local]))
    Enum.each(pids, &:erlang.trace(&1, true, [:call, {:tracer, self()}]))

    try do
      fun.()
    after
      Enum.each(pids, fn pid -> if Process.alive?(pid), do: :erlang.trace(pid, false, [:call]) end)

      Enum.each(@watched, &:erlang.trace_pattern({&1, :_, :_}, false, [:local]))
    end

    collect([])
  end

  defp collect(acc) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        collect([{module, function, length(args)} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp autopilot do
    test = self()

    {:ok, pid} =
      Autopilot.start_link(
        name: nil,
        paused: false,
        interval_ms: :never,
        topics: [],
        follow_up: false,
        registry_settled?: fn -> true end,
        dispatch: fn id, extra ->
          send(test, {:dispatched, id, extra})
          {:ok, %{task_id: id}}
        end
      )

    pid
  end

  test "legacy: the board read calls nothing in the budget path", %{ws: ws, ready: ready} do
    assert [] =
             calls([self()], fn ->
               send(self(), {:board, Snapshot.load(workspace_id: ws.id)})
             end)

    assert_received {:board, board}
    assert board.promote == ready.id
    refute Map.has_key?(board, :walk)
  end

  test "legacy: a whole Autopilot pass calls nothing in the budget path, and dispatches as today",
       %{ready: ready} do
    pid = autopilot()

    assert [] = calls([pid], fn -> assert {:ok, _} = Autopilot.tick(pid, 10_000) end)

    ready_id = ready.id
    assert_received {:dispatched, ^ready_id, []}
  end

  test "shadow: the same pass reaches the budget, the seats and the walk's inputs",
       %{ready: ready} do
    {:ok, "shadow"} = Arbiter.Settings.set_scheduler_admission("shadow")
    pid = autopilot()

    seen = calls([pid], fn -> assert {:ok, _} = Autopilot.tick(pid, 10_000) end)

    assert {Arbiter.Board.WalkInputs, :gather, 3} in seen
    assert {Arbiter.Quota.Budget.Server, :all, 0} in seen
    assert {Arbiter.Quota.Seats, :counts, 0} in seen

    # And today's card still goes, with the walk's decision beside it.
    ready_id = ready.id
    assert_received {:dispatched, ^ready_id, [admission_shadow: %{"policy" => "shadow"}]}
  end
end
