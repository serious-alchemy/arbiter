defmodule Arbiter.Quota.GatePaceExemptTest do
  @moduledoc """
  The P0 pace exemption (bd-6bxv7h, design §4.2): for a dispatch whose own
  priority is exempt, a paced side's ceiling lifts from the paced line up to
  `min(exempt_cap, flat)` — never above the side's flat ceiling, and never
  below the paced line. Off (no `pace_exempt_priority` on the account) nothing
  moves. Every test pins `opts[:now]`.
  """
  use Arbiter.DataCase, async: false

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot
  alias Arbiter.Quota.Headroom
  alias Arbiter.Quota.Pace
  alias Arbiter.Tasks.Workspace

  @now ~U[2026-10-05 12:00:00Z]
  @five_hours 18_000
  @seven_days 604_800

  setup do
    prior = Application.get_env(:arbiter, :quota, [])
    on_exit(fn -> Application.put_env(:arbiter, :quota, prior) end)

    Application.put_env(
      :arbiter,
      :quota,
      Keyword.drop(prior, [:throttle_threshold, :weekly_threshold, :weekly_warning_policy, :gate])
    )

    :ok
  end

  defp account(config), do: %ProviderAccount{provider: :claude, quota_config: config}
  defp ws(quota), do: %Workspace{id: "ws-exempt", config: %{"quota" => quota}}

  defp paced(extra \\ %{}),
    do: account(Map.merge(%{"threshold_mode" => "paced", "pace_exempt_priority" => 0}, extra))

  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  defp snap(attrs) do
    struct(
      %Snapshot{
        provider: "claude",
        utilization: 0.01,
        status: "allowed",
        reset_at: reset_after(0.5, @five_hours),
        captured_at: @now,
        window_label: "5h",
        secondary_utilization: 0.01,
        secondary_status: "allowed",
        secondary_reset_at: reset_after(0.5, @seven_days),
        secondary_window_label: "7d"
      },
      attrs
    )
  end

  defp primary(u, elapsed),
    do: snap(%{utilization: u, reset_at: reset_after(elapsed, @five_hours)})

  defp long(u, elapsed),
    do: snap(%{secondary_utilization: u, secondary_reset_at: reset_after(elapsed, @seven_days)})

  defp gate(quota, policy, priority),
    do: Gate.gating_window(quota, policy, now: @now, priority: priority)

  describe "Pace.side_ceiling/2 with {:paced_exempt, floor, flat, cap}" do
    test "lifts the paced line to the cap" do
      assert {0.9, :exempt} = Pace.side_ceiling({:paced_exempt, 0.2, 0.99, 0.9}, 0.3)
    end

    test "never lowers the paced line: a line already above the cap stays, as :paced" do
      assert {0.95, :paced} = Pace.side_ceiling({:paced_exempt, 0.2, 0.99, 0.9}, 0.95)
    end

    test "unknown elapsed falls back exactly as a paced side does" do
      assert {0.99, :flat} = Pace.side_ceiling({:paced_exempt, 0.2, 0.99, 0.9}, nil)
      assert nil == Pace.side_ceiling({:paced_exempt, 0.2, nil, 0.9}, nil)
    end

    test "evaluate/4 reports :exempt as the mode" do
      thresholds = %{sides: [{:paced_exempt, 0.2, 0.99, 0.9}], default: 0.9}

      assert %{mode: :exempt, ceiling: 0.9, verdict: :holding} =
               Pace.evaluate(0.9, 0.3 * @seven_days, @seven_days, thresholds)
    end
  end

  describe "the 7d window: exemption lifts the paced line up to the dedicated cap" do
    # Paced line is max(0.20 floor, 0.30 elapsed) = 0.30; flat 0.99; cap 0.90.
    @acct %{"weekly_threshold" => 0.99, "weekly_pace_exempt_threshold" => 0.9}

    test "a non-exempt dispatch holds past the paced line" do
      assert %{window: "7d", signal: :utilization, threshold: 0.3} =
               gate(long(0.5, 0.3), {paced(@acct), nil}, 2)
    end

    test "an exempt P0 passes the paced line" do
      assert nil == gate(long(0.5, 0.3), {paced(@acct), nil}, 0)
      assert nil == gate(long(0.89, 0.3), {paced(@acct), nil}, 0)
    end

    test "but never the dedicated cap, which is below the flat ceiling" do
      assert %{window: "7d", threshold: 0.9, mode: :exempt, priority: 0} =
               gate(long(0.9, 0.3), {paced(@acct), nil}, 0)

      assert %{threshold: 0.9} = gate(long(0.95, 0.3), {paced(@acct), nil}, 0)
    end

    test "cap unset falls back to the flat ceiling" do
      acct = paced(%{"weekly_threshold" => 0.99})
      assert nil == gate(long(0.98, 0.3), {acct, nil}, 0)
      assert %{threshold: 0.99, mode: :exempt} = gate(long(0.99, 0.3), {acct, nil}, 0)
    end

    test "cap unset and no flat set: the window's flat default (0.90) is the ceiling" do
      acct = paced()
      assert nil == gate(long(0.89, 0.3), {acct, nil}, 0)
      assert %{threshold: 0.9} = gate(long(0.9, 0.3), {acct, nil}, 0)
    end

    test "a cap above the flat ceiling cannot lift past the flat ceiling" do
      acct = paced(%{"weekly_threshold" => 0.7, "weekly_pace_exempt_threshold" => 1.0})
      assert nil == gate(long(0.69, 0.3), {acct, nil}, 0)
      assert %{threshold: 0.7} = gate(long(0.7, 0.3), {acct, nil}, 0)
    end

    test "late window: the paced line is already above the cap, so nothing is lowered" do
      # elapsed 0.95 > cap 0.90: the line (0.95) is the ceiling for everyone.
      for priority <- [0, 2] do
        assert nil == gate(long(0.93, 0.95), {paced(@acct), nil}, priority)

        assert %{threshold: 0.95} = binding = gate(long(0.96, 0.95), {paced(@acct), nil}, priority)
        assert binding.mode == :paced
      end
    end

    test "a priority below the configured exempt priority is not exempt" do
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {paced(@acct), nil}, 1)
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {paced(@acct), nil}, nil)
    end

    test "pace_exempt_priority 2 exempts P0..P2 and nothing below" do
      acct = paced(Map.put(@acct, "pace_exempt_priority", 2))
      assert nil == gate(long(0.5, 0.3), {acct, nil}, 2)
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {acct, nil}, 3)
    end
  end

  describe "the 5h window" do
    # Paced line max(0.35, 0.40) = 0.40; flat default 0.85; cap 0.80.
    @acct5 %{"pace_exempt_threshold" => 0.8}

    test "has its own cap, set separately from the weekly one" do
      acct = paced(Map.put(@acct5, "weekly_pace_exempt_threshold", 0.5))
      assert nil == gate(primary(0.79, 0.4), {acct, nil}, 0)
      assert %{window: "5h", threshold: 0.8, mode: :exempt} = gate(primary(0.8, 0.4), {acct, nil}, 0)
      assert %{window: "5h", threshold: 0.4} = gate(primary(0.8, 0.4), {acct, nil}, 1)
    end

    test "the weekly cap does not bound the 5h window" do
      acct = paced(%{"weekly_pace_exempt_threshold" => 0.5})
      # No 5h cap: 5h flat default 0.85 applies.
      assert nil == gate(primary(0.84, 0.4), {acct, nil}, 0)
      assert %{threshold: 0.85} = gate(primary(0.85, 0.4), {acct, nil}, 0)
    end
  end

  describe "the workspace side may only tighten" do
    @base %{"weekly_threshold" => 0.99, "weekly_pace_exempt_threshold" => 0.9}

    test "a workspace cap below the account's lowers the cap: min(account, workspace)" do
      w = ws(%{"weekly_pace_exempt_threshold" => 0.6})
      assert nil == gate(long(0.59, 0.3), {paced(@base), w}, 0)
      assert %{threshold: 0.6} = gate(long(0.6, 0.3), {paced(@base), w}, 0)
    end

    test "a workspace cap above the account's does not loosen it" do
      w = ws(%{"weekly_pace_exempt_threshold" => 0.99})
      assert %{threshold: 0.9} = gate(long(0.9, 0.3), {paced(@base), w}, 0)
    end

    test "a workspace cap tightens an account whose cap is unset (flat)" do
      acct = paced(%{"weekly_threshold" => 0.99})
      w = ws(%{"weekly_pace_exempt_threshold" => 0.7})
      assert %{threshold: 0.7} = gate(long(0.7, 0.3), {acct, w}, 0)
    end

    test "a workspace's own flat ceiling still binds an exempt dispatch" do
      w = ws(%{"weekly_threshold" => 0.5})
      assert %{threshold: 0.5} = gate(long(0.5, 0.3), {paced(@base), w}, 0)
    end

    test "workspace pace_exempt_priority narrows the account's" do
      acct = paced(Map.put(@base, "pace_exempt_priority", 2))
      w = ws(%{"pace_exempt_priority" => 0})
      assert nil == gate(long(0.5, 0.3), {acct, w}, 0)
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {acct, w}, 1)
    end

    test "workspace pace_exempt_priority cannot widen the account's" do
      w = ws(%{"pace_exempt_priority" => 3})
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {paced(@base), w}, 1)
    end

    test ~s|workspace "none" switches the exemption off| do
      w = ws(%{"pace_exempt_priority" => "none"})
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {paced(@base), w}, 0)
    end

    test "an account without the setting exempts nothing, whatever the workspace says" do
      acct = account(%{"threshold_mode" => "paced"})
      w = ws(%{"pace_exempt_priority" => 0})
      assert %{threshold: 0.3} = gate(long(0.5, 0.3), {acct, w}, 0)
    end
  end

  describe "off by default / no-regression" do
    test "no pace_exempt_priority: a P0 is gated exactly like a P2" do
      acct = account(%{"threshold_mode" => "paced", "weekly_pace_exempt_threshold" => 0.9})

      for u <- [0.1, 0.3, 0.5, 0.95] do
        assert gate(long(u, 0.3), {acct, nil}, 0) == gate(long(u, 0.3), {acct, nil}, 2)
        assert gate(long(u, 0.3), {acct, nil}, 0) == gate(long(u, 0.3), {acct, nil}, nil)
      end
    end

    test "a flat account is unchanged by the exemption" do
      acct = account(%{"weekly_threshold" => 0.6, "pace_exempt_priority" => 0})
      assert %{threshold: 0.6} = gate(long(0.7, 0.3), {acct, nil}, 0)
      assert gate(long(0.7, 0.3), {acct, nil}, 0) == gate(long(0.7, 0.3), {acct, nil}, 3)
    end

    test "status holds are not an exemption's business" do
      rejected = snap(%{status: "rejected", utilization: 0.01})
      assert %{signal: :status} = gate(rejected, {paced(), nil}, 0)

      warned = snap(%{secondary_status: "allowed_warning"})
      acct = paced(%{"weekly_warning_policy" => "hold"})
      assert %{signal: :warning} = gate(warned, {acct, nil}, 0)
    end

    test "no :priority option behaves as today" do
      acct = paced(%{"weekly_pace_exempt_threshold" => 0.9})

      assert Gate.gating_window(long(0.5, 0.3), {acct, nil}, now: @now) ==
               Gate.gating_window(long(0.5, 0.3), {acct, nil}, now: @now, priority: 4)
    end
  end

  describe "pace_exemption/3 (the audit record)" do
    @acct %{"weekly_threshold" => 0.99, "weekly_pace_exempt_threshold" => 0.9}

    test "names the window, usage, the paced line and the cap when the exemption decided it" do
      assert %{window: "7d", used: 0.5, paced: 0.3, cap: 0.9} =
               Gate.pace_exemption(long(0.5, 0.3), {paced(@acct), nil}, now: @now, priority: 0)
    end

    test "nil when the dispatch was under the paced line anyway" do
      assert nil == Gate.pace_exemption(long(0.2, 0.3), {paced(@acct), nil}, now: @now, priority: 0)
    end

    test "nil for a non-exempt priority, or no priority" do
      assert nil == Gate.pace_exemption(long(0.5, 0.3), {paced(@acct), nil}, now: @now, priority: 2)
      assert nil == Gate.pace_exemption(long(0.5, 0.3), {paced(@acct), nil}, now: @now)
    end

    test "nil when the exemption is off" do
      acct = account(%{"threshold_mode" => "paced"})
      assert nil == Gate.pace_exemption(long(0.5, 0.3), {acct, nil}, now: @now, priority: 0)
    end

    test "nil when a held dispatch is held (past the cap)" do
      assert nil == Gate.pace_exemption(long(0.95, 0.3), {paced(@acct), nil}, now: @now, priority: 0)
    end

    test "5h window" do
      acct = paced(%{"pace_exempt_threshold" => 0.8})

      assert %{window: "5h", used: 0.6, paced: 0.4, cap: 0.8} =
               Gate.pace_exemption(primary(0.6, 0.4), {acct, nil}, now: @now, priority: 0)
    end
  end

  describe "Gate.pace/6 and Headroom read the lifted line" do
    @acct %{"weekly_threshold" => 0.99, "weekly_pace_exempt_threshold" => 0.9}

    test "Gate.pace with :priority" do
      reset = reset_after(0.3, @seven_days)

      assert %{ceiling: 0.9, mode: :exempt} =
               Gate.pace({paced(@acct), nil}, :long, "7d", 0.5, reset, now: @now, priority: 0)

      assert %{ceiling: 0.3, mode: :paced} =
               Gate.pace({paced(@acct), nil}, :long, "7d", 0.5, reset, now: @now, priority: 2)
    end

    test "Headroom.binding/3 reports the lifted headroom for an exempt priority" do
      q = long(0.5, 0.3)
      policy = {paced(@acct), nil}

      assert %{headroom: h, mode: :exempt} =
               Headroom.binding(q, policy, now: @now, priority: 0)

      assert_in_delta h, 0.4, 1.0e-9

      assert %{headroom: h2, mode: :paced} = Headroom.binding(q, policy, now: @now)
      assert_in_delta h2, -0.2, 1.0e-9
    end
  end

  describe "validate_quota_config/1" do
    test "accepts the per-window caps as fractions in (0, 1], coerced to floats" do
      assert {:ok,
              %{
                "pace_exempt_threshold" => 0.95,
                "weekly_pace_exempt_threshold" => 0.9,
                "pace_exempt_priority" => 0
              }} =
               Gate.validate_quota_config(%{
                 "pace_exempt_threshold" => "0.95",
                 "weekly_pace_exempt_threshold" => 0.9,
                 "pace_exempt_priority" => 0
               })

      assert {:ok, %{"weekly_pace_exempt_threshold" => 1.0}} =
               Gate.validate_quota_config(%{"weekly_pace_exempt_threshold" => 1})
    end

    test "rejects out-of-range caps" do
      for key <- ["pace_exempt_threshold", "weekly_pace_exempt_threshold"],
          bad <- [0, -0.1, 1.5, "0", "abc", nil, true] do
        assert {:error, {:invalid_quota_config, message}} =
                 Gate.validate_quota_config(%{key => bad})

        assert message =~ key
      end
    end

    test "pace_exempt_priority is an integer 0..4 (or its string form)" do
      assert {:ok, %{"pace_exempt_priority" => 4}} =
               Gate.validate_quota_config(%{"pace_exempt_priority" => "4"})

      for bad <- [-1, 5, 1.5, "x", nil] do
        assert {:error, {:invalid_quota_config, message}} =
                 Gate.validate_quota_config(%{"pace_exempt_priority" => bad})

        assert message =~ "pace_exempt_priority"
      end
    end
  end

  describe "the workspace config validator" do
    defp ws_errors(quota) do
      n = System.unique_integer([:positive])

      case Ash.create(Workspace, %{
             name: "pe-#{n}",
             prefix: "pe#{n}",
             config: %{"quota" => quota}
           }) do
        {:ok, _} -> ""
        {:error, error} -> Exception.message(error)
      end
    end

    test "accepts valid caps and priorities" do
      assert ws_errors(%{
               "pace_exempt_threshold" => 0.9,
               "weekly_pace_exempt_threshold" => "0.8",
               "pace_exempt_priority" => 0
             }) == ""

      assert ws_errors(%{"pace_exempt_priority" => "none"}) == ""
    end

    test "rejects out-of-range caps" do
      for key <- ["pace_exempt_threshold", "weekly_pace_exempt_threshold"],
          bad <- [0, -1, 1.5, "abc"] do
        assert ws_errors(%{key => bad}) =~ "quota.#{key} must be a number in (0, 1]"
      end
    end

    test "rejects a bad pace_exempt_priority" do
      for bad <- [-1, 5, "high", 1.5] do
        assert ws_errors(%{"pace_exempt_priority" => bad}) =~ "quota.pace_exempt_priority"
      end
    end
  end
end
