defmodule Arbiter.Machine.DerateTest do
  use ExUnit.Case, async: true

  alias Arbiter.Machine.Derate
  alias Arbiter.Machine.Derate.Config

  @gib 1_073_741_824
  @cfg Config.build(%{})
  @healthy %{temp_c: 60.0, psi: %{some_avg10: 0.5}, mem_available: 20 * @gib}

  defp step(readings, prior, now_s, opts \\ []) do
    Derate.evaluate(
      %{cap: opts[:cap] || 4, live: opts[:live] || 2, readings: readings},
      opts[:config] || @cfg,
      prior,
      now_s * 1000
    )
  end

  defp hot(temp), do: %{@healthy | temp_c: temp}

  describe "Config.build/1" do
    test "defaults: on, soft 90, hard 95, 4 GiB floor" do
      assert %Config{
               enabled: true,
               thermal_soft_c: 90.0,
               thermal_hard_c: 95.0,
               mem_floor_bytes: 4_294_967_296
             } = Config.build(%{})
    end

    test "string or atom keys override; garbage falls back to the default" do
      cfg =
        Config.build(%{
          "thermal_soft_c" => 85,
          :thermal_hard_c => "no",
          "enabled" => false,
          "recover_s" => -4,
          "bogus" => 1
        })

      assert cfg.thermal_soft_c == 85.0
      assert cfg.thermal_hard_c == 95.0
      assert cfg.enabled == false
      assert cfg.recover_s == Config.build(%{}).recover_s
    end

    test "hard is never below soft" do
      cfg = Config.build(%{"thermal_soft_c" => 97, "thermal_hard_c" => 95})
      assert cfg.thermal_hard_c >= cfg.thermal_soft_c
    end

    test "from_env/1 reads ARB_NODE_* variables" do
      cfg =
        Config.from_env(%{
          "ARB_NODE_DERATE" => "off",
          "ARB_NODE_THERMAL_SOFT_C" => "80",
          "ARB_NODE_MEM_FLOOR_GIB" => "8",
          "ARB_NODE_MEM_PSI_SOME" => "oops"
        })

      assert cfg.enabled == false
      assert cfg.thermal_soft_c == 80.0
      assert cfg.mem_floor_bytes == 8 * @gib
      assert cfg.psi_some_avg10 == Config.build(%{}).psi_some_avg10
    end
  end

  describe "unknown never derates" do
    test "no readings at all" do
      {r, state} = step(%{temp_c: nil, psi: nil, mem_available: nil}, Derate.initial(), 0)
      assert r.level == :none
      assert r.offered == 4
      assert r.reason == nil
      assert state.level == :none
    end

    test "disabled config never derates even when hot" do
      cfg = Config.build(%{"enabled" => false})
      {r, _} = step(hot(120.0), Derate.initial(), 0, config: cfg)
      assert r.level == :none
      assert r.offered == 4
    end
  end

  describe "thermal" do
    test "healthy offers the full cap" do
      {r, _} = step(@healthy, Derate.initial(), 0)
      assert %{level: :none, offered: 4} = r
    end

    test "at soft: no new slots (offered = live), never below live" do
      {r, _} = step(hot(90.0), Derate.initial(), 0, cap: 4, live: 2)
      assert %{level: :soft, offered: 2} = r
      assert r.reason_text =~ "thermal 90"
    end

    test "offered never exceeds the cap even when live is over it" do
      {r, _} = step(hot(92.0), Derate.initial(), 0, cap: 2, live: 3)
      assert r.offered == 2
    end

    test "with nothing running a soft derate offers 0" do
      {r, _} = step(hot(92.0), Derate.initial(), 0, live: 0)
      assert r.offered == 0
    end

    test "at hard: still never kills (offered = live) but holds resumes and fix passes" do
      {r, _} = step(hot(96.0), Derate.initial(), 0, live: 3)
      assert %{level: :hard, offered: 3} = r
      assert Derate.hold_new_work?(r.level)
      refute Derate.hold_new_work?(:soft)
      assert r.reason_text =~ "thermal 96"
    end

    test "soft to hard is immediate" do
      {_, s1} = step(hot(91.0), Derate.initial(), 0)
      {r, _} = step(hot(96.0), s1, 10)
      assert r.level == :hard
    end
  end

  describe "memory" do
    test "PSI some avg10 at the threshold derates" do
      readings = %{@healthy | psi: %{some_avg10: 25.0}}
      {r, _} = step(readings, Derate.initial(), 0)
      assert %{level: :soft, offered: 2} = r
      assert r.reason_text =~ "PSI"
    end

    test "MemAvailable below the floor derates" do
      readings = %{@healthy | mem_available: 3 * @gib}
      {r, _} = step(readings, Derate.initial(), 0)
      assert r.level == :soft
      assert r.reason_text =~ "MemAvailable"
    end

    test "memory pressure alone is never a hard derate" do
      readings = %{@healthy | psi: %{some_avg10: 90.0}, mem_available: 1 * @gib}
      {r, _} = step(readings, Derate.initial(), 0)
      assert r.level == :soft
    end

    test "a missing PSI file with plenty of memory is fine" do
      {r, _} = step(%{@healthy | psi: nil}, Derate.initial(), 0)
      assert r.level == :none
    end
  end

  describe "hysteresis" do
    test "recovers only after recover_s continuously below soft - delta" do
      recover = @cfg.recover_s
      {_, s} = step(hot(92.0), Derate.initial(), 0)

      # Cooled to 80 (< 90 - 5): the clock starts, nothing recovers yet.
      {r1, s1} = step(hot(80.0), s, 10)
      assert r1.level == :soft
      {r2, s2} = step(hot(80.0), s1, 10 + recover - 1)
      assert r2.level == :soft
      {r3, s3} = step(hot(80.0), s2, 10 + recover)
      assert r3.level == :none
      assert r3.offered == 4
      assert s3.level == :none
    end

    test "inside the band (soft - delta .. soft) it holds and resets the clock" do
      recover = @cfg.recover_s
      {_, s} = step(hot(92.0), Derate.initial(), 0)
      {_, s1} = step(hot(80.0), s, 10)
      # Back up into the band at 87 (>= 85): clock resets.
      {r2, s2} = step(hot(87.0), s1, 10 + recover - 5)
      assert r2.level == :soft
      assert s2.recover_since == nil
      # Cool again: needs a full window from here.
      {_, s3} = step(hot(80.0), s2, 10 + recover)
      {r4, _} = step(hot(80.0), s3, 10 + recover + recover - 1)
      assert r4.level == :soft
      {r5, _} = step(hot(80.0), s3, 10 + recover + recover)
      assert r5.level == :none
    end

    test "a spike back above soft while recovering does not flap: stays soft, clock cleared" do
      recover = @cfg.recover_s
      {_, s} = step(hot(92.0), Derate.initial(), 0)
      {_, s1} = step(hot(80.0), s, 10)
      {r2, s2} = step(hot(91.0), s1, 20)
      assert r2.level == :soft
      assert s2.recover_since == nil
      {r3, _} = step(hot(80.0), s2, 20 + recover - 1)
      assert r3.level == :soft
    end

    test "hard steps down to soft after the window, then to none after another" do
      recover = @cfg.recover_s
      {_, s} = step(hot(97.0), Derate.initial(), 0)
      # 88: below hard - delta (90) but still inside soft's band (85..90).
      {_, s1} = step(hot(88.0), s, 10)
      {r2, s2} = step(hot(88.0), s1, 10 + recover)
      assert r2.level == :soft
      assert r2.offered == 2
      # The soft recovery window starts from the step down.
      {r3, s3} = step(hot(80.0), s2, 10 + recover + 1)
      assert r3.level == :soft
      {r4, _} = step(hot(80.0), s3, 10 + recover + 1 + recover)
      assert r4.level == :none
    end

    test "unknown readings while derated recover like healthy ones (unknown never derates)" do
      recover = @cfg.recover_s
      {_, s} = step(hot(92.0), Derate.initial(), 0)
      unknown = %{temp_c: nil, psi: nil, mem_available: nil}
      {_, s1} = step(unknown, s, 10)
      {r, _} = step(unknown, s1, 10 + recover)
      assert r.level == :none
    end

    test "memory recovers on psi - delta and floor + delta" do
      recover = @cfg.recover_s
      bad = %{@healthy | psi: %{some_avg10: 30.0}}
      {_, s} = step(bad, Derate.initial(), 0)
      # PSI 20 is under 25 but not under 25 - 10: held.
      {r1, s1} = step(%{@healthy | psi: %{some_avg10: 20.0}}, s, 10)
      assert r1.level == :soft
      assert s1.recover_since == nil
      {_, s2} = step(@healthy, s1, 20)
      {r3, _} = step(@healthy, s2, 20 + recover)
      assert r3.level == :none
    end
  end

  describe "apply_level/3 (the primary's side of a node heartbeat)" do
    test "none keeps the cap; soft and hard offer min(cap, live)" do
      assert Derate.apply_level(4, 1, :none) == 4
      assert Derate.apply_level(4, 1, :soft) == 1
      assert Derate.apply_level(4, 3, :hard) == 3
      assert Derate.apply_level(2, 5, :soft) == 2
    end

    test "level parsing from the wire is closed over known words" do
      assert Derate.parse_level("hard") == :hard
      assert Derate.parse_level("soft") == :soft
      assert Derate.parse_level("none") == :none
      assert Derate.parse_level("bogus") == :none
      assert Derate.parse_level(nil) == :none
    end
  end
end
