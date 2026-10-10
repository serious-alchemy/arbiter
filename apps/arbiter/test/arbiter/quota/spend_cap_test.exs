defmodule Arbiter.Quota.SpendCapTest do
  @moduledoc """
  The dollar spend cap (bd-a6grlr): fixed UTC windows, the paced line through
  `Gate.pace/6`, and which ledger spend counts (metered only).
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Accounts.ProviderCredential
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.SpendCap
  alias Arbiter.Usage.Event

  # Wednesday. Its week began Monday 2026-10-12 00:00 UTC.
  @now ~U[2026-10-14 15:30:00Z]
  # Exactly half way through the week: Thursday 12:00 UTC.
  @half_week ~U[2026-10-15 12:00:00Z]

  defp account(config, attrs \\ %{}) do
    struct(
      %ProviderAccount{
        id: Ecto.UUID.generate(),
        provider: :claude,
        slug: "spend-#{System.unique_integer([:positive])}",
        quota_config: config
      },
      attrs
    )
  end

  defp persisted!(config, provider \\ :claude) do
    Ash.create!(ProviderAccount, %{
      provider: provider,
      slug: "spend-#{System.unique_integer([:positive])}",
      quota_config: config
    })
  end

  defp ledger!(account, cost, occurred_at, extra \\ %{}) do
    Ash.create!(
      Event,
      Map.merge(
        %{
          task_id: "bd-sp-#{System.unique_integer([:positive])}",
          source: :task,
          step: :work,
          provider: "claude",
          provider_account_id: account.id,
          workspace_id: nil,
          cost_usd: cost,
          occurred_at: occurred_at
        },
        extra
      )
    )
  end

  describe "config/1" do
    test "reads the cap with week / flat defaults" do
      assert %{usd: 20.0, window: :week, mode: :flat} = SpendCap.config(account(%{"spend_cap" => 20.0}))
    end

    test "reads window and mode" do
      cfg = account(%{"spend_cap" => 5.0, "spend_window" => "day", "spend_mode" => "paced"})
      assert %{usd: 5.0, window: :day, mode: :paced} = SpendCap.config(cfg)
    end

    test "no cap, no config" do
      assert SpendCap.config(account(%{})) == nil
      assert SpendCap.config(nil) == nil
      assert SpendCap.config(account(%{"spend_cap" => "garbage"})) == nil
    end
  end

  describe "bounds/2: fixed UTC windows" do
    test "day starts at 00:00 UTC" do
      assert %{start: ~U[2026-10-14 00:00:00Z], reset_at: ~U[2026-10-15 00:00:00Z], seconds: 86_400} =
               SpendCap.bounds(:day, @now)
    end

    test "week starts Monday 00:00 UTC" do
      assert %{start: ~U[2026-10-12 00:00:00Z], reset_at: ~U[2026-10-19 00:00:00Z], seconds: 604_800} =
               SpendCap.bounds(:week, @now)
    end

    test "a Monday 00:00 instant opens a new week" do
      assert %{start: ~U[2026-10-12 00:00:00Z]} = SpendCap.bounds(:week, ~U[2026-10-12 00:00:00Z])
      assert %{start: ~U[2026-10-05 00:00:00Z]} = SpendCap.bounds(:week, ~U[2026-10-11 23:59:59Z])
    end

    test "month starts on the 1st and has the calendar length" do
      assert %{start: ~U[2026-10-01 00:00:00Z], reset_at: ~U[2026-11-01 00:00:00Z], seconds: s} =
               SpendCap.bounds(:month, @now)

      assert s == 31 * 86_400

      assert %{reset_at: ~U[2027-01-01 00:00:00Z]} = SpendCap.bounds(:month, ~U[2026-12-31 23:00:00Z])
    end
  end

  describe "verdict/4: the line is Gate.pace/6's" do
    test "flat mode allows the whole cap at any time" do
      cfg = SpendCap.config(account(%{"spend_cap" => 20.0}))
      assert %{verdict: v} = SpendCap.verdict(cfg, 19.0, @now)
      assert v != :holding
      assert %{verdict: :holding} = SpendCap.verdict(cfg, 20.0, @now)
      assert %{verdict: :holding} = SpendCap.verdict(cfg, 25.0, @now)
    end

    test "paced mode holds past cap x elapsed fraction" do
      cfg = SpendCap.config(account(%{"spend_cap" => 20.0, "spend_mode" => "paced"}))

      assert %{verdict: v, allowed: allowed} = SpendCap.verdict(cfg, 9.0, @half_week)
      assert v != :holding
      assert_in_delta allowed, 10.0, 0.001

      assert %{verdict: :holding} = SpendCap.verdict(cfg, 11.0, @half_week)
    end

    test "the paced ceiling is exactly what Gate.pace/6 says for the :spend window" do
      acct = account(%{"spend_cap" => 20.0, "spend_mode" => "paced", "spend_window" => "week"})
      cfg = SpendCap.config(acct)
      %{reset_at: reset, seconds: seconds} = SpendCap.bounds(:week, @half_week)

      gate = Gate.pace(acct, :spend, "spend_week", 11.0 / 20.0, reset, now: @half_week, window_seconds: seconds)
      mine = SpendCap.verdict(cfg, 11.0, @half_week)

      assert gate.verdict == mine.verdict
      assert gate.mode == :paced
      assert_in_delta gate.ceiling, mine.allowed / 20.0, 1.0e-9
      assert_in_delta gate.ceiling, 0.5, 1.0e-9
    end

    test "a flat cap through Gate.pace/6 has a ceiling of 1.0 (the whole cap)" do
      acct = account(%{"spend_cap" => 20.0})
      %{reset_at: reset, seconds: seconds} = SpendCap.bounds(:week, @now)
      gate = Gate.pace(acct, :spend, "spend_week", 0.5, reset, now: @now, window_seconds: seconds)
      assert gate.mode == :flat
      assert gate.ceiling == 1.0
    end

    test "nothing spent never holds, even at the very start of a paced window" do
      cfg = SpendCap.config(account(%{"spend_cap" => 20.0, "spend_mode" => "paced"}))
      refute SpendCap.verdict(cfg, 0.0, ~U[2026-10-12 00:00:00Z]).verdict == :holding
    end
  end

  describe "metered?/1: only real metered spend counts" do
    test "an explicit flag wins either way" do
      assert SpendCap.metered?(persisted!(%{"spend_cap" => 5.0, "spend_metered" => true}))
      refute SpendCap.metered?(persisted!(%{"spend_cap" => 5.0, "spend_metered" => false}))
    end

    test "unflagged: a subscription account (no api key) is not metered" do
      refute SpendCap.metered?(persisted!(%{"spend_cap" => 5.0}))
    end

    test "unflagged: an active api_key credential makes the account metered" do
      acct = persisted!(%{"spend_cap" => 5.0})

      Ash.create!(ProviderCredential, %{
        provider_account_id: acct.id,
        kind: :api_key,
        env_var: "ANTHROPIC_API_KEY",
        fingerprint: "fp-spend",
        secret: "sk-test-not-real"
      })

      assert SpendCap.metered?(acct)
    end

    test "an explicit false beats an api key" do
      acct = persisted!(%{"spend_cap" => 5.0, "spend_metered" => false})

      Ash.create!(ProviderCredential, %{
        provider_account_id: acct.id,
        kind: :api_key,
        env_var: "ANTHROPIC_API_KEY",
        fingerprint: "fp-spend-2",
        secret: "sk-test-not-real"
      })

      refute SpendCap.metered?(acct)
    end
  end

  describe "status/2: settled spend from the ledger" do
    test "counts only priced rows of this account inside the window" do
      acct = persisted!(%{"spend_cap" => 20.0, "spend_metered" => true})
      other = persisted!(%{"spend_cap" => 20.0, "spend_metered" => true})

      ledger!(acct, 3.0, ~U[2026-10-13 10:00:00Z])
      ledger!(acct, 2.0, ~U[2026-10-14 09:00:00Z])
      # notional / unpriced: NULL cost never counts
      ledger!(acct, nil, ~U[2026-10-14 09:30:00Z], %{cost_note: "cost unavailable: subscription"})
      # before the window opened
      ledger!(acct, 50.0, ~U[2026-10-11 23:59:00Z])
      # someone else's
      ledger!(other, 7.0, ~U[2026-10-14 09:00:00Z])

      status = SpendCap.status(acct, now: @now, in_flight: 0.0)
      assert status.metered?
      assert_in_delta status.spent, 5.0, 1.0e-9
      assert_in_delta status.used, 5.0, 1.0e-9
    end

    test "a non-metered account reports no metered spend and never holds" do
      acct = persisted!(%{"spend_cap" => 1.0, "spend_metered" => false})
      # notional API-equivalent price of subscription usage: far past the cap
      ledger!(acct, 400.0, ~U[2026-10-14 09:00:00Z])

      status = SpendCap.status(acct, now: @now, in_flight: 0.0)
      refute status.metered?
      assert status.state == :no_metered_spend
      assert status.spent == 0.0
      refute status.holding?
      assert SpendCap.check(acct, nil, now: @now, in_flight: 0.0) == :ok
    end

    test "no cap configured -> nil" do
      assert SpendCap.status(persisted!(%{}), now: @now) == nil
      assert SpendCap.check(persisted!(%{}), nil, now: @now) == :ok
    end

    test "in-flight estimate is added to settled spend" do
      acct = persisted!(%{"spend_cap" => 20.0, "spend_metered" => true})
      ledger!(acct, 12.0, ~U[2026-10-14 09:00:00Z])

      status = SpendCap.status(acct, now: @now, in_flight: 5.0)
      assert_in_delta status.used, 17.0, 1.0e-9
      assert_in_delta status.in_flight, 5.0, 1.0e-9
      refute status.holding?
    end
  end

  describe "check/3" do
    test "flat: held once settled + in-flight reaches the cap, with a clear reason" do
      acct = persisted!(%{"spend_cap" => 20.0, "spend_metered" => true})
      ledger!(acct, 15.0, ~U[2026-10-14 09:00:00Z])

      assert :ok = SpendCap.check(acct, nil, now: @now, in_flight: 4.0)

      assert {:hold, reason} = SpendCap.check(acct, nil, now: @now, in_flight: 5.0)
      assert reason.gate == :spend
      assert reason.phrase =~ "spend cap $20.00/week reached"
      assert reason.phrase =~ "$15.00 spent + ~$5.00 in flight"
      assert reason.phrase =~ "resets 2026-10-19"
      assert reason.wake_at == ~U[2026-10-19 00:00:00Z]
    end

    test "flat: the hold lifts when the window resets" do
      acct = persisted!(%{"spend_cap" => 20.0, "spend_metered" => true})
      ledger!(acct, 25.0, ~U[2026-10-14 09:00:00Z])

      assert {:hold, _} = SpendCap.check(acct, nil, now: @now, in_flight: 0.0)
      assert :ok = SpendCap.check(acct, nil, now: ~U[2026-10-19 00:00:01Z], in_flight: 0.0)
    end

    test "paced: held past the line, with the pace phrase and a wake time on the line" do
      acct = persisted!(%{"spend_cap" => 20.0, "spend_mode" => "paced", "spend_metered" => true})
      ledger!(acct, 12.0, ~U[2026-10-15 08:00:00Z])

      assert {:hold, reason} = SpendCap.check(acct, nil, now: @half_week, in_flight: 0.0)
      assert reason.phrase =~ "spend pace: $12.00 of $10.00 allowed by now"
      # $12 is allowed at 60% of the week: Thursday 2026-10-15 12:00 + 0.1 week
      assert reason.wake_at == DateTime.add(~U[2026-10-12 00:00:00Z], round(0.6 * 604_800), :second)
    end

    test "paced: allowed while under the line" do
      acct = persisted!(%{"spend_cap" => 20.0, "spend_mode" => "paced", "spend_metered" => true})
      ledger!(acct, 8.0, ~U[2026-10-15 08:00:00Z])
      assert :ok = SpendCap.check(acct, nil, now: @half_week, in_flight: 0.0)
    end
  end

  describe "fresh_dispatch?/2" do
    test "an idle ticket being started is fresh" do
      assert SpendCap.fresh_dispatch?(%{id: "bd-1", state: :open}, [])
    end

    test "follow-ups of a started ticket are not" do
      refute SpendCap.fresh_dispatch?(%{id: "bd-1", state: :active}, [])
      refute SpendCap.fresh_dispatch?(%{id: "bd-1", state: :open}, resume: true)
      refute SpendCap.fresh_dispatch?(%{id: "bd-1", state: :open}, review: true)
      refute SpendCap.fresh_dispatch?(%{id: "bd-1#review", state: :open}, [])
      refute SpendCap.fresh_dispatch?(%{id: "bd-1:fixpass", state: :open}, [])
    end
  end
end
