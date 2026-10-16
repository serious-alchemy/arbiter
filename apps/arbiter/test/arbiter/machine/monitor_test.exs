defmodule Arbiter.Machine.MonitorTest do
  use ExUnit.Case, async: true

  alias Arbiter.Machine.Derate.Config
  alias Arbiter.Machine.Monitor

  @gib 1_073_741_824

  defp start_monitor(readings, opts \\ []) do
    {:ok, script} = Agent.start_link(fn -> readings end)
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    name = :"monitor_#{System.unique_integer([:positive])}"
    test = self()

    start_supervised!(
      {Monitor,
       [
         name: name,
         interval_ms: :manual,
         config_fun: fn -> opts[:config] || Config.build(%{"recover_s" => 60}) end,
         cap_fun: fn -> 4 end,
         live_fun: fn -> 2 end,
         alpha: opts[:alpha] || 1.0,
         sensor_fun: fn -> Agent.get(script, & &1) end,
         clock: fn -> Agent.get(clock, & &1) end,
         on_transition: fn event -> send(test, {:transition, event}) end
       ]}
    )

    {name, script, clock}
  end

  defp readings(temp, opts \\ []) do
    %{
      temp_c: temp,
      psi: opts[:psi] || %{some_avg10: 0.0, some_avg60: 0.0, full_avg10: 0.0, full_avg60: 0.0},
      mem_available: opts[:mem] || 20 * @gib
    }
  end

  test "a machine that has not sampled yet reports nothing" do
    name = :"unstarted_#{System.unique_integer([:positive])}"
    assert Monitor.current(name) == nil
    assert Monitor.level(name) == :none
  end

  test "healthy: full cap offered, level none" do
    {name, _script, _clock} = start_monitor(readings(60.0))
    snap = Monitor.sample(name)
    assert %{level: :none, offered: 4, temp_c: 60.0, reason: nil} = snap
    assert Monitor.current(name) == snap
  end

  test "enters soft derate at the threshold and announces the transition once" do
    {name, script, _clock} =
      start_monitor(readings(60.0),
        config: Config.build(%{"recover_s" => 60, "thermal_entry_samples" => 1})
      )

    Monitor.sample(name)
    Agent.update(script, fn _ -> readings(91.0) end)
    snap = Monitor.sample(name)
    assert %{level: :soft, offered: 2} = snap
    assert Monitor.level(name) == :soft
    assert_receive {:transition, %{from: :none, to: :soft, snapshot: %{level: :soft}}}

    Monitor.sample(name)
    refute_receive {:transition, _}, 20
  end

  test "hard derate then recovery announces entering and leaving hard" do
    {name, script, clock} = start_monitor(readings(60.0))
    Agent.update(script, fn _ -> readings(97.0) end)
    Monitor.sample(name)
    assert_receive {:transition, %{from: :none, to: :hard}}

    Agent.update(script, fn _ -> readings(70.0) end)
    Agent.update(clock, fn _ -> 1_000 end)
    Monitor.sample(name)
    refute_receive {:transition, _}, 20
    Agent.update(clock, fn _ -> 61_000 end)
    Monitor.sample(name)
    assert_receive {:transition, %{from: :hard, to: :none}}
  end

  test "smoothing: one spike below the threshold after EWMA does not derate" do
    {name, script, _clock} = start_monitor(readings(60.0), alpha: 0.2)
    Monitor.sample(name)
    Agent.update(script, fn _ -> readings(99.0) end)
    snap = Monitor.sample(name)
    # 60 + 0.2 * (99 - 60) = 67.8
    assert_in_delta snap.temp_c, 67.8, 0.01
    assert snap.level == :none
  end

  test "unknown readings stay unknown and never derate" do
    {name, _script, _clock} =
      start_monitor(%{temp_c: nil, psi: nil, mem_available: nil})

    assert %{level: :none, temp_c: nil, psi: nil, mem_available: nil} = Monitor.sample(name)
  end

  describe "smooth/3" do
    test "first sample is taken as is; unknown drops; psi keys smooth independently" do
      new =
        readings(80.0,
          psi: %{some_avg10: 10.0, some_avg60: 0.0, full_avg10: 0.0, full_avg60: 0.0}
        )

      assert Monitor.smooth(nil, new, 0.5) == new

      prev = readings(60.0)
      out = Monitor.smooth(prev, new, 0.5)
      assert out.temp_c == 70.0
      assert out.psi.some_avg10 == 5.0

      assert Monitor.smooth(prev, %{new | temp_c: nil}, 0.5).temp_c == nil
      assert Monitor.smooth(prev, %{new | psi: nil}, 0.5).psi == nil
    end
  end
end
