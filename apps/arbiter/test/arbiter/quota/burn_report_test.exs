defmodule Arbiter.Quota.BurnReportTest do
  @moduledoc """
  The burn report (bd-cklotu): per account, p50/p90/p99 of the historical rolling-24h
  burn of the 7d window, and — for an account with a `daily_burn_cap` — how often the
  cap would have held. `build/1` is pure; `collect/1` reads `quota_snapshots`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Board.AdmissionShadowReport
  alias Arbiter.Quota.BurnReport
  alias Arbiter.Quota.QuotaSnapshot

  @t0 ~U[2026-10-01 00:00:00Z]
  @until DateTime.add(@t0, 5 * 86_400, :second)
  @reset ~U[2026-10-07 00:00:00Z]

  defp account(id, config \\ %{}),
    do: %ProviderAccount{id: id, provider: :claude, slug: "slug-#{id}", quota_config: config}

  # One 7d sample per hour; `rate` is the utilization gained each hour. The
  # first day climbs at 0.01/h (0.24 per day), the rest at 0.002/h.
  defp samples(id, hours \\ 120) do
    {rows, _} =
      Enum.map_reduce(0..hours, 0.0, fn h, util ->
        step = if h < 24, do: 0.01, else: 0.002
        row = row(id, h, util)
        {row, util + step}
      end)

    rows
  end

  defp row(id, hours, util) do
    %{
      provider_account_id: id,
      provider: "claude",
      bucket: "claude",
      window: "7d",
      utilization: util,
      resets_at: @reset,
      captured_at: DateTime.add(@t0, hours * 3600, :second),
      seats: nil,
      budget: nil
    }
  end

  defp data(accounts, snapshots),
    do: %{
      since: @t0,
      until: @until,
      snapshots: snapshots,
      accounts: Map.new(accounts, &{&1.id, &1})
    }

  test "p50/p90/p99 of the 24h deltas per account" do
    report = BurnReport.build(data([account("a")], samples("a")))
    assert [%{account: "claude:slug-a", deltas: d}] = report.accounts

    # day 2 reads 0.24 down to 0.048 as the fast day ages out, then settles at 0.048
    assert d.n > 90
    assert_in_delta d.p99, 0.24, 0.011
    assert_in_delta d.p50, 0.048, 0.011
    assert d.p50 <= d.p90 and d.p90 <= d.p99
  end

  test "accounts are reported separately, and one with no usable history says so" do
    short = Enum.take(samples("b"), 5)
    report = BurnReport.build(data([account("a"), account("b")], samples("a") ++ short))

    assert [%{account: "claude:slug-a"}, %{account: "claude:slug-b", deltas: %{n: 0}}] =
             report.accounts
  end

  test "a capped account counts the grid points the cap would have held" do
    acct = account("a", %{"daily_burn_cap" => 0.10})
    report = BurnReport.build(data([acct], samples("a")))
    assert [%{cap: 0.10, mode: "shadow", would_hold: w}] = report.accounts

    # the first day's 0.24 burn is over 0.10 until it ages out
    assert w.points > 0
    assert w.points < report.accounts |> hd() |> get_in([:deltas, :n])
    assert w.of == hd(report.accounts).deltas.n
    assert w.first_at
  end

  test "an operator-supplied cap is evaluated on every account" do
    report = BurnReport.build(data([account("a")], samples("a")), cap: 0.30)
    assert [%{cap: 0.30, would_hold: %{points: 0}}] = report.accounts
  end

  test "format/1 prints the percentiles and the would-hold line" do
    acct = account("a", %{"daily_burn_cap" => 0.10})
    text = acct |> then(&BurnReport.build(data([&1], samples("a")))) |> BurnReport.format()
    assert text =~ "claude:slug-a"
    assert text =~ "p50"
    assert text =~ "p99"
    assert text =~ "would have held"
  end

  test "format/1 with no accounts" do
    assert BurnReport.format(BurnReport.build(data([], []))) =~ "no 7d quota history"
  end

  describe "in the admission shadow report" do
    defp shadow(data), do: AdmissionShadowReport.build(Map.merge(base(), data))

    defp base,
      do: %{
        since: @t0,
        until: @until,
        dispatches: [],
        events: [],
        snapshots: [],
        accounts: %{},
        calibration: []
      }

    test "only an account with a cap gets the section" do
      plain = shadow(data([account("a")], samples("a")))
      refute AdmissionShadowReport.format(plain) =~ "Burn governor"

      capped = shadow(data([account("a", %{"daily_burn_cap" => 0.10})], samples("a")))
      text = AdmissionShadowReport.format(capped)
      assert text =~ "Burn governor"
      assert text =~ "would have held"
      assert [%{cap: 0.10}] = capped.burn.accounts
    end
  end

  describe "collect/1" do
    test "reads the 7d history from quota_snapshots" do
      acct =
        Ash.create!(ProviderAccount, %{
          provider: :claude,
          slug: "br-#{System.unique_integer([:positive])}"
        })

      for r <- samples(acct.id) do
        QuotaSnapshot |> Ash.Changeset.for_create(:record, r) |> Ash.create!()
      end

      report = [since: @t0, until: @until] |> BurnReport.collect() |> BurnReport.build()
      assert [%{deltas: %{n: n}}] = report.accounts
      assert n > 90
    end
  end
end
