defmodule Arbiter.NodeAgent.ProtocolTest do
  use ExUnit.Case, async: true

  alias Arbiter.NodeAgent.Config
  alias Arbiter.NodeAgent.Protocol

  @gib 1024 * 1024 * 1024

  describe "suggestion/2 (design §13)" do
    test "CPU-bound: plenty of memory, few CPUs" do
      # 8 cpus / 2 per worker = 4; memory would allow 0.8 * 128 / 4 = 25
      assert Protocol.suggestion(8, 128 * @gib) == 4
    end

    test "memory-bound: many CPUs, little memory" do
      # 64 cpus / 2 = 32; 0.8 * 16 / 4 = 3.2 -> 3
      assert Protocol.suggestion(64, 16 * @gib) == 3
    end

    test "ryan-oryx-pro shape: 20 cpus, ~31.2 GiB" do
      assert Protocol.suggestion(20, trunc(31.2 * @gib)) == 6
    end

    test "never below 1 on a tiny machine" do
      assert Protocol.suggestion(1, 1 * @gib) == 1
    end

    test "unknown memory falls back to the CPU term alone" do
      assert Protocol.suggestion(8, nil) == 4
    end
  end

  describe "hello/2 capacity" do
    defp config(opts) do
      struct!(Config, [version: "0.0.0", node_id: "n1", run_opts: []] ++ opts)
    end

    test "carries a suggestion derived from cpus and mem_total" do
      %{"capacity" => capacity} = Protocol.hello(config([]), %{})
      assert is_integer(capacity["cpus"])

      assert capacity["suggestion"] ==
               Protocol.suggestion(capacity["cpus"], capacity["mem_total"])
    end

    test "carries the owner ceiling when configured, omits it otherwise" do
      assert %{"capacity" => %{"ceiling" => 3}} = Protocol.hello(config(max_workers: 3), %{})
      refute Map.has_key?(Protocol.hello(config([]), %{})["capacity"], "ceiling")
    end
  end

  describe "hello/2 caps" do
    test "advertises holding a run for recovery (bd-24o760) and handing it to a new Worker (bd-4p1vui)" do
      caps = Protocol.hello(config([]), %{})["caps"]
      assert caps["run_hold"] == "quiesce"
      assert caps["run_adopt"] == "attach"
    end
  end

  describe "Config max_workers" do
    test "ARB_NODE_MAX_WORKERS parses to the ceiling; junk is ignored" do
      load = fn value ->
        {:ok, config} =
          Config.load(
            env: %{
              "ARB_NODE_URL" => "https://p.example",
              "HOME" => "/tmp/x",
              "ARB_NODE_MAX_WORKERS" => value
            },
            app_config: [],
            read_credential: fn _ -> {:ok, "arbn_00000000-0000-0000-0000-000000000001.s"} end
          )

        config.max_workers
      end

      assert load.("4") == 4
      assert load.("0") == nil
      assert load.("many") == nil
    end
  end

  describe "heartbeat/2 derate fields (bd-6w7usy)" do
    alias Arbiter.Machine.Monitor

    defp monitor(readings, live) do
      name = :"hb_monitor_#{System.unique_integer([:positive])}"

      start_supervised!(
        {Monitor,
         name: name,
         interval_ms: :manual,
         alpha: 1.0,
         cap_fun: fn -> 4 end,
         live_fun: fn -> live end,
         sensor_fun: fn -> readings end}
      )

      Monitor.sample(name)
      name
    end

    defp hb_config(monitor),
      do: struct!(Config, version: "0.0.0", node_id: "n1", monitor: monitor)

    test "a derated machine reports temp, pressure, offered, level and reason" do
      psi = %{some_avg10: 1.5, some_avg60: 0.5, full_avg10: 0.0, full_avg60: 0.0}
      name = monitor(%{temp_c: 96.0, psi: psi, mem_available: 20 * @gib}, 3)

      hb = Protocol.heartbeat(hb_config(name), 7)

      assert hb["temp_c"] == 96.0

      assert hb["psi"] == %{
               "some_avg10" => 1.5,
               "some_avg60" => 0.5,
               "full_avg10" => 0.0,
               "full_avg60" => 0.0
             }

      assert hb["derate"] == "hard"
      assert hb["offered"] == 3
      assert hb["derate_reason"] =~ "thermal 96"
    end

    test "a healthy machine reports level none and its whole cap" do
      name = monitor(%{temp_c: 60.0, psi: nil, mem_available: 20 * @gib}, 1)
      hb = Protocol.heartbeat(hb_config(name), 1)
      assert hb["derate"] == "none"
      assert hb["offered"] == 4
      assert hb["temp_c"] == 60.0
      refute Map.has_key?(hb, "psi")
      refute Map.has_key?(hb, "derate_reason")
    end

    test "no monitor running: the heartbeat is as before" do
      hb = Protocol.heartbeat(hb_config(:no_such_monitor), 1)
      refute Map.has_key?(hb, "derate")
      refute Map.has_key?(hb, "temp_c")
      refute Map.has_key?(hb, "offered")
    end
  end
end
