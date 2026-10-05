defmodule Arbiter.Loop.CanaryMetricsFloorTest do
  @moduledoc """
  bd-c675ny (R8, design §6.4): a floor-clamped dispatch did not get the rule
  its canary arm assigned it, so `Canary.Metrics` leaves it out — of the
  convergence, the cost and the dispatch count the verdict and the
  `min_dispatches` gate read.
  """

  use Arbiter.DataCase, async: false

  alias Arbiter.Loop
  alias Arbiter.Loop.Canary
  alias Arbiter.Loop.Canary.Metrics
  alias Arbiter.ReviewGate.Round
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Workers.Run

  @routing_config %{
    "agent" => %{"type" => "claude", "config" => %{}},
    "routing" => %{"policy" => "by_difficulty"}
  }

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{name: "metrics-floor-ws", prefix: "mf", config: @routing_config})

    {:ok, row} =
      Loop.record(%{
        kind: :config_set,
        gist: "D2 first-pass convergence is 41%: raise D2 to premium/high",
        category: "difficulty misestimate — D2 under-provisioned",
        target: "routing.rules.D2",
        difficulty: 2,
        scope: :fleet,
        target_metric: "first-pass ReviewGate convergence at D2",
        baseline: "41%",
        incident_refs: ["run-a", "run-b", "run-c"],
        task_refs: ["bd-1", "bd-2"],
        payload: %{
          "workspace_id" => ws.id,
          "patch" => %{
            "routing" => %{
              "rules" => %{"D2" => %{"model_tier" => "premium", "thinking" => "high"}}
            }
          }
        },
        origin: "loop.analyze",
        workspace_id: ws.id
      })

    {:ok, ws} =
      Ash.update(ws, %{patch: %{"loop" => %{"autonomous_routing_enabled" => true}}},
        action: :patch_config,
        actor: "operator"
      )

    {:ok, ws} = Canary.start(ws, row, actor: "loop")
    %{ws: ws, canary: Canary.active(ws)}
  end

  defp seed!(ws, task_id, floor_clamped) do
    {:ok, _} =
      Ash.create(Run, %{
        task_id: task_id,
        repo: "arbiter",
        workspace_id: ws.id,
        kind: :implement,
        role: "base",
        state: :finished,
        outcome: :succeeded,
        difficulty_at_dispatch: 2,
        floor_clamped: floor_clamped,
        started_at: DateTime.utc_now()
      })

    {:ok, _} =
      Ash.create(Round, %{
        task_id: task_id,
        round: 1,
        role: :review,
        verdict: :approve,
        converged: true
      })
  end

  defp ids_in(canary, arm, n, prefix) do
    1..5000
    |> Stream.map(&"#{prefix}-#{&1}")
    |> Stream.filter(&(Canary.arm(canary, &1) == arm))
    |> Enum.take(n)
  end

  test "clamped dispatches are left out of the canary arm", %{ws: ws, canary: canary} do
    [kept, legacy, clamped_a, clamped_b] = ids_in(canary, :canary, 4, "mf")

    seed!(ws, kept, false)
    # A run that predates the column reads as not clamped.
    seed!(ws, legacy, nil)
    seed!(ws, clamped_a, true)
    seed!(ws, clamped_b, true)

    stats = Metrics.collect(ws.id, canary)

    assert stats.canary.dispatches == 2
    assert stats.canary.tasks == 2
    assert stats.canary.reviewed_tasks == 2
    assert stats.clamped == 2
  end

  test "and out of the control arm, which did not get its baseline rule either",
       %{ws: ws, canary: canary} do
    [kept, clamped] = ids_in(canary, :control, 2, "mc")

    seed!(ws, kept, false)
    seed!(ws, clamped, true)

    stats = Metrics.collect(ws.id, canary)

    assert stats.control.dispatches == 1
    assert stats.clamped == 1
  end

  test "I1: with nothing clamped the measurement is exactly what it was",
       %{ws: ws, canary: canary} do
    for id <- ids_in(canary, :canary, 3, "mn"), do: seed!(ws, id, false)
    for id <- ids_in(canary, :control, 2, "mo"), do: seed!(ws, id, nil)

    stats = Metrics.collect(ws.id, canary)

    assert stats.canary.dispatches == 3
    assert stats.control.dispatches == 2
    assert stats.clamped == 0
  end
end
