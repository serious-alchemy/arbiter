defmodule Arbiter.Quota.BudgetCalibrationShadowTest do
  @moduledoc """
  DC2 is shadow only (bd-c1dief; design §10, I1/I2): the seat-hour calibration
  reads the history and prints; it never writes, and no admission, gate,
  dispatch or board module consumes it. Until DC8 nothing may change a
  dispatch decision, and these tests pin the construction.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Quota.BudgetCalibration
  alias Arbiter.Quota.QuotaSnapshot

  @lib Path.expand("../../../lib", __DIR__)
  @consumers ~r/BudgetCalibration|budget_calibration/

  # The only files allowed to name the calibration: its own module, the two
  # operator entry points, the admission shadow report (DC7), the budget that consumes it (DC3, bd-6c8g4t: its pure
  # function, server and inputs), and two moduledocs that point at it (`Draw` shares its
  # intervals; `QuotaSnapshot` documents the columns).
  @allowed ~w(
    arbiter/quota/budget_calibration.ex
    arbiter/quota/budget.ex
    arbiter/quota/budget/inputs.ex
    arbiter/quota/budget/server.ex
    arbiter/loop/scarcity/draw.ex
    arbiter/quota/quota_snapshot.ex
    arbiter/release.ex
    mix/tasks/arbiter.budget_calibration.ex
    board/admission_shadow_report.ex
  )

  test "no admission, gate, dispatch, scheduler or board module reads the calibration" do
    offenders =
      @lib
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(Path.relative_to(&1, @lib) in @allowed))
      |> Enum.filter(&(File.read!(&1) =~ @consumers))
      |> Enum.map(&Path.relative_to(&1, @lib))

    assert offenders == []
  end

  test "the web app does not read it either" do
    web = Path.expand("../../../../arbiter_web/lib", __DIR__)

    offenders =
      web
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ @consumers))

    assert offenders == []
  end

  test "the admission surfaces never name the calibration or its persisted columns" do
    surfaces = ~w(
      accounts/admission.ex
      accounts/concurrency.ex
      quota/gate.ex
      board/autopilot.ex
      board/scheduler.ex
      workflows/dispatch_queue.ex
    )

    for rel <- surfaces, File.exists?(Path.join(@lib, rel)) do
      source = File.read!(Path.join(@lib, rel))
      refute source =~ @consumers, "#{rel} reads the budget calibration"
      refute source =~ ~r/\.seats\b|\.budget\b/, "#{rel} reads quota_snapshots.seats/budget"
    end
  end

  test "calibrating writes nothing" do
    account = Ecto.UUID.generate()
    t0 = ~U[2026-10-01 00:00:00Z]

    for i <- 0..9 do
      Ash.create!(QuotaSnapshot, %{
        provider_account_id: account,
        provider: "claude",
        bucket: "claude",
        window: "5h",
        utilization: 0.01 * i,
        resets_at: DateTime.add(t0, 300 * 60, :second),
        captured_at: DateTime.add(t0, i * 1800, :second),
        seats: 1
      })
    end

    snapshots = length(Ash.read!(QuotaSnapshot))

    results = BudgetCalibration.calibrate(since: DateTime.add(t0, -1, :second))
    assert [%{rung: rung, rho: rho}] = results
    assert rung in [0, 1, 2] and rho > 0.0
    assert length(Ash.read!(QuotaSnapshot)) == snapshots
  end

  test "Arbiter.Release.budget_calibration/0 prints an empty history, not a fabricated fit" do
    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert Arbiter.Release.budget_calibration(start: false) == []
      end)

    assert output =~ "No quota history"
  end

  test "Arbiter.Release.budget_calibration/0 prints per-pool fits" do
    account = Ecto.UUID.generate()
    t0 = DateTime.add(DateTime.utc_now(), -86_400, :second) |> DateTime.truncate(:second)

    for i <- 0..12 do
      Ash.create!(QuotaSnapshot, %{
        provider_account_id: account,
        provider: "codex",
        bucket: "codex",
        window: "5h",
        utilization: 0.003 * i + 0.002 * rem(i * 3, 4),
        resets_at: DateTime.add(t0, 86_400, :second),
        captured_at: DateTime.add(t0, i * 2400, :second),
        seats: rem(i, 3) + 1
      })
    end

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert [%{pool: "codex", window: "5h"}] = Arbiter.Release.budget_calibration(start: false)
      end)

    assert output =~ "codex / 5h"
    assert output =~ "seat-h"
    assert output =~ "H 2.0 h"
  end

  test "the mix task is wired to the same report" do
    assert Code.ensure_loaded?(Mix.Tasks.Arbiter.BudgetCalibration)
    assert Mix.Task.get("arbiter.budget_calibration") == Mix.Tasks.Arbiter.BudgetCalibration
  end
end
