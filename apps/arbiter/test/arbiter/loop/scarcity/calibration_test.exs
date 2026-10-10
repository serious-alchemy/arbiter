defmodule Arbiter.Loop.Scarcity.CalibrationTest do
  use ExUnit.Case, async: true

  alias Arbiter.Loop.Scarcity.Calibration

  # Deterministic synthetic fixtures: each observation is one interval between
  # two quota captures, with the weighted tokens each model drew in it and the
  # window-share the provider reported for it (the "truth" is a known
  # coefficient per model, so the fit has an exact answer to recover).
  defp observations(truth, n, opts \\ []) do
    :rand.seed(:exsss, {11, 22, 33})
    background = Keyword.get(opts, :background, 0.0)
    noise = Keyword.get(opts, :noise, 0.0)
    only = Keyword.get(opts, :only)

    for _ <- 1..n do
      hours = 0.5 + :rand.uniform() * 3.0

      draws =
        Map.new(truth, fn {model, _c} ->
          active? = only == nil or :rand.uniform() < only
          {model, if(active?, do: :rand.uniform() * 2_000_000, else: 0.0)}
        end)

      share =
        Enum.reduce(truth, background * hours, fn {m, c}, acc -> acc + c * draws[m] end) +
          (:rand.uniform() - 0.5) * 2 * noise

      %{share: share, hours: hours, draws: draws}
    end
  end

  defp rel_err(actual, expected), do: abs(actual - expected) / expected

  describe "fit/2 on synthetic fixtures" do
    test "recovers known per-model coefficients from noise-free data" do
      truth = %{"opus" => 4.0e-8, "sonnet" => 1.5e-8}
      fit = Calibration.fit(observations(truth, 40))

      assert fit.status == :calibrated
      assert fit.n == 40

      for {model, c} <- truth do
        entry = fit.models[model]
        assert entry.status == :calibrated
        assert rel_err(entry.share_per_weighted_token, c) < 1.0e-6
      end
    end

    test "separates a constant background draw from the model coefficients" do
      truth = %{"opus" => 4.0e-8, "sonnet" => 1.5e-8}
      fit = Calibration.fit(observations(truth, 60, background: 0.004))

      assert rel_err(fit.models["opus"].share_per_weighted_token, 4.0e-8) < 1.0e-6
      assert rel_err(fit.models["sonnet"].share_per_weighted_token, 1.5e-8) < 1.0e-6
      assert rel_err(fit.background_share_per_hour, 0.004) < 1.0e-5
    end

    test "stays close to the truth under bounded noise" do
      truth = %{"opus" => 4.0e-8, "sonnet" => 1.5e-8}
      fit = Calibration.fit(observations(truth, 200, noise: 0.002))

      assert rel_err(fit.models["opus"].share_per_weighted_token, 4.0e-8) < 0.15
      assert rel_err(fit.models["sonnet"].share_per_weighted_token, 1.5e-8) < 0.15
    end

    test "a single model is recovered too" do
      fit = Calibration.fit(observations(%{"gemini-pro" => 2.0e-9}, 20))
      assert rel_err(fit.models["gemini-pro"].share_per_weighted_token, 2.0e-9) < 1.0e-6
    end
  end

  describe "fit/2 absence is never zero" do
    test "too few observations reports insufficient data, with no coefficient at all" do
      fit = Calibration.fit(observations(%{"opus" => 4.0e-8}, 3))

      assert fit.status == :insufficient_data
      assert fit.reason == :too_few_observations
      assert fit.models["opus"].status == :insufficient_data
      assert fit.models["opus"].share_per_weighted_token == nil
    end

    test "no observations at all is insufficient, not an empty calibrated fit" do
      fit = Calibration.fit([])
      assert fit.status == :insufficient_data
      assert fit.models == %{}
      assert fit.background_share_per_hour == nil
    end

    test "a model seen in too few intervals is insufficient while the others calibrate" do
      truth = %{"opus" => 4.0e-8, "rare" => 9.0e-8}
      obs = observations(Map.delete(truth, "rare"), 30)

      obs =
        obs
        |> Enum.with_index()
        |> Enum.map(fn {o, i} ->
          draw = if i < 2, do: 1_000.0, else: 0.0
          %{o | share: o.share + 9.0e-8 * draw, draws: Map.put(o.draws, "rare", draw)}
        end)

      fit = Calibration.fit(obs)

      assert fit.status == :calibrated
      assert fit.models["rare"].status == :insufficient_data
      assert fit.models["rare"].reason == :too_few_model_observations
      assert fit.models["rare"].share_per_weighted_token == nil
      assert rel_err(fit.models["opus"].share_per_weighted_token, 4.0e-8) < 1.0e-3
    end

    test "collinear models are not separable and report no coefficient" do
      obs =
        for i <- 1..20 do
          x = i * 100_000.0
          %{share: 3.0e-8 * x, hours: 1.0, draws: %{"a" => x, "b" => 2 * x}}
        end

      fit = Calibration.fit(obs, background: false)

      assert Enum.any?(fit.models, fn {_m, e} -> e.reason == :collinear end)

      for {_m, e} <- fit.models, e.status == :insufficient_data do
        assert e.share_per_weighted_token == nil
      end
    end

    test "a model the fit drives to zero is reported as non-positive, never as 0.0" do
      truth = %{"opus" => 4.0e-8, "ghost" => 0.0}
      fit = Calibration.fit(observations(truth, 40))

      assert fit.models["ghost"].status == :insufficient_data
      assert fit.models["ghost"].reason == :non_positive
      assert fit.models["ghost"].share_per_weighted_token == nil
      assert rel_err(fit.models["opus"].share_per_weighted_token, 4.0e-8) < 1.0e-6
    end

    test "no calibrated coefficient is ever zero or negative" do
      truth = %{"a" => 1.0e-8, "b" => 3.0e-8, "c" => 0.0}
      fit = Calibration.fit(observations(truth, 50, noise: 0.003, only: 0.6))

      for {_m, e} <- fit.models do
        case e.share_per_weighted_token do
          nil -> assert e.status == :insufficient_data
          c -> assert c > 0.0
        end
      end
    end
  end

  describe "fit/2 standard errors (bd-c1dief, DC2)" do
    # One column, no background: se(c) = sqrt(RSS / (n - 1) / sum x^2).
    test "a single coefficient's standard error matches the closed form" do
      xs = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]
      noise = [0.1, -0.2, 0.15, -0.05, 0.2, -0.1, 0.05, -0.15, 0.1, -0.2]

      obs =
        for {x, e} <- Enum.zip(xs, noise),
            do: %{share: 0.5 * x + e, hours: 1.0, draws: %{"seat" => x}}

      fit = Calibration.fit(obs, background: false)
      entry = fit.models["seat"]
      c = entry.share_per_weighted_token

      rss = obs |> Enum.map(fn o -> (o.share - c * o.draws["seat"]) ** 2 end) |> Enum.sum()
      expected = :math.sqrt(rss / (length(obs) - 1) / Enum.sum(Enum.map(xs, &(&1 * &1))))

      assert_in_delta entry.std_error, expected, 1.0e-9
      assert fit.dof == length(obs) - 1
    end

    test "a background pinned at zero has no standard error and costs no degree of freedom" do
      obs = for x <- 1..10, do: %{share: 0.1 * x, hours: 1.0 / x, draws: %{"seat" => x * 1.0}}
      fit = Calibration.fit(obs)

      assert fit.background_share_per_hour == nil
      assert fit.background_std_error == nil
      assert fit.dof == 9
    end

    test "noise-free data has a zero standard error" do
      obs = for x <- 1..10, do: %{share: 0.1 * x, hours: 1.0, draws: %{"seat" => x * 1.0}}
      fit = Calibration.fit(obs, background: false)
      assert_in_delta fit.models["seat"].std_error, 0.0, 1.0e-9
    end

    test "the background coefficient carries its own standard error" do
      :rand.seed(:exsss, {3, 4, 5})

      obs =
        for _ <- 1..30 do
          h = 0.5 + :rand.uniform() * 3
          s = h * (1 + :rand.uniform())

          %{
            share: 0.05 * s + 0.02 * h + (:rand.uniform() - 0.5) * 0.01,
            hours: h,
            draws: %{"seat" => s}
          }
        end

      fit = Calibration.fit(obs)
      assert fit.models["seat"].std_error > 0.0
      assert fit.background_std_error > 0.0
      assert fit.dof == 28
    end
  end

  describe "t_critical/1" do
    test "one-sided 95% cutoffs" do
      assert_in_delta Calibration.t_critical(8), 1.860, 0.001
      assert_in_delta Calibration.t_critical(1), 6.314, 0.001
      assert_in_delta Calibration.t_critical(30), 1.697, 0.001
      assert_in_delta Calibration.t_critical(1000), 1.646, 0.002
      assert Calibration.t_critical(0) == nil
    end
  end

  describe "nnls/2" do
    test "solves an unconstrained-positive system exactly" do
      # columns [1,0,1], [0,1,1]; b = 2*c1 + 3*c2
      cols = [[1.0, 0.0, 1.0], [0.0, 1.0, 1.0]]
      b = [2.0, 3.0, 5.0]
      assert {:ok, [x1, x2], _blocked} = Calibration.nnls(cols, b)
      assert_in_delta x1, 2.0, 1.0e-9
      assert_in_delta x2, 3.0, 1.0e-9
    end

    test "clamps a coefficient that would go negative to zero" do
      # b = c1 - c2 : unconstrained answer has x2 = -1
      cols = [[1.0, 0.0, 1.0], [0.0, 1.0, 1.0]]
      b = [1.0, -1.0, 0.0]
      assert {:ok, [x1, x2], _} = Calibration.nnls(cols, b)
      assert x2 == 0.0
      assert x1 >= 0.0
    end
  end
end
