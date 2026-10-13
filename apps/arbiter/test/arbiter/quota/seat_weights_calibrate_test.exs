defmodule Arbiter.Quota.SeatWeightsCalibrateTest do
  @moduledoc """
  DC11 (bd-8lsfey): `SeatWeights.calibrate/1` end to end through the three
  tables it reads — `quota_snapshots` and `usage_events` (R3's per-model fit,
  `Arbiter.Loop.Scarcity.Draw`) and `worker_runs` (the run-hours behind the
  tokens per seat-hour). Read-only.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Scarcity
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Quota.SeatWeights
  alias Arbiter.Usage
  alias Arbiter.Workers.Run

  @t0 ~U[2026-10-01 00:00:00Z]
  @truth %{"opus" => 4.0e-7, "sonnet" => 1.0e-7}

  defp at(minutes), do: DateTime.add(@t0, round(minutes * 60), :second)

  defp snapshot!(account, minutes, util) do
    Ash.create!(QuotaSnapshot, %{
      provider_account_id: account,
      provider: "claude",
      bucket: "claude",
      window: "5h",
      utilization: util,
      resets_at: at(300),
      captured_at: at(minutes)
    })
  end

  # A ten-minute run of `model` that drew `tokens` output tokens.
  defp run_with_event!(account, model, start, tokens) do
    run =
      Ash.create!(Run, %{
        task_id: "bd-w#{System.unique_integer([:positive])}",
        workspace_id: "ws",
        repo: "arbiter",
        provider: "claude",
        model: model,
        provider_account_id: account,
        started_at: at(start),
        completed_at: at(start + 10)
      })

    Ash.create!(Usage.Event, %{
      step: :other,
      source: :maintenance,
      provider: "claude",
      model: model,
      provider_account_id: account,
      worker_run_id: run.id,
      occurred_at: at(start + 5),
      tokens_out: tokens
    })
  end

  # Twelve 30-minute intervals, each with its own opus/sonnet mix, noise-free.
  defp seed!(account) do
    {totals, utils} =
      Enum.reduce(0..11, {%{"opus" => 0, "sonnet" => 0}, [{0, 0.0}]}, fn i,
                                                                         {sums,
                                                                          [{_, u} | _] = acc} ->
        opus = 1000 + 700 * rem(i * 5, 7)
        sonnet = 900 + 450 * rem(i * 3, 5)
        run_with_event!(account, "opus", i * 30 + 5, opus)
        run_with_event!(account, "sonnet", i * 30 + 15, sonnet)
        share = (@truth["opus"] * opus + @truth["sonnet"] * sonnet) * 5.0

        {%{sums | "opus" => sums["opus"] + opus, "sonnet" => sums["sonnet"] + sonnet},
         [{(i + 1) * 30, u + share} | acc]}
      end)

    Enum.each(utils, fn {m, u} -> snapshot!(account, m, u) end)
    totals
  end

  test "weights come from R3's per-model draw: the model that draws more per run-hour weighs more" do
    account = Ecto.UUID.generate()
    totals = seed!(account)

    assert [%{account_id: ^account, pool: "claude", window: "5h", weights: weights}] =
             SeatWeights.calibrate(since: at(-10), until: at(1000))

    # Both models ran the same hours, so the ratio is c_m × tokens_m.
    expected_ratio =
      @truth["opus"] * Scarcity.weighted_tokens(%{tokens_out: totals["opus"]}) /
        (@truth["sonnet"] * Scarcity.weighted_tokens(%{tokens_out: totals["sonnet"]}))

    assert_in_delta weights["opus"] / weights["sonnet"], expected_ratio, 1.0e-3
    assert weights["opus"] > 1.0 and weights["sonnet"] < 1.0
    # Equal run-hours: the mix averages one seat per seat.
    assert_in_delta (weights["opus"] + weights["sonnet"]) / 2, 1.0, 1.0e-9
  end

  test "an account with too little history gets no weights, never a fabricated 1" do
    account = Ecto.UUID.generate()
    snapshot!(account, 0, 0.0)
    snapshot!(account, 30, 0.1)
    run_with_event!(account, "opus", 5, 1000)

    assert SeatWeights.calibrate(since: at(-10), until: at(1000)) == []
  end

  test "calibrating writes nothing" do
    account = Ecto.UUID.generate()
    seed!(account)

    before =
      {length(Ash.read!(QuotaSnapshot)), length(Ash.read!(Usage.Event)), length(Ash.read!(Run))}

    _ = SeatWeights.calibrate(since: at(-10), until: at(1000))

    assert {length(Ash.read!(QuotaSnapshot)), length(Ash.read!(Usage.Event)),
            length(Ash.read!(Run))} ==
             before
  end
end
