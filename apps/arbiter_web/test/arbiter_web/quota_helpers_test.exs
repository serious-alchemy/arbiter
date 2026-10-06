defmodule ArbiterWeb.QuotaHelpersTest do
  use ExUnit.Case, async: true

  import ArbiterWeb.QuotaHelpers

  alias Arbiter.Accounts.ProviderAccount
  alias Arbiter.Quota.Gate
  alias Arbiter.Quota.Gate.Snapshot

  describe "quota_provider_label/1" do
    test "maps known provider codes to display names" do
      assert quota_provider_label("claude") == "Claude"
      assert quota_provider_label("codex") == "Codex"
      assert quota_provider_label("antigravity") == "Antigravity"
    end

    test "title-cases unknown provider codes as a fallback" do
      assert quota_provider_label("some_new_provider") == "Some New Provider"
    end
  end

  describe "quota_elapsed_pct_5h/2" do
    test "nil reset_at yields no marker" do
      assert quota_elapsed_pct_5h("claude", nil) == nil
    end

    test "midpoint of the 5h window is 50% elapsed" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 50
    end

    test "clamps to 0 when the window hasn't opened yet" do
      reset_at = DateTime.add(DateTime.utc_now(), 10 * 60 * 60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 0
    end

    test "clamps to 100 when the window is overdue to reset" do
      reset_at = DateTime.add(DateTime.utc_now(), -60, :second)
      assert quota_elapsed_pct_5h("claude", reset_at) == 100
    end

    test "providers without a fixed window get no marker, even with a reset_at present" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("codex", reset_at) == nil
      assert quota_elapsed_pct_5h("someday_cli", reset_at) == nil
    end

    test "antigravity gets a marker identical to claude's, same fixed 5h window" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_elapsed_pct_5h("antigravity", reset_at) == 50

      assert quota_elapsed_pct_5h("antigravity", reset_at) ==
               quota_elapsed_pct_5h("claude", reset_at)
    end
  end

  describe "quota_elapsed_pct_7d/2" do
    test "nil reset_at yields no marker" do
      assert quota_elapsed_pct_7d("claude", nil) == nil
    end

    test "a third of the way through a 7d window" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("claude", reset_at) == 33
    end

    test "providers without a fixed window get no marker" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("codex", reset_at) == nil
      assert quota_elapsed_pct_7d("someday_cli", reset_at) == nil
    end

    test "antigravity gets a marker identical to claude's, same fixed 7d window" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_elapsed_pct_7d("antigravity", reset_at) == 33

      assert quota_elapsed_pct_7d("antigravity", reset_at) ==
               quota_elapsed_pct_7d("claude", reset_at)
    end
  end

  describe "quota_tooltip_5h/3" do
    test "nil reset_at yields no tooltip" do
      assert quota_tooltip_5h("claude", 0.62, nil) == nil
    end

    test "states both usage and elapsed numbers in words" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("claude", 0.62, reset_at) ==
               "62% quota used · 50% of window elapsed (2.5h into 5h)"
    end

    test "falls back to a neutral phrase when utilization is unknown" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("claude", nil, reset_at) ==
               "no usage data · 50% of window elapsed (2.5h into 5h)"
    end

    test "providers without a fixed window get no tooltip" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)
      assert quota_tooltip_5h("codex", 0.62, reset_at) == nil
      assert quota_tooltip_5h("someday_cli", 0.62, reset_at) == nil
    end

    test "antigravity gets a tooltip identical to claude's" do
      reset_at = DateTime.add(DateTime.utc_now(), 2 * 60 * 60 + 30 * 60, :second)

      assert quota_tooltip_5h("antigravity", 0.62, reset_at) ==
               "62% quota used · 50% of window elapsed (2.5h into 5h)"
    end
  end

  # ---- colour from the gate's pace verdict (bd-clzkvp) -------------------
  #
  # Every case pins `@now` and names its gate policy outright, so the verdict
  # depends only on the numbers in the test.

  @now ~U[2026-09-23 12:00:00Z]
  @five_hours 18_000
  @seven_days 604_800

  defp account(config), do: %ProviderAccount{provider: :claude, quota_config: config}
  defp paced(extra \\ %{}), do: account(Map.merge(%{"threshold_mode" => "paced"}, extra))
  defp flat, do: account(%{})
  defp gate_policy(account, enforcing?), do: %{policy: {account, nil}, enforcing?: enforcing?}

  defp reset_after(elapsed, seconds),
    do: DateTime.add(@now, round((1 - elapsed) * seconds), :second)

  defp bar(provider, window, u, elapsed, extra \\ %{}) do
    seconds = if window == "5h", do: @five_hours, else: @seven_days

    Map.merge(
      %{
        provider: provider,
        window: window,
        label: window,
        utilization: u,
        reset_at: reset_after(elapsed, seconds),
        overage_status: nil
      },
      extra
    )
  end

  defp pace(bar, account, enforcing? \\ true),
    do: quota_pace(bar, gate_policy(account, enforcing?), @now)

  defp state(bar, account \\ paced()), do: pace(bar, account).state

  describe "quota_pace/3 — state is the gate's verdict" do
    test "ok → green, approaching → amber, holding → red, sampling → grey" do
      # 5h, paced floor 0.35 until 35% elapsed; amber from 10 points under it.
      assert state(bar("claude", "5h", 0.36, 0.1)) == :red
      assert state(bar("claude", "5h", 0.30, 0.1)) == :amber
      assert state(bar("claude", "5h", 0.20, 0.3)) == :green
      assert state(bar("claude", "5h", 0.10, 0.02)) == :grey
    end

    test "regression: 7d at 35% used / 29% elapsed is red only where the gate holds" do
      # The deficit-minute colours called this red for every account. At the
      # default 0.20 weekly floor the paced gate does hold it (1.2x pace)…
      assert state(bar("claude", "7d", 0.35, 0.29)) == :red

      assert Gate.gating_window(snapshot("7d", 0.35, 0.29), paced(), now: @now) != nil

      # …but with a 0.40 weekly floor the gate dispatches, so it is not red.
      loose = paced(%{"weekly_paced_floor" => 0.4})
      assert state(bar("claude", "7d", 0.35, 0.29), loose) == :amber
      assert Gate.gating_window(snapshot("7d", 0.35, 0.29), loose, now: @now) == nil
    end

    test "under pace near reset is amber at worst — the 21:45Z/0.89 false-alarm case" do
      assert state(bar("claude", "5h", 0.89, 0.98)) == :amber
      assert state(bar("claude", "5h", 0.70, 0.98)) == :green
    end

    test "the paced floor holds however early the window is" do
      assert state(bar("claude", "5h", 0.5, 0.005)) == :red
    end

    test "in_overage forces red regardless of pace" do
      assert state(bar("claude", "5h", 0.2, 0.5, %{overage_status: "in_overage"})) == :red
    end

    test "nil utilization is green (no usage data, distinct from sampling)" do
      assert state(bar("claude", "5h", nil, 0.5)) == :green
    end

    test "a window with no fixed length uses the gate's flat fallback" do
      # Codex "session" / Antigravity's collapsed "used" have no length, so
      # paced falls back to the 0.85 flat ceiling — as the gate does.
      for {provider, label} <- [{"codex", "session"}, {"antigravity", "used"}] do
        assert state(bar(provider, "5h", 0.35, 0.5, %{label: label})) == :green
        assert state(bar(provider, "5h", 0.80, 0.5, %{label: label})) == :amber
        assert state(bar(provider, "5h", 0.90, 0.5, %{label: label})) == :red
      end
    end

    test "a nil reset_at uses the flat fallback too" do
      assert state(bar("claude", "5h", 0.95, 0.5, %{reset_at: nil})) == :red
      assert state(bar("claude", "5h", 0.35, 0.5, %{reset_at: nil})) == :green
    end

    test "antigravity (5h / weekly) is paced exactly like claude" do
      assert state(bar("antigravity", "5h", 0.36, 0.1)) == :red
      assert state(bar("antigravity", "7d", 0.35, 0.29, %{label: "weekly"})) == :red
    end

    test "the account's floors move the colour" do
      assert state(bar("claude", "5h", 0.4, 0.1)) == :red
      assert state(bar("claude", "5h", 0.4, 0.1), paced(%{"paced_floor" => 0.6})) == :green
    end
  end

  describe "quota_pace/3 — would hold vs holding" do
    test "a paced, enforcing account is holding" do
      assert %{state: :red, holding: :enforcing, mode: :paced, ceiling: 0.35} =
               pace(bar("claude", "5h", 0.4, 0.1), paced())
    end

    test "a flat account is coloured by the paced thresholds, but only would hold" do
      assert %{state: :red, holding: :not_enforcing, mode: :paced} =
               pace(bar("claude", "5h", 0.4, 0.1), flat())
    end

    test "a :continue workspace never holds, so a paced red only would hold" do
      assert %{state: :red, holding: :not_enforcing} =
               pace(bar("claude", "5h", 0.4, 0.1), paced(), false)
    end

    test "a flat gate that holds is red and holding even where pacing would not" do
      # 90% at 99% elapsed: under the paced ceiling, over the flat 0.85.
      assert %{state: :red, holding: :enforcing, mode: :flat, ceiling: 0.85} =
               pace(bar("claude", "5h", 0.9, 0.99), flat())
    end

    test "no holding flag below the ceiling" do
      assert %{holding: nil} = pace(bar("claude", "5h", 0.3, 0.1), paced())
    end

    test "nil gate_policy resolves the install default" do
      assert %{state: :red, holding: :not_enforcing} =
               quota_pace(bar("claude", "5h", 0.4, 0.1), nil, @now)
    end

    test "quota_hold_text/2 tells the operator which it is" do
      u = 0.4
      b = bar("claude", "5h", u, 0.1)

      assert quota_hold_text(pace(b, paced()), u) ==
               "holding dispatch — 40% used ≥ paced ceiling 35%"

      assert quota_hold_text(pace(b, flat()), u) ==
               "would hold — 40% used ≥ paced ceiling 35% (gate not enforcing)"

      assert quota_hold_text(pace(bar("claude", "5h", 0.3, 0.1), paced()), 0.3) ==
               "approaching paced ceiling 35%"

      assert quota_hold_text(pace(bar("claude", "5h", 0.9, 0.99), flat()), 0.9) ==
               "holding dispatch — 90% used ≥ ceiling 85%"

      assert quota_hold_text(pace(bar("claude", "5h", 0.1, 0.3), paced()), 0.1) == nil
    end
  end

  # AC4: a red bar always means the gate holds (or, for an account that is
  # not paced, that the paced gate would), and an enforcing gate that holds
  # is always red. Both sides run over the same inputs.
  describe "quota_pace/3 — the P0 exemption note (bd-6bxv7h)" do
    @exempt %{"pace_exempt_priority" => 0, "pace_exempt_threshold" => 0.8}

    test "no pace_exempt_priority: no exempt note, hold text unchanged" do
      pace = pace(bar("claude", "5h", 0.4, 0.1), paced())

      assert pace.exempt == nil
      assert quota_hold_text(pace, 0.4) == "holding dispatch — 40% used ≥ paced ceiling 35%"
    end

    test "an exempting account says P0 exempt, and how far up" do
      pace = pace(bar("claude", "5h", 0.4, 0.1), paced(@exempt))

      assert %{exempt: %{ceiling: 0.8, label: "P0 exempt"}} = pace
      # The colour and holding flag are an ordinary dispatch's.
      assert %{state: :red, holding: :enforcing} = pace

      assert quota_hold_text(pace, 0.4) ==
               "holding dispatch — 40% used ≥ paced ceiling 35%; P0 exempt up to 80%"
    end

    test "past the exempt cap the note says so" do
      pace = pace(bar("claude", "5h", 0.85, 0.1), paced(@exempt))

      assert quota_hold_text(pace, 0.85) =~ "P0 exempt cap 80% reached"
    end

    test "a wider exempt priority is labelled with its range" do
      pace =
        pace(bar("claude", "5h", 0.4, 0.1), paced(Map.put(@exempt, "pace_exempt_priority", 2)))

      assert %{exempt: %{label: "P0–P2 exempt"}} = pace
    end

    test "no note when the exemption lifts nothing (late window: the line is above the cap)" do
      assert %{exempt: nil} = pace(bar("claude", "5h", 0.96, 0.95), paced(@exempt))
    end

    test "no note when the gate is not enforcing (:continue)" do
      assert %{exempt: nil} = pace(bar("claude", "5h", 0.4, 0.1), paced(@exempt), false)
    end
  end

  describe "red ⇔ the gate holds, over a grid of inputs" do
    @utilizations [0.0, 0.04, 0.1, 0.19, 0.2, 0.25, 0.3, 0.34, 0.35, 0.36, 0.5] ++
                    [0.6, 0.75, 0.84, 0.85, 0.9, 0.99, 1.0]
    @elapsed [0.001, 0.04, 0.1, 0.2, 0.29, 0.35, 0.5, 0.6, 0.9, 0.99]

    for window <- ["5h", "7d"],
        {name, account} <- [
          paced: quote(do: paced()),
          flat: quote(do: flat()),
          loose_floors: quote(do: paced(%{"paced_floor" => 0.6, "weekly_paced_floor" => 0.45})),
          tight_flat:
            quote(do: account(%{"throttle_threshold" => 0.5, "weekly_threshold" => 0.4}))
        ] do
      test "#{window}, #{name} account" do
        account = unquote(account)
        window = unquote(window)

        for u <- @utilizations, e <- @elapsed do
          pace = pace(bar("claude", window, u, e), account)
          holds? = gate_holds?(window, u, e, account)
          paced_holds? = gate_holds?(window, u, e, Gate.paced_policy(account))
          where = "u=#{u} elapsed=#{e}: #{inspect(pace)}"

          if pace.state == :red do
            case pace.holding do
              :enforcing -> assert holds?, where
              :not_enforcing -> assert paced_holds? and not holds?, where
            end
          end

          if holds?, do: assert(pace.state == :red and pace.holding == :enforcing, where)
        end
      end
    end
  end

  defp snapshot(window, u, elapsed) do
    {primary, long} =
      if window == "5h", do: {{u, elapsed}, {0.0, 0.5}}, else: {{0.0, 0.5}, {u, elapsed}}

    %Snapshot{
      provider: "claude",
      utilization: elem(primary, 0),
      status: "allowed",
      reset_at: reset_after(elem(primary, 1), @five_hours),
      captured_at: @now,
      window_label: "5h",
      secondary_utilization: elem(long, 0),
      secondary_status: "allowed",
      secondary_reset_at: reset_after(elem(long, 1), @seven_days),
      secondary_window_label: "7d"
    }
  end

  defp gate_holds?(window, u, elapsed, policy) do
    case Gate.gating_window(snapshot(window, u, elapsed), policy, now: @now) do
      %{window: ^window, signal: :utilization} -> true
      _ -> false
    end
  end

  describe "quota_pace_label/3 — on_exhaustion-aware label text" do
    defp label(bar, on_exhaustion, account \\ paced()),
      do: quota_pace_label(bar, pace(bar, account), on_exhaustion)

    test "labels the throttle mode as \"stalls in Nm\"" do
      assert label(bar("claude", "5h", 0.35, 0.1), :throttle) =~ ~r/^stalls in \d+m$/
    end

    test "projects the burn: 35% in 30 minutes leaves 65% for ~55 minutes" do
      assert label(bar("claude", "5h", 0.35, 0.1), :throttle) == "stalls in 55m"
    end

    test "labels the continue mode as \"starts billing overage in Nm\"" do
      assert label(bar("claude", "5h", 0.35, 0.1), :continue) =~
               ~r/^starts billing overage in \d+m$/
    end

    test "labels amber too" do
      assert label(bar("claude", "5h", 0.30, 0.1), :throttle) =~ ~r/^stalls in /
    end

    test "no label when the bar is green or sampling" do
      assert label(bar("claude", "5h", 0.2, 0.5), :throttle) == nil
      assert label(bar("claude", "5h", 0.1, 0.02), :throttle) == nil
    end

    test "antigravity always says \"stalls in Nm\", never overage billing, even under :continue" do
      assert label(bar("antigravity", "5h", 0.35, 0.1), :continue) =~ ~r/^stalls in \d+m$/

      assert label(bar("antigravity", "7d", 0.35, 0.1, %{label: "weekly"}), :continue) =~
               ~r/^stalls in /
    end

    test "nil for providers without a fixed window, even when red" do
      for provider <- ["codex", "someday_cli"] do
        b = bar(provider, "5h", 0.95, 0.1, %{label: "session"})
        assert pace(b, paced()).state == :red
        assert label(b, :continue) == nil
      end
    end
  end

  describe "quota_pace_ratio/2 — pace ratio exposed for tooltip text" do
    defp ratio(bar), do: quota_pace_ratio(bar, pace(bar, paced()))

    test "reports how many times faster than on-pace the current burn is" do
      assert ratio(bar("claude", "5h", 0.35, 0.1)) == "3.5x pace"
      assert ratio(bar("claude", "7d", 0.35, 0.1)) == "3.5x pace"
    end

    test "reports sampling when the verdict is sampling" do
      assert ratio(bar("claude", "5h", 0.1, 0.02)) =~ "sampling"
    end

    test "nil for providers without a fixed window" do
      for provider <- ["codex", "someday_cli"] do
        assert ratio(bar(provider, "5h", 0.5, 0.5)) == nil
      end
    end

    test "antigravity reports the same pace ratio as claude" do
      assert ratio(bar("antigravity", "5h", 0.35, 0.1)) == ratio(bar("claude", "5h", 0.35, 0.1))
    end
  end

  describe "quota_binding_class/2 — de-emphasize the non-binding window" do
    test "no emphasis class when this window is the binding one" do
      assert quota_binding_class("five_hour", "five_hour") == nil
    end

    test "de-emphasis class when this window isn't the binding one" do
      assert quota_binding_class("five_hour", "seven_day") == "opacity-50"
    end

    test "no emphasis class when representative_claim is unknown" do
      assert quota_binding_class(nil, "five_hour") == nil
    end
  end

  describe "quota_binding_title/2 — explain the non-binding window" do
    test "no explanation title when this window is the binding one" do
      assert quota_binding_title("five_hour", "five_hour") == nil
      assert quota_binding_title("seven_day", "seven_day") == nil
    end

    test "explanation title names it as not the binding window and names the binding window" do
      assert quota_binding_title("seven_day", "five_hour") ==
               "not the binding window — Anthropic is currently limiting on 7d"

      assert quota_binding_title("five_hour", "seven_day") ==
               "not the binding window — Anthropic is currently limiting on 5h"
    end

    test "no explanation title when representative_claim is unknown" do
      assert quota_binding_title(nil, "five_hour") == nil
    end
  end

  describe "quota_note_color/2 — note/countdown colour derived from pace state" do
    test "amber pace state maps to --arb-attention" do
      assert quota_note_color(:amber, false) == "var(--arb-attention)"
    end

    test "red pace state maps to --arb-fail" do
      assert quota_note_color(:red, false) == "var(--arb-fail)"
    end

    test "grey/sampling and green pace states map to nil (neutral)" do
      assert quota_note_color(:grey, false) == nil
      assert quota_note_color(:green, false) == nil
    end

    test "stale reading maps to nil (neutral)" do
      assert quota_note_color(:red, true) == nil
      assert quota_note_color(:amber, true) == nil
      assert quota_note_color(:grey, true) == nil
      assert quota_note_color(:green, true) == nil
    end
  end

  describe "quota_tooltip_7d/3" do
    test "renders window durations in days" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)

      assert quota_tooltip_7d("claude", 0.45, reset_at) ==
               "45% quota used · 33% of window elapsed (2.3d into 7d)"
    end

    test "providers without a fixed window get no tooltip" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)
      assert quota_tooltip_7d("codex", 0.45, reset_at) == nil
      assert quota_tooltip_7d("someday_cli", 0.45, reset_at) == nil
    end

    test "antigravity gets a tooltip identical to claude's" do
      window_seconds = 7 * 24 * 60 * 60
      reset_at = DateTime.add(DateTime.utc_now(), round(window_seconds * 2 / 3), :second)

      assert quota_tooltip_7d("antigravity", 0.45, reset_at) ==
               "45% quota used · 33% of window elapsed (2.3d into 7d)"
    end
  end

  # bd-i2gwwn: the status-bar chip's rings.
  describe "Arbiter.Quota.Codex.view/1" do
    alias Arbiter.Quota.Codex
    alias Arbiter.Quota.CodexQuota

    test "session-only snapshot (nil weekly) produces single-window view" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      row = %CodexQuota{
        provider_account_id: "acc-1",
        provider: "codex",
        plan: "free",
        session_used_percent: 30.0,
        session_reset_at: DateTime.add(now, 3600),
        weekly_used_percent: nil,
        weekly_reset_at: nil,
        captured_at: now
      }

      view = Codex.view(row)

      assert view.utilization_5h == 0.30
      assert view.reset_5h_at == DateTime.add(now, 3600)
      assert view.utilization_7d == nil
      assert view.reset_7d_at == nil
      assert view.primary_label == "session"
      assert view.secondary_label == nil
    end

    test "zero weekly snapshot (0.0 weekly) produces two-window view" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      row = %CodexQuota{
        provider_account_id: "acc-1",
        provider: "codex",
        plan: "free",
        session_used_percent: 50.0,
        session_reset_at: DateTime.add(now, 3600),
        weekly_used_percent: 0.0,
        weekly_reset_at: DateTime.add(now, 604_800),
        captured_at: now
      }

      view = Codex.view(row)

      assert view.utilization_5h == 0.50
      assert view.utilization_7d == 0.0
      assert view.reset_7d_at == DateTime.add(now, 604_800)
      assert view.primary_label == "session"
      assert view.secondary_label == "weekly"
    end
  end

  describe "quota_rings/1, quota_ring_summary/2" do
    @flat %{policy: {nil, nil}, enforcing?: true}

    defp view(attrs) do
      "claude"
      |> Arbiter.Quota.blank_view()
      |> Map.merge(%{gate_policy: @flat, captured_at: DateTime.utc_now()})
      |> Map.merge(attrs)
    end

    test "paid overage reds the ring and says so" do
      v = view(%{utilization_5h: 1.0, utilization_7d: 0.5, overage_status: "in_overage"})
      rings = quota_rings(v)

      assert rings.inner.state == :holding
      assert rings.inner.status == "in paid overage"
      assert quota_ring_stroke(rings.inner.state) == "var(--arb-fail)"
    end

    test "a window with no reading is a no-data ring, named as such" do
      v = view(%{utilization_5h: 0.3})
      rings = quota_rings(v)

      assert rings.outer.state == :no_data
      assert rings.outer.pct == nil
      assert quota_ring_stroke(:no_data) == nil
      assert quota_ring_summary(v, rings) =~ "; 7d no data"
    end

    test "a single-window view leaves its empty outer ring out of the label" do
      v =
        "antigravity"
        |> Arbiter.Quota.blank_view()
        |> Map.merge(%{
          gate_policy: @flat,
          utilization_5h: 0.6,
          primary_label: "used",
          secondary_label: nil
        })

      rings = quota_rings(v)
      assert rings.outer.state == :no_data
      assert quota_ring_summary(v, rings) =~ ~r/^Antigravity: used 60%, [a-z ,]+$/
    end

    test "a no-data placeholder reads 'no data yet' on both rings" do
      v =
        "claude" |> Arbiter.Quota.blank_view() |> Map.merge(%{no_data: true, gate_policy: @flat})

      rings = quota_rings(v)

      assert quota_no_data?(v)
      assert rings.inner.state == :no_data and rings.outer.state == :no_data
      assert quota_ring_summary(v, rings) == "Claude: no data yet"
    end

    test "antigravity rings take the more-constrained bucket group, per window" do
      reset = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

      models = [
        %{"model_id" => "gemini_models_5h", "remaining_percentage" => 90.0, "reset_at" => reset},
        %{
          "model_id" => "gemini_models_weekly",
          "remaining_percentage" => 50.0,
          "reset_at" => reset
        },
        %{
          "model_id" => "claude_and_gpt_models_5h",
          "remaining_percentage" => 20.0,
          "reset_at" => reset
        },
        %{
          "model_id" => "claude_and_gpt_models_weekly",
          "remaining_percentage" => 95.0,
          "reset_at" => reset
        }
      ]

      v =
        "antigravity"
        |> Arbiter.Quota.blank_view()
        |> Map.merge(%{gate_policy: @flat, models: models})

      rings = quota_rings(v)
      assert {rings.inner.pct, rings.inner.group} == {80, "Claude and GPT models"}
      assert {rings.outer.pct, rings.outer.group} == {50, "Gemini Models"}
    end

    test "a stale reading is a neutral stale ring, whatever the pace" do
      v = view(%{utilization_5h: 0.99, utilization_7d: 0.99, message: "agy unreachable"})
      rings = quota_rings(v)

      assert rings.inner.state == :stale
      assert quota_ring_stroke(:stale) == "var(--arb-done)"
      assert quota_ring_title(v, rings) =~ "stale reading: agy unreachable"
    end

    test "codex with only session data (no weekly) renders one ring" do
      v =
        "codex"
        |> Arbiter.Quota.blank_view()
        |> Map.merge(%{
          gate_policy: @flat,
          utilization_5h: 0.27,
          reset_5h_at: DateTime.utc_now() |> DateTime.add(3600),
          utilization_7d: nil,
          reset_7d_at: nil,
          primary_label: "session",
          secondary_label: nil,
          captured_at: DateTime.utc_now()
        })

      rings = quota_rings(v)

      assert rings.inner.state == :ok
      assert rings.inner.pct == 27
      assert rings.inner.label == "session"
      assert rings.outer.state == :no_data
      assert quota_ring_summary(v, rings) =~ "session 27%, on pace"
      refute quota_ring_summary(v, rings) =~ "7d"
    end

    test "codex with zero weekly data shows only session ring" do
      v =
        "codex"
        |> Arbiter.Quota.blank_view()
        |> Map.merge(%{
          gate_policy: @flat,
          utilization_5h: 0.50,
          reset_5h_at: DateTime.utc_now() |> DateTime.add(3600),
          utilization_7d: nil,
          reset_7d_at: nil,
          primary_label: "session",
          secondary_label: nil,
          captured_at: DateTime.utc_now()
        })

      rings = quota_rings(v)

      # Inner ring should be the session window
      assert rings.inner.label == "session"
      assert rings.inner.pct == 50
      # Outer ring should be no_data, not rendered in summary
      assert rings.outer.state == :no_data
      summary = quota_ring_summary(v, rings)
      assert summary =~ "Codex: session 50%"
      refute summary =~ "no data"
    end
  end
end
