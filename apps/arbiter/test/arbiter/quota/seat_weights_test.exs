defmodule Arbiter.Quota.SeatWeightsTest do
  @moduledoc """
  DC11 (bd-8lsfey; `docs/design/provider-dynamic-concurrency.md` §3.4 phase 2,
  §8 R11): a seat weighs `ρ_m / ρ̄`, with `ρ_m = c_m × weighted tokens per
  seat-hour of m` and `c_m` from R3's per-model draw fit
  (`Arbiter.Loop.Scarcity.Draw`). A model whose coefficient fails the
  confidence-bound test weighs 1, and no weight falls below the floor.
  """
  use ExUnit.Case, async: true

  alias Arbiter.Quota.SeatWeights

  @t0 ~U[2026-10-01 00:00:00Z]

  defp at(hours), do: DateTime.add(@t0, round(hours * 3600), :second)

  # A calibrated per-model entry; `se` small enough that c - t·se > 0.
  defp entry(c, se \\ nil) do
    %{
      status: :calibrated,
      reason: nil,
      share_per_weighted_token: c,
      std_error: se || c / 20,
      n: 12
    }
  end

  defp fit(models, dof \\ 10), do: %{status: :calibrated, models: models, dof: dof}

  defp rate(tau, hours), do: %{tau: tau, hours: hours, tokens: tau * hours}

  describe "rates/3: weighted tokens per run-hour of each model" do
    test "tokens of the events on a run over the run's hours, by the run's dominant model" do
      runs = [
        %{id: "r1", started_at: at(0), completed_at: at(2)},
        %{id: "r2", started_at: at(2), completed_at: at(3)}
      ]

      events = [
        %{worker_run_id: "r1", model: "opus", tokens_in: 1000, tokens_out: 0},
        %{worker_run_id: "r1", model: "opus", tokens_in: 1000, tokens_out: 0},
        %{worker_run_id: "r2", model: "sonnet", tokens_in: 500, tokens_out: 0}
      ]

      rates = SeatWeights.rates(events, runs, at(10))

      assert_in_delta rates["opus"].hours, 2.0, 1.0e-9
      assert_in_delta rates["sonnet"].hours, 1.0, 1.0e-9
      assert_in_delta rates["opus"].tau, rates["opus"].tokens / 2.0, 1.0e-9
      assert rates["opus"].tokens > rates["sonnet"].tokens
    end

    test "an open run is charged until `until`; events without a known run are ignored" do
      runs = [%{id: "r1", started_at: at(0), completed_at: nil}]

      events = [
        %{worker_run_id: "r1", model: "opus", tokens_in: 1000, tokens_out: 0},
        %{worker_run_id: "gone", model: "opus", tokens_in: 9999, tokens_out: 0},
        %{worker_run_id: nil, model: "opus", tokens_in: 9999, tokens_out: 0}
      ]

      rates = SeatWeights.rates(events, runs, at(4))

      assert_in_delta rates["opus"].hours, 4.0, 1.0e-9

      assert rates["opus"].tokens ==
               Arbiter.Loop.Scarcity.weighted_tokens(%{tokens_in: 1000, tokens_out: 0})
    end

    test "no runs, no rates" do
      assert SeatWeights.rates([], [], at(1)) == %{}
    end
  end

  describe "weights/2: ρ_m / ρ̄" do
    test "a model that draws twice as fast per seat-hour weighs twice another; the mix averages 1" do
      fit = fit(%{"opus" => entry(2.0e-6), "sonnet" => entry(1.0e-6)})
      # Same tokens per seat-hour: the coefficient is the whole difference.
      rates = %{"opus" => rate(1000.0, 10.0), "sonnet" => rate(1000.0, 10.0)}

      weights = SeatWeights.weights(fit, rates)

      assert_in_delta weights["opus"] / weights["sonnet"], 2.0, 1.0e-9
      # ρ̄ is the seat-hour-weighted mean: opus 10 h, sonnet 10 h → (2 + 1) / 2.
      assert_in_delta (weights["opus"] * 10 + weights["sonnet"] * 10) / 20, 1.0, 1.0e-9
    end

    test "tokens per seat-hour count as well as the coefficient" do
      fit = fit(%{"a" => entry(1.0e-6), "b" => entry(1.0e-6)})
      rates = %{"a" => rate(3000.0, 5.0), "b" => rate(1000.0, 5.0)}

      weights = SeatWeights.weights(fit, rates)

      assert_in_delta weights["a"] / weights["b"], 3.0, 1.0e-9
    end

    test "a coefficient the data cannot tell from 0 is left out (its seats weigh 1)" do
      noisy = entry(1.0e-6, 1.0e-6)
      fit = fit(%{"opus" => entry(2.0e-6), "sonnet" => entry(1.0e-6), "haiku" => noisy})
      rates = Map.new(["opus", "sonnet", "haiku"], &{&1, rate(1000.0, 10.0)})

      weights = SeatWeights.weights(fit, rates)

      refute Map.has_key?(weights, "haiku")
      assert Map.has_key?(weights, "opus")
    end

    test "an uncalibrated entry, a model with no rate and a missing dof are left out" do
      absent = %{
        status: :insufficient_data,
        reason: :non_positive,
        share_per_weighted_token: nil,
        std_error: nil,
        n: 3
      }

      fit = fit(%{"opus" => entry(2.0e-6), "x" => absent, "norate" => entry(1.0e-6)})
      weights = SeatWeights.weights(fit, %{"opus" => rate(1000.0, 10.0), "x" => rate(1.0, 1.0)})

      assert Map.keys(weights) == ["opus"]
      assert SeatWeights.weights(%{fit | dof: nil}, %{"opus" => rate(1000.0, 10.0)}) == %{}
    end

    test "an insufficient fit gives no weights" do
      assert SeatWeights.weights(
               %{status: :insufficient_data, models: %{}, dof: nil},
               %{"opus" => rate(1.0, 1.0)}
             ) == %{}
    end

    test "a model with no hours has no weight" do
      fit = fit(%{"opus" => entry(2.0e-6)})
      assert SeatWeights.weights(fit, %{"opus" => rate(0.0, 0.0)}) == %{}
    end
  end

  describe "weight/3: what a seat weighs at admission" do
    test "an unknown or unweighted model weighs 1" do
      assert SeatWeights.weight(%{"opus" => 2.0}, nil, 0.25) == 1.0
      assert SeatWeights.weight(%{"opus" => 2.0}, "sonnet", 0.25) == 1.0
      assert SeatWeights.weight(%{}, "opus", 0.25) == 1.0
      assert SeatWeights.weight(nil, "opus", 0.25) == 1.0
    end

    test "a routed alias finds the resolved ids it names; several are averaged" do
      weights = %{"claude-opus-4-8" => 3.0, "claude-opus-4-7" => 2.0, "claude-sonnet-4-5" => 0.5}

      assert SeatWeights.weight(weights, "opus", 0.25) == 2.5
      assert SeatWeights.weight(weights, "claude-sonnet-4-5[1m]", 0.25) == 0.5
      assert SeatWeights.weight(weights, "Sonnet", 0.25) == 0.5
      assert SeatWeights.weight(weights, "haiku", 0.25) == 1.0
    end

    test "a weighted model weighs its weight, never below the floor" do
      assert SeatWeights.weight(%{"opus" => 2.5}, "opus", 0.25) == 2.5
      assert SeatWeights.weight(%{"haiku" => 0.01}, "haiku", 0.25) == 0.25
    end
  end

  describe "who reads the weights (I1, I2, I8)" do
    @lib Path.expand("../../../lib", __DIR__)
    @consumers ~r/SeatWeights|\bseat_weights\(/

    # The calibration, the budget server that runs and holds it, and the two
    # readers that weigh seats: the seat check (enforce only) and the walk's
    # inputs (shadow and enforce). Nothing that stops a run, and no gate or
    # dispatch path, names it.
    @allowed ~w(
      arbiter/quota/seat_weights.ex
      arbiter/quota/seats.ex
      arbiter/quota/budget/server.ex
      arbiter/accounts/seat_check.ex
      arbiter/board/walk_inputs.ex
    )

    test "only the seat check and the walk's inputs read the weights" do
      offenders =
        @lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&(Path.relative_to(&1, @lib) in @allowed))
        |> Enum.filter(&(File.read!(&1) =~ @consumers))
        |> Enum.map(&Path.relative_to(&1, @lib))

      assert offenders == []
    end
  end
end
