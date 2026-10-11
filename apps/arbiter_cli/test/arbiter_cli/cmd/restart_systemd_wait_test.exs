defmodule ArbiterCli.Cmd.RestartSystemdWaitTest do
  # async: false — Process-dictionary seams plus the shared Req.Test stub.
  use ArbiterCli.CliCase, async: false

  alias ArbiterCli.Cmd.Restart

  @green %{"data" => [%{"id" => "ws-1", "name" => "default", "prefix" => "bd"}]}

  setup do
    Process.put(:bd2_sleep, fn _ms -> :ok end)
    stub_get("/api/workspaces", @green)
    :ok
  end

  # Stubs systemctl: `states` is the queue of ActiveState answers `show` gives
  # (the last one repeats). Every command is sent to the test process.
  defp stub_systemctl(states) do
    test_pid = self()
    {:ok, agent} = Agent.start_link(fn -> states end)

    Process.put(:bd2_cmd_runner, fn cmd, args, _opts ->
      send(test_pid, {:cmd, cmd, args})

      case {cmd, args} do
        {"systemctl", ["--user", "cat", "arbiter.service"]} ->
          {"", 0}

        {"systemctl", ["--user", "show", "arbiter.service" | _]} ->
          state =
            Agent.get_and_update(agent, fn
              [last] -> {last, [last]}
              [head | rest] -> {head, rest}
            end)

          {show_output(state), 0}

        _ ->
          {"", 0}
      end
    end)
  end

  defp show_output({state, id, job}),
    do: "ActiveState=#{state}\nInvocationID=#{id}\nJob=#{job}\n"

  defp show_output(state), do: "ActiveState=#{state}\n"

  defp cmds(acc \\ []) do
    receive do
      {:cmd, cmd, args} -> cmds([{cmd, args} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "normal: restart is non-blocking and the service is verified active" do
    stub_systemctl(["activating", "active"])

    assert {:ok, [{:systemd_restart, :ok, nil}], _} = Restart.perform("/tmp/x", 5_000)

    cmds = cmds()
    assert {"systemctl", ["--user", "restart", "--no-block", "arbiter.service"]} in cmds
    refute {"systemctl", ["--user", "daemon-reexec"]} in cmds
  end

  test "stuck waiting: daemon-reexec, one start retry, then recovered" do
    # inactive for the whole stuck window, then active once started again
    stub_systemctl(List.duplicate("inactive", 40) ++ ["active"])

    assert {:ok, [{:systemd_restart, :recovered, _}], _} = Restart.perform("/tmp/x", 5_000)

    cmds = cmds()
    assert Enum.count(cmds, &(&1 == {"systemctl", ["--user", "daemon-reexec"]})) == 1
    assert {"systemctl", ["--user", "start", "--no-block", "arbiter.service"]} in cmds
  end

  test "stays down: perform reports :down and does not loop forever" do
    stub_systemctl(["inactive"])

    assert {:down, [{:systemd_restart, :down, "inactive"}], _} = Restart.perform("/tmp/x", 5_000)

    cmds = cmds()
    assert Enum.count(cmds, &(&1 == {"systemctl", ["--user", "daemon-reexec"]})) == 1

    assert Enum.count(
             cmds,
             &(&1 == {"systemctl", ["--user", "start", "--no-block", "arbiter.service"]})
           ) == 1
  end

  test "an `active` read of the old instance (same InvocationID) is not success" do
    # baseline read, then old instance still active, then a new instance
    stub_systemctl([{"active", "old", ""}, {"active", "old", ""}, {"active", "new", ""}])

    assert {:ok, [{:systemd_restart, :ok, nil}], _} = Restart.perform("/tmp/x", 5_000)
    # a second `show` poll was needed: the first `active` was the old instance
    shows = Enum.count(cmds(), &match?({"systemctl", ["--user", "show" | _]}, &1))
    assert shows >= 4
  end

  test "an `active` unit with a queued job is not success; stays down is reported" do
    stub_systemctl([{"active", "old", ""}, {"active", "new", "123"}])

    assert {:down, [{:systemd_restart, :down, "inactive"}], _} =
             Restart.perform("/tmp/x", 5_000)
  end

  test "down_message
 names the state and the recovery and rollback commands" do
    msg = Restart.down_message({:systemd_restart, :down, "inactive"})
    assert msg =~ "server is DOWN"
    assert msg =~ "systemctl --user daemon-reexec"
    assert msg =~ "systemctl --user start arbiter.service"
    assert msg =~ "current"
  end
end
