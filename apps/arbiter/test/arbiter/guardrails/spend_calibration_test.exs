defmodule Arbiter.Guardrails.SpendCalibrationTest do
  @moduledoc """
  G19: re-derive the tier spend caps from the usage ledger — per-task token and
  wall-clock totals by provider, as percentiles, so a cap can be set against what
  real runs of that provider cost.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Guardrails.SpendCalibration
  alias Arbiter.Tasks.Workspace
  alias Arbiter.Usage.Event

  setup do
    {:ok, ws} =
      Ash.create(Workspace, %{
        name: "calib-#{System.unique_integer([:positive])}",
        prefix: "ca#{System.unique_integer([:positive])}"
      })

    %{ws: ws}
  end

  defp row!(ws, task_id, attrs) do
    base = %{
      task_id: task_id,
      base_task_id: task_id,
      source: :task,
      step: :work,
      role: "base",
      workspace_id: ws.id,
      occurred_at: DateTime.utc_now()
    }

    {:ok, ev} = Ash.create(Event, Map.merge(base, attrs))
    ev
  end

  test "percentiles of per-task tokens and wall-clock, per provider", %{ws: ws} do
    # Ten antigravity tasks of 1M..10M tokens and 10..100 minutes.
    for n <- 1..10 do
      row!(ws, "cal-#{n}", %{
        provider: "antigravity",
        tokens_in: n * 900_000,
        tokens_out: n * 100_000,
        duration_ms: n * 10 * 60_000
      })
    end

    # A claude task must not leak into antigravity's figures.
    row!(ws, "cal-claude", %{provider: "claude", tokens_in: 99_000_000, duration_ms: 1})

    assert %{"antigravity" => agy} = SpendCalibration.report(workspace_id: ws.id)

    assert agy.tasks == 10
    assert agy.tokens.p50 == 5_000_000
    assert agy.tokens.p90 == 9_000_000
    assert agy.tokens.max == 10_000_000
    assert agy.wall_clock_s.p50 == 50 * 60
    assert agy.wall_clock_s.max == 100 * 60
  end

  test "a task's passes are summed, and rows with no tokens count zero", %{ws: ws} do
    row!(ws, "cal-one", %{
      provider: "codex",
      tokens_in: 1_000,
      tokens_out: 500,
      duration_ms: 60_000
    })

    row!(ws, "cal-one", %{provider: "codex", tokens_in: nil, tokens_out: nil, duration_ms: 60_000})

    assert %{"codex" => codex} = SpendCalibration.report(workspace_id: ws.id)
    assert codex.tasks == 1
    assert codex.tokens.max == 1_500
    assert codex.wall_clock_s.max == 120
  end

  test "an empty ledger is an empty report", %{ws: ws} do
    assert SpendCalibration.report(workspace_id: ws.id) == %{}
  end
end
