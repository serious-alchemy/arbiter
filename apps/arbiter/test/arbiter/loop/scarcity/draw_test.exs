defmodule Arbiter.Loop.Scarcity.DrawTest do
  @moduledoc """
  R3 (bd-3is1nz): window share per weighted token per (pool, window, model),
  calibrated from `quota_snapshots` deltas against `usage_events`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Loop.Scarcity
  alias Arbiter.Loop.Scarcity.Draw
  alias Arbiter.Quota.QuotaSnapshot
  alias Arbiter.Usage

  @t0 ~U[2026-10-01 00:00:00Z]

  defp at(minutes), do: DateTime.add(@t0, minutes * 60, :second)

  defp sample(minutes, util, reset_minutes \\ 300) do
    %{utilization: util, resets_at: at(reset_minutes), captured_at: at(minutes)}
  end

  defp usage(minutes, model, tokens_out, provider \\ "claude") do
    %{
      occurred_at: at(minutes),
      provider: provider,
      model: model,
      tokens_in: 0,
      tokens_out: tokens_out,
      cache_creation_tokens: 0,
      cache_read_tokens: 0
    }
  end

  @opts [pool: "claude", provider: "claude", window: "5h"]

  describe "observations/3 (pure)" do
    test "an interval's share is the utilization delta and its draw is the usage inside it" do
      samples = [sample(0, 0.10), sample(40, 0.30)]
      rows = [usage(10, "opus", 1000), usage(30, "sonnet", 200), usage(50, "opus", 9999)]

      assert [obs] = Draw.observations(samples, rows, @opts)
      assert_in_delta obs.share, 0.20, 1.0e-12
      assert_in_delta obs.hours, 40 / 60, 1.0e-12
      # output tokens carry the 5.0 weight
      assert obs.draws == %{"opus" => 5000.0, "sonnet" => 1000.0}
    end

    test "usage belongs to the interval it falls in, boundaries going to the earlier one (the capture's own instant is inside it)" do
      samples = [sample(0, 0.1), sample(40, 0.2), sample(80, 0.3)]
      rows = [usage(40, "opus", 100), usage(41, "opus", 100)]

      assert [first, second] = Draw.observations(samples, rows, @opts)
      assert first.draws == %{"opus" => 500.0}
      assert second.draws == %{"opus" => 500.0}
    end

    test "close captures coalesce until the interval is long enough to carry a signal" do
      samples = [sample(0, 0.10), sample(5, 0.11), sample(10, 0.12), sample(40, 0.15)]
      assert [obs] = Draw.observations(samples, [], @opts)
      assert_in_delta obs.share, 0.05, 1.0e-12
    end

    test "an interval that straddles a window reset is dropped, not diffed" do
      samples = [sample(0, 0.80, 20), sample(40, 0.05, 340), sample(80, 0.15, 340)]
      rows = [usage(60, "opus", 100)]

      assert [obs] = Draw.observations(samples, rows, @opts)
      assert_in_delta obs.share, 0.10, 1.0e-12
    end

    test "a utilization drop with no resets_at is still read as a reset" do
      samples = [
        %{utilization: 0.8, resets_at: nil, captured_at: at(0)},
        %{utilization: 0.1, resets_at: nil, captured_at: at(40)}
      ]

      assert Draw.observations(samples, [], @opts) == []
    end

    test "usage from another pool is ignored" do
      samples = [sample(0, 0.1), sample(40, 0.2)]
      rows = [usage(10, "gpt-5", 1000, "codex"), usage(20, "opus", 100)]

      assert [obs] = Draw.observations(samples, rows, @opts)
      assert obs.draws == %{"opus" => 500.0}
    end

    test "an interval longer than the window can hold is dropped" do
      assert Draw.observations([sample(0, 0.1, 900), sample(600, 0.2, 900)], [], @opts) == []
    end
  end

  describe "calibrate/1 against the ledger" do
    defp account!, do: Ecto.UUID.generate()

    defp snapshot!(account_id, minutes, util) do
      Ash.create!(QuotaSnapshot, %{
        provider_account_id: account_id,
        provider: "claude",
        bucket: "claude",
        window: "5h",
        utilization: util,
        resets_at: at(300),
        captured_at: at(minutes)
      })
    end

    defp event!(account_id, minutes, model, counts) do
      Ash.create!(
        Usage.Event,
        Map.merge(
          %{
            step: :other,
            source: :maintenance,
            provider: "claude",
            model: model,
            provider_account_id: account_id,
            occurred_at: at(minutes)
          },
          counts
        )
      )
    end

    test "recovers known coefficients end to end through both tables" do
      account = account!()
      truth = %{"opus" => 4.0e-7, "sonnet" => 1.0e-7}

      # 12 intervals of 30 minutes, each with a distinct opus/sonnet mix.
      util =
        Enum.reduce(0..11, [{0, 0.0}], fn i, [{_, u} | _] = acc ->
          opus = 1000 + 700 * rem(i * 5, 7)
          sonnet = 900 + 450 * rem(i * 3, 5)
          event!(account, i * 30 + 10, "opus", %{tokens_out: opus})
          event!(account, i * 30 + 20, "sonnet", %{tokens_out: sonnet})
          share = truth["opus"] * opus * 5.0 + truth["sonnet"] * sonnet * 5.0
          [{(i + 1) * 30, u + share} | acc]
        end)

      Enum.each(util, fn {m, u} -> snapshot!(account, m, u) end)

      assert [result] = Draw.calibrate(until: at(1000), since: at(-10))
      assert result.account_id == account
      assert result.pool == "claude"
      assert result.window == "5h"
      assert result.fit.status == :calibrated

      assert_in_delta result.fit.models["opus"].share_per_weighted_token, 4.0e-7, 1.0e-9
      assert_in_delta result.fit.models["sonnet"].share_per_weighted_token, 1.0e-7, 1.0e-9
    end

    test "a pool with a handful of samples reports insufficient data, never zero" do
      account = account!()
      event!(account, 10, "opus", %{tokens_out: 1000})
      snapshot!(account, 0, 0.0)
      snapshot!(account, 30, 0.02)

      assert [result] = Draw.calibrate(until: at(1000), since: at(-10))
      assert result.fit.status == :insufficient_data
      assert result.fit.models["opus"].share_per_weighted_token == nil
      assert Draw.lookup([result], "claude", "5h", "opus") == nil
    end
  end

  describe "lookup/5 and Scarcity.draw_share/5" do
    @fit %{
      status: :calibrated,
      reason: nil,
      n: 20,
      background_share_per_hour: nil,
      rmse: 0.0,
      models: %{
        "opus" => %{
          status: :calibrated,
          reason: nil,
          share_per_weighted_token: 2.0e-6,
          n: 20
        },
        "haiku" => %{
          status: :insufficient_data,
          reason: :too_few_model_observations,
          share_per_weighted_token: nil,
          n: 1
        }
      }
    }

    @results [%{account_id: "a", provider: "claude", pool: "claude", window: "5h", fit: @fit}]

    test "returns the calibrated coefficient, and nil for everything else" do
      assert Draw.lookup(@results, "claude", "5h", "opus") == 2.0e-6
      assert Draw.lookup(@results, "claude", "5h", "haiku") == nil
      assert Draw.lookup(@results, "claude", "5h", "unseen") == nil
      assert Draw.lookup(@results, "claude", "7d", "opus") == nil
      assert Draw.lookup(@results, "codex", "5h", "opus") == nil
      assert Draw.lookup([], "claude", "5h", "opus") == nil
    end

    test "Scarcity.draw_share/5 scales weighted tokens, and is nil when uncalibrated" do
      assert_in_delta Scarcity.draw_share(500_000.0, @results, "claude", "5h", "opus"),
                      1.0,
                      1.0e-9

      assert Scarcity.draw_share(500_000.0, @results, "claude", "5h", "haiku") == nil
      assert Scarcity.draw_share(nil, @results, "claude", "5h", "opus") == nil
    end
  end

  describe "format/1" do
    test "says plainly when a coefficient is unavailable, and never prints 0" do
      text =
        Draw.format([
          %{account_id: "a", provider: "claude", pool: "claude", window: "5h", fit: @fit}
        ])

      assert text =~ "insufficient data"
      assert text =~ "opus"
      # @fit's opus is 2.0e-6 of the window per weighted token: 1M tokens = 200%.
      assert text =~ "opus: 200.0000% of the window per 1M weighted tokens"
    end
  end
end
