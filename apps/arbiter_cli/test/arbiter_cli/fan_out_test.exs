defmodule ArbiterCli.FanOutTest do
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.FanOut

  @arb_cmdline [
    "beam.smp",
    "-noshell",
    "-run",
    "escript",
    "start",
    "-extra",
    "/home/u/.local/bin/arb",
    "x"
  ]

  defp fake_proc(entries) do
    root = Path.join(System.tmp_dir!(), "arb-proc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {pid, cmdline} <- entries do
      File.mkdir_p!(Path.join(root, to_string(pid)))

      File.write!(
        Path.join([root, to_string(pid), "cmdline"]),
        Enum.join(cmdline, <<0>>) <> <<0>>
      )
    end

    root
  end

  describe "count_peers/1" do
    test "counts other arb escript VMs and ignores self and unrelated processes" do
      root =
        fake_proc([
          {1, @arb_cmdline},
          {2, @arb_cmdline},
          {3, ["bash", "-c", "arb"]},
          {4, ["beam.smp", "-extra", "/usr/bin/other"]},
          {System.pid() |> String.to_integer(), @arb_cmdline}
        ])

      assert FanOut.count_peers(proc_root: root) == 2
    end

    test "fails open (0) when /proc is unavailable" do
      assert FanOut.count_peers(proc_root: "/nonexistent/proc") == 0
    end
  end

  describe "check/2" do
    test "ok at or below the soft threshold" do
      assert FanOut.check(16, warn: 16, max: 64) == :ok
    end

    test "warns above the soft threshold, pointing at arb batch" do
      assert {:warn, msg} = FanOut.check(17, warn: 16, max: 64)
      assert msg =~ "arb batch"
    end

    test "refuses above the hard ceiling" do
      assert {:refuse, msg} = FanOut.check(65, warn: 16, max: 64)
      assert msg =~ "ARB_ALLOW_FANOUT=1"
    end

    test "force turns a refusal into a warning" do
      assert {:warn, _} = FanOut.check(65, warn: 16, max: 64, force: true)
    end
  end

  describe "thresholds/1" do
    test "defaults and env overrides" do
      assert FanOut.thresholds(%{}) == [warn: 16, max: 64]

      assert FanOut.thresholds(%{"ARB_FANOUT_WARN" => "3", "ARB_FANOUT_MAX" => "5"}) ==
               [warn: 3, max: 5]

      assert FanOut.thresholds(%{"ARB_FANOUT_WARN" => "junk"}) == [warn: 16, max: 64]
    end
  end

  describe "enforce!/1 through Main" do
    setup do
      stub_get("/api/workspaces", %{
        "data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]
      })

      :ok
    end

    test "refuses over the ceiling, allows with --allow-fanout" do
      Process.put(:bd2_fanout_count, 100)
      {_out, err, code} = capture(fn -> ArbiterCli.Main.main(["where"]) end)
      assert code == 1
      assert err =~ "arb batch"

      {_out, err, code} = capture(fn -> ArbiterCli.Main.main(["where", "--allow-fanout"]) end)
      assert code == 0
      assert err =~ "arb batch"
    end

    test "leading --force and repeated --allow-fanout lift the refusal" do
      Process.put(:bd2_fanout_count, 100)

      for argv <- [["--force", "where"], ["where", "--allow-fanout", "--allow-fanout"]] do
        {_out, _err, code} = capture(fn -> ArbiterCli.Main.main(argv) end)
        assert code == 0
      end
    end

    test "warns between the thresholds but still runs" do
      Process.put(:bd2_fanout_count, 20)
      {_out, err, code} = capture(fn -> ArbiterCli.Main.main(["where"]) end)
      assert code == 0
      assert err =~ "20 other"
    end
  end
end
